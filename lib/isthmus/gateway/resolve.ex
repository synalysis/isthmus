defmodule Isthmus.Gateway.Resolve do
  @moduledoc false

  alias Isthmus.Gateway.Message
  alias Isthmus.Registrations

  @type group :: Isthmus.Registrations.RegistrationGroup.t()

  @spec group(Message.t()) :: {group() | nil, Message.t()}
  def group(%Message{group_id: id} = msg) when is_binary(id) and id != "" do
    case Registrations.get_group(id) do
      %{status: "active"} = group -> {group, msg}
      _ -> {nil, msg}
    end
  end

  def group(%Message{from_network: :nostr} = msg) do
    subject = msg.meta["subject"] || msg.meta[:subject]
    to = msg.to_ref && String.downcase(msg.to_ref)
    from = msg.from_ref && String.downcase(msg.from_ref)

    group =
      (is_binary(to) && Registrations.find_by_leg(:nostr, to)) ||
        (is_binary(subject) && Registrations.find_by_nostr_subject(subject)) ||
        (is_binary(from) && Registrations.find_by_leg(:nostr, from))

    {group, msg}
  end

  def group(%Message{from_network: :meshcore} = msg), do: meshcore_group(msg)
  def group(%Message{from_network: :meshtastic} = msg), do: meshtastic_group(msg)

  def group(%Message{from_network: net, to_ref: to} = msg)
      when net in [:reticulum, "reticulum"] do
    group =
      (is_binary(to) && Registrations.find_by_leg(:reticulum, String.downcase(to))) ||
        (is_binary(msg.from_ref) &&
           Registrations.find_by_leg(:reticulum, String.downcase(msg.from_ref)))

    {group, msg}
  end

  def group(%Message{from_network: net, from_ref: from} = msg) when is_binary(from) do
    {Registrations.find_by_leg(net, from), msg}
  end

  def group(msg), do: {nil, msg}

  @spec channel_idx(Message.t(), String.t()) :: integer() | nil
  def channel_idx(%Message{meta: meta}, "meshcore") when is_map(meta) do
    parse_idx(meta["meshcore_channel"] || meta[:meshcore_channel])
  end

  def channel_idx(%Message{meta: meta}, "meshtastic") when is_map(meta) do
    parse_idx(meta["meshtastic_channel"] || meta[:meshtastic_channel])
  end

  def channel_idx(_, _), do: nil

  defp parse_idx(idx) when is_integer(idx), do: idx

  defp parse_idx(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_idx(_), do: nil

  @spec radio_id(Message.t()) :: term()
  def radio_id(%Message{meta: meta}) when is_map(meta) do
    meta["radio_id"] || meta[:radio_id]
  end

  def radio_id(_), do: nil

  defp meshcore_group(%Message{} = msg) do
    case channel_idx(msg, "meshcore") do
      idx when not is_nil(idx) ->
        {Registrations.find_by_meshcore_channel(idx, radio_id(msg)), msg}

      nil ->
        meshcore_dm_group(msg)
    end
  end

  defp meshcore_dm_group(%Message{} = msg) do
    from = msg.from_ref && String.downcase(msg.from_ref)
    to = msg.to_ref && String.downcase(msg.to_ref)

    cond do
      is_binary(to) && Registrations.find_by_leg(:meshcore, to) ->
        {Registrations.find_by_leg(:meshcore, to), msg}

      is_binary(from) && Registrations.find_by_leg(:meshcore, from) ->
        {Registrations.find_by_leg(:meshcore, from), msg}

      token = extract_address_token(msg.body) ->
        case Registrations.find_by_token(token) do
          nil -> {nil, msg}
          group -> {group, strip_address_token(msg, token)}
        end

      true ->
        {nil, msg}
    end
  end

  defp meshtastic_group(%Message{} = msg) do
    case channel_idx(msg, "meshtastic") do
      idx when not is_nil(idx) ->
        {Registrations.find_by_meshtastic_channel(idx, radio_id(msg)), msg}

      nil when is_binary(msg.from_ref) ->
        {Registrations.find_by_leg(:meshtastic, msg.from_ref), msg}

      nil ->
        {nil, msg}
    end
  end

  defp extract_address_token(body) when is_binary(body) do
    case Regex.run(~r/^\s*@([A-Za-z0-9_-]{2,64})\b/, body) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp strip_address_token(%Message{body: body} = msg, token) when is_binary(body) do
    stripped =
      body
      |> String.replace(~r/^\s*@#{Regex.escape(token)}\b\s*/i, "")
      |> String.trim_leading()

    %{msg | body: stripped}
  end
end
