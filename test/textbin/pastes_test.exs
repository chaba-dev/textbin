defmodule Textbin.PastesTest do
  use Textbin.DataCase, async: true

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  import Textbin.AccountsFixtures

  describe "pastes" do
    @valid_attrs %{data: "some data"}
    @invalid_attrs %{data: nil}

    setup do
      user = user_fixture()
      %{scope: user_scope_fixture(user), other_scope: user_scope_fixture()}
    end

    test "list_pastes/1 returns scoped pastes", %{scope: scope, other_scope: other_scope} do
      {:ok, older_paste} = Pastes.create_paste(scope, @valid_attrs)
      {:ok, newer_paste} = Pastes.create_paste(scope, %{data: "newer data"})
      {:ok, other_paste} = Pastes.create_paste(other_scope, %{data: "other user data"})

      paste_ids = Pastes.list_pastes(scope) |> Enum.map(& &1.id)

      assert older_paste.id in paste_ids
      assert newer_paste.id in paste_ids
      refute other_paste.id in paste_ids
    end

    test "get_paste!/2 returns the scoped paste with given id", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, @valid_attrs)

      assert Pastes.get_paste!(scope, paste.id).id == paste.id
    end

    test "get_paste!/2 raises for another user's paste", %{scope: scope, other_scope: other_scope} do
      {:ok, paste} = Pastes.create_paste(other_scope, @valid_attrs)

      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
    end

    test "create_paste/2 with valid data creates a paste", %{scope: scope} do
      assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, @valid_attrs)
      assert paste.data == "some data"
      assert paste.syntax_highlight == "plain"
      assert paste.user_id == scope.user.id
      assert {microsecond, 6} = paste.inserted_at.microsecond
      assert rem(microsecond, 1000) == 0
    end

    test "create_paste/2 stores the syntax highlight", %{scope: scope} do
      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{data: "IO.puts(:ok)", syntax_highlight: "elixir"})

      assert paste.data == "IO.puts(:ok)"
      assert paste.syntax_highlight == "elixir"
    end

    test "create_paste/2 with invalid data returns error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} = Pastes.create_paste(scope, @invalid_attrs)
    end

    test "delete_paste/2 deletes the scoped paste", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, @valid_attrs)

      assert {:ok, %Paste{}} = Pastes.delete_paste(scope, paste)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
    end

    test "delete_paste/2 does not delete another user's paste", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, paste} = Pastes.create_paste(other_scope, @valid_attrs)

      assert Pastes.delete_paste(scope, paste) == {:error, :not_found}
      assert Pastes.get_paste!(other_scope, paste.id)
    end

    test "change_paste/3 returns a paste changeset", %{scope: scope} do
      assert %Ecto.Changeset{} = Pastes.change_paste(scope, %Paste{})
    end
  end
end
