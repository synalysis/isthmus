defmodule Isthmus.Networks.MeshCore.FakeCompanionTransport do
  @moduledoc false

  @behaviour Isthmus.Networks.MeshCore.Transport

  @impl true
  def connect(_opts) do
    reply = Application.get_env(:isthmus, :fake_companion_reply, <<0>>)
    {:ok, %{type: :usb, reply: reply}}
  end

  @impl true
  def write(state, data) do
    if command_byte(data) in [11, 12] do
      send(self(), {:circuits_uart, "fake", usb_reply(state.reply)})
    end

    :ok
  end

  @impl true
  def close(_state), do: :ok

  @impl true
  def info(_state), do: %{type: :usb, status: :connected}

  defp command_byte(<<"<", _len::little-16, cmd, _::binary>>), do: cmd
  defp command_byte(_), do: nil

  defp usb_reply(frame) when is_binary(frame) do
    <<">", byte_size(frame)::little-16, frame::binary>>
  end
end
