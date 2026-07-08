defmodule TextbinWeb.Router do
  use TextbinWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TextbinWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TextbinWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", TextbinWeb.UI do
    pipe_through :browser

    live "/pastes", PasteLive, :index
    live "/pastes/:id", PasteLive, :show
  end

  # v1 API
  scope "/api/v1", TextbinWeb.ApiV1 do
    pipe_through :api

    resources "/pastes", PasteController, except: [:new, :edit]
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
end
