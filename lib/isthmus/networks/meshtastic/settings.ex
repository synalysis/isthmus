defmodule Isthmus.Networks.Meshtastic.Settings do
  @moduledoc """
  Combined companion settings for the admin configuration dialog.

  Each section is an independent nested map (`lora`, `device`, …). To expose a
  new knob, add it to that section's module and render a control in the dialog;
  `cast/2` already forwards unknown future section keys as long as they are
  listed in `sections/0`.
  """

  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.RadioConfig

  @sections [:lora, :device]

  def sections, do: @sections

  def empty do
    %{lora: RadioConfig.empty(), device: DeviceConfig.empty()}
  end

  def to_form_params(settings) when is_map(settings) do
    %{
      "lora" => RadioConfig.to_form_params(section(settings, :lora, RadioConfig.empty())),
      "device" => DeviceConfig.to_form_params(section(settings, :device, DeviceConfig.empty()))
    }
  end

  def to_form_params(_), do: to_form_params(empty())

  @doc """
  Cast a settings form (or a partial map with only some sections).

  Omitted sections become `nil` so the companion can skip that admin write.
  """
  def cast(params, bases \\ empty())

  def cast(params, bases) when is_map(params) and is_map(bases) do
    bases = Map.merge(empty(), Map.new(bases, fn {k, v} -> {cast_key(k), v} end))
    params = unwrap(params)

    with {:ok, lora} <- cast_section(:lora, params, bases.lora),
         {:ok, device} <- cast_section(:device, params, bases.device) do
      if is_nil(lora) and is_nil(device) do
        {:error, "no settings to apply"}
      else
        {:ok, %{lora: lora, device: device}}
      end
    end
  end

  def cast(_, _), do: {:error, "invalid settings"}

  defp cast_section(:lora, params, base) do
    case nested(params, :lora) do
      nil -> {:ok, nil}
      section -> RadioConfig.cast(section, base)
    end
  end

  defp cast_section(:device, params, base) do
    case nested(params, :device) do
      nil -> {:ok, nil}
      section -> DeviceConfig.cast(section, base)
    end
  end

  defp nested(params, key) do
    case fetch(params, [key, Atom.to_string(key)]) do
      map when is_map(map) ->
        if blank_map?(map), do: nil, else: map

      _ ->
        nil
    end
  end

  defp unwrap(params) do
    case fetch(params, [:settings, "settings"]) do
      map when is_map(map) -> map
      _ -> params
    end
  end

  defp blank_map?(map) do
    Enum.all?(map, fn {_k, v} -> v in [nil, ""] end)
  end

  defp section(settings, key, default) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key)) || default
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
end
