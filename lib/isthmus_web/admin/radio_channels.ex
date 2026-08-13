defmodule IsthmusWeb.Admin.RadioChannels do
  @moduledoc false

  alias Isthmus.Registrations

  @type group :: Isthmus.Registrations.RegistrationGroup.t()

  @spec parse_slot(term()) :: integer()
  def parse_slot(idx) when is_integer(idx), do: idx

  def parse_slot(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, ""} -> n
      _ -> -1
    end
  end

  def parse_slot(_), do: -1

  @spec blank_port(term()) :: String.t() | nil
  def blank_port(port) when is_binary(port) and port != "", do: port
  def blank_port(_), do: nil

  @spec linked_group([group()], integer(), String.t() | nil, String.t()) :: group() | nil
  def linked_group(_groups, _idx, nil, _network), do: nil

  def linked_group(groups, idx, radio_id, network) do
    Enum.find(groups, fn g ->
      g.status == "active" and
        match?(%{channel_idx: ^idx}, Registrations.radio_link(g, network, radio_id))
    end)
  end

  @spec assignable_groups([group()], integer(), String.t() | nil, String.t()) :: [group()]
  def assignable_groups(bridges, idx, radio_id, network) do
    Enum.filter(bridges, fn g ->
      case Registrations.radio_link(g, network, radio_id) do
        nil -> true
        %{channel_idx: ^idx} -> true
        _ -> false
      end
    end)
  end

  @spec occupied_slot_indexes([map()]) :: [integer()]
  def occupied_slot_indexes(channels) when is_list(channels) do
    for ch <- channels, ch.index in 1..7, ch.empty? != true, do: ch.index
  end

  @spec empty_channel?([map()] | nil, integer()) :: boolean()
  def empty_channel?(channels, idx) do
    case Enum.find(channels || [], &(&1.index == idx)) do
      %{empty?: true} -> true
      nil -> true
      _ -> false
    end
  end
end
