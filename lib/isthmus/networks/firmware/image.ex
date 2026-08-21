defmodule Isthmus.Networks.Firmware.Image do
  @moduledoc false

  alias Isthmus.Networks.Firmware.Board

  @skip ~r/(update|bleota|littlefs)/i

  @spec pick_member([String.t()], atom() | map() | nil, atom()) :: String.t() | nil
  def pick_member(names, board_id, kind) when is_list(names) do
    board = Board.get(board_id) || if(is_map(board_id), do: board_id)
    regex = Board.asset_regex(board, kind)
    programmer = Board.programmer(board)

    names
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&match_name?(&1, regex))
    |> Enum.reject(&skip_name?/1)
    |> Enum.sort_by(&rank(&1, programmer))
    |> List.first()
  end

  def pick_member(_, _, _), do: nil

  @spec extract_zip(Path.t(), Path.t(), atom() | map() | nil, atom()) ::
          {:ok, Path.t()} | {:error, term()}
  def extract_zip(zip_path, dest_dir, board_id, kind)
      when is_binary(zip_path) and is_binary(dest_dir) do
    with {:ok, names} <- zip_names(zip_path),
         member when is_binary(member) <- pick_member(names, board_id, kind) || :nomatch do
      File.mkdir_p!(dest_dir)

      case :zip.extract(String.to_charlist(zip_path), [
             {:cwd, String.to_charlist(dest_dir)},
             {:file_list, [String.to_charlist(member)]}
           ]) do
        {:ok, _} ->
          {:ok, Path.join(dest_dir, member)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :nomatch -> {:error, :no_matching_image}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_image(Path.t(), Path.t(), atom() | map() | nil, atom()) ::
          {:ok, Path.t()} | {:error, term()}
  def resolve_image(downloaded, work_dir, board_id, kind)
      when is_binary(downloaded) and is_binary(work_dir) do
    cond do
      zip?(downloaded) ->
        extract_zip(downloaded, work_dir, board_id, kind)

      File.regular?(downloaded) ->
        {:ok, downloaded}

      true ->
        {:error, :missing_image}
    end
  end

  @spec flash_offset(atom(), String.t() | nil) :: non_neg_integer()
  def flash_offset(:meshtastic, _), do: 0x10000
  def flash_offset(_, _), do: 0x0

  @spec installable?(atom() | String.t() | nil, atom() | nil, map() | nil) :: boolean()
  def installable?(board_id, kind, offer) when is_map(offer) do
    kind in [:companion, :island, :meshtastic, :rnode] and
      Board.programmer(board_id) in [:esptool, :uf2] and
      is_binary(offer[:url]) and offer[:url] != ""
  end

  def installable?(_, _, _), do: false

  defp match_name?(name, %Regex{} = regex), do: Regex.match?(regex, name)
  defp match_name?(_, _), do: false

  defp skip_name?(name), do: Regex.match?(@skip, name)

  defp rank(name, :uf2) do
    cond do
      String.ends_with?(name, ".uf2") -> 0
      String.ends_with?(name, ".bin") -> 1
      true -> 2
    end
  end

  defp rank(name, _) do
    cond do
      String.ends_with?(name, "-merged.bin") -> 0
      String.ends_with?(name, ".bin") -> 1
      String.ends_with?(name, ".uf2") -> 2
      true -> 3
    end
  end

  defp zip?(path) do
    String.ends_with?(String.downcase(path), ".zip") or zip_magic?(path)
  end

  defp zip_magic?(path) do
    case File.open(path, [:read], fn io -> IO.binread(io, 2) end) do
      {:ok, "PK"} -> true
      _ -> false
    end
  end

  defp zip_names(path) do
    case :zip.table(String.to_charlist(path)) do
      {:ok, entries} ->
        names =
          for {:zip_file, name, _info, _, _, _} <- entries,
              do: List.to_string(name)

        {:ok, names}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
