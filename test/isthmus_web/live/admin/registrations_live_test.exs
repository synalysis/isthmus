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
  end
end
