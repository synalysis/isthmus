defmodule IsthmusWeb.Admin.TunnelsLive do
  use IsthmusWeb, :live_view

  alias IsthmusWeb.Admin.TunnelsHTML

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.LocalIdentity
  alias Isthmus.Networks.Reticulum
  alias Isthmus.Networks.Reticulum.Sidecar
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.Outbox
  alias Isthmus.Tunnel.Peer

  @default_carrier "meshcore"
  @default_payload "reticulum"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:carrier, @default_carrier)
     |> assign(:payload, @default_payload)
     |> assign(:modal, nil)
     |> assign(:editing_peer, nil)
     |> assign(:edit_form, nil)
     |> assign(:edit_pairing, "")
     |> assign_local_identity()
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  @impl true
  # phx-change fires on every keystroke. The payload/carrier selects must be
  # controlled from assigns, otherwise each re-render resets them to their first
  # <option> (dropping the operator's choice before submit). Resolving the local
  # identity can hit the RNS sidecar, so only do that when the carrier moves.
  def handle_event("form_changed", %{"peer" => peer}, socket) do
    socket = assign(socket, :payload, peer["payload_network"] || socket.assigns.payload)
    carrier = peer["carrier_network"] || socket.assigns.carrier

    socket =
      if carrier == socket.assigns.carrier do
        socket
      else
        socket
        |> assign(:carrier, carrier)
        |> assign_local_identity()
      end

    {:noreply, socket}
  end

  def handle_event("form_changed", _params, socket), do: {:noreply, socket}

  def handle_event("open_add_peer", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal, :add_peer)
     |> assign(:carrier, @default_carrier)
     |> assign(:payload, @default_payload)
     |> assign(:form, to_form(Tunnel.change_peer(%Peer{})))
     |> assign_local_identity()}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("save", %{"peer" => params}, socket) do
    case Tunnel.create_peer(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tunnel peer added.")
         |> assign(:modal, nil)
         |> assign(:form, to_form(Tunnel.change_peer(%Peer{})))
         |> assign(:carrier, @default_carrier)
         |> assign(:payload, @default_payload)
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)
    {:ok, _} = Tunnel.update_peer(peer, %{enabled: !peer.enabled})
    {:noreply, assign_data(socket)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)

    {:noreply,
     socket
     |> assign(:editing_peer, peer)
     |> assign(:edit_form, to_form(Tunnel.change_peer(peer)))
     |> assign(:edit_pairing, "")}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_edit(socket)}
  end

  def handle_event("validate_edit", %{"peer" => params}, socket) do
    case socket.assigns.editing_peer do
      nil ->
        {:noreply, socket}

      peer ->
        changeset = peer |> Tunnel.change_peer(params) |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:edit_form, to_form(changeset))
         |> assign(:edit_pairing, params["pairing_code"] || "")}
    end
  end

  def handle_event("save_edit", %{"peer" => params}, socket) do
    case socket.assigns.editing_peer do
      nil ->
        {:noreply, socket}

      peer ->
        case Tunnel.update_peer(peer, params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Tunnel peer updated.")
             |> clear_edit()
             |> assign_data()}

          {:error, changeset} ->
            {:noreply, assign(socket, :edit_form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)
    {:ok, _} = Tunnel.delete_peer(peer)

    socket =
      if socket.assigns.editing_peer && socket.assigns.editing_peer.id == peer.id do
        clear_edit(socket)
      else
        socket
      end

    {:noreply, socket |> put_flash(:info, "Tunnel peer deleted.") |> assign_data()}
  end

  def handle_event("retry_outbox", %{"id" => id}, socket) do
    result =
      case Outbox.nudge(id) do
        {:ok, _} = ok -> ok
        {:error, :not_active} -> Outbox.retry(id)
        other -> other
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Queued for delivery.") |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Retry failed: #{inspect(reason)}")}
    end
  end

  def handle_event("drop_outbox", %{"id" => id}, socket) do
    case Outbox.drop(id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Dropped from outbox.") |> assign_data()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Drop failed: #{inspect(reason)}")}
    end
  end

  def handle_event("request_path", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)

    case Reticulum.request_path(peer.peer_ref) do
      {:ok, status} ->
        known =
          if status[:path_known] || status["path_known"], do: "path known", else: "requested"

        {:noreply, socket |> put_flash(:info, "RNS path #{known} for peer.") |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Path request failed: #{inspect(reason)}")}
    end
  end

  def handle_event("announce_tunnel", _params, socket) do
    case Sidecar.tunnel_announce() do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Tunnel destination announced.") |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Tunnel announce failed: #{inspect(reason)}")}

      other ->
        {:noreply, put_flash(socket, :error, "Tunnel announce failed: #{inspect(other)}")}
    end
  end

  defp assign_data(socket) do
    peers = Tunnel.list_peers()
    peer_refs = peers |> Enum.map(& &1.peer_ref) |> Enum.uniq()
    tunnel_ids = Enum.map(peers, & &1.tunnel_id)

    routing_notes =
      peer_refs
      |> Enum.filter(fn ref -> length(Tunnel.candidates(ref)) > 1 end)
      |> Map.new(fn ref -> {ref, Tunnel.routing_choice(ref)} end)

    peer_metrics =
      Map.new(peers, fn peer ->
        sighting = Sightings.latest_for_tunnel(peer.tunnel_id)
        {peer.id, %{sighting: sighting, score: Tunnel.score_peer(peer)}}
      end)

    preferred_ids =
      routing_notes
      |> Enum.map(fn {_ref, %{best: best}} -> best end)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.id, true})

    waiting = Outbox.list_waiting_by_tunnel(tunnel_ids)

    # Global DLQ: non-tunnel leftovers only (tunnel waiting shows under each peer).
    dlq =
      Outbox.list_failed(30)
      |> Enum.reject(&String.starts_with?(&1.channel || "", "tunnel:"))

    socket
    |> assign(:page_title, "Tunnels")
    |> assign(:peers, peers)
    |> assign(:tunnel_health, Tunnel.Engine.health())
    |> assign(:local_tunnel_dest, local_tunnel_destination())
    |> assign(:peer_metrics, peer_metrics)
    |> assign(:preferred_ids, preferred_ids)
    |> assign(:routing_notes, routing_notes)
    |> assign(:outbox_by_tunnel, waiting)
    |> assign(:tunnel_sightings, Sightings.list_recent_for_tunnels(20))
    |> assign(:outbox, Outbox.stats())
    |> assign(:dlq, dlq)
    |> assign(:governor, Governor.stats())
    |> assign(:drops, Governor.drops_summary(20))
    |> assign(:form, socket.assigns[:form] || to_form(Tunnel.change_peer(%Peer{})))
  end

  defp local_tunnel_destination do
    case Sidecar.health() do
      %{meta: meta} when is_map(meta) ->
        meta["tunnel_destination_hash"] || meta[:tunnel_destination_hash]

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # What the remote must enter as peer_ref for this carrier.
  defp assign_local_identity(socket) do
    assign(socket, :local_identity, LocalIdentity.for_network(socket.assigns.carrier))
  end

  defp clear_edit(socket) do
    socket
    |> assign(:editing_peer, nil)
    |> assign(:edit_form, nil)
    |> assign(:edit_pairing, "")
  end

  @impl true
  def render(assigns), do: TunnelsHTML.page(assigns)
end
