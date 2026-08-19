defmodule Isthmus.Networks.MeshCore.Devices do
  @moduledoc """
  Groups USB ports into logical MeshCore **devices** with stable ids.

  A bridge repeater's two CDC interfaces share a USB serial number and become
  one device with roles `:bridge_cli` + `:bridge_packet`. Each companion USB
  port is its own device. Runtime health comes from the named primary companion
  plus extras started by `MeshCore.Supervisor`.
  """

  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.Ports

  @type port_role :: :companion | :bridge_cli | :bridge_packet | :ignore | :unassigned

  @type device :: %{
          id: String.t(),
          label: String.t(),
          serial_number: String.t() | nil,
          vendor_id: non_neg_integer() | nil,
          product_id: non_neg_integer() | nil,
          manufacturer: String.t() | nil,
          description: String.t() | nil,
          kind: :companion | :bridge_repeater | :unknown,
          ports: [%{path: String.t(), role: port_role()}],
          identity: %{name: String.t() | nil, public_key: String.t() | nil} | nil,
          companion?: boolean(),
          bridge_cli?: boolean(),
          bridge_packet?: boolean()
        }

  @doc """
  Build the device inventory from USB enumeration + Discover roles + live health.

  Options (tests):
  * `:ports` — override `Ports.list/0`
  * `:roles` — override `Discover.roles/0`
  * `:companion` / `:companions` / `:bridge_cli` / `:bridge_link` — health maps
  """
  def inventory(opts \\ []) do
    ports = Keyword.get_lazy(opts, :ports, &Ports.list/0)
    roles = Keyword.get_lazy(opts, :roles, &Discover.roles/0)

    companions =
      cond do
        Keyword.has_key?(opts, :companions) ->
          Keyword.get(opts, :companions) || []

        Keyword.has_key?(opts, :companion) ->
          List.wrap(Keyword.get(opts, :companion))

        true ->
          try do
            Companion.list_health()
          catch
            :exit, _ -> []
          end
      end

    bridge_cli = Keyword.get(opts, :bridge_cli, %{})
    bridge_link = Keyword.get(opts, :bridge_link, %{})

    meshtastic_paths = foreign_paths(roles)
    ports = Enum.reject(ports, fn p -> MapSet.member?(meshtastic_paths, p.path) end)

    path_roles = role_paths(roles)
    by_path = Map.new(ports, &{&1.path, &1})

    # Ensure role paths appear even when enumerate missed them (env override).
    by_path =
      Enum.reduce(path_roles, by_path, fn {path, _role}, acc ->
        Map.put_new(acc, path, synthetic_port(path, roles))
      end)

    probe_errors = roles[:probe_errors] || %{}

    usb =
      by_path
      |> Map.values()
      |> group_ports()
      |> Enum.map(
        &build_device(
          &1,
          path_roles,
          path_sources(roles),
          companions,
          bridge_cli,
          bridge_link,
          probe_errors
        )
      )

    (usb ++ ble_devices(companions))
    |> Enum.sort_by(&device_sort/1)
  end

  @doc "Stable device id from USB identity, falling back to a path key."
  def device_id(port_or_meta) when is_map(port_or_meta) do
    serial = blank(port_or_meta[:serial_number] || port_or_meta["serial_number"])
    vid = port_or_meta[:vendor_id] || port_or_meta["vendor_id"]
    pid = port_or_meta[:product_id] || port_or_meta["product_id"]
    path = port_or_meta[:path] || port_or_meta["path"]

    cond do
      is_binary(serial) and serial != "" and is_integer(vid) and is_integer(pid) ->
        "usb:#{hex4(vid)}:#{hex4(pid)}:#{serial}"

      is_binary(serial) and serial != "" ->
        "usb:serial:#{serial}"

      is_binary(path) and path != "" ->
        "path:#{path}"

      true ->
        "unknown"
    end
  end

  defp foreign_paths(roles) when is_map(roles) do
    meshtastic_paths(roles)
    |> MapSet.union(rnode_paths(roles))
  end

  defp meshtastic_paths(roles) when is_map(roles) do
    primary =
      case roles[:meshtastic] do
        %{path: path} when is_binary(path) -> [path]
        _ -> []
      end

    extras =
      Enum.flat_map(roles[:meshtastic_ports] || [], fn
        %{path: path} when is_binary(path) -> [path]
        path when is_binary(path) -> [path]
        _ -> []
      end)

    MapSet.new(primary ++ extras)
  end

  defp rnode_paths(roles) when is_map(roles) do
    primary =
      case roles[:rnode] do
        %{path: path} when is_binary(path) -> [path]
        _ -> []
      end

    extras =
      Enum.flat_map(roles[:rnode_ports] || [], fn
        %{path: path} when is_binary(path) -> [path]
        path when is_binary(path) -> [path]
        _ -> []
      end)

    MapSet.new(primary ++ extras)
  end

  defp role_paths(roles) when is_map(roles) do
    singletons =
      for {role, %{path: path}} <- roles,
          role in [:companion, :bridge_cli, :bridge_packet],
          is_binary(path) and path != "",
          into: %{},
          do: {path, normalize_role(role)}

    extras =
      for entry <- roles[:companion_ports] || [],
          path = companion_entry_path(entry),
          is_binary(path) and path != "",
          into: %{},
          do: {path, :companion}

    ignored =
      for entry <- roles[:ignored_ports] || [],
          path = companion_entry_path(entry),
          is_binary(path) and path != "",
          into: %{},
          do: {path, :ignore}

    extras
    |> Map.merge(ignored)
    |> Map.merge(singletons)
  end

  defp path_sources(roles) when is_map(roles) do
    singles =
      for {role, %{path: path, source: source}} <- roles,
          role in [:companion, :bridge_cli, :bridge_packet],
          is_binary(path) and path != "",
          into: %{},
          do: {path, source}

    lists =
      for key <- [:companion_ports, :ignored_ports],
          entry <- roles[key] || [],
          path = companion_entry_path(entry),
          is_binary(path) and path != "",
          into: %{},
          do: {path, entry[:source]}

    Map.merge(lists, singles)
  end

  defp companion_entry_path(%{path: path}), do: path
  defp companion_entry_path(path) when is_binary(path), do: path
  defp companion_entry_path(_), do: nil

  defp normalize_role(role) when is_atom(role), do: role
  defp normalize_role("companion"), do: :companion
  defp normalize_role("bridge_cli"), do: :bridge_cli
  defp normalize_role("bridge_packet"), do: :bridge_packet
  defp normalize_role("ignore"), do: :ignore
  defp normalize_role(_), do: :unassigned

  defp synthetic_port(path, roles) do
    detail =
      companion_detail(roles, path) ||
        roles
        |> Map.values()
        |> Enum.find_value(fn
          %{path: ^path, detail: %{} = d} -> d
          _ -> nil
        end)

    %{
      name: Path.basename(path),
      path: path,
      score: 0,
      reasons: ["role"],
      description: detail[:description],
      manufacturer: detail[:manufacturer],
      serial_number: detail[:serial_number],
      vendor_id: detail[:vendor_id],
      product_id: detail[:product_id]
    }
  end

  defp companion_detail(roles, path) do
    Enum.find_value(roles[:companion_ports] || [], fn
      %{path: ^path, detail: %{} = d} -> d
      _ -> nil
    end)
  end

  # Group CDC siblings that share a USB serial; otherwise one port = one device.
  defp group_ports(ports) do
    {with_serial, without} =
      Enum.split_with(ports, fn p -> is_binary(p.serial_number) and p.serial_number != "" end)

    grouped =
      with_serial
      |> Enum.group_by(&{&1.vendor_id, &1.product_id, &1.serial_number})
      |> Map.values()

    grouped ++ Enum.map(without, &[&1])
  end

  defp build_device(
         port_group,
         path_roles,
         path_sources,
         companions,
         bridge_cli,
         bridge_link,
         probe_errors
       ) do
    primary = List.first(port_group) || %{}

    ports =
      port_group
      |> Enum.map(fn p ->
        %{
          path: p.path,
          role: Map.get(path_roles, p.path, :unassigned),
          serial_number: blank(p[:serial_number]),
          vendor_id: p[:vendor_id],
          product_id: p[:product_id],
          source: Map.get(path_sources, p.path)
        }
      end)
      |> Enum.sort_by(&{role_rank(&1.role), &1.path})

    roles = MapSet.new(Enum.map(ports, & &1.role))
    companion? = MapSet.member?(roles, :companion)
    bridge_cli? = MapSet.member?(roles, :bridge_cli)
    bridge_packet? = MapSet.member?(roles, :bridge_packet)

    kind =
      cond do
        companion? and not (bridge_cli? or bridge_packet?) -> :companion
        bridge_cli? or bridge_packet? -> :bridge_repeater
        true -> :unknown
      end

    companion = Enum.find(List.wrap(companions), &match_port?(&1, ports))

    identity =
      if companion? and match_port?(companion, ports) do
        %{
          name: blank(companion[:self_name]),
          public_key: blank(companion[:self_ref])
        }
      end

    probe_error =
      port_group
      |> Enum.map(& &1.path)
      |> Enum.find_value(&Map.get(probe_errors, &1))

    %{
      id: device_id(primary),
      label: device_label(primary, kind, identity),
      serial_number: blank(primary[:serial_number]),
      vendor_id: primary[:vendor_id],
      product_id: primary[:product_id],
      manufacturer: blank(primary[:manufacturer]),
      description: blank(primary[:description]),
      kind: kind,
      ports: ports,
      identity: identity,
      ble?: false,
      ble_address: nil,
      companion?: companion?,
      bridge_cli?: bridge_cli?,
      bridge_packet?: bridge_packet?,
      probe_error: probe_error,
      active_companion?:
        companion? and match_port?(companion, ports) and companion[:status] == :online,
      active_bridge_cli?:
        bridge_cli? and match_port?(bridge_cli, ports) and bridge_cli[:status] == :online,
      active_bridge_link?:
        bridge_packet? and match_port?(bridge_link, ports) and bridge_link[:status] == :online,
      companion_health: if(companion? and is_map(companion), do: companion),
      bridge_cli_health: if(bridge_cli? and match_port?(bridge_cli, ports), do: bridge_cli),
      bridge_link_health: if(bridge_packet? and match_port?(bridge_link, ports), do: bridge_link),
      channels:
        if(is_map(companion) and is_binary(companion[:port]),
          do: Companion.list_channels(companion[:port]),
          else: []
        )
    }
  end

  defp ble_devices(companions) do
    companions
    |> List.wrap()
    |> Enum.filter(fn h ->
      is_binary(h[:port]) and String.starts_with?(h[:port], "ble:")
    end)
    |> Enum.map(&build_ble_device/1)
  end

  defp build_ble_device(health) do
    address = health[:ble_address] || Companion.ble_address(health[:port])
    name = blank(health[:self_name]) || blank(health[:name])
    online? = health[:status] == :online

    %{
      id: health[:port],
      label: name || "MeshCore Bluetooth",
      serial_number: nil,
      vendor_id: nil,
      product_id: nil,
      manufacturer: "Bluetooth",
      description: address,
      kind: :companion,
      ports: [%{path: health[:port], role: :companion}],
      identity:
        if(health[:self_ref],
          do: %{name: name, public_key: blank(health[:self_ref])},
          else: nil
        ),
      ble?: true,
      ble_address: address,
      companion?: true,
      bridge_cli?: false,
      bridge_packet?: false,
      probe_error: nil,
      active_companion?: online?,
      active_bridge_cli?: false,
      active_bridge_link?: false,
      companion_health: health,
      bridge_cli_health: nil,
      bridge_link_health: nil,
      channels: Companion.list_channels(health[:port])
    }
  end

  defp match_port?(health, ports) when is_map(health) do
    path = health[:port]
    is_binary(path) and Enum.any?(ports, &(&1.path == path))
  end

  defp match_port?(_, _), do: false

  defp device_label(primary, kind, identity) do
    cond do
      is_map(identity) and is_binary(identity.name) and identity.name != "" ->
        identity.name

      is_binary(primary[:description]) and primary[:description] != "" ->
        primary[:description]

      is_binary(primary[:manufacturer]) and primary[:manufacturer] != "" ->
        primary[:manufacturer]

      kind == :companion ->
        "Companion"

      kind == :bridge_repeater ->
        "Bridge repeater"

      true ->
        "USB device"
    end
  end

  defp device_sort(%{kind: kind, label: label}) do
    rank =
      case kind do
        :companion -> 0
        :bridge_repeater -> 1
        _ -> 2
      end

    {rank, String.downcase(label)}
  end

  defp role_rank(:companion), do: 0
  defp role_rank(:bridge_cli), do: 1
  defp role_rank(:bridge_packet), do: 2
  defp role_rank(:ignore), do: 8
  defp role_rank(_), do: 9

  defp hex4(n) when is_integer(n),
    do: n |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()

  defp blank(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp blank(_), do: nil
end
