defmodule Isthmus.Networks.Meshtastic.Devices do
  @moduledoc """
  Inventory for Meshtastic companion radios (USB serial and Bluetooth).

  One serial port is one USB device. BLE companions are keyed `ble:<address>`.
  Runtime health comes from the named primary companion plus extras started by
  `Meshtastic.Supervisor`.
  """

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.Devices, as: MeshDevices
  alias Isthmus.Networks.MeshCore.Ports
  alias Isthmus.Networks.Meshtastic.Companion

  @type device :: %{
          id: String.t(),
          label: String.t(),
          path: String.t() | nil,
          kind: :meshtastic,
          serial_number: String.t() | nil,
          vendor_id: non_neg_integer() | nil,
          product_id: non_neg_integer() | nil,
          manufacturer: String.t() | nil,
          description: String.t() | nil,
          health: map(),
          channels: [map()],
          primary?: boolean(),
          active?: boolean(),
          ble?: boolean(),
          ble_address: String.t() | nil
        }

  def inventory(opts \\ []) do
    ports = Keyword.get_lazy(opts, :ports, &Ports.list/0)
    roles = Keyword.get_lazy(opts, :roles, &Discover.roles/0)
    healths = Keyword.get_lazy(opts, :healths, &Companion.list_health/0)

    by_path = Map.new(ports, &{&1.path, &1})
    health_by_port = Map.new(healths, fn h -> {h[:port], h} end)

    discover_paths =
      (roles[:meshtastic_ports] || [])
      |> Enum.map(fn
        %{path: path} -> path
        path when is_binary(path) -> path
        _ -> nil
      end)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    primary_path =
      case roles[:meshtastic] do
        %{path: path} when is_binary(path) -> path
        _ -> nil
      end

    running_paths =
      healths
      |> Enum.map(& &1[:port])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    usb =
      (discover_paths ++ [primary_path] ++ running_paths)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&String.starts_with?(&1, "ble:"))
      |> Enum.uniq()
      |> Enum.map(fn path ->
        meta = by_path[path] || synthetic_port(path, roles)
        health = health_by_port[path] || %{status: :disconnected, port: path}
        build_device(meta, health, path == primary_path)
      end)

    (usb ++ ble_devices(healths))
    |> Enum.sort_by(
      &{if(&1.primary?, do: 0, else: 1), if(&1.ble?, do: 1, else: 0), String.downcase(&1.label)}
    )
  end

  defp ble_devices(healths) do
    healths
    |> List.wrap()
    |> Enum.filter(fn h ->
      is_binary(h[:port]) and String.starts_with?(h[:port], "ble:")
    end)
    |> Enum.map(&build_ble_device/1)
  end

  defp build_ble_device(health) do
    address = health[:ble_address] || Companion.ble_address(health[:port])
    node = health[:node_id]
    name = blank(health[:name])

    label =
      cond do
        is_binary(node) and node != "" -> "!" <> node
        is_binary(name) -> name
        true -> "Meshtastic Bluetooth"
      end

    %{
      id: health[:port],
      label: label,
      path: health[:port],
      kind: :meshtastic,
      serial_number: nil,
      vendor_id: nil,
      product_id: nil,
      manufacturer: "Bluetooth",
      description: address,
      health: health,
      channels: Companion.list_channels(health[:port]),
      primary?: false,
      active?: health[:status] == :online,
      ble?: true,
      ble_address: address
    }
  end

  defp synthetic_port(path, roles) do
    detail =
      case roles[:meshtastic] do
        %{path: ^path, detail: %{} = d} ->
          d

        _ ->
          Enum.find_value(roles[:meshtastic_ports] || [], fn
            %{path: ^path, detail: %{} = d} -> d
            _ -> nil
          end)
      end || %{}

    %{
      path: path,
      description: detail[:description],
      manufacturer: detail[:manufacturer],
      serial_number: detail[:serial_number],
      vendor_id: detail[:vendor_id],
      product_id: detail[:product_id]
    }
  end

  defp build_device(meta, health, primary?) do
    node = health[:node_id]
    label = device_label(meta, node)

    %{
      id: MeshDevices.device_id(meta),
      label: label,
      path: meta[:path] || health[:port],
      kind: :meshtastic,
      serial_number: blank(meta[:serial_number]),
      vendor_id: meta[:vendor_id],
      product_id: meta[:product_id],
      manufacturer: blank(meta[:manufacturer]),
      description: blank(meta[:description]),
      health: health,
      channels: Companion.list_channels(health[:port]),
      primary?: primary? or health[:primary?] == true,
      active?: health[:status] == :online,
      ble?: false,
      ble_address: nil
    }
  end

  defp device_label(_meta, node) when is_binary(node) and node != "", do: "!" <> node

  defp device_label(meta, _) do
    cond do
      is_binary(meta[:description]) and meta[:description] != "" -> meta[:description]
      is_binary(meta[:manufacturer]) and meta[:manufacturer] != "" -> meta[:manufacturer]
      is_binary(meta[:path]) -> Path.basename(meta[:path])
      true -> "Meshtastic companion"
    end
  end

  defp blank(""), do: nil
  defp blank(v) when is_binary(v), do: v
  defp blank(_), do: nil
end
