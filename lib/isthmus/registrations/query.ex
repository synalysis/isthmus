defmodule Isthmus.Registrations.Query do
  @moduledoc false

  import Ecto.Query
  alias Isthmus.Registrations.{IdentityLeg, RegistrationGroup}
  alias Isthmus.Repo

  @group_preloads [:legs, :radio_channels]

  @type group :: RegistrationGroup.t()
  @type leg :: IdentityLeg.t()
  @type network :: String.t() | atom()

  @spec list_all() :: [group()]
  def list_all do
    RegistrationGroup
    |> order_by([g], desc: g.inserted_at)
    |> preload(^@group_preloads)
    |> Repo.all()
  end

  @spec list_by_kind(String.t()) :: [group()]
  def list_by_kind(kind) when kind in ["registration", "bridge"] do
    RegistrationGroup
    |> where([g], g.kind == ^kind)
    |> order_by([g], desc: g.inserted_at)
    |> preload(^@group_preloads)
    |> Repo.all()
  end

  @spec get_for_owner(String.t()) :: [group()]
  def get_for_owner(pubkey_hex) do
    hex = String.downcase(pubkey_hex)

    RegistrationGroup
    |> where([g], g.owner_pubkey_hex == ^hex and g.status != "revoked")
    |> order_by([g], desc: g.inserted_at)
    |> preload(^@group_preloads)
    |> Repo.all()
  end

  @spec active_registration_for_owner(String.t()) :: group() | nil
  def active_registration_for_owner(pubkey_hex) do
    hex = String.downcase(pubkey_hex)

    RegistrationGroup
    |> where(
      [g],
      g.owner_pubkey_hex == ^hex and g.status == "active" and g.kind == "registration"
    )
    |> preload(^@group_preloads)
    |> Repo.one()
  end

  @spec get_group(term()) :: group() | nil
  def get_group(id) do
    RegistrationGroup
    |> preload(^@group_preloads)
    |> Repo.get(id)
  end

  @spec get_group!(term()) :: group()
  def get_group!(id) do
    RegistrationGroup
    |> preload(^@group_preloads)
    |> Repo.get!(id)
  end

  @spec find_by_leg(network(), String.t()) :: group() | nil
  def find_by_leg(network, identity_ref) when is_binary(identity_ref) do
    network = to_string(network)
    ref = String.downcase(identity_ref)

    from(g in RegistrationGroup,
      join: l in assoc(g, :legs),
      where: g.status == "active" and l.network == ^network and l.identity_ref == ^ref,
      preload: ^@group_preloads,
      limit: 1
    )
    |> Repo.one()
  end

  @spec find_by_token(String.t()) :: group() | nil
  def find_by_token(token) when is_binary(token) do
    token =
      token
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    if token == "" do
      nil
    else
      groups = list_all() |> Enum.filter(&(&1.status == "active"))

      Enum.find(groups, fn g ->
        slug = token_slug(g.display_name)

        slug == token or
          g.id == token or
          Enum.any?(g.legs, fn leg ->
            String.starts_with?(leg.identity_ref, token) or
              String.slice(leg.identity_ref, 0, 8) == token
          end)
      end)
    end
  end

  @spec nostr_room_subject(group()) :: String.t()
  def nostr_room_subject(%RegistrationGroup{} = group) do
    slug = token_slug(group.display_name)

    cond do
      slug != "" -> "isthmus/#{slug}"
      is_binary(group.id) -> "isthmus/#{group.id}"
      true -> "isthmus/group"
    end
  end

  @spec find_by_nostr_subject(term()) :: group() | nil
  def find_by_nostr_subject(subject) when is_binary(subject) do
    subject = String.trim(subject)

    token =
      cond do
        String.starts_with?(subject, "isthmus/") ->
          String.trim_leading(subject, "isthmus/")

        String.starts_with?(String.downcase(subject), "isthmus:") ->
          subject |> String.split(":", parts: 2) |> Enum.at(1) || ""

        true ->
          subject
      end

    find_by_token(token)
  end

  def find_by_nostr_subject(_), do: nil

  @spec token_slug(String.t() | nil) :: String.t()
  def token_slug(nil), do: ""

  def token_slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  @spec leg(group(), network()) :: leg() | nil
  def leg(%RegistrationGroup{legs: legs}, network) when is_list(legs) do
    network = to_string(network)
    prefer_leg(Enum.filter(legs, &(&1.network == network)))
  end

  @spec other_legs(group(), network()) :: [leg()]
  @spec other_legs(group(), network(), String.t() | nil) :: [leg()]
  def other_legs(group, from_network, from_ref \\ nil)

  def other_legs(%RegistrationGroup{kind: "bridge", legs: legs}, from_network, from_ref)
      when is_list(legs) do
    from_ref = from_ref && String.downcase(from_ref)
    from_network = to_string(from_network)

    Enum.reject(legs, fn leg ->
      same_ref? = is_binary(from_ref) and String.downcase(leg.identity_ref) == from_ref
      proxy? = leg.role == "proxy"
      rns_bounce? = from_network == "reticulum" and leg.network == "reticulum"

      same_ref? or proxy? or rns_bounce?
    end)
  end

  def other_legs(%RegistrationGroup{legs: legs}, from_network, _from_ref) when is_list(legs) do
    from_network = to_string(from_network)

    legs
    |> Enum.reject(&(&1.network == from_network))
    |> Enum.reject(&(&1.network == "nostr" and &1.role == "proxy"))
    |> Enum.group_by(& &1.network)
    |> Enum.map(fn {_net, net_legs} -> prefer_leg(net_legs) end)
  end

  @spec real_destination_leg?(term()) :: boolean()
  def real_destination_leg?(%IdentityLeg{role: role}) when role in ["primary", "member"], do: true
  def real_destination_leg?(_), do: false

  @spec insert_group(map()) :: {:ok, group()} | {:error, Ecto.Changeset.t()}
  def insert_group(attrs) do
    %RegistrationGroup{}
    |> RegistrationGroup.changeset(attrs)
    |> Repo.insert()
  end

  @spec insert_leg(group(), map()) :: {:ok, leg()} | {:error, Ecto.Changeset.t()}
  def insert_leg(group, attrs) do
    %IdentityLeg{}
    |> IdentityLeg.changeset(Map.put(attrs, :registration_group_id, group.id))
    |> Repo.insert()
  end

  @spec stringify_map(map()) :: map()
  def stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp prefer_leg(legs) do
    Enum.find(legs, &(&1.role in ["primary", "member"])) || List.first(legs)
  end
end
