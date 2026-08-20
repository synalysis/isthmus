defmodule Isthmus.Networks.Firmware.Catalog do
  @moduledoc """
  Cached latest-firmware snapshot (GitHub). Does not fetch on boot.
  """
  use GenServer

  alias Isthmus.Networks.Firmware.GitHub

  @default_ttl_ms 6 * 60 * 60 * 1000

  @type asset :: %{name: String.t(), url: String.t()}
  @type release :: %{
          optional(:version) => String.t(),
          optional(:html_url) => String.t(),
          optional(:zip_url) => String.t(),
          optional(:assets) => [asset()]
        }

  @type snapshot :: %{
          fetched_at: DateTime.t() | nil,
          error: String.t() | nil,
          companion: release() | nil,
          island: release() | nil,
          meshtastic: release() | nil,
          rnode: release() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec peek(GenServer.server()) :: snapshot()
  def peek(name \\ __MODULE__) do
    GenServer.call(name, :peek)
  rescue
    _ -> empty_snapshot()
  catch
    :exit, _ -> empty_snapshot()
  end

  @spec refresh(GenServer.server()) :: {:ok, snapshot()} | {:error, term()}
  def refresh(name \\ __MODULE__) do
    GenServer.call(name, :refresh, 30_000)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec put_snapshot(snapshot(), GenServer.server()) :: :ok
  def put_snapshot(snapshot, name \\ __MODULE__) when is_map(snapshot) do
    GenServer.call(name, {:put, snapshot})
  end

  @spec empty_snapshot() :: snapshot()
  def empty_snapshot do
    %{
      fetched_at: nil,
      error: nil,
      companion: nil,
      island: nil,
      meshtastic: nil,
      rnode: nil
    }
  end

  @doc false
  def snapshot_from_github(payloads) when is_map(payloads) do
    companion = payloads["companion"] || payloads[:companion]
    island = payloads["island"] || payloads[:island]
    meshtastic = payloads["meshtastic"] || payloads[:meshtastic]
    rnode = payloads["rnode"] || payloads[:rnode]

    %{
      fetched_at: payloads[:fetched_at] || ~U[2026-08-14 13:32:00Z],
      error: nil,
      companion: unwrap(companion_from_list(companion)),
      island: unwrap(island_from_list(island)),
      meshtastic: unwrap(meshtastic_from_map(meshtastic)),
      rnode: unwrap(rnode_from_map(rnode))
    }
  end

  @spec fixture_snapshot() :: snapshot()
  def fixture_snapshot do
    %{
      fetched_at: ~U[2026-08-14 13:32:00Z],
      error: nil,
      companion: %{
        version: "1.17.1",
        html_url: "https://github.com/meshcore-dev/MeshCore/releases/tag/companion-v1.17.1",
        assets: [
          %{
            name: "WioTrackerL1_companion_radio_usb-v1.17.1-d929643.uf2",
            url: "https://example.test/WioTrackerL1_companion_radio_usb-v1.17.1-d929643.uf2"
          },
          %{
            name: "Heltec_v3_companion_radio_usb-v1.17.1-d929643-merged.bin",
            url: "https://example.test/Heltec_v3_companion.bin"
          }
        ]
      },
      island: nil,
      meshtastic: %{
        version: "2.7.26.54e0d8d",
        html_url: "https://github.com/meshtastic/firmware/releases/tag/v2.7.26.54e0d8d",
        zip_url:
          "https://github.com/meshtastic/firmware/releases/download/v2.7.26.54e0d8d/firmware-2.7.26.54e0d8d.zip",
        assets: [
          %{
            name: "firmware-2.7.26.54e0d8d.zip",
            url:
              "https://github.com/meshtastic/firmware/releases/download/v2.7.26.54e0d8d/firmware-2.7.26.54e0d8d.zip"
          }
        ]
      },
      rnode: %{
        version: "1.86",
        html_url: "https://github.com/markqvist/RNode_Firmware/releases/tag/1.86",
        assets: [
          %{
            name: "rnode_firmware_heltec32v3.zip",
            url: "https://example.test/rnode_firmware_heltec32v3.zip"
          },
          %{
            name: "rnode_firmware_rak4631.zip",
            url: "https://example.test/rnode_firmware_rak4631.zip"
          }
        ]
      }
    }
  end

  @impl true
  def init(opts) do
    fetch = Keyword.get(opts, :fetch, configured_fetch())
    ttl_ms = Keyword.get(opts, :ttl_ms, configured_ttl())

    {:ok,
     %{
       snapshot: empty_snapshot(),
       fetch: fetch,
       ttl_ms: ttl_ms
     }}
  end

  @impl true
  def handle_call(:peek, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:refresh, _from, state) do
    case do_fetch(state.fetch) do
      {:ok, snapshot} ->
        {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}

      {:error, reason} = error ->
        snapshot = %{
          state.snapshot
          | error: inspect(reason),
            fetched_at: DateTime.utc_now()
        }

        {:reply, error, %{state | snapshot: snapshot}}
    end
  end

  def handle_call({:put, snapshot}, _from, state) do
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  def default_fetch do
    companion_task = Task.async(fn -> meshcore_role("meshcore-dev/MeshCore", "companion-v") end)
    island_task = Task.async(fn -> island_releases() end)
    meshtastic_task = Task.async(fn -> meshtastic_latest() end)
    rnode_task = Task.async(fn -> rnode_latest() end)

    companion = Task.await(companion_task, 20_000)
    island = Task.await(island_task, 20_000)
    meshtastic = Task.await(meshtastic_task, 20_000)
    rnode = Task.await(rnode_task, 20_000)

    errors =
      Enum.flat_map([companion, island, meshtastic, rnode], fn
        {:error, reason} -> [inspect(reason)]
        _ -> []
      end)

    {:ok,
     %{
       fetched_at: DateTime.utc_now(),
       error: if(errors == [], do: nil, else: Enum.join(errors, "; ")),
       companion: unwrap(companion),
       island: unwrap(island),
       meshtastic: unwrap(meshtastic),
       rnode: unwrap(rnode)
     }}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp unwrap({:ok, release}), do: release
  defp unwrap(_), do: nil

  defp meshcore_role(repo, prefix) do
    case GitHub.get("https://api.github.com/repos/#{repo}/releases?per_page=30") do
      {:ok, releases} when is_list(releases) ->
        companion_from_list(releases, prefix)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp island_releases do
    case GitHub.get("https://api.github.com/repos/synalysis/MeshCore/releases?per_page=20") do
      {:ok, releases} when is_list(releases) ->
        island_from_list(releases)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp meshtastic_latest do
    case GitHub.get("https://api.github.com/repos/meshtastic/firmware/releases/latest") do
      {:ok, %{} = release} -> meshtastic_from_map(release)
      {:error, reason} -> {:error, reason}
    end
  end

  defp rnode_latest do
    case GitHub.get("https://api.github.com/repos/markqvist/RNode_Firmware/releases/latest") do
      {:ok, %{} = release} -> rnode_from_map(release)
      {:error, reason} -> {:error, reason}
    end
  end

  defp companion_from_list(releases, prefix \\ "companion-v")

  defp companion_from_list(releases, prefix) when is_list(releases) do
    case newest_tag(releases, prefix) do
      nil -> {:ok, nil}
      release -> {:ok, to_release(release)}
    end
  end

  defp companion_from_list(_, _), do: {:ok, nil}

  defp island_from_list(releases) when is_list(releases) do
    release =
      newest_tag(releases, "bridge-") ||
        Enum.find(releases, &island_assets?(&1))

    {:ok, if(release, do: to_release(release))}
  end

  defp island_from_list(_), do: {:ok, nil}

  defp meshtastic_from_map(release) when is_map(release) do
    parsed = to_release(release)
    zip = Enum.find(parsed.assets, &String.ends_with?(&1.name, ".zip"))
    {:ok, Map.put(parsed, :zip_url, zip && zip.url)}
  end

  defp meshtastic_from_map(_), do: {:ok, nil}

  defp rnode_from_map(release) when is_map(release) do
    {:ok, to_release(release)}
  end

  defp rnode_from_map(_), do: {:ok, nil}

  defp newest_tag(releases, prefix) do
    releases
    |> Enum.filter(fn release ->
      tag = release["tag_name"] || release[:tag_name] || ""
      String.starts_with?(tag, prefix)
    end)
    |> Enum.sort_by(&published_at/1, {:desc, DateTime})
    |> List.first()
  end

  defp published_at(release) do
    raw = release["published_at"] || release["created_at"] || ""

    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> dt
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp island_assets?(release) do
    Enum.any?(assets(release), fn asset ->
      name = asset["name"] || ""
      String.contains?(String.downcase(name), "bridge_usbserial")
    end)
  end

  defp to_release(release) when is_map(release) do
    tag = release["tag_name"] || release[:tag_name] || ""

    %{
      version: normalize_tag(tag),
      html_url: release["html_url"] || release[:html_url],
      assets:
        Enum.map(assets(release), fn asset ->
          %{
            name: asset["name"] || asset[:name] || "",
            url: asset["browser_download_url"] || asset[:browser_download_url] || ""
          }
        end)
    }
  end

  defp assets(release) do
    case release["assets"] || release[:assets] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp normalize_tag(tag) when is_binary(tag) do
    tag
    |> String.replace_prefix("companion-v", "")
    |> String.replace_prefix("repeater-v", "")
    |> String.replace_prefix("room-server-v", "")
    |> String.replace_prefix("bridge-", "")
    |> String.replace_prefix("v", "")
  end

  defp normalize_tag(_), do: ""

  defp do_fetch(fetch) when is_function(fetch, 0) do
    case fetch.() do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      {:error, _} = error -> error
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      other -> {:error, {:invalid_fetch, other}}
    end
  end

  defp do_fetch(_), do: {:error, :invalid_fetch}

  defp configured_fetch do
    Application.get_env(:isthmus, __MODULE__, [])
    |> Keyword.get(:fetch, &__MODULE__.default_fetch/0)
  end

  defp configured_ttl do
    Application.get_env(:isthmus, __MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
