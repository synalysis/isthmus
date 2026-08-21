defmodule Isthmus.Networks.Firmware.Board do
  @moduledoc """
  Curated radio boards Isthmus can map to firmware catalog assets.
  """

  @type id :: atom()

  @boards [
    %{
      id: :wio_tracker_l1,
      label: "Seeed Wio Tracker L1",
      programmer: :uf2,
      vids: [{0x2886, 0x1667}, {0x2886, 0x0057}],
      hints: ["wio tracker", "tracker l1"],
      companion: ~r/WioTrackerL1_companion_radio_usb/i,
      island: ~r/WioTrackerL1.*(bridge_usbserial|repeater_bridge)/i,
      meshtastic: ~r/seeed[-_]wio[-_]tracker[-_]l1/i,
      rnode: nil
    },
    %{
      id: :t1000_e,
      label: "SenseCAP T1000-E",
      programmer: :uf2,
      vids: [{0x239A, nil}],
      hints: ["t1000", "tracker t1000"],
      companion: ~r/(T1000|SenseCap_T1000|Tracker_T1000).*companion_radio_usb/i,
      island: ~r/(T1000|SenseCap_T1000).*bridge/i,
      meshtastic: ~r/tracker[-_]t1000[-_]e/i,
      rnode: nil
    },
    %{
      id: :rak4631,
      label: "RAK4631",
      programmer: :uf2,
      vids: [],
      hints: ["rak4631", "rak 4631", "wisblock"],
      companion: ~r/RAK_4631_companion_radio_usb/i,
      island: ~r/RAK_4631.*(bridge_usbserial|repeater_bridge)/i,
      meshtastic: ~r/rak4631/i,
      rnode: ~r/rnode_firmware_rak4631/i
    },
    %{
      id: :heltec_v3,
      label: "Heltec V3",
      programmer: :esptool,
      vids: [],
      hints: ["heltec v3", "wifi lora 32(v3)", "wifi lora 32 v3"],
      companion: ~r/Heltec_v3.*companion/i,
      island: ~r/Heltec_v3.*bridge/i,
      meshtastic: ~r/heltec[-_]?v3/i,
      rnode: ~r/rnode_firmware_heltec32v3/i
    },
    %{
      id: :heltec_t114,
      label: "Heltec T114",
      programmer: :uf2,
      vids: [],
      hints: ["heltec t114", "t114"],
      companion: ~r/Heltec_t114_companion_radio_usb/i,
      island: ~r/Heltec_t114.*bridge/i,
      meshtastic: ~r/heltec[-_]mesh[-_]node[-_]t114|heltec[-_]t114/i,
      rnode: ~r/rnode_firmware_heltec_t114/i
    },
    %{
      id: :tbeam,
      label: "LilyGO T-Beam",
      programmer: :esptool,
      vids: [],
      hints: ["t-beam", "tbeam"],
      companion: ~r/Tbeam(?!_Supreme).*companion/i,
      island: ~r/Tbeam(?!_Supreme).*bridge/i,
      meshtastic: ~r/(^|[^_])tbeam([^_]|$)|tbeam[-_]1e/i,
      rnode: ~r/rnode_firmware_tbeam(?!_supreme|_sx1262)/i
    },
    %{
      id: :tbeam_supreme,
      label: "LilyGO T-Beam Supreme",
      programmer: :esptool,
      vids: [],
      hints: ["t-beam supreme", "tbeam supreme"],
      companion: ~r/Tbeam_Supreme.*companion/i,
      island: ~r/Tbeam_Supreme.*bridge/i,
      meshtastic: ~r/tbeam[-_]supreme/i,
      rnode: ~r/rnode_firmware_tbeam_supreme/i
    },
    %{
      id: :t3s3,
      label: "LilyGO T3-S3",
      programmer: :esptool,
      vids: [],
      hints: ["t3-s3", "t3s3"],
      companion: ~r/T3S3.*companion|LilyGo_T3S3.*companion/i,
      island: ~r/T3S3.*bridge|LilyGo_T3S3.*bridge/i,
      meshtastic: ~r/t3[-_]?s3/i,
      rnode: ~r/rnode_firmware_t3s3(?!_)/i
    },
    %{
      id: :sensecap_solar,
      label: "SenseCAP Solar",
      programmer: :uf2,
      vids: [],
      hints: ["sensecap solar", "mesh solar"],
      companion: ~r/(SenseCap_Solar|Heltec_mesh_solar).*companion_radio_usb/i,
      island: ~r/(SenseCap_Solar|Heltec_mesh_solar).*bridge/i,
      meshtastic: ~r/seeed[-_]solar[-_]node|sensecap[-_]solar/i,
      rnode: nil
    },
    %{
      id: :xiao_nrf52,
      label: "Seeed XIAO nRF52",
      programmer: :uf2,
      vids: [],
      hints: ["xiao nrf", "xiao_nrf52"],
      companion: ~r/Xiao_nrf52_companion_radio_usb/i,
      island: ~r/Xiao_nrf52.*bridge/i,
      meshtastic: ~r/xiao[-_]nrf52/i,
      rnode: nil
    }
  ]

  @spec all() :: [map()]
  def all, do: @boards

  @spec options() :: [{String.t(), String.t()}]
  def options do
    Enum.map(@boards, &{&1.label, Atom.to_string(&1.id)})
  end

  @spec get(id() | String.t() | nil) :: map() | nil
  def get(id) when is_atom(id), do: Enum.find(@boards, &(&1.id == id))

  def get(id) when is_binary(id) do
    case String.trim(id) do
      "" ->
        nil

      trimmed ->
        Enum.find(@boards, fn board -> Atom.to_string(board.id) == trimmed end)
    end
  end

  def get(_), do: nil

  @spec guess(map() | nil) :: id() | nil
  def guess(device) when is_map(device) do
    vid = device[:vendor_id] || device["vendor_id"]
    pid = device[:product_id] || device["product_id"]

    desc =
      [
        device[:description],
        device[:manufacturer],
        device[:label],
        device[:firmware_model],
        get_in(device, [:companion_health, :firmware_model]),
        get_in(device, [:health, :firmware_model])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      match = Enum.find(@boards, &vid_pid_hit?(&1, vid, pid)) ->
        match.id

      match = Enum.find(@boards, &hint_hit?(&1, desc)) ->
        match.id

      true ->
        nil
    end
  end

  def guess(_), do: nil

  @spec programmer(id() | map() | String.t() | nil) :: :esptool | :uf2 | nil
  def programmer(board) when is_map(board), do: board[:programmer]
  def programmer(id) when is_atom(id) or is_binary(id), do: id |> get() |> programmer()
  def programmer(_), do: nil

  @spec asset_regex(id() | map() | nil, atom()) :: Regex.t() | nil
  def asset_regex(board, kind) when is_map(board), do: Map.get(board, kind)
  def asset_regex(id, kind), do: id |> get() |> asset_regex(kind)

  defp vid_pid_hit?(board, vid, pid) when is_integer(vid) do
    Enum.any?(board.vids, fn
      {^vid, nil} -> true
      {^vid, want_pid} when is_integer(pid) -> want_pid == pid
      _ -> false
    end)
  end

  defp vid_pid_hit?(_, _, _), do: false

  defp hint_hit?(_board, ""), do: false

  defp hint_hit?(board, desc) do
    Enum.any?(board.hints, &String.contains?(desc, &1))
  end
end
