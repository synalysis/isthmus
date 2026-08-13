defmodule Isthmus.Networks.Meshtastic do
  @moduledoc """
  Meshtastic adapter.

  Companion serial API (`Isthmus.Networks.Meshtastic.Companion`) bridges
  channel text into registration groups. Opaque tunnel frames still go through
  the in-memory `Meshtastic.Transport` until a radio-backed raw path exists.
  """
  @behaviour Isthmus.NetworkAdapter

  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.Transport

  @impl true
  def network_id, do: :meshtastic

  @impl true
  def capabilities, do: MapSet.new([:dm, :identity, :airtime_limited])

  @impl true
  def parse_identity_ref(input) when is_binary(input) do
    cleaned = String.trim(input)

    cond do
      String.match?(cleaned, ~r/^[0-9a-fA-F]{8}$/) ->
        hex = String.downcase(cleaned)
        {:ok, hex, %{node_id: hex}}

      String.match?(cleaned, ~r/![0-9a-fA-F]{8}/) ->
        hex = cleaned |> String.trim_leading("!") |> String.downcase()
        {:ok, hex, %{node_id: hex}}

      true ->
        {:error, :invalid_meshtastic_identity}
    end
  end

  @impl true
  def generate_proxy_identity(opts) do
    name = Map.get(opts, :name, "Isthmus Meshtastic Proxy")

    node_id =
      case Companion.health() do
        %{node_id: id} when is_binary(id) and id != "" -> id
        _ -> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      end

    {:ok,
     %{
       identity_ref: node_id,
       public_material: %{node_id: node_id, name: name},
       private_material: %{note: "meshtastic companion node — DMs use the attached radio"},
       presentations: identity_presentations(node_id, %{node_id: node_id, name: name})
     }}
  end

  @impl true
  def identity_presentations(ref, material) do
    node = material[:node_id] || material["node_id"] || ref
    name = material[:name] || material["name"] || "Isthmus"
    uri = "https://meshtastic.org/e/#?name=#{URI.encode_www_form(name)}&node=#{node}"

    [
      %{
        format_id: "meshtastic_node",
        label: "Meshtastic node",
        uri_or_text: "!#{node}",
        qr_payload: uri,
        app_hints: ["Meshtastic"]
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

    transport =
      try do
        Transport.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    Map.merge(
      %{
        network: :meshtastic,
        detail: companion[:detail] || "Meshtastic companion",
        tunnel_transport: transport[:status]
      },
      companion
    )
  end

  @impl true
  def mtu(_opts), do: 200

  @impl true
  def estimated_bitrate(_opts), do: 50

  @impl true
  def send_message(ref, body, _opts) when is_binary(ref) and is_binary(body) do
    Companion.send_text(ref, body)
  end

  @impl true
  def send_raw(payload, opts) when is_binary(payload) do
    Transport.send_raw(payload, opts)
  end
end
