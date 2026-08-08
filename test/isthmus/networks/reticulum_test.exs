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

  describe "addressed tunnel delivery gate" do
    setup do
      original = System.get_env("ISTHMUS_TUNNEL_ADDRESSED")

      on_exit(fn ->
        if original,
          do: System.put_env("ISTHMUS_TUNNEL_ADDRESSED", original),
          else: System.delete_env("ISTHMUS_TUNNEL_ADDRESSED")
      end)

      :ok
    end

    test "addressed_enabled? defaults on and only a falsey env disables it" do
      System.delete_env("ISTHMUS_TUNNEL_ADDRESSED")
      assert Reticulum.addressed_enabled?()

      for on <- ~w(1 true YES on anything) do
        System.put_env("ISTHMUS_TUNNEL_ADDRESSED", on)
        assert Reticulum.addressed_enabled?(), "expected #{on} to enable"
      end

      for off <- ~w(0 false no off) do
        System.put_env("ISTHMUS_TUNNEL_ADDRESSED", off)
        refute Reticulum.addressed_enabled?(), "expected #{off} to disable"
      end
    end

    test "tunnel_destination_hash is nil while addressed mode is disabled" do
      System.put_env("ISTHMUS_TUNNEL_ADDRESSED", "0")
      assert Reticulum.tunnel_destination_hash() == nil
    end
  end
end
