defmodule Textbin.ConfigTest do
  use ExUnit.Case, async: false

  test "the test database default port matches Docker Compose" do
    database_port = System.get_env("DATABASE_PORT")
    System.delete_env("DATABASE_PORT")

    on_exit(fn -> restore_env("DATABASE_PORT", database_port) end)

    config = Config.Reader.read!("config/test.exs", env: :test)
    test_port = config[:textbin][Textbin.Repo][:port]
    docker_compose = File.read!("docker-compose.yml")

    assert docker_compose =~ ~s(- "#{test_port}:5432")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
