defmodule Isthmus.Tunnel.Outbox.Class do
  @moduledoc """
  Classify outbox payloads as `:ephemeral` or `:durable`.

  Ephemeral (announces / MeshCore adverts & path packets) should not pile up in
  the DLQ. Durable traffic (messages, opaque data, unknown) is kept and retried.
  """

  alias Isthmus.Networks.MeshCore.Packet

  @ephemeral_meshcore_types [Packet.type_advert(), Packet.type_path()]

  @doc "Return `:ephemeral` or `:durable` for a payload + meta map."
  def classify(payload, meta \\ %{}) when is_binary(payload) do
    meta = stringify_keys(meta)

    cond do
      control_announce?(meta, payload) -> :ephemeral
      meshcore_ephemeral?(payload) -> :ephemeral
      true -> :durable
    end
  end

  @doc "True when message meta (or payload) is classified ephemeral."
  def ephemeral?(meta, payload \\ nil)

  def ephemeral?(meta, payload) when is_map(meta) do
    case Map.get(stringify_keys(meta), "class") do
      "ephemeral" -> true
      "durable" -> false
      _ when is_binary(payload) -> classify(payload, meta) == :ephemeral
      _ -> false
    end
  end

  def ephemeral?(_, payload) when is_binary(payload), do: classify(payload) == :ephemeral
  def ephemeral?(_, _), do: false

  def durable?(meta, payload \\ nil), do: not ephemeral?(meta, payload)

  defp control_announce?(meta, payload) do
    kind = meta["kind"]

    if kind in ["control", :control] do
      case Jason.decode(payload) do
        {:ok, %{"op" => "announce"}} ->
          true

        {:ok, %{op: "announce"}} ->
          true

        _ ->
          # Control frames without a parseable body still count as ephemeral
          # (pings do not use the outbox).
          true
      end
    else
      false
    end
  end

  defp meshcore_ephemeral?(payload) do
    case Packet.decode(payload) do
      {:ok, %{payload_type: type}} -> type in @ephemeral_meshcore_types
      _ -> false
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
