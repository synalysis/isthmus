defmodule Isthmus.Networks.MeshCore.BridgeLink do
  @moduledoc """
  Serial link to a bridge-enabled MeshCore repeater.

  This is what lets MeshCore be a tunnel *payload*. The companion protocol only
  surfaces traffic addressed to us, but a repeater built with `WITH_RS232_BRIDGE`
  streams every packet it relays as `BridgeFrame` frames, and accepts frames back
  to transmit on its island. Joining two of those over a tunnel merges the two
  islands into one mesh.

  Port comes from auto-detect (`Discover`) or `ISTHMUS_MESHCORE_BRIDGE_PORT`.
  Left unset / undetected the process still starts but stays `:disabled`.

  Note this is a *different* serial port from the companion and from the
  repeater CLI. With the USB CDC bridge firmware a single repeater presents
  two ports: the CLI console and this packet stream.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.MeshCore.BridgeFrame
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.USBTransport
  alias Isthmus.Tunnel

  @status_table :isthmus_meshcore_bridge_status
  @payload_network "meshcore"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Non-blocking health snapshot (ETS-backed)."
  def health(name \\ __MODULE__) do
    # Never create the table here: it must stay owned by the GenServer, or a
    # short-lived reader would take ownership and take it down with it.
    with table when table != :undefined <- :ets.whereis(@status_table),
         [{{:health, ^name}, health}] <- :ets.lookup(table, {:health, name}) do
      health
    else
      _ ->
        safe_call(name, :health, %{status: :unknown, last_error: "bridge link not started"}, 500)
    end
  end

  @doc "True when a bridge port is configured, regardless of link state."
  def configured?(name \\ __MODULE__), do: health(name)[:status] != :disabled

  @doc """
  Transmit a raw mesh packet on the attached island.

  Used for tunnel-delivered payloads. The packet is marked as bridged first so
  an echo from the radio isn't sent back down the tunnel.
  """
  def inject(name \\ __MODULE__, packet)

  def inject(name, packet) when is_binary(packet) and byte_size(packet) > 0 do
    safe_call(name, {:inject, packet}, {:error, :bridge_not_started}, 5_000)
  end

  def inject(_name, _packet), do: {:error, :invalid_packet}

  @doc "Re-resolve the packet port (after Discover.refresh) and reconnect."
  def reconnect(name \\ __MODULE__), do: GenServer.cast(name, :reconnect)

  @doc "Release the packet UART so Discover can re-probe the port."
  def disconnect(name \\ __MODULE__), do: safe_call(name, :disconnect, :ok, 2_000)

  defp safe_call(name, request, fallback, timeout) do
    GenServer.call(name, request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    ensure_ets(@status_table)

    port =
      Keyword.get(opts, :port) || Discover.resolve_port(:bridge_packet)

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      transport_mod: Keyword.get(opts, :transport_mod, USBTransport),
      transport: nil,
      port: port,
      transport_opts: Keyword.get(opts, :transport_opts, %{}),
      forward: Keyword.get(opts, :forward, &__MODULE__.default_forward/1),
      buffer: <<>>,
      status: :disconnected,
      last_error: nil,
      fail_count: 0,
      stats: %{
        frames_in: 0,
        frames_out: 0,
        checksum_errors: 0,
        dropped_bytes: 0,
        last_rx_at: nil,
        last_tx_at: nil
      }
    }

    {:ok, maybe_connect(state)}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    if stay_connected?(state) do
      {:noreply, state}
    else
      if state.transport, do: state.transport_mod.close(state.transport)

      state = %{
        state
        | transport: nil,
          buffer: <<>>,
          status: :disconnected,
          port: Discover.resolve_port(:bridge_packet)
      }

      {:noreply, maybe_connect(state)}
    end
  end

  defp stay_connected?(state) do
    state[:status] == :online and not is_nil(state[:transport]) and
      Discover.resolve_port(:bridge_packet) == state[:port]
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, health_map(state), publish_status(state)}
  end

  def handle_call(:disconnect, _from, state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    {:reply, :ok,
     publish_status(%{
       state
       | transport: nil,
         buffer: <<>>,
         status: :disconnected,
         last_error: "released for rediscovery"
     })}
  end

  def handle_call({:inject, packet}, _from, %{status: :online, transport: t} = state)
      when not is_nil(t) do
    case BridgeFrame.encode(packet) do
      {:ok, frame} ->
        # Suppress the echo before it can reach us. `:duplicate` means a tunnel
        # (or earlier inject) already marked this packet — still safe to TX.
        _ = Tunnel.Bridge.mark_forwarded(packet)

        case state.transport_mod.write(t, frame) do
          :ok ->
            state =
              state
              |> bump(:frames_out)
              |> touch(:last_tx_at)
              |> publish_status()

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, publish_status(%{state | last_error: inspect(reason)})}
        end

      {:error, :invalid_length} ->
        Logger.warning(
          "bridge inject rejected: #{byte_size(packet)} bytes exceeds MeshCore packet limit"
        )

        {:reply, {:error, :invalid_length}, state}
    end
  end

  def handle_call({:inject, _packet}, _from, %{status: :disabled} = state) do
    {:reply, {:error, :bridge_disabled}, state}
  end

  def handle_call({:inject, _packet}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {packets, rest, frame_stats} = BridgeFrame.decode(state.buffer <> data)

    Enum.each(packets, state.forward)

    if frame_stats.checksum_errors > 0 do
      Logger.debug(
        "meshcore bridge: #{frame_stats.checksum_errors} frame(s) failed checksum, resynced"
      )
    end

    state =
      state
      |> Map.put(:buffer, rest)
      |> merge_frame_stats(frame_stats, length(packets))
      |> then(fn s -> if packets == [], do: s, else: touch(s, :last_rx_at) end)
      |> publish_status()

    {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("meshcore bridge serial error: #{inspect(reason)}")
    if state.transport, do: state.transport_mod.close(state.transport)
    Process.send_after(self(), :reconnect, 5_000)

    state =
      publish_status(%{
        state
        | transport: nil,
          buffer: <<>>,
          status: :error,
          last_error: inspect(reason)
      })

    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    state =
      maybe_connect(%{
        state
        | transport: nil,
          buffer: <<>>,
          status: :disconnected,
          port: Discover.resolve_port(:bridge_packet)
      })

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def default_forward(packet) do
    # Fan out to synthetic identities before (and beside) tunnel forward.
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshcore:bridge_rx",
      {:bridge_packet, packet}
    )

    Tunnel.Bridge.forward_packet(@payload_network, packet, %{source: "bridge"})
  end

  defp maybe_connect(%{port: port} = state) when port in [nil, ""] do
    publish_status(%{
      state
      | status: :disabled,
        last_error:
          "no bridge packet port detected (set ISTHMUS_MESHCORE_BRIDGE_PORT to override)"
    })
  end

  defp maybe_connect(state) do
    case state.transport_mod.connect(Map.put(state.transport_opts, :port, state.port)) do
      {:ok, transport} ->
        Logger.info("MeshCore bridge link online via #{state.port}")

        publish_status(%{
          state
          | transport: transport,
            status: :online,
            last_error: nil,
            fail_count: 0
        })

      {:error, reason} ->
        delay = reconnect_delay(reason, state)
        log_connect_failure(reason, delay)
        Process.send_after(self(), :reconnect, delay)

        publish_status(%{
          state
          | status: :error,
            last_error: inspect(reason),
            fail_count: state.fail_count + 1
        })
    end
  end

  defp reconnect_delay(reason, state) do
    base = if reason == :eacces, do: 30_000, else: 5_000
    min(120_000, base * max(1, state.fail_count + 1))
  end

  defp log_connect_failure(:eacces, delay) do
    Logger.warning(
      "MeshCore bridge connect failed: permission denied (:eacces). " <>
        "Add your user to the `dialout` group, then retry in #{div(delay, 1000)}s."
    )
  end

  defp log_connect_failure(reason, delay) do
    Logger.warning(
      "MeshCore bridge connect failed: #{inspect(reason)} (retry in #{div(delay, 1000)}s)"
    )
  end

  defp merge_frame_stats(state, frame_stats, packet_count) do
    stats =
      state.stats
      |> Map.update!(:frames_in, &(&1 + packet_count))
      |> Map.update!(:checksum_errors, &(&1 + frame_stats.checksum_errors))
      |> Map.update!(:dropped_bytes, &(&1 + frame_stats.dropped_bytes))

    %{state | stats: stats}
  end

  defp bump(state, key), do: %{state | stats: Map.update!(state.stats, key, &(&1 + 1))}

  defp touch(state, key),
    do: %{state | stats: Map.put(state.stats, key, DateTime.utc_now())}

  defp health_map(state) do
    Map.merge(state.stats, %{
      status: state.status,
      port: state.port,
      last_error: state.last_error,
      buffered_bytes: byte_size(state.buffer)
    })
  end

  defp publish_status(state) do
    health = health_map(state)
    :ets.insert(@status_table, {{:health, state.name}, health})
    key = {health[:status], health[:port]}

    if state[:pub_key] != key do
      broadcast_status(:bridge_link, health)
    end

    Map.put(state, :pub_key, key)
  end

  defp broadcast_status(kind, health) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshcore:status",
      {:meshcore_status, kind, health}
    )
  catch
    :error, _ -> :ok
    :exit, _ -> :ok
  end

  defp ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end
end
