defmodule Isthmus.Networks.Firmware.Flasher do
  @moduledoc """
  One-at-a-time USB firmware write.

  Holds the serial path so Discover and companions do not reopen it (DTR reset)
  while esptool or a UF2 copy is running.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.Firmware.Board
  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.Firmware.Image
  alias Isthmus.Networks.Firmware.Offer
  alias Isthmus.Networks.Firmware.Writer.Esptool
  alias Isthmus.Networks.Firmware.Writer.Uf2
  alias Isthmus.Networks.MeshCore.BridgeCLI
  alias Isthmus.Networks.MeshCore.BridgeLink
  alias Isthmus.Networks.MeshCore.Companion, as: MeshCoreCompanion
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion

  @table :isthmus_firmware_flasher
  @topic "firmware:flash"

  @type job :: %{
          optional(:error) => term(),
          id: String.t(),
          device_id: String.t(),
          path: String.t(),
          board_id: atom(),
          kind: atom(),
          version: String.t() | nil,
          filename: String.t() | nil,
          url: String.t() | nil,
          programmer: :esptool | :uf2,
          offset: non_neg_integer(),
          image_path: String.t() | nil,
          phase: atom()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec held_paths() :: [String.t()]
  def held_paths do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> :ets.lookup_element(@table, :held, 2)
    end
  rescue
    _ -> []
  end

  @spec held?(term()) :: boolean()
  def held?(path) when is_binary(path) and path != "", do: path in held_paths()
  def held?(_), do: false

  @spec status() :: job() | nil
  def status do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ -> :ets.lookup_element(@table, :job, 2)
    end
  rescue
    _ -> nil
  end

  @spec install(map()) :: {:ok, job()} | {:error, term()}
  def install(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:install, attrs}, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    table =
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        existing -> existing
      end

    :ets.insert(table, {:held, []})
    :ets.insert(table, {:job, nil})

    {:ok,
     %{
       table: table,
       task: nil,
       download: Keyword.get(opts, :download, configured(:download) || (&default_download/2)),
       write: Keyword.get(opts, :write, configured(:write) || (&default_write/1)),
       disconnect:
         Keyword.get(opts, :disconnect, configured(:disconnect) || (&default_disconnect/1)),
       refresh: Keyword.get(opts, :refresh, configured(:refresh) || (&default_refresh/0)),
       work_dir: Keyword.get(opts, :work_dir, System.tmp_dir!())
     }}
  end

  @impl true
  def handle_call({:install, attrs}, _from, state) do
    cond do
      match?(%Task{}, state.task) ->
        {:reply, {:error, :busy}, state}

      match?(%{phase: phase} when phase not in [nil, :done, :error], status()) ->
        {:reply, {:error, :busy}, state}

      true ->
        case build_job(attrs) do
          {:ok, job} ->
            hold(job.path)
            persist_job(job)
            task = Task.async(fn -> run_job(job, state) end)
            {:reply, {:ok, job}, %{state | task: task}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish_job(result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    finish_job({:error, reason}, %{state | task: nil})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish_job(result, state) do
    job = status() || %{phase: :error, path: nil, error: result}

    job =
      case result do
        :ok -> broadcast(%{job | phase: :done, error: nil})
        {:error, reason} -> broadcast(%{job | phase: :error, error: reason})
      end

    persist_job(job)
    if is_binary(job[:path]), do: unhold(job.path)
    refresh = configured(:refresh) || state.refresh
    _ = refresh.()
    {:noreply, %{state | task: nil}}
  end

  defp build_job(attrs) do
    path = attrs[:path] || attrs["path"]
    device_id = attrs[:device_id] || attrs["device_id"] || path
    board_id = Board.get(attrs[:board_id] || attrs["board_id"])
    kind = kind_atom(attrs[:kind] || attrs["kind"])
    catalog = attrs[:catalog] || attrs["catalog"] || Catalog.peek()
    offer = attrs[:offer] || Offer.lookup(board_id && board_id.id, kind, catalog)
    programmer = Board.programmer(board_id)

    cond do
      is_binary(path) and String.starts_with?(path, "ble:") ->
        {:error, :ble_not_supported}

      not is_binary(path) or path == "" ->
        {:error, :missing_port}

      is_nil(board_id) ->
        {:error, :unknown_board}

      is_nil(kind) ->
        {:error, :unknown_kind}

      not Image.installable?(board_id.id, kind, offer) ->
        {:error, :not_installable}

      true ->
        {:ok,
         %{
           id: Ecto.UUID.generate(),
           device_id: to_string(device_id),
           path: path,
           board_id: board_id.id,
           kind: kind,
           version: offer[:version],
           filename: offer[:filename],
           url: offer[:url],
           programmer: programmer,
           offset: Image.flash_offset(kind, offer[:filename]),
           image_path: nil,
           phase: :queued,
           error: nil
         }}
    end
  end

  defp run_job(job, state) do
    work = Path.join(state.work_dir, "isthmus-fw-" <> job.id)
    File.mkdir_p!(work)
    download = configured(:download) || state.download
    write = configured(:write) || state.write
    disconnect = configured(:disconnect) || state.disconnect

    with :ok <- phase(job, :holding),
         :ok <- disconnect.(job.path),
         :ok <- phase(job, :downloading),
         {:ok, downloaded} <- download.(job.url, Path.join(work, job.filename || "image.bin")),
         :ok <- phase(job, :writing),
         {:ok, image} <-
           Image.resolve_image(downloaded, Path.join(work, "unpacked"), job.board_id, job.kind),
         job <- %{
           job
           | image_path: image,
             offset: Image.flash_offset(job.kind, Path.basename(image))
         },
         :ok <- persist_job(job),
         :ok <- write.(job),
         :ok <- phase(job, :waiting) do
      :ok
    end
  after
    # work dir is left for debugging failed flashes; tests use a tmp dir
    :ok
  end

  defp phase(job, name) do
    persist_job(broadcast(%{job | phase: name}))
    :ok
  end

  defp default_download(url, dest) when is_binary(url) and is_binary(dest) do
    File.mkdir_p!(Path.dirname(dest))

    case Req.get(url, decode_body: false, redirect: true, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        File.write!(dest, body)
        {:ok, dest}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_write(%{programmer: :esptool} = job), do: Esptool.write(job)

  defp default_write(%{programmer: :uf2} = job) do
    Uf2.write(Map.put(job, :on_phase, fn name -> phase(status() || job, name) end))
  end

  defp default_write(_), do: {:error, :unknown_programmer}

  defp default_disconnect(path) when is_binary(path) do
    _ = safe_disconnect(fn -> MeshtasticCompanion.disconnect(path) end)
    _ = safe_disconnect(fn -> MeshCoreCompanion.disconnect(path) end)

    if BridgeCLI.health()[:port] == path do
      _ = safe_disconnect(fn -> BridgeCLI.disconnect() end)
    end

    if BridgeLink.health()[:port] == path do
      _ = safe_disconnect(fn -> BridgeLink.disconnect() end)
    end

    :ok
  end

  defp default_refresh do
    case Discover.refresh() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("firmware flash rescan failed: #{inspect(reason)}")
    end

    :ok
  end

  defp safe_disconnect(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defp hold(path) when is_binary(path) do
    paths = Enum.uniq([path | held_paths()])
    :ets.insert(@table, {:held, paths})
    :ok
  end

  defp unhold(path) when is_binary(path) do
    :ets.insert(@table, {:held, List.delete(held_paths(), path)})
    :ok
  end

  defp persist_job(job) do
    :ets.insert(@table, {:job, job})
    :ok
  end

  defp broadcast(job) do
    Phoenix.PubSub.broadcast(Isthmus.PubSub, @topic, {:firmware_flash, job})
    job
  end

  defp kind_atom(kind) when kind in [:companion, :island, :meshtastic, :rnode], do: kind
  defp kind_atom("companion"), do: :companion
  defp kind_atom("island"), do: :island
  defp kind_atom("meshtastic"), do: :meshtastic
  defp kind_atom("rnode"), do: :rnode
  defp kind_atom(_), do: nil

  defp configured(key) do
    Application.get_env(:isthmus, __MODULE__, []) |> Keyword.get(key)
  end
end
