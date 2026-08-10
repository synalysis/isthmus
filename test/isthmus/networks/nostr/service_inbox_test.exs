defmodule Isthmus.Networks.Nostr.ServiceInboxTest do
  use ExUnit.Case, async: false

  alias Isthmus.Networks.Nostr.ServiceInbox

  setup do
    ServiceInbox.clear()
    :ok
  end

  test "records and lists recent DMs newest first" do
    ServiceInbox.record(%{
      from_ref: String.duplicate("aa", 32),
      body: "first",
      external_id: "svc-1"
    })

    ServiceInbox.record(%{
      from_ref: String.duplicate("bb", 32),
      body: "second",
      external_id: "svc-2",
      meta: %{"subject" => "isthmus/lobby"}
    })

    [a, b] = ServiceInbox.list(10)
    assert a.body == "second"
    assert a.subject == "isthmus/lobby"
    assert b.body == "first"
  end
end
