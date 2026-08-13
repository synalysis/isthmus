defmodule Isthmus.MCP.Args do
  @moduledoc false

  alias Isthmus.Accounts
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Registrations
  alias Isthmus.Tunnel

  @type args :: map()
  @type error :: {:error, String.t()}

  @spec fetch(args(), atom()) :: term()
  def fetch(args, key) when is_map(args) do
    Map.get(args, key) || Map.get(args, Atom.to_string(key))
  end

  @spec require_text(args(), atom()) :: {:ok, String.t()} | error()
  def require_text(args, key) do
    case args |> fetch(key) |> to_string() |> String.trim() do
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  @spec optional_text(args(), atom()) :: String.t() | nil
  def optional_text(args, key) do
    case args |> fetch(key) |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @spec require_bool(args(), atom()) :: {:ok, boolean()} | error()
  def require_bool(args, key) do
    case fetch(args, key) do
      v when is_boolean(v) -> {:ok, v}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  @spec clamp_int(term(), integer(), integer(), integer()) :: integer()
  def clamp_int(nil, default, _min, _max), do: default
  def clamp_int(n, _default, min, max) when is_integer(n), do: n |> max(min) |> min(max)

  def clamp_int(n, default, min, max) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> clamp_int(i, default, min, max)
      _ -> default
    end
  end

  def clamp_int(_, default, _, _), do: default

  @spec resolve_group(term()) :: {:ok, Registrations.group()} | error()
  def resolve_group(nil), do: {:error, "group is required"}
  def resolve_group(""), do: {:error, "group is required"}

  def resolve_group(id_or_name) when is_binary(id_or_name) do
    trimmed = String.trim(id_or_name)

    by_id =
      case Ecto.UUID.cast(trimmed) do
        {:ok, _} -> Registrations.get_group(trimmed)
        :error -> nil
      end

    cond do
      is_map(by_id) ->
        {:ok, by_id}

      true ->
        name = String.downcase(trimmed)

        case Enum.find(
               Registrations.list_all(),
               &(String.downcase(&1.display_name || "") == name)
             ) do
          nil -> {:error, "group not found: #{trimmed}"}
          group -> {:ok, Registrations.get_group!(group.id)}
        end
    end
  end

  def resolve_group(_), do: {:error, "group is required"}

  @spec resolve_tunnel(term()) :: {:ok, map()} | error()
  def resolve_tunnel(nil), do: {:error, "tunnel is required"}
  def resolve_tunnel(""), do: {:error, "tunnel is required"}

  def resolve_tunnel(id_or_name) when is_binary(id_or_name) do
    trimmed = String.trim(id_or_name)
    peers = Tunnel.list_peers()

    found =
      Enum.find(peers, &(&1.id == trimmed)) ||
        Enum.find(peers, &(String.downcase(&1.name || "") == String.downcase(trimmed))) ||
        Enum.find(peers, &(&1.tunnel_id == trimmed))

    if found, do: {:ok, found}, else: {:error, "tunnel not found: #{trimmed}"}
  end

  @spec resolve_owner(term()) :: {:ok, String.t()} | error()
  def resolve_owner(nil), do: default_owner()
  def resolve_owner(""), do: default_owner()

  def resolve_owner(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.match?(trimmed, ~r/\A[0-9a-f]{64}\z/i) ->
        {:ok, String.downcase(trimmed)}

      true ->
        case Bech32.decode(trimmed) do
          {:ok, "npub", pubkey} -> {:ok, Base.encode16(pubkey, case: :lower)}
          _ -> {:error, "owner must be an npub or 64-char hex pubkey"}
        end
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> inspect()
  end

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(reason), do: inspect(reason)

  defp default_owner do
    case Accounts.list_admins() do
      [%{pubkey_hex: hex} | _] -> {:ok, hex}
      [] -> {:error, "no admin on file — pass owner as npub"}
    end
  end
end
