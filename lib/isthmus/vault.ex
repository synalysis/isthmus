defmodule Isthmus.Vault do
  @moduledoc """
  Encrypts proxy private material at rest with a host secret.
  """

  @aad "isthmus-proxy-v1"

  def encrypt(map) when is_map(map) do
    plaintext = Jason.encode!(map)
    key = secret_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    {:ok, iv <> tag <> ciphertext}
  end

  def decrypt(blob) when is_binary(blob) and byte_size(blob) > 28 do
    <<iv::binary-12, tag::binary-16, ciphertext::binary>> = blob
    key = secret_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> Jason.decode(plaintext)
      :error -> {:error, :decrypt_failed}
    end
  end

  def decrypt(_), do: {:error, :invalid_blob}

  defp secret_key do
    secret =
      System.get_env("ISTHMUS_VAULT_SECRET") ||
        Application.get_env(:isthmus, :vault_secret) ||
        "dev-only-insecure-isthmus-vault-secret!!"

    :crypto.hash(:sha256, secret)
  end
end
