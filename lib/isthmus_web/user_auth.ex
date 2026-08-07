defmodule IsthmusWeb.UserAuth do
  @moduledoc "Session helpers and LiveView on_mount hooks."

  import Plug.Conn
  import Phoenix.Controller
  use IsthmusWeb, :verified_routes

  alias Isthmus.Accounts
  alias Isthmus.Nostr.Bech32

  def log_in_user(conn, %{pubkey_hex: pubkey_hex, npub: npub}) do
    conn
    |> renew_session()
    |> put_session(:current_pubkey_hex, pubkey_hex)
    |> put_session(:current_npub, npub)
  end

  def log_out_user(conn) do
    conn
    |> renew_session()
    |> clear_session()
    |> redirect(to: ~p"/")
  end

  def fetch_current_user(conn, _opts) do
    pubkey = get_session(conn, :current_pubkey_hex)
    npub = get_session(conn, :current_npub)

    user =
      if pubkey do
        %{
          pubkey_hex: pubkey,
          npub: npub || encode_npub(pubkey),
          admin?: Accounts.admin?(pubkey)
        }
      end

    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Please sign in with a Nostr extension.")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def require_admin_user(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && user.admin? do
      conn
    else
      conn
      |> put_flash(:error, "Admin access required.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Please sign in with a Nostr extension.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_admin, _params, session, socket) do
    socket = mount_user(socket, session)
    user = socket.assigns.current_user

    if user && user.admin? do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Admin access required.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  defp mount_user(socket, session) do
    pubkey = session["current_pubkey_hex"]
    npub = session["current_npub"]

    user =
      if pubkey do
        %{
          pubkey_hex: pubkey,
          npub: npub || encode_npub(pubkey),
          admin?: Accounts.admin?(pubkey)
        }
      end

    Phoenix.Component.assign(socket, :current_user, user)
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp encode_npub(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bin} -> Bech32.encode_npub(bin)
      _ -> hex
    end
  end
end
