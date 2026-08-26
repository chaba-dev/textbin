defmodule TextbinWeb.Router do
  use TextbinWeb, :router

  import TextbinWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TextbinWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_current_scope_for_api_token
  end

  pipeline :require_authenticated_api do
    plug :require_api_token
  end

  scope "/", TextbinWeb do
    pipe_through :browser

    get "/pastes/:id/raw", PasteController, :raw
  end

  # v1 API
  scope "/api/v1", TextbinWeb.ApiV1 do
    pipe_through :api

    post "/auth/tokens", AuthController, :create
  end

  scope "/api/v1", TextbinWeb.ApiV1 do
    pipe_through [:api, :require_authenticated_api]

    get "/me", AuthController, :show
    delete "/me/token", AuthController, :delete
    get "/organizations", OrganizationController, :index
    get "/organizations/:id/workspaces", OrganizationController, :workspaces
    get "/organizations/:id/audit-events", OrganizationController, :audit_events
    post "/workspaces/:workspace_id/recovery", OrganizationController, :recover_workspace
    get "/workspaces/:workspace_id/pastes", PasteController, :index
    post "/workspaces/:workspace_id/pastes", PasteController, :create
    get "/workspaces/:workspace_id/pastes/:id", PasteController, :show
    delete "/workspaces/:workspace_id/pastes/:id", PasteController, :delete
    resources "/pastes", PasteController, except: [:new, :edit, :update]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:textbin, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TextbinWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TextbinWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home

    live_session :require_authenticated_user,
      on_mount: [{TextbinWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/orgs", UI.OrganizationLive, :index
      live "/orgs/new", UI.OrganizationLive, :new
      live "/o/:organization_slug", UI.OrganizationLive, :show
      live "/o/:organization_slug/workspaces", UI.WorkspaceManagementLive, :index
      live "/o/:organization_slug/workspaces/new", UI.WorkspaceManagementLive, :new
      live "/o/:organization_slug/audit-log", UI.AuditLogLive, :index
      live "/o/:organization_slug/members", UI.OrganizationLive, :members
      live "/o/:organization_slug/settings", UI.OrganizationLive, :settings
      live "/w/:organization_slug/:workspace_slug/members", UI.WorkspaceLive, :members
      live "/w/:organization_slug/:workspace_slug/settings", UI.WorkspaceLive, :settings
      live "/admin", UI.AdminLive, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", TextbinWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TextbinWeb.UserAuth, :mount_current_scope}] do
      live "/pastes", UI.PasteLive, :legacy_index
      live "/pastes/:id", UI.PasteLive, :show
      live "/w/:organization_slug/:workspace_slug/pastes", UI.PasteLive, :workspace_index
      live "/w/:organization_slug/:workspace_slug/pastes/:id", UI.PasteLive, :workspace_show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
