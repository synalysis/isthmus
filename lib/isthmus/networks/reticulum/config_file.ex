defmodule Isthmus.Networks.Reticulum.ConfigFile do
  @moduledoc """
  Comment-preserving reader/writer for Isthmus's own Reticulum INI config
  (`ISTHMUS_RNS_CONFIGDIR/config`).

  Strategy: keep the file as ordered segments. Only rewrite the `[interfaces]`
  body when adding/removing `[[Name]]` blocks, and only replace the active
  assignment line when changing a `[reticulum]` key. Surrounding comments and
  unrelated sections are left intact.
  """

  @allowed_types ~w(AutoInterface TCPClientInterface TCPServerInterface)

  def path do
    configdir =
      System.get_env("ISTHMUS_RNS_CONFIGDIR") ||
        Path.expand("~/.isthmus/reticulum")

    Path.join(configdir, "config")
  end

  def allowed_types, do: @allowed_types

  def read(path \\ path()) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_interfaces(path \\ path()) do
    with {:ok, text} <- read(path),
         {:ok, doc} <- parse(text) do
      {:ok, Enum.map(doc.interfaces, &block_to_map/1)}
    end
  end

  @doc """
  Add an interface block. Attrs:

  * `:name` (required)
  * `:type` — AutoInterface | TCPClientInterface | TCPServerInterface
  * `:enabled` — boolean (default true)
  * `:target_host`, `:target_port` — TCP client
  * `:listen_ip`, `:listen_port` — TCP server
  """
  def add_interface(attrs, path \\ path()) when is_map(attrs) do
    name =
      case Map.get(attrs, :name) || Map.get(attrs, "name") do
        n when is_binary(n) -> String.trim(n)
        other -> other
      end

    type = attrs |> Map.get(:type) || Map.get(attrs, "type")
    attrs = Map.put(attrs, :name, name)

    with :ok <- validate_name(name),
         :ok <- validate_type(type),
         {:ok, text} <- read(path),
         {:ok, doc} <- parse(text),
         :ok <- ensure_name_free(doc, name) do
      block = render_interface_block(attrs)
      doc = %{doc | interfaces: doc.interfaces ++ [block]}
      write_parsed(path, doc)
    end
  end

  @doc "Read the active `share_instance` value from `[reticulum]` (defaults to true if unset)."
  def share_instance?(path \\ path()) do
    case get_reticulum_option("share_instance", path) do
      {:ok, v} when is_binary(v) ->
        String.downcase(v) in ~w(yes true 1 on)

      _ ->
        true
    end
  end

  def get_reticulum_option(key, path \\ path()) when is_binary(key) do
    with {:ok, text} <- read(path) do
      lines = String.split(text, ~r/\r?\n/, trim: false)

      case Enum.find_index(lines, &(&1 =~ ~r/^\s*\[reticulum\]\s*$/)) do
        nil ->
          {:error, :section_missing}

        start_idx ->
          end_idx =
            case Enum.find_index(Enum.drop(lines, start_idx + 1), &top_level_section?/1) do
              nil -> length(lines)
              j -> start_idx + 1 + j
            end

          Enum.slice(lines, start_idx..(end_idx - 1))
          |> Enum.find_value(fn line ->
            if assignment_line?(line, key) do
              case String.split(String.trim(line), "=", parts: 2) do
                [_, v] -> {:ok, String.trim(v)}
                _ -> nil
              end
            end
          end) || {:error, :key_missing}
      end
    end
  end

  def remove_interface(name, path \\ path()) when is_binary(name) do
    with {:ok, text} <- read(path),
         {:ok, doc} <- parse(text) do
      {kept, removed} = Enum.split_with(doc.interfaces, &(&1.name != name))

      if removed == [] do
        {:error, :not_found}
      else
        write_parsed(path, %{doc | interfaces: kept})
      end
    end
  end

  @doc """
  Set `enabled` (or legacy `interface_enabled`) on an interface block without
  rewriting the rest of the block.
  """
  def set_interface_enabled(name, enabled?, path \\ path())
      when is_binary(name) and is_boolean(enabled?) do
    value = if(enabled?, do: "Yes", else: "No")

    with {:ok, text} <- read(path),
         {:ok, doc} <- parse(text) do
      case Enum.find_index(doc.interfaces, &(&1.name == name)) do
        nil ->
          {:error, :not_found}

        idx ->
          block = Enum.at(doc.interfaces, idx)
          lines = set_block_enabled_lines(block.lines, value)
          interfaces = List.replace_at(doc.interfaces, idx, %{block | lines: lines})
          write_parsed(path, %{doc | interfaces: interfaces})
      end
    end
  end

  @doc """
  Set a `[reticulum]` key on its existing assignment line (preserves comments).
  Creates the key under `[reticulum]` if missing.
  """
  def set_reticulum_option(key, value, path \\ path())
      when is_binary(key) and is_binary(value) do
    with {:ok, text} <- read(path) do
      case replace_section_assignment(text, "reticulum", key, value) do
        {:ok, updated} -> atomic_write(path, updated)
        {:error, :section_missing} -> {:error, :section_missing}
        {:error, :key_missing} -> insert_reticulum_assignment(text, key, value, path)
      end
    end
  end

  def set_share_instance(enabled?, path \\ path()) when is_boolean(enabled?) do
    set_reticulum_option("share_instance", if(enabled?, do: "Yes", else: "No"), path)
  end

  # --- parse / write ----------------------------------------------------------

  defp parse(text) when is_binary(text) do
    lines = String.split(text, ~r/\r?\n/, trim: false)

    case split_interfaces_region(lines) do
      {:ok, before, header, preamble, iface_lines, after_lines} ->
        interfaces = parse_interface_blocks(iface_lines)

        {:ok,
         %{
           before: before,
           header: header,
           preamble: preamble,
           interfaces: interfaces,
           after: after_lines
         }}

      {:error, _} = err ->
        err
    end
  end

  defp split_interfaces_region(lines) do
    case Enum.find_index(lines, &interface_section_header?/1) do
      nil ->
        {:error, :no_interfaces_section}

      idx ->
        {before, rest} = Enum.split(lines, idx)
        [header | after_header] = rest

        {iface_region, after_section} =
          case Enum.find_index(after_header, &top_level_section?/1) do
            nil -> {after_header, []}
            j -> Enum.split(after_header, j)
          end

        {preamble, iface_lines} = split_preamble(iface_region)
        {:ok, before, header, preamble, iface_lines, after_section}
    end
  end

  defp split_preamble(lines) do
    case Enum.find_index(lines, &interface_block_header?/1) do
      nil -> {lines, []}
      idx -> Enum.split(lines, idx)
    end
  end

  defp parse_interface_blocks(lines) do
    lines
    |> chunk_interface_blocks()
    |> Enum.map(fn [header | body] ->
      name =
        case Regex.run(~r/^\s*\[\[([^\]]+)\]\]\s*$/, header) do
          [_, n] -> String.trim(n)
          _ -> "unknown"
        end

      %{name: name, lines: [header | body]}
    end)
  end

  defp chunk_interface_blocks(lines) do
    Enum.reduce(lines, {[], nil}, fn line, {acc, current} ->
      if interface_block_header?(line) do
        acc = if current, do: acc ++ [Enum.reverse(current)], else: acc
        {acc, [line]}
      else
        if current do
          {acc, [line | current]}
        else
          {acc, nil}
        end
      end
    end)
    |> then(fn {acc, current} ->
      if current, do: acc ++ [Enum.reverse(current)], else: acc
    end)
  end

  defp write_parsed(path, doc) do
    iface_lines = Enum.flat_map(doc.interfaces, & &1.lines)

    text =
      (doc.before ++ [doc.header] ++ doc.preamble ++ iface_lines ++ doc.after)
      |> Enum.join("\n")
      |> ensure_trailing_nl()

    atomic_write(path, text)
  end

  defp atomic_write(path, text) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    backup = path <> ".bak"
    if File.exists?(path), do: File.copy!(path, backup)
    tmp = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp, text),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp replace_section_assignment(text, section, key, value) do
    lines = String.split(text, ~r/\r?\n/, trim: false)

    case Enum.find_index(lines, &(&1 =~ ~r/^\s*\[#{Regex.escape(section)}\]\s*$/)) do
      nil ->
        {:error, :section_missing}

      start_idx ->
        end_idx =
          Enum.find_index(Enum.drop(lines, start_idx + 1), &top_level_section?/1)
          |> case do
            nil -> length(lines)
            j -> start_idx + 1 + j
          end

        section_range = start_idx..(end_idx - 1)

        case Enum.find_index(Enum.slice(lines, section_range), &assignment_line?(&1, key)) do
          nil ->
            {:error, :key_missing}

          rel ->
            abs = start_idx + rel
            indent = leading_ws(Enum.at(lines, abs))
            updated = List.replace_at(lines, abs, "#{indent}#{key} = #{value}")
            {:ok, Enum.join(updated, "\n") |> ensure_trailing_nl()}
        end
    end
  end

  defp insert_reticulum_assignment(text, key, value, path) do
    lines = String.split(text, ~r/\r?\n/, trim: false)

    case Enum.find_index(lines, &(&1 =~ ~r/^\s*\[reticulum\]\s*$/)) do
      nil ->
        {:error, :section_missing}

      idx ->
        updated = List.insert_at(lines, idx + 1, "  #{key} = #{value}")
        atomic_write(path, Enum.join(updated, "\n") |> ensure_trailing_nl())
    end
  end

  defp assignment_line?(line, key) do
    # Active assignment only — skip commented lines.
    String.match?(line, ~r/^\s*#{Regex.escape(key)}\s*=/)
  end

  defp leading_ws(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, ws] -> ws
      _ -> "  "
    end
  end

  defp ensure_trailing_nl(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  defp interface_section_header?(line), do: String.match?(line, ~r/^\s*\[interfaces\]\s*$/)

  defp top_level_section?(line),
    do: String.match?(line, ~r/^\s*\[[^\[\]]+\]\s*$/) and not interface_block_header?(line)

  defp interface_block_header?(line), do: String.match?(line, ~r/^\s*\[\[[^\]]+\]\]\s*$/)

  defp validate_name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" -> {:error, :invalid_name}
      String.contains?(name, ["[", "]"]) -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp validate_type(type) when type in @allowed_types, do: :ok
  defp validate_type(_), do: {:error, :unsupported_type}

  defp ensure_name_free(doc, name) do
    if Enum.any?(doc.interfaces, &(&1.name == name)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp render_interface_block(attrs) do
    name = String.trim(Map.get(attrs, :name) || Map.get(attrs, "name"))
    type = Map.get(attrs, :type) || Map.get(attrs, "type")
    enabled? = Map.get(attrs, :enabled, Map.get(attrs, "enabled", true))
    enabled = if enabled? in [false, "false", "no", "No", "0"], do: "No", else: "Yes"

    lines =
      [
        "  [[#{name}]]",
        "    type = #{type}",
        "    enabled = #{enabled}"
      ] ++ type_specific_lines(type, attrs)

    %{name: name, lines: lines ++ [""]}
  end

  defp type_specific_lines("TCPClientInterface", attrs) do
    host = Map.get(attrs, :target_host) || Map.get(attrs, "target_host") || "127.0.0.1"
    port = Map.get(attrs, :target_port) || Map.get(attrs, "target_port") || "4242"

    [
      "    target_host = #{host}",
      "    target_port = #{port}"
    ]
  end

  defp type_specific_lines("TCPServerInterface", attrs) do
    ip = Map.get(attrs, :listen_ip) || Map.get(attrs, "listen_ip") || "0.0.0.0"
    port = Map.get(attrs, :listen_port) || Map.get(attrs, "listen_port") || "4242"

    [
      "    listen_ip = #{ip}",
      "    listen_port = #{port}"
    ]
  end

  defp type_specific_lines(_, _), do: []

  defp set_block_enabled_lines(lines, value) when is_list(lines) do
    keys = ["enabled", "interface_enabled"]

    case Enum.find_index(lines, fn line -> Enum.any?(keys, &assignment_line?(line, &1)) end) do
      nil ->
        # Insert after type= if present, else after the [[Name]] header.
        insert_at =
          case Enum.find_index(lines, &assignment_line?(&1, "type")) do
            nil -> min(1, length(lines))
            i -> i + 1
          end

        List.insert_at(lines, insert_at, "    enabled = #{value}")

      idx ->
        line = Enum.at(lines, idx)

        key =
          if assignment_line?(line, "interface_enabled"), do: "interface_enabled", else: "enabled"

        indent = leading_ws(line)
        List.replace_at(lines, idx, "#{indent}#{key} = #{value}")
    end
  end

  defp block_to_map(%{name: name, lines: lines}) do
    fields =
      lines
      |> Enum.reduce(%{}, fn line, acc ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            acc

          String.match?(trimmed, ~r/^\[\[/) ->
            acc

          String.contains?(trimmed, "=") ->
            [k, v] = String.split(trimmed, "=", parts: 2)
            Map.put(acc, String.trim(k), String.trim(v))

          true ->
            acc
        end
      end)

    %{
      name: name,
      type: fields["type"],
      enabled: parse_bool(fields["enabled"] || fields["interface_enabled"]),
      target_host: fields["target_host"],
      target_port: fields["target_port"],
      listen_ip: fields["listen_ip"],
      listen_port: fields["listen_port"]
    }
  end

  defp parse_bool(nil), do: nil

  defp parse_bool(v) do
    case String.downcase(to_string(v)) do
      x when x in ~w(yes true 1 on) -> true
      x when x in ~w(no false 0 off) -> false
      _ -> nil
    end
  end
end
