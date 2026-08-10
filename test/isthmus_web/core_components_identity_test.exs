defmodule IsthmusWeb.CoreComponentsIdentityTest do
  use ExUnit.Case, async: true

  alias Isthmus.Nostr.Bech32
  alias IsthmusWeb.CoreComponents

  test "format_identity_ref encodes nostr hex as npub" do
    raw = :crypto.strong_rand_bytes(32)
    hex = Base.encode16(raw, case: :lower)
    npub = Bech32.encode_npub(raw)

    assert CoreComponents.format_identity_ref("nostr", hex) == npub
    assert CoreComponents.format_identity_ref("nostr", npub) == npub
    assert CoreComponents.format_identity_ref("meshcore", hex) == hex
  end

  test "short_identity_ref keeps npub prefix recognizable" do
    raw = :crypto.strong_rand_bytes(32)
    hex = Base.encode16(raw, case: :lower)
    short = CoreComponents.short_identity_ref("nostr", hex)

    assert String.starts_with?(short, "npub1")
    assert String.contains?(short, "…")
  end
end
