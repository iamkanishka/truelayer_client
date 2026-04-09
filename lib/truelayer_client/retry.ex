defmodule TruelayerClient.Retry do
  @moduledoc """
  Exponential backoff with cryptographically random full jitter.

  ## Retry safety

  Only idempotent calls are retried unconditionally. POST requests are retried
  only when the response carries `Tl-Should-Retry: true` (captured in
  `TruelayerClient.Error.retryable?/1`).

  Jitter uses `:crypto.strong_rand_bytes/1` — never `rand` — to prevent
  thundering-herd reconnections.
  """

  alias TruelayerClient.Error

  @type policy :: %{
          max_attempts: pos_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          multiplier: float()
        }

  @doc "Build a retry policy from a `TruelayerClient.Config`."
  @spec from_config(TruelayerClient.Config.t()) :: policy()
  def from_config(config) do
    %{
      max_attempts: config.max_retries,
      base_delay_ms: config.base_retry_delay_ms,
      max_delay_ms: 10_000,
      multiplier: 2.0
    }
  end

  @doc """
  Execute `fun` up to `policy.max_attempts` times, backing off between failures.

  `fun` must return `{:ok, result}` or `{:error, %TruelayerClient.Error{}}`.
  Retries occur only when `TruelayerClient.Error.retryable?/1` returns `true`.

  ## Example

      Retry.run(policy, fn ->
        HTTP.json_request(http, config, method: :get, url: url, headers: headers)
      end)
  """
  @spec run(policy(), (-> {:ok, term()} | {:error, Error.t()})) ::
          {:ok, term()} | {:error, Error.t()}
  def run(policy, fun) when is_function(fun, 0) do
    do_run(fun, policy, 1, policy.base_delay_ms)
  end

  defp do_run(fun, policy, attempt, delay_ms) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, error} = err ->
        if attempt < policy.max_attempts and Error.retryable?(error) do
          jitter_ms = crypto_jitter(delay_ms)
          Process.sleep(jitter_ms)

          next_delay = min(trunc(delay_ms * policy.multiplier), policy.max_delay_ms)
          do_run(fun, policy, attempt + 1, next_delay)
        else
          err
        end
    end
  end

  # Uniform random integer in [0, max_ms) using cryptographic entropy.
  defp crypto_jitter(0), do: 0

  defp crypto_jitter(max_ms) do
    <<n::unsigned-big-64>> = :crypto.strong_rand_bytes(8)
    rem(n, max_ms)
  end
end
