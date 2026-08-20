defmodule Isthmus.Networks.Firmware.Offer do
  @moduledoc "Match a catalog snapshot to a board + firmware kind."

  alias Isthmus.Networks.Firmware.Board
  alias Isthmus.Networks.Firmware.Version

  @type t :: %{
          version: String.t(),
          filename: String.t(),
          url: String.t(),
          html_url: String.t() | nil,
          source: atom()
        }

  @spec lookup(atom() | String.t() | nil, atom() | String.t() | nil, map() | nil) :: t() | nil
  def lookup(board_id, kind, snapshot) do
    board = Board.get(board_id)
    release = release_for(snapshot, kind)

    cond do
      is_nil(board) or is_nil(release) ->
        nil

      true ->
        match_asset(board, kind_atom(kind), release)
    end
  end

  @spec status(term(), t() | nil) :: Version.status()
  def status(running, %{version: latest}) do
    Version.compare(running, latest)
  end

  def status(_, _), do: :unknown

  @spec kind_release(map() | nil, atom() | String.t() | nil) :: map() | nil
  def kind_release(snapshot, kind), do: release_for(snapshot, kind)

  defp release_for(snapshot, kind) when is_map(snapshot) do
    case kind_atom(kind) do
      :companion -> snapshot[:companion]
      :island -> snapshot[:island]
      :meshtastic -> snapshot[:meshtastic]
      :rnode -> snapshot[:rnode]
      _ -> nil
    end
  end

  defp release_for(_, _), do: nil

  defp match_asset(board, kind, release) do
    regex = Board.asset_regex(board, kind)
    assets = List.wrap(release[:assets])

    cond do
      is_struct(regex, Regex) ->
        case Enum.find(assets, &Regex.match?(regex, &1[:name] || &1["name"] || "")) do
          %{name: name, url: url} = asset when url != "" ->
            build(release, asset_name(asset, name), url, kind)

          _ ->
            fallback_zip(board, kind, release)
        end

      true ->
        fallback_zip(board, kind, release)
    end
  end

  defp fallback_zip(_board, :meshtastic, release) do
    url = release[:zip_url] || zip_asset_url(release)

    if is_binary(url) and url != "" do
      build(release, Path.basename(url), url, :meshtastic)
    end
  end

  defp fallback_zip(_, _, _), do: nil

  defp zip_asset_url(release) do
    release
    |> Map.get(:assets, [])
    |> Enum.find_value(fn asset ->
      name = asset_name(asset, "")
      if String.ends_with?(name, ".zip"), do: asset[:url] || asset["url"]
    end)
  end

  defp build(release, filename, url, kind) do
    %{
      version: release[:version] || "",
      filename: filename,
      url: url,
      html_url: release[:html_url],
      source: kind
    }
  end

  defp asset_name(%{name: name}, _default) when is_binary(name), do: name
  defp asset_name(asset, default) when is_map(asset), do: asset["name"] || default
  defp asset_name(_, default), do: default

  defp kind_atom(kind) when kind in [:companion, :island, :meshtastic, :rnode], do: kind
  defp kind_atom("companion"), do: :companion
  defp kind_atom("island"), do: :island
  defp kind_atom("meshtastic"), do: :meshtastic
  defp kind_atom("rnode"), do: :rnode
  defp kind_atom(_), do: nil
end
