defmodule Isthmus.Nostr.Event do
  @moduledoc """
  NIP-01 event helpers built on `nostr_lib`.
  """

  # nostr_lib's `t()` requires id/sig binaries, but `create/2` builds unsigned
  # events with nil id/sig. Dialyzer then flags every sign/compute_id call.
  @dialyzer {:nowarn_function, [sign: 2, compute_id: 1]}

  @doc """
  Compute event id (hex) from event fields per NIP-01.
  """
  def compute_id(%{
        pubkey: pubkey,
        created_at: created_at,
        kind: kind,
        tags: tags,
        content: content
      })
      when is_binary(pubkey) and is_integer(created_at) and is_integer(kind) and is_list(tags) and
             is_binary(content) do
    nostr_tags =
      Enum.map(tags, fn
        %Nostr.Tag{} = tag -> tag
        list when is_list(list) -> Nostr.Tag.parse(list)
      end)
      |> Enum.reject(&is_nil/1)

    %Nostr.Event{
      kind: kind,
      pubkey: String.downcase(pubkey),
      tags: nostr_tags,
      created_at: DateTime.from_unix!(created_at),
      content: content
    }
    |> Nostr.Event.compute_id()
  end

  @doc "Sign an event (including unsigned structs from `Nostr.Event.create/2`)."
  @spec sign(struct(), String.t()) :: struct()
  def sign(%Nostr.Event{} = event, seckey_hex) when is_binary(seckey_hex) do
    # apply/3 keeps Dialyzer from using nostr_lib's success typing (id/sig required).
    apply(Nostr.Event, :sign, [event, seckey_hex])
  end

  @doc """
  Verify a signed Nostr event map with hex pubkey/id/sig fields.
  """
  def verify(event) when is_map(event) do
    case Nostr.Event.parse(stringify_keys(event)) do
      %Nostr.Event{pubkey: pubkey} when is_binary(pubkey) ->
        {:ok, String.downcase(pubkey)}

      _ ->
        {:error, :invalid_signature}
    end
  end

  def verify(_), do: {:error, :invalid_event}

  @doc "Convert a `Nostr.Event` struct to a string-keyed wire map for relay publish."
  def to_wire_map(%Nostr.Event{} = event) do
    %{
      "id" => event.id,
      "pubkey" => event.pubkey,
      "created_at" => DateTime.to_unix(event.created_at),
      "kind" => event.kind,
      "tags" => Enum.map(event.tags, &tag_to_list/1),
      "content" => event.content,
      "sig" => event.sig
    }
  end

  defp tag_to_list(%Nostr.Tag{type: type, data: nil, info: info}) do
    [Atom.to_string(type) | info]
  end

  defp tag_to_list(%Nostr.Tag{type: type, data: data, info: info}) do
    [Atom.to_string(type), data | info]
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
