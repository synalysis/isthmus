defmodule Isthmus.Networks.MeshCore.RadioParams do
  @moduledoc "Shared validation and normalization for MeshCore radio settings."

  @type t :: %{
          freq_mhz: float(),
          bw_khz: float(),
          sf: pos_integer(),
          cr: pos_integer(),
          tx_power: integer()
        }

  @doc """
  Validate and normalize a params map (string or atom keys).

  Returns `{:ok, t}` or `{:error, message}`.
  """
  def cast(params) when is_map(params) do
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
      "freq_mhz" => format_num(Map.get(radio, :freq_mhz) || Map.get(radio, "freq_mhz")),
      "bw_khz" => format_num(Map.get(radio, :bw_khz) || Map.get(radio, "bw_khz")),
      "sf" => to_string(Map.get(radio, :sf) || Map.get(radio, "sf") || ""),
      "cr" => to_string(Map.get(radio, :cr) || Map.get(radio, "cr") || ""),
      "tx_power" => to_string(Map.get(radio, :tx_power) || Map.get(radio, "tx_power") || "")
    }
  end

  def empty_form_params do
    %{"freq_mhz" => "", "bw_khz" => "", "sf" => "7", "cr" => "5", "tx_power" => "10"}
  end

  def companion_wire(%{freq_mhz: freq, bw_khz: bw, sf: sf, cr: cr}) do
    {round(freq * 1000), round(bw * 1000), sf, cr}
  end

  def cli_radio_command(%{freq_mhz: freq, bw_khz: bw, sf: sf, cr: cr}) do
    "set radio #{trim_float(freq)},#{trim_float(bw)},#{sf},#{cr}"
  end

  def cli_tx_command(%{tx_power: tx}), do: "set tx #{tx}"

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
