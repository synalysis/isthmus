defmodule IsthmusWeb.Admin.RegistrationsLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Announce.Sightings
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Registrations

  setup %{conn: conn} do
    raw = :crypto.strong_rand_bytes(32)
    pubkey = Base.encode16(raw, case: :lower)
    npub = Bech32.encode_npub(raw)
    {:ok, _} = Accounts.add_admin(%{pubkey_hex: pubkey, npub: npub, label: "test"})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> IsthmusWeb.UserAuth.log_in_user(%{pubkey_hex: pubkey, npub: npub})

    {:ok, group} =
      Registrations.create_bridge_group(pubkey, %{display_name: "Camp", created_by: "admin"})

    %{conn: conn, group: group}
  end

  test "new group modal opens on toolbar click", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/registrations")

    refute has_element?(view, "#new-group-modal")
    view |> element("button", "New group") |> render_click()
    assert has_element?(view, "#new-group-modal #bridge-create-form")
  end

  test "attach member modal opens for a group and lists heard reticulum addresses",
       %{conn: conn, group: group} do
    ref = String.duplicate("ab", 16)

    {:ok, _} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: ref,
        meta: %{"name" => "Alice"}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/registrations")

    view
    |> element("#group-#{group.id} button[phx-click='open_attach']")
    |> render_click()

    assert has_element?(view, "#attach-member-modal #bridge-attach-form")
    assert has_element?(view, "#bridge-attach-form option[value='agent']")

    # Switch the network to reticulum; the heard address should be suggested.
    view
    |> element("#bridge-attach-form")
    |> render_change(%{"network" => "reticulum", "identity" => ""})

    assert has_element?(view, "#suggestion-#{ref}")

    # Clicking the suggestion fills the identity field with the full ref.
    view |> element("#suggestion-#{ref} button") |> render_click()
    assert has_element?(view, "#bridge-attach-form input[name='identity'][value='#{ref}']")
  end

  test "revoked groups are hidden by default and can be shown", %{conn: conn, group: group} do
    {:ok, _} = Registrations.revoke(group)
    {:ok, view, _html} = live(conn, ~p"/admin/registrations")

    refute has_element?(view, "#group-#{group.id}")
    assert has_element?(view, "#toggle-show-revoked", "Show revoked")

    view |> element("#toggle-show-revoked") |> render_click()

    assert has_element?(view, "#group-#{group.id}")
    assert has_element?(view, "#toggle-show-revoked", "Hide revoked")
  end

  test "manage opens the selected group's members", %{conn: conn, group: group} do
    {:ok, view, _html} = live(conn, ~p"/admin/registrations")

    refute has_element?(view, "#manage-group-modal")
    refute has_element?(view, "#bridge-members-table")

    view |> element("#manage-group-#{group.id}") |> render_click()

    assert has_element?(view, "#manage-group-modal")
    assert has_element?(view, "#bridge-members-table")
    assert has_element?(view, "#manage-group-modal", "Camp")
    assert has_element?(view, "#toggle-store-messages-#{group.id}", "Group messages not stored")

    view |> element("#toggle-store-messages-#{group.id}") |> render_click()
    assert has_element?(view, "#toggle-store-messages-#{group.id}", "Storing group messages")
    assert Registrations.get_group!(group.id).store_messages
  end

  test "attaching a reticulum member closes the modal and lists the member",
       %{conn: conn, group: group} do
    ref = String.duplicate("cd", 16)
    {:ok, view, _html} = live(conn, ~p"/admin/registrations")

    view
    |> element("#group-#{group.id} button[phx-click='open_attach']")
    |> render_click()

    view
    |> form("#bridge-attach-form", %{"network" => "reticulum", "identity" => ref})
    |> render_submit()

    refute has_element?(view, "#attach-member-modal")
    assert render(view) =~ "Member attached."
    assert has_element?(view, "#manage-group-modal #bridge-members-table", "external")
  end

  test "minted Nostr proxy is labelled proxy, attached Reticulum is external",
       %{conn: conn, group: group} do
    ref = String.duplicate("ef", 16)
    assert {:ok, group} = Registrations.attach_member(group, "reticulum", ref)
    assert {:ok, group} = Registrations.ensure_nostr_proxy(group)

    nostr = Enum.find(group.legs, &(&1.network == "nostr" and &1.role == "proxy"))
    rns = Enum.find(group.legs, &(&1.network == "reticulum" and &1.role == "member"))
    assert nostr
    assert rns

    {:ok, view, _html} = live(conn, ~p"/admin/registrations")
    view |> element("#manage-group-#{group.id}") |> render_click()

    assert has_element?(view, "#member-#{nostr.id}-role", "proxy")
    assert has_element?(view, "#member-#{rns.id}-role", "external")
  end

  test "radio channels show as legs, not a separate MC ch column", %{conn: conn, group: group} do
    psk = String.duplicate("ab", 16)
    assert {:ok, _} = Registrations.link_meshcore_channel(group, 2, psk)
    assert {:ok, _} = Registrations.link_meshtastic_channel(group, 3, psk)

    {:ok, view, html} = live(conn, ~p"/admin/registrations")

    refute html =~ "MC ch"
    assert has_element?(view, "#group-#{group.id}-chip-meshcore-ch", "meshcore/ch 2")
    assert has_element?(view, "#group-#{group.id}-chip-meshtastic-ch", "meshtastic/ch 3")

    view |> element("#manage-group-#{group.id}") |> render_click()

    group = Registrations.get_group!(group.id)
    mc = Enum.find(group.radio_channels, &(&1.network == "meshcore"))
    mt = Enum.find(group.radio_channels, &(&1.network == "meshtastic"))
    assert mc
    assert mt
    assert has_element?(view, "#member-channel-#{mc.id}", "channel slot 2")
    assert has_element?(view, "#member-channel-#{mt.id}", "channel slot 3")
  end

  test "send message modal injects into the selected group", %{conn: conn, group: group} do
    mc = String.duplicate("aa", 32)
    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)

    {:ok, view, _html} = live(conn, ~p"/admin/registrations")

    refute has_element?(view, "#inject-message-modal")
    view |> element("#inject-group-#{group.id}") |> render_click()

    assert has_element?(view, "#inject-message-modal #group-inject-form")
    assert has_element?(view, "#inject-message-modal", "Camp")

    view
    |> form("#group-inject-form", %{"body" => "hello from admin"})
    |> render_submit()

    assert render(view) =~ "Sent to Camp."
    _ = :sys.get_state(Isthmus.Gateway.Translator)

    assert Enum.any?(Isthmus.Gateway.list_forward_log(20), fn log ->
             log.registration_group_id == group.id and log.from_network == "admin" and
               log.to_network == "meshcore"
           end)
  end

  test "send message modal rejects an empty body", %{conn: conn, group: group} do
    {:ok, view, _html} = live(conn, ~p"/admin/registrations")
    view |> element("#inject-group-#{group.id}") |> render_click()

    view
    |> form("#group-inject-form", %{"body" => "   "})
    |> render_submit()

    assert render(view) =~ "Message is empty."
    assert has_element?(view, "#inject-message-modal")
  end
end
