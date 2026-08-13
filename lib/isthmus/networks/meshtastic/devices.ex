defmodule Isthmus.Networks.Meshtastic.Devices do
  @moduledoc """
  USB inventory for Meshtastic companion radios.

  One serial port is one device. Runtime health comes from the named primary
  companion plus any extra companions started by `Meshtastic.Supervisor`.
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
          active?: boolean()
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

    (discover_paths ++ [primary_path] ++ running_paths)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn path ->
      meta = by_path[path] || synthetic_port(path, roles)
      health = health_by_port[path] || %{status: :disconnected, port: path}
      build_device(meta, health, path == primary_path)
    end)
    |> Enum.sort_by(&{if(&1.primary?, do: 0, else: 1), String.downcase(&1.label)})
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
      active?: health[:status] == :online
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
