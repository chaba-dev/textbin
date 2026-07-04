defmodule Kopynpaste.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KopynpasteWeb.Telemetry,
      Kopynpaste.Repo,
      {DNSCluster, query: Application.get_env(:kopynpaste, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kopynpaste.PubSub},
      # Start a worker by calling: Kopynpaste.Worker.start_link(arg)
      # {Kopynpaste.Worker, arg},
      # Start to serve requests, typically the last entry
      KopynpasteWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kopynpaste.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KopynpasteWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
