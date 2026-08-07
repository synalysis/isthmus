defmodule Isthmus.Accounts do
  @moduledoc "Admin allowlist and role helpers."

  import Ecto.Query
  alias Isthmus.Accounts.AdminPubkey
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Repo

  def admin?(pubkey_hex) when is_binary(pubkey_hex) do
    hex = String.downcase(pubkey_hex)

    env_admin?(hex) or
      Repo.exists?(from a in AdminPubkey, where: a.pubkey_hex == ^hex)
  end

  def admin?(_), do: false

  def list_admins do
    Repo.all(from a in AdminPubkey, order_by: [asc: a.inserted_at])
  end

  def add_admin(attrs) do
    %AdminPubkey{}
    |> AdminPubkey.changeset(normalize_admin_attrs(attrs))
    |> Repo.insert()
  end

  def remove_admin(id), do: Repo.get!(AdminPubkey, id) |> Repo.delete()

  def bootstrap_from_env! do
    for npub <- env_admin_npubs() do
      case Bech32.decode(npub) do
        {:ok, "npub", pubkey} ->
          hex = Base.encode16(pubkey, case: :lower)
          encoded = Bech32.encode_npub(pubkey)

          case Repo.get_by(AdminPubkey, pubkey_hex: hex) do
            nil ->
              {:ok, _} = add_admin(%{pubkey_hex: hex, npub: encoded, label: "bootstrap"})

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp env_admin?(hex) do
    Enum.any?(env_admin_npubs(), fn npub ->
      case Bech32.decode(npub) do
        {:ok, "npub", pubkey} -> Base.encode16(pubkey, case: :lower) == hex
        _ -> false
      end
    end)
  end

  defp env_admin_npubs do
    System.get_env("ISTHMUS_ADMIN_NPUBS", "")
    |> String.split([",", " ", "\n"], trim: true)
  end

  defp normalize_admin_attrs(%{npub: npub} = attrs) when is_binary(npub) do
    case Bech32.decode(npub) do
      {:ok, "npub", pubkey} ->
        Map.merge(attrs, %{
          pubkey_hex: Base.encode16(pubkey, case: :lower),
          npub: Bech32.encode_npub(pubkey)
        })

      _ ->
        attrs
    end
  end

  defp normalize_admin_attrs(attrs), do: attrs
end
