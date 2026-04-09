defmodule TruelayerClient.Auth.Token do
  @moduledoc """
  Represents a TrueLayer OAuth2 access token with expiry tracking.

  ## Token isolation

  The `:token_type` field enforces strict isolation between Payments tokens
  (used by Payments, Payouts, Mandates) and Data tokens (used by the Data API).
  A Data token can never authorise a Payments API call — the `:token_type`
  discriminant is checked before every request.
  """

  @type token_type :: :payments | :data

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: token_type(),
          scopes: [String.t()],
          expires_at: DateTime.t()
        }

  @enforce_keys [:access_token, :token_type, :expires_at]
  defstruct [:access_token, :refresh_token, :token_type, :expires_at, scopes: []]

  @doc """
  Build a `Token` from a raw OAuth2 response map.

  Applies a 30-second safety buffer to `expires_at` to account for clock skew
  and network latency between token acquisition and first use.
  """
  @spec from_response(map(), token_type()) :: t()
  def from_response(%{"access_token" => at} = resp, token_type)
      when token_type in [:payments, :data] do
    expires_in = Map.get(resp, "expires_in", 3600)

    %__MODULE__{
      access_token: at,
      refresh_token: resp["refresh_token"],
      token_type: token_type,
      scopes: resp |> Map.get("scope", "") |> String.split(" ", trim: true),
      expires_at: DateTime.add(DateTime.utc_now(), expires_in - 30, :second)
    }
  end

  @doc """
  Returns `true` when this token is expired and should not be used.

  The 30-second buffer applied in `from_response/2` ensures tokens are
  refreshed before the server rejects them.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  @doc """
  Returns an `{\"authorization\", \"Bearer <token>\"}` header tuple,
  ready to merge into a request headers map.
  """
  @spec bearer_header(t()) :: {String.t(), String.t()}
  def bearer_header(%__MODULE__{access_token: at}), do: {"authorization", "Bearer #{at}"}
end
