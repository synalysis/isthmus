defmodule Isthmus.Networks.UsbAssignments do
  @moduledoc """
  Persisted USB serial roles (Policy), keyed by USB identity when present.

  MeshCore and Meshtastic share CP210x/CH340/ACM chips, and opening those
  ports resets ESP32 boards — so Isthmus does not guess firmware. The admin
  assigns a role; Discover reuses it across restart and Rescan.
  """

  alias Isthmus.Policy

  @policy_key "usb_port_roles"
  @roles [:meshtastic, :companion, :bridge_cli, :bridge_packet, :rnode, :ignore]

  @type role :: :meshtastic | :companion | :bridge_cli | :bridge_packet | :rnode | :ignore
  @type entry :: %{String.t() => term()}
  @type usb_port :: map()

  @spec roles() :: [role()]
  def roles, do: @roles

  @spec list() :: [entry()]
  def list do
    Policy.get(@policy_key)
    |> normalize_list()
  rescue
    _ -> []
  end

  @spec role_for(usb_port()) :: role() | nil
  def role_for(port) when is_map(port), do: role_for(port, list())

  @spec role_for(usb_port(), [entry()]) :: role() | nil
  def role_for(port, entries) when is_map(port) and is_list(entries) do
    case Enum.find(entries, &matches?(&1, port)) do
      %{"role" => role} -> parse_role(role)
      _ -> nil
    end
  end

  @spec assign(usb_port(), role() | String.t()) :: :ok | {:error, term()}
  def assign(port, role) when is_map(port) do
    case parse_role(role) do
      nil ->
        {:error, :invalid_role}

      parsed ->
        entry = build_entry(port, parsed)

        if entry["path"] in [nil, ""] and entry["serial"] in [nil, ""] do
          {:error, :missing_identity}
        else
          persist([entry | Enum.reject(list(), &matches?(&1, port))])
        end
    end
  end

  @spec clear(usb_port()) :: :ok
  def clear(port) when is_map(port) do
    persist(Enum.reject(list(), &matches?(&1, port)))
  end

  @firmware_kinds [:meshtastic, :companion, :island, :rnode, :ignore]

  @doc """
  Plan per-port roles after the user chooses firmware for a radio.

  Dual-CDC island radios: CLI is the port that answers `ver`, otherwise the
  lower `ttyACM` (USB CDC 0). The sibling is mesh traffic. A port that
  answers as packet traffic is treated as the traffic CDC.
  """
  @spec plan_firmware([usb_port()], atom() | String.t(), keyword()) ::
          [{usb_port(), role()}] | :clear | {:error, term()}
  def plan_firmware(ports, kind, opts \\ []) when is_list(ports) do
    ports = Enum.filter(ports, &(is_binary(port_path(&1)) and port_path(&1) != ""))
    probe = Keyword.get(opts, :probe, &Isthmus.Networks.MeshCore.Discover.probe_for/3)

    case parse_firmware_kind(kind) do
      :clear -> :clear
      nil -> {:error, :invalid_kind}
      :ignore -> Enum.map(ports, &{&1, :ignore})
      :island -> plan_island(ports, probe)
      firmware -> plan_single(ports, firmware, probe)
    end
  end

  @spec assign_firmware([usb_port()], atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def assign_firmware(ports, kind, opts \\ []) when is_list(ports) do
    case plan_firmware(ports, kind, opts) do
      {:error, reason} ->
        {:error, reason}

      :clear ->
        persist(Enum.reject(list(), fn entry -> Enum.any?(ports, &matches?(entry, &1)) end))

      pairs ->
        assign_many(pairs)
    end
  end

  defp plan_island(ports, probe) do
    probed = Enum.map(ports, fn port -> {port, safe_probe(probe, port, :island)} end)

    cond do
      cli = find_probed(probed, :bridge_cli) ->
        island_with_cli(ports, cli)

      packet = find_probed(probed, :bridge_packet) ->
        rest = Enum.reject(ports, &(port_path(&1) == port_path(packet)))
        [{packet, :bridge_packet} | Enum.map(rest, &{&1, :bridge_cli})]

      true ->
        island_by_acm_order(ports)
    end
  end

  defp find_probed(probed, role) do
    case Enum.find(probed, fn {_, hit} -> hit == role end) do
      {port, _} -> port
      nil -> nil
    end
  end

  defp island_with_cli(ports, cli) do
    rest = Enum.reject(ports, &(port_path(&1) == port_path(cli)))
    [{cli, :bridge_cli} | Enum.map(rest, &{&1, :bridge_packet})]
  end

  defp island_by_acm_order(ports) do
    case Enum.sort_by(ports, &port_path/1) do
      [] -> []
      [one] -> [{one, :bridge_cli}]
      [cli | rest] -> [{cli, :bridge_cli} | Enum.map(rest, &{&1, :bridge_packet})]
    end
  end

  defp plan_single(ports, role, probe) do
    probed = Enum.map(ports, fn port -> {port, safe_probe(probe, port, role)} end)
    hits = for {port, ^role} <- probed, do: {port, role}

    cond do
      hits != [] ->
        hit_paths = MapSet.new(Enum.map(hits, fn {port, _} -> port_path(port) end))

        misses =
          ports
          |> Enum.reject(&MapSet.member?(hit_paths, port_path(&1)))
          |> Enum.map(&{&1, :ignore})

        hits ++ misses

      true ->
        case Enum.sort_by(ports, &port_path/1) do
          [] -> []
          [one | rest] -> [{one, role} | Enum.map(rest, &{&1, :ignore})]
        end
    end
  end

  defp safe_probe(probe, port, kind) do
    path = port_path(port)

    case probe.(path, port, kind) do
      role when is_atom(role) -> role
      {:error, _} -> :unknown
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  defp assign_many(pairs) do
    ports = Enum.map(pairs, fn {port, _} -> port end)
    rest = Enum.reject(list(), fn entry -> Enum.any?(ports, &matches?(entry, &1)) end)
    entries = Enum.map(pairs, fn {port, role} -> build_entry(port, role) end)
    persist(entries ++ rest)
  end

  defp parse_firmware_kind(kind) when kind in @firmware_kinds, do: kind
  defp parse_firmware_kind(:clear), do: :clear

  defp parse_firmware_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "meshtastic" -> :meshtastic
      "companion" -> :companion
      "island" -> :island
      "rnode" -> :rnode
      "ignore" -> :ignore
      "clear" -> :clear
      _ -> nil
    end
  end

  defp parse_firmware_kind(_), do: nil

  defp port_path(port) when is_map(port), do: normalize_path(port[:path] || port["path"])
  defp port_path(_), do: nil

  @doc false
  def matches?(entry, port) when is_map(entry) and is_map(port) do
    entry_path = normalize_path(entry["path"] || entry[:path])
    port_path = normalize_path(port[:path] || port["path"])
    entry_serial = blank(entry["serial"] || entry[:serial])
    port_serial = blank(port[:serial_number] || port["serial_number"] || port["serial"])

    path_hit = is_binary(entry_path) and is_binary(port_path) and entry_path == port_path

    # Dual-CDC boards share a USB serial. Never apply one stored role to every
    # sibling path. Serial-only matching is for entries that have no path.
    serial_only =
      is_nil(entry_path) and is_binary(entry_serial) and is_binary(port_serial) and
        entry_serial == port_serial and vid_pid_compatible?(entry, port)

    path_hit or serial_only
  end

  def matches?(_, _), do: false

  defp vid_pid_compatible?(entry, port) do
    entry_vid = to_int(entry["vendor_id"] || entry[:vendor_id])
    entry_pid = to_int(entry["product_id"] || entry[:product_id])
    port_vid = to_int(port[:vendor_id] || port["vendor_id"])
    port_pid = to_int(port[:product_id] || port["product_id"])

    cond do
      is_integer(entry_vid) and is_integer(entry_pid) and is_integer(port_vid) and
          is_integer(port_pid) ->
        entry_vid == port_vid and entry_pid == port_pid

      true ->
        true
    end
  end

  defp build_entry(port, role) do
    %{
      "path" => normalize_path(port[:path] || port["path"]),
      "serial" => blank(port[:serial_number] || port["serial_number"] || port["serial"]),
      "vendor_id" => to_int(port[:vendor_id] || port["vendor_id"]),
      "product_id" => to_int(port[:product_id] || port["product_id"]),
      "role" => Atom.to_string(role)
    }
  end

  defp persist(entries) do
    case Policy.put(@policy_key, entries) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> :ok
  end

  defp normalize_list(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{} = entry ->
        role = parse_role(entry["role"] || entry[:role])
        path = normalize_path(entry["path"] || entry[:path])
        serial = blank(entry["serial"] || entry[:serial])

        if is_nil(role) or (is_nil(path) and is_nil(serial)) do
          []
        else
          [
            %{
              "path" => path,
              "serial" => serial,
              "vendor_id" => to_int(entry["vendor_id"] || entry[:vendor_id]),
              "product_id" => to_int(entry["product_id"] || entry[:product_id]),
              "role" => Atom.to_string(role)
            }
          ]
        end

      _ ->
        []
    end)
  end

  defp normalize_list(_), do: []

  defp parse_role(role) when role in @roles, do: role

  defp parse_role(role) when is_binary(role) do
    case String.trim(role) do
      "meshtastic" -> :meshtastic
      "companion" -> :companion
      "bridge_cli" -> :bridge_cli
      "bridge_packet" -> :bridge_packet
      "rnode" -> :rnode
      "ignore" -> :ignore
      _ -> nil
    end
  end

  defp parse_role(_), do: nil

  defp normalize_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_path(_), do: nil

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
