defmodule Isthmus.Announce.Inbound do
  @moduledoc """
  Records inbound announces/adverts as 24h sightings (with display names when
  known) so they can be listed on Adverts and suggested when attaching members.

  Throttled so periodic re-announces don't flood the table; a recent nameless
  sighting is upgraded in place once we learn its name.
  """

  require Logger
  alias Isthmus.Announce.Sightings

  # Keep at most one recorded sighting per address per window (unless upgrading name).
  @dedup_window_seconds 900

  @doc """
  Handle a sidecar `announce` message:
  `%{"destination_hash" => hex, "name" => name, "aspect" => "lxmf.delivery"}`.

  Only LXMF delivery announces are persisted (those are the addresses used when
  attaching Reticulum members). Recording runs off the caller so the IPC loop
  never blocks.
  """
  def handle_reticulum(%{"destination_hash" => dh} = msg)
      when is_binary(dh) and dh != "" do
    aspect = msg["aspect"]
    name = normalize_name(msg["name"])

    cond do
      # Primary: LXMF delivery destinations (what Attach-member uses).
      aspect == "lxmf.delivery" ->
        log_and_record(dh, name, aspect)

      # Unclassified but name decoded from LXMF-shaped app_data.
      (is_nil(aspect) or aspect == "") and is_binary(name) ->
        log_and_record(dh, name, aspect)

      true ->
        :ok
    end
  end

  def handle_reticulum(_), do: :ok

  defp log_and_record(dh, name, aspect) do
    Logger.info(
      "RNS announce #{String.slice(dh, 0, 8)}… name=#{inspect(name)} aspect=#{inspect(aspect)}"
    )

    record("reticulum", dh, name, "announce")
  end

  @doc "Record a MeshCore advert/contact sighting with optional display name."
  def record_meshcore(pubkey_hex, name, source \\ "advert")
      when is_binary(pubkey_hex) do
    # Off the companion GenServer — contact sync can deliver many at once.
    Task.start(fn -> record("meshcore", pubkey_hex, normalize_name(name), source) end)
    :ok
  end

  @doc false
  def record_reticulum(destination_hash, name) do
    record("reticulum", destination_hash, normalize_name(name), "announce")
  end

  @doc false
  def record(network, identity_ref, name, source)
      when is_binary(network) and is_binary(identity_ref) do
    ref = String.downcase(String.trim(identity_ref))

    if ref == "" do
      :ok
    else
      case decide(network, ref, name) do
        :skip ->
          :ok

        {:upgrade, row} ->
          case Sightings.put_name(row, name) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.debug("announce name upgrade failed: #{inspect(reason)}")
          end

        :insert ->
          meta =
            %{"source" => to_string(source)}
            |> maybe_put_name(name)

          case Sightings.record(%{
                 network: network,
                 direction: "in",
                 identity_ref: ref,
                 meta: meta
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.debug("announce sighting failed: #{inspect(reason)}")
          end
      end
    end
  rescue
    e -> Logger.debug("announce record error: #{inspect(e)}")
  end

  defp decide(network, ref, name) do
    case Sightings.best_for(network, ref) do
      %{seen_at: %DateTime{} = seen_at, meta: meta} = row ->
        age = DateTime.diff(DateTime.utc_now(), seen_at, :second)
        existing = sighting_name(meta)

        cond do
          age >= @dedup_window_seconds ->
            :insert

          is_binary(name) and name != "" and is_nil(existing) ->
            {:upgrade, row}

          true ->
            :skip
        end

      _ ->
        :insert
    end
  end

  defp sighting_name(meta) when is_map(meta), do: normalize_name(meta["name"] || meta[:name])
  defp sighting_name(_), do: nil

  defp maybe_put_name(meta, nil), do: meta
  defp maybe_put_name(meta, name), do: Map.put(meta, "name", name)

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_name(_), do: nil
end
