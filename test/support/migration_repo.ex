defmodule Textbin.MigrationRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :textbin,
    adapter: Ecto.Adapters.Postgres

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @doc """
  Every migration as a `{version, module}` pair, for `Ecto.Migrator.run/4`.

  Passing the migrations path instead makes the migrator compile every file
  again on each run, and the `test` alias has already loaded them through
  `ecto.migrate`, so each run would print a "redefining module" warning per
  migration. The files are compiled once per test run instead.
  """
  def migrations do
    case :persistent_term.get({__MODULE__, :migrations}, nil) do
      nil ->
        migrations = load_migrations()
        :persistent_term.put({__MODULE__, :migrations}, migrations)
        migrations

      migrations ->
        migrations
    end
  end

  defp load_migrations do
    # `ecto.migrate` may have compiled some of these already; this one load
    # replaces them with identical code.
    ignore_conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      for file <- Enum.sort(Path.wildcard(Path.join(@migrations_path, "*.exs"))) do
        [version | _name] = file |> Path.basename() |> String.split("_", parts: 2)
        modules = for {module, _bytecode} <- Code.compile_file(file), do: module

        {String.to_integer(version),
         Enum.find(modules, &function_exported?(&1, :__migration__, 0))}
      end
    after
      Code.put_compiler_option(:ignore_module_conflict, ignore_conflicts)
    end
  end
end
