defmodule Isthmus.Registrations do
  @moduledoc """
  Cross-network identity groups.

  * `kind: "registration"` — primary + Isthmus-minted proxies
  * `kind: "bridge"` — attached real identities only; fan-out gateway
  """

  import Ecto.Query
  alias Isthmus.Networks
  alias Isthmus.Policy

  alias Isthmus.Registrations.{
    Announce,
    GroupRadioChannel,
    IdentityLeg,
    Proxy,
    Query,
    Radio,
    RegistrationGroup
  }

  alias Isthmus.Repo

  @type group :: RegistrationGroup.t()
  @type leg :: IdentityLeg.t()
  @type radio_link :: GroupRadioChannel.t()
  @type network :: String.t() | atom()
  @type result(ok) :: {:ok, ok} | {:error, term()}

  @spec list_all() :: [group()]
  defdelegate list_all(), to: Query

  @spec list_by_kind(String.t()) :: [group()]
  defdelegate list_by_kind(kind), to: Query

  @spec get_for_owner(String.t()) :: [group()]
  defdelegate get_for_owner(pubkey_hex), to: Query

  @spec active_registration_for_owner(String.t()) :: group() | nil
  defdelegate active_registration_for_owner(pubkey_hex), to: Query

  @spec get_group(term()) :: group() | nil
  defdelegate get_group(id), to: Query

  @spec get_group!(term()) :: group()
  defdelegate get_group!(id), to: Query

  @spec find_by_leg(network(), String.t()) :: group() | nil
  defdelegate find_by_leg(network, identity_ref), to: Query

  @spec find_by_token(String.t()) :: group() | nil
  defdelegate find_by_token(token), to: Query

  @spec nostr_room_subject(group()) :: String.t()
  defdelegate nostr_room_subject(group), to: Query

  @spec find_by_nostr_subject(term()) :: group() | nil
  defdelegate find_by_nostr_subject(subject), to: Query

  @spec token_slug(String.t() | nil) :: String.t()
  defdelegate token_slug(name), to: Query

  @spec leg(group(), network()) :: leg() | nil
  defdelegate leg(group, network), to: Query

  @spec other_legs(group(), network()) :: [leg()]
  @spec other_legs(group(), network(), String.t() | nil) :: [leg()]
  defdelegate other_legs(group, from_network), to: Query
  defdelegate other_legs(group, from_network, from_ref), to: Query

  @spec real_destination_leg?(term()) :: boolean()
  defdelegate real_destination_leg?(leg), to: Query

  @spec radio_links(group() | term(), network()) :: [radio_link()]
  defdelegate radio_links(group, network), to: Radio, as: :links

  @spec radio_link(group(), network(), String.t() | nil) :: radio_link() | nil
  defdelegate radio_link(group, network, device_id), to: Radio, as: :link

  @spec find_by_meshcore_channel(integer()) :: group() | nil
  @spec find_by_meshcore_channel(integer(), String.t() | nil) :: group() | nil
  def find_by_meshcore_channel(idx, device_id \\ nil),
    do: Radio.find_by_channel("meshcore", idx, device_id)

  @spec link_meshcore_channel(group(), integer(), String.t()) :: result(group())
  @spec link_meshcore_channel(group(), integer(), String.t(), keyword()) :: result(group())
  def link_meshcore_channel(group, idx, secret_hex, opts \\ []),
    do: Radio.link_channel(group, "meshcore", idx, secret_hex, opts)

  @spec unlink_meshcore_channel(group()) :: result(group())
  @spec unlink_meshcore_channel(group(), keyword()) :: result(group())
  def unlink_meshcore_channel(group, opts \\ []),
    do: Radio.unlink_channel(group, "meshcore", opts)

  @spec provision_meshcore_channel(group()) :: result(group())
  @spec provision_meshcore_channel(group(), keyword()) :: result(group())
  def provision_meshcore_channel(group, opts \\ []),
    do: Radio.provision(group, "meshcore", opts)

  @spec meshcore_channel_invite(group()) :: result(map())
  @spec meshcore_channel_invite(group(), keyword()) :: result(map())
  def meshcore_channel_invite(group, opts \\ []),
    do: Radio.invite(group, "meshcore", opts)

  @spec find_by_meshtastic_channel(integer()) :: group() | nil
  @spec find_by_meshtastic_channel(integer(), String.t() | nil) :: group() | nil
  def find_by_meshtastic_channel(idx, device_id \\ nil),
    do: Radio.find_by_channel("meshtastic", idx, device_id)

  @spec link_meshtastic_channel(group(), integer(), String.t()) :: result(group())
  @spec link_meshtastic_channel(group(), integer(), String.t(), keyword()) :: result(group())
  def link_meshtastic_channel(group, idx, psk_hex, opts \\ []),
    do: Radio.link_channel(group, "meshtastic", idx, psk_hex, opts)

  @spec unlink_meshtastic_channel(group()) :: result(group())
  @spec unlink_meshtastic_channel(group(), keyword()) :: result(group())
  def unlink_meshtastic_channel(group, opts \\ []),
    do: Radio.unlink_channel(group, "meshtastic", opts)

  @spec provision_meshtastic_channel(group()) :: result(group())
  @spec provision_meshtastic_channel(group(), keyword()) :: result(group())
  def provision_meshtastic_channel(group, opts \\ []),
    do: Radio.provision(group, "meshtastic", opts)

  @spec meshtastic_channel_invite(group()) :: result(map())
  @spec meshtastic_channel_invite(group(), keyword()) :: result(map())
  def meshtastic_channel_invite(group, opts \\ []),
    do: Radio.invite(group, "meshtastic", opts)

  @spec normalize_radio_id(term()) :: String.t() | nil
  defdelegate normalize_radio_id(id), to: Radio

  @spec claim_unscoped_radio_channel(atom() | String.t(), String.t() | nil, [integer()]) :: :ok
  defdelegate claim_unscoped_radio_channel(network, device_id, occupied_idxs), to: Radio

  @spec ensure_bridge_rns_proxy(group()) :: result(group())
  defdelegate ensure_bridge_rns_proxy(group), to: Proxy

  @spec ensure_nostr_proxy(group()) :: result(group())
  defdelegate ensure_nostr_proxy(group), to: Proxy

  @spec nostr_proxy_leg(group() | term()) :: leg() | nil
  defdelegate nostr_proxy_leg(group), to: Proxy

  @spec ensure_meshcore_proxy(group()) :: result(group())
  defdelegate ensure_meshcore_proxy(group), to: Proxy

  @spec meshcore_proxy_leg(group() | term()) :: leg() | nil
  defdelegate meshcore_proxy_leg(group), to: Proxy

  @spec list_meshcore_proxy_legs() :: [leg()]
  defdelegate list_meshcore_proxy_legs(), to: Proxy

  @spec meshcore_proxy_seed(term()) :: {:ok, binary(), binary()} | {:error, atom()}
  defdelegate meshcore_proxy_seed(leg), to: Proxy

  @spec nostr_proxy_seckey(group()) :: {:ok, binary()} | {:error, atom()}
  defdelegate nostr_proxy_seckey(group), to: Proxy

  @spec list_nostr_inbox_keypairs() :: [{String.t(), binary()}]
  defdelegate list_nostr_inbox_keypairs(), to: Proxy

  @spec can_announce_leg?(term()) :: boolean()
  defdelegate can_announce_leg?(leg), to: Announce

  @spec external_reticulum_leg?(term()) :: boolean()
  defdelegate external_reticulum_leg?(leg), to: Announce

  @spec announce_leg(leg()) :: :ok | {:error, term()}
  @spec announce_leg(leg(), map() | keyword()) :: :ok | {:error, term()}
  defdelegate announce_leg(leg), to: Announce
  defdelegate announce_leg(leg, opts), to: Announce

  @spec ensure_reticulum_ready(leg()) :: result(leg())
  defdelegate ensure_reticulum_ready(leg), to: Announce

  @spec announce_group(group()) :: result([{String.t(), :ok | {:error, term()}}])
  @spec announce_group(group(), map() | keyword()) ::
          result([{String.t(), :ok | {:error, term()}}])
  defdelegate announce_group(group), to: Announce
  defdelegate announce_group(group, opts), to: Announce

  @spec request_reticulum_path(leg()) :: :ok | {:ok, term()} | {:error, term()}
  defdelegate request_reticulum_path(leg), to: Announce

  @doc "Self-service: bind session Nostr pubkey and mint Nostr + RNS + MeshCore proxies."
  @spec register_self(String.t()) :: result(group()) | {:error, {:already_registered, group()}}
  @spec register_self(String.t(), map()) ::
          result(group()) | {:error, {:already_registered, group()}}
  def register_self(pubkey_hex, attrs \\ %{}) when is_binary(pubkey_hex) do
    unless Policy.registration_open?() do
      {:error, :registration_closed}
    else
      hex = String.downcase(pubkey_hex)

      case Query.active_registration_for_owner(hex) do
        %RegistrationGroup{} = existing ->
          {:error, {:already_registered, existing}}

        nil ->
          do_register_nostr_primary(hex, Map.put(attrs, :created_by, "self_service"))
      end
    end
  end

  @doc "Register a known MeshCore identity as primary; mint Nostr + RNS proxies."
  @spec register_meshcore_primary(String.t(), String.t()) :: result(group())
  @spec register_meshcore_primary(String.t(), String.t(), map()) :: result(group())
  def register_meshcore_primary(owner_hex, meshcore_input, attrs \\ %{})
      when is_binary(owner_hex) and is_binary(meshcore_input) do
    if registration_allowed?(attrs) do
      with {:ok, ref, material} <- Networks.MeshCore.parse_identity_ref(meshcore_input),
           :ok <- ensure_ref_free("meshcore", ref),
           :ok <- ensure_no_active_registration(owner_hex) do
        do_register_meshcore_primary(String.downcase(owner_hex), ref, material, attrs)
      end
    else
      {:error, :registration_closed}
    end
  end

  @doc "Register a known Reticulum dest as primary; mint Nostr + MeshCore proxies."
  @spec register_reticulum_primary(String.t(), String.t()) :: result(group())
  @spec register_reticulum_primary(String.t(), String.t(), map()) :: result(group())
  def register_reticulum_primary(owner_hex, rns_input, attrs \\ %{})
      when is_binary(owner_hex) and is_binary(rns_input) do
    if registration_allowed?(attrs) do
      with {:ok, ref, material} <- Networks.Reticulum.parse_identity_ref(rns_input),
           :ok <- ensure_ref_free("reticulum", ref),
           :ok <- ensure_no_active_registration(owner_hex) do
        do_register_reticulum_primary(String.downcase(owner_hex), ref, material, attrs)
      end
    else
      {:error, :registration_closed}
    end
  end

  @spec create_bridge_group(String.t()) :: result(group())
  @spec create_bridge_group(String.t(), map()) :: result(group())
  def create_bridge_group(owner_hex, attrs \\ %{}) when is_binary(owner_hex) do
    name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Bridge"

    %RegistrationGroup{}
    |> RegistrationGroup.changeset(%{
      owner_pubkey_hex: String.downcase(owner_hex),
      display_name: name,
      status: "active",
      created_by: Map.get(attrs, :created_by) || Map.get(attrs, "created_by") || "admin",
      kind: "bridge"
    })
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, Query.get_group!(group.id)}
      err -> err
    end
  end

  @spec attach_member(group(), network(), String.t()) :: result(group())
  def attach_member(%RegistrationGroup{kind: "bridge"} = group, network, identity_input)
      when is_binary(identity_input) do
    network = to_string(network)

    with {:ok, ref, material, presentations} <- parse_attached(network, identity_input),
         :ok <- ensure_ref_free(network, ref) do
      Query.insert_leg(group, %{
        network: network,
        role: "member",
        identity_ref: ref,
        public_material: Query.stringify_map(material),
        presentation_cache: %{items: presentations},
        encrypted_private_material: nil
      })
      |> case do
        {:ok, _} -> {:ok, Query.get_group!(group.id)}
        err -> err
      end
    end
  end

  def attach_member(%RegistrationGroup{}, _, _), do: {:error, :not_a_bridge_group}

  @spec detach_member(term()) :: :ok | {:error, term()}
  def detach_member(%IdentityLeg{role: "member"} = leg) do
    case Repo.delete(leg) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  def detach_member(_), do: {:error, :not_a_member}

  @doc """
  Create a bridge group and provision a private MeshCore channel (slot 1–7).
  """
  @spec create_bridge_with_channel(String.t()) :: result(group())
  @spec create_bridge_with_channel(String.t(), map()) :: result(group())
  def create_bridge_with_channel(owner_hex, attrs \\ %{}) when is_binary(owner_hex) do
    name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Bridge"

    with :ok <- Radio.companion_online("meshcore"),
         {:ok, idx} <- Radio.pick_slot("meshcore", nil, nil),
         {:ok, channel} <- Radio.set_channel("meshcore", idx, name, nil),
         {:ok, group} <-
           create_bridge_group(owner_hex, Map.merge(Map.new(attrs), %{display_name: name})),
         {:ok, group} <-
           Radio.link_channel(group, "meshcore", idx, channel.secret_hex,
             device_id: Radio.device_id("meshcore", nil)
           ),
         {:ok, group} <- Proxy.ensure_bridge_rns_proxy(group),
         {:ok, group} <- Proxy.ensure_nostr_proxy(group),
         {:ok, group} <- Proxy.ensure_meshcore_proxy(group) do
      {:ok, group}
    end
  end

  @doc """
  Create a bridge group and provision a private Meshtastic secondary channel (slots 1–7).
  """
  @spec create_bridge_with_meshtastic_channel(String.t()) :: result(group())
  @spec create_bridge_with_meshtastic_channel(String.t(), map()) :: result(group())
  def create_bridge_with_meshtastic_channel(owner_hex, attrs \\ %{}) when is_binary(owner_hex) do
    name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Bridge"
    port = Map.get(attrs, :port) || Map.get(attrs, "port")

    with :ok <- Radio.companion_online("meshtastic", port),
         {:ok, idx} <- Radio.pick_slot("meshtastic", nil, port),
         {:ok, channel} <- Radio.set_channel("meshtastic", idx, name, port),
         {:ok, group} <-
           create_bridge_group(owner_hex, Map.merge(Map.new(attrs), %{display_name: name})),
         {:ok, group} <-
           Radio.link_channel(group, "meshtastic", idx, channel.psk_hex,
             device_id: Radio.device_id("meshtastic", port)
           ),
         {:ok, group} <- Proxy.ensure_bridge_rns_proxy(group),
         {:ok, group} <- Proxy.ensure_nostr_proxy(group),
         {:ok, group} <- Proxy.ensure_meshcore_proxy(group) do
      {:ok, group}
    end
  end

  @spec revoke(group()) :: result(group())
  def revoke(%RegistrationGroup{} = group) do
    changeset =
      RegistrationGroup.changeset(group, %{
        status: "revoked",
        meshcore_channel_idx: nil,
        meshcore_channel_secret_enc: nil,
        meshcore_channel_device_id: nil,
        meshtastic_channel_idx: nil,
        meshtastic_channel_psk_enc: nil,
        meshtastic_channel_device_id: nil
      })

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, revoked} ->
          Repo.delete_all(
            from(c in GroupRadioChannel, where: c.registration_group_id == ^group.id)
          )

          Repo.delete_all(from(l in IdentityLeg, where: l.registration_group_id == ^group.id))
          revoked

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp registration_allowed?(attrs) do
    Policy.registration_open?() or
      Map.get(attrs, :created_by) == "admin" or
      Map.get(attrs, "created_by") == "admin"
  end

  defp do_register_nostr_primary(hex, attrs) do
    npub =
      case Base.decode16(hex, case: :lower) do
        {:ok, bin} -> Isthmus.Nostr.Bech32.encode_npub(bin)
        _ -> hex
      end

    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Isthmus user"

    Repo.transaction(fn ->
      {:ok, group} =
        Query.insert_group(%{
          owner_pubkey_hex: hex,
          display_name: display_name,
          status: "active",
          created_by: Map.get(attrs, :created_by, "self_service"),
          kind: "registration"
        })

      {:ok, _} =
        Query.insert_leg(group, %{
          network: "nostr",
          role: "primary",
          identity_ref: hex,
          public_material: %{pubkey_hex: hex, npub: npub},
          presentation_cache: %{items: Networks.Nostr.identity_presentations(hex, %{npub: npub})},
          encrypted_private_material: nil
        })

      :ok = Proxy.mint_nostr_proxy!(group, display_name)
      :ok = Proxy.mint_rns_proxy!(group, display_name)
      :ok = Proxy.mint_meshcore_proxy!(group, display_name)
      Query.get_group!(group.id)
    end)
  end

  defp do_register_meshcore_primary(owner_hex, ref, material, attrs) do
    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") ||
        material[:name] || material["name"] || "Isthmus user"

    Repo.transaction(fn ->
      {:ok, group} =
        Query.insert_group(%{
          owner_pubkey_hex: owner_hex,
          display_name: display_name,
          status: "active",
          created_by: Map.get(attrs, :created_by) || "self_service",
          kind: "registration"
        })

      {:ok, _} =
        Query.insert_leg(group, %{
          network: "meshcore",
          role: "primary",
          identity_ref: ref,
          public_material: Query.stringify_map(material),
          presentation_cache: %{
            items: Networks.MeshCore.identity_presentations(ref, material)
          },
          encrypted_private_material: nil
        })

      :ok = Proxy.mint_nostr_proxy!(group, display_name)
      :ok = Proxy.mint_rns_proxy!(group, display_name)
      Query.get_group!(group.id)
    end)
  end

  defp do_register_reticulum_primary(owner_hex, ref, material, attrs) do
    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Isthmus user"

    Repo.transaction(fn ->
      {:ok, group} =
        Query.insert_group(%{
          owner_pubkey_hex: owner_hex,
          display_name: display_name,
          status: "active",
          created_by: Map.get(attrs, :created_by) || "self_service",
          kind: "registration"
        })

      {:ok, _} =
        Query.insert_leg(group, %{
          network: "reticulum",
          role: "primary",
          identity_ref: ref,
          public_material: Query.stringify_map(material),
          presentation_cache: %{
            items: Networks.Reticulum.identity_presentations(ref, material)
          },
          encrypted_private_material: nil
        })

      :ok = Proxy.mint_nostr_proxy!(group, display_name)
      :ok = Proxy.mint_meshcore_proxy!(group, display_name)
      :ok = Proxy.mint_rns_proxy!(group, display_name <> " inbox")
      Query.get_group!(group.id)
    end)
  end

  defp parse_attached("nostr", input) do
    with {:ok, ref, material} <- Networks.Nostr.parse_identity_ref(input) do
      {:ok, ref, material, Networks.Nostr.identity_presentations(ref, material)}
    end
  end

  defp parse_attached("meshcore", input) do
    with {:ok, ref, material} <- Networks.MeshCore.parse_identity_ref(input) do
      {:ok, ref, material, Networks.MeshCore.identity_presentations(ref, material)}
    end
  end

  defp parse_attached("reticulum", input) do
    with {:ok, ref, material} <- Networks.Reticulum.parse_identity_ref(input) do
      {:ok, ref, material, Networks.Reticulum.identity_presentations(ref, material)}
    end
  end

  defp parse_attached("agent", input) do
    with {:ok, ref, material} <- Networks.Agent.parse_identity_ref(input) do
      {:ok, ref, material, Networks.Agent.identity_presentations(ref, material)}
    end
  end

  defp parse_attached(_, _), do: {:error, :unsupported_network}

  defp ensure_ref_free(network, ref) do
    reclaim_orphaned_legs(network, ref)

    case Query.find_by_leg(network, ref) do
      nil -> :ok
      _ -> {:error, :identity_already_linked}
    end
  end

  defp reclaim_orphaned_legs(network, ref) do
    ids =
      from(l in IdentityLeg,
        join: g in assoc(l, :registration_group),
        where: g.status == "revoked" and l.network == ^network and l.identity_ref == ^ref,
        select: l.id
      )
      |> Repo.all()

    if ids != [] do
      from(l in IdentityLeg, where: l.id in ^ids) |> Repo.delete_all()
    end

    :ok
  end

  defp ensure_no_active_registration(owner_hex) do
    case Query.active_registration_for_owner(owner_hex) do
      nil -> :ok
      existing -> {:error, {:already_registered, existing}}
    end
  end
end
