defmodule Isthmus.Networks.MeshCore.Ports do
  @moduledoc """
  Enumerate serial ports and score likely MeshCore companion devices.

  MeshCore radios commonly appear as USB CDC (`ttyACM*`) or USB-UART bridges
  (Silicon Labs CP210x, CH340, FTDI) under `ttyUSB*`.
  """

  @type port_info :: %{
          required(:name) => String.t(),
          required(:path) => String.t(),
          required(:score) => non_neg_integer(),
          required(:reasons) => [String.t()],
          required(:description) => String.t() | nil,
          required(:manufacturer) => String.t() | nil,
          required(:serial_number) => String.t() | nil,
          required(:vendor_id) => non_neg_integer() | nil,
          required(:product_id) => non_neg_integer() | nil
        }

  @usb_uart_vids %{
    # Silicon Labs CP210x — very common on companion / ESP boards
    0x10C4 => "Silicon Labs",
    # QinHeng CH340/CH341
    0x1A86 => "QinHeng (CH340)",
    # FTDI
    0x0403 => "FTDI",
    # Nordic Semiconductor (nRF USB CDC)
    0x1915 => "Nordic Semiconductor",
    # Espressif
    0x303A => "Espressif",
    # Seeed Studio
    0x2886 => "Seeed Studio",
    # Raspberry Pi Ltd (some Pico / hats)
    0x2E8A => "Raspberry Pi"
  }

  @doc "List scored serial ports. Pass `:enumerate` for tests."
  def list(opts \\ []) do
    enumerate = Keyword.get(opts, :enumerate, &Circuits.UART.enumerate/0)
    configured = Keyword.get(opts, :configured, System.get_env("ISTHMUS_MESHCORE_PORT"))

    enumerate.()
    |> Enum.map(fn {name, meta} -> score_port(name, meta || %{}, configured) end)
    |> Enum.reject(&system_noise?/1)
    |> Enum.sort_by(&{-&1.score, &1.path})
  end

  @doc "Best-guess MeshCore port path, or nil."
  def suggest(opts \\ []) do
    case list(opts) do
      [%{score: score, path: path} | _] when score > 0 -> path
      _ -> nil
    end
  end

  @doc "Human-readable report lines."
  def format_report(opts \\ []) do
    ports = list(opts)
    suggestion = suggest(opts)
    configured = Keyword.get(opts, :configured, System.get_env("ISTHMUS_MESHCORE_PORT"))

    header = [
      "MeshCore serial ports",
      "====================="
    ]

    body =
      case ports do
        [] ->
          ["(no candidate USB serial devices found)"]

        ports ->
          Enum.map(ports, &format_port/1)
      end

    footer =
      cond do
        is_binary(suggestion) ->
          [
            "",
            "Suggested ISTHMUS_MESHCORE_PORT=#{suggestion}",
            "Companion baud rate: 115200"
          ]

        true ->
          [
            "",
            "No strong MeshCore candidate. Plug in the radio and re-run,",
            "or set ISTHMUS_MESHCORE_PORT manually (often /dev/ttyACM0 or /dev/ttyUSB0)."
          ]
      end

    configured_line =
      if is_binary(configured) and configured != "" do
        match? = suggestion == configured

        [
          "",
          "Currently configured: #{configured}" <>
            if(match?, do: " (matches suggestion)", else: "")
        ]
      else
        []
      end

    header ++ body ++ footer ++ configured_line
  end

  defp format_port(p) do
    meta =
      [
        p.manufacturer,
        p.description,
        vid_pid(p)
      ]
      |> Enum.reject(&is_nil_or_blank/1)
      |> Enum.join(" | ")

    reasons =
      if p.reasons == [], do: "", else: "  [#{Enum.join(p.reasons, ", ")}]"

    score = String.pad_leading(Integer.to_string(p.score), 3)

    "#{score}  #{p.path}" <>
      if(meta == "", do: "", else: "  — #{meta}") <>
      reasons
  end

  defp vid_pid(%{vendor_id: vid, product_id: pid})
       when is_integer(vid) and is_integer(pid) do
    "VID:PID #{hex4(vid)}:#{hex4(pid)}"
  end

  defp vid_pid(_), do: nil

  defp hex4(n), do: n |> Integer.to_string(16) |> String.pad_leading(4, "0")

  defp score_port(name, meta, configured) do
    path = device_path(name)
    text = searchable_text(name, meta)

    {score, reasons} =
      {0, []}
      |> boost(usb_device_name?(name), 40, "usb-serial name")
      |> boost(Map.has_key?(meta, :vendor_id), 20, "has USB ids")
      |> boost(known_uart_bridge?(meta), 35, known_uart_label(meta))
      |> boost(meshcore_hint?(text), 25, "meshcore-like description")
      |> boost(acm_device?(name), 15, "USB CDC (ACM)")
      |> boost(configured_match?(path, configured), 50, "matches ISTHMUS_MESHCORE_PORT")

    %{
      name: name,
      path: path,
      score: score,
      reasons: Enum.reverse(reasons),
      description: meta[:description],
      manufacturer: meta[:manufacturer],
      serial_number: meta[:serial_number],
      vendor_id: meta[:vendor_id],
      product_id: meta[:product_id]
    }
  end

  defp boost({score, reasons}, true, points, reason),
    do: {score + points, [reason | reasons]}

  defp boost(acc, false, _points, _reason), do: acc

  defp device_path(name) do
    cond do
      String.starts_with?(name, "/") -> name
      String.starts_with?(name, "cu.") or String.starts_with?(name, "tty.") -> "/dev/#{name}"
      true -> "/dev/#{name}"
    end
  end

  defp usb_device_name?(name) do
    String.contains?(name, "ttyUSB") or
      String.contains?(name, "ttyACM") or
      String.contains?(name, "usbmodem") or
      String.contains?(name, "usbserial") or
      String.contains?(name, "cu.usb")
  end

  defp acm_device?(name),
    do: String.contains?(name, "ttyACM") or String.contains?(name, "usbmodem")

  defp known_uart_bridge?(meta) do
    vid = meta[:vendor_id]
    is_integer(vid) and Map.has_key?(@usb_uart_vids, vid)
  end

  defp known_uart_label(meta) do
    case Map.get(@usb_uart_vids, meta[:vendor_id]) do
      nil -> "known USB-UART"
      label -> label
    end
  end

  defp meshcore_hint?(text) do
    Enum.any?(
      ~w(meshcore rak wisblock heltec seeed lilygo tbeam t-beam nrf52 nrf52840 cp210 ch340 companion),
      &String.contains?(text, &1)
    )
  end

  defp configured_match?(path, configured) when is_binary(configured) do
    path == configured or Path.basename(path) == Path.basename(configured)
  end

  defp configured_match?(_, _), do: false

  defp searchable_text(name, meta) do
    [
      name,
      meta[:description],
      meta[:manufacturer],
      meta[:serial_number]
    ]
    |> Enum.reject(&is_nil_or_blank/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  # Drop platform UART noise (ttyS*, ttyAMA without USB meta) unless somehow matched.
  defp system_noise?(%{score: 0, name: name}) do
    String.match?(name, ~r/^ttyS\d+$/) or
      String.match?(name, ~r/^ttyAMA\d+$/) or
      String.match?(name, ~r/^ttyprintk/)
  end

  defp system_noise?(_), do: false

  defp is_nil_or_blank(nil), do: true
  defp is_nil_or_blank(""), do: true
  defp is_nil_or_blank(_), do: false
end
