defmodule Textbin.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        TextbinWeb.Telemetry,
        Textbin.Repo,
        {DNSCluster, query: Application.get_env(:textbin, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Textbin.PubSub}
      ] ++
        storage_children() ++
        expiration_cleanup_children() ++ upload_cleanup_children() ++ [TextbinWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Textbin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TextbinWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp expiration_cleanup_children do
    if Application.get_env(:textbin, :expiration_cleanup_enabled, true) do
      [Textbin.Pastes.ExpirationCleaner]
    else
      []
    end
  end

  defp upload_cleanup_children do
    if Application.get_env(:textbin, :upload_cleanup_enabled, true) do
      [Textbin.Pastes.UploadCleaner]
    else
      []
    end
  end

  defp storage_children do
    case Textbin.Storage.child_spec() do
      nil -> []
      child_spec -> [child_spec]
    end
  end
end
