defmodule Isthmus.Networks.Reticulum.ConfigFileTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Reticulum.ConfigFile

  @fixture """
  # Top comment stays.

  [reticulum]

    # keep me
    enable_transport = False
    share_instance = Yes
    instance_name = default

  [logging]
    loglevel = 4

  # Interfaces preamble comment
  [interfaces]

    # This interface enables communication
    [[Default Interface]]
      type = AutoInterface
      enabled = Yes

  """

  setup do
    dir = Path.join(System.tmp_dir!(), "isthmus-rns-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, @fixture)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: path, dir: dir}
  end

  test "list_interfaces parses blocks", %{path: path} do
    assert {:ok, [iface]} = ConfigFile.list_interfaces(path)
    assert iface.name == "Default Interface"
    assert iface.type == "AutoInterface"
    assert iface.enabled == true
  end

  test "round-trip without edits preserves comments", %{path: path} do
    original = File.read!(path)
    assert {:error, :not_found} = ConfigFile.remove_interface("missing", path)
    assert File.read!(path) == original

    assert {:ok, _} =
             ConfigFile.add_interface(
               %{
                 name: "TCP Peer",
                 type: "TCPClientInterface",
                 target_host: "127.0.0.1",
                 target_port: "4242"
               },
               path
             )

    text = File.read!(path)
    assert text =~ "# Top comment stays."
    assert text =~ "# keep me"
    assert text =~ "# This interface enables communication"
    assert text =~ "[[Default Interface]]"
    assert text =~ "[[TCP Peer]]"
    assert text =~ "target_host = 127.0.0.1"
  end

  test "remove_interface keeps unrelated comments", %{path: path} do
    assert {:ok, _} =
             ConfigFile.add_interface(%{name: "Extra", type: "AutoInterface"}, path)

    assert {:ok, _} = ConfigFile.remove_interface("Extra", path)
    text = File.read!(path)
    assert text =~ "# Top comment stays."
    assert text =~ "[[Default Interface]]"
    refute text =~ "[[Extra]]"
  end

  test "set_share_instance replaces active line only", %{path: path} do
    assert {:ok, _} = ConfigFile.set_share_instance(false, path)
    text = File.read!(path)
    assert text =~ ~r/^\s*share_instance = No/m
    assert text =~ "# keep me"
    refute ConfigFile.share_instance?(path)
  end

  test "rejects duplicate names and bad types", %{path: path} do
    assert {:error, :already_exists} =
             ConfigFile.add_interface(%{name: "Default Interface", type: "AutoInterface"}, path)

    assert {:error, :unsupported_type} =
             ConfigFile.add_interface(%{name: "Radio", type: "NotARealInterface"}, path)
  end

  test "adds RNodeInterface with radio fields", %{path: path} do
    assert {:error, :missing_port} =
             ConfigFile.add_interface(%{name: "Radio", type: "RNodeInterface"}, path)

    assert {:ok, _} =
             ConfigFile.add_interface(
               %{
                 name: "RNode USB",
                 type: "RNodeInterface",
                 port: "/dev/ttyACM3",
                 frequency: 915_000_000,
                 bandwidth: 125_000,
                 txpower: 7,
                 spreadingfactor: 8,
                 codingrate: 5
               },
               path
             )

    assert {:ok, ifaces} = ConfigFile.list_interfaces(path)
    rnode = Enum.find(ifaces, &(&1.name == "RNode USB"))
    assert rnode.type == "RNodeInterface"
    assert rnode.port == "/dev/ttyACM3"
    assert rnode.frequency == "915000000"
    assert rnode.spreadingfactor == "8"

    text = File.read!(path)
    assert text =~ "[[RNode USB]]"
    assert text =~ "type = RNodeInterface"
    assert text =~ "port = /dev/ttyACM3"
  end

  test "set_interface_enabled toggles without dropping comments", %{path: path} do
    assert {:ok, _} = ConfigFile.set_interface_enabled("Default Interface", false, path)
    text = File.read!(path)
    assert text =~ "# This interface enables communication"
    assert text =~ ~r/^\s*enabled = No/m

    assert {:ok, [iface]} = ConfigFile.list_interfaces(path)
    assert iface.enabled == false

    assert {:ok, _} = ConfigFile.set_interface_enabled("Default Interface", true, path)
    assert {:ok, [iface]} = ConfigFile.list_interfaces(path)
    assert iface.enabled == true
  end
end
