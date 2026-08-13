defmodule Isthmus.Networks.Reticulum.RNode do
  @moduledoc """
  RNode USB detect (RNS KISS) and helpers for `RNodeInterface` config.

  Detect sequence matches `RNS.Interfaces.RNodeInterface.detect/1`:
  `FEND CMD_DETECT DETECT_REQ FEND` plus version / platform / MCU queries.
  A live RNode replies with `FEND CMD_DETECT DETECT_RESP FEND`.
  """

  @fend 0xC0
  @cmd_detect 0x08
  @detect_req 0x73
  @detect_resp 0x46
  @cmd_fw_version 0x50
  @cmd_platform 0x48
  @cmd_mcu 0x49

  @freq_min_hz 137_000_000
  @freq_max_hz 3_000_000_000
  @bw_min_hz 7_800
  @bw_max_hz 1_625_000

  @detect_reply <<@fend, @cmd_detect, @detect_resp, @fend>>

  def detect_frame do
    <<@fend, @cmd_detect, @detect_req, @fend, @fend, @cmd_fw_version, 0x00, @fend, @fend,
      @cmd_platform, 0x00, @fend, @fend, @cmd_mcu, 0x00, @fend>>
  end

  def detect_response?(data) when is_binary(data) do
    :binary.match(data, @detect_reply) != :nomatch
  end

  def detect_response?(_), do: false

  @doc "Build RNodeInterface INI fields from the admin form (MHz / kHz)."
  def config_from_form(params) when is_map(params) do
    %{
      port: String.trim(to_string(params["port"] || params[:port] || "")),
      frequency: mhz_to_hz(params["frequency_mhz"] || params[:frequency_mhz]),
      bandwidth: khz_to_hz(params["bandwidth_khz"] || params[:bandwidth_khz]),
      txpower: parse_int(params["txpower"] || params[:txpower]),
      spreadingfactor: parse_int(params["spreadingfactor"] || params[:spreadingfactor]),
      codingrate: parse_int(params["codingrate"] || params[:codingrate])
    }
  end

  def validate_config(attrs) when is_map(attrs) do
    port = attrs[:port] || attrs["port"]
    freq = attrs[:frequency] || attrs["frequency"]
    bw = attrs[:bandwidth] || attrs["bandwidth"]
    tx = attrs[:txpower] || attrs["txpower"]
    sf = attrs[:spreadingfactor] || attrs["spreadingfactor"]
    cr = attrs[:codingrate] || attrs["codingrate"]

    cond do
      not (is_binary(port) and String.trim(port) != "") ->
        {:error, :missing_port}

      not valid_hz?(freq, @freq_min_hz, @freq_max_hz) ->
        {:error, :invalid_frequency}

      not valid_hz?(bw, @bw_min_hz, @bw_max_hz) ->
        {:error, :invalid_bandwidth}

      not valid_int?(tx, 0, 37) ->
        {:error, :invalid_txpower}

      not valid_int?(sf, 5, 12) ->
        {:error, :invalid_spreadingfactor}

      not valid_int?(cr, 5, 8) ->
        {:error, :invalid_codingrate}

      true ->
        :ok
    end
  end

  def default_form_params(port \\ "") do
    %{
      "name" => default_name(port),
      "type" => "RNodeInterface",
      "port" => port,
      "frequency_mhz" => "915.0",
      "bandwidth_khz" => "125",
      "txpower" => "7",
      "spreadingfactor" => "8",
      "codingrate" => "5"
    }
  end

  def default_name(port) when is_binary(port) and port != "" do
    "RNode #{Path.basename(port)}"
  end

  def default_name(_), do: "RNode"

  defp mhz_to_hz(v) do
    case parse_float(v) do
      nil -> nil
      mhz -> round(mhz * 1_000_000)
    end
  end

  defp khz_to_hz(v) do
    case parse_float(v) do
      nil -> nil
      khz -> round(khz * 1_000)
    end
  end

  defp parse_float(v) when is_integer(v), do: v * 1.0
  defp parse_float(v) when is_float(v), do: v

  defp parse_float(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp valid_hz?(v, min, max) when is_integer(v), do: v >= min and v <= max
  defp valid_hz?(_, _, _), do: false

  defp valid_int?(v, min, max) when is_integer(v), do: v >= min and v <= max
  defp valid_int?(_, _, _), do: false
end
