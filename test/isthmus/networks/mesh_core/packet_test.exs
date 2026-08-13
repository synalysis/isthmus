defmodule Isthmus.Networks.MeshCore.PacketTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Packet

  test "hop_count reads the low 6 bits of path_len" do
    assert Packet.hop_count(0) == 0
    assert Packet.hop_count(Packet.encode_path_len(3)) == 3
    assert Packet.hop_count(Packet.encode_path_len(3, 2)) == 3
  end
end
