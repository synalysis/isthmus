defmodule IsthmusWeb.Admin.NostrLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Networks.Nostr.ServiceInbox
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

    ServiceInbox.clear()
    %{conn: conn}
  end

  test "shows service inbox and clarifies no group matching", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/nostr")

    assert has_element?(view, "#service-identity-card")
    assert has_element?(view, "#service-inbox-card")
    assert has_element?(view, "#service-inbox-empty")
    refute html =~ "users DM this key to reach"
    assert html =~ "proxy"
  end

  test "lists retained service DMs", %{conn: conn} do
    ServiceInbox.record(%{
      from_ref: String.duplicate("ab", 32),
      body: "operator note",
      external_id: "live-svc-1"
    })

    {:ok, view, _html} = live(conn, ~p"/admin/nostr")

    assert has_element?(view, "#service-inbox-list")
    assert render(view) =~ "operator note"
  end
end
