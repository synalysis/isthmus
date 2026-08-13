defmodule Isthmus.Networks.MeshCore do
  @moduledoc "MeshCore companion adapter."
  @behaviour Isthmus.NetworkAdapter

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.BridgeCLI
  alias Isthmus.Networks.MeshCore.BridgeLink
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.SyntheticNode

  @impl true
  def network_id, do: :meshcore

  @impl true
  def capabilities, do: MapSet.new([:dm, :identity, :raw_tunnel, :airtime_limited, :announce])

  @impl true
  def parse_identity_ref(input) when is_binary(input) do
    cleaned = String.trim(input)

    cond do
      String.starts_with?(cleaned, "meshcore://contact/add?") ->
        uri = URI.parse(cleaned)
        params = URI.decode_query(uri.query || "")

        case Map.get(params, "public_key") do
          key when is_binary(key) and byte_size(key) == 64 ->
            hex = String.downcase(key)
            {:ok, hex, %{public_key: hex, name: params["name"], type: params["type"] || "1"}}

          _ ->
            {:error, :invalid_meshcore_uri}
        end

      String.match?(cleaned, ~r/^[0-9a-fA-F]{64}$/) ->
        hex = String.downcase(cleaned)
        {:ok, hex, %{public_key: hex}}

      true ->
        {:error, :invalid_meshcore_identity}
    end
  end

  @impl true
  def generate_proxy_identity(opts) do
    name = Map.get(opts, :name, "Isthmus Proxy")
    {public, secret} = Crypto.generate_keypair()
    hex = Base.encode16(public, case: :lower)

    uri =
      "meshcore://contact/add?name=#{URI.encode_www_form(name)}&public_key=#{hex}&type=1"

    {:ok,
     %{
       identity_ref: hex,
       public_material: %{public_key: hex, name: name, type: 1},
       private_material: %{
         secret_hex: Base.encode16(secret, case: :lower),
         public_key: hex
       },
       presentations: identity_presentations(hex, %{uri: uri, public_key: hex, name: name})
     }}
  end

  @doc "32-byte Ed25519 seed from vaulted proxy private material."
  def private_seed(%{secret_hex: hex}) when is_binary(hex),
    do: private_seed(%{"secret_hex" => hex})

  def private_seed(%{"secret_hex" => hex}) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, seed} when byte_size(seed) == 32 -> {:ok, seed}
      _ -> {:error, :invalid_seed}
    end
  end

  def private_seed(_), do: {:error, :invalid_seed}

  @impl true
  def identity_presentations(_ref, material) do
    uri = material[:uri] || material["uri"] || build_contact_uri(material)

    [
      %{
        format_id: "meshcore_contact",
        label: "MeshCore contact",
        uri_or_text: uri,
        qr_payload: uri,
        app_hints: ["MeshCore"]
      }
    ]
  end

  @impl true
  def health do
    companion =
      try do
        Companion.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    bridge =
      try do
        BridgeLink.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    bridge_cli =
      try do
        BridgeCLI.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    synthetic =
      try do
        SyntheticNode.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    Map.merge(
      %{
        network: :meshcore,
        detail: "Companion and island tunnel radios"
      },
      companion
    )
    |> Map.put(:bridge, bridge)
    |> Map.put(:bridge_cli, bridge_cli)
    |> Map.put(:synthetic, synthetic)
  end

  @impl true
  def mtu(_opts), do: 184

  @impl true
  def estimated_bitrate(_opts), do: 300

  @impl true
  def send_raw(payload, opts) when is_binary(payload) do
    Companion.send_raw(payload, opts)
  end

  @doc """
  Transmit a tunnelled MeshCore packet verbatim on the local island.

  Requires a bridge-enabled repeater on `ISTHMUS_MESHCORE_BRIDGE_PORT`. The
  companion cannot do this — its `CMD_SEND_RAW_DATA` builds a `RAW_CUSTOM` app
  packet from our own identity rather than replaying the original.
  """
  @impl true
  def inject_raw(payload, _opts) when is_binary(payload) do
    BridgeLink.inject(payload)
  end

  @impl true
  def announce_or_advert(ref, opts \\ %{}) do
    opts = Map.new(opts)
    force? = truthy?(opts[:force] || opts["force"])
    flood? = truthy?(opts[:flood] || opts["flood"])
    from_tunnel? = truthy?(opts[:from_tunnel] || opts["from_tunnel"])
    bridge_online? = match?(%{status: :online}, BridgeLink.health())

    cond do
      bridge_online? and is_binary(ref) and SyntheticNode.has_identity?(ref) ->
        SyntheticNode.announce(ref, Map.put(opts, :force, force? || from_tunnel?))

      true ->
        allowed =
          if force? do
            :ok
          else
            Governor.allow?(:advert, :meshcore, "companion")
          end

        case allowed do
          :ok ->
            result =
              case Companion.send_self_advert(flood: flood?) do
                :ok -> :ok
                {:ok, _} -> :ok
                {:error, reason} -> {:error, reason}
              end

            if match?(:ok, result) and is_binary(ref) and ref != "" do
              _ =
                Sightings.record(%{
                  network: "meshcore",
                  direction: "out",
                  identity_ref: ref,
                  hops: 0,
                  meta: %{source: "self_advert", flood: flood?, from_tunnel: from_tunnel?}
                })

              unless from_tunnel? do
                Isthmus.Tunnel.Bridge.forward_announce("meshcore", ref, %{
                  source: "self_advert",
                  flood: flood?
                })
              end
            end

            result

          {:drop, reason} ->
            {:error, {:governor, reason}}
        end
    end
  end

  defp build_contact_uri(material) do
    name = material[:name] || material["name"] || "Isthmus"
    key = material[:public_key] || material["public_key"]
    "meshcore://contact/add?name=#{URI.encode_www_form(name)}&public_key=#{key}&type=1"
  end

  defp truthy?(v), do: v in [true, "true", "1", 1]
end
