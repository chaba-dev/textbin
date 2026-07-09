defmodule Textbin.Repo.Migrations.AddSyntaxHighlight do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      add_if_not_exists :syntax_highlight, :text, null: false, default: "plain"
    end
  end

  def down do
    alter table(:pastes) do
      remove_if_exists :syntax_highlight
    end
  end
end
