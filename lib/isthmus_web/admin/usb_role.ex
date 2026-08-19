defmodule IsthmusWeb.Admin.UsbRole do
  @moduledoc false
  use IsthmusWeb, :html

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.Ports
  alias Isthmus.Networks.UsbAssignments

  @role_options [
    {"Meshtastic companion", "meshtastic"},
    {"MeshCore companion", "companion"},
    {"Island config port", "bridge_cli"},
    {"Island mesh traffic port", "bridge_packet"},
    {"Reticulum RNode", "rnode"},
    {"Ignore this port", "ignore"}
  ]

  @firmware_options [
    {"Meshtastic companion", "meshtastic"},
    {"MeshCore companion", "companion"},
    {"Island tunnel radio", "island"},
    {"Reticulum RNode", "rnode"},
    {"Ignore this radio", "ignore"}
  ]

  attr :id, :string, required: true
  attr :device_id, :string, required: true
  attr :current, :atom, default: nil
  attr :source, :atom, default: nil

  def usb_firmware_picker(assigns) do
    assigns =
      assigns
      |> assign(:firmware_options, firmware_options(assigns.current))
      |> assign(:current_value, current_value(assigns.current))

    ~H"""
    <%= cond do %>
      <% @source == :env -> %>
        <p class="text-xs opacity-70" id={"#{@id}-env"}>
          Pinned by environment variable — USB role is not stored.
        </p>
      <% true -> %>
        <form
          id={@id}
          phx-submit="assign_usb_firmware"
          class="flex flex-nowrap items-center gap-2 [&_.fieldset]:contents [&_label]:contents"
        >
          <input type="hidden" name="device_id" value={@device_id} />
          <span class="label w-24 shrink-0 px-0">Firmware</span>
          <.input
            id={"#{@id}-kind"}
            name="kind"
            type="select"
            prompt="This radio is…"
            options={@firmware_options}
            value={@current_value}
            class="select select-sm h-8 min-h-8 w-56"
          />
          <button
            class="btn btn-primary btn-sm h-8 min-h-8 shrink-0"
            id={"#{@id}-apply"}
            type="submit"
          >
            Apply
          </button>
        </form>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :serial_number, :string, default: nil
  attr :vendor_id, :integer, default: nil
  attr :product_id, :integer, default: nil
  attr :current, :atom, default: nil
  attr :source, :atom, default: nil
  attr :compact, :boolean, default: false

  def usb_role_picker(assigns) do
    assigns =
      assigns
      |> assign(:role_options, role_options(assigns.current))
      |> assign(:current_value, current_value(assigns.current))

    ~H"""
    <%= cond do %>
      <% @source == :env -> %>
        <p class="text-xs opacity-70" id={"#{@id}-env"}>
          Pinned by environment variable — USB role is not stored.
        </p>
      <% true -> %>
        <form
          id={@id}
          phx-submit="assign_usb_role"
          class={[
            "flex flex-nowrap items-center gap-2 [&_.fieldset]:contents [&_label]:contents",
            @compact && "mt-1"
          ]}
        >
          <input type="hidden" name="path" value={@path} />
          <input type="hidden" name="serial" value={@serial_number || ""} />
          <input type="hidden" name="vendor_id" value={@vendor_id || ""} />
          <input type="hidden" name="product_id" value={@product_id || ""} />
          <span :if={not @compact} class="label w-24 shrink-0 px-0">USB role</span>
          <.input
            id={"#{@id}-role"}
            name="role"
            type="select"
            prompt="Use as…"
            options={@role_options}
            value={@current_value}
            class="select select-sm h-8 min-h-8 w-56"
          />
          <button
            class="btn btn-primary btn-sm h-8 min-h-8 shrink-0"
            id={"#{@id}-apply"}
            type="submit"
          >
            Apply
          </button>
        </form>
    <% end %>
    """
  end

  @spec apply_event(map()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_event(params) when is_map(params) do
    meta = port_meta(params)
    role = params["role"] || params[:role]

    cond do
      meta[:path] in [nil, ""] ->
        {:error, "Missing USB port path."}

      role in [nil, "", "clear"] ->
        _ = UsbAssignments.clear(meta)
        refresh_after(clear_flash())

      true ->
        case UsbAssignments.assign(meta, role) do
          :ok ->
            refresh_after(assigned_flash(role))

          {:error, :invalid_role} ->
            {:error, "Unknown USB role."}

          {:error, :missing_identity} ->
            {:error, "This USB port has no path or serial to remember."}

          {:error, reason} ->
            {:error, "Could not save USB role: #{inspect(reason)}"}
        end
    end
  end

  @spec firmware_kind(map()) :: atom() | nil
  def firmware_kind(device) when is_map(device) do
    roles =
      device
      |> Map.get(:ports, [])
      |> List.wrap()
      |> Enum.map(fn
        %{role: role} -> role
        port when is_map(port) -> port[:role]
        _ -> nil
      end)
      |> Kernel.++([device[:usb_role]])
      |> Enum.reject(&(&1 in [nil, :unassigned]))

    cond do
      device[:kind] == :meshtastic or :meshtastic in roles ->
        :meshtastic

      :companion in roles or device[:kind] == :companion ->
        :companion

      :bridge_cli in roles or :bridge_packet in roles or device[:kind] == :bridge_repeater ->
        :island

      :rnode in roles ->
        :rnode

      roles != [] and Enum.all?(roles, &(&1 == :ignore)) ->
        :ignore

      true ->
        nil
    end
  end

  @spec apply_firmware(map(), String.t() | atom()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_firmware(device, kind) when is_map(device) do
    ports = firmware_ports(device)

    cond do
      device[:ble?] == true ->
        {:error, "Bluetooth companions are not assigned as USB firmware."}

      ports == [] ->
        {:error, "No USB ports on this radio."}

      true ->
        case UsbAssignments.assign_firmware(ports, kind) do
          :ok -> refresh_after(firmware_flash(kind))
          {:error, :invalid_kind} -> {:error, "Unknown firmware type."}
          {:error, reason} -> {:error, "Could not save USB firmware: #{inspect(reason)}"}
        end
    end
  end

  defp firmware_ports(device) do
    from_card = card_ports(device)
    serials = from_card |> Enum.map(&blank(&1[:serial_number])) |> Enum.reject(&is_nil/1)

    listed =
      try do
        Ports.list()
        |> Enum.filter(fn port ->
          serial = blank(port[:serial_number])
          serial && serial in serials
        end)
      rescue
        _ -> []
      end

    if listed == [], do: from_card, else: listed
  end

  defp card_ports(device) do
    case device[:ports] do
      list when is_list(list) and list != [] ->
        Enum.flat_map(list, fn port ->
          path = port[:path] || port.path

          if usb_path?(path) do
            [
              %{
                path: path,
                serial_number: port[:serial_number] || device[:serial_number],
                vendor_id: port[:vendor_id] || device[:vendor_id],
                product_id: port[:product_id] || device[:product_id]
              }
            ]
          else
            []
          end
        end)

      _ ->
        if usb_path?(device[:path]) do
          [
            %{
              path: device.path,
              serial_number: device[:serial_number],
              vendor_id: device[:vendor_id],
              product_id: device[:product_id]
            }
          ]
        else
          []
        end
    end
  end

  defp usb_path?(path) when is_binary(path) do
    not String.starts_with?(path, "ble:") and not String.starts_with?(path, "BLE:")
  end

  defp usb_path?(_), do: false

  defp firmware_flash(kind) when is_atom(kind), do: firmware_flash(Atom.to_string(kind))

  defp firmware_flash("island") do
    "Island radio — config is the port that answered ver (else the lower ttyACM); traffic is the sibling."
  end

  defp firmware_flash("meshtastic") do
    "Using this radio as Meshtastic. Extra CDC ports are ignored."
  end

  defp firmware_flash("companion"), do: "Using this radio as a MeshCore companion."
  defp firmware_flash("rnode"), do: "Using this radio as a Reticulum RNode."
  defp firmware_flash("ignore"), do: "Ignoring this USB radio."
  defp firmware_flash("clear"), do: "Cleared USB firmware for this radio."
  defp firmware_flash(_), do: "Saved the USB firmware."

  defp refresh_after(flash) do
    case Discover.refresh() do
      {:ok, _} -> {:ok, flash}
      {:error, reason} -> {:error, "Saved the USB role, but rescan failed: #{inspect(reason)}"}
    end
  end

  defp port_meta(params) do
    %{
      path: blank(params["path"] || params[:path]),
      serial_number: blank(params["serial"] || params["serial_number"] || params[:serial]),
      vendor_id: to_int(params["vendor_id"] || params[:vendor_id]),
      product_id: to_int(params["product_id"] || params[:product_id])
    }
  end

  defp role_options(current) when current in [nil, :unassigned] do
    @role_options
  end

  defp role_options(_current), do: @role_options ++ [{"Clear role", "clear"}]

  defp firmware_options(current) when current in [nil, :unassigned] do
    @firmware_options
  end

  defp firmware_options(_current), do: @firmware_options ++ [{"Clear firmware", "clear"}]

  defp current_value(role) when is_atom(role) and role not in [nil, :unassigned],
    do: Atom.to_string(role)

  defp current_value(_), do: ""

  defp assigned_flash("meshtastic"), do: "Using this USB port as a Meshtastic companion."
  defp assigned_flash("companion"), do: "Using this USB port as a MeshCore companion."
  defp assigned_flash("bridge_cli"), do: "Using this USB port as the island config port."

  defp assigned_flash("bridge_packet"),
    do: "Using this USB port as the island mesh traffic port."

  defp assigned_flash("rnode"), do: "Using this USB port as a Reticulum RNode."
  defp assigned_flash("ignore"), do: "Ignoring this USB port."
  defp assigned_flash(_), do: "Saved the USB role."

  defp clear_flash, do: "Cleared the USB role. Choose a role to connect."

  defp blank(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_), do: nil

  defp to_int(n) when is_integer(n) and n >= 0, do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
