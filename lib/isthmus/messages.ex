defmodule Isthmus.Messages do
  @moduledoc """
  Heard Public radio-channel traffic and, optionally, Isthmus group messages.

  Public MeshCore / Meshtastic channel text is stored so operators can search
  it. Registration-group bodies are **not** kept after gateway distribution
  unless that group has `store_messages` on.
  """

  import Ecto.Query

  alias Isthmus.Messages.Heard
  alias Isthmus.Networks.MeshCore.Channel
  alias Isthmus.Networks.MeshCore.Companion, as: MeshCoreCompanion
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion
  alias Isthmus.Repo

  @default_limit 200
  @networks ~w(meshcore meshtastic reticulum nostr agent)

  def networks, do: @networks

  @doc "Record a heard message. Blank bodies are ignored. Duplicate `external_id` is a no-op."
  def record(attrs) when is_map(attrs) do
    attrs = Map.new(attrs)
    body = attrs[:body] || attrs["body"] || ""
    external_id = blank_to_nil(attrs[:external_id] || attrs["external_id"])

    cond do
      blank?(body) ->
        {:ok, :empty}

      external_id && existing_external_id?(external_id) ->
        {:ok, :duplicate}

      true ->
        seen_at = coerce_seen_at(attrs)
        ingested_at = DateTime.utc_now() |> DateTime.truncate(:second)

        expires_at =
          attrs[:expires_at] || attrs["expires_at"] ||
            DateTime.add(ingested_at, Heard.retention_seconds(), :second)

        %Heard{}
        |> Heard.changeset(%{
          kind: to_string(attrs[:kind] || attrs["kind"] || "channel"),
          network: to_string(attrs[:network] || attrs["network"]),
          channel_name: blank_to_nil(attrs[:channel_name] || attrs["channel_name"]),
          channel_idx: attrs[:channel_idx] || attrs["channel_idx"],
          from_ref: blank_to_nil(attrs[:from_ref] || attrs["from_ref"]),
          sender_name: blank_to_nil(attrs[:sender_name] || attrs["sender_name"]),
          body: String.trim(to_string(body)),
          external_id: external_id,
          registration_group_id: attrs[:registration_group_id] || attrs["registration_group_id"],
          meta: attrs[:meta] || attrs["meta"] || %{},
          seen_at: seen_at,
          expires_at: expires_at
        })
        |> Repo.insert()
        |> tap_broadcast()
    end
  end

  @doc """
  Recent heard messages, newest first.

  Options:
  * `:networks` — filter in SQL
  * `:kinds` — `"channel"` / `"group"`
  * `:per_network` — apply `limit` per selected network then merge
  """
  def list_recent(limit \\ @default_limit, opts \\ [])

  def list_recent(limit, opts) when is_integer(limit) and is_list(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    networks = List.wrap(Keyword.get(opts, :networks, [])) |> Enum.map(&to_string/1)
    kinds = List.wrap(Keyword.get(opts, :kinds, [])) |> Enum.map(&to_string/1)

    cond do
      Keyword.get(opts, :per_network, false) and networks != [] ->
        networks
        |> Enum.flat_map(fn net ->
          recent_query(now, [net], kinds, limit) |> Repo.all()
        end)
        |> Enum.sort_by(& &1.seen_at, {:desc, DateTime})

      true ->
        recent_query(now, networks, kinds, limit) |> Repo.all()
    end
  end

  def purge_expired do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Heard
      |> where([m], m.expires_at <= ^now)
      |> Repo.delete_all()

    count
  end

  @doc "Store a MeshCore companion channel message when the slot is Public."
  def maybe_record_meshcore_channel(attrs) when is_map(attrs) do
    idx = attrs[:channel_idx] || attrs["channel_idx"]

    slot =
      attrs[:slot] || attrs["slot"] ||
        if(is_integer(idx), do: safe_channel(fn -> MeshCoreCompanion.get_channel(idx) end))

    if public_meshcore_slot?(slot, idx) do
      body = attrs[:body] || attrs["body"] || ""
      {sender, text} = split_sender(body)
      meta = stringify(attrs[:meta] || attrs["meta"] || %{})

      record(%{
        kind: "channel",
        network: "meshcore",
        channel_name: present_name(slot && slot[:name]) || "Public",
        channel_idx: idx,
        sender_name: sender,
        body: text,
        seen_at: attrs[:seen_at] || attrs["seen_at"],
        external_id:
          attrs[:external_id] || attrs["external_id"] ||
            meshcore_channel_external_id(idx, meta, body),
        meta: meta
      })
    else
      {:ok, :skipped}
    end
  end

  @doc "Decrypt and store a MeshCore Public GRP_TXT heard on the island."
  def maybe_record_meshcore_packet(packet) when is_binary(packet) do
    case Channel.decrypt_public_text(packet) do
      {:ok, %{name: name, text: text} = parsed} ->
        record(%{
          kind: "channel",
          network: "meshcore",
          channel_name: "Public",
          sender_name: name,
          body: text,
          seen_at: unix_seen_at(parsed[:timestamp]),
          external_id: parsed[:external_id],
          meta: %{"source" => "bridge"}
        })

      _ ->
        {:ok, :skipped}
    end
  end

  def maybe_record_meshcore_packet(_), do: {:ok, :skipped}

  @doc "Store a Meshtastic Primary / Public channel message."
  def maybe_record_meshtastic_channel(attrs) when is_map(attrs) do
    idx = attrs[:channel_idx] || attrs["channel_idx"] || 0

    port =
      attrs[:port] || attrs["port"] || get_in(attrs, [:meta, :port]) ||
        get_in(attrs, [:meta, "port"])

    slot =
      if is_integer(idx), do: safe_channel(fn -> MeshtasticCompanion.get_channel(idx, port) end)

    force? = attrs[:force] in [true, "true"] or attrs["force"] in [true, "true"]

    if force? or public_meshtastic_slot?(slot, idx) do
      meta = stringify(attrs[:meta] || attrs["meta"] || %{})
      packet_id = attrs[:external_id] || attrs["external_id"] || meta["id"]

      record(%{
        kind: "channel",
        network: "meshtastic",
        channel_name: meshtastic_channel_name(slot, idx),
        channel_idx: idx,
        from_ref: attrs[:from_ref] || attrs["from_ref"],
        sender_name: meshtastic_sender_name(attrs[:from_ref] || attrs["from_ref"]),
        body: attrs[:body] || attrs["body"] || "",
        seen_at: attrs[:seen_at] || attrs["seen_at"] || unix_seen_at(meta["rx_time"]),
        external_id: meshtastic_external_id(packet_id),
        meta: meta
      })
    else
      {:ok, :skipped}
    end
  end

  @doc "Store a gateway group message when that group has retention on."
  def maybe_record_group(msg, group) do
    if group_store_messages?(group) do
      record(%{
        kind: "group",
        network: to_string(msg.from_network),
        channel_name: group.display_name,
        from_ref: msg.from_ref,
        sender_name: msg.from_ref,
        body: msg.body,
        external_id: msg.external_id,
        registration_group_id: group.id,
        meta: stringify(msg.meta || %{})
      })
    else
      {:ok, :skipped}
    end
  end

  defp recent_query(now, networks, kinds, limit) do
    Heard
    |> where([m], m.expires_at > ^now)
    |> maybe_networks(networks)
    |> maybe_kinds(kinds)
    |> order_by([m], desc: m.seen_at, desc: m.inserted_at)
    |> limit(^limit)
  end

  defp maybe_networks(q, []), do: q
  defp maybe_networks(q, nets), do: where(q, [m], m.network in ^nets)

  defp maybe_kinds(q, []), do: q
  defp maybe_kinds(q, kinds), do: where(q, [m], m.kind in ^kinds)

  defp tap_broadcast({:ok, %Heard{} = row} = result) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "messages:heard",
      {:heard_message, %{id: row.id, network: row.network, kind: row.kind}}
    )

    result
  end

  defp tap_broadcast(result), do: result

  defp group_store_messages?(%{store_messages: true}), do: true
  defp group_store_messages?(%{"store_messages" => v}) when v in [true, "true"], do: true
  defp group_store_messages?(_), do: false

  defp public_meshcore_slot?(slot, idx) do
    cond do
      Channel.public_slot?(slot) -> true
      is_nil(slot) and idx == 0 -> true
      true -> false
    end
  end

  defp public_meshtastic_slot?(slot, idx) do
    role = slot && (slot[:role] || slot["role"])
    name = slot && (slot[:name] || slot["name"])

    cond do
      is_integer(role) and role == Isthmus.Networks.Meshtastic.Protocol.role_primary() ->
        true

      is_binary(name) and String.downcase(String.trim(name)) == "public" ->
        true

      is_nil(slot) and idx in [0, nil] ->
        true

      idx == 0 ->
        true

      true ->
        false
    end
  end

  defp meshtastic_channel_name(slot, idx) do
    name = present_name(slot && (slot[:name] || slot["name"]))

    cond do
      generic_meshtastic_channel_name?(name) and (idx == 0 or meshtastic_primary_role?(slot)) ->
        "Primary"

      is_binary(name) ->
        name

      idx == 0 ->
        "Primary"

      is_integer(idx) ->
        "slot #{idx}"

      true ->
        "Primary"
    end
  end

  defp meshtastic_primary_role?(slot) do
    role = slot && (slot[:role] || slot["role"])
    is_integer(role) and role == Isthmus.Networks.Meshtastic.Protocol.role_primary()
  end

  defp generic_meshtastic_channel_name?(name) when name in [nil, ""], do: true

  defp generic_meshtastic_channel_name?(name) when is_binary(name) do
    String.downcase(name) in ["channel", "primary", "primary channel"]
  end

  defp generic_meshtastic_channel_name?(_), do: true

  defp present_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_name(_), do: nil

  defp meshtastic_sender_name(ref) when is_binary(ref) and ref != "" do
    case Isthmus.Announce.KnownAddresses.name_for("meshtastic", ref) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp meshtastic_sender_name(_), do: nil

  defp split_sender(body) when is_binary(body) do
    case String.split(body, ": ", parts: 2) do
      [name, text] when name != "" -> {String.trim(name), String.trim(text)}
      _ -> {nil, String.trim(body)}
    end
  end

  defp stringify(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify(_), do: %{}

  defp existing_external_id?(id) when is_binary(id) do
    Heard
    |> where([m], m.external_id == ^id)
    |> Repo.exists?()
  end

  defp coerce_seen_at(attrs) do
    cond do
      match?(%DateTime{}, attrs[:seen_at]) ->
        DateTime.truncate(attrs[:seen_at], :second)

      match?(%DateTime{}, attrs["seen_at"]) ->
        DateTime.truncate(attrs["seen_at"], :second)

      ts = unix_seen_at(attrs[:timestamp] || attrs["timestamp"]) ->
        ts

      true ->
        DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp unix_seen_at(ts) when is_integer(ts) and ts > 1_600_000_000 and ts < 2_200_000_000 do
    DateTime.from_unix!(ts) |> DateTime.truncate(:second)
  end

  defp unix_seen_at(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, ""} -> unix_seen_at(n)
      _ -> nil
    end
  end

  defp unix_seen_at(_), do: nil

  defp meshcore_channel_external_id(idx, meta, body) do
    ts = meta["timestamp"] || meta[:timestamp] || 0
    digest = body |> :erlang.phash2() |> Integer.to_string(16) |> String.downcase()
    "mc-ch-#{idx || 0}-#{ts}-#{digest}"
  end

  defp meshtastic_external_id(id) when is_integer(id) and id > 0, do: "mt-#{id}"
  defp meshtastic_external_id("mt-" <> _ = id), do: id

  defp meshtastic_external_id(id) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> "mt-#{n}"
      _ -> "mt-#{id}"
    end
  end

  defp meshtastic_external_id(_), do: nil

  defp blank?(v), do: v in [nil, ""] or (is_binary(v) and String.trim(v) == "")
  defp blank_to_nil(v), do: if(blank?(v), do: nil, else: v)

  defp safe_channel(fun) do
    fun.()
  rescue
    _ -> nil
  end
end
