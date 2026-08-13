defmodule Isthmus.Networks.Meshtastic.DeviceConfig do
  @moduledoc """
  Editable Meshtastic `Config.DeviceConfig` fields for the companion dialog.

  Only keys in `editable_keys/0` are written back; everything else is preserved
  from the radio. Add a field here (and a form control) when exposing more
  DeviceConfig knobs.
  """

  alias Isthmus.Networks.Meshtastic.Protocol

  # Config.DeviceConfig.BuzzerMode
  @buzzer_modes [
    {0, "enabled", "Enabled (all sounds)"},
    {1, "disabled", "Disabled"},
    {2, "notifications_only", "Notifications only"},
    {3, "system_only", "System only"},
    {4, "direct_msg_only", "Direct messages only"}
  ]

  @buzzer_by_id Map.new(@buzzer_modes, fn {id, slug, _label} -> {id, slug} end)
  @buzzer_by_slug Map.new(@buzzer_modes, fn {id, slug, _label} -> {slug, id} end)
  @buzzer_labels Map.new(@buzzer_modes, fn {id, _slug, label} -> {id, label} end)

  @editable [:buzzer_mode]

  def editable_keys, do: @editable

  def empty, do: Protocol.empty_device_config()

  def buzzer_options do
    Enum.map(@buzzer_modes, fn {id, _slug, label} -> {label, Integer.to_string(id)} end)
  end

  def buzzer_label(id) when is_integer(id), do: Map.get(@buzzer_labels, id, "Buzzer #{id}")
  def buzzer_label(_), do: buzzer_label(0)

  def buzzer_slug(id) when is_integer(id), do: Map.get(@buzzer_by_id, id, "enabled")
  def buzzer_slug(_), do: "enabled"

  def to_form_params(device) when is_map(device) do
    %{
      "buzzer_mode" => int_str(device, :buzzer_mode, 0)
    }
  end

  def to_form_params(_), do: to_form_params(empty())

  @doc """
  Overlay editable fields from form params onto a cached/base DeviceConfig.
  """
  def cast(params, base \\ empty())

  def cast(params, base) when is_map(params) and is_map(base) do
    merged = Map.merge(empty(), Map.new(base, fn {k, v} -> {cast_key(k), v} end))

    with {:ok, buzzer} <- parse_buzzer(params) do
      {:ok, merge(merged, %{buzzer_mode: buzzer})}
    end
  end

  def cast(_, _), do: {:error, "invalid device settings"}

  def merge(base, overlay) when is_map(base) and is_map(overlay) do
    Enum.reduce(@editable, base, fn key, acc ->
      case fetch(overlay, [key, Atom.to_string(key)]) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp parse_buzzer(params) do
    case fetch(params, ["buzzer_mode", :buzzer_mode]) do
      nil ->
        {:ok, 0}

      "" ->
        {:ok, 0}

      v when is_integer(v) and v in 0..4 ->
        {:ok, v}

      v when is_binary(v) ->
        trimmed = String.trim(v)

        cond do
          Map.has_key?(@buzzer_by_slug, trimmed) ->
            {:ok, @buzzer_by_slug[trimmed]}

          true ->
            case Integer.parse(trimmed) do
              {n, ""} when n in 0..4 -> {:ok, n}
              _ -> {:error, "unknown buzzer mode"}
            end
        end

      _ ->
        {:error, "unknown buzzer mode"}
    end
  end

  defp fetch(params, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(params, key) ||
        (is_atom(key) && Map.get(params, Atom.to_string(key))) ||
        (is_binary(key) && Map.get(params, safe_atom(key)))
    end)
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp cast_key(k) when is_atom(k), do: k

  defp cast_key(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :unknown
  end

  defp int_str(map, key, default) do
    v = Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
    to_string(v)
  end
end
