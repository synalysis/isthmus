defmodule Isthmus.Networks.MeshCore.BridgeLinkTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.MeshCore.BridgeFrame
  alias Isthmus.Networks.MeshCore.BridgeLink

  defmodule FakeTransport do
    @moduledoc false
    @behaviour Isthmus.Networks.MeshCore.Transport

    @impl true
    def connect(%{port: "/dev/broken"}), do: {:error, :enoent}

    @impl true
    def connect(%{port: port} = opts) do
      {:ok, %{port: port, test_pid: Map.fetch!(opts, :test_pid)}}
    end

    @impl true
    def write(%{test_pid: pid}, data) do
      send(pid, {:bridge_write, data})
      :ok
    end

    @impl true
    def close(_), do: :ok

    @impl true
    def info(%{port: port}), do: %{type: :fake, port: port}
  end

  defp start_link!(opts) do
    test_pid = self()

    defaults = [
      name: :"bridge_link_#{System.unique_integer([:positive])}",
      port: "/dev/fake",
      transport_mod: FakeTransport,
      transport_opts: %{test_pid: test_pid},
      forward: fn packet -> send(test_pid, {:forwarded, packet}) end
    ]

    pid = start_supervised!({BridgeLink, Keyword.merge(defaults, opts)})
    Ecto.Adapters.SQL.Sandbox.allow(Isthmus.Repo, test_pid, pid)
    {pid, Keyword.get(Keyword.merge(defaults, opts), :name)}
  end

  defp feed(pid, data) do
    send(pid, {:circuits_uart, "/dev/fake", data})
    # Force the message to be processed before we assert.
    _ = :sys.get_state(pid)
    :ok
  end

  describe "without a configured port" do
    test "stays disabled instead of retrying forever" do
      {_pid, name} = start_link!(port: nil)

      health = BridgeLink.health(name)
      assert health.status == :disabled
      assert health.last_error =~ "bridge packet port"
      refute BridgeLink.configured?(name)
    end

    test "inject reports the bridge is disabled" do
      {_pid, name} = start_link!(port: nil)
      assert {:error, :bridge_disabled} = BridgeLink.inject(name, <<1, 2, 3>>)
    end
  end

  describe "receiving from the island" do
    test "connects and reports online" do
      {_pid, name} = start_link!([])

      health = BridgeLink.health(name)
      assert health.status == :online
      assert health.port == "/dev/fake"
      assert health.frames_in == 0
    end

    test "decoded packets reach the forwarder" do
      {pid, name} = start_link!([])
      packet = <<0x04, 0x00, 0xAB, 0xCD>>

      feed(pid, BridgeFrame.encode!(packet))

      assert_received {:forwarded, ^packet}
      assert BridgeLink.health(name).frames_in == 1
    end

    test "default_forward publishes bridge_rx for synthetic fan-out" do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:bridge_rx")
      packet = <<0x11, 0x22, 0x33>>

      assert :ok = BridgeLink.default_forward(packet)
      assert_receive {:bridge_packet, ^packet}, 500
    end

    test "a frame split across reads is reassembled" do
      {pid, _name} = start_link!([])
      packet = <<9, 8, 7, 6, 5>>
      encoded = BridgeFrame.encode!(packet)
      {head, tail} = :erlang.split_binary(encoded, 4)

      feed(pid, head)
      refute_received {:forwarded, _}

      feed(pid, tail)
      assert_received {:forwarded, ^packet}
    end

    test "line noise is counted and the next frame still decodes" do
      {pid, name} = start_link!([])
      packet = <<1, 1, 1>>

      feed(pid, <<0xFF, 0xFE, 0xFD>> <> BridgeFrame.encode!(packet))

      assert_received {:forwarded, ^packet}
      assert BridgeLink.health(name).dropped_bytes == 3
    end

    test "a corrupt frame is rejected and counted" do
      {pid, name} = start_link!([])
      good = <<2, 2, 2>>
      encoded = BridgeFrame.encode!(good)
      last_index = byte_size(encoded) - 1
      <<head::binary-size(^last_index), last>> = encoded
      corrupt = head <> <<Bitwise.bxor(last, 0xFF)>>

      feed(pid, corrupt <> encoded)

      assert_received {:forwarded, ^good}
      health = BridgeLink.health(name)
      assert health.checksum_errors == 1
      assert health.frames_in == 1
    end
  end

  describe "injecting onto the island" do
    test "writes a well-formed bridge frame" do
      {_pid, name} = start_link!([])
      packet = <<0xDE, 0xAD, 0xBE, 0xEF>>

      assert :ok = BridgeLink.inject(name, packet)

      assert_received {:bridge_write, frame}
      assert frame == BridgeFrame.encode!(packet)
      assert BridgeLink.health(name).frames_out == 1
    end

    test "an injected packet is marked as bridged so an echo can't loop back" do
      {_pid, name} = start_link!([])
      packet = <<0x42, 0x43, 0x44, 0x45>>

      refute dedup_recorded?(packet)
      assert :ok = BridgeLink.inject(name, packet)
      assert dedup_recorded?(packet)
    end

    test "rejects a packet larger than MeshCore can carry" do
      {_pid, name} = start_link!([])
      assert {:error, :invalid_length} = BridgeLink.inject(name, :binary.copy(<<0>>, 300))
      refute_received {:bridge_write, _}
    end

    test "rejects an empty packet without touching the transport" do
      {_pid, name} = start_link!([])
      assert {:error, :invalid_packet} = BridgeLink.inject(name, <<>>)
      refute_received {:bridge_write, _}
    end
  end

  describe "connection failures" do
    test "a failed connect is recorded and retried later" do
      {_pid, name} = start_link!(port: "/dev/broken")

      health = BridgeLink.health(name)
      assert health.status == :error
      assert health.last_error =~ "enoent"
    end
  end

  # Read-only view of the dedup table; Dedup.seen?/2 records as a side effect.
  defp dedup_recorded?(packet) do
    hash = Base.encode16(Isthmus.Tunnel.Frame.hash16(packet), case: :lower)
    Repo.get_by(Isthmus.Announce.Dedup.Entry, dedup_key: "tunnel_pkt|#{hash}") != nil
  end
end
