defmodule IsthmusWeb.Admin.MeshtasticLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Nostr.Bech32

  setup %{conn: conn} do
    raw = :crypto.strong_rand_bytes(32)
    pubkey = Base.encode16(raw, case: :lower)
    npub = Bech32.encode_npub(raw)
    {:ok, _} = Accounts.add_admin(%{pubkey_hex: pubkey, npub: npub, label: "test"})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> IsthmusWeb.UserAuth.log_in_user(%{pubkey_hex: pubkey, npub: npub})

    %{conn: conn}
  end

  test "renders companion and groups-channels sections", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/meshtastic")

    assert has_element?(view, "#companion-status")
    assert has_element?(view, "#groups-channels")
    assert has_element?(view, "#companion-setup-card")
    assert has_element?(view, "#reconnect-meshtastic-btn")
    assert has_element?(view, "#rescan-meshtastic-btn")
    refute has_element?(view, "#meshtastic-lora-form")
    assert html =~ "auto-detected"
  end
end
