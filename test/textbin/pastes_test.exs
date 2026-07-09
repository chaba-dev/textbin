defmodule Textbin.PastesTest do
  use Textbin.DataCase, async: true

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  describe "pastes" do
    @valid_attrs %{data: "some data"}
    @invalid_attrs %{data: nil}

    test "list_pastes/0 returns all pastes" do
      {:ok, older_paste} = Pastes.create_paste(@valid_attrs)
      {:ok, newer_paste} = Pastes.create_paste(%{data: "newer data"})

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
      assert paste.data == "some data"
      assert {microsecond, 6} = paste.inserted_at.microsecond
      assert rem(microsecond, 1000) == 0
    end

    test "create_paste/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Pastes.create_paste(@invalid_attrs)
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
