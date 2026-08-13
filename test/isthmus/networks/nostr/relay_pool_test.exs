defmodule Isthmus.Networks.Nostr.RelayPoolInboundTest do
  use Isthmus.DataCase, async: false

  import Ecto.Query

  alias Isthmus.Announce.Governor.Event, as: GovernorEvent
  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Networks.Nostr.TunnelCarrier
  alias Isthmus.Repo

  setup do
    translator = Process.whereis(Isthmus.Gateway.Translator)

    if translator do
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), translator)
    end

    :ok
  end

  test "broadcasts a DM once when several relays echo the same event id" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "nostr:inbound")
    pubkey = unique_hex()
    event = dm_event(pubkey)
    before = gateway_drops(pubkey)

    send(RelayPool, {:nostr_event, "wss://relay-a.example", event})
    assert_receive {:event, "wss://relay-a.example", ^event}, 1_000

    send(RelayPool, {:nostr_event, "wss://relay-b.example", event})
    refute_receive {:event, _, _}, 150
    drain_gateway()

    assert gateway_drops(pubkey) == before
  end

  test "does not broadcast tunnel frames on the gateway topic" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "nostr:inbound")
    pubkey = unique_hex()
    before = gateway_drops(pubkey)

    event = %{
      "id" => unique_id(),
      "pubkey" => pubkey,
      "kind" => TunnelCarrier.kind(),
      "content" => Base.encode64("ISTH"),
      "tags" => [["t", TunnelCarrier.tag()]]
    }

    send(RelayPool, {:nostr_event, "wss://relay-a.example", event})
    refute_receive {:event, _, _}, 150
    drain_gateway()
    assert gateway_drops(pubkey) == before
  end

  test "distinct DMs from the same author are not collapsed" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "nostr:inbound")
    pubkey = unique_hex()
    first = dm_event(pubkey)
    second = dm_event(pubkey)

    send(RelayPool, {:nostr_event, "wss://relay-a.example", first})
    send(RelayPool, {:nostr_event, "wss://relay-a.example", second})

    assert_receive {:event, _, ^first}, 1_000
    assert_receive {:event, _, ^second}, 1_000
    drain_gateway()
  end

  defp drain_gateway do
    _ = :sys.get_state(RelayPool)
    translator = Process.whereis(Isthmus.Gateway.Translator)
    if translator, do: _ = :sys.get_state(translator)
    :ok
  end

  defp dm_event(pubkey) do
    %{
      "id" => unique_id(),
      "pubkey" => pubkey,
      "kind" => 4,
      "content" => "hi",
      "tags" => [],
      "created_at" => System.os_time(:second)
    }
  end

  defp gateway_drops(pubkey) do
    GovernorEvent
    |> where(
      [e],
      e.network == "nostr" and e.class == "gateway_message" and e.identity_key == ^pubkey
    )
    |> Repo.aggregate(:count)
  end

  defp unique_hex, do: unique_id()

  defp unique_id do
    Integer.to_string(System.unique_integer([:positive]), 16)
    |> String.pad_leading(64, "0")
    |> String.downcase()
  end
end
