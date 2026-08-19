defmodule TextbinWeb.UserLive.Settings do
  use TextbinWeb, :live_view

  alias Textbin.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address, password, and paste defaults</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <section id="paste-defaults" class="space-y-4">
        <.header>
          Paste Defaults
          <:subtitle>Choose the default expiration for new pastes.</:subtitle>
        </.header>

        <.form
          for={@paste_defaults_form}
          id="paste_defaults_form"
          phx-submit="update_paste_defaults"
        >
          <.input
            field={@paste_defaults_form[:default_paste_ttl]}
            type="select"
            label="Default paste expiration"
            options={paste_ttl_options()}
          />
          <.button variant="primary" phx-disable-with="Saving...">Save Paste Defaults</.button>
        </.form>
      </section>

      <div class="divider" />

      <section id="api-tokens" class="space-y-6">
        <.header>
          API Tokens
          <:subtitle>Create tokens for CLI and script access.</:subtitle>
        </.header>

        <%= if @new_api_token do %>
          <div id="new-api-token" class="alert alert-info items-start">
            <.icon name="hero-information-circle" class="mt-1 size-5 shrink-0" />
            <div class="space-y-2">
              <p class="font-semibold">Copy this token now. It will not be shown again.</p>
              <input
                id="new-api-token-value"
                type="text"
                class="input input-bordered w-full border-base-300 bg-base-100 font-mono text-sm text-base-content"
                value={@new_api_token}
                readonly
              />
            </div>
          </div>
        <% end %>

        <.form for={@api_token_form} id="api_token_form" phx-submit="create_api_token">
          <.input
            field={@api_token_form[:name]}
            type="text"
            label="Token name"
            placeholder="CLI"
            required
          />
          <.button variant="primary" phx-disable-with="Creating...">Create API Token</.button>
        </.form>

        <div id="api-token-list" class="space-y-3">
          <div
            :if={@api_tokens == []}
            id="api-token-empty"
            class="rounded-lg border border-dashed border-base-300 p-6 text-sm text-base-content/60"
          >
            No API tokens yet.
          </div>

          <div
            :for={token <- @api_tokens}
            id={"api-token-#{token.id}"}
            class="flex flex-col gap-3 rounded-lg border border-base-300 p-4 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <p class="font-medium">{token.name}</p>
              <p class="text-sm text-base-content/60">
                Created {format_api_token_time(token.inserted_at)}
                <%= if token.last_used_at do %>
                  · Last used {format_api_token_time(token.last_used_at)}
                <% else %>
                  · Never used
                <% end %>
              </p>
            </div>
            <button
              id={"delete-api-token-#{token.id}"}
              type="button"
              phx-click="delete_api_token"
              phx-value-id={token.id}
              data-confirm="Revoke this API token?"
              class="btn btn-sm btn-error"
            >
              Revoke
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)
    paste_defaults_changeset = Accounts.change_user_paste_defaults(user)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:paste_defaults_form, to_form(paste_defaults_changeset))
      |> assign(:api_token_form, to_form(%{"name" => ""}, as: :api_token))
      |> assign(:api_tokens, Accounts.list_user_api_tokens(user))
      |> assign(:new_api_token, nil)
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params

    with_sudo_mode(socket, fn user ->
      case Accounts.change_user_email(user, user_params) do
        %{valid?: true} = changeset ->
          Accounts.deliver_user_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            user.email,
            &url(~p"/users/settings/confirm-email/#{&1}")
          )

          info = "A link to confirm your email change has been sent to the new address."
          {:noreply, put_flash(socket, :info, info)}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    end)
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params

    with_sudo_mode(socket, fn user ->
      case Accounts.change_user_password(user, user_params) do
        %{valid?: true} = changeset ->
          {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

        changeset ->
          {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
      end
    end)
  end

  def handle_event("update_paste_defaults", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_paste_defaults(user, user_params) do
      {:ok, user} ->
        current_scope = %{socket.assigns.current_scope | user: user}

        {:noreply,
         socket
         |> put_flash(:info, "Paste defaults updated.")
         |> assign(:current_scope, current_scope)
         |> assign(:paste_defaults_form, to_form(Accounts.change_user_paste_defaults(user)))}

      {:error, changeset} ->
        {:noreply, assign(socket, paste_defaults_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("create_api_token", %{"api_token" => api_token_params}, socket) do
    with_sudo_mode(socket, fn user ->
      case Accounts.create_user_api_token(user, api_token_params) do
        {:ok, {token, _user_token}} ->
          {:noreply,
           socket
           |> put_flash(:info, "API token created.")
           |> assign(:api_token_form, to_form(%{"name" => ""}, as: :api_token))
           |> assign(:api_tokens, Accounts.list_user_api_tokens(user))
           |> assign(:new_api_token, token)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not create API token.")}
      end
    end)
  end

  def handle_event("delete_api_token", %{"id" => token_id}, socket) do
    with_sudo_mode(socket, fn user ->
      case Accounts.delete_user_api_token(user, token_id) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "API token revoked.")
           |> assign(:api_tokens, Accounts.list_user_api_tokens(user))
           |> assign(:new_api_token, nil)}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "API token not found.")}
      end
    end)
  end

  defp with_sudo_mode(socket, callback) do
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      callback.(user)
    else
      {:noreply,
       socket
       |> put_flash(:error, "You must re-authenticate to change sensitive account settings.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  defp format_api_token_time(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp paste_ttl_options do
    [
      {"Never", "never"},
      {"10 minutes", "10m"},
      {"1 hour", "1h"},
      {"6 hours", "6h"},
      {"12 hours", "12h"},
      {"1 day", "1d"},
      {"7 days", "7d"},
      {"30 days", "30d"}
    ]
  end
end
