defmodule IsthmusWeb.Admin.AgentLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Networks.Agent.Settings
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Policy

  setup %{conn: conn} do
    previous = Application.get_env(:isthmus, Isthmus.Networks.Agent)

    on_exit(fn ->
      Application.put_env(:isthmus, Isthmus.Networks.Agent, previous)
    end)

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

  test "ACP settings page shows the spawn form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/agent")

    assert has_element?(view, "#acp-status")
    assert has_element?(view, "#acp-settings-form")
    assert has_element?(view, "#acp-apply")
    html = render(view)
    assert html =~ "gemini --acp"
    assert html =~ "opencode acp"
    assert html =~ "goose acp"
  end

  test "applying the Hermes preset saves command and reconnects", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/agent")

    view
    |> form("#acp-settings-form", %{
      "acp" => %{"preset" => "hermes", "enabled" => "false", "cwd" => ""}
    })
    |> render_submit()

    assert Policy.get("acp_command") == "hermes acp"
    assert Settings.current().command == "hermes acp"
    assert render(view) =~ "hermes acp"
  end
end
