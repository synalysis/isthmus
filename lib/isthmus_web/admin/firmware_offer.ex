defmodule IsthmusWeb.Admin.FirmwareOffer do
  @moduledoc false
  use IsthmusWeb, :html

  alias Isthmus.Networks.Firmware.Board
  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.Firmware.Offer
  alias IsthmusWeb.Admin.UsbRole

  def mount_assigns(socket) do
    socket
    |> Phoenix.Component.assign(:firmware_catalog, Catalog.peek())
    |> Phoenix.Component.assign(:firmware_catalog_loading, false)
    |> Phoenix.Component.assign(:board_by_device, %{})
    |> maybe_schedule_refresh()
  end

  def maybe_schedule_refresh(socket) do
    if Phoenix.LiveView.connected?(socket) and empty_catalog?(socket.assigns.firmware_catalog) do
      send(self(), :refresh_firmware_catalog)

      Phoenix.Component.assign(socket, :firmware_catalog_loading, true)
    else
      socket
    end
  end

  def handle_refresh(socket) do
    case Catalog.refresh() do
      {:ok, snapshot} ->
        socket
        |> Phoenix.Component.assign(:firmware_catalog, snapshot)
        |> Phoenix.Component.assign(:firmware_catalog_loading, false)

      {:error, reason} ->
        socket
        |> Phoenix.Component.assign(:firmware_catalog_loading, false)
        |> Phoenix.LiveView.put_flash(:error, "Firmware list failed: #{inspect(reason)}")
    end
  end

  def pick_board(socket, device_id, board) do
    boards = socket.assigns[:board_by_device] || %{}
    Phoenix.Component.assign(socket, :board_by_device, Map.put(boards, device_id, board))
  end

  def board_id(device, overrides) when is_map(device) do
    id = device[:id] || device[:path]
    overridden = is_map(overrides) && Map.get(overrides, id)

    case Board.get(overridden) do
      %{id: board_id} -> board_id
      _ -> Board.guess(device)
    end
  end

  def board_id(_, _), do: nil

  def newer?(device, overrides, catalog) do
    kind = kind_for(device)
    board = board_id(device, overrides)
    offer = Offer.lookup(board, kind, catalog)
    connected?(device) and Offer.status(device[:firmware_version], offer) == :newer_available
  end

  attr :id, :string, required: true
  attr :device_id, :string, required: true
  attr :kind, :atom, default: nil
  attr :board_id, :atom, default: nil
  attr :running_version, :string, default: nil
  attr :connected, :boolean, default: false
  attr :catalog, :map, required: true
  attr :source, :atom, default: nil

  def usb_firmware_offer(assigns) do
    offer = Offer.lookup(assigns.board_id, assigns.kind, assigns.catalog)
    status = Offer.status(assigns.running_version, offer)
    release = Offer.kind_release(assigns.catalog, assigns.kind)

    assigns =
      assigns
      |> assign(:offer, offer)
      |> assign(:status, status)
      |> assign(:release, release)
      |> assign(:board_options, Board.options())
      |> assign(:board_value, board_value(assigns.board_id))

    ~H"""
    <div id={@id} class="space-y-2">
      <form
        :if={@source != :env}
        id={"#{@id}-board"}
        phx-submit="assign_usb_board"
        class="flex flex-nowrap items-center gap-2 [&_.fieldset]:contents [&_label]:contents"
      >
        <input type="hidden" name="device_id" value={@device_id} />
        <span class="label w-24 shrink-0 px-0">Board</span>
        <.input
          id={"#{@id}-board-select"}
          name="board"
          type="select"
          prompt="This hardware is…"
          options={@board_options}
          value={@board_value}
          class="select select-sm h-8 min-h-8 w-56"
        />
        <button
          class="btn btn-outline btn-sm h-8 min-h-8 shrink-0"
          id={"#{@id}-board-apply"}
          type="submit"
        >
          Apply
        </button>
      </form>

      <%= cond do %>
        <% is_nil(@kind) or @kind == :ignore -> %>
          <p class="text-xs opacity-70" id={"#{@id}-hint"}>
            Choose firmware to see the latest build.
          </p>
        <% is_nil(@board_id) -> %>
          <p class="text-xs opacity-70" id={"#{@id}-hint"}>
            Choose the board to match a firmware file.
          </p>
        <% @kind == :island and is_nil(@release) -> %>
          <p class="text-xs opacity-70" id={"#{@id}-hint"}>
            No published island-bridge build yet. Flash from the
            <a
              href="https://github.com/synalysis/MeshCore"
              class="link"
              target="_blank"
              rel="noreferrer"
            >
              synalysis/MeshCore
            </a>
            recipe (UF2 onto the bootloader volume).
          </p>
        <% is_nil(@offer) -> %>
          <p class="text-xs opacity-70" id={"#{@id}-hint"}>
            No official image for this board in the latest catalog.
          </p>
        <% @connected and @status == :newer_available -> %>
          <p class="text-sm" id={"#{@id}-status"}>
            Running {@running_version} — latest is {@offer.version}.
            <a
              id={"#{@id}-download"}
              href={@offer.url}
              class="link"
              target="_blank"
              rel="noreferrer"
            >
              Download {@offer.filename}
            </a>
          </p>
        <% @connected and @status == :current -> %>
          <p class="text-xs opacity-70" id={"#{@id}-status"}>
            Up to date ({@offer.version}).
          </p>
        <% true -> %>
          <p class="text-sm" id={"#{@id}-status"}>
            Latest {kind_label(@kind)} — {@offer.version}.
            <a
              id={"#{@id}-download"}
              href={@offer.url}
              class="link"
              target="_blank"
              rel="noreferrer"
            >
              Download {@offer.filename}
            </a>
          </p>
      <% end %>
    </div>
    """
  end

  defp kind_for(device) do
    UsbRole.firmware_kind(device) ||
      if(device[:kind] == :rnode, do: :rnode)
  end

  defp connected?(device) when is_map(device) do
    device[:active?] == true or device[:active_companion?] == true or
      device[:active_bridge_cli?] == true or device[:kind] == :rnode
  end

  defp empty_catalog?(catalog) when is_map(catalog) do
    is_nil(catalog[:fetched_at]) and is_nil(catalog[:companion]) and
      is_nil(catalog[:meshtastic]) and is_nil(catalog[:rnode])
  end

  defp empty_catalog?(_), do: true

  defp board_value(id) when is_atom(id) and id != nil, do: Atom.to_string(id)
  defp board_value(id) when is_binary(id), do: id
  defp board_value(_), do: ""

  defp kind_label(:companion), do: "MeshCore companion"
  defp kind_label(:island), do: "island tunnel radio"
  defp kind_label(:meshtastic), do: "Meshtastic"
  defp kind_label(:rnode), do: "RNode"
  defp kind_label(_), do: "firmware"
end
