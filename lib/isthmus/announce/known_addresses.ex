defmodule Isthmus.Announce.KnownAddresses do
  @moduledoc """
  Recently-heard addresses (adverts/announces within the last 24h), with names
  when we know them. Used to power admin autocomplete when attaching members
  and to decorate Adverts / announce-flow tables.

  * MeshCore — companion contact table (`adv_name` + `last_advert`), merged with
    named 24h sightings.
  * Reticulum — 24h announce sightings (name from meta when present).
  * Meshtastic — 24h NodeInfo / node-DB sightings (long name when present).
  """

  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.Companion

  @window_seconds 24 * 60 * 60
  @max 50

  @type suggestion :: %{ref: String.t(), name: String.t() | nil, seen_at: DateTime.t() | nil}

  @doc "Named suggestions for a network, most-recently-heard first."
  @spec for_network(String.t() | atom()) :: [suggestion()]
  def for_network(network) when is_atom(network), do: for_network(Atom.to_string(network))
  def for_network("meshcore"), do: meshcore()
  def for_network("reticulum"), do: reticulum()
  def for_network("meshtastic"), do: meshtastic()
  def for_network(_other), do: []

  @doc """
  Best known display name for an address on a network, or nil.

  Prefers companion contacts (MeshCore), then the newest sighting meta name.
  """
  @spec name_for(String.t() | atom(), String.t()) :: String.t() | nil
  def name_for(network, ref) when is_atom(network), do: name_for(Atom.to_string(network), ref)

  def name_for("meshcore", ref) when is_binary(ref) do
    key = String.downcase(String.trim(ref))

    case Companion.get_contact(key) do
      %{name: name} ->
        case blank_to_nil(name) do
          nil -> sighting_name_for("meshcore", key)
          n -> n
        end

      _ ->
        sighting_name_for("meshcore", key)
    end
  rescue
    _ -> sighting_name_for("meshcore", ref)
  end

  def name_for(network, ref) when is_binary(network) and is_binary(ref) do
    sighting_name_for(network, String.downcase(String.trim(ref)))
  end

  def name_for(_, _), do: nil

  defp meshcore do
    cutoff = System.system_time(:second) - @window_seconds

    from_contacts =
      Companion.list_contacts()
      |> Enum.filter(&recent_advert?(&1, cutoff))
      |> Enum.sort_by(&(&1[:last_advert] || 0), :desc)
      |> Enum.map(fn c ->
        %{ref: to_string(c[:public_key]), name: blank_to_nil(c[:name]), seen_at: c[:last_advert]}
      end)

    from_sightings =
      Sightings.recent_for_network("meshcore", 200)
      |> Enum.map(fn s ->
        %{ref: to_string(s.identity_ref), name: sighting_name(s), seen_at: s.seen_at}
      end)

    # Contacts first so their names win when both sources have the same ref.
    (from_contacts ++ from_sightings)
    |> prefer_named()
    |> dedup_and_cap()
  rescue
    _ ->
      Sightings.recent_for_network("meshcore", 200)
      |> Enum.map(fn s ->
        %{ref: to_string(s.identity_ref), name: sighting_name(s), seen_at: s.seen_at}
      end)
      |> prefer_named()
      |> dedup_and_cap()
  end

  # last_advert is the device's unix time when it last heard the advert; keep
  # plausible-epoch contacts within the window, but don't hide contacts whose
  # clock/timestamp is unknown (0) so the list is never surprisingly empty.
  defp recent_advert?(contact, cutoff) do
    case contact[:last_advert] do
      ts when is_integer(ts) and ts >= 1_000_000_000 -> ts >= cutoff
      _ -> true
    end
  end

  defp reticulum do
    Sightings.recent_for_network("reticulum", 200)
    |> Enum.map(fn s ->
      %{ref: to_string(s.identity_ref), name: sighting_name(s), seen_at: s.seen_at}
    end)
    |> prefer_named()
    |> dedup_and_cap()
  rescue
    _ -> []
  end

  defp meshtastic do
    Sightings.recent_for_network("meshtastic", 200)
    |> Enum.map(fn s ->
      %{ref: to_string(s.identity_ref), name: sighting_name(s), seen_at: s.seen_at}
    end)
    |> prefer_named()
    |> dedup_and_cap()
  rescue
    _ -> []
  end

  defp sighting_name_for(network, ref) do
    case Sightings.best_for(network, ref) do
      %{meta: _} = s -> sighting_name(s)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sighting_name(%{meta: meta}) when is_map(meta) do
    blank_to_nil(meta["name"] || meta["display_name"] || meta[:name] || meta[:display_name])
  end

  defp sighting_name(_), do: nil

  # Propagate the best known name onto every row for a ref (contacts are listed
  # before sightings so a contact name wins), then uniq_by keeps the newest.
  defp prefer_named(list) do
    names =
      Enum.reduce(list, %{}, fn s, acc ->
        case {Map.get(acc, s.ref), s.name} do
          {existing, nil} -> Map.put(acc, s.ref, existing)
          {nil, name} -> Map.put(acc, s.ref, name)
          # Prefer the first non-nil name (contacts are listed before sightings).
          {existing, _name} -> Map.put(acc, s.ref, existing)
        end
      end)

    Enum.map(list, fn s -> %{s | name: Map.get(names, s.ref) || s.name} end)
  end

  defp dedup_and_cap(list) do
    list
    |> Enum.reject(&blank?(&1.ref))
    |> Enum.uniq_by(& &1.ref)
    |> Enum.take(@max)
  end

  defp blank_to_nil(value) do
    case value do
      v when is_binary(v) -> if String.trim(v) == "", do: nil, else: v
      _ -> nil
    end
  end

  defp blank?(v), do: is_nil(v) or (is_binary(v) and String.trim(v) == "")
end
