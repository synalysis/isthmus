defmodule Isthmus.Repo.Migrations.NormalizeTunnelPeerRefs do
  use Ecto.Migration

  # Peers created before peer_ref was normalized in the changeset can hold
  # mixed-case or padded refs, which never match the downcased/trimmed lookups
  # in Tunnel.candidates/1 and Sightings.lookup_tunnel_id/1.
  def up do
    execute("""
    UPDATE tunnel_peers
    SET peer_ref = lower(trim(peer_ref))
    WHERE peer_ref IS NOT NULL AND peer_ref <> lower(trim(peer_ref))
    """)
  end

  def down, do: :ok
end
