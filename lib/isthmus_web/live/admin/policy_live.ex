defmodule IsthmusWeb.Admin.PolicyLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Policy

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Policy")
     |> assign_data()}
  end

  defp assign_data(socket) do
    settings = Policy.all_settings()
    allow = List.wrap(settings["gateway_allow_directions"])
    deny = List.wrap(settings["gateway_deny_directions"])

    socket
    |> assign(:settings, settings)
    |> assign(:direction_keys, Policy.direction_keys())
    |> assign(:allow, MapSet.new(allow))
    |> assign(:deny, MapSet.new(deny))
    |> assign(
      :form,
      to_form(
        %{
          "announce_min_interval_sec" => settings["announce_min_interval_sec"],
          "nostr_publish_budget_per_hour" => settings["nostr_publish_budget_per_hour"]
        },
        as: :policy
      )
    )
  end

  @impl true
  def handle_event("save_budgets", %{"policy" => params}, socket) do
    interval = parse_int(params["announce_min_interval_sec"], 3600)
    budget = parse_int(params["nostr_publish_budget_per_hour"], 60)

    {:ok, _} = Policy.put("announce_min_interval_sec", interval)
    {:ok, _} = Policy.put("nostr_publish_budget_per_hour", budget)

    {:noreply, socket |> put_flash(:info, "Budgets saved.") |> assign_data()}
  end

  def handle_event("toggle_allow", %{"key" => key}, socket) do
    allow =
      if MapSet.member?(socket.assigns.allow, key) do
        MapSet.delete(socket.assigns.allow, key)
      else
        MapSet.put(socket.assigns.allow, key)
      end

    list = MapSet.to_list(allow)
    {:ok, _} = Policy.put("gateway_allow_directions", list)
    {:noreply, assign(socket, :allow, allow)}
  end

  def handle_event("toggle_deny", %{"key" => key}, socket) do
    deny =
      if MapSet.member?(socket.assigns.deny, key) do
        MapSet.delete(socket.assigns.deny, key)
      else
        MapSet.put(socket.assigns.deny, key)
      end

    list = MapSet.to_list(deny)
    {:ok, _} = Policy.put("gateway_deny_directions", list)
    {:noreply, assign(socket, :deny, deny)}
  end

  def handle_event("clear_allow", _params, socket) do
    {:ok, _} = Policy.put("gateway_allow_directions", [])

    {:noreply,
     socket |> put_flash(:info, "Allow-list cleared (all directions permitted).") |> assign_data()}
  end

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(n, _) when is_integer(n), do: n
  defp parse_int(_, default), do: default

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Policy</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Registration, budgets, and gateway direction rules.
            </p>
          </div>
          <.admin_nav current={:policy} />
        </div>

        <div class="rounded-box border border-base-300 bg-base-200 p-4 space-y-2">
          <p class="font-medium">Registration</p>
          <p class="text-sm opacity-70">
            Self-service registration is
            <span class="font-semibold">
              {if @settings["registration_open"], do: "open", else: "closed"}
            </span>
            (toggle on Admin home).
          </p>
        </div>

        <.form
          for={@form}
          id="policy-budgets-form"
          phx-submit="save_budgets"
          class="rounded-box border border-base-300 bg-base-200 p-4 space-y-4 max-w-lg"
        >
          <h2 class="text-lg font-medium">Budgets</h2>
          <.input
            field={@form[:announce_min_interval_sec]}
            type="number"
            label="Announce min interval (sec)"
            min="0"
          />
          <.input
            field={@form[:nostr_publish_budget_per_hour]}
            type="number"
            label="Nostr publish budget / hour"
            min="0"
          />
          <button type="submit" class="btn btn-primary btn-sm">Save budgets</button>
        </.form>

        <div class="space-y-3">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium">Gateway directions</h2>
              <p class="text-xs opacity-60">
                Empty allow-list = all directions permitted. Deny always wins.
              </p>
            </div>
            <button
              type="button"
              id="clear-allow"
              class="btn btn-ghost btn-xs"
              phx-click="clear_allow"
            >
              Clear allow-list
            </button>
          </div>

          <div class="overflow-x-auto rounded-box border border-base-300" id="direction-policy">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Direction</th>
                  <th>Allow-list</th>
                  <th>Deny-list</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={key <- @direction_keys}>
                  <td class="font-mono text-sm">{key}</td>
                  <td>
                    <button
                      type="button"
                      id={"allow-#{String.replace(key, ">", "-")}"}
                      class={[
                        "btn btn-xs",
                        MapSet.member?(@allow, key) && "btn-success",
                        not MapSet.member?(@allow, key) && "btn-ghost"
                      ]}
                      phx-click="toggle_allow"
                      phx-value-key={key}
                    >
                      {if MapSet.member?(@allow, key), do: "allowed", else: "—"}
                    </button>
                  </td>
                  <td>
                    <button
                      type="button"
                      id={"deny-#{String.replace(key, ">", "-")}"}
                      class={[
                        "btn btn-xs",
                        MapSet.member?(@deny, key) && "btn-error",
                        not MapSet.member?(@deny, key) && "btn-ghost"
                      ]}
                      phx-click="toggle_deny"
                      phx-value-key={key}
                    >
                      {if MapSet.member?(@deny, key), do: "denied", else: "—"}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
