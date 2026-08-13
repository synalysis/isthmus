defmodule Isthmus.MCP.JSON do
  @moduledoc false

  @redact [
    :__meta__,
    :encrypted_private_material,
    :secret_enc,
    :meshcore_channel_secret_enc,
    :meshtastic_channel_psk_enc,
    :auth_secret
  ]

  @redact_names Enum.map(@redact, &Atom.to_string/1)

  def encode(data) do
    data |> sanitize() |> Jason.encode!(pretty: true)
  end

  def sanitize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def sanitize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def sanitize(%MapSet{} = set), do: set |> MapSet.to_list() |> sanitize()
  def sanitize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> sanitize()

  def sanitize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop(@redact)
    |> sanitize()
  end

  def sanitize(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> redacted?(k, sanitize_key(k)) end)
    |> Map.new(fn {k, v} -> {sanitize_key(k), sanitize(v)} end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  def sanitize(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom) do
    Atom.to_string(atom)
  end

  def sanitize(bin) when is_binary(bin) do
    if String.valid?(bin), do: bin, else: Base.encode16(bin, case: :lower)
  end

  def sanitize(other), do: other

  defp sanitize_key(k) when is_atom(k), do: Atom.to_string(k)
  defp sanitize_key(k), do: to_string(k)

  defp redacted?(k, _key) when is_atom(k), do: k in @redact
  defp redacted?(_k, key), do: key in @redact_names
end
