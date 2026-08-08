defmodule Isthmus.Registrations do
  @moduledoc """
  Cross-network identity groups.

  * `kind: "registration"` — primary + Isthmus-minted proxies
  * `kind: "bridge"` — attached real identities only; fan-out gateway
  """

  import Ecto.Query
  alias Isthmus.Networks
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Policy
  alias Isthmus.Registrations.{IdentityLeg, RegistrationGroup}
  alias Isthmus.Repo
  alias Isthmus.Vault

  def list_all do
    RegistrationGroup
    |> order_by([g], desc: g.inserted_at)
    |> preload(:legs)
    |> Repo.all()
  end

  def list_by_kind(kind) when kind in ["registration", "bridge"] do
    RegistrationGroup
    |> where([g], g.kind == ^kind)
    |> order_by([g], desc: g.inserted_at)
    |> preload(:legs)
    |> Repo.all()
  end

  def get_for_owner(pubkey_hex) do
    hex = String.downcase(pubkey_hex)

    RegistrationGroup
    |> where([g], g.owner_pubkey_hex == ^hex and g.status != "revoked")
    |> order_by([g], desc: g.inserted_at)
    |> preload(:legs)
    |> Repo.all()
  end

  def active_registration_for_owner(pubkey_hex) do
    hex = String.downcase(pubkey_hex)

    RegistrationGroup
    |> where(
      [g],
      g.owner_pubkey_hex == ^hex and g.status == "active" and g.kind == "registration"
    )
    |> preload(:legs)
    |> Repo.one()
  end

  def get_group!(id) do
    RegistrationGroup
    |> preload(:legs)
    |> Repo.get!(id)
  end

  @doc "Find active group that owns a leg on `network` with `identity_ref`."
  def find_by_leg(network, identity_ref) when is_binary(identity_ref) do
    network = to_string(network)
    ref = String.downcase(identity_ref)

    from(g in RegistrationGroup,
      join: l in assoc(g, :legs),
      where: g.status == "active" and l.network == ^network and l.identity_ref == ^ref,
      preload: [:legs],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Resolve a MeshCore address token (`@name` or `@` + hex prefix) to an active group.
  """
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

  @doc """
  NIP-17 chat-room subject for a group (`isthmus/<slug>`).

  Peers reply in the same room (same `p` tags + subject) so inbound DMs can be
  routed without minting a Nostr identity per group.
  """
  def nostr_room_subject(%RegistrationGroup{} = group) do
    slug = token_slug(group.display_name)

    cond do
      slug != "" -> "isthmus/#{slug}"
      is_binary(group.id) -> "isthmus/#{group.id}"
      true -> "isthmus/group"
    end
  end

  @doc "Resolve an active group from a NIP-17 subject tag."
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

  def token_slug(nil), do: ""

  def token_slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  def leg(%RegistrationGroup{legs: legs}, network) when is_list(legs) do
    network = to_string(network)
    prefer_leg(Enum.filter(legs, &(&1.network == network)))
  end

  @doc """
  Legs to fan out to.

  * registration — one preferred leg per other network (primary/member over proxy)
  * bridge — every other member (may include same network); excludes `from_ref` when given
  """
  def other_legs(group, from_network, from_ref \\ nil)

  def other_legs(%RegistrationGroup{kind: "bridge", legs: legs}, from_network, from_ref)
      when is_list(legs) do
    from_ref = from_ref && String.downcase(from_ref)
    from_network = to_string(from_network)

    Enum.reject(legs, fn leg ->
      same_ref? = is_binary(from_ref) and String.downcase(leg.identity_ref) == from_ref
      # Proxies are Isthmus-owned inboxes — never fan-out targets.
      proxy? = leg.role == "proxy"
      # RNS ingress must not bounce to other RNS legs (identity hash ≠ LXMF dest causes
      # confusing echo attempts back toward the sender).
      rns_bounce? = from_network == "reticulum" and leg.network == "reticulum"

      same_ref? or proxy? or rns_bounce?
    end)
  end

  def other_legs(%RegistrationGroup{legs: legs}, from_network, _from_ref) when is_list(legs) do
    from_network = to_string(from_network)

    legs
    |> Enum.reject(&(&1.network == from_network))
    # Nostr proxies are Isthmus-owned ingress identities — do not DM them outbound.
    |> Enum.reject(&(&1.network == "nostr" and &1.role == "proxy"))
    |> Enum.group_by(& &1.network)
    |> Enum.map(fn {_net, net_legs} -> prefer_leg(net_legs) end)
  end

  def real_destination_leg?(%IdentityLeg{role: role}) when role in ["primary", "member"], do: true
  def real_destination_leg?(_), do: false

  defp prefer_leg(legs) do
    Enum.find(legs, &(&1.role in ["primary", "member"])) || List.first(legs)
  end

  # --- Registration (minting) -------------------------------------------------

  @doc "Self-service: bind session Nostr pubkey and mint Nostr + RNS + MeshCore proxies."
  def register_self(pubkey_hex, attrs \\ %{}) when is_binary(pubkey_hex) do
    unless Policy.registration_open?() do
      {:error, :registration_closed}
    else
      hex = String.downcase(pubkey_hex)

      case active_registration_for_owner(hex) do
        %RegistrationGroup{} = existing ->
          {:error, {:already_registered, existing}}

        nil ->
          do_register_nostr_primary(hex, Map.put(attrs, :created_by, "self_service"))
      end
    end
  end

  @doc "Register a known MeshCore identity as primary; mint Nostr + RNS proxies."
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

  defp registration_allowed?(attrs) do
    Policy.registration_open?() or
      Map.get(attrs, :created_by) == "admin" or
      Map.get(attrs, "created_by") == "admin"
  end

  # --- Bridge groups ----------------------------------------------------------

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
      {:ok, group} -> {:ok, get_group!(group.id)}
      err -> err
    end
  end

  def attach_member(%RegistrationGroup{kind: "bridge"} = group, network, identity_input)
      when is_binary(identity_input) do
    network = to_string(network)

    with {:ok, ref, material, presentations} <- parse_attached(network, identity_input),
         :ok <- ensure_ref_free(network, ref) do
      insert_leg(group, %{
        network: network,
        role: "member",
        identity_ref: ref,
        public_material: stringify_map(material),
        presentation_cache: %{items: presentations},
        encrypted_private_material: nil
      })
      |> case do
        {:ok, _} -> {:ok, get_group!(group.id)}
        err -> err
      end
    end
  end

  def attach_member(%RegistrationGroup{}, _, _), do: {:error, :not_a_bridge_group}

  def detach_member(%IdentityLeg{role: "member"} = leg) do
    case Repo.delete(leg) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  def detach_member(_), do: {:error, :not_a_member}

  @doc "Find active bridge/registration group linked to a MeshCore channel index."
  def find_by_meshcore_channel(idx) when is_integer(idx) do
    from(g in RegistrationGroup,
      where: g.status == "active" and g.meshcore_channel_idx == ^idx,
      preload: [:legs],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Link a MeshCore channel slot to a bridge group (stores encrypted secret)."
  def link_meshcore_channel(%RegistrationGroup{kind: "bridge"} = group, idx, secret_hex)
      when is_integer(idx) and idx in 0..7 and is_binary(secret_hex) do
    with :ok <- ensure_channel_idx_free(idx),
         {:ok, enc} <- Vault.encrypt(%{"secret_hex" => String.downcase(secret_hex)}) do
      group
      |> RegistrationGroup.changeset(%{
        meshcore_channel_idx: idx,
        meshcore_channel_secret_enc: enc
      })
      |> Repo.update()
      |> case do
        {:ok, _} -> {:ok, get_group!(group.id)}
        err -> err
      end
    end
  end

  def link_meshcore_channel(%RegistrationGroup{}, _, _), do: {:error, :not_a_bridge_group}

  def unlink_meshcore_channel(%RegistrationGroup{} = group) do
    group
    |> RegistrationGroup.changeset(%{meshcore_channel_idx: nil, meshcore_channel_secret_enc: nil})
    |> Repo.update()
    |> case do
      {:ok, _} -> {:ok, get_group!(group.id)}
      err -> err
    end
  end

  @doc """
  Decrypt channel credentials for inviting a second MeshCore device.

  Returns name + secret (for the app's "secret key" join) and a
  `meshcore://channel/add?...` URI (for QR / paste).
  """
  def meshcore_channel_invite(
        %RegistrationGroup{
          kind: "bridge",
          status: "active",
          meshcore_channel_idx: idx,
          meshcore_channel_secret_enc: enc
        } = group
      )
      when is_integer(idx) and is_binary(enc) do
    case Vault.decrypt(enc) do
      {:ok, material} when is_map(material) ->
        secret_hex =
          case Map.get(material, "secret_hex") || Map.get(material, :secret_hex) do
            s when is_binary(s) and s != "" -> String.downcase(s)
            _ -> nil
          end

        if secret_hex do
          name = channel_invite_name(group, idx)
          uri = "meshcore://channel/add?name=#{URI.encode_www_form(name)}&secret=#{secret_hex}"

          {:ok,
           %{
             slot: idx,
             name: name,
             secret_hex: secret_hex,
             uri: uri
           }}
        else
          {:error, :invite_unavailable}
        end

      _ ->
        {:error, :invite_unavailable}
    end
  end

  def meshcore_channel_invite(%RegistrationGroup{}), do: {:error, :no_channel_linked}

  defp channel_invite_name(group, idx) do
    case Companion.get_channel(idx) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> group.display_name || "Channel"
    end
  end

  @doc """
  Create a bridge group and provision a private MeshCore channel (slot 1–7).
  """
  def create_bridge_with_channel(owner_hex, attrs \\ %{}) when is_binary(owner_hex) do
    name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Bridge"

    with :ok <- companion_online(),
         {:ok, idx} <- first_empty_private_channel_slot(),
         {:ok, channel} <- Companion.set_channel(idx, name, nil),
         {:ok, group} <-
           create_bridge_group(owner_hex, Map.merge(Map.new(attrs), %{display_name: name})),
         {:ok, group} <- link_meshcore_channel(group, idx, channel.secret_hex),
         {:ok, group} <- ensure_bridge_rns_proxy(group),
         {:ok, group} <- ensure_nostr_proxy(group),
         {:ok, group} <- ensure_meshcore_proxy(group) do
      {:ok, group}
    end
  end

  @doc """
  Ensure a bridge group has an Isthmus-owned RNS proxy (announce + LXMF source/inbox).

  Attached `reticulum/member` legs are external peers we send *to*; they cannot be
  announced from Isthmus. The proxy is what peers should message / what we announce.
  """
  def ensure_bridge_rns_proxy(%RegistrationGroup{kind: "bridge"} = group) do
    group = get_group!(group.id)

    if Enum.any?(group.legs, &(&1.network == "reticulum" and &1.role == "proxy")) do
      {:ok, group}
    else
      display = (group.display_name || "Bridge") <> " bridge"

      case mint_rns_proxy(group, display) do
        :ok -> {:ok, get_group!(group.id)}
        {:error, _} = err -> err
      end
    end
  end

  def ensure_bridge_rns_proxy(%RegistrationGroup{} = group), do: {:ok, get_group!(group.id)}

  @doc """
  Ensure the group has an Isthmus-owned Nostr proxy (per-group nsec).

  Outbound DMs are sent *from* this proxy; inbound gift-wraps addressed to it
  route unambiguously to this group even when clients omit the NIP-17 subject.
  """
  def ensure_nostr_proxy(%RegistrationGroup{} = group) do
    group = get_group!(group.id)

    if Enum.any?(group.legs, &(&1.network == "nostr" and &1.role == "proxy")) do
      {:ok, group}
    else
      display = group.display_name || "Isthmus"

      case mint_nostr_proxy(group, display) do
        :ok ->
          reload_nostr_subscriptions()
          {:ok, get_group!(group.id)}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Nostr proxy leg for a group, if minted."
  def nostr_proxy_leg(%RegistrationGroup{legs: legs}) when is_list(legs) do
    Enum.find(legs, &(&1.network == "nostr" and &1.role == "proxy"))
  end

  def nostr_proxy_leg(_), do: nil

  @doc """
  Ensure the group has an Isthmus-owned MeshCore proxy (synthetic contact identity).

  Works for registration and bridge groups. Live on-air when the island bridge
  is online (`SyntheticNode`); otherwise the contact URI is still available.
  """
  def ensure_meshcore_proxy(%RegistrationGroup{} = group) do
    group = get_group!(group.id)

    if Enum.any?(group.legs, &(&1.network == "meshcore" and &1.role == "proxy")) do
      {:ok, group}
    else
      display = group.display_name || "Isthmus"

      case mint_meshcore_proxy(group, display) do
        :ok ->
          reload_meshcore_synthetics()
          {:ok, get_group!(group.id)}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "MeshCore proxy leg for a group, if minted."
  def meshcore_proxy_leg(%RegistrationGroup{legs: legs}) when is_list(legs) do
    Enum.find(legs, &(&1.network == "meshcore" and &1.role == "proxy"))
  end

  def meshcore_proxy_leg(_), do: nil

  @doc "All vaulted meshcore/proxy legs across active groups."
  def list_meshcore_proxy_legs do
    list_all()
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.flat_map(fn group ->
      Enum.filter(group.legs, &(&1.network == "meshcore" and &1.role == "proxy"))
    end)
  end

  @doc "Decrypt MeshCore proxy seed + public key binaries from a vaulted leg."
  def meshcore_proxy_seed(%IdentityLeg{} = leg) do
    if not is_binary(leg.encrypted_private_material) do
      {:error, :missing_private_material}
    else
      case Vault.decrypt(leg.encrypted_private_material) do
        {:ok, material} ->
          case Networks.MeshCore.private_seed(material) do
            {:ok, seed} ->
              pub_hex =
                material["public_key"] || material[:public_key] || leg.identity_ref

              case Base.decode16(to_string(pub_hex), case: :mixed) do
                {:ok, pub} when byte_size(pub) == 32 -> {:ok, seed, pub}
                _ -> {:error, :invalid_public_key}
              end

            err ->
              err
          end

        {:error, _} ->
          {:error, :decrypt_failed}
      end
    end
  end

  def meshcore_proxy_seed(_), do: {:error, :missing_private_material}

  @doc """
  Decrypt the group's Nostr proxy seckey (32-byte binary, BIP340-normalized).
  """
  def nostr_proxy_seckey(%RegistrationGroup{} = group) do
    case nostr_proxy_leg(group) do
      nil -> {:error, :no_nostr_proxy}
      leg -> nostr_leg_seckey(leg)
    end
  end

  @doc """
  Active Nostr inbox keypairs for inbound decrypt: every vaulted `nostr/proxy`
  leg, plus the optional `ISTHMUS_NOSTR_NSEC` service identity as fallback.
  """
  def list_nostr_inbox_keypairs do
    proxy_pairs =
      list_all()
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.flat_map(fn group ->
        group.legs
        |> Enum.filter(&(&1.network == "nostr" and &1.role == "proxy"))
        |> Enum.flat_map(fn leg ->
          case nostr_leg_seckey(leg) do
            {:ok, seckey} -> [{String.downcase(leg.identity_ref), seckey}]
            _ -> []
          end
        end)
      end)

    service_pair =
      case Isthmus.Nostr.Crypto.service_keypair() do
        {:ok, seckey, pubkey} ->
          [{Base.encode16(pubkey, case: :lower), seckey}]

        _ ->
          []
      end

    Enum.uniq_by(proxy_pairs ++ service_pair, fn {pk, _} -> pk end)
  end

  defp companion_online do
    case Companion.health() do
      %{status: :online} -> :ok
      _ -> {:error, :not_connected}
    end
  end

  def revoke(%RegistrationGroup{} = group) do
    # Legs keep a global unique index on (network, identity_ref). Free them on
    # revoke so identities can be attached or registered again.
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :group,
      RegistrationGroup.changeset(group, %{
        status: "revoked",
        meshcore_channel_idx: nil,
        meshcore_channel_secret_enc: nil
      })
    )
    |> Ecto.Multi.delete_all(
      :legs,
      from(l in IdentityLeg, where: l.registration_group_id == ^group.id)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{group: revoked}} -> {:ok, revoked}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # --- Announce ---------------------------------------------------------------

  @doc "True when Isthmus holds keys (or MeshCore companion advert) for this leg."
  def can_announce_leg?(%IdentityLeg{} = leg) do
    Networks.supports_announce?(leg.network) and leg.role == "proxy"
  end

  def can_announce_leg?(_), do: false

  @doc "Attached/primary RNS destinations we route to but do not own."
  def external_reticulum_leg?(%IdentityLeg{network: "reticulum", role: role})
      when role in ["primary", "member"],
      do: true

  def external_reticulum_leg?(_), do: false

  def announce_leg(%IdentityLeg{} = leg, opts \\ %{}) do
    opts = Map.merge(%{force: true}, Map.new(opts))

    cond do
      not Networks.supports_announce?(leg.network) ->
        {:error, :announce_not_supported}

      not can_announce_leg?(leg) ->
        {:error, :external_identity}

      true ->
        with {:ok, leg} <- prepare_leg_for_announce(leg) do
          Networks.announce(leg.network, leg.identity_ref, opts)
        end
    end
  end

  def ensure_reticulum_ready(%IdentityLeg{network: "reticulum"} = leg) do
    alias Isthmus.Networks.Reticulum.Sidecar

    # Primary/member RNS legs are external destinations — nothing to register locally.
    if leg.role in ["primary", "member"] do
      {:ok, leg}
    else
      case private_key_hex(leg) do
        {:ok, pk} ->
          case Sidecar.register_identity(%{
                 "private_key_hex" => pk,
                 "display_name" => group_display_name(leg)
               }) do
            {:ok, _} ->
              {:ok, leg}

            {:error, :stub_mode} ->
              {:error, :rns_not_live}

            {:error, :not_connected} ->
              {:error, :rns_not_live}

            # Never remint a leg that still has vault material — rotating the LXMF
            # destination breaks MeshChatX conversations permanently.
            {:error, reason, _} ->
              {:error, reason}

            {:error, reason} ->
              {:error, reason}
          end

        # Only mint when the leg is an explicit stub (no real keys). Decrypt /
        # malformed-key failures must NOT rotate the destination hash.
        {:error, :stub_material} ->
          if reticulum_stub?(leg) do
            remint_reticulum_leg(leg)
          else
            {:error, :stub_material}
          end

        {:error, :decrypt_failed} ->
          require Logger

          Logger.error(
            "RNS proxy #{leg.identity_ref} vault decrypt failed — check ISTHMUS_VAULT_SECRET matches the secret used when the key was stored. Refusing to remint."
          )

          {:error, :decrypt_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  def ensure_reticulum_ready(%IdentityLeg{} = leg), do: {:ok, leg}

  def announce_group(%RegistrationGroup{legs: legs} = group, opts \\ %{}) when is_list(legs) do
    if group.status == "revoked" do
      {:error, :revoked}
    else
      group =
        case group.kind do
          "bridge" ->
            case ensure_bridge_rns_proxy(group) do
              {:ok, g} -> g
              {:error, _} -> group
            end

          _ ->
            group
        end

      group =
        case ensure_nostr_proxy(group) do
          {:ok, g} -> g
          {:error, _} -> group
        end

      group =
        case ensure_meshcore_proxy(group) do
          {:ok, g} -> g
          {:error, _} -> group
        end

      results =
        group.legs
        |> Enum.filter(&can_announce_leg?/1)
        |> Enum.map(fn leg -> {leg.network, announce_leg(leg, opts)} end)

      if results == [] do
        {:error, :no_announceable_legs}
      else
        {:ok, results}
      end
    end
  end

  @doc "Ask RNS for a path to an external destination (attached bridge member / peer)."
  def request_reticulum_path(%IdentityLeg{} = leg) do
    if external_reticulum_leg?(leg) do
      Isthmus.Networks.Reticulum.request_path(leg.identity_ref)
    else
      {:error, :not_external_reticulum}
    end
  end

  # --- private: registration builders -----------------------------------------

  defp do_register_nostr_primary(hex, attrs) do
    npub =
      case Base.decode16(hex, case: :lower) do
        {:ok, bin} -> Bech32.encode_npub(bin)
        _ -> hex
      end

    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Isthmus user"

    Repo.transaction(fn ->
      {:ok, group} =
        insert_group(%{
          owner_pubkey_hex: hex,
          display_name: display_name,
          status: "active",
          created_by: Map.get(attrs, :created_by, "self_service"),
          kind: "registration"
        })

      {:ok, _} =
        insert_leg(group, %{
          network: "nostr",
          role: "primary",
          identity_ref: hex,
          public_material: %{pubkey_hex: hex, npub: npub},
          presentation_cache: %{items: Networks.Nostr.identity_presentations(hex, %{npub: npub})},
          encrypted_private_material: nil
        })

      :ok = mint_nostr_proxy!(group, display_name)
      :ok = mint_rns_proxy!(group, display_name)
      :ok = mint_meshcore_proxy!(group, display_name)
      get_group!(group.id)
    end)
  end

  defp do_register_meshcore_primary(owner_hex, ref, material, attrs) do
    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") ||
        material[:name] || material["name"] || "Isthmus user"

    Repo.transaction(fn ->
      {:ok, group} =
        insert_group(%{
          owner_pubkey_hex: owner_hex,
          display_name: display_name,
          status: "active",
          created_by: Map.get(attrs, :created_by) || "self_service",
          kind: "registration"
        })

      {:ok, _} =
        insert_leg(group, %{
          network: "meshcore",
          role: "primary",
          identity_ref: ref,
          public_material: stringify_map(material),
          presentation_cache: %{
            items: Networks.MeshCore.identity_presentations(ref, material)
          },
          encrypted_private_material: nil
        })

      :ok = mint_nostr_proxy!(group, display_name)
      :ok = mint_rns_proxy!(group, display_name)
      get_group!(group.id)
    end)
  end

  defp do_register_reticulum_primary(owner_hex, ref, material, attrs) do
    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") || "Isthmus user"

    Repo.transaction(fn ->
      {:ok, group} =
        insert_group(%{
          owner_pubkey_hex: owner_hex,
          display_name: display_name,
          status: "active",
          created_by: Map.get(attrs, :created_by) || "self_service",
          kind: "registration"
        })

      {:ok, _} =
        insert_leg(group, %{
          network: "reticulum",
          role: "primary",
          identity_ref: ref,
          public_material: stringify_map(material),
          presentation_cache: %{
            items: Networks.Reticulum.identity_presentations(ref, material)
          },
          encrypted_private_material: nil
        })

      :ok = mint_nostr_proxy!(group, display_name)
      :ok = mint_meshcore_proxy!(group, display_name)
      # Also mint a receive proxy so MeshChatX can message Isthmus → fanout to primary
      :ok = mint_rns_proxy!(group, display_name <> " inbox")
      get_group!(group.id)
    end)
  end

  defp mint_nostr_proxy!(group, display_name) do
    {:ok, nostr} = Networks.Nostr.generate_proxy_identity(%{name: display_name})
    {:ok, enc} = Vault.encrypt(nostr.private_material)

    {:ok, _} =
      insert_leg(group, %{
        network: "nostr",
        role: "proxy",
        identity_ref: nostr.identity_ref,
        public_material: stringify_map(nostr.public_material),
        presentation_cache: %{items: nostr.presentations},
        encrypted_private_material: enc
      })

    :ok
  end

  defp mint_nostr_proxy(group, display_name) do
    mint_nostr_proxy!(group, display_name)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp mint_rns_proxy!(group, display_name) do
    {:ok, rns} = Networks.Reticulum.generate_proxy_identity(%{name: display_name})
    {:ok, enc} = Vault.encrypt(rns.private_material)

    {:ok, _} =
      insert_leg(group, %{
        network: "reticulum",
        role: "proxy",
        identity_ref: rns.identity_ref,
        public_material: stringify_map(rns.public_material),
        presentation_cache: %{items: rns.presentations},
        encrypted_private_material: enc
      })

    :ok
  end

  defp mint_rns_proxy(group, display_name) do
    mint_rns_proxy!(group, display_name)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp mint_meshcore_proxy!(group, display_name) do
    {:ok, mc} = Networks.MeshCore.generate_proxy_identity(%{name: display_name})
    {:ok, enc} = Vault.encrypt(mc.private_material)

    {:ok, _} =
      insert_leg(group, %{
        network: "meshcore",
        role: "proxy",
        identity_ref: mc.identity_ref,
        public_material: stringify_map(mc.public_material),
        presentation_cache: %{items: mc.presentations},
        encrypted_private_material: enc
      })

    reload_meshcore_synthetics()
    :ok
  end

  defp mint_meshcore_proxy(group, display_name) do
    mint_meshcore_proxy!(group, display_name)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp reload_meshcore_synthetics do
    cfg = Application.get_env(:isthmus, Isthmus.Networks.MeshCore.SyntheticNode, [])

    if Keyword.get(cfg, :autoload, true) do
      Isthmus.Networks.MeshCore.SyntheticNode.reload()
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp insert_group(attrs) do
    %RegistrationGroup{}
    |> RegistrationGroup.changeset(attrs)
    |> Repo.insert()
  end

  defp insert_leg(group, attrs) do
    %IdentityLeg{}
    |> IdentityLeg.changeset(Map.put(attrs, :registration_group_id, group.id))
    |> Repo.insert()
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

  defp parse_attached(_, _), do: {:error, :unsupported_network}

  defp ensure_ref_free(network, ref) do
    reclaim_orphaned_legs(network, ref)

    case find_by_leg(network, ref) do
      nil -> :ok
      _ -> {:error, :identity_already_linked}
    end
  end

  # Pre-fix revokes left legs behind; delete those so unique index can't block reuse.
  # SQLite cannot DELETE with JOIN, so select ids then delete.
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
    case active_registration_for_owner(owner_hex) do
      nil -> :ok
      existing -> {:error, {:already_registered, existing}}
    end
  end

  defp ensure_channel_idx_free(idx) do
    case find_by_meshcore_channel(idx) do
      nil -> :ok
      _ -> {:error, :channel_already_linked}
    end
  end

  defp first_empty_private_channel_slot do
    channels = Companion.list_channels()
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

  defp prepare_leg_for_announce(%IdentityLeg{network: "reticulum"} = leg) do
    ensure_reticulum_ready(leg)
  end

  defp prepare_leg_for_announce(leg), do: {:ok, leg}

  defp remint_reticulum_leg(%IdentityLeg{role: "proxy"} = leg) do
    alias Isthmus.Networks.Reticulum.Sidecar

    display = group_display_name(leg)
    {:ok, rns} = Networks.Reticulum.generate_proxy_identity(%{name: display})
    stub? = rns.public_material[:stub] == true or rns.public_material["stub"] == true

    if stub? do
      {:error, :rns_still_stub}
    else
      pk = rns.private_material[:private_key_hex] || rns.private_material["private_key_hex"]
      {:ok, enc} = Vault.encrypt(rns.private_material)

      case leg
           |> IdentityLeg.changeset(%{
             identity_ref: rns.identity_ref,
             public_material: stringify_map(rns.public_material),
             presentation_cache: %{items: rns.presentations},
             encrypted_private_material: enc
           })
           |> Repo.update() do
        {:ok, updated} ->
          _ =
            if is_binary(pk) do
              Sidecar.register_identity(%{"private_key_hex" => pk, "display_name" => display})
            end

          {:ok, updated}

        {:error, _} = err ->
          err
      end
    end
  end

  defp remint_reticulum_leg(leg), do: {:ok, leg}

  defp private_key_hex(%IdentityLeg{} = leg) do
    cond do
      reticulum_stub?(leg) ->
        {:error, :stub_material}

      not is_binary(leg.encrypted_private_material) ->
        {:error, :missing_private_material}

      true ->
        case Vault.decrypt(leg.encrypted_private_material) do
          {:ok, material} ->
            pk = material["private_key_hex"] || material[:private_key_hex]

            if is_binary(pk) and byte_size(pk) >= 64 do
              {:ok, pk}
            else
              {:error, :stub_material}
            end

          {:error, _} ->
            {:error, :decrypt_failed}
        end
    end
  end

  defp nostr_leg_seckey(%IdentityLeg{} = leg) do
    if not is_binary(leg.encrypted_private_material) do
      {:error, :missing_private_material}
    else
      case Vault.decrypt(leg.encrypted_private_material) do
        {:ok, material} ->
          seckey_from_nostr_material(material)

        {:error, _} ->
          {:error, :decrypt_failed}
      end
    end
  end

  defp seckey_from_nostr_material(material) when is_map(material) do
    seckey_hex = material["seckey_hex"] || material[:seckey_hex]
    nsec = material["nsec"] || material[:nsec]

    cond do
      is_binary(seckey_hex) ->
        case Base.decode16(seckey_hex, case: :mixed) do
          {:ok, sk} when byte_size(sk) == 32 ->
            {:ok, Isthmus.Nostr.Crypto.normalize_seckey(sk)}

          _ ->
            {:error, :invalid_seckey}
        end

      is_binary(nsec) ->
        case Bech32.decode(String.trim(nsec)) do
          {:ok, "nsec", sk} when byte_size(sk) == 32 ->
            {:ok, Isthmus.Nostr.Crypto.normalize_seckey(sk)}

          _ ->
            {:error, :invalid_nsec}
        end

      true ->
        {:error, :missing_seckey}
    end
  end

  defp reload_nostr_subscriptions do
    if Process.whereis(Isthmus.Networks.Nostr.RelayPool) do
      Isthmus.Networks.Nostr.RelayPool.reload()
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reticulum_stub?(%IdentityLeg{public_material: mat}) when is_map(mat) do
    mat["stub"] == true or mat[:stub] == true or
      (is_binary(mat["note"]) and String.contains?(mat["note"], "stub")) or
      (is_binary(mat[:note]) and String.contains?(mat[:note], "stub"))
  end

  defp reticulum_stub?(_), do: false

  defp group_display_name(%IdentityLeg{registration_group_id: id}) do
    case Repo.get(RegistrationGroup, id) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> "Isthmus"
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
