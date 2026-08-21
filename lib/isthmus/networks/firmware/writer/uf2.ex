defmodule Isthmus.Networks.Firmware.Writer.Uf2 do
  @moduledoc false

  require Logger

  @boot_baud 1_200
  @poll_ms 250
  @default_timeout_ms 60_000
  @touch_timeout_ms 3_000
  @marker_timeout_ms 800
  @fat_fs ~w(vfat msdos msdosfs exfat fuseblk)
  @label_hints ~w(uf2 nrf52 nrf52840 wio tracker wtl1 seeed rak4631 t114 xiao sensecap adafruit nicenano)
  @transient_copy [:eio, :enospc, :enoent, :enodev, :eacces]

  @spec write(map()) :: :ok | {:error, term()}
  def write(%{path: path, image_path: image} = job)
      when is_binary(path) and is_binary(image) do
    timeout = job[:timeout_ms] || @default_timeout_ms
    mounts = job[:mounts] || (&fat_mount_paths/0)
    volumes = job[:volumes] || (&list_uf2_volumes/0)
    copy = job[:copy] || (&File.cp/2)
    on_phase = job[:on_phase] || fn _ -> :ok end
    before = mounts.()

    with :ok <- touch_bootloader(path, job[:touch] || (&default_touch/1)),
         :ok <- on_phase.(:waiting_volume),
         {:ok, dest} <- wait_volume(before, mounts, volumes, timeout) do
      Logger.info("UF2 volume #{dest}")
      gone? = fn -> gone?(dest, mounts, volumes) end

      with :ok <- on_phase.(:copying),
           :ok <- copy_uf2(image, dest, copy, timeout, gone?) do
        _ = wait_volume_gone(dest, mounts, volumes, timeout)
        :ok
      end
    end
  end

  def write(_), do: {:error, :invalid_flash_job}

  @doc false
  def list_uf2_volumes do
    (fat_mount_paths() ++ media_dirs())
    |> Enum.uniq()
    |> Enum.filter(&uf2_label?(Path.basename(&1)))
  end

  @doc false
  def fat_mount_paths(source \\ "/proc/mounts") do
    case File.read(source) do
      {:ok, body} ->
        body
        |> parse_mounts()
        |> Enum.filter(&(&1.fstype in @fat_fs))
        |> Enum.map(& &1.path)

      _ ->
        []
    end
  end

  @doc false
  def parse_mounts(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ") do
        [_spec, path, fstype | _] ->
          [%{path: unescape_mount(path), fstype: fstype}]

        _ ->
          []
      end
    end)
  end

  @doc false
  def uf2_label?(name) when is_binary(name) do
    down = String.downcase(name)
    Enum.any?(@label_hints, &String.contains?(down, &1))
  end

  def uf2_label?(_), do: false

  defp media_dirs do
    ["/run/media", "/media"]
    |> Enum.flat_map(&volume_roots/1)
  end

  defp volume_roots(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          path = Path.join(root, name)

          cond do
            uf2_label?(name) ->
              [path]

            true ->
              case File.ls(path) do
                {:ok, inner} ->
                  for child <- inner, uf2_label?(child), do: Path.join(path, child)

                _ ->
                  []
              end
          end
        end)

      _ ->
        []
    end
  end

  defp touch_bootloader(path, fun) when is_function(fun, 1) do
    case timed(fn -> fun.(path) end, @touch_timeout_ms) do
      :ok -> :ok
      {:error, reason} when reason in [:enoent, :enodev, :eagain, :timeout] -> :ok
      {:error, {:timeout, _}} -> :ok
      other -> other
    end
  end

  defp default_touch(path) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        result = Circuits.UART.open(uart, path, speed: @boot_baud, active: false)
        Isthmus.Networks.Uart.release(uart)
        if result == :ok, do: :ok, else: result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_volume(before, mounts, volumes, timeout_ms) do
    deadline = now_ms() + timeout_ms

    wait_until(
      deadline,
      fn ->
        now = mounts.()

        List.first(now -- before) ||
          Enum.find(now, &uf2_label?(Path.basename(&1))) ||
          List.first(volumes.()) ||
          Enum.find(now, &uf2_marker?/1)
      end,
      :uf2_volume_timeout
    )
  end

  defp wait_volume_gone(dest, mounts, volumes, timeout_ms) do
    deadline = now_ms() + timeout_ms

    wait_until(
      deadline,
      fn -> if gone?(dest, mounts, volumes), do: :gone end,
      :ok
    )
  end

  defp gone?(dest, mounts, volumes) do
    dest not in mounts.() and dest not in volumes.()
  end

  defp wait_until(deadline, fun, timeout_reason) do
    case fun.() do
      nil ->
        if now_ms() >= deadline do
          if timeout_reason == :ok, do: :ok, else: {:error, timeout_reason}
        else
          Process.sleep(@poll_ms)
          wait_until(deadline, fun, timeout_reason)
        end

      :gone ->
        :ok

      value ->
        {:ok, value}
    end
  end

  defp copy_uf2(image, dest_dir, copy_fun, timeout_ms, gone?) do
    target = Path.join(dest_dir, Path.basename(image))
    task = Task.async(fn -> copy_fun.(image, target) end)
    await_copy(task, dest_dir, now_ms() + timeout_ms, gone?)
  end

  defp await_copy(task, dest, deadline, gone?) do
    remain = max(deadline - now_ms(), 0)
    slice = min(remain, @poll_ms)

    cond do
      remain == 0 ->
        _ = Task.shutdown(task, :brutal_kill)
        if gone?.(), do: :ok, else: {:error, :uf2_copy_timeout}

      (result = Task.yield(task, slice)) != nil ->
        finish_copy(result, gone?)

      gone?.() ->
        _ = Task.shutdown(task, :brutal_kill)
        :ok

      true ->
        await_copy(task, dest, deadline, gone?)
    end
  end

  defp finish_copy({:ok, :ok}, _gone?), do: :ok

  defp finish_copy({:ok, {:error, reason}}, gone?) do
    if gone?.() or reason in @transient_copy do
      :ok
    else
      {:error, {:uf2_copy, reason}}
    end
  end

  defp finish_copy(_, gone?) do
    if gone?.(), do: :ok, else: {:error, :uf2_copy_timeout}
  end

  defp uf2_marker?(path) do
    quick_exists?(Path.join(path, "INFO_UF2.TXT")) or
      quick_exists?(Path.join(path, "CURRENT.UF2"))
  end

  defp timed(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp quick_exists?(path) do
    timed(fn -> File.exists?(path) end, @marker_timeout_ms) == true
  end

  defp unescape_mount(path) do
    path
    |> String.replace("\\040", " ")
    |> String.replace("\\011", "\t")
    |> String.replace("\\012", "\n")
    |> String.replace("\\134", "\\")
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
