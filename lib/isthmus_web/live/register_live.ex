defmodule IsthmusWeb.RegisterLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Policy
  alias Isthmus.Registrations

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    existing = Registrations.active_registration_for_owner(user.pubkey_hex)

    {:ok,
     socket
     |> assign(:page_title, "Register")
     |> assign(:registration_open, Policy.registration_open?())
     |> assign(:existing, existing)
     |> assign(:primary, "nostr")
     |> assign(:display_name, "")
     |> assign(:identity_input, "")
     |> assign(
       :form,
       to_form(%{"display_name" => "", "identity_input" => "", "primary" => "nostr"})
     )}
  end

  @impl true
  def handle_event("validate", params, socket) do
    primary = params["primary"] || "nostr"

    {:noreply,
     socket
     |> assign(:primary, primary)
     |> assign(:form, to_form(params))}
  end

  def handle_event("register", params, socket) do
    user = socket.assigns.current_user
    primary = params["primary"] || "nostr"
    name = String.trim(params["display_name"] || "")
    input = String.trim(params["identity_input"] || "")
    attrs = %{display_name: name}

    result =
      case primary do
        "nostr" ->
          Registrations.register_self(user.pubkey_hex, attrs)

        "meshcore" ->
          Registrations.register_meshcore_primary(user.pubkey_hex, input, attrs)

        "reticulum" ->
          Registrations.register_reticulum_primary(user.pubkey_hex, input, attrs)

        _ ->
          {:error, :unknown_primary}
      end

    case result do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, success_flash(primary))
         |> push_navigate(to: ~p"/me")}

      {:error, :registration_closed} ->
        {:noreply, put_flash(socket, :error, "Registration is currently closed.")}

      {:error, {:already_registered, _group}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Already registered.")
         |> push_navigate(to: ~p"/me")}

      {:error, :identity_already_linked} ->
        {:noreply, put_flash(socket, :error, "That identity is already linked to another group.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not register: #{inspect(reason)}")}
    end
  end

  defp success_flash("nostr"), do: "Registered. Proxies minted for Reticulum and MeshCore."
  defp success_flash("meshcore"), do: "Registered MeshCore primary. Nostr + RNS proxies minted."

  defp success_flash("reticulum"),
    do: "Registered Reticulum primary. Nostr + MeshCore proxies minted."

  defp success_flash(_), do: "Registered."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="max-w-2xl space-y-6">
        <div>
          <h1 class="text-3xl font-semibold">Register identity</h1>
          <p class="mt-2 text-base-content/70">
            Pick a primary network you already use. Isthmus mints proxies on the other networks so
            messages can fan out through the gateway.
          </p>
        </div>

        <%= cond do %>
          <% @existing -> %>
            <div class="alert alert-info">
              You already have an active registration.
              <.link navigate={~p"/me"} class="link">View identities</.link>
            </div>
          <% not @registration_open -> %>
            <div class="alert alert-warning">Self-service registration is closed by an admin.</div>
          <% true -> %>
            <.form
              for={@form}
              id="register-form"
              phx-change="validate"
              phx-submit="register"
              class="card bg-base-200 border border-base-300"
            >
              <div class="card-body space-y-4">
                <fieldset class="space-y-2">
                  <legend class="label-text font-medium">Primary network</legend>
                  <div class="flex flex-wrap gap-3">
                    <label class="label cursor-pointer gap-2">
                      <input
                        type="radio"
                        name="primary"
                        value="nostr"
                        class="radio radio-sm"
                        checked={@primary == "nostr"}
                      />
                      <span class="label-text">Nostr</span>
                    </label>
                    <label class="label cursor-pointer gap-2">
                      <input
                        type="radio"
                        name="primary"
                        value="meshcore"
                        class="radio radio-sm"
                        checked={@primary == "meshcore"}
                      />
                      <span class="label-text">MeshCore</span>
                    </label>
                    <label class="label cursor-pointer gap-2">
                      <input
                        type="radio"
                        name="primary"
                        value="reticulum"
                        class="radio radio-sm"
                        checked={@primary == "reticulum"}
                      />
                      <span class="label-text">Reticulum</span>
                    </label>
                  </div>
                </fieldset>

                <%= if @primary == "nostr" do %>
                  <div>
                    <label class="label"><span class="label-text">Nostr npub</span></label>
                    <p class="font-mono text-sm break-all">{@current_user.npub}</p>
                    <p class="text-xs opacity-60 mt-1">Uses your signed-in session key as primary.</p>
                  </div>
                <% else %>
                  <.input
                    field={@form[:identity_input]}
                    type="text"
                    label={identity_label(@primary)}
                    placeholder={identity_placeholder(@primary)}
                  />
                <% end %>

                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Display name"
                  placeholder="Used for MeshCore @token and adverts"
                />

                <button class="btn btn-primary" type="submit" id="register-submit">
                  {submit_label(@primary)}
                </button>
              </div>
            </.form>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  defp identity_label("meshcore"), do: "MeshCore pubkey or contact URI"
  defp identity_label("reticulum"), do: "Reticulum LXMF destination hash"
  defp identity_label(_), do: "Identity"

  defp identity_placeholder("meshcore"),
    do: "64-char hex or meshcore://contact/add?..."

  defp identity_placeholder("reticulum"), do: "32-char hex destination hash"
  defp identity_placeholder(_), do: ""

  defp submit_label("nostr"), do: "Create RNS + MeshCore proxies"
  defp submit_label("meshcore"), do: "Register MeshCore + mint proxies"
  defp submit_label("reticulum"), do: "Register Reticulum + mint proxies"
  defp submit_label(_), do: "Register"
end
