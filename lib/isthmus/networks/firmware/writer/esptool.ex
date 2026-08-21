defmodule Isthmus.Networks.Firmware.Writer.Esptool do
  @moduledoc false

  @script Path.expand("sidecar/firmware_flash.py")

  @spec write(map()) :: :ok | {:error, term()}
  def write(%{path: port, image_path: image, offset: offset} = job)
      when is_binary(port) and is_binary(image) and is_integer(offset) do
    python = System.find_executable("python3") || System.find_executable("python")
    script = job[:script] || @script

    cond do
      is_nil(python) ->
        {:error, :python_missing}

      not File.exists?(script) ->
        {:error, :esptool_script_missing}

      true ->
        run(python, script, port, offset, image)
    end
  end

  def write(_), do: {:error, :invalid_flash_job}

  defp run(python, script, port, offset, image) do
    {output, status} =
      System.cmd(
        python,
        [script, "--port", port, "--offset", hex(offset), "--image", image],
        stderr_to_stdout: true
      )

    if status == 0 do
      :ok
    else
      {:error, format_error(output, status)}
    end
  end

  defp hex(n) when is_integer(n), do: "0x" <> Integer.to_string(n, 16)

  defp format_error(output, status) do
    text = output |> to_string() |> String.trim()

    cond do
      String.contains?(text, "esptool is not installed") ->
        :esptool_missing

      text == "" ->
        {:esptool_failed, status}

      true ->
        {:esptool_failed, text}
    end
  end
end
