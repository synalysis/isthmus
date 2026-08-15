defmodule Isthmus.Networks.Meshtastic.MessageStoreTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Messages
  alias Isthmus.Networks.Meshtastic.Companion.Inbound
  alias Isthmus.Networks.Meshtastic.MessageStore
  alias Isthmus.Networks.Meshtastic.Protocol

  test "parse reads packed on-device chat records" do
    blob = store_blob(0x9EEC_C24C, 0, 1_700_000_500, "camp check")
    assert [row] = MessageStore.parse(blob)
    assert row.type == :broadcast
    assert row.channel_idx == 0
    assert row.sender == 0x9EEC_C24C
    assert row.body == "camp check"
    assert row.timestamp == 1_700_000_500
  end

  test "empty or truncated files yield no rows" do
    assert MessageStore.parse(<<>>) == []
    assert MessageStore.parse(<<5, 1, 2, 3>>) == []
  end

  test "EOT after an XModem chunk records channel broadcasts even off Primary" do
    blob = store_blob(0x9EEC_C24C, 3, 1_700_000_600, "held on 9eecc24c")

    state = %{
      uart: :test,
      my_info: %{my_node_num: 1, node_id: "9eecc24c"},
      port: "/dev/ttyTEST",
      xmodem: %{filename: MessageStore.filename(), acc: blob, seq: 1}
    }

    payload = Protocol.parse_xmodem(xmodem_inner(Protocol.xmodem_eot()))
    _ = Inbound.handle_payload(state, encode_fromradio_xmodem(Protocol.xmodem_eot()))
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)

    assert payload.control == Protocol.xmodem_eot()

    assert Enum.any?(Messages.list_recent(20), fn row ->
             row.network == "meshtastic" and row.body == "held on 9eecc24c" and
               row.from_ref == "9eecc24c" and row.channel_idx == 3
           end)
  end

  test "NAK retries the next Messages_ filename" do
    state = %{
      uart: :test,
      history_requested: true,
      xmodem: %{
        filename: "/Messages_default.msgs",
        candidates: ["Messages_default.msgs"],
        acc: <<>>,
        seq: 0
      }
    }

    state = Inbound.handle_payload(state, encode_fromradio_xmodem(Protocol.xmodem_nak()))
    assert state.xmodem.filename == "Messages_default.msgs"
    assert state.history_requested
    flush_xmodem_mail()
  end

  test "device reboot clears a one-shot pull so the next handshake retries" do
    state = %{
      uart: nil,
      history_requested: true,
      files: [%{name: "/Messages_default.msgs", size: 100}],
      xmodem: %{filename: "/Messages_default.msgs", acc: <<>>, seq: 0}
    }

    state = Inbound.handle_payload(state, encode_rebooted())
    assert state.history_requested == false
    assert state.files == []
    assert state.xmodem == nil
  end

  test "request_message_store starts with the flash filename" do
    state = Inbound.request_message_store(%{uart: :test, files: []})
    assert state.xmodem.filename == MessageStore.filename()
    assert "Messages_default.msgs" in state.xmodem.candidates
    assert state.history_requested
    flush_xmodem_mail()
  end

  defp store_blob(sender, channel, ts, body) do
    text = String.pad_trailing(body, 220, <<0>>)

    rec =
      <<ts::little-32, sender::little-32, channel, 0xFFFF_FFFF::little-32, 0, 0, 0,
        byte_size(body)::little-16, text::binary>>

    <<1, rec::binary>>
  end

  defp xmodem_inner(control) do
    Isthmus.Networks.Meshtastic.Protobuf.encode_varint_field(1, control)
  end

  defp encode_fromradio_xmodem(control) do
    Isthmus.Networks.Meshtastic.Protobuf.encode_message_field(12, xmodem_inner(control))
  end

  defp encode_rebooted do
    Isthmus.Networks.Meshtastic.Protobuf.encode_varint_field(8, 1)
  end

  defp flush_xmodem_mail do
    receive do
      :xmodem_timeout -> flush_xmodem_mail()
      :pull_message_store -> flush_xmodem_mail()
    after
      0 -> :ok
    end
  end
end
