defmodule Textbin.Pastes do
  @moduledoc """
  The Pastes context.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste
  alias Textbin.Pastes.PendingUpload
  alias Textbin.Repo
  alias Textbin.Storage
  alias Textbin.Storage.IntegrityError
  alias Textbin.Organizations
  alias Textbin.Organizations.Organization
  alias Textbin.Organizations.OrganizationMembership
  alias Textbin.Organizations.Workspace
  alias Textbin.Organizations.WorkspaceMembership
  alias Textbin.Organizations.Policy

  require Logger

  @default_inline_paste_bytes 8_192
  @default_max_paste_bytes 1_048_576

  def list_pastes(%Scope{user: %User{}} = scope) do
    case list_pastes_with_access(scope) do
      {:ok, pastes} ->
        pastes

      {:error, :not_found} ->
        []
    end
  end

  def list_pastes_with_access(%Scope{user: %User{}} = scope) do
    with_locked_read_workspace(scope, fn workspace ->
      now = Paste.utc_now_ms()

      Repo.all(
        from p in Paste,
          where:
            p.workspace_id == ^workspace.id and is_nil(p.removed_at) and
              (is_nil(p.expires_at) or p.expires_at > ^now),
          order_by: [desc: p.inserted_at]
      )
      |> Enum.map(&load_data/1)
    end)
  end

  def list_pastes_with_access(_scope), do: {:error, :not_found}

  def list_paste_metadata(%Scope{user: %User{}} = scope) do
    case with_locked_read_workspace(scope, fn workspace ->
           now = Paste.utc_now_ms()

           Repo.all(
             from p in Paste,
               where:
                 p.workspace_id == ^workspace.id and is_nil(p.removed_at) and
                   (is_nil(p.expires_at) or p.expires_at > ^now),
               select:
                 struct(p, [
                   :id,
                   :title,
                   :reference_url,
                   :storage_key,
                   :size_bytes,
                   :sha256,
                   :content_type,
                   :syntax_highlight,
                   :audience,
                   :expires_at,
                   :workspace_id,
                   :created_by_user_id,
                   :inserted_at,
                   :updated_at
                 ]),
               order_by: [desc: p.inserted_at]
           )
           |> preload_author()
         end) do
      {:ok, pastes} ->
        pastes

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Loads the author so lists and headings can name who created a paste.
  """
  def preload_author(paste_or_pastes), do: Repo.preload(paste_or_pastes, :created_by_user)

  @search_limit 50
  @excerpt_context 60

  @doc """
  Searches active pastes in every workspace the user belongs to, newest first.

  Titles always match. Content matches only for text kept inline in the
  database; larger pastes live in object storage and are found by title.
  Removed pastes and binary content are never searched.

  Each result carries the paste (with author), its workspace and
  organization, and an excerpt `{before, match, after}` around the first
  content match, or nil when only the title matched.
  """
  def search_pastes(scope, query, opts \\ [])

  def search_pastes(%Scope{user: %User{id: user_id}}, query, opts) when is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      term ->
        user_id
        |> search_query("%" <> escape_like(term) <> "%", Keyword.get(opts, :limit, @search_limit))
        |> Repo.all()
        |> Enum.map(fn {paste, workspace, organization} ->
          %{
            paste: preload_author(paste),
            workspace: workspace,
            organization: organization,
            excerpt: excerpt(paste.data, term)
          }
        end)
    end
  end

  def search_pastes(_scope, _query, _opts), do: []

  defp search_query(user_id, pattern, limit) do
    now = Paste.utc_now_ms()

    from(p in Paste,
      join: w in Workspace,
      on: w.id == p.workspace_id,
      join: o in Organization,
      on: o.id == w.organization_id,
      join: wm in WorkspaceMembership,
      on: wm.workspace_id == w.id and wm.user_id == ^user_id,
      join: om in OrganizationMembership,
      on: om.organization_id == o.id and om.user_id == ^user_id,
      where: is_nil(w.deletion_requested_at) and is_nil(o.deletion_requested_at),
      where: ilike(p.title, ^pattern) or ilike(p.data, ^pattern),
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^limit,
      select: {p, w, o}
    )
    |> active_pastes(now)
    |> textual_pastes()
  end

  defp textual_pastes(query) do
    where(
      query,
      [p],
      like(p.content_type, "text/%") or
        p.content_type in ^ContentType.textual_application_types() or
        like(p.content_type, "application/%+json") or like(p.content_type, "application/%+xml")
    )
  end

  defp escape_like(term), do: String.replace(term, ["\\", "%", "_"], &("\\" <> &1))

  # Case-insensitive search for the term inside the text, returning a short
  # window around the first hit. Matching on downcased copies keeps grapheme
  # boundaries intact for the slices.
  defp excerpt(data, term) when is_binary(data) do
    if String.valid?(data) do
      graphemes = String.graphemes(data)
      lowered = Enum.map(graphemes, &String.downcase/1)
      needle = term |> String.downcase() |> String.graphemes()

      case find_sublist(lowered, length(lowered), needle, length(needle), 0) do
        nil ->
          nil

        index ->
          length = length(needle)
          start = max(index - @excerpt_context, 0)

          {
            leading(start) <> squash(Enum.slice(graphemes, start, index - start)),
            Enum.join(Enum.slice(graphemes, index, length)),
            squash(Enum.slice(graphemes, index + length, @excerpt_context)) <>
              trailing(index + length + @excerpt_context, length(graphemes))
          }
      end
    end
  end

  defp excerpt(_data, _term), do: nil

  defp find_sublist(_haystack, remaining, _needle, needed, _index) when remaining < needed,
    do: nil

  defp find_sublist([_ | rest] = haystack, remaining, needle, needed, index) do
    if prefix?(haystack, needle),
      do: index,
      else: find_sublist(rest, remaining - 1, needle, needed, index + 1)
  end

  defp prefix?(_haystack, []), do: true
  defp prefix?([same | haystack], [same | needle]), do: prefix?(haystack, needle)
  defp prefix?(_haystack, _needle), do: false

  defp squash(graphemes), do: graphemes |> Enum.join() |> String.replace(~r/\s+/u, " ")
  defp leading(0), do: ""
  defp leading(_start), do: "…"
  defp trailing(stop, total) when stop < total, do: "…"
  defp trailing(_stop, _total), do: ""

  def get_paste(%Scope{user: %User{}} = scope, id) when is_binary(id) do
    with {:ok, paste_id} <- Ecto.UUID.cast(id),
         {:ok, paste} <-
           with_locked_read_workspace(scope, fn workspace ->
             now = Paste.utc_now_ms()

             Repo.one(
               from p in Paste,
                 where:
                   p.id == ^paste_id and p.workspace_id == ^workspace.id and
                     is_nil(p.removed_at) and (is_nil(p.expires_at) or p.expires_at > ^now)
             )
             |> load_data()
           end) do
      paste
    else
      _error ->
        nil
    end
  end

  def get_paste(_scope, _id), do: nil

  def get_paste!(%Scope{user: %User{}} = scope, id) do
    case get_paste(scope, id) do
      %Paste{} = paste ->
        paste

      nil ->
        raise Ecto.NoResultsError, queryable: Paste
    end
  end

  def get_shared_paste(current_scope, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, paste_id} ->
        with_locked_shared_paste(current_scope, paste_id)

      :error ->
        nil
    end
  end

  def get_shared_paste(_current_scope, _id), do: nil

  defp with_locked_shared_paste(current_scope, paste_id) do
    operation = fn ->
      query = shared_paste_query(current_scope, paste_id)

      with %Paste{workspace_id: workspace_id} <- Repo.one(query),
           %Workspace{deletion_requested_at: nil} <- lock_workspace(workspace_id, "FOR SHARE") do
        query |> Repo.one() |> load_data()
      else
        _error -> nil
      end
    end

    run_shared_paste_operation(operation, Repo.in_transaction?())
  end

  defp run_shared_paste_operation(operation, true), do: operation.()

  defp run_shared_paste_operation(operation, false) do
    case Repo.transact(fn -> {:ok, operation.()} end) do
      {:ok, paste} -> paste
      {:error, _reason} -> nil
    end
  end

  defp shared_paste_query(current_scope, paste_id) do
    now = Paste.utc_now_ms()

    Paste
    |> where([paste], paste.id == ^paste_id)
    |> where([paste], is_nil(paste.removed_at))
    |> where([paste], is_nil(paste.expires_at) or paste.expires_at > ^now)
    |> allow_shared_access(current_scope)
  end

  def create_paste(%Scope{user: %User{} = user} = scope, attrs \\ %{}) do
    with {:ok, workspace} <- authorized_workspace(scope) do
      attrs =
        attrs
        |> attrs_with_defaults(user, ContentType.text_safe?(attr_data(attrs)))

      paste = new_paste(user, workspace.id)

      changeset =
        paste
        |> Paste.changeset(attrs)
        |> validate_audience(workspace)
        |> validate_data_size()
        |> with_derived_title(fn -> Paste.derive_title(attr_data(attrs)) end)

      if changeset.valid? do
        store_paste(scope, changeset)
      else
        {:error, changeset}
      end
    end
  end

  def create_paste_from_file(
        %Scope{user: %User{} = user} = scope,
        path,
        %{size_bytes: size_bytes, sha256: sha256} = metadata,
        attrs \\ %{}
      )
      when is_binary(path) and is_integer(size_bytes) and is_binary(sha256) do
    with {:ok, workspace} <- authorized_workspace(scope) do
      text_safe? = match?({:ok, true}, ContentType.text_safe_file(path))
      attrs = attrs_with_defaults(attrs, user, text_safe?)
      paste = new_paste(user, workspace.id)
      storage_key = "pastes/#{paste.id}"

      changeset =
        %{paste | storage_key: storage_key}
        |> Paste.changeset(attrs)
        |> validate_audience(workspace)
        |> validate_uploaded_file(path, metadata)
        |> with_derived_title(fn ->
          # Validate the upload size first, bounding even a single long line by
          # the paste limit; do not load the entire file just to find its title.
          path |> File.stream!() |> Enum.find_value(&Paste.derive_title/1)
        end)

      if changeset.valid? do
        store_paste_file(scope, changeset, path, metadata)
      else
        {:error, changeset}
      end
    end
  end

  @doc """
  Removes a paste the caller manages. The row and its content stay put so it
  can be restored from the workspace's Deleted tab until the recovery window
  ends; every shared link stops working immediately.
  """
  def delete_paste(%Scope{user: %User{} = user} = scope, %Paste{} = paste) do
    case Ecto.UUID.cast(paste.id) do
      {:ok, paste_id} ->
        paste_id
        |> manageable_paste_query(user.id)
        |> scope_to_workspace(scope)
        |> active_pastes(Paste.utc_now_ms())
        |> remove_paste_matching(user)

      :error ->
        {:error, :not_found}
    end
  end

  def delete_paste(_scope, %Paste{}), do: {:error, :not_found}

  def delete_personal_paste(%Scope{user: %User{} = user}, %Paste{} = paste) do
    workspace_id = personal_workspace_id(user)

    case Ecto.UUID.cast(paste.id) do
      {:ok, paste_id} ->
        from(candidate in Paste,
          where: candidate.id == ^paste_id and candidate.workspace_id == ^workspace_id
        )
        |> active_pastes(Paste.utc_now_ms())
        |> remove_paste_matching(user)

      :error ->
        {:error, :not_found}
    end
  end

  def delete_personal_paste(_scope, %Paste{}), do: {:error, :not_found}

  def manage_paste?(%Scope{user: %User{id: user_id}}, %Paste{id: paste_id}) do
    paste_id
    |> manageable_paste_query(user_id)
    |> Repo.exists?()
  end

  def manage_paste?(_scope, _paste), do: false

  @doc """
  Lists the workspace's removed pastes that can still be restored, newest
  removal first. Content is not loaded.
  """
  def list_removed_pastes(%Scope{user: %User{}} = scope) do
    case with_locked_read_workspace(scope, fn workspace ->
           now = Paste.utc_now_ms()

           from(p in Paste,
             where: p.workspace_id == ^workspace.id,
             order_by: [
               desc: fragment("coalesce(?, ?)", p.removed_at, p.expires_at),
               desc: p.id
             ],
             select:
               struct(p, [
                 :id,
                 :title,
                 :reference_url,
                 :content_type,
                 :syntax_highlight,
                 :audience,
                 :expires_at,
                 :removed_at,
                 :removal_reason,
                 :removed_by_user_id,
                 :workspace_id,
                 :created_by_user_id,
                 :inserted_at,
                 :updated_at
               ])
           )
           |> restorable_pastes(workspace, now)
           |> Repo.all()
           |> Repo.preload([:created_by_user, :removed_by_user])
         end) do
      {:ok, pastes} -> pastes
      {:error, :not_found} -> []
    end
  end

  def list_removed_pastes(_scope), do: []

  @doc """
  Returns a removed paste the caller could restore, for the page a removed
  paste's link shows its owner. Content is not loaded.
  """
  def get_removed_paste(%Scope{user: %User{id: user_id}} = scope, id) when is_binary(id) do
    with {:ok, paste_id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- authorized_workspace(scope) do
      paste_id
      |> manageable_paste_query(user_id)
      |> where([paste], paste.workspace_id == ^workspace.id)
      |> restorable_pastes(workspace, Paste.utc_now_ms())
      |> Repo.one()
      |> Repo.preload([:created_by_user, :removed_by_user])
    else
      _error -> nil
    end
  end

  def get_removed_paste(_scope, _id), do: nil

  @doc """
  Finds which workspace holds a removed paste the caller could restore, so
  its shared link can send them to the restore page. Returns nil otherwise.
  """
  def removed_paste_workspace_id(%Scope{user: %User{id: user_id}}, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, paste_id} ->
        now = Paste.utc_now_ms()

        paste_id
        |> manageable_paste_query(user_id)
        |> where(
          [paste],
          (not is_nil(paste.removed_at) and paste.removal_reason == "deleted") or
            (is_nil(paste.removed_at) and paste.expires_at <= ^now)
        )
        |> select([paste], paste.workspace_id)
        |> Repo.one()

      :error ->
        nil
    end
  end

  def removed_paste_workspace_id(_scope, _id), do: nil

  @doc """
  Brings a removed paste back. Restoring an expired paste clears its expiry,
  because otherwise it would disappear again at once.
  """
  def restore_paste(%Scope{user: %User{}} = scope, paste_id) when is_binary(paste_id) do
    case Ecto.UUID.cast(paste_id) do
      {:ok, paste_id} -> Repo.transact(fn -> restore_paste_in_transaction(scope, paste_id) end)
      :error -> {:error, :not_found}
    end
  end

  def restore_paste(_scope, _paste_id), do: {:error, :not_found}

  @doc """
  Hard-deletes a removed paste right away instead of waiting for the end of
  the recovery window. Active pastes must be deleted first.
  """
  def purge_paste(%Scope{user: %User{}} = scope, paste_id) when is_binary(paste_id) do
    with {:ok, paste_id} <- Ecto.UUID.cast(paste_id),
         {:ok, paste} <-
           Repo.transact(fn -> claim_manual_purge(scope, paste_id) end),
         :ok <- delete_stored_data(paste) do
      Repo.delete(paste, allow_stale: true)
    else
      {:error, _reason} = error -> error
      _not_found -> {:error, :not_found}
    end
  end

  def purge_paste(_scope, _paste_id), do: {:error, :not_found}

  defp claim_manual_purge(%Scope{user: %User{id: user_id}} = scope, paste_id) do
    with {:ok, workspace} <- lock_authorized_workspace(scope, scope_workspace_id(scope)) do
      now = Paste.utc_now_ms()
      restorable = restorable_pastes(Paste, workspace, now) |> select([p], p.id)

      paste_id
      |> manageable_paste_query(user_id)
      |> where([p], p.workspace_id == ^workspace.id)
      |> where([p], p.removal_reason == "purging" or p.id in subquery(restorable))
      |> claim_purge(now)
    end
  end

  # Commit the irreversible intent before touching object storage. Restore uses
  # the same workspace/paste lock order and excludes this durable retry state.
  defp claim_purge(query, now) do
    case query |> lock("FOR UPDATE") |> Repo.one() do
      %Paste{} = paste ->
        paste
        |> Ecto.Changeset.change(
          removed_at: paste.removed_at || paste.expires_at || now,
          removal_reason: "purging"
        )
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  defp restore_paste_in_transaction(%Scope{user: %User{id: user_id}} = scope, paste_id) do
    now = Paste.utc_now_ms()

    with {:ok, workspace} <- lock_authorized_workspace(scope, scope_workspace_id(scope)),
         %Paste{} = paste <-
           paste_id
           |> manageable_paste_query(user_id)
           |> where([paste], paste.workspace_id == ^workspace.id)
           |> restorable_pastes(workspace, now)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      paste
      |> Ecto.Changeset.change(
        removed_at: nil,
        removal_reason: nil,
        removed_by_user_id: nil,
        expires_at: expiry_after_restore(paste.expires_at, now)
      )
      |> Repo.update()
    else
      _error -> {:error, :not_found}
    end
  end

  defp expiry_after_restore(nil, _now), do: nil

  defp expiry_after_restore(expires_at, now) do
    if DateTime.after?(expires_at, now), do: expires_at, else: nil
  end

  defp scope_to_workspace(query, %Scope{workspace: %{id: workspace_id}}),
    do: where(query, [paste], paste.workspace_id == ^workspace_id)

  defp scope_to_workspace(query, _scope), do: query

  defp active_pastes(query, now) do
    where(
      query,
      [paste],
      is_nil(paste.removed_at) and (is_nil(paste.expires_at) or paste.expires_at > ^now)
    )
  end

  # Deleted or expired pastes still inside the workspace's recovery window.
  # Moderated pastes never qualify.
  defp restorable_pastes(query, %Workspace{recovery_window_days: window_days}, now) do
    where(
      query,
      [paste],
      ((not is_nil(paste.removed_at) and paste.removal_reason == "deleted") or
         (is_nil(paste.removed_at) and paste.expires_at <= ^now)) and
        fragment(
          "coalesce(?, ?) + make_interval(days => ?) > ?",
          paste.removed_at,
          paste.expires_at,
          ^window_days,
          ^now
        )
    )
  end

  defp remove_paste_matching(query, %User{id: user_id}) do
    Repo.transact(fn ->
      case query |> lock("FOR UPDATE") |> Repo.one() do
        %Paste{} = paste ->
          paste
          |> Ecto.Changeset.change(
            removed_at: Paste.utc_now_ms(),
            removal_reason: "deleted",
            removed_by_user_id: user_id
          )
          |> Repo.update()

        nil ->
          {:error, :not_found}
      end
    end)
  end

  defp manageable_paste_query(paste_id, user_id) do
    owner_role = Policy.workspace_owner_role()

    from paste in Paste,
      join: membership in WorkspaceMembership,
      on: membership.workspace_id == paste.workspace_id,
      where:
        paste.id == ^paste_id and membership.user_id == ^user_id and
          (membership.role == ^owner_role or paste.created_by_user_id == ^user_id)
  end

  @doc """
  Hard-deletes one bounded batch of pastes whose time is up and returns the
  number deleted:

    * deleted or expired pastes once their workspace's recovery window ends
    * moderated pastes, and every paste of a workspace being deleted, at once

  The oldest removals are handled first so a backlog drains predictably. A
  paste whose stored content cannot be deleted is kept and retried later.
  """
  @spec purge_removed_pastes(keyword()) :: non_neg_integer()
  def purge_removed_pastes(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &Paste.utc_now_ms/0)
    limit = Keyword.get(opts, :limit, 500)

    if !is_integer(limit) or limit <= 0 do
      raise ArgumentError, ":limit must be a positive integer"
    end

    due_pastes =
      due_pastes(now)
      |> order_by([p, w],
        asc: fragment("coalesce(?, ?, ?)", p.removed_at, p.expires_at, w.deletion_requested_at),
        asc: p.id
      )
      |> limit(^limit)
      |> Repo.all()

    deletable_ids =
      for candidate <- due_pastes,
          {:ok, paste} <- [claim_due_purge(candidate, now)],
          delete_stored_data(paste) == :ok,
          do: paste.id

    {deleted_count, nil} = Repo.delete_all(from p in Paste, where: p.id in ^deletable_ids)

    deleted_count
  end

  defp due_pastes(now) do
    from p in Paste,
      join: w in Workspace,
      on: w.id == p.workspace_id,
      where:
        not is_nil(w.deletion_requested_at) or p.removal_reason in ["moderated", "purging"] or
          fragment(
            "coalesce(?, ?) + make_interval(days => ?) <= ?",
            p.removed_at,
            p.expires_at,
            w.recovery_window_days,
            ^now
          )
  end

  defp claim_due_purge(candidate, now) do
    Repo.transact(fn ->
      # Recheck eligibility after locking: a restore or window change may have
      # won since this bounded batch was selected.
      case lock_workspace(candidate.workspace_id, "FOR UPDATE") do
        %Workspace{} ->
          due_pastes(now)
          |> where([p], p.id == ^candidate.id)
          |> claim_purge(now)

        nil ->
          {:error, :not_found}
      end
    end)
  end

  def delete_workspace_pastes(workspace_id) when is_binary(workspace_id) do
    pastes = Repo.all(from paste in Paste, where: paste.workspace_id == ^workspace_id)

    deletable_ids = for paste <- pastes, delete_stored_data(paste) == :ok, do: paste.id
    Repo.delete_all(from paste in Paste, where: paste.id in ^deletable_ids)

    if Repo.exists?(from paste in Paste, where: paste.workspace_id == ^workspace_id) do
      {:error, :storage_cleanup_failed}
    else
      :ok
    end
  end

  def load_data(nil), do: nil

  def load_data(%Paste{data: data} = paste) when is_binary(data) do
    verify_content!(paste, data)
  end

  def load_data(%Paste{storage_key: storage_key} = paste) when is_binary(storage_key) do
    data = Storage.get!(storage_key)
    paste = verify_content!(paste, data)
    %{paste | data: data}
  end

  defp verify_content!(%Paste{size_bytes: nil, sha256: nil} = paste, _data), do: paste

  defp verify_content!(%Paste{} = paste, data) do
    if paste.size_bytes == byte_size(data) and
         paste.sha256 == :crypto.hash(:sha256, data) do
      paste
    else
      raise IntegrityError, storage_key: paste.storage_key
    end
  end

  def change_paste(%Scope{user: %User{} = user} = scope, %Paste{} = paste, attrs \\ %{}) do
    paste = %{
      paste
      | workspace_id: paste.workspace_id || scope_workspace_id(scope),
        created_by_user_id: paste.created_by_user_id || user.id
    }

    changeset = Paste.changeset(paste, attrs_with_audience(attrs))

    case authorized_workspace(scope) do
      {:ok, workspace} -> validate_audience(changeset, workspace)
      {:error, :not_found} -> changeset
    end
  end

  def prepare_paste(%Scope{user: %User{} = user} = scope),
    do: new_paste(user, scope_workspace_id(scope))

  defp new_paste(user, workspace_id) do
    %Paste{
      id: Ecto.UUID.generate(),
      workspace_id: workspace_id,
      created_by_user_id: user.id
    }
  end

  defp authorized_workspace(%Scope{workspace: %{id: workspace_id}} = scope) do
    case Organizations.resolve_workspace_scope(scope, workspace_id) do
      {:ok, %{workspace: %Workspace{deletion_requested_at: nil} = workspace}} -> {:ok, workspace}
      {:ok, _resolved_scope} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp authorized_workspace(%Scope{user: user}) do
    case Organizations.get_personal_default_workspace!(user) do
      %Workspace{deletion_requested_at: nil} = workspace -> {:ok, workspace}
      _workspace -> {:error, :not_found}
    end
  end

  defp scope_workspace_id(%Scope{workspace: %{id: workspace_id}}), do: workspace_id
  defp scope_workspace_id(%Scope{user: user}), do: personal_workspace_id(user)

  defp personal_workspace_id(user) do
    Organizations.get_personal_default_workspace!(user).id
  end

  defp store_paste(scope, changeset) do
    data = Ecto.Changeset.get_field(changeset, :data)
    metadata = content_metadata(data)

    if inline_data?(changeset, data) do
      insert_inline_paste(scope, changeset, metadata, data)
    else
      store_blob_paste(scope, changeset, data)
    end
  end

  defp store_blob_paste(scope, changeset, data) do
    storage_key = "pastes/#{changeset.data.id}"

    with_pending_upload(storage_key, changeset, fn ->
      case Storage.put(storage_key, data) do
        {:ok, stored_metadata} ->
          insert_stored_paste(scope, changeset, storage_key, stored_metadata, data)

        {:error, reason} ->
          storage_error(changeset, storage_key, reason)
      end
    end)
  end

  defp store_paste_file(scope, changeset, path, metadata) do
    if inline_size?(metadata) do
      store_inline_file(scope, changeset, path, metadata)
    else
      store_blob_file(scope, changeset, path, metadata)
    end
  end

  defp store_inline_file(scope, changeset, path, expected_metadata) do
    with {:ok, data} <- File.read(path),
         metadata = content_metadata(data),
         true <- metadata == expected_metadata do
      if inline_data?(changeset, data) do
        insert_inline_paste(scope, changeset, metadata, data)
      else
        store_blob_file(scope, changeset, path, metadata)
      end
    else
      false ->
        inline_metadata_error(changeset)

      {:error, _reason} ->
        {:error, Ecto.Changeset.add_error(changeset, :data, "could not be read")}
    end
  end

  defp store_blob_file(scope, changeset, path, metadata) do
    storage_key = changeset.data.storage_key

    with_pending_upload(storage_key, changeset, fn ->
      case Storage.put_file(storage_key, path, metadata) do
        {:ok, stored_metadata} when stored_metadata == metadata ->
          insert_stored_paste(scope, changeset, storage_key, stored_metadata, nil)

        {:ok, _stored_metadata} ->
          storage_metadata_error(changeset, storage_key)

        {:error, :metadata_mismatch} ->
          storage_metadata_error(changeset, storage_key)

        {:error, reason} ->
          storage_error(changeset, storage_key, reason)
      end
    end)
  end

  defp insert_inline_paste(scope, changeset, metadata, data) do
    changeset =
      changeset
      |> Ecto.Changeset.put_change(:data, data)
      |> Ecto.Changeset.put_change(:storage_key, nil)
      |> Ecto.Changeset.put_change(:size_bytes, metadata.size_bytes)
      |> Ecto.Changeset.put_change(:sha256, metadata.sha256)

    Repo.transact(fn ->
      with {:ok, workspace} <- lock_authorized_workspace(scope, changeset.data.workspace_id) do
        changeset
        |> validate_audience(workspace)
        |> Repo.insert()
      end
    end)
  end

  defp with_storage_compensation(storage_key, operation) do
    try do
      operation.()
    rescue
      exception ->
        delete_storage_key(storage_key)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        delete_storage_key(storage_key)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp with_pending_upload(storage_key, changeset, operation) do
    case Repo.insert(%PendingUpload{storage_key: storage_key}) do
      {:ok, _pending_upload} ->
        with_storage_compensation(storage_key, operation)

      {:error, pending_changeset} ->
        Logger.error("Failed to journal paste upload: #{inspect(pending_changeset.errors)}")
        {:error, Ecto.Changeset.add_error(changeset, :data, "could not be stored")}
    end
  end

  defp insert_stored_paste(scope, changeset, storage_key, metadata, data) do
    stored_changeset =
      changeset
      |> Ecto.Changeset.put_change(:data, nil)
      |> Ecto.Changeset.put_change(:storage_key, storage_key)
      |> Ecto.Changeset.put_change(:size_bytes, metadata.size_bytes)
      |> Ecto.Changeset.put_change(:sha256, metadata.sha256)

    Repo.transact(fn ->
      with {:ok, workspace} <- lock_authorized_workspace(scope, changeset.data.workspace_id),
           {:ok, paste} <-
             stored_changeset
             |> validate_audience(workspace)
             |> Repo.insert(),
           {1, nil} <-
             Repo.delete_all(
               from upload in PendingUpload,
                 where: upload.storage_key == ^storage_key and is_nil(upload.claimed_at)
             ) do
        {:ok, paste}
      else
        {:error, reason} -> {:error, reason}
        {0, nil} -> {:error, :upload_claimed}
      end
    end)
    |> finalize_insert(stored_changeset, storage_key, data)
  end

  defp storage_error(changeset, storage_key, reason) do
    # A failed HTTP response can be ambiguous: the object store may have
    # committed the PUT before the connection failed.
    delete_storage_key(storage_key)
    Logger.error("Failed to store paste content: #{inspect(reason)}")
    {:error, Ecto.Changeset.add_error(changeset, :data, "could not be stored")}
  end

  defp storage_metadata_error(changeset, storage_key) do
    delete_storage_key(storage_key)
    {:error, Ecto.Changeset.add_error(changeset, :data, "does not match the uploaded file")}
  end

  defp inline_metadata_error(changeset) do
    {:error, Ecto.Changeset.add_error(changeset, :data, "does not match the uploaded file")}
  end

  defp finalize_insert({:ok, paste}, _changeset, _storage_key, data),
    do: {:ok, %{paste | data: data}}

  defp finalize_insert({:error, %Ecto.Changeset{}} = error, _changeset, storage_key, _data) do
    delete_storage_key(storage_key)
    error
  end

  defp finalize_insert({:error, :upload_claimed}, changeset, storage_key, _data) do
    delete_storage_key(storage_key)
    {:error, Ecto.Changeset.add_error(changeset, :data, "could not be finalized")}
  end

  defp delete_stored_data(%Paste{storage_key: storage_key}), do: delete_storage_key(storage_key)

  defp delete_storage_key(nil), do: :ok

  defp delete_storage_key(storage_key) do
    case Storage.delete(storage_key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete stored paste content: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp validate_data_size(changeset) do
    case Ecto.Changeset.get_field(changeset, :data) do
      data when is_binary(data) -> validate_uploaded_size(changeset, byte_size(data))
      _data -> changeset
    end
  end

  defp validate_uploaded_file(changeset, path, %{size_bytes: size_bytes, sha256: sha256}) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: ^size_bytes}}
      when size_bytes >= 0 and byte_size(sha256) == 32 ->
        validate_uploaded_size(changeset, size_bytes)

      {:ok, _stat} ->
        Ecto.Changeset.add_error(changeset, :data, "does not match the uploaded file")

      {:error, _reason} ->
        Ecto.Changeset.add_error(changeset, :data, "could not be read")
    end
  end

  defp validate_uploaded_size(changeset, size_bytes) do
    cond do
      size_bytes == 0 and !Keyword.has_key?(changeset.errors, :data) ->
        Ecto.Changeset.add_error(changeset, :data, "can't be blank")

      size_bytes > max_paste_bytes() ->
        Ecto.Changeset.add_error(
          changeset,
          :data,
          "must be at most #{max_paste_bytes()} bytes"
        )

      true ->
        changeset
    end
  end

  defp max_paste_bytes do
    Application.get_env(:textbin, :max_paste_bytes, @default_max_paste_bytes)
  end

  defp inline_size?(metadata), do: metadata.size_bytes <= inline_paste_bytes()

  defp inline_data?(changeset, data) do
    byte_size(data) <= inline_paste_bytes() and ContentType.text_safe?(data) and
      changeset |> Ecto.Changeset.get_field(:content_type) |> ContentType.textual?()
  end

  defp inline_paste_bytes do
    Application.get_env(:textbin, :inline_paste_bytes, @default_inline_paste_bytes)
  end

  defp content_metadata(data) do
    %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
  end

  defp attrs_with_defaults(attrs, user, text_safe?) do
    attrs
    |> attrs_with_default_ttl(user)
    |> attrs_with_audience()
    |> attrs_with_content_type(text_safe?)
  end

  defp attrs_with_content_type(attrs, text_safe?) do
    content_type = Map.get(attrs, "content_type") || Map.get(attrs, :content_type)

    Map.put(
      attrs,
      attr_key(attrs, "content_type", :content_type),
      ContentType.normalize(content_type, text_safe?)
    )
  end

  defp attr_data(attrs), do: Map.get(attrs, "data") || Map.get(attrs, :data)

  # Only creation derives a title. Live validation leaves the field alone so the
  # form does not overwrite what the person is typing.
  defp with_derived_title(changeset, derive) do
    if changeset.valid? and is_nil(Ecto.Changeset.get_field(changeset, :title)) and
         ContentType.textual?(Ecto.Changeset.get_field(changeset, :content_type)) do
      Ecto.Changeset.put_change(changeset, :title, derive.())
    else
      changeset
    end
  end

  defp attrs_with_default_ttl(attrs, user) do
    if ttl_provided?(attrs) do
      attrs
    else
      Map.put(attrs, default_ttl_key(attrs), user.default_paste_ttl || "never")
    end
  end

  defp default_ttl_key(attrs) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: "expires_in", else: :expires_in
  end

  defp attrs_with_audience(attrs) when is_map(attrs) do
    Map.put(attrs, attr_key(attrs, "audience", :audience), audience_value(attrs) || "workspace")
  end

  defp audience_value(attrs) do
    case Map.get(attrs, "audience") || Map.get(attrs, :audience) ||
           Map.get(attrs, "visibility") || Map.get(attrs, :visibility) do
      "" -> nil
      "private" -> "workspace"
      audience -> audience
    end
  end

  defp validate_audience(changeset, workspace) do
    audience = Ecto.Changeset.get_field(changeset, :audience)

    if Keyword.has_key?(changeset.errors, :audience) or
         audience_allowed?(audience, workspace.external_sharing_policy) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :audience, "is disabled by the workspace policy")
    end
  end

  defp audience_allowed?("workspace", _policy), do: true
  defp audience_allowed?("unlisted", policy), do: policy in ["unlisted", "public"]
  defp audience_allowed?("public", "public"), do: true
  defp audience_allowed?(_audience, _policy), do: false

  defp lock_authorized_workspace(scope, workspace_id) do
    lock_authorized_workspace(scope, workspace_id, "FOR UPDATE")
  end

  defp lock_authorized_workspace(scope, workspace_id, lock) do
    workspace = lock_workspace(workspace_id, lock)

    with %Workspace{} <- workspace,
         {:ok, %Workspace{id: ^workspace_id} = current_workspace} <- authorized_workspace(scope) do
      {:ok, current_workspace}
    else
      _error -> {:error, :not_found}
    end
  end

  defp lock_workspace(workspace_id, "FOR UPDATE") do
    Repo.one(
      from workspace in Workspace,
        where: workspace.id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_workspace(workspace_id, "FOR SHARE") do
    Repo.one(
      from workspace in Workspace,
        where: workspace.id == ^workspace_id,
        lock: "FOR SHARE"
    )
  end

  # Keep membership authorization valid until inline or external paste data is
  # loaded. Membership mutations take an exclusive workspace lock, so either
  # the read completes first or observes the committed revocation.
  defp with_locked_read_workspace(scope, operation) do
    transaction = fn ->
      with {:ok, workspace} <-
             lock_authorized_workspace(scope, scope_workspace_id(scope), "FOR SHARE") do
        {:ok, operation.(workspace)}
      end
    end

    if Repo.in_transaction?(), do: transaction.(), else: Repo.transact(transaction)
  end

  defp attr_key(attrs, string_key, atom_key) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: string_key, else: atom_key
  end

  defp ttl_provided?(attrs) when is_map(attrs) do
    ttl_value(attrs) not in [nil, ""]
  end

  defp ttl_provided?(_attrs), do: false

  defp ttl_value(attrs) do
    Map.get(attrs, "expires_in") || Map.get(attrs, :expires_in) || Map.get(attrs, "ttl") ||
      Map.get(attrs, :ttl)
  end

  defp allow_shared_access(query, %Scope{user: %User{id: user_id}}) do
    workspace_ids =
      from membership in WorkspaceMembership,
        where: membership.user_id == ^user_id,
        select: membership.workspace_id

    query
    |> join(:inner, [paste], workspace in Workspace, on: workspace.id == paste.workspace_id)
    |> where([_paste, workspace], is_nil(workspace.deletion_requested_at))
    |> where(
      [paste, workspace],
      paste.workspace_id in subquery(workspace_ids) or
        (paste.audience == "unlisted" and
           workspace.external_sharing_policy in ["unlisted", "public"]) or
        (paste.audience == "public" and workspace.external_sharing_policy == "public")
    )
  end

  defp allow_shared_access(query, nil) do
    query
    |> join(:inner, [paste], workspace in Workspace, on: workspace.id == paste.workspace_id)
    |> where([_paste, workspace], is_nil(workspace.deletion_requested_at))
    |> where(
      [paste, workspace],
      (paste.audience == "unlisted" and
         workspace.external_sharing_policy in ["unlisted", "public"]) or
        (paste.audience == "public" and workspace.external_sharing_policy == "public")
    )
  end
end
