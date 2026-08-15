defmodule Isthmus.Networks.Meshtastic.Companion.Admin do
  @moduledoc false

  alias Isthmus.Networks.Meshtastic.Companion.Link
  alias Isthmus.Networks.Meshtastic.Companion.Status
  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.Protocol
  alias Isthmus.Networks.Meshtastic.Timezone

  @admin_timeout_ms 4_000
  @admin_timeout_ble_ms 15_000

  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @admin_timeout_ms

  @spec timeout_ms(map() | term()) :: pos_integer()
  def timeout_ms(%{transport_kind: :ble}), do: @admin_timeout_ble_ms
  def timeout_ms(_), do: @admin_timeout_ms

  @spec begin_channel_write(GenServer.from(), map(), map()) ::
          {:reply, term(), map()} | {:noreply, map()}
  def begin_channel_write(_from, %{admin: admin} = state, _channel) when is_map(admin) do
    {:reply, {:error, :busy}, state}
  end

  def begin_channel_write(from, state, channel) do
    idx = channel[:index]

    cond do
      not Link.online?(state) ->
        {:reply, {:error, :not_connected}, state}

      true ->
        case state.my_info do
          %{my_node_num: num} when is_integer(num) and num > 0 and is_integer(idx) ->
            frame = Protocol.get_channel_admin_frame(num, idx)

            reply_after_admin_write(state, frame, %{
              kind: :set_channel,
              from: from,
              channel: channel,
              node_num: num
            })

          _ ->
            {:reply, {:error, :not_ready}, state}
        end
    end
  end

  def maybe_handle_admin(%{admin: %{kind: :set_channel} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_channel_response, _ch, passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        frame = Protocol.set_channel_admin_frame(admin.node_num, admin.channel, passkey)

        case Link.write(state, frame) do
          :ok ->
            channel = Status.channel_map(admin.channel)
            state = Status.put_channel(state, channel) |> Status.persist_channels()
            GenServer.reply(admin.from, {:ok, channel})
            request_config(%{state | admin: nil, sent: state.sent + 1})

          {:error, reason} ->
            GenServer.reply(admin.from, {:error, reason})
            %{state | admin: nil, last_error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  def maybe_handle_admin(%{admin: %{kind: :set_lora} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_config_response, _cfg, passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        frame = Protocol.set_config_lora_admin_frame(admin.node_num, admin.lora, passkey)

        case Link.write(state, frame) do
          :ok ->
            _ = Link.write(state, Protocol.reboot_admin_frame(admin.node_num, 2))
            state = Status.persist_lora(%{state | lora: admin.lora, sent: state.sent + 1})
            Status.broadcast_lora(state)
            GenServer.reply(admin.from, {:ok, admin.lora})
            %{state | admin: nil}

          {:error, reason} ->
            GenServer.reply(admin.from, {:error, reason})
            %{state | admin: nil, last_error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  def maybe_handle_admin(%{admin: %{kind: :set_settings} = admin} = state, pkt) do
    case {admin.step, Protocol.parse_admin_payload(pkt.payload)} do
      {:get_device, {:get_config_response, cfg, passkey}} ->
        apply_device_settings_step(state, admin, cfg, passkey)

      {:get_lora, {:get_config_response, _cfg, passkey}} ->
        apply_lora_settings_step(state, admin, passkey)

      _ ->
        state
    end
  end

  def maybe_handle_admin(%{admin: %{kind: :read_lora} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_config_response, {:lora, lora}, _passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        state =
          Status.persist_lora(%{state | lora: lora, admin: nil, sent: (state[:sent] || 0) + 1})

        Status.broadcast_lora(state)
        maybe_begin_time_sync(state)

      _ ->
        state
    end
  end

  def maybe_handle_admin(%{admin: %{kind: :set_time} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_config_response, cfg, passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        unix = System.os_time(:second)
        frame = Protocol.set_time_admin_frame(admin.node_num, unix, passkey)

        case Link.write(state, frame) do
          :ok ->
            tzdef = apply_device_tzdef(state, admin, cfg, passkey)
            if admin[:from], do: GenServer.reply(admin.from, :ok)

            Status.put_device_time(
              %{state | admin: nil, sent: state.sent + 1, device_tzdef: tzdef},
              unix,
              synced?: true
            )

          {:error, reason} ->
            if admin[:from], do: GenServer.reply(admin.from, {:error, reason})
            %{state | admin: nil, last_error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  def maybe_handle_admin(state, _), do: state

  def begin_time_sync(_from, %{admin: admin} = state, _tz) when is_map(admin) do
    {:reply, {:error, :busy}, state}
  end

  def begin_time_sync(from, state, tz) do
    cond do
      not Link.online?(state) ->
        {:reply, {:error, :not_connected}, state}

      true ->
        case state.my_info do
          %{my_node_num: num} when is_integer(num) and num > 0 ->
            frame = Protocol.get_config_admin_frame(num, :device)

            reply_after_admin_write(state, frame, %{
              kind: :set_time,
              from: from,
              node_num: num,
              tz: tz
            })

          _ ->
            {:reply, {:error, :not_ready}, state}
        end
    end
  end

  def begin_settings_write(from, state, num, settings) do
    {step, type} =
      if settings.device, do: {:get_device, :device}, else: {:get_lora, :lora}

    frame = Protocol.get_config_admin_frame(num, type)

    reply_after_admin_write(state, frame, %{
      kind: :set_settings,
      step: step,
      from: from,
      node_num: num,
      device: settings.device,
      lora: settings.lora
    })
  end

  def apply_device_settings_step(state, admin, cfg, passkey) do
    if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

    base =
      case cfg do
        {:device, %{} = device} -> device
        _ -> DeviceConfig.empty()
      end

    device = DeviceConfig.merge(base, admin.device)
    frame = Protocol.set_config_device_admin_frame(admin.node_num, device, passkey)

    case Link.write(state, frame) do
      :ok ->
        state =
          Status.persist_device(%{
            state
            | device: device,
              sent: state.sent + 1
          })

        Status.broadcast_device(state)
        admin = %{admin | device: device}

        if admin.lora do
          continue_settings(state, admin, :lora)
        else
          finish_settings(state, admin)
        end

      {:error, reason} ->
        GenServer.reply(admin.from, {:error, reason})
        %{state | admin: nil, last_error: inspect(reason)}
    end
  end

  def apply_lora_settings_step(state, admin, passkey) do
    if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

    frame = Protocol.set_config_lora_admin_frame(admin.node_num, admin.lora, passkey)

    case Link.write(state, frame) do
      :ok ->
        state = Status.persist_lora(%{state | lora: admin.lora, sent: state.sent + 1})
        Status.broadcast_lora(state)
        finish_settings(state, admin)

      {:error, reason} ->
        GenServer.reply(admin.from, {:error, reason})
        %{state | admin: nil, last_error: inspect(reason)}
    end
  end

  def continue_settings(state, admin, :lora) do
    frame = Protocol.get_config_admin_frame(admin.node_num, :lora)

    case write_and_arm_admin(state, frame, %{admin | step: :get_lora}) do
      {:ok, state} ->
        state

      {:error, reason} ->
        GenServer.reply(admin.from, {:error, reason})
        %{state | admin: nil, last_error: inspect(reason)}
    end
  end

  def finish_settings(state, admin) do
    _ = Link.write(state, Protocol.reboot_admin_frame(admin.node_num, 2))

    GenServer.reply(admin.from, {:ok, %{device: state.device, lora: state.lora}})
    %{state | admin: nil}
  end

  def maybe_begin_time_sync(state) do
    case begin_time_sync(nil, state, nil) do
      {:noreply, new_state} -> new_state
      {:reply, _, state} -> state
    end
  end

  @doc """
  Ask the radio for LoRa config when the want_config dump left region unset.

  PhoneAPI sends channels before Config.lora. A BLE drain that stalls after the
  channel list leaves the settings dialog on the empty default (Unset / 0).
  """
  def maybe_refresh_lora(state) do
    region = (state[:lora] || %{})[:region] || 0
    num = get_in(state, [:my_info, :my_node_num])

    cond do
      is_integer(region) and region > 0 ->
        state

      is_map(state[:admin]) ->
        state

      not Link.online?(state) ->
        state

      is_integer(num) and num > 0 ->
        begin_read_lora(state, num)

      true ->
        state
    end
  end

  defp begin_read_lora(state, num) do
    frame = Protocol.get_config_admin_frame(num, :lora)

    case write_and_arm_admin(state, frame, %{kind: :read_lora, from: nil, node_num: num}) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp reply_after_admin_write(state, frame, admin) do
    case write_and_arm_admin(state, frame, admin) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  # Arm the wait-for-response timer only after the GATT/UART write returns.
  # Starting it first burns the budget while BLE write-with-response is blocked.
  defp write_and_arm_admin(state, frame, admin) do
    case Link.write(state, frame) do
      :ok ->
        timer = Process.send_after(self(), :admin_timeout, timeout_ms(state))
        {:ok, %{state | admin: Map.put(admin, :timer, timer)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_device_tzdef(state, admin, cfg, passkey) do
    posix = Timezone.posix(admin[:tz])

    device =
      case cfg do
        {:device, %{} = device} -> device
        {:other, _} -> Protocol.empty_device_config()
        _ -> nil
      end

    cond do
      posix == "" ->
        state[:device_tzdef]

      is_nil(device) ->
        state[:device_tzdef]

      device[:tzdef] == posix ->
        posix

      true ->
        frame =
          Protocol.set_config_device_admin_frame(
            admin.node_num,
            Map.put(device, :tzdef, posix),
            passkey
          )

        case Link.write(state, frame) do
          :ok -> posix
          {:error, _} -> state[:device_tzdef]
        end
    end
  end

  def request_config(state) do
    if Link.online?(state) do
      nonce = :rand.uniform(0x7FFF_FFFE) + 1
      if is_reference(state[:config_timer]), do: Process.cancel_timer(state.config_timer)
      timer = Process.send_after(self(), :config_sync_timeout, config_timeout_ms(state))

      state =
        state
        |> Map.put(:config_nonce, nonce)
        |> Map.put(:config_timer, timer)
        |> Map.put(:history_requested, false)
        |> Map.put(:files, [])

      case Link.write(state, Protocol.want_config_frame(nonce)) do
        :ok ->
          %{state | sent: (state[:sent] || 0) + 1}

        {:error, reason} ->
          Process.cancel_timer(timer)
          %{state | last_error: inspect(reason), config_timer: nil}
      end
    else
      state
    end
  end

  defp config_timeout_ms(%{transport_kind: :ble}), do: 30_000
  defp config_timeout_ms(_), do: 15_000

  def normalize_psk(nil), do: :crypto.strong_rand_bytes(16)
  def normalize_psk(<<>>), do: :crypto.strong_rand_bytes(16)

  def normalize_psk(bin) when is_binary(bin) do
    cond do
      byte_size(bin) in [16, 32] ->
        bin

      String.match?(bin, ~r/^[0-9a-fA-F]+$/) and rem(byte_size(bin), 2) == 0 ->
        Protocol.psk_from_hex(bin) || :crypto.strong_rand_bytes(16)

      true ->
        :crypto.strong_rand_bytes(16)
    end
  end
end
