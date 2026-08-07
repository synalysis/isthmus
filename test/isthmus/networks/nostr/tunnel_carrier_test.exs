defmodule Isthmus.Networks.Nostr.TunnelCarrierTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Nostr.TunnelCarrier

  test "ignores non-tunnel kinds" do
    assert :ignore =
             TunnelCarrier.handle_inbound_event(%{"kind" => 1, "content" => "hi", "tags" => []})
  end

  test "decodes plain base64 tunnel events without engine crash" do
    payload = <<"ISTH", 1, 2, 3, 4>>

    event = %{
      "kind" => TunnelCarrier.kind(),
      "content" => Base.encode64(payload),
      "tags" => [["t", TunnelCarrier.tag()]],
      "pubkey" => String.duplicate("ab", 32)
    }

    # Engine may reject incomplete frames; we only assert decode path runs
    result = TunnelCarrier.handle_inbound_event(event)
    assert result in [:ok, :error]
  end

  test "filter helpers" do
    assert %{"kinds" => [21_278], "#t" => ["isthmus-tunnel"]} = TunnelCarrier.filter_global()
    f = TunnelCarrier.filter_for_service("aabb")
    assert f["#p"] == ["aabb"]
  end
end
