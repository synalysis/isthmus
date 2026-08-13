defmodule Isthmus.Networks.MeshCore.RadioParams do
  @moduledoc """
  Shared validation and normalization for MeshCore radio settings.

  Community presets match the MeshCore app list from
  `https://api.meshcore.nz/api/v1/config` (`suggested_radio_settings`).
  """

  @type t :: %{
          freq_mhz: float(),
          bw_khz: float(),
          sf: pos_integer(),
          cr: pos_integer(),
          tx_power: integer()
        }

  @type preset :: %{
          slug: String.t(),
          title: String.t(),
          description: String.t(),
          freq_mhz: float(),
          bw_khz: float(),
          sf: pos_integer(),
          cr: pos_integer()
        }

  # Snapshot of MeshCore app suggested_radio_settings (api.meshcore.nz).
  @presets [
    %{
      slug: "australia",
      title: "Australia",
      description: "915.800MHz / SF10 / BW250 / CR5",
      freq_mhz: 915.8,
      bw_khz: 250.0,
      sf: 10,
      cr: 5
    },
    %{
      slug: "australia_narrow",
      title: "Australia (Narrow)",
      description: "916.575MHz / SF7 / BW62.5 / CR8",
      freq_mhz: 916.575,
      bw_khz: 62.5,
      sf: 7,
      cr: 8
    },
    %{
      slug: "australia_mid",
      title: "Australia (Mid)",
      description: "915.075MHz / SF9 / BW125 / CR5",
      freq_mhz: 915.075,
      bw_khz: 125.0,
      sf: 9,
      cr: 5
    },
    %{
      slug: "australia_sa_wa",
      title: "Australia: SA, WA",
      description: "923.125MHz / SF8 / BW62.5 / CR8",
      freq_mhz: 923.125,
      bw_khz: 62.5,
      sf: 8,
      cr: 8
    },
    %{
      slug: "australia_qld",
      title: "Australia: QLD",
      description: "923.125MHz / SF8 / BW62.5 / CR5",
      freq_mhz: 923.125,
      bw_khz: 62.5,
      sf: 8,
      cr: 5
    },
    %{
      slug: "brazil",
      title: "Brazil",
      description: "923.125MHz / SF8 / BW62.5 / CR8",
      freq_mhz: 923.125,
      bw_khz: 62.5,
      sf: 8,
      cr: 8
    },
    %{
      slug: "costa_rica",
      title: "Costa Rica",
      description: "910.525MHz / SF11 / BW125 / CR5",
      freq_mhz: 910.525,
      bw_khz: 125.0,
      sf: 11,
      cr: 5
    },
    %{
      slug: "eu_uk_narrow",
      title: "EU/UK (Narrow)",
      description: "869.618MHz / SF8 / BW62.5 / CR8",
      freq_mhz: 869.618,
      bw_khz: 62.5,
      sf: 8,
      cr: 8
    },
    %{
      slug: "eu_uk_deprecated",
      title: "EU/UK (Deprecated)",
      description: "869.525MHz / SF11 / BW250 / CR5",
      freq_mhz: 869.525,
      bw_khz: 250.0,
      sf: 11,
      cr: 5
    },
    %{
      slug: "czech_narrow",
      title: "Czech Republic (Narrow)",
      description: "869.432MHz / SF7 / BW62.5 / CR5",
      freq_mhz: 869.432,
      bw_khz: 62.5,
      sf: 7,
      cr: 5
    },
    %{
      slug: "eu_433_long_range",
      title: "EU 433MHz (Long Range)",
      description: "433.650MHz / SF11 / BW250 / CR5",
      freq_mhz: 433.65,
      bw_khz: 250.0,
      sf: 11,
      cr: 5
    },
    %{
      slug: "eu_433_narrow",
      title: "EU 433MHz (Narrow)",
      description: "433.650MHz / SF8 / BW62.5 / CR8",
      freq_mhz: 433.65,
      bw_khz: 62.5,
      sf: 8,
      cr: 8
    },
    %{
      slug: "hungary",
      title: "Hungary",
      description: "869.618MHz / SF7 / BW62.5 / CR5",
      freq_mhz: 869.618,
      bw_khz: 62.5,
      sf: 7,
      cr: 5
    },
    %{
      slug: "netherlands",
      title: "Netherlands",
      description: "869.618MHz / SF7 / BW62.5 / CR5",
      freq_mhz: 869.618,
      bw_khz: 62.5,
      sf: 7,
      cr: 5
    },
    %{
      slug: "new_zealand",
      title: "New Zealand",
      description: "917.375MHz / SF11 / BW250 / CR5",
      freq_mhz: 917.375,
      bw_khz: 250.0,
      sf: 11,
      cr: 5
    },
    %{
      slug: "new_zealand_narrow",
      title: "New Zealand (Narrow)",
      description: "917.375MHz / SF7 / BW62.5 / CR5",
      freq_mhz: 917.375,
      bw_khz: 62.5,
      sf: 7,
      cr: 5
    },
    %{
      slug: "portugal_433",
      title: "Portugal 433",
      description: "433.375MHz / SF9 / BW62.5 / CR6",
      freq_mhz: 433.375,
      bw_khz: 62.5,
      sf: 9,
      cr: 6
    },
    %{
      slug: "portugal_868",
      title: "Portugal 868",
      description: "869.618MHz / SF7 / BW62.5 / CR6",
      freq_mhz: 869.618,
      bw_khz: 62.5,
      sf: 7,
      cr: 6
    },
    %{
      slug: "slovakia",
      title: "Slovakia",
      description: "869.618MHz / SF7 / BW62.5 / CR5",
      freq_mhz: 869.618,
      bw_khz: 62.5,
      sf: 7,
      cr: 5
    },
    %{
      slug: "switzerland",
      title: "Switzerland",
      description: "869.618MHz / SF8 / BW62.5 / CR8",
      freq_mhz: 869.618,
      bw_khz: 62.5,
      sf: 8,
      cr: 8
    },
    %{
      slug: "usa_canada",
      title: "USA/Canada (Recommended)",
      description: "910.525MHz / SF7 / BW62.5 / CR5",
      freq_mhz: 910.525,
      bw_khz: 62.5,
      sf: 7,
      cr: 5
    },
    %{
      slug: "vietnam_narrow",
      title: "Vietnam (Narrow)",
      description: "920.250MHz / SF8 / BW62.5 / CR5",
      freq_mhz: 920.25,
      bw_khz: 62.5,
      sf: 8,
      cr: 5
    },
    %{
      slug: "vietnam_deprecated",
      title: "Vietnam (Deprecated)",
      description: "920.250MHz / SF11 / BW250 / CR5",
      freq_mhz: 920.25,
      bw_khz: 250.0,
      sf: 11,
      cr: 5
    }
  ]

  @presets_by_slug Map.new(@presets, &{&1.slug, &1})

  def presets, do: @presets

  def get_preset(slug) when is_binary(slug), do: Map.get(@presets_by_slug, slug)
  def get_preset(_), do: nil

  def preset_options do
    custom = {"Custom", "custom"}

    listed =
      Enum.map(@presets, fn p ->
        {"#{p.title} — #{p.description}", p.slug}
      end)

    [custom | listed]
  end

  @doc """
  Validate and normalize a params map (string or atom keys).

  A non-custom `preset` fills frequency / BW / SF / CR before validation.
  TX power is never taken from a preset.

  Returns `{:ok, t}` or `{:error, message}`.
  """
  def cast(params) when is_map(params) do
    params = overlay_preset(stringify(params))

    with {:ok, freq} <- parse_float(params, ["freq_mhz", :freq_mhz, "freq", :freq]),
         {:ok, bw} <- parse_float(params, ["bw_khz", :bw_khz, "bw", :bw]),
         {:ok, sf} <- parse_int(params, ["sf", :sf]),
         {:ok, cr} <- parse_int(params, ["cr", :cr]),
         {:ok, tx} <- parse_int(params, ["tx_power", :tx_power, "tx", :tx]) do
      cond do
        freq < 100.0 or freq > 2500.0 ->
          {:error, "frequency must be between 100 and 2500 MHz"}

        bw < 7.0 or bw > 500.0 ->
          {:error, "bandwidth must be between 7 and 500 kHz"}

        sf not in 5..12 ->
          {:error, "spreading factor must be 5–12"}

        cr not in 5..8 ->
          {:error, "coding rate must be 5–8"}

        tx < 0 or tx > 22 ->
          {:error, "TX power must be 0–22 dBm"}

        true ->
          {:ok,
           %{
             freq_mhz: freq * 1.0,
             bw_khz: bw * 1.0,
             sf: sf,
             cr: cr,
             tx_power: tx
           }}
      end
    end
  end

  def cast(_), do: {:error, "invalid params"}

  def to_form_params(%{} = radio) do
    %{
      "preset" => match_preset_slug(radio) || "custom",
      "freq_mhz" => format_num(Map.get(radio, :freq_mhz) || Map.get(radio, "freq_mhz")),
      "bw_khz" => format_num(Map.get(radio, :bw_khz) || Map.get(radio, "bw_khz")),
      "sf" => to_string(Map.get(radio, :sf) || Map.get(radio, "sf") || ""),
      "cr" => to_string(Map.get(radio, :cr) || Map.get(radio, "cr") || ""),
      "tx_power" => to_string(Map.get(radio, :tx_power) || Map.get(radio, "tx_power") || "")
    }
  end

  def empty_form_params do
    %{
      "preset" => "custom",
      "freq_mhz" => "",
      "bw_khz" => "",
      "sf" => "7",
      "cr" => "5",
      "tx_power" => "10"
    }
  end

  @doc """
  Update form params after a LiveView `phx-change`.

  Selecting a preset fills freq / BW / SF / CR. Editing those fields switches
  the dropdown to Custom unless the values still match a preset.
  """
  def apply_form_change(params, target \\ nil) when is_map(params) do
    params = stringify(params)

    cond do
      preset_field?(target) and params["preset"] == "custom" ->
        Map.put(params, "preset", "custom")

      preset_field?(target) ->
        overlay_preset(params)

      true ->
        Map.put(params, "preset", match_preset_slug(params) || "custom")
    end
  end

  def companion_wire(%{freq_mhz: freq, bw_khz: bw, sf: sf, cr: cr}) do
    {round(freq * 1000), round(bw * 1000), sf, cr}
  end

  def cli_radio_command(%{freq_mhz: freq, bw_khz: bw, sf: sf, cr: cr}) do
    "set radio #{trim_float(freq)},#{trim_float(bw)},#{sf},#{cr}"
  end

  def cli_tx_command(%{tx_power: tx}), do: "set tx #{tx}"

  def match_preset_slug(radio) when is_map(radio) do
    with {:ok, freq} <- parse_float(radio, ["freq_mhz", :freq_mhz, "freq", :freq]),
         {:ok, bw} <- parse_float(radio, ["bw_khz", :bw_khz, "bw", :bw]),
         {:ok, sf} <- parse_int(radio, ["sf", :sf]),
         {:ok, cr} <- parse_int(radio, ["cr", :cr]) do
      matches = Enum.filter(@presets, &preset_match?(&1, freq, bw, sf, cr))
      preferred = radio["preset"] || radio[:preset]

      cond do
        is_binary(preferred) and Enum.any?(matches, &(&1.slug == preferred)) ->
          preferred

        matches != [] ->
          hd(matches).slug

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp overlay_preset(params) do
    case get_preset(params["preset"] || params[:preset]) do
      nil ->
        params

      preset ->
        Map.merge(params, %{
          "preset" => preset.slug,
          "freq_mhz" => trim_float(preset.freq_mhz),
          "bw_khz" => trim_float(preset.bw_khz),
          "sf" => Integer.to_string(preset.sf),
          "cr" => Integer.to_string(preset.cr)
        })
    end
  end

  defp preset_match?(preset, freq, bw, sf, cr) do
    sf == preset.sf and cr == preset.cr and close?(freq, preset.freq_mhz, 0.001) and
      close?(bw, preset.bw_khz, 0.05)
  end

  defp close?(a, b, eps), do: abs(a - b) <= eps

  defp preset_field?(target) when is_list(target), do: List.last(target) == "preset"
  defp preset_field?("preset"), do: true
  defp preset_field?(_), do: false

  defp stringify(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_binary(v), do: v
  defp stringify_value(v) when is_integer(v), do: Integer.to_string(v)
  defp stringify_value(v) when is_float(v), do: trim_float(v)
  defp stringify_value(v), do: v

  defp parse_float(params, keys) do
    case fetch(params, keys) do
      nil ->
        {:error, "missing #{hd(keys)}"}

      "" ->
        {:error, "missing #{hd(keys)}"}

      v when is_number(v) ->
        {:ok, v * 1.0}

      v when is_binary(v) ->
        case Float.parse(String.trim(v)) do
          {n, _} -> {:ok, n}
          :error -> {:error, "invalid #{hd(keys)}"}
        end
    end
  end

  defp parse_int(params, keys) do
    case fetch(params, keys) do
      nil ->
        {:error, "missing #{hd(keys)}"}

      "" ->
        {:error, "missing #{hd(keys)}"}

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

  defp format_num(nil), do: ""
  defp format_num(n) when is_integer(n), do: Integer.to_string(n)
  defp format_num(n) when is_float(n), do: trim_float(n)
  defp format_num(n) when is_binary(n), do: n

  defp trim_float(n) when is_float(n) do
    :erlang.float_to_binary(n, decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp trim_float(n) when is_integer(n), do: Integer.to_string(n)
end
