defmodule Isthmus.Networks.Meshtastic.BLETransportTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.BLESidecar
  alias Isthmus.Networks.Meshtastic.BLETransport
  alias Isthmus.Networks.Meshtastic.Protocol

  @fake_script Path.expand("../../../support/meshcore_ble_fake.py", __DIR__)
  @sidecar Isthmus.Networks.Meshtastic.BLESidecarFake

  test "requires address" do
    assert {:error, :missing_ble_address} = BLETransport.connect(%{})
  end

  test "fake sidecar connect_profile writes raw ToRadio protobufs" do
    start_supervised!({BLESidecar, name: @sidecar, script: @fake_script})
    await_live(@sidecar)

    BLESidecar.watch("11:22:33:44:55:66", self(), @sidecar)

    assert {:ok, transport} =
             BLETransport.connect(%{
               address: "11:22:33:44:55:66",
               pin: "123456",
               sidecar: @sidecar
             })

    assert transport.type == :ble
    assert_receive {:ble_frame, <<0x0A>>}, 1_000

    frame = Protocol.want_config_frame(123)
    assert :ok = BLETransport.write(transport, Protocol.ble_payload(frame))
    assert :ok = BLETransport.close(transport)
  end

  test "notify is delivered when the watcher used a different address case" do
    sidecar = Isthmus.Networks.Meshtastic.BLESidecarCase
    start_supervised!({BLESidecar, name: sidecar, script: @fake_script})
    await_live(sidecar)

    BLESidecar.watch("aa:bb:cc:dd:ee:ff", self(), sidecar)

    assert {:ok, _transport} =
             BLETransport.connect(%{
               address: "AA:BB:CC:DD:EE:FF",
               pin: "123456",
               sidecar: sidecar
             })

    assert_receive {:ble_frame, <<0x0A>>}, 1_000
  end

  defp await_live(name, tries \\ 40) do
    health = BLESidecar.health(name)

    cond do
      health[:live] == true or health[:status] == :live ->
        :ok

      tries <= 0 ->
        flunk("fake BLE sidecar not live: #{inspect(health)}")

      true ->
        receive do
        after
          25 -> await_live(name, tries - 1)
        end
    end
  end
end
