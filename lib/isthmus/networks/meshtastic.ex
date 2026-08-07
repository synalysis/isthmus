defmodule Isthmus.Networks.Meshtastic do
  @moduledoc """
  Meshtastic adapter stub.

  Not a live radio client yet — implements `Isthmus.NetworkAdapter` so registration,
  QR presentation, and health surfaces can grow without core rewrites.

  See `docs/guides/meshtastic_adapter.md` for the integration guide.
  """
  @behaviour Isthmus.NetworkAdapter

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
    # Placeholder 32-bit node id until a real radio-backed identity is minted.
    node_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    {:ok,
     %{
       identity_ref: node_id,
       public_material: %{node_id: node_id, name: name},
       private_material: %{note: "meshtastic proxy stub — bind to radio later"},
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
    %{
      network: :meshtastic,
      status: :stub,
      detail: "Adapter stub — see docs/guides/meshtastic_adapter.md"
    }
  end

  @impl true
  def mtu(_opts), do: 200

  @impl true
  def estimated_bitrate(_opts), do: 50

  @impl true
  def send_message(_ref, _body, _opts), do: {:error, :not_implemented}

  @impl true
  def send_raw(_payload, _opts), do: {:error, :not_implemented}
end
