defmodule IsthmusWeb.Admin.RegistrationsLive do
  use IsthmusWeb, :live_view

  alias IsthmusWeb.Admin.RegistrationsHTML

  alias Isthmus.Announce.KnownAddresses
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Translator
  alias Isthmus.Registrations

  @default_attach_network "meshcore"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Groups")
     |> assign(:modal, nil)
     |> assign(:show_revoked, false)
     |> assign(:bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:attach_form, to_form(%{"group_id" => "", "network" => "nostr", "identity" => ""}))
     |> assign(:inject_form, to_form(%{"group_id" => "", "body" => ""}))
     |> assign(:attach_network, "nostr")
     |> assign(:attach_group_id, nil)
     |> assign(:attach_group_name, nil)
     |> assign(:identity_suggestions, [])
     |> assign(:filtered_suggestions, [])
     |> assign(:selected_bridge_id, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("toggle_show_revoked", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_revoked, !socket.assigns.show_revoked)
     |> refresh()}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)
    {:ok, _} = Registrations.revoke(group)

    {:noreply,
     socket
     |> put_flash(:info, "Revoked.")
     |> refresh()}
  end

  def handle_event("announce", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.announce_group(group) do
      {:ok, results} ->
        msg =
          results
          |> Enum.map(fn
            {net, :ok} -> "#{net}: ok"
            {net, {:error, reason}} -> "#{net}: #{inspect(reason)}"
          end)
          |> Enum.join("; ")

        {:noreply,
         socket
         |> put_flash(:info, "Announce — #{msg}")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Announce failed: #{inspect(reason)}")}
    end
  end

  def handle_event("announce_leg", %{"group_id" => gid, "leg_id" => leg_id}, socket) do
    group = Registrations.get_group!(gid)
    leg = Enum.find(group.legs, &(&1.id == leg_id))

    case leg && Registrations.announce_leg(leg) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Announced on #{leg.network}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Announce failed: #{inspect(reason)}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Leg not found.")}
    end
  end

  def handle_event("ensure_bridge_proxy", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.ensure_bridge_rns_proxy(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Bridge RNS proxy minted.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mint failed: #{inspect(reason)}")}
    end
  end

  def handle_event("ensure_nostr_proxy", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.ensure_nostr_proxy(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nostr proxy minted.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mint failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create_bridge", %{"display_name" => name}, socket) do
    owner = socket.assigns.current_user.pubkey_hex

    case Registrations.create_bridge_group(owner, %{
           display_name: String.trim(name),
           created_by: "admin"
         }) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Bridge group created.")
         |> assign(:selected_bridge_id, group.id)
         |> assign(:bridge_form, to_form(%{"display_name" => ""}))
         |> assign(:modal, :manage)
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create: #{inspect(reason)}")}
    end
  end

  def handle_event("select_bridge", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_bridge_id, id) |> assign(:modal, :manage) |> refresh()}
  end

  def handle_event("open_new_group", _params, socket) do
    {:noreply,
     socket
     |> assign(:bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:modal, :new_group)}
  end

  def handle_event("open_attach", %{"id" => id}, socket) do
    group = Enum.find(socket.assigns.groups, &(&1.id == id))
    network = @default_attach_network
    suggestions = KnownAddresses.for_network(network)

    {:noreply,
     socket
     |> assign(:attach_group_id, id)
     |> assign(:attach_group_name, group && group.display_name)
     |> assign(:attach_network, network)
     |> assign(:identity_suggestions, suggestions)
     |> assign(:filtered_suggestions, filter_suggestions(suggestions, "", network))
     |> assign(
       :attach_form,
       to_form(%{"group_id" => id, "network" => network, "identity" => ""})
     )
     |> assign(:modal, :attach)}
  end

  def handle_event("open_inject", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_bridge_id, id)
     |> assign(:inject_form, to_form(%{"group_id" => id, "body" => ""}))
     |> assign(:modal, :inject)
     |> refresh()}
  end

  def handle_event("close_modal", _params, socket) do
    next_modal =
      if socket.assigns.modal in [:attach, :inject] and socket.assigns.selected_bridge do
        :manage
      else
        nil
      end

    {:noreply, assign(socket, :modal, next_modal)}
  end

  # Refresh address suggestions when the target network changes; suggestions are
  # recomputed only on an actual network switch, and filtered as the admin types.
  def handle_event("attach_form_changed", params, socket) do
    network = params["network"] || socket.assigns.attach_network
    identity = params["identity"] || ""
    network_changed? = network != socket.assigns.attach_network

    suggestions =
      if network_changed?,
        do: KnownAddresses.for_network(network),
        else: socket.assigns.identity_suggestions

    {:noreply,
     socket
     |> assign(:attach_network, network)
     |> assign(:identity_suggestions, suggestions)
     |> assign(:filtered_suggestions, filter_suggestions(suggestions, identity, network))
     |> assign(
       :attach_form,
       to_form(%{
         "group_id" => socket.assigns.attach_group_id,
         "network" => network,
         "identity" => identity
       })
     )}
  end

  def handle_event("pick_suggestion", %{"ref" => ref}, socket) do
    network = socket.assigns.attach_network
    display_ref = format_identity_ref(network, ref)

    {:noreply,
     socket
     |> assign(
       :filtered_suggestions,
       filter_suggestions(socket.assigns.identity_suggestions, display_ref, network)
     )
     |> assign(
       :attach_form,
       to_form(%{
         "group_id" => socket.assigns.attach_group_id,
         "network" => network,
         "identity" => display_ref
       })
     )}
  end

  def handle_event("inject_message", params, socket) do
    body = params |> Map.get("body", "") |> to_string() |> String.trim()
    group_id = params["group_id"] || socket.assigns.selected_bridge_id

    cond do
      body == "" ->
        {:noreply,
         socket
         |> put_flash(:error, "Message is empty.")
         |> assign(:inject_form, to_form(%{"group_id" => group_id, "body" => ""}))}

      true ->
        case Registrations.get_group(group_id) do
          %{status: "active"} = group ->
            Translator.ingest(%Message{
              from_network: :admin,
              from_ref: "admin",
              body: body,
              group_id: group.id,
              external_id: "ui-#{System.unique_integer([:positive])}",
              meta: %{"injected_by" => "admin"}
            })

            {:noreply,
             socket
             |> put_flash(:info, "Sent to #{group.display_name}.")
             |> assign(:inject_form, to_form(%{"group_id" => group.id, "body" => ""}))
             |> assign(:selected_bridge_id, group.id)
             |> refresh()}

          _ ->
            {:noreply, put_flash(socket, :error, "Group is not active.")}
        end
    end
  end

  def handle_event("attach_member", params, socket) do
    group = Registrations.get_group!(params["group_id"])

    case Registrations.attach_member(
           group,
           params["network"],
           String.trim(params["identity"] || "")
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Member attached.")
         |> assign(:selected_bridge_id, group.id)
         |> assign(:modal, :manage)
         |> refresh()}

      {:error, :identity_already_linked} ->
        {:noreply, put_flash(socket, :error, "Identity already linked to another group.")}

      {:error, :not_a_bridge_group} ->
        {:noreply, put_flash(socket, :error, "Not a group that can attach members.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, attach_changeset_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach failed: #{inspect(reason)}")}
    end
  end

  def handle_event("detach_member", %{"leg_id" => leg_id, "group_id" => group_id}, socket) do
    group = Registrations.get_group!(group_id)
    leg = Enum.find(group.legs, &(&1.id == leg_id))

    case leg && Registrations.detach_member(leg) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Member detached.") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Detach failed: #{inspect(reason)}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Leg not found.")}
    end
  end

  def handle_event(
        "unlink_channel",
        %{"network" => network, "group_id" => group_id} = params,
        socket
      )
      when network in ["meshcore", "meshtastic"] do
    label = if network == "meshcore", do: "MeshCore", else: "Meshtastic"
    device_id = params["device_id"]
    unlink_fun = unlink_fun(network)

    unlink_radio_channel(socket, group_id, unlink_fun, label, device_id)
  end

  defp unlink_fun("meshcore"), do: &Registrations.unlink_meshcore_channel/2
  defp unlink_fun("meshtastic"), do: &Registrations.unlink_meshtastic_channel/2

  defp refresh(socket) do
    all_groups = Registrations.list_all()
    revoked_count = Enum.count(all_groups, &(&1.status == "revoked"))

    groups =
      if socket.assigns.show_revoked do
        all_groups
      else
        Enum.reject(all_groups, &(&1.status == "revoked"))
      end

    bridges = Enum.filter(all_groups, &(&1.kind == "bridge" and &1.status == "active"))
    selected = Enum.find(bridges, &same_id?(&1.id, socket.assigns.selected_bridge_id))

    socket =
      socket
      |> assign(:groups, groups)
      |> assign(:revoked_count, revoked_count)
      |> assign(:bridges, bridges)
      |> assign(:selected_bridge, selected)
      |> assign(:selected_bridge_id, selected && selected.id)

    if socket.assigns.modal in [:manage, :inject] and is_nil(selected) do
      assign(socket, :modal, nil)
    else
      socket
    end
  end

  defp same_id?(a, b), do: to_string(a || "") == to_string(b || "") and to_string(a || "") != ""

  @suggestion_limit 20

  # Filter recently-heard addresses by the typed query (matches name or ref),
  # so the combobox narrows as the admin types. Empty query shows the newest.
  defp filter_suggestions(suggestions, query, network) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    suggestions
    |> Enum.filter(fn s ->
      display =
        format_identity_ref(network, s.ref)
        |> to_string()
        |> String.downcase()

      q == "" or
        String.contains?(String.downcase(to_string(s.ref)), q) or
        String.contains?(display, q) or
        (is_binary(s.name) and String.contains?(String.downcase(s.name), q))
    end)
    |> Enum.take(@suggestion_limit)
  end

  defp attach_changeset_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :network) or
         Keyword.has_key?(changeset.errors, :identity_ref) do
      "Identity already linked to another group."
    else
      "Attach failed: #{inspect(changeset.errors)}"
    end
  end

  defp unlink_radio_channel(socket, group_id, unlink_fun, label, device_id) do
    group = Registrations.get_group!(group_id)
    opts = if device_id in [nil, ""], do: [], else: [device_id: device_id]

    {:ok, _} = unlink_fun.(group, opts)

    {:noreply,
     socket
     |> put_flash(:info, "#{label} channel unlinked.")
     |> refresh()}
  end

  @impl true
  def render(assigns), do: RegistrationsHTML.page(assigns)
end
