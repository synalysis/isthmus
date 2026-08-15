defmodule Isthmus.Networks.MeshCore.BLETransportTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.BLESidecar
  alias Isthmus.Networks.MeshCore.BLETransport
  alias Isthmus.Networks.MeshCore.Companion

  @fake_script Path.expand("../../../support/meshcore_ble_fake.py", __DIR__)
  @sidecar Isthmus.Networks.MeshCore.BLESidecarFake

  test "requires address" do
    assert {:error, :missing_ble_address} = BLETransport.connect(%{})
  end

  test "connect without a radio returns a sidecar error, not a stub atom" do
    assert {:error, reason} = BLETransport.connect(%{address: "AA:BB:CC:DD:EE:FF"})
    refute reason == {:ble_not_implemented, "AA:BB:CC:DD:EE:FF"}
  end

  test "ble_key prefixes bleak addresses" do
    assert Companion.ble_key("AA:BB") == "ble:AA:BB"
    assert Companion.ble_key("ble:AA:BB") == "ble:AA:BB"
    assert Companion.ble_key("aa:bb") == "ble:AA:BB"
    assert Companion.ble_address("ble:AA:BB") == "AA:BB"
    assert Companion.same_ble_address?("aa:bb", "ble:AA:BB")
  end

  test "sidecar health is a map" do
    health = BLESidecar.health()
    assert is_map(health)
    assert health[:status] in [:starting, :online, :live, :stub, :crashed, :not_started]
  end

  test "fake sidecar IPC covers scan, connect, write, and notify" do
    start_supervised!({BLESidecar, name: @sidecar, script: @fake_script})
    await_live(@sidecar)

    assert {:ok, status} = BLESidecar.adapter_status(@sidecar)
    assert status["discovering"] == false or status[:discovering] == false

    assert {:ok, devices} = BLESidecar.scan(500, @sidecar)
    meshcore = Enum.find(devices, &(&1.address == "AA:BB:CC:DD:EE:FF"))
    meshtastic = Enum.find(devices, &(&1.address == "11:22:33:44:55:66"))
    assert meshcore.name == "MeshCore-1"
    assert meshcore.kind == :meshcore
    assert meshtastic.name == "Meshtastic_Andreas"
    assert meshtastic.kind == :meshtastic

    BLESidecar.watch("AA:BB:CC:DD:EE:FF", self(), @sidecar)

    assert {:ok, transport} =
             BLETransport.connect(%{
               address: "AA:BB:CC:DD:EE:FF",
               pin: "123456",
               sidecar: @sidecar
             })

    assert transport.type == :ble
    assert_receive {:ble_frame, <<0x0A>>}, 1_000
    assert :ok = BLETransport.write(transport, <<0x16, 3>>)
    assert :ok = BLETransport.close(transport)
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
