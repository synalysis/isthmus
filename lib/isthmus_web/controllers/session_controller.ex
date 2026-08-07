defmodule IsthmusWeb.SessionController do
  use IsthmusWeb, :controller

  alias Isthmus.Auth
  alias IsthmusWeb.UserAuth

  # Prefer POST so the one-shot token is not logged in Referer/query strings.
  def create(conn, %{"token" => token}) do
    case Auth.consume_login_token(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Signed in as #{user.npub}")
        |> UserAuth.log_in_user(user)
        |> redirect(to: redirect_path(user))

      {:error, _} ->
        conn
        |> put_flash(:error, "Login token invalid or expired.")
        |> redirect(to: ~p"/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  defp redirect_path(%{pubkey_hex: hex}) do
    if Isthmus.Accounts.admin?(hex), do: ~p"/admin", else: ~p"/me"
  end
end
