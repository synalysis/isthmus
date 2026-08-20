defmodule Isthmus.Networks.Firmware.Version do
  @moduledoc """
  Normalize and compare radio firmware version strings.

  Compares the numeric dotted prefix only (`1.17.1`, `v1.17.1-d929643`,
  `2.7.26.54e0d8d`). Git hashes and other suffixes are ignored.
  """

  @type status :: :newer_available | :current | :running_ahead | :unknown

  @spec compare(term(), term()) :: status()
  def compare(running, latest) do
    case {parse(running), parse(latest)} do
      {[], _} -> :unknown
      {_, []} -> :unknown
      {a, b} -> cmp_parts(a, b)
    end
  end

  @spec parse(term()) :: [non_neg_integer()]
  def parse(version) when is_binary(version) do
    version
    |> String.trim()
    |> String.trim_leading("v")
    |> String.trim_leading("V")
    |> String.split(~r/[-+_]/, parts: 2)
    |> List.first()
    |> String.split(".")
    |> Enum.reduce_while([], fn part, acc ->
      case Integer.parse(part) do
        {n, ""} when n >= 0 -> {:cont, [n | acc]}
        _ -> {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end

  def parse(_), do: []

  @spec display(term()) :: String.t() | nil
  def display(version) when is_binary(version) do
    case String.trim(version) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def display(_), do: nil

  defp cmp_parts(a, b) do
    max_len = max(length(a), length(b))
    left = pad(a, max_len)
    right = pad(b, max_len)

    cond do
      left < right -> :newer_available
      left > right -> :running_ahead
      true -> :current
    end
  end

  defp pad(parts, n), do: parts ++ List.duplicate(0, n - length(parts))
end
