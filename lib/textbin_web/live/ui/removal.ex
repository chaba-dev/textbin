defmodule TextbinWeb.UI.Removal do
  @moduledoc """
  Wording for removed pastes, shared by the Deleted tab and the page a removed
  paste's link shows the people who can restore it.

  Only used inside a workspace the viewer belongs to, so showing a member's
  email here does not leak it outside the team.
  """

  alias Textbin.Accounts.User
  alias Textbin.Pastes.Paste

  def reason_sentence(%Paste{} = paste, scope) do
    case Paste.removal_reason(paste) do
      "expired" ->
        "Expired #{format_date(Paste.removed_on(paste))}"

      _deleted ->
        "Deleted by #{actor(paste.removed_by_user, scope)} #{format_date(paste.removed_at)}"
    end
  end

  def days_left_sentence(%Paste{} = paste, %{recovery_window_days: window_days}) do
    case Paste.recovery_days_left(paste, window_days) do
      1 -> "Permanently deleted in 1 day"
      days -> "Permanently deleted in #{days} days"
    end
  end

  defp actor(%User{id: id}, %{user: %User{id: id}}), do: "you"
  defp actor(%User{email: email}, _scope), do: email
  defp actor(_user, _scope), do: "a former member"

  defp format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "on %b %-d, %Y")
end
