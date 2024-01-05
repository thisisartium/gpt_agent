defmodule GptAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :gpt_agent,
      version: "2.0.0-dev",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: [
        main: "GptAgent",
        extras: ["README.md"]
      ],
      source_url: "https://github.com/fractaltechnologylabs/gpt_agent",
      homepage_url: "https://thisisartium.com",
      package: [
        description: "A client for the OpenAI Assistants API",
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/fractaltechnologylabs/gpt_agent",
          "Documentation" => "https://hexdocs.pm/gpt_agent",
          "Artium" => "https://thisisartium.com"
        }
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:assert_match, "~> 1.0", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:eventually, "~> 1.1", only: :test},
      {:ex_check, "~> 0.15", only: :dev, runtime: false},
      {:ex_doc, "~> 0.30", only: [:dev, :test], runtime: false},
      {:faker, "0.17.0", only: :test},
      {:jason, "~> 1.2"},
      {:knigge, "~> 1.4"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:mix_test_interactive, "~> 1.2", only: :dev, runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:open_ai_client, "~> 2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:stream_data, "~> 0.6"},
      {:sobelow, "~> 0.12", only: [:dev, :test], runtime: false},
      {:typed_struct, "~> 0.3"},
      {:uuid, "~> 1.1"}
    ]
  end

  defp aliases do
    [
      compile: ["compile --warnings-as-errors"],
      sobelow: ["sobelow --config"],
      dialyzer: ["dialyzer --list-unused-filters"],
      credo: ["credo --strict"],
      check_formatting: ["format --check-formatted"]
    ]
  end
end
