defmodule Isthmus.Tunnel.Outbox.ClassTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Tunnel.Outbox.Class

  test "control announce JSON is ephemeral" do
    payload =
      Jason.encode!(%{
        "v" => 1,
        "op" => "announce",
        "network" => "meshcore",
        "ref" => "abc"
      })

    assert Class.classify(payload, %{"kind" => "control"}) == :ephemeral
  end

  test "control without announce op is still ephemeral" do
    assert Class.classify(<<"not-json">>, %{"kind" => "control"}) == :ephemeral
  end

  test "MeshCore advert and path packets are ephemeral" do
    advert =
      Packet.encode(Packet.build(Packet.route_flood(), Packet.type_advert(), 0, <<>>, <<"x">>))

    path = Packet.encode(Packet.build(Packet.route_flood(), Packet.type_path(), 0, <<>>, <<"y">>))

    assert Class.classify(advert) == :ephemeral
    assert Class.classify(path) == :ephemeral
  end

  test "MeshCore text and opaque bytes are durable" do
    txt =
      Packet.encode(Packet.build(Packet.route_direct(), Packet.type_txt_msg(), 0, <<>>, <<"hi">>))

    assert Class.classify(txt) == :durable
    assert Class.classify(<<"hello opaque">>, %{}) == :durable
  end

  test "meta class override is honoured by ephemeral?" do
    assert Class.ephemeral?(%{"class" => "ephemeral"}, <<"anything">>)
    refute Class.ephemeral?(%{"class" => "durable"}, <<"anything">>)
  end
end
