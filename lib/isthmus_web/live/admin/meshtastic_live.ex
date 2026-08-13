defmodule IsthmusWeb.Admin.MeshtasticLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.Health
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.RadioConfig
  alias Isthmus.QR
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.Copy

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:channels")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:lora")
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Meshtastic")
     |> assign(:channel_syncing, false)
     |> assign(:lora_applying, false)
     |> assign(:channel_invite, nil)
     |> assign(:selected_bridge_id, nil)
     |> assign(:channel_bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:channel_link_form, to_form(%{"group_id" => "", "channel_idx" => ""}))
     |> assign(:lora_form, to_form(RadioConfig.empty_form_params(), as: :lora))
     |> refresh()
     |> then(fn socket ->
       assign(
         socket,
         :lora_form,
         to_form(RadioConfig.to_form_params(Companion.lora_config()), as: :lora)
       )
     end)}
  end

  @impl true
  def handle_event("sync_channels", _params, socket) do
    health = Companion.health()

    if health.status == :online do
      Companion.sync_channels_async()

      {:noreply,
       socket
       |> assign(:channel_syncing, true)
       |> assign(:companion_health, health)
       |> put_flash(:info, "Syncing Meshtastic channels…")}
    else
      {:noreply,
       socket
       |> assign(:companion_health, health)
       |> put_flash(
         :error,
         "Meshtastic companion offline — plug in a radio or pin ISTHMUS_MESHTASTIC_PORT."
       )}
    end
  end

  def handle_event("reconnect", _params, socket) do
    Companion.reconnect()

    {:noreply,
     socket
     |> put_flash(:info, "Reconnecting Meshtastic companion…")
     |> refresh()}
  end

  def handle_event("rescan_devices", _params, socket) do
    case Discover.refresh() do
      {:ok, roles} ->
        path =
          case roles[:meshtastic] do
            %{path: p} -> p
            _ -> nil
          end

        msg =
          if is_binary(path) do
            "Rescanned — Meshtastic companion on #{path}."
          else
            "Rescanned — no Meshtastic companion found."
          end

        {:noreply, socket |> put_flash(:info, msg) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create_bridge_with_channel", %{"display_name" => name}, socket) do
    owner = socket.assigns.current_user.pubkey_hex

    result =
      try do
        Registrations.create_bridge_with_meshtastic_channel(owner, %{
          display_name: String.trim(name),
          created_by: "admin"
        })
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Group + private Meshtastic channel created (slot #{group.meshtastic_channel_idx})."
         )
         |> assign(:selected_bridge_id, group.id)
         |> assign(:channel_bridge_form, to_form(%{"display_name" => ""}))
         |> assign(:channel_invite, nil)
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "Meshtastic companion offline.")}

      {:error, :no_empty_channel_slot} ->
        {:noreply, put_flash(socket, :error, "No empty secondary channel slots (1–7).")}

      {:error, :timeout} ->
        {:noreply, put_flash(socket, :error, "Timed out talking to Meshtastic companion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create: #{inspect(reason)}")}
    end
  end

  def handle_event("select_bridge", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_bridge_id, id)
     |> assign(:channel_invite, nil)}
  end

  def handle_event("link_channel", params, socket) do
    group = Registrations.get_group!(params["group_id"])
    idx = String.to_integer(params["channel_idx"] || "-1")

    cond do
      idx not in 1..7 ->
        {:noreply,
         put_flash(socket, :error, "Pick a secondary slot (1–7). Slot 0 is PRIMARY / frequency.")}

      empty_channel?(socket.assigns.meshtastic_channels, idx) ->
        provision_channel(socket, group, idx: idx)

      true ->
        with %{psk_hex: psk} when is_binary(psk) and psk != "" <- Companion.get_channel(idx),
             {:ok, _} <- Registrations.link_meshtastic_channel(group, idx, psk) do
          {:noreply,
           socket
           |> assign(:selected_bridge_id, group.id)
           |> assign(:channel_invite, nil)
           |> put_flash(:info, "Channel #{idx} linked.")
           |> refresh()}
        else
          nil ->
            {:noreply, put_flash(socket, :error, "Channel not in companion cache — sync first.")}

          %{psk_hex: _} ->
            {:noreply,
             put_flash(socket, :error, "Channel has no PSK — pick a private secondary slot.")}

          {:error, :channel_already_linked} ->
            {:noreply, put_flash(socket, :error, "Channel already linked to another group.")}

          {:error, :not_a_bridge_group} ->
            {:noreply, put_flash(socket, :error, "Only bridge groups can link channels.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Link failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("create_channel_on_group", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)
    provision_channel(socket, group, [])
  end

  def handle_event("validate_lora", %{"lora" => params}, socket) do
    {:noreply, assign(socket, :lora_form, to_form(params, as: :lora))}
  end

  def handle_event("save_lora", %{"lora" => params}, socket) do
    socket = assign(socket, :lora_applying, true)

    case Companion.set_lora_config(params) do
      {:ok, lora} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> assign(:lora_form, to_form(RadioConfig.to_form_params(lora), as: :lora))
         |> put_flash(
           :info,
           "LoRa config written — radio is rebooting and will reconnect shortly."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> put_flash(:error, "Meshtastic companion offline.")}

      {:error, :timeout} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> put_flash(:error, "Timed out talking to Meshtastic companion.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> put_flash(:error, "LoRa config failed: #{format_err(reason)}")}
    end
  end

  def handle_event("unlink_channel", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.unlink_meshtastic_channel(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:channel_invite, nil)
         |> put_flash(:info, "Channel unlinked.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unlink failed: #{inspect(reason)}")}
    end
  end

  def handle_event("show_channel_invite", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.meshtastic_channel_invite(group) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> assign(:selected_bridge_id, group.id)
         |> assign(:channel_invite, invite)}

      {:error, :no_channel_linked} ->
        {:noreply, put_flash(socket, :error, "No Meshtastic channel linked to this group.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not decrypt channel invite.")}
    end
  end

  def handle_event("hide_channel_invite", _params, socket) do
    {:noreply, assign(socket, :channel_invite, nil)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info({:meshtastic_channels, channels}, socket) when is_list(channels) do
    {:noreply,
     socket
     |> assign(:channel_syncing, false)
     |> assign(:meshtastic_channels, Enum.sort_by(channels, & &1.index))
     |> assign(:companion_health, Companion.health())}
  end

  def handle_info({:meshtastic_lora, lora}, socket) when is_map(lora) do
    {:noreply,
     socket
     |> assign(:lora_form, to_form(RadioConfig.to_form_params(lora), as: :lora))
     |> assign(:companion_health, Companion.health())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))
    health = Companion.health()
    report = Health.normalize(:meshtastic, health)

    selected =
      case socket.assigns[:selected_bridge_id] do
        nil ->
          Enum.find(bridges, &(&1.meshtastic_channel_idx != nil)) || List.first(bridges)

        id ->
          Enum.find(bridges, &(&1.id == id)) || List.first(bridges)
      end

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:selected_bridge, selected)
    |> assign(:selected_bridge_id, selected && selected.id)
    |> assign(:meshtastic_channels, Companion.list_channels())
    |> assign(:companion_health, health)
    |> assign(:health_report, report)
    |> assign(:lora_applying, socket.assigns[:lora_applying] || false)
  end

  defp provision_channel(socket, group, opts) do
    result =
      try do
        Registrations.provision_meshtastic_channel(group, opts)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, linked} ->
        {:noreply,
         socket
         |> assign(:selected_bridge_id, linked.id)
         |> assign(:channel_invite, nil)
         |> put_flash(
           :info,
           "Private Meshtastic channel created on slot #{linked.meshtastic_channel_idx}."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "Meshtastic companion offline.")}

      {:error, :no_empty_channel_slot} ->
        {:noreply, put_flash(socket, :error, "No empty secondary channel slots (1–7).")}

      {:error, :slot_occupied} ->
        {:noreply, put_flash(socket, :error, "That slot is already configured on the radio.")}

      {:error, :already_linked} ->
        {:noreply, put_flash(socket, :error, "This group already has a Meshtastic channel.")}

      {:error, :timeout} ->
        {:noreply, put_flash(socket, :error, "Timed out talking to Meshtastic companion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create channel: #{inspect(reason)}")}
    end
  end

  defp empty_channel?(channels, idx) do
    case Enum.find(channels, &(&1.index == idx)) do
      %{empty?: true} -> true
      nil -> true
      _ -> false
    end
  end

  defp format_err(reason) when is_binary(reason), do: reason
  defp format_err(reason), do: inspect(reason)

  defp lora_mode(form) do
    case form[:mode].value do
      "custom" -> "custom"
      _ -> "preset"
    end
  end

  defp linked_group_name(groups, idx) do
    case Enum.find(groups, &(&1.status == "active" and &1.meshtastic_channel_idx == idx)) do
      nil -> nil
      group -> group.display_name
    end
  end

  defp role_label(1), do: "primary"
  defp role_label(2), do: "secondary"
  defp role_label(_), do: "empty"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-10">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Meshtastic</h1>
            <p class="mt-1 text-sm text-base-content/70 max-w-2xl">
              Connect a <strong class="font-medium">companion radio</strong>
              over USB serial and link a private channel to an Isthmus group.
            </p>
          </div>
          <.admin_nav current={:meshtastic} />
        </div>

        <div class="space-y-4" id="companion-status">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium">Companion radio</h2>
              <p class="text-xs opacity-70 mt-1">
                USB serial is auto-detected by handshake (MeshCore
                <code class="font-mono">&lt;/&gt;</code>
                frames vs Meshtastic <code class="font-mono">0x94 0xC3</code>
                protobuf). Pin <code class="font-mono">ISTHMUS_MESHTASTIC_PORT</code>
                only to override.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <button
                class="btn btn-outline btn-sm"
                id="rescan-meshtastic-btn"
                phx-click="rescan_devices"
                type="button"
              >
                Rescan USB
              </button>
              <button
                class="btn btn-outline btn-sm"
                id="reconnect-meshtastic-btn"
                phx-click="reconnect"
                type="button"
              >
                Reconnect
              </button>
              <button
                class="btn btn-outline btn-sm"
                id="sync-meshtastic-channels-btn"
                phx-click="sync_channels"
                disabled={@channel_syncing or @companion_health.status != :online}
                type="button"
              >
                Sync channels
              </button>
            </div>
          </div>

          <article class="rounded-box border border-base-300 bg-base-200 p-4 space-y-2">
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="font-medium">{@health_report.summary}</p>
                <p :if={@companion_health[:node_id]} class="text-sm opacity-70 font-mono mt-1">
                  !{@companion_health.node_id}
                </p>
              </div>
              <span class={["badge badge-sm", Copy.status_badge_class(@companion_health.status)]}>
                {Copy.status_plain(@companion_health.status)}
              </span>
            </div>
            <p :if={@health_report.issue} class="text-sm text-warning">{@health_report.issue}</p>
            <p :if={@health_report.fix} class="text-sm opacity-70">{@health_report.fix}</p>
            <p
              :if={@companion_health.status == :online and @companion_health[:region_label]}
              class="text-sm opacity-70"
            >
              {RadioConfig.region_label(@companion_health[:region])} · {if(
                @companion_health[:use_preset],
                do: RadioConfig.preset_label(@companion_health[:modem_preset]),
                else: "custom LoRa"
              )} · hops {@companion_health[:hop_limit] || 3}
            </p>
          </article>
        </div>

        <div
          :if={@companion_health.status == :online}
          class="space-y-4"
          id="meshtastic-radio-config"
        >
          <div>
            <h2 class="text-lg font-medium">Radio configuration</h2>
            <p class="text-xs opacity-70 mt-1">
              Region (country / band) and modem preset, or explicit bandwidth /
              spreading factor / coding rate. Apply writes LoRa config and reboots
              the companion — mesh traffic drops for a few seconds.
            </p>
          </div>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body space-y-3">
              <.form
                for={@lora_form}
                id="meshtastic-lora-form"
                phx-change="validate_lora"
                phx-submit="save_lora"
                class="space-y-3"
              >
                <div class="grid gap-3 sm:grid-cols-2">
                  <.input
                    field={@lora_form[:region]}
                    type="select"
                    label="Region"
                    options={RadioConfig.region_options()}
                    id="lora-region"
                  />
                  <.input
                    field={@lora_form[:mode]}
                    type="select"
                    label="Modem"
                    options={RadioConfig.mode_options()}
                    id="lora-mode"
                  />
                </div>
                <%= if lora_mode(@lora_form) == "custom" do %>
                  <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
                    <.input
                      field={@lora_form[:bandwidth]}
                      type="select"
                      label="BW (kHz)"
                      options={[
                        {"31.25", "31"},
                        {"62.5", "62"},
                        {"125", "125"},
                        {"250", "250"},
                        {"500", "500"}
                      ]}
                      id="lora-bandwidth"
                    />
                    <.input
                      field={@lora_form[:spread_factor]}
                      type="number"
                      label="SF"
                      min="7"
                      max="12"
                      id="lora-sf"
                    />
                    <.input
                      field={@lora_form[:coding_rate]}
                      type="number"
                      label="CR"
                      min="5"
                      max="8"
                      id="lora-cr"
                    />
                    <.input
                      field={@lora_form[:override_frequency]}
                      type="text"
                      label="Freq (MHz, optional)"
                      placeholder="leave blank for region default"
                      id="lora-freq"
                    />
                  </div>
                <% else %>
                  <.input
                    field={@lora_form[:modem_preset]}
                    type="select"
                    label="Preset"
                    options={RadioConfig.preset_options()}
                    id="lora-preset"
                  />
                <% end %>
                <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
                  <.input
                    field={@lora_form[:hop_limit]}
                    type="number"
                    label="Hop limit"
                    min="1"
                    max="7"
                    id="lora-hops"
                  />
                  <.input
                    field={@lora_form[:tx_power]}
                    type="number"
                    label="TX (dBm, 0 = max legal)"
                    min="0"
                    max="30"
                    id="lora-tx"
                  />
                  <.input
                    field={@lora_form[:channel_num]}
                    type="number"
                    label="LoRa channel #"
                    min="0"
                    max="83"
                    id="lora-channel-num"
                  />
                </div>
                <p class="text-xs opacity-70">
                  LoRa channel # is the frequency slot inside the region (0 = hash
                  from PRIMARY name), not a group chat slot.
                </p>
                <button
                  class={["btn btn-primary btn-sm", @lora_applying && "loading"]}
                  type="submit"
                  id="save-lora-btn"
                  disabled={@lora_applying}
                >
                  {if(@lora_applying, do: "Applying…", else: "Apply & reboot")}
                </button>
              </.form>
            </div>
          </div>
        </div>

        <div class="space-y-4" id="groups-channels">
          <div>
            <h2 class="text-lg font-medium">Groups and radio channels</h2>
            <p class="text-xs opacity-70 mt-1">
              Link a Meshtastic channel on the companion to an Isthmus
              <strong class="font-medium">group</strong>
              so members across networks share that channel. Slot 0 is PRIMARY
              (radio frequency); Isthmus creates private group chat on secondary
              slots 1–7. Empty slots can be provisioned here — you do not need
              the Meshtastic app first.
            </p>
          </div>

          <%= if @companion_health.status != :online do %>
            <div
              class="rounded-lg border border-base-300 bg-base-200/50 p-4 space-y-2"
              id="companion-setup-card"
            >
              <p class="text-sm">
                To create or sync private channels, connect a Meshtastic
                <strong class="font-medium">companion radio</strong>
                and Rescan USB. Pin <code class="font-mono">ISTHMUS_MESHTASTIC_PORT</code>
                only if several serial devices are attached.
              </p>
              <p class="text-sm opacity-70">
                Membership for groups is managed on <.link
                  navigate={~p"/admin/registrations"}
                  class="link"
                >Groups</.link>.
              </p>
            </div>
          <% else %>
            <div class="grid gap-6 lg:grid-cols-2" id="companion-channel-tools">
              <div class="card bg-base-200 border border-base-300">
                <div class="card-body space-y-3">
                  <h3 class="card-title text-base">New group + private channel</h3>
                  <p class="text-xs opacity-70">
                    Creates a group and provisions a secondary channel (slots 1–7) on the companion.
                  </p>
                  <.form
                    for={@channel_bridge_form}
                    id="channel-bridge-form"
                    phx-submit="create_bridge_with_channel"
                    class="space-y-3"
                  >
                    <.input
                      field={@channel_bridge_form[:display_name]}
                      type="text"
                      label="Group name"
                      placeholder="Lobby"
                    />
                    <button class="btn btn-primary btn-sm" type="submit">Create</button>
                  </.form>
                </div>
              </div>

              <div class="card bg-base-200 border border-base-300">
                <div class="card-body space-y-3">
                  <h3 class="card-title text-base">Link or create on existing group</h3>
                  <%= if @bridges == [] do %>
                    <p class="text-sm opacity-70">
                      Create a group on
                      <.link navigate={~p"/admin/registrations"} class="link">Groups</.link>
                      first, or use “New group + private channel”.
                    </p>
                  <% else %>
                    <.form
                      for={@channel_link_form}
                      id="channel-link-form"
                      phx-submit="link_channel"
                      class="space-y-3"
                    >
                      <div>
                        <label class="label" for="link-bridge">
                          <span class="label-text">Group</span>
                        </label>
                        <select id="link-bridge" name="group_id" class="select select-bordered w-full">
                          <option
                            :for={g <- @bridges}
                            value={g.id}
                            selected={g.id == @selected_bridge_id}
                          >
                            {g.display_name}
                          </option>
                        </select>
                      </div>
                      <div>
                        <label class="label" for="link-channel">
                          <span class="label-text">Channel slot (1–7)</span>
                        </label>
                        <select
                          id="link-channel"
                          name="channel_idx"
                          class="select select-bordered w-full"
                        >
                          <option
                            :for={ch <- @meshtastic_channels}
                            :if={ch.index in 1..7}
                            value={ch.index}
                          >
                            <%= if ch.empty? do %>
                              Create on #{ch.index} (empty)
                            <% else %>
                              #{ch.index} — {ch.name || "unnamed"} ({role_label(ch.role)})
                            <% end %>
                          </option>
                        </select>
                      </div>
                      <p class="text-xs opacity-70">
                        Empty slots are created on the radio with a new PSK.
                        Occupied slots are linked as-is. Slot 0 (PRIMARY) is not used for groups.
                      </p>
                      <button class="btn btn-primary btn-sm" type="submit">Link or create</button>
                    </.form>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="overflow-x-auto">
              <table class="table table-sm" id="meshtastic-channels-table">
                <thead>
                  <tr>
                    <th>Slot</th>
                    <th>Name</th>
                    <th>Role</th>
                    <th>Linked group</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={ch <- @meshtastic_channels} id={"channel-#{ch.index}"}>
                    <td>{ch.index}</td>
                    <td>{if ch.empty?, do: "—", else: ch.name}</td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        ch.empty? && "badge-ghost",
                        not ch.empty? && ch.role == 1 && "badge-warning",
                        not ch.empty? && ch.role != 1 && "badge-primary"
                      ]}>
                        {role_label(ch.role)}
                      </span>
                    </td>
                    <td>{linked_group_name(@groups, ch.index) || "—"}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>

          <div
            :if={@selected_bridge}
            class="card bg-base-200 border border-base-300"
            id="channel-bridge-detail"
          >
            <div class="card-body space-y-3">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-xl font-medium">{@selected_bridge.display_name}</h3>
                <span class="badge badge-secondary badge-sm">group</span>
                <select
                  id="invite-bridge-select"
                  class="select select-bordered select-sm"
                  phx-change="select_bridge"
                  name="id"
                >
                  <option :for={g <- @bridges} value={g.id} selected={g.id == @selected_bridge_id}>
                    {g.display_name}
                    <%= if g.meshtastic_channel_idx != nil do %>
                      (slot {g.meshtastic_channel_idx})
                    <% end %>
                  </option>
                </select>
              </div>

              <%= if @selected_bridge.meshtastic_channel_idx != nil do %>
                <div
                  class="space-y-3 rounded-lg border border-base-300 bg-base-100/40 p-4"
                  id="channel-invite-section"
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm opacity-70 grow">
                      Linked Meshtastic channel · slot {@selected_bridge.meshtastic_channel_idx}
                    </p>
                    <%= if @channel_invite do %>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        id="hide-channel-invite-btn"
                        phx-click="hide_channel_invite"
                      >
                        Hide invite
                      </button>
                    <% else %>
                      <button
                        type="button"
                        class="btn btn-outline btn-xs"
                        id="show-channel-invite-btn"
                        phx-click="show_channel_invite"
                        phx-value-id={@selected_bridge.id}
                      >
                        Show channel invite
                      </button>
                    <% end %>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs text-error"
                      id="unlink-channel-btn"
                      phx-click="unlink_channel"
                      phx-value-id={@selected_bridge.id}
                    >
                      Unlink
                    </button>
                  </div>

                  <%= if @channel_invite do %>
                    <p class="text-xs opacity-60">
                      On another Meshtastic device: add this channel, then send a message —
                      Isthmus fans it out to attached group members.
                    </p>

                    <div class="grid gap-4 md:grid-cols-2" id="channel-invite-panel">
                      <div class="space-y-2" id="channel-invite-secret">
                        <h4 class="text-sm font-medium">Channel PSK</h4>
                        <p class="text-xs opacity-60">
                          Meshtastic app → add a secondary channel. Name + hex PSK.
                        </p>
                        <dl class="space-y-2 text-sm">
                          <div>
                            <dt class="text-xs opacity-60">Name</dt>
                            <dd class="font-mono select-all">{@channel_invite.name}</dd>
                          </div>
                          <div>
                            <dt class="text-xs opacity-60">PSK</dt>
                            <dd class="font-mono text-xs break-all select-all">
                              {@channel_invite.psk_hex}
                            </dd>
                          </div>
                          <div>
                            <dt class="text-xs opacity-60">Gateway slot (local)</dt>
                            <dd class="font-mono">{@channel_invite.slot}</dd>
                          </div>
                        </dl>
                      </div>

                      <div class="space-y-2" id="channel-invite-qr">
                        <h4 class="text-sm font-medium">QR code</h4>
                        <p class="text-xs opacity-60">
                          Meshtastic app → scan to add the channel (or paste the URL).
                        </p>
                        <%= if qr = QR.svg(@channel_invite.uri) do %>
                          <div class="bg-white p-2 rounded-lg inline-block size-[236px]">
                            {Phoenix.HTML.raw(qr)}
                          </div>
                        <% end %>
                        <p class="font-mono text-xs break-all select-all opacity-80">
                          {@channel_invite.uri}
                        </p>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <p class="text-sm opacity-70">
                  This group has no Meshtastic channel linked yet.
                </p>
                <button
                  :if={@companion_health.status == :online}
                  type="button"
                  class="btn btn-primary btn-sm"
                  id="create-channel-on-group-btn"
                  phx-click="create_channel_on_group"
                  phx-value-id={@selected_bridge.id}
                >
                  Create private channel on this group
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
