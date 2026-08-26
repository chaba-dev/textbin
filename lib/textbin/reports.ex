defmodule Textbin.Reports do
  @moduledoc """
  Abuse-report submission and its non-public reporter boundary.

  Reports retain paste and reporter identifiers after either record is deleted,
  so those identifiers intentionally are not database foreign keys. Only the
  administration context can read or review submitted reports.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Organizations.{Organization, Workspace}
  alias Textbin.Pastes.Paste
  alias Textbin.Repo
  alias Textbin.Reports.Report

  @doc "Submits an abuse report for an active public or unlisted paste."
  def create_report(%Scope{user: %User{id: reporter_id}}, paste_id, attrs)
      when is_map(attrs) do
    with {:ok, paste_id} <- Ecto.UUID.cast(paste_id) do
      Repo.transact(fn -> create_report_in_transaction(reporter_id, paste_id, attrs) end)
    else
      :error -> {:error, :not_found}
    end
  end

  def create_report(_scope, _paste_id, _attrs), do: {:error, :forbidden}

  defp create_report_in_transaction(reporter_id, paste_id, attrs) do
    case active_registered_user(reporter_id) do
      %User{} = reporter -> insert_report(reporter, paste_id, attrs)
      nil -> {:error, :forbidden}
    end
  end

  defp insert_report(reporter, paste_id, attrs) do
    case reportable_paste(paste_id) do
      %Paste{} = paste ->
        %Report{paste_id: paste.id, reporter_user_id: reporter.id}
        |> Report.submission_changeset(attrs)
        |> Repo.insert()

      nil ->
        {:error, :not_found}
    end
  end

  defp active_registered_user(user_id) do
    Repo.one(
      from user in User,
        where:
          user.id == ^user_id and user.kind == "registered" and
            not is_nil(user.confirmed_at) and is_nil(user.suspended_at),
        lock: "FOR SHARE"
    )
  end

  defp reportable_paste(paste_id) do
    now = Paste.utc_now_ms()

    Repo.one(
      from paste in Paste,
        join: workspace in Workspace,
        on: workspace.id == paste.workspace_id,
        join: organization in Organization,
        on: organization.id == workspace.organization_id,
        where:
          paste.id == ^paste_id and
            (is_nil(paste.expires_at) or paste.expires_at > ^now) and
            is_nil(workspace.deletion_requested_at) and
            is_nil(organization.deletion_requested_at) and
            ((paste.audience == "unlisted" and
                workspace.external_sharing_policy in ["unlisted", "public"]) or
               (paste.audience == "public" and
                  workspace.external_sharing_policy == "public")),
        lock: "FOR SHARE"
    )
  end
end
