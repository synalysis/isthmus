defmodule Isthmus.Tunnel.OutboxTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Repo
  alias Isthmus.Tunnel.Outbox
  alias Isthmus.Tunnel.Outbox.Message

  test "enqueue and fetch due messages" do
    assert {:ok, msg} = Outbox.enqueue("tunnel:abc", "peer", <<"hello">>, %{})
    assert msg.status == "pending"
    assert [^msg | _] = Outbox.due() |> Enum.filter(&(&1.id == msg.id))
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
end
