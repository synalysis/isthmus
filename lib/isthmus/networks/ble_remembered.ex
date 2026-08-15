defmodule Isthmus.Networks.BLERemembered do
  @moduledoc false

  alias Isthmus.Policy

  @networks [:meshtastic, :meshcore]

  @spec list(:meshtastic | :meshcore) :: [map()]
  def list(network) when network in @networks do
    Policy.get(key(network))
    |> normalize_list()
  rescue
    _ -> []
  end

  @spec remember(:meshtastic | :meshcore, String.t(), keyword()) :: :ok
  def remember(network, address, opts \\ []) when network in @networks do
    address = norm_addr(address)
    name = name_opt(opts)

    if address == "" do
      :ok
    else
      current = list(network)
      existing = Enum.find(current, &(&1["address"] == address))

      cond do
        match?(%{"name" => ^name}, existing) ->
          :ok

        existing && is_nil(name) ->
          :ok

        true ->
          entry = %{"address" => address, "name" => name || existing["name"]}
          persist(network, [entry | Enum.reject(current, &(&1["address"] == address))])
      end
    end
  end

  @spec forget(:meshtastic | :meshcore, String.t()) :: :ok
  def forget(network, address) when network in @networks do
    address = norm_addr(address)
    persist(network, Enum.reject(list(network), &(&1["address"] == address)))
  end

  @doc "Remember BLE radios that are already running (so a restart can restore them)."
  @spec remember_healths(:meshtastic | :meshcore, [map()]) :: :ok
  def remember_healths(network, healths) when network in @networks and is_list(healths) do
    Enum.each(healths, fn health ->
      addr = health[:ble_address] || address_from_port(health[:port])
      status = health[:status]

      if is_binary(addr) and addr != "" and status in [:online, :connecting, :error] do
        remember(network, addr, name: health[:name])
      end
    end)

    :ok
  end

  defp address_from_port("ble:" <> rest), do: rest
  defp address_from_port("BLE:" <> rest), do: rest
  defp address_from_port(_), do: nil

  defp persist(network, entries) do
    case Policy.put(key(network), entries) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp key(:meshtastic), do: "ble_companions_meshtastic"
  defp key(:meshcore), do: "ble_companions_meshcore"

  defp norm_addr(address) when is_binary(address) do
    address
    |> String.trim()
    |> then(fn
      "ble:" <> rest -> rest
      "BLE:" <> rest -> rest
      other -> other
    end)
    |> String.upcase()
  end

  defp norm_addr(_), do: ""

  defp name_opt(opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp normalize_list(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"address" => addr} = entry when is_binary(addr) ->
        wrap_addr(addr, entry["name"])

      addr when is_binary(addr) ->
        wrap_addr(addr, nil)

      _ ->
        []
    end)
  end

  defp normalize_list(_), do: []

  defp wrap_addr(addr, name) do
    case norm_addr(addr) do
      "" -> []
      address -> [%{"address" => address, "name" => empty_to_nil(name)}]
    end
  end

  defp empty_to_nil(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp empty_to_nil(_), do: nil
end
