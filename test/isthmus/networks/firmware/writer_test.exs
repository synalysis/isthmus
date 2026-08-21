defmodule Isthmus.Networks.Firmware.WriterTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Firmware.Writer.Esptool
  alias Isthmus.Networks.Firmware.Writer.Uf2

  test "esptool fails when the sidecar script is missing" do
    assert {:error, :esptool_script_missing} =
             Esptool.write(%{
               path: "/dev/ttyUSB0",
               image_path: __ENV__.file,
               offset: 0x10000,
               script: Path.join(System.tmp_dir!(), "missing-firmware_flash.py")
             })
  end

  test "UF2 writer copies onto a volume then waits for it to leave" do
    tmp = Path.join(System.tmp_dir!(), "isthmus-uf2-#{System.unique_integer([:positive])}")
    vol = Path.join(tmp, "UF2BOOT")
    image = Path.join(tmp, "board.uf2")
    on_exit(fn -> File.rm_rf(tmp) end)

    File.mkdir_p!(vol)
    File.write!(Path.join(vol, "INFO_UF2.TXT"), "UF2 Bootloader")
    File.write!(image, "UF2IMAGE")

    volumes = fn ->
      if File.exists?(Path.join(vol, "board.uf2")), do: [], else: [vol]
    end

    assert :ok =
             Uf2.write(%{
               path: "/dev/ttyACM0",
               image_path: image,
               touch: fn path ->
                 assert path == "/dev/ttyACM0"
                 :ok
               end,
               volumes: volumes,
               timeout_ms: 1_000
             })

    assert File.read!(Path.join(vol, "board.uf2")) == "UF2IMAGE"
  end

  test "UF2 writer treats a hung copy as success once the volume leaves" do
    vol = "/run/media/ape/TRACKER L1"
    image = Path.join(System.tmp_dir!(), "isthmus-uf2-#{System.unique_integer([:positive])}.uf2")
    File.write!(image, "UF2IMAGE")
    on_exit(fn -> File.rm(image) end)

    {:ok, agent} = Agent.start_link(fn -> [vol] end)
    parent = self()

    task =
      Task.async(fn ->
        Uf2.write(%{
          path: "/dev/ttyACM0",
          image_path: image,
          touch: fn _ -> :ok end,
          mounts: fn -> Agent.get(agent, & &1) end,
          volumes: fn -> Agent.get(agent, & &1) end,
          copy: fn _from, _to ->
            send(parent, :copy_started)
            receive do: (:never -> :ok)
          end,
          timeout_ms: 2_000
        })
      end)

    assert_receive :copy_started
    Agent.update(agent, fn _ -> [] end)
    assert Task.await(task) == :ok
  end

  test "UF2 writer accepts EIO after the bootloader reboots" do
    vol = "/run/media/ape/WTL1BOOT"
    image = Path.join(System.tmp_dir!(), "isthmus-uf2-#{System.unique_integer([:positive])}.uf2")
    File.write!(image, "UF2IMAGE")
    on_exit(fn -> File.rm(image) end)

    {:ok, agent} = Agent.start_link(fn -> [vol] end)

    assert :ok =
             Uf2.write(%{
               path: "/dev/ttyACM0",
               image_path: image,
               touch: fn _ -> :ok end,
               mounts: fn -> [] end,
               volumes: fn -> Agent.get(agent, & &1) end,
               copy: fn _from, _to ->
                 Agent.update(agent, fn _ -> [] end)
                 {:error, :eio}
               end,
               timeout_ms: 500
             })
  end

  test "UF2 writer picks a new FAT mount without touching INFO_UF2.TXT" do
    vol = "/run/media/ape/TRACKER L1"
    image = Path.join(System.tmp_dir!(), "isthmus-uf2-#{System.unique_integer([:positive])}.uf2")
    File.write!(image, "UF2IMAGE")
    on_exit(fn -> File.rm(image) end)

    {:ok, agent} = Agent.start_link(fn -> {[], :waiting} end)

    assert :ok =
             Uf2.write(%{
               path: "/dev/ttyACM0",
               image_path: image,
               touch: fn _ ->
                 Agent.update(agent, fn _ -> {[vol], :mounted} end)
                 :ok
               end,
               mounts: fn ->
                 {paths, _} = Agent.get(agent, & &1)
                 paths
               end,
               volumes: fn -> [] end,
               copy: fn _from, to ->
                 assert to == Path.join(vol, Path.basename(image))
                 Agent.update(agent, fn _ -> {[], :gone} end)
                 :ok
               end,
               timeout_ms: 1_000
             })
  end

  test "parse_mounts unescapes TRACKER L1 volume labels" do
    mounts =
      Uf2.parse_mounts("""
      /dev/sdb /run/media/ape/TRACKER\\040L1 vfat rw,relatime 0 0
      proc /proc proc rw 0 0
      """)

    assert %{path: "/run/media/ape/TRACKER L1", fstype: "vfat"} in mounts
    assert Uf2.uf2_label?("TRACKER L1")
    assert Uf2.uf2_label?("WTL1BOOT")
    assert Uf2.uf2_label?("NRF52BOOT")
    refute Uf2.uf2_label?("EFI")
  end
end
