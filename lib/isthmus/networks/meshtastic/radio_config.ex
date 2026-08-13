defmodule Isthmus.Networks.Meshtastic.RadioConfig do
  @moduledoc """
  Validation and labels for Meshtastic LoRa config (region / modem preset / custom).
  """

  @type t :: %{
          use_preset: boolean(),
          modem_preset: non_neg_integer(),
          bandwidth: non_neg_integer(),
          spread_factor: non_neg_integer(),
          coding_rate: non_neg_integer(),
          region: non_neg_integer(),
          hop_limit: non_neg_integer(),
          tx_enabled: boolean(),
          tx_power: integer(),
          channel_num: non_neg_integer(),
          override_frequency: float(),
          sx126x_rx_boosted_gain: boolean(),
          override_duty_cycle: boolean(),
          ignore_mqtt: boolean(),
          config_ok_to_mqtt: boolean(),
          pa_fan_disabled: boolean(),
          frequency_offset: float()
        }

  # Config.LoRaConfig.RegionCode
  @regions [
    {0, "Unset"},
    {1, "United States (US 915)"},
    {2, "EU 433"},
    {3, "EU 868"},
    {4, "China"},
    {5, "Japan"},
    {6, "Australia / NZ (ANZ 915)"},
    {7, "Korea"},
    {8, "Taiwan"},
    {9, "Russia"},
    {10, "India"},
    {11, "New Zealand 865"},
    {12, "Thailand"},
    {13, "2.4 GHz (LoRa)"},
    {14, "Ukraine 433"},
    {15, "Ukraine 868"},
    {16, "Malaysia 433"},
    {17, "Malaysia 919"},
    {18, "Singapore 923"},
    {19, "Philippines 433"},
    {20, "Philippines 868"},
    {21, "Philippines 915"},
    {22, "ANZ 433"},
    {23, "Kazakhstan 433"},
    {24, "Kazakhstan 863"},
    {25, "Nepal 865"},
    {26, "Brazil 902"}
  ]

  # Config.LoRaConfig.ModemPreset — skip deprecated VERY_LONG_SLOW in the UI.
  @presets [
    {0, "Long Fast"},
    {1, "Long Slow"},
    {3, "Medium Slow"},
    {4, "Medium Fast"},
    {5, "Short Slow"},
    {6, "Short Fast"},
    {7, "Long Moderate"},
    {8, "Short Turbo"}
  ]

  @preset_names Map.new(@presets)
  @region_names Map.new(@regions)

  def regions, do: @regions
  def presets, do: @presets

  def region_options do
    Enum.map(@regions, fn {id, label} -> {label, Integer.to_string(id)} end)
  end

  def preset_options do
    Enum.map(@presets, fn {id, label} -> {label, Integer.to_string(id)} end)
  end

  def mode_options, do: [{"Modem preset", "preset"}, {"Custom (BW / SF / CR)", "custom"}]

  def region_label(id) when is_integer(id), do: Map.get(@region_names, id, "Region #{id}")
  def region_label(_), do: "Unset"

  def preset_label(id) when is_integer(id) do
    Map.get(@preset_names, id, if(id == 2, do: "Very Long Slow", else: "Preset #{id}"))
  end

  def preset_label(_), do: "Long Fast"

  def empty do
    %{
      use_preset: true,
      modem_preset: 0,
      bandwidth: 0,
      spread_factor: 0,
      coding_rate: 0,
      region: 0,
      hop_limit: 3,
      tx_enabled: true,
      tx_power: 0,
      channel_num: 0,
      override_frequency: 0.0,
      sx126x_rx_boosted_gain: false,
      override_duty_cycle: false,
      ignore_mqtt: false,
      config_ok_to_mqtt: false,
      pa_fan_disabled: false,
      frequency_offset: 0.0
    }
  end

  def empty_form_params do
    to_form_params(empty())
  end

  def to_form_params(lora) when is_map(lora) do
    use_preset? = truthy?(Map.get(lora, :use_preset) || Map.get(lora, "use_preset"), true)

    %{
      "mode" => if(use_preset?, do: "preset", else: "custom"),
      "region" => int_str(lora, :region, 0),
      "modem_preset" => int_str(lora, :modem_preset, 0),
      "bandwidth" => positive_int_str(lora, :bandwidth, 125),
      "spread_factor" => positive_int_str(lora, :spread_factor, 11),
      "coding_rate" => positive_int_str(lora, :coding_rate, 5),
      "hop_limit" => int_str(lora, :hop_limit, 3),
      "tx_power" => int_str(lora, :tx_power, 0),
      "channel_num" => int_str(lora, :channel_num, 0),
      "override_frequency" => float_str(lora, :override_frequency)
    }
  end

  @doc """
  Merge form params onto a cached LoRa config (preserves flags the UI does not edit).
  """
  def cast(params, base \\ empty())

  def cast(params, base) when is_map(params) and is_map(base) do
    merged = Map.merge(empty(), Map.new(base, fn {k, v} -> {cast_key(k), v} end))

    with {:ok, region} <- parse_int(params, ["region", :region], 0),
         {:ok, preset} <- parse_int(params, ["modem_preset", :modem_preset], 0),
         {:ok, bw} <- parse_int(params, ["bandwidth", :bandwidth], 0),
         {:ok, sf} <- parse_int(params, ["spread_factor", :spread_factor], 0),
         {:ok, cr} <- parse_int(params, ["coding_rate", :coding_rate], 0),
         {:ok, hops} <- parse_int(params, ["hop_limit", :hop_limit], 3),
         {:ok, tx} <- parse_int(params, ["tx_power", :tx_power], 0),
         {:ok, ch} <- parse_int(params, ["channel_num", :channel_num], 0),
         {:ok, freq} <- parse_float(params, ["override_frequency", :override_frequency], 0.0) do
      use_preset? = preset_mode?(params)

      cond do
        region not in 0..26 ->
          {:error, "unknown region"}

        use_preset? and preset not in [0, 1, 3, 4, 5, 6, 7, 8] ->
          {:error, "unknown modem preset"}

        not use_preset? and bw != 0 and bw not in [31, 62, 125, 250, 500] ->
          {:error, "bandwidth must be 31, 62, 125, 250, or 500 kHz"}

        not use_preset? and sf != 0 and sf not in 7..12 ->
          {:error, "spreading factor must be 7–12"}

        not use_preset? and cr != 0 and cr not in 5..8 ->
          {:error, "coding rate must be 5–8"}

        hops not in 1..7 ->
          {:error, "hop limit must be 1–7"}

        tx < 0 or tx > 30 ->
          {:error, "TX power must be 0–30 dBm (0 = region max)"}

        ch < 0 or ch > 83 ->
          {:error, "LoRa channel number is out of range"}

        freq < 0.0 or freq > 2500.0 ->
          {:error, "override frequency must be 0 (unset) or a MHz value"}

        true ->
          {:ok,
           %{
             merged
             | use_preset: use_preset?,
               modem_preset: if(use_preset?, do: preset, else: merged.modem_preset),
               bandwidth: if(use_preset?, do: 0, else: bw),
               spread_factor: if(use_preset?, do: 0, else: sf),
               coding_rate: if(use_preset?, do: 0, else: cr),
               region: region,
               hop_limit: hops,
               tx_enabled: true,
               tx_power: tx,
               channel_num: ch,
               override_frequency: if(use_preset?, do: 0.0, else: freq)
           }}
      end
    end
  end

  def cast(_, _), do: {:error, "invalid params"}

  defp preset_mode?(params) do
    case fetch(params, ["mode", :mode, "use_preset", :use_preset]) do
      "custom" -> false
      "preset" -> true
      false -> false
      "false" -> false
      0 -> false
      other -> truthy?(other, true)
    end
  end

  defp truthy?(v, default) do
    case v do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      nil -> default
      _ -> default
    end
  end

  defp parse_int(params, keys, default) do
    case fetch(params, keys) do
      nil ->
        {:ok, default}

      "" ->
        {:ok, default}

      v when is_integer(v) ->
        {:ok, v}

      v when is_float(v) ->
        {:ok, trunc(v)}

      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {n, _} -> {:ok, n}
          :error -> {:error, "invalid #{hd(keys)}"}
        end
    end
  end

  defp parse_float(params, keys, default) do
    case fetch(params, keys) do
      nil ->
        {:ok, default * 1.0}

      "" ->
        {:ok, default * 1.0}

      v when is_number(v) ->
        {:ok, v * 1.0}

      v when is_binary(v) ->
        case Float.parse(String.trim(v)) do
          {n, _} -> {:ok, n}
          :error -> {:error, "invalid #{hd(keys)}"}
        end
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

  defp positive_int_str(map, key, default) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_integer(n) and n > 0 -> Integer.to_string(n)
      n when is_binary(n) and n not in ["", "0"] -> n
      _ -> Integer.to_string(default)
    end
  end

  defp float_str(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_float(n) and n > 0.0 ->
        :erlang.float_to_binary(n, decimals: 6)
        |> String.trim_trailing("0")
        |> String.trim_trailing(".")

      n when is_integer(n) and n > 0 ->
        Integer.to_string(n)

      n when is_binary(n) ->
        n

      _ ->
        ""
    end
  end
end
