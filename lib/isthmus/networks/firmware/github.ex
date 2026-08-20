defmodule Isthmus.Networks.Firmware.GitHub do
  @moduledoc false

  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(url, opts \\ []) when is_binary(url) do
    request = Keyword.get(opts, :request, &Req.get/2)

    case request.(url, req_opts()) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req_opts do
    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "Isthmus firmware catalog"}
    ]

    headers =
      case github_token() do
        token when is_binary(token) and token != "" ->
          [{"authorization", "Bearer #{token}"} | headers]

        _ ->
          headers
      end

    [headers: headers, decode_body: true, retry: false, receive_timeout: 15_000]
  end

  defp github_token do
    System.get_env("ISTHMUS_GITHUB_TOKEN") || System.get_env("GITHUB_TOKEN")
  end
end
