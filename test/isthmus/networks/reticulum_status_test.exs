defmodule Isthmus.Networks.ReticulumStatusTest do
  use ExUnit.Case, async: false

  alias Isthmus.Networks.Reticulum

  test "instance_status returns a shaped snapshot when sidecar is up" do
    case Reticulum.instance_status() do
      {:ok, status} ->
        assert is_boolean(status.live)
        assert is_binary(status.instance_role)
        assert is_map(status.instance)
        assert is_map(status.config)
        assert is_list(status.interfaces)

      {:error, :stub_mode} ->
        :ok

      {:error, :not_started} ->
        :ok

      {:error, :not_connected} ->
        :ok

      {:error, other} ->
        flunk("unexpected error: #{inspect(other)}")
    end
  end
end
