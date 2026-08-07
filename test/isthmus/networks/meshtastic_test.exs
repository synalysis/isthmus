defmodule Isthmus.Networks.MeshtasticTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic

  test "parses node ids" do
    assert {:ok, "deadbeef", _} = Meshtastic.parse_identity_ref("deadbeef")
    assert {:ok, "deadbeef", _} = Meshtastic.parse_identity_ref("!deadbeef")
  end

  test "generates stub proxy identity" do
    assert {:ok, id} = Meshtastic.generate_proxy_identity(%{name: "Test"})
    assert byte_size(id.identity_ref) == 8
    assert [%{format_id: "meshtastic_node"} | _] = id.presentations
  end

  test "registered in Networks" do
    assert :meshtastic in Isthmus.Networks.list_adapters()
    assert %{status: :stub} = Isthmus.Networks.adapter!(:meshtastic).health()
  end
end
