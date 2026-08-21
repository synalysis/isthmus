defmodule IsthmusWeb.Admin.FirmwareOffer do
  @moduledoc false
  use IsthmusWeb, :html

  alias Isthmus.Networks.Firmware.Board
  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.Firmware.Flasher
  alias Isthmus.Networks.Firmware.Image
  alias Isthmus.Networks.Firmware.Offer
  alias IsthmusWeb.Admin.UsbRole

  @flash_topic "firmware:flash"

  def mount_assigns(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, @flash_topic)
    end

    socket
    |> Phoenix.Component.assign(:firmware_catalog, Catalog.peek())
    |> Phoenix.Component.assign(:firmware_catalog_loading, false)
    |> Phoenix.Component.assign(:firmware_flash, Flasher.status())
    |> Phoenix.Component.assign(:board_by_device, %{})
    |> Phoenix.Component.assign(:kind_by_device, %{})
    |> maybe_schedule_refresh()
  end

  def handle_flash_progress(socket, job) do
    Phoenix.Component.assign(socket, :firmware_flash, job)
  end

  def start_install(socket, params) when is_map(params) do
    id = params["device_id"] || params["device-id"] || params[:device_id]
    device = find_device(socket, id)
    board = board_id(device, socket.assigns[:board_by_device])

    kind =
      kind_atom(params["kind"] || params[:kind]) ||
        flash_kind(device, socket.assigns[:kind_by_device])

    path = serial_path(device) || params["path"] || params[:path]

    if is_map(device) and kind not in [nil, :ignore] do
      _ = UsbRole.save_firmware(device, kind)
    end

    case Flasher.install(%{
           device_id: id,
           path: path,
           board_id: board,
           kind: kind,
           catalog: socket.assigns[:firmware_catalog]
         }) do
      {:ok, job} ->
        socket
        |> Phoenix.Component.assign(:firmware_flash, job)
        |> Phoenix.LiveView.put_flash(
          :info,
          "Installing #{job.filename || "firmware"} — the radio will disconnect."
        )

      {:error, :busy} ->
        Phoenix.LiveView.put_flash(socket, :error, "A firmware install is already running.")

      {:error, :ble_not_supported} ->
        Phoenix.LiveView.put_flash(
          socket,
          :error,
          "USB flash only — Bluetooth radios stay download-only."
        )

      {:error, :not_installable} ->
        Phoenix.LiveView.put_flash(
          socket,
          :error,
          "No flashable image for this board and firmware."
        )

      {:error, reason} ->
        Phoenix.LiveView.put_flash(socket, :error, "Could not start install: #{inspect(reason)}")
    end
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

  def pick_kind(socket, device_id, kind) do
    kinds = socket.assigns[:kind_by_device] || %{}
    Phoenix.Component.assign(socket, :kind_by_device, Map.put(kinds, device_id, kind_atom(kind)))
  end

  def flash_kind(device, overrides) when is_map(device) do
    id = device[:id] || device[:path]
    overridden = is_map(overrides) && Map.get(overrides, id)
    kind_atom(overridden) || kind_for(device)
  end

  def flash_kind(_, _), do: nil

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
  attr :running_kind, :atom, default: nil
  attr :board_id, :atom, default: nil
  attr :running_version, :string, default: nil
  attr :connected, :boolean, default: false
  attr :catalog, :map, required: true
  attr :source, :atom, default: nil
  attr :flash_job, :map, default: nil

  def usb_firmware_offer(assigns) do
    running_kind = assigns.running_kind || assigns.kind
    replacing? = replacing_firmware?(running_kind, assigns.kind)
    offer = Offer.lookup(assigns.board_id, assigns.kind, assigns.catalog)
    status = Offer.status(assigns.running_version, offer)
    release = Offer.kind_release(assigns.catalog, assigns.kind)
    installable? = Image.installable?(assigns.board_id, assigns.kind, offer)
    flash = flash_for(assigns.flash_job, assigns.device_id)

    assigns =
      assigns
      |> assign(:running_kind, running_kind)
      |> assign(:replacing?, replacing?)
      |> assign(:offer, offer)
      |> assign(:status, status)
      |> assign(:release, release)
      |> assign(:installable?, installable?)
      |> assign(:flash, flash)
      |> assign(:board_options, Board.options())
      |> assign(:board_value, board_value(assigns.board_id))
      |> assign(:kind_value, board_value(assigns.kind))
      |> assign(:kind_options, UsbRole.flash_kind_options())

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

      <details
        id={"#{@id}-write"}
        class="rounded-lg border border-base-300/60 px-3 py-2"
        open={@replacing?}
      >
        <summary class="cursor-pointer text-sm font-medium">Write firmware</summary>
        <p class="mt-1 text-xs opacity-70">
          Optional. Leave this closed to keep using the radio as it is.
        </p>

        <form
          :if={@source != :env}
          id={"#{@id}-kind"}
          phx-change="pick_usb_firmware"
          class="mt-2 flex flex-nowrap items-center gap-2 [&_.fieldset]:contents [&_label]:contents"
        >
          <input type="hidden" name="device_id" value={@device_id} />
          <span class="label w-24 shrink-0 px-0">Flash as</span>
          <.input
            id={"#{@id}-kind-select"}
            name="kind"
            type="select"
            prompt="Firmware to write…"
            options={@kind_options}
            value={@kind_value}
            class="select select-sm h-8 min-h-8 w-56"
          />
        </form>

        <%= cond do %>
          <% is_nil(@kind) -> %>
            <p class="mt-2 text-xs opacity-70" id={"#{@id}-hint"}>
              Choose firmware, then press Flash to write it.
            </p>
          <% is_nil(@board_id) -> %>
            <p class="mt-2 text-xs opacity-70" id={"#{@id}-hint"}>
              Choose the board to match a firmware file.
            </p>
          <% @kind == :island and is_nil(@release) -> %>
            <p class="mt-2 text-xs opacity-70" id={"#{@id}-hint"}>
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
            <p class="mt-2 text-xs opacity-70" id={"#{@id}-hint"}>
              No official image for this board in the latest catalog.
            </p>
          <% @replacing? -> %>
            <p class="mt-2 text-sm" id={"#{@id}-status"}>
              Running {kind_label(@running_kind)}{running_version_suffix(@running_version)}.
              Flash {kind_label(@kind)} {@offer.version} to replace it.
              <.firmware_actions
                id={@id}
                device_id={@device_id}
                kind={@kind}
                offer={@offer}
                replacing?={true}
                installable?={@installable?}
                flash={@flash}
              />
            </p>
          <% @connected and @status == :newer_available -> %>
            <p class="mt-2 text-sm" id={"#{@id}-status"}>
              Running {@running_version} — latest is {@offer.version}.
              <.firmware_actions
                id={@id}
                device_id={@device_id}
                kind={@kind}
                offer={@offer}
                replacing?={false}
                installable?={@installable?}
                flash={@flash}
              />
            </p>
          <% @connected and @status == :current -> %>
            <p class="mt-2 text-xs opacity-70" id={"#{@id}-status"}>
              Up to date ({@offer.version}).
              <.firmware_actions
                id={@id}
                device_id={@device_id}
                kind={@kind}
                offer={@offer}
                replacing?={false}
                installable?={@installable?}
                flash={@flash}
              />
            </p>
          <% true -> %>
            <p class="mt-2 text-sm" id={"#{@id}-status"}>
              Latest {kind_label(@kind)} — {@offer.version}.
              <.firmware_actions
                id={@id}
                device_id={@device_id}
                kind={@kind}
                offer={@offer}
                replacing?={false}
                installable?={@installable?}
                flash={@flash}
              />
            </p>
        <% end %>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :device_id, :string, required: true
  attr :kind, :atom, required: true
  attr :offer, :map, required: true
  attr :replacing?, :boolean, default: false
  attr :installable?, :boolean, required: true
  attr :flash, :map, default: nil

  defp firmware_actions(assigns) do
    assigns =
      assign(
        assigns,
        :flash_label,
        flash_button_label(assigns.replacing?, assigns.kind, assigns.offer.version)
      )

    ~H"""
    <span class="inline-flex flex-wrap items-center gap-x-3 gap-y-1">
      <a
        id={"#{@id}-download"}
        href={@offer.url}
        class="link"
        target="_blank"
        rel="noreferrer"
      >
        Download {@offer.filename}
      </a>
      <%= cond do %>
        <% @flash && @flash.phase == :error -> %>
          <span id={"#{@id}-progress"} class="text-xs text-error">
            {flash_error_label(@flash[:error])}
          </span>
          <button
            :if={@installable?}
            id={"#{@id}-install"}
            type="button"
            class="btn btn-primary btn-xs h-7 min-h-7"
            phx-click="install_firmware"
            phx-value-device-id={@device_id}
            phx-value-kind={@kind}
            data-confirm={"Write #{kind_label(@kind)} #{@offer.filename} (#{@offer.version}) to this radio? The USB link will disconnect."}
          >
            Retry {@flash_label}
          </button>
        <% @flash && @flash.phase not in [:done, :error] -> %>
          <span id={"#{@id}-progress"} class="text-xs opacity-70">
            {flash_phase_label(@flash.phase)}
          </span>
        <% true -> %>
          <button
            :if={@installable?}
            id={"#{@id}-install"}
            type="button"
            class="btn btn-primary btn-xs h-7 min-h-7"
            phx-click="install_firmware"
            phx-value-device-id={@device_id}
            phx-value-kind={@kind}
            data-confirm={"Write #{kind_label(@kind)} #{@offer.filename} (#{@offer.version}) to this radio? The USB link will disconnect."}
          >
            {@flash_label}
          </button>
      <% end %>
    </span>
    """
  end

  defp kind_for(device) when is_map(device) do
    UsbRole.firmware_kind(device) ||
      if(device[:kind] == :rnode, do: :rnode)
  end

  defp kind_for(_), do: nil

  defp kind_atom(kind) when kind in [:companion, :island, :meshtastic, :rnode, :ignore], do: kind
  defp kind_atom("companion"), do: :companion
  defp kind_atom("island"), do: :island
  defp kind_atom("meshtastic"), do: :meshtastic
  defp kind_atom("rnode"), do: :rnode
  defp kind_atom("ignore"), do: :ignore
  defp kind_atom(_), do: nil

  defp replacing_firmware?(running, target)
       when is_atom(running) and is_atom(target) and running != nil and target != nil and
              running != target and target != :ignore,
       do: true

  defp replacing_firmware?(_, _), do: false

  defp flash_button_label(true, kind, version), do: "Flash #{kind_label(kind)} #{version}"
  defp flash_button_label(false, _kind, version), do: "Install #{version}"

  defp running_version_suffix(version) when is_binary(version) and version != "",
    do: " " <> version

  defp running_version_suffix(_), do: ""

  defp find_device(socket, id) do
    devices = List.wrap(socket.assigns[:devices])
    rnodes = List.wrap(socket.assigns[:detected_rnodes])

    Enum.find(devices, &device_id?(&1, id)) ||
      case Enum.find(rnodes, &device_id?(&1, id)) do
        nil -> nil
        rnode -> Map.put(rnode, :kind, :rnode)
      end
  end

  defp device_id?(device, id) when is_map(device) and is_binary(id) do
    device[:id] == id or device[:path] == id
  end

  defp device_id?(_, _), do: false

  defp serial_path(device) when is_map(device) do
    cond do
      is_binary(device[:path]) and device[:path] != "" and
          not String.starts_with?(device[:path], "ble:") ->
        device[:path]

      true ->
        device
        |> Map.get(:ports, [])
        |> Enum.find_value(fn port ->
          path = port[:path]
          if is_binary(path) and path != "" and not String.starts_with?(path, "ble:"), do: path
        end)
    end
  end

  defp serial_path(_), do: nil

  defp flash_for(%{device_id: id} = job, device_id) when id == device_id, do: job
  defp flash_for(%{path: path} = job, device_id) when path == device_id, do: job
  defp flash_for(_, _), do: nil

  defp flash_phase_label(:queued), do: "Starting…"
  defp flash_phase_label(:holding), do: "Releasing USB…"
  defp flash_phase_label(:downloading), do: "Downloading…"
  defp flash_phase_label(:writing), do: "Writing…"
  defp flash_phase_label(:waiting_volume), do: "Waiting for bootloader volume…"
  defp flash_phase_label(:copying), do: "Copying firmware…"
  defp flash_phase_label(:waiting), do: "Waiting for reboot…"
  defp flash_phase_label(_), do: "Installing…"

  defp flash_error_label(:uf2_volume_timeout),
    do: "Bootloader volume not found. Double-tap reset and retry."

  defp flash_error_label(:uf2_copy_timeout), do: "Copy to the bootloader volume timed out."
  defp flash_error_label({:uf2_copy, reason}), do: "Copy failed (#{inspect(reason)})."

  defp flash_error_label(reason) when not is_nil(reason),
    do: "Install failed (#{inspect(reason)})."

  defp flash_error_label(_), do: "Install failed."

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
