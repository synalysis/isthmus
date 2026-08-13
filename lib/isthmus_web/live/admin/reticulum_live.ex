defmodule IsthmusWeb.Admin.ReticulumLive do
  use IsthmusWeb, :live_view

  alias IsthmusWeb.Admin.ReticulumHTML

  alias Isthmus.Networks.Reticulum
  alias Isthmus.Networks.Reticulum.ConfigFile
  alias Isthmus.Networks.Reticulum.RNode
  alias Isthmus.Registrations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Reticulum")
     |> assign(:iface_form, blank_iface_form())
     |> assign(:iface_modal, false)
     |> assign(:sidecar_health, %{status: :unknown})
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  @impl true
  def handle_event("iface_validate", %{"iface" => params}, socket) do
    {:noreply, assign(socket, :iface_form, to_form(maybe_rnode_defaults(params), as: :iface))}
  end

  def handle_event("open_iface_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:iface_form, blank_iface_form())
     |> assign(:iface_modal, true)}
  end

  def handle_event("close_iface_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:iface_modal, false)
     |> assign(:iface_form, blank_iface_form())}
  end

  def handle_event("iface_add", %{"iface" => params}, socket) do
    attrs = iface_attrs(params)

    case Reticulum.add_config_interface(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:iface_modal, false)
         |> assign(:iface_form, blank_iface_form())
         |> put_flash(:info, "Interface added to config. Click Apply to reload the sidecar.")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add interface: #{format_err(reason)}")}
    end
  end

  def handle_event("use_rnode", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:iface_form, to_form(RNode.default_form_params(path), as: :iface))
     |> assign(:iface_modal, true)}
  end

  def handle_event("rescan_rnodes", _params, socket) do
    case Isthmus.Networks.MeshCore.Discover.refresh() do
      {:ok, _roles} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rescanned USB serial ports.")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
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

        {:error, :timeout} ->
          socket
          |> assign(:status, nil)
          |> assign(
            :error,
            "RNS sidecar not responding (status timed out). Announces may be stalled — restart Isthmus or click Apply to respawn the sidecar."
          )

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

    health =
      try do
        Reticulum.health()
      catch
        :exit, _ -> %{status: :unknown}
      end

    socket
    |> assign(:config_path, Reticulum.config_path())
    |> assign(:config_interfaces, config_ifaces)
    |> assign(:detected_rnodes, Reticulum.detected_rnodes())
    |> assign(:lxmf_destinations, lxmf_destination_rows(socket.assigns[:status]))
    |> assign(:share_instance, share?)
    |> assign(:sidecar_health, health)
    |> assign(:allowed_types, ConfigFile.allowed_types())
  end

  defp iface_attrs(%{"type" => "RNodeInterface"} = params) do
    Map.merge(
      %{
        name: params["name"],
        type: "RNodeInterface",
        enabled: true
      },
      RNode.config_from_form(params)
    )
  end

  defp iface_attrs(params) do
    %{
      name: params["name"],
      type: params["type"],
      enabled: true,
      target_host: params["target_host"],
      target_port: params["target_port"],
      listen_ip: params["listen_ip"],
      listen_port: params["listen_port"]
    }
  end

  defp maybe_rnode_defaults(%{"type" => "RNodeInterface"} = params) do
    defaults = RNode.default_form_params(params["port"] || "")

    Enum.reduce(defaults, params, fn {key, value}, acc ->
      if String.trim(to_string(acc[key] || "")) == "" do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp maybe_rnode_defaults(params), do: params

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

  defp format_err(:missing_port), do: "RNode needs a serial port"
  defp format_err(:invalid_frequency), do: "RNode frequency must be 137–3000 MHz"
  defp format_err(:invalid_bandwidth), do: "RNode bandwidth must be 7.8–1625 kHz"
  defp format_err(:invalid_txpower), do: "RNode TX power must be 0–37 dBm"
  defp format_err(:invalid_spreadingfactor), do: "RNode spreading factor must be 5–12"
  defp format_err(:invalid_codingrate), do: "RNode coding rate must be 5–8"
  defp format_err(:unsupported_type), do: "Unsupported interface type"
  defp format_err(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_err(reason), do: inspect(reason)

  defp lxmf_destination_rows(%{registered: registered}) when is_list(registered) do
    by_ref = reticulum_leg_index()

    Enum.map(registered, fn dest ->
      hex = dest |> to_string() |> String.downcase()

      case Map.get(by_ref, hex) do
        {group, leg} ->
          %{
            dest: dest,
            group_name: group.display_name,
            group_kind: group.kind,
            role: leg.role
          }

        _ ->
          %{dest: dest, group_name: nil, group_kind: nil, role: nil}
      end
    end)
  end

  defp lxmf_destination_rows(_), do: []

  defp reticulum_leg_index do
    for group <- Registrations.list_all(),
        group.status == "active",
        leg <- group.legs || [],
        leg.network == "reticulum",
        is_binary(leg.identity_ref),
        into: %{} do
      {String.downcase(leg.identity_ref), {group, leg}}
    end
  rescue
    _ -> %{}
  end

  @impl true
  def render(assigns), do: ReticulumHTML.page(assigns)
end
