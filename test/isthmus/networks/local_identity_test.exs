defmodule Isthmus.Networks.LocalIdentityTest do
  use ExUnit.Case, async: false

  alias Isthmus.Networks.LocalIdentity

  test "meshtastic reports unavailable with an explanation" do
    identity = LocalIdentity.for_network("meshtastic")

    assert identity.status == :unavailable
    assert identity.refs == []
    assert identity.note =~ "stub"
  end

  test "unknown networks are unavailable rather than crashing" do
    assert %{status: :unavailable, refs: []} = LocalIdentity.for_network("carrier-pigeon")
  end

  test "accepts atoms as well as strings" do
    assert LocalIdentity.for_network(:meshtastic) == LocalIdentity.for_network("meshtastic")
  end

  test "nostr reports the service pubkey when configured" do
    identity = LocalIdentity.for_network("nostr")

    case Isthmus.Nostr.Crypto.service_pubkey_hex() do
      nil ->
        assert identity.status == :unavailable
        assert identity.hint =~ "ISTHMUS_NOSTR_NSEC"

      hex ->
        assert identity.status == :ok
        assert identity.refs == [hex]
    end
  end

  test "every network returns the same shape" do
    for network <- ~w(reticulum meshcore nostr meshtastic) do
      identity = LocalIdentity.for_network(network)

      assert identity.network == network
      assert identity.status in [:ok, :partial, :pending, :unavailable]
      assert is_list(identity.refs)
      assert Enum.all?(identity.refs, &is_binary/1)
    end
  end

  test "meshcore is pending until the companion reports its key" do
    identity = LocalIdentity.for_network("meshcore")

    # Without a radio attached in test the companion never learns self_info.
    assert identity.status in [:ok, :pending]

    if identity.status == :pending do
      assert identity.refs == []
      assert identity.hint =~ "companion"
    end
  end
end
