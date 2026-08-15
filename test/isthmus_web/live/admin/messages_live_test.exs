defmodule IsthmusWeb.Admin.MessagesLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Messages
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

  test "lists Public channel messages and filters like Adverts", %{conn: conn} do
    {:ok, mc} =
      Messages.record(%{
        kind: "channel",
        network: "meshcore",
        channel_name: "Public",
        sender_name: "Mobby",
        body: "hello from the hill"
      })

    {:ok, mt} =
      Messages.record(%{
        kind: "channel",
        network: "meshtastic",
        channel_name: "Primary",
        from_ref: "aabbccdd",
        body: "trail check-in"
      })

    {:ok, view, html} = live(conn, ~p"/admin/messages")

    assert has_element?(view, "#admin-nav")
    assert has_element?(view, "#admin-nav-ops")
    assert has_element?(view, "#filter-meshcore")
    assert has_element?(view, "#filter-meshtastic")
    assert has_element?(view, "#filter-kind-channel")
    assert has_element?(view, "#group-retention-off")
    assert html =~ "hello from the hill"
    assert html =~ "trail check-in"
    assert has_element?(view, row_sel(mc.id))
    assert has_element?(view, row_sel(mt.id))
    assert has_element?(view, "#{row_sel(mc.id)} [title='Public']", "Public")
    assert has_element?(view, "#{row_sel(mt.id)} [title='Primary']", "Primary")

    view |> element("#filter-meshcore") |> render_click()
    refute has_element?(view, row_sel(mc.id))
    assert has_element?(view, row_sel(mt.id))

    view |> element("#filter-meshcore") |> render_click()
    view |> element("#messages-search-form") |> render_change(%{"q" => "hill"})
    assert has_element?(view, row_sel(mc.id))
    refute has_element?(view, row_sel(mt.id))

    view |> element("#messages-search-clear") |> render_click()
    assert has_element?(view, row_sel(mc.id))
    assert has_element?(view, row_sel(mt.id))
  end

  test "blank Meshtastic channel name shows as Primary, not Kind", %{conn: conn} do
    {:ok, row} =
      Messages.record(%{
        kind: "channel",
        network: "meshtastic",
        channel_idx: 0,
        from_ref: "9eecc24c",
        body: "from the radio"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/messages")

    assert has_element?(view, "#{row_sel(row.id)} [title='Primary']", "Primary")
    refute has_element?(view, "#{row_sel(row.id)} [title='Channel']")
  end

  test "generic Meshtastic name Channel shows as Primary", %{conn: conn} do
    {:ok, row} =
      Messages.record(%{
        kind: "channel",
        network: "meshtastic",
        channel_idx: 0,
        channel_name: "Channel",
        from_ref: "9eecc24c",
        body: "named channel"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/messages")

    assert has_element?(view, "#{row_sel(row.id)} [title='Primary']", "Primary")
    refute has_element?(view, "#{row_sel(row.id)} [title='Channel']")
  end

  test "group messages appear only when retention is enabled", %{conn: conn} do
    {:ok, _} =
      Messages.record(%{
        kind: "group",
        network: "nostr",
        channel_name: "Lobby",
        sender_name: "alice",
        body: "group only text"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/messages")
    assert render(view) =~ "group only text"

    view |> element("#filter-kind-group") |> render_click()
    refute render(view) =~ "group only text"
  end

  defp row_sel(id), do: "#message-#{id}"
end
