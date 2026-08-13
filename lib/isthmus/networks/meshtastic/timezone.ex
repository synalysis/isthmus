defmodule Isthmus.Networks.Meshtastic.Timezone do
  @moduledoc """
  POSIX TZ strings for Meshtastic `DeviceConfig.tzdef`.

  The radio RTC is Unix/UTC. The OLED clock uses `tzdef` (same POSIX form as
  https://github.com/nayarsystems/posix_tz_db). Strings are read from the host
  zoneinfo file when possible.
  """

  @zoneinfo "/usr/share/zoneinfo"
  @localtime "/etc/localtime"

  @doc """
  POSIX TZ for an IANA name, an already-POSIX string, or the host timezone.
  """
  def posix(nil), do: host_posix()
  def posix(""), do: host_posix()

  def posix(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> host_posix()
      posix_like?(value) -> value
      iana?(value) -> from_zoneinfo(value) || host_posix()
      true -> host_posix()
    end
  end

  def posix(_), do: host_posix()

  @doc "POSIX TZ for this host (`ISTHMUS_MESHTASTIC_TZ`, `TZ`, or `/etc/localtime`)."
  def host_posix do
    case first_present([System.get_env("ISTHMUS_MESHTASTIC_TZ"), System.get_env("TZ")]) do
      tz when is_binary(tz) ->
        cond do
          posix_like?(tz) -> tz
          iana?(tz) -> from_zoneinfo(tz) || from_path(@localtime) || offset_posix()
          true -> from_path(@localtime) || offset_posix()
        end

      _ ->
        from_path(@localtime) || offset_posix()
    end
  end

  defp first_present(values) do
    Enum.find(values, fn
      v when is_binary(v) -> String.trim(v) != ""
      _ -> false
    end)
  end

  defp from_zoneinfo(iana) when is_binary(iana) do
    from_path(Path.join(@zoneinfo, iana))
  end

  defp from_path(path) when is_binary(path) do
    with true <- String.starts_with?(Path.expand(path), @zoneinfo) or path == @localtime,
         {:ok, bin} <- File.read(path),
         posix when is_binary(posix) <- trailing_posix(bin) do
      posix
    else
      _ -> nil
    end
  end

  defp trailing_posix(bin) when is_binary(bin) do
    bin
    |> :binary.split("\n", [:global])
    |> Enum.reverse()
    |> Enum.find_value(fn part ->
      if String.valid?(part) do
        s = String.trim(part)
        if posix_like?(s), do: s
      end
    end)
  end

  defp iana?(name) when is_binary(name) do
    name in ["UTC", "GMT"] or
      (String.contains?(name, "/") and String.match?(name, ~r/\A[A-Za-z0-9_+\-\/]+\z/))
  end

  defp posix_like?(s) when is_binary(s) do
    byte_size(s) in 3..64 and String.valid?(s) and
      String.match?(s, ~r/\A(?:UTC0|GMT0|<[^>]+>-?\d|[A-Z]{2,6}-?\d)/)
  end

  # POSIX offset is hours *added to local* to get UTC (west of UTC is positive).
  defp offset_posix do
    utc = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    local = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
    offset_sec = local - utc
    hours = div(offset_sec, 3600)
    mins = offset_sec |> rem(3600) |> abs() |> div(60)
    posix_hours = -hours
    sign = if posix_hours < 0, do: "-", else: ""
    abs_h = abs(posix_hours)

    name =
      cond do
        hours == 0 -> "UTC"
        hours > 0 -> "<+" <> pad2(hours) <> ">"
        true -> "<-" <> pad2(abs(hours)) <> ">"
      end

    if mins == 0 do
      "#{name}#{sign}#{abs_h}"
    else
      "#{name}#{sign}#{abs_h}:#{pad2(mins)}"
    end
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: Integer.to_string(n)
end
