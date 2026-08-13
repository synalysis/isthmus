defmodule Isthmus.Registrations.Announce do
  @moduledoc false

  require Logger

  alias Isthmus.Networks
  alias Isthmus.Networks.Reticulum.Sidecar
  alias Isthmus.Registrations.{IdentityLeg, Proxy, Query, RegistrationGroup}
  alias Isthmus.Repo
  alias Isthmus.Vault

  @type group :: RegistrationGroup.t()
  @type leg :: IdentityLeg.t()
  @type result(ok) :: {:ok, ok} | {:error, term()}

  @spec can_announce_leg?(term()) :: boolean()
  def can_announce_leg?(%IdentityLeg{} = leg) do
    Networks.supports_announce?(leg.network) and leg.role == "proxy"
  end

  def can_announce_leg?(_), do: false

  @spec external_reticulum_leg?(term()) :: boolean()
  def external_reticulum_leg?(%IdentityLeg{network: "reticulum", role: role})
      when role in ["primary", "member"],
      do: true

  def external_reticulum_leg?(_), do: false

  @spec announce_leg(leg()) :: :ok | {:error, term()}
  @spec announce_leg(leg(), map() | keyword()) :: :ok | {:error, term()}
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

  @spec ensure_reticulum_ready(leg()) :: result(leg())
  def ensure_reticulum_ready(%IdentityLeg{network: "reticulum"} = leg) do
    if leg.role in ["primary", "member"] do
      {:ok, leg}
    else
      register_or_remint_reticulum(leg)
    end
  end

  def ensure_reticulum_ready(%IdentityLeg{} = leg), do: {:ok, leg}

  @spec announce_group(group()) :: result([{String.t(), :ok | {:error, term()}}])
  @spec announce_group(group(), map() | keyword()) ::
          result([{String.t(), :ok | {:error, term()}}])
  def announce_group(%RegistrationGroup{legs: legs} = group, opts \\ %{}) when is_list(legs) do
    if group.status == "revoked" do
      {:error, :revoked}
    else
      group = ensure_announce_proxies(group)

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

  @spec request_reticulum_path(leg()) :: :ok | {:ok, term()} | {:error, term()}
  def request_reticulum_path(%IdentityLeg{} = leg) do
    if external_reticulum_leg?(leg) do
      Isthmus.Networks.Reticulum.request_path(leg.identity_ref)
    else
      {:error, :not_external_reticulum}
    end
  end

  defp ensure_announce_proxies(%RegistrationGroup{kind: "bridge"} = group) do
    group =
      case Proxy.ensure_bridge_rns_proxy(group) do
        {:ok, g} -> g
        {:error, _} -> group
      end

    ensure_shared_proxies(group)
  end

  defp ensure_announce_proxies(group), do: ensure_shared_proxies(group)

  defp ensure_shared_proxies(group) do
    group =
      case Proxy.ensure_nostr_proxy(group) do
        {:ok, g} -> g
        {:error, _} -> group
      end

    case Proxy.ensure_meshcore_proxy(group) do
      {:ok, g} -> g
      {:error, _} -> group
    end
  end

  defp register_or_remint_reticulum(leg) do
    case private_key_hex(leg) do
      {:ok, pk} ->
        register_reticulum_identity(leg, pk)

      {:error, :stub_material} ->
        if reticulum_stub?(leg), do: remint_reticulum_leg(leg), else: {:error, :stub_material}

      {:error, :decrypt_failed} ->
        Logger.error(
          "RNS proxy #{leg.identity_ref} vault decrypt failed — check ISTHMUS_VAULT_SECRET matches the secret used when the key was stored. Refusing to remint."
        )

        {:error, :decrypt_failed}

      {:error, _} = err ->
        err
    end
  end

  defp register_reticulum_identity(leg, pk) do
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

      {:error, reason, _} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_leg_for_announce(%IdentityLeg{network: "reticulum"} = leg) do
    ensure_reticulum_ready(leg)
  end

  defp prepare_leg_for_announce(leg), do: {:ok, leg}

  defp remint_reticulum_leg(%IdentityLeg{role: "proxy"} = leg) do
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
             public_material: Query.stringify_map(rns.public_material),
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
end
