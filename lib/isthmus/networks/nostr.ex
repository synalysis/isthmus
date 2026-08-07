defmodule Isthmus.Networks.Nostr do
  @moduledoc "Nostr network adapter with relay pool."
  @behaviour Isthmus.NetworkAdapter

  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Relays

  @impl true
  def network_id, do: :nostr

  @impl true
  def capabilities, do: MapSet.new([:dm, :identity, :raw_tunnel])

  @impl true
  def parse_identity_ref(input) when is_binary(input) do
    cleaned = String.trim(input)

    case Bech32.decode(cleaned) do
      {:ok, "npub", pubkey} when byte_size(pubkey) == 32 ->
        hex = Base.encode16(pubkey, case: :lower)
        {:ok, hex, %{npub: Bech32.encode_npub(pubkey), pubkey_hex: hex}}

      _ ->
        with true <- String.match?(cleaned, ~r/^[0-9a-fA-F]{64}$/),
             hex <- String.downcase(cleaned),
             {:ok, bin} <- Base.decode16(hex, case: :lower) do
          {:ok, hex, %{npub: Bech32.encode_npub(bin), pubkey_hex: hex}}
        else
          _ -> {:error, :invalid_nostr_identity}
        end
    end
  end

  @impl true
  def generate_proxy_identity(_opts) do
    {seckey, _pubkey} = Secp256k1.keypair(:xonly)
    seckey = Isthmus.Nostr.Crypto.normalize_seckey(seckey)
    pubkey = Secp256k1.pubkey(seckey, :xonly)
    hex = Base.encode16(pubkey, case: :lower)
    npub = Bech32.encode_npub(pubkey)
    nsec = Bech32.encode("nsec", seckey)

    {:ok,
     %{
       identity_ref: hex,
       public_material: %{pubkey_hex: hex, npub: npub},
       private_material: %{nsec: nsec, seckey_hex: Base.encode16(seckey, case: :lower)},
       presentations: identity_presentations(hex, %{npub: npub})
     }}
  end

  @impl true
  def identity_presentations(_ref, material) do
    npub = material[:npub] || material["npub"]

    relays =
      Relays.list_relays() |> Enum.filter(& &1.enabled) |> Enum.map(& &1.url) |> Enum.take(3)

    [
      %{
        format_id: "nostr_npub",
        label: "Nostr npub",
        uri_or_text: npub || "",
        qr_payload: if(npub, do: "nostr:" <> npub),
        app_hints: ["Damus", "Amethyst", "Alby"] ++ relays
      }
    ]
  end

  @impl true
  def health do
    pool =
      try do
        RelayPool.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    relays = Relays.list_relays()

    Map.merge(
      %{
        network: :nostr,
        relays_configured: length(relays),
        detail: "Relay pool"
      },
      pool
    )
  end

  # RNS-/MeshCore-over-Nostr tunnel carrier (kind 21278).
  @impl true
  def mtu(_opts), do: 1200

  @impl true
  def estimated_bitrate(_opts), do: 50_000

  @impl true
  def send_raw(payload, opts) when is_binary(payload) do
    Isthmus.Networks.Nostr.TunnelCarrier.send_raw(payload, opts)
  end
end
