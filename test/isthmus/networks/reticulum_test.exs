defmodule Isthmus.Networks.ReticulumTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.Reticulum
  alias Isthmus.Networks.Reticulum.Sidecar

  test "parse_identity_ref accepts 32-hex destination hashes" do
    hash = String.duplicate("ab", 16)
    assert {:ok, ^hash, %{destination_hash: ^hash}} = Reticulum.parse_identity_ref(hash)
  end

  test "generate_proxy_identity returns destination hash and private key material" do
    assert {:ok, result} = Reticulum.generate_proxy_identity(%{name: "Test"})
    assert String.match?(result.identity_ref, ~r/^[0-9a-f]{32}$/)

    assert is_binary(
             result.private_material[:private_key_hex] ||
               result.private_material["private_key_hex"]
           )

    assert Enum.any?(result.presentations, &(&1.format_id == "lxmf_destination"))
  end

  test "sidecar health reports status" do
    health = Sidecar.health()
    assert health.status in [:starting, :online, :live, :stub, :crashed]
  end
end
