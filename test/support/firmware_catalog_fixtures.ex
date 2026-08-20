defmodule Isthmus.FirmwareCatalogFixtures do
  @moduledoc false

  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.MeshCore.Companion.Status, as: MeshStatus
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion.Status, as: MeshtasticStatus

  def put_catalog do
    Catalog.put_snapshot(Catalog.fixture_snapshot())
  end

  def wio_detail(path \\ "/dev/ttyACM2") do
    %{
      path: path,
      description: "Seeed Wio Tracker L1",
      manufacturer: "Seeed",
      serial_number: "WIO1",
      vendor_id: 0x2886,
      product_id: 0x1667
    }
  end

  def heltec_detail(path \\ "/dev/ttyUSB0") do
    %{
      path: path,
      description: "Heltec WiFi LoRa 32(V3)",
      manufacturer: "Silicon Labs",
      serial_number: "HT1",
      vendor_id: 0x10C4,
      product_id: 0xEA60
    }
  end

  def seed_discover_roles(roles) when is_map(roles) do
    previous = Discover.roles()
    :sys.replace_state(Discover, fn state -> %{state | roles: roles} end)
    previous
  end

  def restore_discover_roles(roles) when is_map(roles) do
    :sys.replace_state(Discover, fn state -> %{state | roles: roles} end)
    :ok
  end

  def seed_meshcore_wio(opts \\ []) do
    version = Keyword.get(opts, :firmware_version, "1.16.0")
    detail = wio_detail()

    previous =
      seed_discover_roles(%{
        companion: %{path: detail.path, source: :assigned, detail: detail},
        companion_ports: [%{path: detail.path, source: :assigned, detail: detail}]
      })

    MeshStatus.ensure_ets(MeshStatus.status_table())

    :ets.insert(
      MeshStatus.status_table(),
      {{:health, detail.path},
       %{
         status: :online,
         port: detail.path,
         firmware_version: version,
         self_name: "Wio",
         primary?: true
       }}
    )

    put_catalog()
    {previous, detail}
  end

  def cleanup_meshcore_wio(previous) do
    restore_discover_roles(previous)
    _ = :ets.delete(MeshStatus.status_table(), {:health, wio_detail().path})
    :ok
  end

  def seed_meshtastic_wio(opts \\ []) do
    version = Keyword.get(opts, :firmware_version, "2.7.15.567b8ea")
    path = Keyword.get(opts, :path, "/dev/ttyUSB9")
    detail = wio_detail(path)

    previous =
      seed_discover_roles(%{
        meshtastic: %{path: path, source: :assigned, detail: detail},
        meshtastic_ports: [%{path: path, source: :assigned, detail: detail}]
      })

    MeshtasticStatus.ensure_ets(MeshtasticStatus.status_table())

    :ets.insert(
      MeshtasticStatus.status_table(),
      {{:health, path},
       %{
         status: :online,
         port: path,
         firmware_version: version,
         name: "Wio",
         primary?: true
       }}
    )

    put_catalog()
    {previous, detail}
  end

  def cleanup_meshtastic_wio(previous, path \\ "/dev/ttyUSB9") do
    restore_discover_roles(previous)
    _ = :ets.delete(MeshtasticStatus.status_table(), {:health, path})
    :ok
  end

  def seed_rnode_heltec(opts \\ []) do
    version = Keyword.get(opts, :firmware_version, "1.80")
    detail = heltec_detail("/dev/ttyACM3")

    previous =
      seed_discover_roles(%{
        rnode: %{path: detail.path, source: :detected, detail: detail},
        rnode_ports: [
          %{path: detail.path, source: :detected, detail: detail, firmware_version: version}
        ]
      })

    put_catalog()
    {previous, detail}
  end
end
