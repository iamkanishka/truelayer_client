defmodule TruelayerClient.Signing do
  @moduledoc """
  ES512 JWS request signing for the TrueLayer Payments, Payouts, and Mandates APIs.

  Uses Erlang's `:crypto` and `:public_key` OTP modules — zero external dependencies.

  ## TrueLayer signing specification

    * Algorithm: ES512 (ECDSA with P-521 curve and SHA-512)
    * Format: `<base64url_header>..<base64url_p1363_signature>`
    * JWS protected header: `{"alg":"ES512","kid":"<key_id>","tl-version":"2","tl-headers":"<header_names>","iat":<unix_ts>}`
    * Signing payload: `<METHOD>\\n<PATH>\\n<HEADER_LINES>\\n<BODY>`

  ## Obtaining a signing key

  Generate a P-521 EC key pair using OpenSSL:

      openssl ecparam -name secp521r1 -genkey -noout -out signing_private.pem
      openssl ec -in signing_private.pem -pubout -out signing_public.pem

  Upload the public key to the TrueLayer Console and note the returned Key ID.
  """

  alias TruelayerClient.Error

  @type signer :: %{key: term(), key_id: String.t()}

  @doc """
  Parse a PEM-encoded EC private key (PKCS8 or SEC1) and return a signer map.

  ## Example

      pem = File.read!("keys/signing_private.pem")
      {:ok, signer} = TruelayerClient.Signing.new_signer(pem, "my-key-id")
  """
  @spec new_signer(binary(), String.t()) :: {:ok, signer()} | {:error, Error.t()}
  def new_signer(pem, key_id) when is_binary(pem) and byte_size(pem) > 0 and is_binary(key_id) do
    case :public_key.pem_decode(pem) do
      [] ->
        {:error, %Error{type: :validation_error, reason: "no PEM block found in signing key"}}

      [entry | _] ->
        try do
          key = :public_key.pem_entry_decode(entry)
          {:ok, %{key: key, key_id: key_id}}
        rescue
          e ->
            {:error,
             %Error{type: :validation_error, reason: "PEM decode failed: #{Exception.message(e)}"}}
        end
    end
  end

  def new_signer("", _key_id) do
    {:error, %Error{type: :validation_error, reason: "signing_key_pem must not be empty"}}
  end

  def new_signer(_pem, _key_id) do
    {:error, %Error{type: :validation_error, reason: "signing_key_pem must be a binary"}}
  end

  @doc """
  Produce the value of the `Tl-Signature` request header.

  ## Parameters

    * `signer` - signer map from `new_signer/2`
    * `method` - HTTP method in uppercase, e.g. `"POST"`
    * `path` - request path without query string, e.g. `"/v3/payments"`
    * `headers` - map of header names → values to include in the signature
    * `body` - raw request body bytes (use `""` for no body)

  ## Example

      {:ok, sig} = TruelayerClient.Signing.sign(signer, "POST", "/v3/payments", %{
        "idempotency-key" => "idem-001",
        "content-type" => "application/json"
      }, body_bytes)
      # Use sig as the value of the Tl-Signature header
  """
  @spec sign(signer(), String.t(), String.t(), map(), binary()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def sign(%{key: key, key_id: key_id}, method, path, headers, body)
      when is_binary(method) and is_binary(path) and is_map(headers) and is_binary(body) do
    try do
      sorted_names = headers |> Map.keys() |> Enum.map(&String.downcase/1) |> Enum.sort()

      header_lines =
        Enum.map(sorted_names, fn name ->
          val = Map.get(headers, name) || Map.get(headers, String.upcase(name)) || ""
          "#{name}: #{val}"
        end)

      jws_header_json =
        Jason.encode!(%{
          "alg" => "ES512",
          "kid" => key_id,
          "tl-version" => "2",
          "tl-headers" => Enum.join(sorted_names, ","),
          "iat" => System.os_time(:second)
        })

      encoded_header = Base.url_encode64(jws_header_json, padding: false)

      signing_input =
        [String.upcase(method), path | header_lines]
        |> Kernel.++([body])
        |> Enum.join("\n")

      payload_to_sign = "#{encoded_header}.#{signing_input}"
      digest = :crypto.hash(:sha512, payload_to_sign)

      der_sig = :public_key.sign(digest, :none, key)
      p1363_sig = der_to_p1363(der_sig, 66)
      encoded_sig = Base.url_encode64(p1363_sig, padding: false)

      {:ok, "#{encoded_header}..#{encoded_sig}"}
    rescue
      e ->
        {:error, %Error{type: :unknown, reason: "signing failed: #{Exception.message(e)}"}}
    end
  end

  # ── DER ↔ P1363 conversion ────────────────────────────────────────────────────

  # Convert DER-encoded ECDSA signature to IEEE P1363 format (fixed-width r || s).
  # P-521 uses 66 bytes per coordinate.
  defp der_to_p1363(der, coord_bytes) do
    {r_int, s_int} = decode_der_ecdsa(der)
    pad_big_endian(r_int, coord_bytes) <> pad_big_endian(s_int, coord_bytes)
  end

  # Parse DER SEQUENCE { INTEGER r, INTEGER s }
  defp decode_der_ecdsa(<<0x30, _len, rest::binary>>) do
    {r_int, rest2} = decode_asn1_integer(rest)
    {s_int, _} = decode_asn1_integer(rest2)
    {r_int, s_int}
  end

  defp decode_asn1_integer(<<0x02, len, data::binary>>) do
    <<int_bytes::binary-size(len), rest::binary>> = data
    n = :binary.decode_unsigned(int_bytes)
    {n, rest}
  end

  defp pad_big_endian(n, size) do
    raw = :binary.encode_unsigned(n)
    len = byte_size(raw)
    pad = max(size - len, 0)
    :binary.copy(<<0>>, pad) <> raw
  end
end
