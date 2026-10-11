defmodule TextbinWeb.Sharing do
  @moduledoc """
  The words the interface uses for who can reach a paste or a workspace.

  The design names three settings, each read as a sentence: **Who can see
  this** on a paste, and **Sharing outside the team** and **Who can join** on
  a workspace. The stored values (`audience`, `external_sharing_policy` and
  `visibility`) predate that vocabulary and stay as they are, because the API,
  the CLI and recorded audit metadata depend on them. Screens name them only
  through this module so the same setting reads the same everywhere.

  Unknown values fall back to the raw value rather than raising, because audit
  metadata can outlive the set of values the code knows about.
  """

  @audiences ["workspace", "unlisted", "public"]
  @sharing_policies ["disabled", "unlisted", "public"]
  @join_policies ["open", "private"]

  ## Who can see this (per paste)

  def audiences, do: @audiences

  def audience_label("workspace"), do: "Workspace"
  def audience_label("unlisted"), do: "Anyone with the link"
  def audience_label("public"), do: "Public"
  def audience_label(audience), do: audience

  def audience_description("workspace"), do: "Everyone in the workspace"
  def audience_description("unlisted"), do: "Not listed anywhere; the link is the key"
  def audience_description("public"), do: "Anyone, signed in or not"
  def audience_description(_audience), do: nil

  def audience_icon("public"), do: "hero-globe-alt"
  def audience_icon("unlisted"), do: "hero-link"
  def audience_icon(_audience), do: "hero-user-group"

  def audience_sentence("workspace", workspace_name) when is_binary(workspace_name),
    do: "Everyone in #{workspace_name} can see this paste."

  def audience_sentence("workspace", _workspace_name),
    do: "Everyone in the workspace can see this paste."

  def audience_sentence("unlisted", _workspace_name),
    do: "Anyone with the link can see this paste."

  def audience_sentence("public", _workspace_name), do: "Anyone can see this paste."

  ## Sharing outside the team (per workspace)

  def sharing_policy_options,
    do: Enum.map(@sharing_policies, &{sharing_policy_label(&1), &1})

  def sharing_policy_label("disabled"), do: "Members only"
  def sharing_policy_label("unlisted"), do: "Members may share a link"
  def sharing_policy_label("public"), do: "Members may also publish"
  def sharing_policy_label(policy), do: policy

  # The settings form saves immediately, and tightening rewrites the pastes
  # that are already shared (Organizations clamps their audience), so the
  # consequence is spelled out next to the control rather than discovered.
  def sharing_policy_sentence("disabled"),
    do: "Pastes stay inside the workspace. Links shared earlier stop working."

  def sharing_policy_sentence("unlisted"),
    do: "Members can give people outside the team a link. Public pastes become link-only."

  def sharing_policy_sentence("public"),
    do: "Members can share a link or make a paste public."

  def sharing_policy_sentence(_policy), do: nil

  ## Who can join (per workspace)

  def join_policy_options, do: Enum.map(@join_policies, &{join_policy_label(&1), &1})

  def join_policy_label("open"), do: "Anyone in the organization"
  def join_policy_label("private"), do: "Invite only"
  def join_policy_label(visibility), do: visibility

  def join_policy_sentence("open"),
    do: "Everyone in the organization can find and join this workspace."

  def join_policy_sentence("private"),
    do: "Only people an owner adds can find or open this workspace."

  def join_policy_sentence(_visibility), do: nil

  def join_policy_icon("private"), do: "hero-lock-closed"
  def join_policy_icon(_visibility), do: "hero-building-office-2"
end
