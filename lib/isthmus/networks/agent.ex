defmodule Isthmus.Networks.Agent do
  @moduledoc """
  ACP agent adapter.

  A group member on this network is a coding agent Isthmus drives as an ACP
  **client** (via `ex_mcp`). Attach a short name such as `cursor`; Isthmus
  prompts that agent with group traffic and fans the reply back out.

  Default command is Cursor CLI `agent acp`. Override from Admin → ACP
  or `ISTHMUS_ACP_COMMAND`. Member identity is a session name on that one
  subprocess — it does not select which binary to spawn.
  """
  @behaviour Isthmus.NetworkAdapter

  alias Isthmus.Networks.Agent.Bridge

  @impl true
  def network_id, do: :agent

  @impl true
  def capabilities, do: MapSet.new([:dm])

  @impl true
  def parse_identity_ref(input) when is_binary(input) do
    cleaned =
      input
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    if Regex.match?(~r/\A[a-z][a-z0-9_-]{1,31}\z/, cleaned) do
      {:ok, cleaned, %{name: cleaned}}
    else
      {:error, :invalid_agent_identity}
    end
  end

  @impl true
  def generate_proxy_identity(_opts), do: {:error, :not_supported}

  @impl true
  def identity_presentations(ref, _material) do
    [
      %{
        format_id: "acp_agent",
        label: "ACP agent",
        uri_or_text: ref,
        qr_payload: nil,
        app_hints: ["Admin → ACP", "Cursor `agent acp`", "Gemini `gemini --acp`"]
      }
    ]
  end

  @impl true
  def health do
    try do
      Bridge.health()
    catch
      :exit, _ ->
        %{
          status: :not_started,
          last_error: "ACP bridge not started",
          detail: "Agent Client Protocol"
        }
    end
  end

  @impl true
  def send_message(identity_ref, text, meta) when is_binary(identity_ref) and is_binary(text) do
    Bridge.prompt(identity_ref, text, meta || %{})
  end

  @impl true
  def subscribe_inbound(_pid), do: :ok

  @impl true
  def mtu(_opts), do: 1024

  @impl true
  def send_raw(_bin, _opts), do: {:error, :not_supported}

  @impl true
  def inject_raw(_bin, _opts), do: {:error, :not_supported}

  @impl true
  def subscribe_raw(_pid), do: :ok

  @impl true
  def estimated_bitrate(_opts), do: 0
end
