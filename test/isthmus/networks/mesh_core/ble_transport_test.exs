defmodule Isthmus.Networks.MeshCore.BLETransportTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.BLETransport

  test "requires address" do
    assert {:error, :missing_ble_address} = BLETransport.connect(%{})
  end

  test "returns not implemented when address set" do
    assert {:error, {:ble_not_implemented, "AA:BB"}} =
             BLETransport.connect(%{address: "AA:BB"})
  end
end
