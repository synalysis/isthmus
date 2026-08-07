defmodule IsthmusWeb.Admin.ReticulumLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.Reticulum
  alias Isthmus.Networks.Reticulum.ConfigFile

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Reticulum")
     |> assign(:iface_form, blank_iface_form())
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  @impl true
  def handle_event("iface_validate", %{"iface" => params}, socket) do
    {:noreply, assign(socket, :iface_form, to_form(params, as: :iface))}
  end

  def handle_event("iface_add", %{"iface" => params}, socket) do
    attrs = %{
      name: params["name"],
      type: params["type"],
      enabled: true,
      target_host: params["target_host"],
      target_port: params["target_port"],
      listen_ip: params["listen_ip"],
      listen_port: params["listen_port"]
    }

    case Reticulum.add_config_interface(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Interface added to config. Click Apply to reload the sidecar.")
         |> assign(:iface_form, blank_iface_form())
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add interface: #{format_err(reason)}")}
    end
  end

  def handle_event("iface_remove", %{"name" => name}, socket) do
    case Reticulum.remove_config_interface(name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Removed #{name}. Click Apply to reload the sidecar.")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove: #{format_err(reason)}")}
    end
  end

  def handle_event("iface_set_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled in ["true", "1", "yes", "on"]

    case Reticulum.set_config_interface_enabled(name, enabled?) do
      {:ok, _} ->
        label = if(enabled?, do: "Enabled", else: "Disabled")

        {:noreply,
         socket
         |> put_flash(:info, "#{label} #{name}. Click Apply to reload the sidecar.")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update: #{format_err(reason)}")}
    end
  end

  def handle_event("set_share_instance", %{"enabled" => enabled}, socket) do
    enabled? = enabled in ["true", "1", "yes", "on"]

    case Reticulum.set_share_instance(enabled?) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "share_instance set to #{if(enabled?, do: "Yes", else: "No")}. Click Apply to reload."
         )
         |> assign_data()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not update share_instance: #{format_err(reason)}")}
    end
  end

  def handle_event("apply_config", _params, socket) do
    case Reticulum.apply_config() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Sidecar restarting to load the updated config…")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Apply failed: #{format_err(reason)}")}
    end
  end

  defp assign_data(socket) do
    socket =
      case Reticulum.instance_status() do
        {:ok, status} ->
          socket
          |> assign(:status, status)
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:status, nil)
          |> assign(:error, inspect(reason))
      end

    config_ifaces =
      case Reticulum.list_config_interfaces() do
        {:ok, list} -> list
        _ -> []
      end

    share? =
      try do
        Reticulum.share_instance?()
      rescue
        _ -> true
      end

    socket
    |> assign(:config_path, Reticulum.config_path())
    |> assign(:config_interfaces, config_ifaces)
    |> assign(:share_instance, share?)
    |> assign(:allowed_types, ConfigFile.allowed_types())
  end

  defp blank_iface_form do
    to_form(
      %{
        "name" => "",
        "type" => "AutoInterface",
        "target_host" => "127.0.0.1",
        "target_port" => "4242",
        "listen_ip" => "0.0.0.0",
        "listen_port" => "4242"
      },
      as: :iface
    )
  end

  defp format_err(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_err(reason), do: inspect(reason)

  defp slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp role_badge("client"), do: {"client (attached)", "badge-success"}
  defp role_badge("shared_master"), do: {"shared master", "badge-info"}
  defp role_badge("standalone"), do: {"standalone", "badge-warning"}
  defp role_badge(other), do: {other || "unknown", "badge-ghost"}

  defp online_badge(true), do: {"online", "badge-success"}
  defp online_badge(false), do: {"offline", "badge-error"}
  defp online_badge(_), do: {"?", "badge-ghost"}

  defp bool_label(true), do: "yes"
  defp bool_label(false), do: "no"
  defp bool_label(_), do: "—"

  defp pretty_bytes(nil), do: "—"
  defp pretty_bytes(n) when is_number(n) and n < 1024, do: "#{trunc(n)} B"
  defp pretty_bytes(n) when is_number(n) and n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KiB"
  defp pretty_bytes(n) when is_number(n), do: "#{Float.round(n / 1_048_576, 2)} MiB"
  defp pretty_bytes(_), do: "—"

  defp pretty_rate(nil), do: "—"
  defp pretty_rate(n) when is_number(n), do: "#{pretty_bytes(n)}/s"
  defp pretty_rate(_), do: "—"

  defp iface_online?(iface) do
    Map.get(iface, "online") || Map.get(iface, "status") || false
  end

  defp config_iface_details(iface) do
    [
      iface.target_host && "host=#{iface.target_host}",
      iface.target_port && "port=#{iface.target_port}",
      iface.listen_ip && "listen=#{iface.listen_ip}",
      iface.listen_port && "port=#{iface.listen_port}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "—"
      other -> other
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Reticulum</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Sidecar status and Isthmus-owned RNS config (`ISTHMUS_RNS_CONFIGDIR`).
            </p>
          </div>
          <.admin_nav current={:reticulum} />
        </div>

        <div :if={@error} class="alert alert-error text-sm">
          Could not load RNS status: {@error}
        </div>

        <div :if={@status} id="rns-status" class="space-y-8">
          <div class="grid gap-4 md:grid-cols-4">
            <div class="stat bg-base-200 rounded-box border border-base-300">
              <div class="stat-title">Sidecar</div>
              <div class="stat-value text-2xl">
                {if @status.live, do: "live", else: "not live"}
              </div>
            </div>
            <div class="stat bg-base-200 rounded-box border border-base-300">
              <div class="stat-title">Instance role</div>
              <div class="stat-value text-lg">
                <% {label, class} = role_badge(@status.instance_role) %>
                <span class={["badge", class]}>{label}</span>
              </div>
              <div class="stat-desc font-mono text-xs">
                {@status.instance["instance_name"] || "default"}
              </div>
            </div>
            <div class="stat bg-base-200 rounded-box border border-base-300">
              <div class="stat-title">LXMF destinations</div>
              <div class="stat-value text-2xl">{@status.registered_count}</div>
            </div>
            <div class="stat bg-base-200 rounded-box border border-base-300">
              <div class="stat-title">Traffic</div>
              <div class="stat-value text-sm font-mono leading-relaxed">
                ↓ {pretty_bytes(@status.traffic["rxb"])}<br />
                ↑ {pretty_bytes(@status.traffic["txb"])}
              </div>
              <div class="stat-desc font-mono text-xs">
                {pretty_rate(@status.traffic["rxs"])} / {pretty_rate(@status.traffic["txs"])}
              </div>
            </div>
          </div>

          <div class="rounded-box border border-base-300 bg-base-200 p-4 space-y-3">
            <h2 class="text-lg font-medium">Instance</h2>
            <dl class="grid gap-2 sm:grid-cols-2 text-sm">
              <div>
                <dt class="opacity-60">Config dir</dt>
                <dd class="font-mono text-xs break-all">{@status.configdir || "—"}</dd>
              </div>
              <div>
                <dt class="opacity-60">Storage</dt>
                <dd class="font-mono text-xs break-all">{@status.storagepath || "—"}</dd>
              </div>
              <div>
                <dt class="opacity-60">share_instance (runtime)</dt>
                <dd>{bool_label(@status.instance["share_instance"])}</dd>
              </div>
              <div>
                <dt class="opacity-60">Connected to shared</dt>
                <dd>{bool_label(@status.instance["is_connected_to_shared_instance"])}</dd>
              </div>
              <div>
                <dt class="opacity-60">Is shared master</dt>
                <dd>{bool_label(@status.instance["is_shared_instance"])}</dd>
              </div>
              <div>
                <dt class="opacity-60">Transport enabled</dt>
                <dd>{bool_label(@status.instance["transport_enabled"])}</dd>
              </div>
              <div>
                <dt class="opacity-60">IsthmusInterface socket</dt>
                <dd class="font-mono text-xs">
                  {@status.interface_socket[:path] || @status.interface_socket["path"] || "—"} · {@status.interface_socket[
                    :status
                  ] || @status.interface_socket["status"] || "—"}
                </dd>
              </div>
            </dl>
            <p
              :if={@status.instance_role == "client"}
              class="text-xs opacity-70"
            >
              Attached to another local RNS process (typically MeshChatX) via instance <span class="font-mono">{@status.instance["instance_name"]}</span>.
              Physical radios are owned by that shared master — local interface edits below only apply when Isthmus runs standalone or as shared master.
            </p>
            <p
              :if={@status.instance_role == "shared_master"}
              class="text-xs opacity-70"
            >
              This sidecar owns the shared instance. Other local apps with the same
              <span class="font-mono">instance_name</span>
              will attach as clients.
            </p>
            <p
              :if={@status.instance_role == "standalone"}
              class="text-xs opacity-70"
            >
              Running standalone — not attached to MeshChatX. Peer via AutoInterface/TCP
              or start MeshChatX first with matching <span class="font-mono">instance_name</span>.
            </p>
          </div>

          <div
            id="rns-config-editor"
            class="rounded-box border border-base-300 bg-base-200 p-4 space-y-4"
          >
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h2 class="text-lg font-medium">Isthmus config</h2>
                <p class="text-xs opacity-70 mt-1 font-mono break-all">{@config_path}</p>
                <p class="text-xs opacity-60 mt-1">
                  Edits only this file (comments preserved). Apply restarts the sidecar.
                </p>
              </div>
              <button
                id="rns-apply-config"
                type="button"
                phx-click="apply_config"
                class="btn btn-primary btn-sm"
                data-confirm="Restart the RNS sidecar to load the current config?"
              >
                Apply (restart sidecar)
              </button>
            </div>

            <div
              :if={@status.instance_role == "client"}
              class="alert alert-warning text-sm"
            >
              Currently attached as a shared-instance client. Interface blocks in this file are
              not opened while attached — set <span class="font-mono">share_instance = No</span>
              and Apply (or quit MeshChatX) for an independent stack.
            </div>

            <div class="flex flex-wrap items-center gap-3 text-sm">
              <span class="opacity-70">share_instance (file)</span>
              <span class="badge badge-ghost">{if(@share_instance, do: "Yes", else: "No")}</span>
              <button
                id="rns-share-yes"
                type="button"
                phx-click="set_share_instance"
                phx-value-enabled="true"
                class={["btn btn-xs", @share_instance && "btn-active"]}
              >
                Yes
              </button>
              <button
                id="rns-share-no"
                type="button"
                phx-click="set_share_instance"
                phx-value-enabled="false"
                class={["btn btn-xs", !@share_instance && "btn-active"]}
              >
                No
              </button>
            </div>

            <h3 class="text-sm font-medium pt-1">Configured interfaces</h3>
            <div class="overflow-x-auto rounded-box border border-base-300">
              <table class="table table-sm" id="rns-configured-ifaces">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Type</th>
                    <th>Enabled</th>
                    <th>Details</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@config_interfaces == []}>
                    <td colspan="5" class="text-sm opacity-60">
                      No interface blocks found in config.
                    </td>
                  </tr>
                  <tr :for={iface <- @config_interfaces} id={"rns-iface-#{slug(iface.name)}"}>
                    <td class="font-medium text-sm">{iface.name}</td>
                    <td class="font-mono text-xs">{iface.type || "—"}</td>
                    <td>{bool_label(iface.enabled)}</td>
                    <td class="font-mono text-xs opacity-70">{config_iface_details(iface)}</td>
                    <td class="text-right whitespace-nowrap">
                      <button
                        :if={iface.enabled != false}
                        type="button"
                        class="btn btn-ghost btn-xs"
                        id={"rns-iface-disable-#{slug(iface.name)}"}
                        phx-click="iface_set_enabled"
                        phx-value-name={iface.name}
                        phx-value-enabled="false"
                      >
                        Disable
                      </button>
                      <button
                        :if={iface.enabled == false}
                        type="button"
                        class="btn btn-ghost btn-xs"
                        id={"rns-iface-enable-#{slug(iface.name)}"}
                        phx-click="iface_set_enabled"
                        phx-value-name={iface.name}
                        phx-value-enabled="true"
                      >
                        Enable
                      </button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="iface_remove"
                        phx-value-name={iface.name}
                        data-confirm={"Remove interface #{iface.name} from config?"}
                      >
                        Remove
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.form
              for={@iface_form}
              id="rns-iface-form"
              phx-change="iface_validate"
              phx-submit="iface_add"
              class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 items-end pt-2"
            >
              <.input field={@iface_form[:name]} type="text" label="Name" required />
              <.input
                field={@iface_form[:type]}
                type="select"
                label="Type"
                options={Enum.map(@allowed_types, &{&1, &1})}
              />
              <.input
                :if={@iface_form[:type].value == "TCPClientInterface"}
                field={@iface_form[:target_host]}
                type="text"
                label="Target host"
              />
              <.input
                :if={@iface_form[:type].value == "TCPClientInterface"}
                field={@iface_form[:target_port]}
                type="text"
                label="Target port"
              />
              <.input
                :if={@iface_form[:type].value == "TCPServerInterface"}
                field={@iface_form[:listen_ip]}
                type="text"
                label="Listen IP"
              />
              <.input
                :if={@iface_form[:type].value == "TCPServerInterface"}
                field={@iface_form[:listen_port]}
                type="text"
                label="Listen port"
              />
              <div class="sm:col-span-2 lg:col-span-3">
                <button type="submit" class="btn btn-secondary btn-sm" id="rns-iface-add">
                  Add interface
                </button>
              </div>
            </.form>
          </div>

          <div class="space-y-2">
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="text-lg font-medium">Live interfaces</h2>
              <p class="text-xs opacity-50">Refreshes every 3s · same source as rnstatus</p>
            </div>
            <p :if={@status.stats_note} class="text-xs opacity-70 max-w-3xl">
              {@status.stats_note}
            </p>
            <p :if={@status.stats_error} class="text-xs text-warning">
              Stats error: {@status.stats_error}
            </p>
            <div class="overflow-x-auto rounded-box border border-base-300">
              <table class="table table-sm" id="rns-live-ifaces">
                <thead>
                  <tr>
                    <th>Status</th>
                    <th>Name</th>
                    <th>Type</th>
                    <th>Bitrate</th>
                    <th>RX / TX</th>
                    <th>Peers / clients</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@status.interfaces == []}>
                    <td colspan="6" class="text-sm opacity-60">No interfaces reported.</td>
                  </tr>
                  <tr :for={iface <- @status.interfaces}>
                    <td>
                      <% {label, class} = online_badge(iface_online?(iface)) %>
                      <span class={["badge badge-sm", class]}>{label}</span>
                    </td>
                    <td class="text-sm">
                      <span class="font-medium">{iface["short_name"] || iface["name"]}</span>
                      <br />
                      <span class="font-mono text-xs opacity-60">{iface["name"]}</span>
                    </td>
                    <td class="font-mono text-xs">{iface["type"] || "—"}</td>
                    <td class="font-mono text-xs">{pretty_rate(iface["bitrate"])}</td>
                    <td class="font-mono text-xs whitespace-nowrap">
                      {pretty_bytes(iface["rxb"])} / {pretty_bytes(iface["txb"])}
                    </td>
                    <td class="font-mono text-xs">
                      {iface["peers"] || "—"} / {iface["clients"] || "—"}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div :if={@status.registered != []} class="space-y-2">
            <h2 class="text-lg font-medium">Registered LXMF destinations</h2>
            <ul class="text-xs font-mono space-y-1 opacity-80">
              <li :for={dest <- @status.registered}>{dest}</li>
            </ul>
          </div>
        </div>

        <div
          :if={!@status && !@error}
          id="rns-config-editor-offline"
          class="rounded-box border border-base-300 bg-base-200 p-4 space-y-4"
        >
          <h2 class="text-lg font-medium">Isthmus config</h2>
          <p class="text-xs font-mono break-all opacity-70">{@config_path}</p>
          <p class="text-sm opacity-70">
            Sidecar status unavailable; you can still edit the config file.
          </p>
          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <tbody>
                <tr :for={iface <- @config_interfaces}>
                  <td>{iface.name}</td>
                  <td class="font-mono text-xs">{iface.type}</td>
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
