defmodule Isthmus.Registrations.Radio do
  @moduledoc false

  import Ecto.Query
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion
  alias Isthmus.Networks.Meshtastic.Protocol, as: MeshtasticProtocol
  alias Isthmus.Registrations.{GroupRadioChannel, Query, RegistrationGroup}
  alias Isthmus.Repo
  alias Isthmus.Vault

  @type group :: RegistrationGroup.t()
  @type link :: GroupRadioChannel.t()
  @type network :: String.t()
  @type opts :: keyword()
  @type result(ok) :: {:ok, ok} | {:error, term()}

  @spec links(group(), atom() | network()) :: [link()]
  def links(%RegistrationGroup{radio_channels: channels}, network) when is_list(channels) do
    net = to_string(network)

    channels
    |> Enum.filter(&(&1.network == net))
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
  end

  def links(%RegistrationGroup{} = group, network) do
    group |> Repo.preload(:radio_channels) |> links(network)
  end

  def links(_, _), do: []

  @spec link(group(), atom() | network(), String.t() | nil) :: link() | nil
  def link(group, network, device_id) do
    device_id = normalize_radio_id(device_id)
    links = links(group, network)

    if is_binary(device_id) do
      Enum.find(links, &(normalize_radio_id(&1.device_id) == device_id))
    else
      Enum.find(links, &is_nil(normalize_radio_id(&1.device_id))) || List.first(links)
    end
  end

  @spec find_by_channel(network(), integer(), String.t() | nil) :: group() | nil
  def find_by_channel(network, idx, device_id \\ nil)

  def find_by_channel(network, idx, device_id) when is_integer(idx) do
    find_group_by_radio_link(to_string(network), idx, normalize_radio_id(device_id))
  end

  @spec link_channel(group(), network(), integer(), String.t(), opts()) :: result(group())
  def link_channel(%RegistrationGroup{kind: "bridge"} = group, network, idx, secret_hex, opts)
      when network in ["meshcore", "meshtastic"] and is_integer(idx) and idx in 0..7 and
             is_binary(secret_hex) and is_list(opts) do
    device_id = normalize_radio_id(Keyword.get(opts, :device_id))
    hex = String.downcase(secret_hex)

    with :ok <- ensure_radio_slot_free(network, idx, device_id, group.id),
         {:ok, enc} <- Vault.encrypt(%{secret_field(network) => hex}) do
      upsert_radio_link(group, network, idx, enc, device_id)
    end
  end

  def link_channel(%RegistrationGroup{}, _, _, _, _), do: {:error, :not_a_bridge_group}

  @spec unlink_channel(group(), network(), opts()) :: result(group())
  def unlink_channel(%RegistrationGroup{} = group, network, opts) when is_list(opts) do
    delete_radio_links(group, to_string(network), Keyword.get(opts, :device_id))
  end

  @spec provision(group(), network(), opts()) :: result(group())
  def provision(%RegistrationGroup{kind: "bridge"} = group, network, opts)
      when network in ["meshcore", "meshtastic"] do
    name = Keyword.get(opts, :name) || group.display_name || "Channel"
    requested = Keyword.get(opts, :idx)
    port = Keyword.get(opts, :port)
    device_id = device_id(network, port)

    with :ok <- companion_online(network, port),
         :ok <- ensure_group_radio_free(group, network, device_id),
         {:ok, idx} <- pick_slot(network, requested, port),
         {:ok, channel} <- set_channel(network, idx, name, port),
         {:ok, hex} <- channel_secret(network, channel) do
      link_channel(group, network, idx, hex, device_id: device_id)
    end
  end

  def provision(%RegistrationGroup{}, _, _), do: {:error, :not_a_bridge_group}

  @spec invite(group(), network(), opts()) :: result(map())
  def invite(%RegistrationGroup{kind: "bridge", status: "active"} = group, network, opts)
      when network in ["meshcore", "meshtastic"] and is_list(opts) do
    case link(group, network, Keyword.get(opts, :device_id)) do
      %{channel_idx: idx, secret_enc: enc} when is_integer(idx) and is_binary(enc) ->
        invite_from_link(group, network, idx, enc)

      _ ->
        {:error, :no_channel_linked}
    end
  end

  def invite(%RegistrationGroup{}, _, _), do: {:error, :no_channel_linked}

  @spec companion_online(network(), String.t() | nil) :: :ok | {:error, :not_connected}
  def companion_online(network, port \\ nil) do
    case companion(network).health(port) do
      %{status: :online} -> :ok
      _ -> {:error, :not_connected}
    end
  end

  @spec pick_slot(network(), integer() | nil, String.t() | nil) ::
          {:ok, integer()} | {:error, :slot_occupied | :invalid_slot | :no_empty_channel_slot}
  def pick_slot(network, nil, port), do: first_empty_slot(companion(network).list_channels(port))

  def pick_slot(network, idx, port) when is_integer(idx) and idx in 1..7 do
    case Enum.find(companion(network).list_channels(port), &(&1.index == idx)) do
      %{empty?: false} -> {:error, :slot_occupied}
      _ -> {:ok, idx}
    end
  end

  def pick_slot(_, _, _), do: {:error, :invalid_slot}

  @spec set_channel(network(), integer(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def set_channel(network, idx, name, port) do
    companion(network).set_channel(idx, name, nil, port)
  end

  @spec device_id(network(), String.t() | nil) :: String.t() | nil
  def device_id("meshcore", port) do
    case Companion.health(port) do
      %{self_ref: id} -> normalize_radio_id(id)
      _ -> nil
    end
  end

  def device_id("meshtastic", port) do
    case MeshtasticCompanion.health(port) do
      %{node_id: id} -> normalize_radio_id(id)
      _ -> nil
    end
  end

  @spec normalize_radio_id(term()) :: String.t() | nil
  def normalize_radio_id(nil), do: nil
  def normalize_radio_id(""), do: nil

  def normalize_radio_id(id) when is_binary(id) do
    id = id |> String.trim() |> String.trim_leading("!") |> String.downcase()
    if id == "", do: nil, else: id
  end

  def normalize_radio_id(_), do: nil

  @spec claim_unscoped_radio_channel(atom() | network(), String.t() | nil, [integer()]) :: :ok
  def claim_unscoped_radio_channel(network, device_id, occupied_idxs)
      when network in [:meshcore, :meshtastic, "meshcore", "meshtastic"] and
             is_list(occupied_idxs) do
    device_id = normalize_radio_id(device_id)
    idxs = Enum.filter(occupied_idxs, &(&1 in 1..7))
    net = to_string(network)

    if is_binary(device_id) and idxs != [] do
      unscoped =
        from(c in GroupRadioChannel,
          where: c.network == ^net and is_nil(c.device_id) and c.channel_idx in ^idxs
        )
        |> Repo.all()

      Enum.each(unscoped, fn row ->
        conflict =
          Repo.one(
            from(c in GroupRadioChannel,
              where:
                c.network == ^net and c.device_id == ^device_id and
                  c.channel_idx == ^row.channel_idx,
              limit: 1
            )
          )

        if is_nil(conflict) do
          case row
               |> GroupRadioChannel.changeset(%{device_id: device_id})
               |> Repo.update() do
            {:ok, _} -> sync_group_channel_cache(row.registration_group_id)
            {:error, _} -> :ok
          end
        end
      end)
    end

    :ok
  end

  def claim_unscoped_radio_channel(_, _, _), do: :ok

  defp invite_from_link(group, network, idx, enc) do
    case Vault.decrypt(enc) do
      {:ok, material} when is_map(material) ->
        case decrypted_secret(network, material) do
          secret when is_binary(secret) ->
            {:ok, invite_payload(network, group, idx, secret)}

          _ ->
            {:error, :invite_unavailable}
        end

      _ ->
        {:error, :invite_unavailable}
    end
  end

  defp invite_payload("meshcore", group, idx, secret) do
    name = invite_name("meshcore", group, idx)
    uri = "meshcore://channel/add?name=#{URI.encode_www_form(name)}&secret=#{secret}"
    %{slot: idx, name: name, secret_hex: secret, uri: uri}
  end

  defp invite_payload("meshtastic", group, idx, secret) do
    name = invite_name("meshtastic", group, idx)
    cached = MeshtasticCompanion.get_channel(idx)

    ch = %{
      index: idx,
      name: name,
      psk_hex: secret,
      channel_id: cached && cached[:channel_id]
    }

    %{
      slot: idx,
      name: name,
      psk_hex: secret,
      secret_hex: secret,
      uri: MeshtasticProtocol.channel_invite_uri(ch)
    }
  end

  defp invite_name(network, group, idx) do
    case companion(network).get_channel(idx) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> group.display_name || "Channel"
    end
  end

  defp channel_secret("meshcore", %{secret_hex: hex}) when is_binary(hex), do: {:ok, hex}
  defp channel_secret("meshtastic", %{psk_hex: hex}) when is_binary(hex), do: {:ok, hex}
  defp channel_secret(_, _), do: {:error, :invite_unavailable}

  defp decrypted_secret(network, material) do
    {string_key, atom_key} = secret_keys(network)

    case Map.get(material, string_key) || Map.get(material, atom_key) do
      s when is_binary(s) and s != "" -> String.downcase(s)
      _ -> nil
    end
  end

  defp secret_field("meshcore"), do: "secret_hex"
  defp secret_field("meshtastic"), do: "psk_hex"

  defp secret_keys("meshcore"), do: {"secret_hex", :secret_hex}
  defp secret_keys("meshtastic"), do: {"psk_hex", :psk_hex}

  defp companion("meshcore"), do: Companion
  defp companion("meshtastic"), do: MeshtasticCompanion

  defp find_group_by_radio_link(network, idx, device_id) do
    query =
      from(c in GroupRadioChannel,
        join: g in assoc(c, :registration_group),
        where: g.status == "active" and c.network == ^network and c.channel_idx == ^idx,
        select: g.id,
        limit: 1
      )

    query =
      if is_binary(device_id) do
        from([c, g] in query, where: c.device_id == ^device_id)
      else
        from([c, g] in query, where: is_nil(c.device_id))
      end

    case Repo.one(query) do
      nil -> nil
      id -> Query.get_group!(id)
    end
  end

  defp ensure_radio_slot_free(network, idx, device_id, group_id) do
    case find_group_by_radio_link(network, idx, device_id) do
      nil ->
        :ok

      %{id: existing_id} ->
        if to_string(existing_id) == to_string(group_id) do
          :ok
        else
          {:error, :channel_already_linked}
        end
    end
  end

  defp ensure_group_radio_free(group, network, device_id) do
    case link(group, network, device_id) do
      nil -> :ok
      _ -> {:error, :already_linked}
    end
  end

  defp upsert_radio_link(group, network, idx, enc, device_id) do
    attrs = %{
      registration_group_id: group.id,
      network: network,
      device_id: device_id,
      channel_idx: idx,
      secret_enc: enc
    }

    result =
      (existing_radio_row(group.id, network, device_id) || %GroupRadioChannel{})
      |> GroupRadioChannel.changeset(attrs)
      |> Repo.insert_or_update()

    case result do
      {:ok, _} ->
        _ = sync_group_channel_cache(group.id)
        {:ok, Query.get_group!(group.id)}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_error?(changeset) do
          {:error, :channel_already_linked}
        else
          {:error, changeset}
        end
    end
  end

  defp existing_radio_row(group_id, network, device_id) do
    scoped =
      from(c in GroupRadioChannel,
        where: c.registration_group_id == ^group_id and c.network == ^network
      )

    scoped =
      if is_binary(device_id) do
        from(c in scoped, where: c.device_id == ^device_id)
      else
        from(c in scoped, where: is_nil(c.device_id))
      end

    case Repo.one(scoped) do
      %GroupRadioChannel{} = row ->
        row

      nil when is_binary(device_id) ->
        from(c in GroupRadioChannel,
          where:
            c.registration_group_id == ^group_id and c.network == ^network and
              is_nil(c.device_id),
          limit: 1
        )
        |> Repo.one()

      nil ->
        nil
    end
  end

  defp delete_radio_links(group, network, device_id) do
    query =
      from(c in GroupRadioChannel,
        where: c.registration_group_id == ^group.id and c.network == ^network
      )

    query =
      case normalize_radio_id(device_id) do
        id when is_binary(id) -> from(c in query, where: c.device_id == ^id)
        _ -> query
      end

    Repo.delete_all(query)
    _ = sync_group_channel_cache(group.id)
    {:ok, Query.get_group!(group.id)}
  end

  defp sync_group_channel_cache(group_id) do
    group =
      RegistrationGroup
      |> Repo.get!(group_id)
      |> Repo.preload(:radio_channels)

    mc = List.first(links(group, "meshcore"))
    mt = List.first(links(group, "meshtastic"))

    group
    |> RegistrationGroup.changeset(%{
      meshcore_channel_idx: mc && mc.channel_idx,
      meshcore_channel_secret_enc: mc && mc.secret_enc,
      meshcore_channel_device_id: mc && mc.device_id,
      meshtastic_channel_idx: mt && mt.channel_idx,
      meshtastic_channel_psk_enc: mt && mt.secret_enc,
      meshtastic_channel_device_id: mt && mt.device_id
    })
    |> Repo.update()
  end

  defp unique_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp first_empty_slot(channels) do
    by_idx = Map.new(channels, &{&1.index, &1})

    case Enum.find(1..7, fn i ->
           case Map.get(by_idx, i) do
             %{empty?: true} -> true
             nil -> true
             _ -> false
           end
         end) do
      nil -> {:error, :no_empty_channel_slot}
      idx -> {:ok, idx}
    end
  end
end
