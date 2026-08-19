defmodule IsthmusWeb.LoginLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Auth

  on_mount {IsthmusWeb.UserAuth, :mount_current_user}

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/me")}
    else
      challenge = Auth.create_challenge("isthmus")

      {:ok,
       socket
       |> assign(:page_title, "Sign in")
       |> assign(:challenge, challenge)
       |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("nostr_signed", %{"event" => event}, socket) do
    case Auth.verify_signed_event(event) do
      {:ok, %{token: token}} ->
        # Hand token to JS for a CSRF-protected POST (avoids token-in-URL).
        {:noreply, push_event(socket, "nostr_login_token", %{token: token})}

      {:error, reason} ->
        challenge = Auth.create_challenge("isthmus")

        {:noreply,
         socket
         |> assign(:challenge, challenge)
         |> assign(:error, "Sign-in failed: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh_challenge", _params, socket) do
    {:noreply, assign(socket, :challenge, Auth.create_challenge("isthmus"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="max-w-xl space-y-6">
        <div>
          <h1 class="text-3xl font-semibold">Sign in</h1>
          <p class="mt-2 text-base-content/70">
            Use a NIP-07 Nostr browser extension (Alby, nos2x, AKA Profiles, …).
            Admin ops require an allowlisted npub. Extensions inject
            <code class="text-sm">window.nostr</code>
            only on HTTPS or localhost — a LAN <code class="text-sm">http://</code>
            origin will not see a signer.
          </p>
        </div>

        <div
          id="nostr-login"
          phx-hook="NostrLogin"
          data-challenge={@challenge.message}
          class="card bg-base-200 border border-base-300"
        >
          <div class="card-body space-y-4">
            <p class="text-sm font-mono break-all opacity-70">{@challenge.message}</p>
            <button type="button" class="btn btn-primary" data-nostr-login>
              Sign with Nostr extension
            </button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="refresh_challenge">
              Refresh challenge
            </button>
            <form id="nostr-session-form" action={~p"/session"} method="post" class="hidden">
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="token" id="nostr-session-token" value="" />
            </form>
            <p :if={@error} class="text-error text-sm">{@error}</p>
            <p id="nostr-login-status" class="text-sm text-base-content/60"></p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
