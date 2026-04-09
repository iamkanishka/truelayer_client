defmodule TruelayerClient.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/iamkanishka/truelayer_client"

  def project do
    [
      app: :truelayer_client,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # Hex package
      description: "Production-grade Elixir client for the TrueLayer open banking API",
      package: package(),
      # ExDoc
      name: "truelayer_client",
      source_url: @source_url,
      docs: docs(),
      # Coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      # Dialyzer
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {TruelayerClient.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},

      # Test / dev
      {:bypass, "~> 2.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["iamkanishka"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        Core: [
          TruelayerClient,
          TruelayerClient.Config,
          TruelayerClient.Error
        ],
        Authentication: [
          TruelayerClient.Auth,
          TruelayerClient.Auth.Token,
          TruelayerClient.Auth.TokenStore,
          TruelayerClient.Auth.MemoryStore
        ],
        Payments: [
          TruelayerClient.Payments,
          TruelayerClient.Payments.Types
        ],
        Payouts: [TruelayerClient.Payouts],
        "Merchant Accounts": [TruelayerClient.Merchant],
        "Mandates (VRP)": [TruelayerClient.Mandates],
        "Data API": [TruelayerClient.Data],
        Verification: [TruelayerClient.Verification],
        "Signup+": [TruelayerClient.SignupPlus],
        Tracking: [TruelayerClient.Tracking],
        Webhooks: [TruelayerClient.Webhooks],
        Internal: [
          TruelayerClient.HTTP,
          TruelayerClient.Signing,
          TruelayerClient.Retry,
          TruelayerClient.Idempotency
        ]
      ]
    ]
  end

  defp aliases do
    [
      "test.all": ["test --cover"],
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      fmt: ["format"]
    ]
  end
end
