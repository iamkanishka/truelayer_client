defmodule TruelayerClient.Tracking do
  @moduledoc """
  TrueLayer Client Tracking API — retrieve events captured during an authorization flow.

  Useful for diagnosing user drop-off and provider-specific issues in the
  authorization flow without requiring server-side instrumentation.
  """

  alias TruelayerClient.Auth
  alias TruelayerClient.Auth.Token
  alias TruelayerClient.{HTTP, Retry}

  @doc """
  Get tracked events for an authorization flow (GET /events/{flow_id}).

  Returns a list of event maps captured during the authorization session.
  """
  @spec get_tracked_events(TruelayerClient.t(), String.t()) ::
          {:ok, [map()]} | {:error, TruelayerClient.Error.t()}
  def get_tracked_events(client, flow_id) when is_binary(flow_id) do
    with {:ok, token} <- payments_token(client),
         {:ok, resp} <-
           Retry.run(Retry.from_config(client.config), fn ->
             HTTP.json_request(client.http, client.config,
               method: :get,
               url: url(client, "/events/#{flow_id}"),
               headers: bearer_map(token)
             )
           end) do
      {:ok, Map.get(resp, "items", [])}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp payments_token(client),
    do: Auth.client_credentials(client, Auth.payments_scopes(), :payments)

  defp bearer_map(%Token{} = token), do: Map.new([Token.bearer_header(token)])
  defp url(%{config: %{api_url: base}}, path), do: base <> path
end
