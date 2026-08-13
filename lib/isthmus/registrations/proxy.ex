defmodule Isthmus.Registrations.Proxy do
  @moduledoc false

  alias Isthmus.Networks
  alias Isthmus.Registrations.{IdentityLeg, Query, RegistrationGroup}
  alias Isthmus.Vault

  @type group :: RegistrationGroup.t()
  @type leg :: IdentityLeg.t()
  @type result(ok) :: {:ok, ok} | {:error, term()}

  @spec ensure_bridge_rns_proxy(group()) :: result(group())
  def ensure_bridge_rns_proxy(%RegistrationGroup{kind: "bridge"} = group) do
    group = Query.get_group!(group.id)

    if Enum.any?(group.legs, &(&1.network == "reticulum" and &1.role == "proxy")) do
      {:ok, group}
    else
      display = (group.display_name || "Bridge") <> " bridge"

      case mint_rns_proxy(group, display) do
        :ok -> {:ok, Query.get_group!(group.id)}
        {:error, _} = err -> err
      end
    end
  end

  def ensure_bridge_rns_proxy(%RegistrationGroup{} = group), do: {:ok, Query.get_group!(group.id)}

  @spec ensure_nostr_proxy(group()) :: result(group())
  def ensure_nostr_proxy(%RegistrationGroup{} = group) do
    group = Query.get_group!(group.id)

    if Enum.any?(group.legs, &(&1.network == "nostr" and &1.role == "proxy")) do
      {:ok, group}
    else
      display = group.display_name || "Isthmus"

      case mint_nostr_proxy(group, display) do
        :ok ->
          reload_nostr_subscriptions()
          {:ok, Query.get_group!(group.id)}

        {:error, _} = err ->
          err
      end
    end
  end

  @spec nostr_proxy_leg(group() | term()) :: leg() | nil
  def nostr_proxy_leg(%RegistrationGroup{legs: legs}) when is_list(legs) do
    Enum.find(legs, &(&1.network == "nostr" and &1.role == "proxy"))
  end

  def nostr_proxy_leg(_), do: nil

  @spec ensure_meshcore_proxy(group()) :: result(group())
  def ensure_meshcore_proxy(%RegistrationGroup{} = group) do
    group = Query.get_group!(group.id)

    if Enum.any?(group.legs, &(&1.network == "meshcore" and &1.role == "proxy")) do
      {:ok, group}
    else
      display = group.display_name || "Isthmus"

      case mint_meshcore_proxy(group, display) do
        :ok ->
          reload_meshcore_synthetics()
          {:ok, Query.get_group!(group.id)}

        {:error, _} = err ->
          err
      end
    end
  end

  @spec meshcore_proxy_leg(group() | term()) :: leg() | nil
  def meshcore_proxy_leg(%RegistrationGroup{legs: legs}) when is_list(legs) do
    Enum.find(legs, &(&1.network == "meshcore" and &1.role == "proxy"))
  end

  def meshcore_proxy_leg(_), do: nil

  @spec list_meshcore_proxy_legs() :: [leg()]
  def list_meshcore_proxy_legs do
    Query.list_all()
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.flat_map(fn group ->
      Enum.filter(group.legs, &(&1.network == "meshcore" and &1.role == "proxy"))
    end)
  end

  @spec meshcore_proxy_seed(term()) ::
          {:ok, binary(), binary()} | {:error, atom()}
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

  @spec nostr_proxy_seckey(group()) :: {:ok, binary()} | {:error, atom()}
  def nostr_proxy_seckey(%RegistrationGroup{} = group) do
    case nostr_proxy_leg(group) do
      nil -> {:error, :no_nostr_proxy}
      leg -> nostr_leg_seckey(leg)
    end
  end

  @spec list_nostr_inbox_keypairs() :: [{String.t(), binary()}]
  def list_nostr_inbox_keypairs do
    proxy_pairs =
      Query.list_all()
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

  @spec mint_nostr_proxy!(group(), String.t()) :: :ok
  def mint_nostr_proxy!(group, display_name) do
    {:ok, nostr} = Networks.Nostr.generate_proxy_identity(%{name: display_name})
    {:ok, enc} = Vault.encrypt(nostr.private_material)

    {:ok, _} =
      Query.insert_leg(group, %{
        network: "nostr",
        role: "proxy",
        identity_ref: nostr.identity_ref,
        public_material: Query.stringify_map(nostr.public_material),
        presentation_cache: %{items: nostr.presentations},
        encrypted_private_material: enc
      })

    :ok
  end

  @spec mint_rns_proxy!(group(), String.t()) :: :ok
  def mint_rns_proxy!(group, display_name) do
    {:ok, rns} = Networks.Reticulum.generate_proxy_identity(%{name: display_name})
    {:ok, enc} = Vault.encrypt(rns.private_material)

    {:ok, _} =
      Query.insert_leg(group, %{
        network: "reticulum",
        role: "proxy",
        identity_ref: rns.identity_ref,
        public_material: Query.stringify_map(rns.public_material),
        presentation_cache: %{items: rns.presentations},
        encrypted_private_material: enc
      })

    :ok
  end

  @spec mint_meshcore_proxy!(group(), String.t()) :: :ok
  def mint_meshcore_proxy!(group, display_name) do
    {:ok, mc} = Networks.MeshCore.generate_proxy_identity(%{name: display_name})
    {:ok, enc} = Vault.encrypt(mc.private_material)

    {:ok, _} =
      Query.insert_leg(group, %{
        network: "meshcore",
        role: "proxy",
        identity_ref: mc.identity_ref,
        public_material: Query.stringify_map(mc.public_material),
        presentation_cache: %{items: mc.presentations},
        encrypted_private_material: enc
      })

    reload_meshcore_synthetics()
    :ok
  end

  defp mint_nostr_proxy(group, display_name) do
    mint_nostr_proxy!(group, display_name)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp mint_rns_proxy(group, display_name) do
    mint_rns_proxy!(group, display_name)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
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
        case Isthmus.Nostr.Bech32.decode(String.trim(nsec)) do
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
end
