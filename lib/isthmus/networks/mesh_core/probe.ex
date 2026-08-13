defmodule Isthmus.Networks.MeshCore.Probe do
  @moduledoc """
  Exclusive USB companion probe for diagnosing MeshCore protocol.

  Opens the serial port (must not be held by the running Phoenix app),
  runs handshake + targeted commands, and returns structured results with
  raw hex for every inbound frame.
  """

  alias Isthmus.Networks.MeshCore.Protocol

  @default_baud 115_200
  @read_idle_ms 80
  @cmd_timeout_ms 1_500
  @channel_timeout_ms 600

  @type frame_log :: %{
          dir: :in | :out,
          hex: String.t(),
          parsed: term(),
          at_ms: non_neg_integer()
        }

  @type step_result :: %{
          name: String.t(),
          ok?: boolean(),
          detail: term(),
          frames: [frame_log()]
        }

  @doc """
  Run selected probes.

  Options:
  - `:port` — serial device (default `ISTHMUS_MESHCORE_PORT`)
  - `:steps` — list of `:device | :contacts | :channels | :set_dry` (default all except set_dry)
  - `:channel_idx` — single channel for `:channels` / `:set_dry` (default all 0..7)
  - `:timeout_ms` — per-command wait (default 2000)
  """
  def run(opts \\ []) do
    port = opts[:port] || System.get_env("ISTHMUS_MESHCORE_PORT")
    steps = opts[:steps] || [:device, :contacts, :channels]
    timeout = opts[:timeout_ms] || @cmd_timeout_ms

    cond do
      not is_binary(port) or port == "" ->
        {:error, :no_port}

      true ->
        Application.ensure_all_started(:circuits_uart)
        do_run(port, steps, timeout, opts)
    end
  end

  defp do_run(port, steps, timeout, opts) do
    # Circuits.UART is linked; close timeouts must not kill the Mix task.
    Process.flag(:trap_exit, true)

    case Circuits.UART.start_link() do
      {:ok, uart} ->
        open_opts = [speed: @default_baud, active: false]

        result =
          case open_with_timeout(uart, port, open_opts, 4_000) do
            :ok ->
              started = System.monotonic_time(:millisecond)
              state = %{uart: uart, port: port, started: started, log: [], timeout: timeout}
              {results, state} = Enum.map_reduce(steps, state, &run_step(&1, &2, opts))

              {:ok,
               %{
                 port: port,
                 baud: @default_baud,
                 steps: results,
                 frames: Enum.reverse(state.log)
               }}

            {:error, reason} ->
              {:error, {:open_failed, reason}}
          end

        safe_close(uart)
        result

      {:error, reason} ->
        {:error, {:uart_start_failed, reason}}
    end
  end

  defp open_with_timeout(uart, port, open_opts, ms) do
    parent = self()
    ref = make_ref()

    opener =
      spawn(fn ->
        result =
          try do
            Circuits.UART.open(uart, port, open_opts)
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} -> result
    after
      ms ->
        Process.exit(opener, :kill)
        {:error, :open_timeout}
    end
  end

  defp safe_close(uart) do
    # Never Circuits.UART.close/1 — close often :port_timed_out on ACM devices.
    Isthmus.Networks.Uart.release(uart)

    receive do
      {:EXIT, ^uart, _} -> :ok
    after
      200 -> :ok
    end
  end

  defp run_step(:device, state, _opts) do
    state = drain(state)
    state = write(state, Protocol.device_query_frame(), :device_query)

    {frames, state} =
      await_parsed(state, fn
        {:device_info, _} -> true
        _ -> false
      end)

    detail =
      case Enum.find_value(frames, fn
             %{parsed: {:device_info, rest}} -> summarize_device_info(rest)
             _ -> nil
           end) do
        nil -> :no_device_info
        info -> info
      end

    state = write(state, Protocol.app_start_frame("IsthmusProbe"), :app_start)

    {self_frames, state} =
      await_parsed(state, fn
        {:self_info, _} -> true
        _ -> false
      end)

    self_ok? = Enum.any?(self_frames, &match?(%{parsed: {:self_info, _}}, &1))
    device_ok? = detail != :no_device_info

    {%{
       name: "device",
       ok?: device_ok? or self_ok?,
       detail: %{
         device_info: detail,
         self_info?: self_ok?,
         frames: length(frames) + length(self_frames)
       },
       frames: frames ++ self_frames
     }, state}
  end

  defp run_step(:contacts, state, _opts) do
    state = drain(state)
    state = write(state, Protocol.get_contacts_frame(), :get_contacts)

    {frames, state, acc} =
      await_until(
        state,
        fn acc, parsed ->
          case parsed do
            {:contacts_start, n} ->
              {:cont, Map.put(acc, :expected, n)}

            {:contact, c} ->
              {:cont, update_in(acc, [:contacts], &[c | &1])}

            {:end_of_contacts, lastmod} ->
              {:halt, Map.put(acc, :lastmod, lastmod)}

            _ ->
              {:cont, acc}
          end
        end,
        %{contacts: [], expected: nil, lastmod: nil}
      )

    contacts = Enum.reverse(acc.contacts)
    count = length(contacts)
    ended? = not is_nil(acc.lastmod)

    {%{
       name: "contacts",
       ok?: ended? or count > 0,
       detail: %{
         count: count,
         expected: acc.expected,
         ended?: ended?,
         lastmod: acc.lastmod,
         sample:
           Enum.map(Enum.take(contacts, 3), fn c ->
             %{name: c.name, public_key: String.slice(c.public_key, 0, 16) <> "…"}
           end)
       },
       frames: frames
     }, state}
  end

  defp run_step(:channels, state, opts) do
    idxs =
      case opts[:channel_idx] do
        i when is_integer(i) and i in 0..7 -> [i]
        _ -> Enum.to_list(0..7)
      end

    # Channels often get no reply — keep per-slot waits short.
    state = %{state | timeout: min(state.timeout, @channel_timeout_ms)}

    {slot_results, state} =
      Enum.map_reduce(idxs, state, fn idx, st ->
        st = drain(st)
        st = write(st, Protocol.get_channel_frame(idx), {:get_channel, idx})

        {frames, st} =
          await_parsed(st, fn
            {:channel_info, %{index: ^idx}} -> true
            {:channel_info, _} -> true
            {:error, :remote} -> true
            {:ok, _} -> true
            _ -> false
          end)

        info =
          Enum.find_value(frames, fn
            %{parsed: {:channel_info, ch}} -> ch
            _ -> nil
          end)

        err? = Enum.any?(frames, &match?(%{parsed: {:error, _}}, &1))

        {%{
           index: idx,
           ok?: not is_nil(info) or err?,
           channel: info,
           error?: err?,
           raw_in: Enum.map(frames, & &1.hex)
         }, st}
      end)

    answered = Enum.count(slot_results, & &1.ok?)

    {%{
       name: "channels",
       ok?: answered > 0,
       detail: %{answered: answered, total: length(idxs), slots: slot_results},
       frames: []
     }, state}
  end

  defp run_step(:set_dry, state, opts) do
    idx = opts[:channel_idx] || 7
    name = opts[:name] || "IsthmusProbe"
    # Use a random secret but restore is caller's problem — default off unless requested.
    secret = :crypto.strong_rand_bytes(16)

    state = drain(state)
    state = write(state, Protocol.set_channel_frame(idx, name, secret), {:set_channel, idx})

    {frames, state} =
      await_parsed(state, fn
        {:ok, _} -> true
        {:error, _} -> true
        _ -> false
      end)

    ok? = Enum.any?(frames, &match?(%{parsed: {:ok, _}}, &1))

    {%{
       name: "set_dry",
       ok?: ok?,
       detail: %{
         index: idx,
         name: name,
         secret_hex: Base.encode16(secret, case: :lower),
         response: Enum.map(frames, & &1.parsed)
       },
       frames: frames
     }, state}
  end

  defp run_step(other, state, _opts) do
    {%{name: to_string(other), ok?: false, detail: :unknown_step, frames: []}, state}
  end

  defp write(state, frame, label) do
    usb = Protocol.encode_usb_frame(frame)
    :ok = Circuits.UART.write(state.uart, usb)
    entry = log_entry(:out, frame, label)
    %{state | log: [entry | state.log]}
  end

  defp drain(state) do
    Process.sleep(@read_idle_ms)
    {chunks, state} = read_available(state, <<>>)
    {frames, _rest} = Protocol.decode_usb_stream(chunks)

    Enum.reduce(frames, state, fn frame, st ->
      %{st | log: [log_entry(:in, frame, Protocol.parse_frame(frame)) | st.log]}
    end)
  end

  defp await_parsed(state, pred) do
    deadline = System.monotonic_time(:millisecond) + state.timeout
    await_parsed_loop(state, pred, deadline, <<>>, [])
  end

  defp await_parsed_loop(state, pred, deadline, buf, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {Enum.reverse(acc), state}
    else
      {chunk, state} = read_available(state, <<>>)
      buf = buf <> chunk
      {frames, rest} = Protocol.decode_usb_stream(buf)

      {acc, state, matched?} =
        Enum.reduce(frames, {acc, state, false}, fn frame, {a, st, matched} ->
          parsed = Protocol.parse_frame(frame)
          entry = log_entry(:in, frame, parsed)
          st = %{st | log: [entry | st.log]}
          a = [entry | a]
          {a, st, matched or pred.(parsed)}
        end)

      cond do
        matched? ->
          # brief settle for trailing bytes
          Process.sleep(@read_idle_ms)
          {more, state} = read_available(state, rest)
          {extra, _} = Protocol.decode_usb_stream(more)

          {acc, state} =
            Enum.reduce(extra, {acc, state}, fn frame, {a, st} ->
              parsed = Protocol.parse_frame(frame)
              entry = log_entry(:in, frame, parsed)
              {[entry | a], %{st | log: [entry | st.log]}}
            end)

          {Enum.reverse(acc), state}

        true ->
          Process.sleep(40)
          await_parsed_loop(state, pred, deadline, rest, acc)
      end
    end
  end

  defp await_until(state, reducer, acc0) do
    deadline = System.monotonic_time(:millisecond) + state.timeout
    await_until_loop(state, reducer, deadline, <<>>, [], acc0)
  end

  defp await_until_loop(state, reducer, deadline, buf, frames, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {Enum.reverse(frames), state, acc}
    else
      {chunk, state} = read_available(state, <<>>)
      buf = buf <> chunk
      {new_frames, rest} = Protocol.decode_usb_stream(buf)

      {frames, state, acc, halt?} =
        Enum.reduce(new_frames, {frames, state, acc, false}, fn frame, {fs, st, a, halt} ->
          if halt do
            {fs, st, a, true}
          else
            parsed = Protocol.parse_frame(frame)
            entry = log_entry(:in, frame, parsed)
            st = %{st | log: [entry | st.log]}
            fs = [entry | fs]

            case reducer.(a, parsed) do
              {:cont, a2} -> {fs, st, a2, false}
              {:halt, a2} -> {fs, st, a2, true}
            end
          end
        end)

      if halt? do
        {Enum.reverse(frames), state, acc}
      else
        Process.sleep(40)
        await_until_loop(state, reducer, deadline, rest, frames, acc)
      end
    end
  end

  defp read_available(state, prefix) do
    case Circuits.UART.read(state.uart, 50) do
      {:ok, <<>>} -> {prefix, state}
      {:ok, data} when is_binary(data) -> {prefix <> data, state}
      {:error, _} -> {prefix, state}
    end
  end

  defp log_entry(:out, frame, label) do
    %{
      dir: :out,
      hex: Base.encode16(frame, case: :lower),
      parsed: label,
      at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp log_entry(:in, frame, parsed) do
    %{
      dir: :in,
      hex: Base.encode16(frame, case: :lower),
      parsed: parsed,
      at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp summarize_device_info(<<fw, rest::binary>>) do
    base = %{fw_ver: fw, raw_len: byte_size(rest) + 1}

    if fw >= 3 and byte_size(rest) >= 78 do
      <<max_contacts_div2, max_channels, ble_pin::little-32, build::binary-12, model::binary-40,
        ver::binary-20, _::binary>> = rest

      Map.merge(base, %{
        max_contacts: max_contacts_div2 * 2,
        max_channels: max_channels,
        ble_pin: ble_pin,
        fw_build: cstr(build),
        model: cstr(model),
        version: cstr(ver)
      })
    else
      Map.put(base, :raw_hex, Base.encode16(<<fw, rest::binary>>, case: :lower))
    end
  end

  defp summarize_device_info(other) when is_binary(other) do
    %{raw_hex: Base.encode16(other, case: :lower)}
  end

  defp cstr(bin) do
    case :binary.split(bin, <<0>>) do
      [s | _] -> String.trim(s)
      _ -> ""
    end
  end

  @doc "Pretty-print a probe result map for Mix.shell."
  def format_report({:error, reason}) do
    ["ERROR: #{inspect(reason)}"]
  end

  def format_report({:ok, result}) do
    lines = [
      "MeshCore companion probe",
      "  port=#{result.port} baud=#{result.baud}",
      ""
    ]

    step_lines =
      Enum.flat_map(result.steps, fn step ->
        status = if step.ok?, do: "OK", else: "FAIL"
        base = ["[#{status}] #{step.name}: #{inspect(step.detail, limit: 40)}"]

        extra =
          case step.detail do
            %{slots: slots} when is_list(slots) ->
              Enum.map(slots, fn s ->
                ch =
                  cond do
                    is_map(s.channel) ->
                      "name=#{inspect(s.channel.name)} empty=#{s.channel.empty?}"

                    s.error? ->
                      "error response"

                    true ->
                      "no response"
                  end

                "    ch#{s.index}: #{if s.ok?, do: "OK", else: "FAIL"} #{ch}"
              end)

            _ ->
              []
          end

        base ++ extra ++ [""]
      end)

    frame_lines =
      ["Raw frames (#{length(result.frames)}):"] ++
        Enum.map(result.frames, fn f ->
          "  #{f.dir} #{f.hex}  => #{inspect(f.parsed, limit: 30)}"
        end)

    lines ++ step_lines ++ frame_lines
  end
end
