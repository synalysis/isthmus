defmodule IsthmusWeb.Admin.ReticulumHTML do
  @moduledoc false
  use IsthmusWeb, :html

  import IsthmusWeb.Admin.FirmwareOffer, only: [usb_firmware_offer: 1]

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
      iface.listen_port && "port=#{iface.listen_port}",
      iface.port && "port=#{iface.port}",
      iface.frequency && "freq=#{iface.frequency} Hz",
      iface.bandwidth && "bw=#{iface.bandwidth} Hz"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "—"
      other -> other
    end
  end

  defp rnode_configured?(path, ifaces) do
    Enum.any?(ifaces, fn iface ->
      iface.type == "RNodeInterface" and iface.port == path
    end)
  end

  defp rnode_dom_id(path) when is_binary(path) do
    "rnode-" <> (path |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_-]/, "-"))
  end

  defp rnode_dom_id(_), do: "rnode-unknown"

  defp rnode_device(rnode) when is_map(rnode) do
    rnode
    |> Map.put(:kind, :rnode)
    |> Map.put(:id, rnode.path)
  end

  defp lxmf_role_label("proxy"), do: "proxy (Isthmus-owned)"

  defp lxmf_role_label("primary"), do: "primary"

  defp lxmf_role_label("member"), do: "member"

  defp lxmf_role_label(role) when is_binary(role) and role != "", do: role

  defp lxmf_role_label(_), do: "—"

  def page(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <.admin_header current={:reticulum} title="Reticulum">
          Sidecar status and Isthmus-owned RNS config (`ISTHMUS_RNS_CONFIGDIR`).
        </.admin_header>

        <div :if={@error} class="alert alert-error text-sm" id="rns-status-error">
          <div class="space-y-1">
            <p>{@error}</p>
            <p :if={@sidecar_health} class="text-xs opacity-80">
              Local sidecar process: {inspect(@sidecar_health[:status])} · live={inspect(
                @sidecar_health[:live]
              )}
              <%= if @sidecar_health[:last_error] do %>
                · {@sidecar_health[:last_error]}
              <% end %>
            </p>
          </div>
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
              <div class="stat-desc">Isthmus-owned delivery inboxes</div>
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

            <div class="flex flex-wrap items-center justify-between gap-2 pt-1">
              <h3 class="text-sm font-medium">Detected RNodes</h3>
              <div class="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  class="btn btn-outline btn-xs"
                  id="rns-rescan-rnodes"
                  phx-click="rescan_rnodes"
                >
                  Rescan USB
                </button>
                <button
                  type="button"
                  class={["btn btn-outline btn-xs", @firmware_catalog_loading && "loading"]}
                  id="refresh-firmware-catalog-btn"
                  phx-click="refresh_firmware_catalog"
                >
                  {if(@firmware_catalog_loading,
                    do: "Firmware list…",
                    else: "Refresh firmware list"
                  )}
                </button>
              </div>
            </div>
            <div
              :if={@detected_rnodes != []}
              class="overflow-x-auto rounded-box border border-base-300"
              id="rns-detected-rnodes"
            >
              <p class="text-xs opacity-70 px-4 pt-3">
                USB radios that answered the RNode detect handshake. Add one as an
                <span class="font-mono">RNodeInterface</span>
                in this config (Apply restarts the sidecar and opens the port).
                If MeshChatX already owns the radio as shared master, leave it there.
              </p>
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Radio</th>
                    <th>Port</th>
                    <th>Firmware</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={rnode <- @detected_rnodes} id={rnode_dom_id(rnode.path)}>
                    <td class="text-sm">
                      <span class="font-medium">{rnode.label}</span>
                      <span
                        :if={rnode_configured?(rnode.path, @config_interfaces)}
                        class="badge badge-sm badge-ghost ml-2"
                      >
                        in config
                      </span>
                      <span
                        :if={
                          IsthmusWeb.Admin.FirmwareOffer.newer?(
                            rnode_device(rnode),
                            @board_by_device,
                            @firmware_catalog
                          )
                        }
                        class="badge badge-sm badge-warning ml-2"
                        id={"#{rnode_dom_id(rnode.path)}-firmware-update"}
                      >
                        Firmware update
                      </span>
                    </td>
                    <td class="font-mono text-xs">{rnode.path}</td>
                    <td>
                      <.usb_firmware_offer
                        id={"usb-firmware-offer-#{rnode_dom_id(rnode.path)}"}
                        device_id={rnode.path}
                        kind={
                          IsthmusWeb.Admin.FirmwareOffer.flash_kind(
                            rnode_device(rnode),
                            @kind_by_device
                          ) || :rnode
                        }
                        running_kind={:rnode}
                        board_id={
                          IsthmusWeb.Admin.FirmwareOffer.board_id(
                            rnode_device(rnode),
                            @board_by_device
                          )
                        }
                        running_version={rnode[:firmware_version]}
                        connected={true}
                        catalog={@firmware_catalog}
                        flash_job={@firmware_flash}
                      />
                    </td>
                    <td class="text-right">
                      <button
                        type="button"
                        class="btn btn-secondary btn-xs"
                        id={"use-rnode-#{rnode_dom_id(rnode.path)}"}
                        phx-click="use_rnode"
                        phx-value-path={rnode.path}
                        disabled={rnode_configured?(rnode.path, @config_interfaces)}
                      >
                        Add as interface
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={@detected_rnodes == []} class="text-xs opacity-60" id="rns-detected-rnodes-empty">
              No USB RNode detected. Plug one in and Rescan USB, or Add interface
              and choose RNodeInterface.
            </p>

            <div class="flex flex-wrap items-center justify-between gap-2 pt-1">
              <h3 class="text-sm font-medium">Configured interfaces</h3>
              <button
                type="button"
                class="btn btn-secondary btn-sm"
                id="rns-open-iface-modal"
                phx-click="open_iface_modal"
              >
                Add interface
              </button>
            </div>
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
          </div>

          <div
            :if={@iface_modal}
            class="modal modal-open"
            role="dialog"
            id="rns-iface-modal"
          >
            <div class="modal-box max-w-lg">
              <h3 class="text-lg font-semibold">Add interface</h3>
              <p class="text-sm opacity-70 mt-1">
                Writes a block into Isthmus’s RNS config. Click Apply on the page
                to restart the sidecar and load it.
              </p>
              <.form
                for={@iface_form}
                id="rns-iface-form"
                phx-change="iface_validate"
                phx-submit="iface_add"
                class="mt-4 space-y-3"
              >
                <.input
                  field={@iface_form[:name]}
                  type="text"
                  label="Name"
                  required
                  autofocus
                  phx-mounted={JS.focus()}
                />
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
                <.input
                  :if={@iface_form[:type].value == "RNodeInterface"}
                  field={@iface_form[:port]}
                  type="text"
                  label="Serial port"
                  placeholder="/dev/ttyACM0"
                />
                <.input
                  :if={@iface_form[:type].value == "RNodeInterface"}
                  field={@iface_form[:frequency_mhz]}
                  type="text"
                  label="Frequency (MHz)"
                />
                <.input
                  :if={@iface_form[:type].value == "RNodeInterface"}
                  field={@iface_form[:bandwidth_khz]}
                  type="text"
                  label="Bandwidth (kHz)"
                />
                <.input
                  :if={@iface_form[:type].value == "RNodeInterface"}
                  field={@iface_form[:txpower]}
                  type="number"
                  label="TX (dBm)"
                  min="0"
                  max="37"
                />
                <.input
                  :if={@iface_form[:type].value == "RNodeInterface"}
                  field={@iface_form[:spreadingfactor]}
                  type="number"
                  label="Spreading factor"
                  min="5"
                  max="12"
                />
                <.input
                  :if={@iface_form[:type].value == "RNodeInterface"}
                  field={@iface_form[:codingrate]}
                  type="number"
                  label="Coding rate"
                  min="5"
                  max="8"
                />
                <div class="modal-action">
                  <button
                    class="btn btn-ghost btn-sm"
                    type="button"
                    id="rns-close-iface-modal"
                    phx-click="close_iface_modal"
                  >
                    Cancel
                  </button>
                  <button class="btn btn-primary btn-sm" type="submit" id="rns-iface-add">
                    Add interface
                  </button>
                </div>
              </.form>
            </div>
            <div class="modal-backdrop" phx-click="close_iface_modal"></div>
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

          <div class="space-y-2" id="rns-lxmf-destinations">
            <h2 class="text-lg font-medium">Registered LXMF destinations</h2>
            <p class="text-xs opacity-70 max-w-3xl">
              These are <strong class="font-medium">Isthmus-owned</strong>
              <span class="font-mono">lxmf.delivery</span>
              inboxes loaded in this sidecar — minted Reticulum
              <strong class="font-medium">proxies</strong>
              for groups and registrations, so Isthmus can receive LXMF and send as
              that identity. Attached MeshChatX hashes are not listed; Isthmus does
              not hold their keys. The tunnel destination is separate (Tunnels).
            </p>
            <%= if @lxmf_destinations == [] do %>
              <p class="text-sm opacity-70">
                None loaded yet. Register a primary or mint an RNS proxy on a group.
              </p>
            <% else %>
              <div class="overflow-x-auto rounded-box border border-base-300">
                <table class="table table-sm" id="rns-lxmf-destinations-table">
                  <thead>
                    <tr>
                      <th>Destination</th>
                      <th>Belongs to</th>
                      <th>Role</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- @lxmf_destinations} id={"rns-lxmf-#{row.dest}"}>
                      <td class="font-mono text-xs break-all">{row.dest}</td>
                      <td class="text-sm">
                        <%= if row.group_name do %>
                          <span class="font-medium">{row.group_name}</span>
                          <span class="badge badge-ghost badge-sm ml-1">
                            {AdminCopy.group_kind_label(row.group_kind)}
                          </span>
                        <% else %>
                          <span class="opacity-60">Not matched to a group</span>
                        <% end %>
                      </td>
                      <td class="text-sm opacity-80">{lxmf_role_label(row.role)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
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
