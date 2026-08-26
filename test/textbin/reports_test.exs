defmodule Textbin.ReportsTest do
  use Textbin.DataCase, async: true

  import Textbin.AccountsFixtures

  alias Textbin.Accounts
  alias Textbin.Accounts.Scope
  alias Textbin.Organizations
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Reports
  alias Textbin.Reports.Report

  setup do
    owner = user_fixture()
    reporter = user_fixture()
    %{owner_scope: Scope.for_user(owner), reporter_scope: Scope.for_user(reporter)}
  end

  test "submits categorized reports for active public and unlisted pastes", context do
    for audience <- ["public", "unlisted"] do
      assert {:ok, paste} =
               Pastes.create_paste(context.owner_scope, %{
                 data: "reportable #{audience}",
                 audience: audience
               })

      assert {:ok, %Report{} = report} =
               Reports.create_report(context.reporter_scope, paste.id, %{
                 "category" => "malware",
                 "notes" => "Suspicious download"
               })

      assert report.paste_id == paste.id
      assert report.reporter_user_id == context.reporter_scope.user.id
      assert report.status == "open"
    end
  end

  test "rejects inaccessible pastes and ineligible reporters", context do
    assert {:ok, workspace_paste} =
             Pastes.create_paste(context.owner_scope, %{
               data: "workspace only",
               audience: "workspace"
             })

    assert {:error, :not_found} =
             Reports.create_report(context.reporter_scope, workspace_paste.id, %{
               "category" => "spam"
             })

    assert {:error, :not_found} =
             Reports.create_report(context.reporter_scope, Ecto.UUID.generate(), %{
               "category" => "spam"
             })

    assert {:ok, public_paste} =
             Pastes.create_paste(context.owner_scope, %{data: "expired", audience: "public"})

    public_paste
    |> Ecto.Changeset.change(expires_at: Paste.utc_now_ms())
    |> Repo.update!()

    assert {:error, :not_found} =
             Reports.create_report(context.reporter_scope, public_paste.id, %{
               "category" => "spam"
             })

    assert {:ok, guest} = Accounts.create_guest_user()

    assert {:error, :forbidden} =
             Reports.create_report(Scope.for_user(guest), workspace_paste.id, %{
               "category" => "spam"
             })

    assert {:error, :forbidden} =
             Reports.create_report(Scope.for_user(nil), workspace_paste.id, %{
               "category" => "spam"
             })

    context.reporter_scope.user
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, :forbidden} =
             Reports.create_report(context.reporter_scope, workspace_paste.id, %{
               "category" => "spam"
             })

    unconfirmed = unconfirmed_user_fixture()

    assert {:error, :forbidden} =
             Reports.create_report(Scope.for_user(unconfirmed), workspace_paste.id, %{
               "category" => "spam"
             })
  end

  test "rejects policy-disabled and deletion-in-progress targets", context do
    organization = Organizations.get_personal_organization!(context.owner_scope.user)
    workspace = hd(organization.workspaces)

    assert {:ok, policy_paste} =
             Pastes.create_paste(context.owner_scope, %{data: "policy", audience: "public"})

    workspace
    |> Ecto.Changeset.change(external_sharing_policy: "disabled")
    |> Repo.update!()

    assert {:error, :not_found} =
             Reports.create_report(context.reporter_scope, policy_paste.id, %{
               "category" => "spam"
             })

    workspace
    |> Ecto.Changeset.change(
      external_sharing_policy: "public",
      deletion_requested_at: Paste.utc_now_ms()
    )
    |> Repo.update!()

    assert {:error, :not_found} =
             Reports.create_report(context.reporter_scope, policy_paste.id, %{
               "category" => "spam"
             })

    workspace
    |> Ecto.Changeset.change(deletion_requested_at: nil)
    |> Repo.update!()

    organization
    |> Ecto.Changeset.change(deletion_requested_at: Paste.utc_now_ms())
    |> Repo.update!()

    assert {:error, :not_found} =
             Reports.create_report(context.reporter_scope, policy_paste.id, %{
               "category" => "spam"
             })
  end

  test "retains reports after reporter and paste deletion", context do
    assert {:ok, paste} =
             Pastes.create_paste(context.owner_scope, %{data: "retained", audience: "public"})

    assert {:ok, report} =
             Reports.create_report(context.reporter_scope, paste.id, %{"category" => "other"})

    assert {:ok, _reporter} = Accounts.delete_user(context.reporter_scope)
    assert Repo.get!(Report, report.id).reporter_user_id == context.reporter_scope.user.id

    assert {:ok, _paste} = Pastes.delete_paste(context.owner_scope, paste)
    refute Repo.get(Paste, paste.id)
    assert Repo.get!(Report, report.id).paste_id == paste.id
  end

  test "validates category, notes, and one open report per reporter", context do
    assert {:ok, paste} =
             Pastes.create_paste(context.owner_scope, %{data: "spam", audience: "public"})

    assert {:error, invalid_category} =
             Reports.create_report(context.reporter_scope, paste.id, %{"category" => "invalid"})

    assert "is invalid" in errors_on(invalid_category).category

    assert {:error, invalid_notes} =
             Reports.create_report(context.reporter_scope, paste.id, %{
               "category" => "spam",
               "notes" => String.duplicate("x", 1_001)
             })

    assert "should be at most 1000 character(s)" in errors_on(invalid_notes).notes

    assert {:ok, _report} =
             Reports.create_report(context.reporter_scope, paste.id, %{"category" => "spam"})

    assert {:error, duplicate} =
             Reports.create_report(context.reporter_scope, paste.id, %{"category" => "spam"})

    assert "has already been reported" in errors_on(duplicate).paste_id
  end
end
