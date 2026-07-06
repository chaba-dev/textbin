defmodule Textbin.PastesTest do
  use Textbin.DataCase, async: true

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  describe "pastes" do
    @valid_attrs %{content: "some content"}
    @update_attrs %{content: "updated content"}
    @invalid_attrs %{content: nil}

    test "list_pastes/0 returns all pastes" do
      {:ok, older_paste} = Pastes.create_paste(@valid_attrs)
      {:ok, newer_paste} = Pastes.create_paste(%{content: "newer content"})

      paste_ids = Pastes.list_pastes() |> Enum.map(& &1.id)

      assert older_paste.id in paste_ids
      assert newer_paste.id in paste_ids
    end

    test "get_paste!/1 returns the paste with given id" do
      {:ok, paste} = Pastes.create_paste(@valid_attrs)

      assert Pastes.get_paste!(paste.id).id == paste.id
    end

    test "create_paste/1 with valid data creates a paste" do
      assert {:ok, %Paste{} = paste} = Pastes.create_paste(@valid_attrs)
      assert paste.content == "some content"
      assert {microsecond, 6} = paste.inserted_at.microsecond
      assert rem(microsecond, 1000) == 0
    end

    test "create_paste/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Pastes.create_paste(@invalid_attrs)
    end

    test "update_paste/2 with valid data updates the paste" do
      {:ok, paste} = Pastes.create_paste(@valid_attrs)

      assert {:ok, %Paste{} = paste} = Pastes.update_paste(paste, @update_attrs)
      assert paste.content == "updated content"
    end

    test "update_paste/2 with invalid data returns error changeset" do
      {:ok, paste} = Pastes.create_paste(@valid_attrs)

      assert {:error, %Ecto.Changeset{}} = Pastes.update_paste(paste, @invalid_attrs)
      assert Pastes.get_paste!(paste.id).content == paste.content
    end

    test "delete_paste/1 deletes the paste" do
      {:ok, paste} = Pastes.create_paste(@valid_attrs)

      assert {:ok, %Paste{}} = Pastes.delete_paste(paste)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(paste.id) end
    end

    test "change_paste/1 returns a paste changeset" do
      assert %Ecto.Changeset{} = Pastes.change_paste(%Paste{})
    end
  end
end
