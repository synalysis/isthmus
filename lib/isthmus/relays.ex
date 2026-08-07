defmodule Isthmus.Relays do
  @moduledoc "Nostr relay configuration."

  import Ecto.Query
  alias Isthmus.Relays.Relay
  alias Isthmus.Repo

  def list_relays do
    Repo.all(from r in Relay, order_by: [asc: r.priority, asc: r.url])
  end

  def get_relay!(id), do: Repo.get!(Relay, id)

  def create_relay(attrs) do
    result =
      %Relay{}
      |> Relay.changeset(attrs)
      |> Repo.insert()

    with {:ok, relay} <- result do
      reload_pool()
      {:ok, relay}
    end
  end

  def update_relay(%Relay{} = relay, attrs) do
    result =
      relay
      |> Relay.changeset(attrs)
      |> Repo.update()

    with {:ok, relay} <- result do
      reload_pool()
      {:ok, relay}
    end
  end

  def delete_relay(%Relay{} = relay) do
    result = Repo.delete(relay)
    reload_pool()
    result
  end

  def change_relay(%Relay{} = relay, attrs \\ %{}), do: Relay.changeset(relay, attrs)

  defp reload_pool do
    try do
      Isthmus.Networks.Nostr.RelayPool.reload()
    catch
      :exit, _ -> :ok
    end
  end
end
