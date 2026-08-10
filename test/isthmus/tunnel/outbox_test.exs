defmodule Isthmus.Tunnel.OutboxTest do
  use Isthmus.DataCase, async: false

  import Ecto.Query

  alias Isthmus.Repo
  alias Isthmus.Tunnel.Outbox
  alias Isthmus.Tunnel.Outbox.Message

  test "enqueue and fetch due messages" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:abc", "peer", <<"hello">>, %{})
    assert msg.status == "pending"
    assert [^msg | _] = Outbox.due() |> Enum.filter(&(&1.id == msg.id))
  end

  test "mark_retry accepts a non-string error (e.g. a tuple) without crashing" do
    {:ok, msg} = Outbox.enqueue("tunnel:gov", "peer", <<"payload">>, %{})

    assert {:ok, retried} = Outbox.mark_retry(msg, {:governor, :dedup})
    assert retried.status == "pending"
    assert retried.attempts == msg.attempts + 1
    assert retried.last_error =~ "governor"
  end

  test "retry and drop failed messages" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:dlq", "peer", <<"payload">>, %{})

    {:ok, failed} =
      msg
      |> Message.changeset(%{status: "failed", attempts: 12, last_error: "max_attempts"})
      |> Repo.update()

    assert Enum.any?(Outbox.list_failed(), &(&1.id == failed.id))

    assert {:ok, retried} = Outbox.retry(failed.id)
    assert retried.status == "pending"

    {:ok, failed2} =
      retried
      |> Message.changeset(%{status: "failed", attempts: 12, last_error: "again"})
      |> Repo.update()

    assert {:ok, dropped} = Outbox.drop(failed2.id)
    assert dropped.status == "dropped"
    refute Enum.any?(Outbox.list_failed(), &(&1.id == dropped.id))
  end

  test "enqueue is idempotent for the same channel+payload while active" do
    assert {:ok, first} = Outbox.enqueue("tunnel:dedup", "peer", <<"same-bytes">>, %{})
    assert {:ok, second} = Outbox.enqueue("tunnel:dedup", "peer", <<"same-bytes">>, %{})
    assert first.id == second.id

    {:ok, failed} =
      first
      |> Message.changeset(%{status: "failed", attempts: 12, last_error: ":timeout"})
      |> Repo.update()

    assert {:ok, again} = Outbox.enqueue("tunnel:dedup", "peer", <<"same-bytes">>, %{})
    assert again.id == failed.id
    assert again.status == "failed"
  end

  test "collapse_failed_duplicates keeps one copy per channel+payload" do
    payload = <<"dup-payload">>
    assert {:ok, first} = Outbox.enqueue("tunnel:collapse", "peer", payload, %{})

    {:ok, first} =
      first
      |> Message.changeset(%{status: "acked"})
      |> Repo.update()

    # Force a second row with the same hash (pre-dedup legacy path).
    {:ok, second} =
      %Message{}
      |> Message.changeset(%{
        channel: "tunnel:collapse",
        destination: "peer",
        payload: payload,
        payload_hash: first.payload_hash,
        status: "failed",
        attempts: 12,
        last_error: ":timeout",
        next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:second),
        meta: %{}
      })
      |> Repo.insert()

    {:ok, _} =
      first
      |> Message.changeset(%{status: "failed", attempts: 12, last_error: ":timeout"})
      |> Repo.update()

    assert :ok = Outbox.collapse_failed_duplicates()

    failed_ids =
      Outbox.list_failed()
      |> Enum.filter(&(&1.channel == "tunnel:collapse"))
      |> Enum.map(& &1.id)

    assert length(failed_ids) == 1
    assert hd(failed_ids) in [first.id, second.id]
  end

  test "enqueue tags durable class on opaque data" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:class", "peer", <<"user-dm">>, %{})
    assert msg.meta["class"] == "durable"
  end

  test "enqueue tags ephemeral class on control announce" do
    payload =
      Jason.encode!(%{"v" => 1, "op" => "announce", "network" => "meshcore", "ref" => "a"})

    assert {:ok, msg} =
             Outbox.enqueue("tunnel:ann", "peer", payload, %{"kind" => "control"})

    assert msg.meta["class"] == "ephemeral"
  end

  test "ephemeral mark_retry drops instead of entering DLQ after max attempts" do
    payload =
      Jason.encode!(%{"v" => 1, "op" => "announce", "network" => "meshcore", "ref" => "b"})

    assert {:ok, msg} =
             Outbox.enqueue("tunnel:eph-fail", "peer", payload, %{"kind" => "control"})

    {:ok, msg} =
      msg
      |> Message.changeset(%{attempts: 11})
      |> Repo.update()

    assert {:ok, dropped} = Outbox.mark_retry(msg, :timeout)
    assert dropped.status == "dropped"
    refute Enum.any?(Outbox.list_failed(), &(&1.id == dropped.id))
  end

  test "ephemeral_expired? and expire drop aged announce payloads" do
    payload =
      Jason.encode!(%{"v" => 1, "op" => "announce", "network" => "meshcore", "ref" => "c"})

    assert {:ok, msg} =
             Outbox.enqueue("tunnel:eph-ttl", "peer", payload, %{"kind" => "control"})

    old = DateTime.utc_now() |> DateTime.add(-(Outbox.ephemeral_ttl_sec() + 5), :second)
    old = DateTime.truncate(old, :second)

    from(m in Message, where: m.id == ^msg.id)
    |> Repo.update_all(set: [inserted_at: old])

    msg = Repo.get!(Message, msg.id)
    assert Outbox.ephemeral_expired?(msg)

    assert {:ok, dropped} = Outbox.mark_retry(msg, :timeout)
    assert dropped.status == "dropped"
  end

  test "durable keeps pending after many failures (unattended retry)" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:dur-fail", "peer", <<"keep-me">>, %{})

    {:ok, msg} =
      msg
      |> Message.changeset(%{attempts: 11})
      |> Repo.update()

    assert {:ok, retried} = Outbox.mark_retry(msg, :timeout)
    assert retried.status == "pending"
    assert retried.attempts == 12
    assert retried.last_error == ":timeout"
    refute Enum.any?(Outbox.list_failed(), &(&1.id == retried.id))
  end

  test "defer reschedules without burning attempts" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:defer", "peer", <<"wait">>, %{})
    assert {:ok, deferred} = Outbox.defer(msg, :tunnel_unreachable, 30)
    assert deferred.status == "pending"
    assert deferred.attempts == msg.attempts
    assert deferred.last_error == ":tunnel_unreachable"
    assert DateTime.compare(deferred.next_attempt_at, msg.next_attempt_at) == :gt
  end

  test "requeue_failed_for_tunnel only requeues durable rows" do
    ann = Jason.encode!(%{"v" => 1, "op" => "announce", "network" => "meshcore", "ref" => "d"})

    assert {:ok, durable} = Outbox.enqueue("tunnel:tq1", "peer", <<"important">>, %{})
    assert {:ok, eph} = Outbox.enqueue("tunnel:tq1", "peer", ann, %{"kind" => "control"})

    {:ok, _} =
      durable
      |> Message.changeset(%{status: "failed", attempts: 12, last_error: ":timeout"})
      |> Repo.update()

    # Force an ephemeral failed row (legacy / race) — should not be requeued.
    {:ok, _} =
      eph
      |> Message.changeset(%{status: "failed", attempts: 12, last_error: ":timeout"})
      |> Repo.update()

    assert 1 == Outbox.requeue_failed_for_tunnel("tq1")

    durable = Repo.get!(Message, durable.id)
    eph = Repo.get!(Message, eph.id)
    assert durable.status == "pending"
    assert eph.status == "failed"
  end

  test "list_waiting_by_tunnel groups active rows by tunnel id" do
    assert {:ok, a} = Outbox.enqueue("tunnel:wa", "peer", <<"one">>, %{})
    assert {:ok, b} = Outbox.enqueue("tunnel:wb", "peer", <<"two">>, %{})
    assert {:ok, _} = Outbox.enqueue("gateway:nostr", "npub", <<"three">>, %{})

    by = Outbox.list_waiting_by_tunnel(["wa", "wb", "missing"])
    assert Map.has_key?(by, "wa")
    assert Map.has_key?(by, "wb")
    refute Map.has_key?(by, "missing")
    assert Enum.any?(by["wa"], &(&1.id == a.id))
    assert Enum.any?(by["wb"], &(&1.id == b.id))
  end

  test "nudge schedules an active message immediately" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:nudge", "peer", <<"go">>, %{})

    later = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)

    {:ok, msg} =
      msg
      |> Message.changeset(%{next_attempt_at: later, last_error: ":timeout"})
      |> Repo.update()

    assert {:ok, nudged} = Outbox.nudge(msg.id)
    assert nudged.status == "pending"
    assert is_nil(nudged.last_error)
    assert DateTime.compare(nudged.next_attempt_at, later) == :lt
  end

  test "MeshCore TXT_MSG retries coalesce when trailing ciphertext matches" do
    alias Isthmus.Networks.MeshCore.{Crypto, Packet, TxtMsg}

    {our_pub, seed} = Crypto.generate_keypair()
    {dest_pub, _} = Crypto.generate_keypair()
    ts = System.system_time(:second)
    # Long enough that ciphertext spans >1 AES block (attempt only touches block 0).
    text = "hello-retry-with-enough-bytes"

    packets =
      for attempt <- 0..3 do
        {:ok, %{packet: packet}} =
          TxtMsg.build(
            seed: seed,
            our_pub: our_pub,
            dest_pub: dest_pub,
            text: text,
            timestamp: ts,
            attempt: attempt
          )

        assert Packet.logical_message_key(packet)
        packet
      end

    assert length(Enum.uniq(packets)) == 4

    assert {:ok, first} =
             Outbox.enqueue("tunnel:mc-retry", "peer", hd(packets), %{"kind" => "data"})

    Enum.each(tl(packets), fn packet ->
      assert {:ok, updated} =
               Outbox.enqueue("tunnel:mc-retry", "peer", packet, %{"kind" => "data"})

      assert updated.id == first.id
      assert updated.payload == packet
      assert updated.meta["logical_key"]
    end)

    active =
      Message
      |> where([m], m.channel == "tunnel:mc-retry" and m.status in ^~w(pending inflight failed))
      |> Repo.all()

    assert length(active) == 1
    assert hd(active).payload == List.last(packets)
  end

  test "short MeshCore TXT_MSG retries are not guessed as equal" do
    alias Isthmus.Networks.MeshCore.{Crypto, Packet, TxtMsg}

    {our_pub, seed} = Crypto.generate_keypair()
    {dest_pub, _} = Crypto.generate_keypair()
    ts = System.system_time(:second)

    packets =
      for attempt <- 0..2 do
        {:ok, %{packet: packet}} =
          TxtMsg.build(
            seed: seed,
            our_pub: our_pub,
            dest_pub: dest_pub,
            text: "short",
            timestamp: ts,
            attempt: attempt
          )

        refute Packet.logical_message_key(packet)
        packet
      end

    ids =
      Enum.map(packets, fn packet ->
        assert {:ok, msg} =
                 Outbox.enqueue("tunnel:mc-short", "peer", packet, %{"kind" => "data"})

        msg.id
      end)

    assert length(Enum.uniq(ids)) == 3
  end

  test "collapse_logical_duplicates drops older MeshCore TXT_MSG retries" do
    alias Isthmus.Networks.MeshCore.{Crypto, Packet, TxtMsg}
    alias Isthmus.Tunnel.Frame

    {our_pub, seed} = Crypto.generate_keypair()
    {dest_pub, _} = Crypto.generate_keypair()
    ts = System.system_time(:second)

    packets =
      for attempt <- 0..2 do
        {:ok, %{packet: packet}} =
          TxtMsg.build(
            seed: seed,
            our_pub: our_pub,
            dest_pub: dest_pub,
            text: "collapse-me-with-enough-bytes",
            timestamp: ts,
            attempt: attempt
          )

        packet
      end

    # Bypass enqueue coalescing to simulate legacy duplicate rows.
    msgs =
      Enum.map(packets, fn packet ->
        hash = Base.encode16(Frame.hash16(packet), case: :lower)
        key = Packet.logical_message_key(packet)
        assert key

        {:ok, msg} =
          %Message{}
          |> Message.changeset(%{
            channel: "tunnel:mc-collapse",
            destination: "peer",
            payload: packet,
            payload_hash: hash,
            status: "pending",
            next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:second),
            meta: %{"logical_key" => key}
          })
          |> Repo.insert()

        msg
      end)

    assert length(msgs) == 3
    assert :ok = Outbox.collapse_logical_duplicates()

    active =
      Message
      |> where(
        [m],
        m.channel == "tunnel:mc-collapse" and m.status in ^~w(pending inflight failed)
      )
      |> Repo.all()

    assert length(active) == 1
  end
end
