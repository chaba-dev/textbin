defmodule Textbin.ConfigTest do
  use ExUnit.Case, async: false

  @production_env %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/textbin_test",
    "PHX_HOST" => "textbin.example.com",
    "SECRET_KEY_BASE" => String.duplicate("a", 64)
  }
  @optional_production_env ~w(HTTPS_PORT POOL_SIZE PORT TLS_CERT_PATH TLS_KEY_PATH)

  setup do
    names = Map.keys(@production_env) ++ @optional_production_env
    previous = Map.new(names, &{&1, System.get_env(&1)})

    Enum.each(@optional_production_env, &System.delete_env/1)
    System.put_env(@production_env)

    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
  end

  test "Phoenix and Cargo release versions stay synchronized" do
    mix_project = File.read!("mix.exs")
    cargo_workspace = File.read!("Cargo.toml")

    assert [mix_version] =
             Regex.run(~r/^\s*version:\s*"([^"]+)"/m, mix_project, capture: :all_but_first)

    assert [cargo_version] =
             Regex.run(~r/^version\s*=\s*"([^"]+)"/m, cargo_workspace, capture: :all_but_first)

    assert mix_version == cargo_version
  end

  test "production uses only HTTP when direct TLS is not configured" do
    endpoint = production_endpoint_config()

    assert endpoint[:http][:port] == 4000
    refute Keyword.has_key?(endpoint, :https)
  end

  test "production enables direct TLS when both certificate paths are configured" do
    root = Path.join(System.tmp_dir!(), "textbin-tls-#{System.unique_integer([:positive])}")
    certfile = Path.join(root, "cert.pem")
    keyfile = Path.join(root, "key.pem")
    File.mkdir_p!(root)
    File.write!(certfile, "certificate")
    File.write!(keyfile, "private key")
    on_exit(fn -> File.rm_rf!(root) end)

    System.put_env(%{
      "HTTPS_PORT" => "4443",
      "TLS_CERT_PATH" => certfile,
      "TLS_KEY_PATH" => keyfile
    })

    endpoint = production_endpoint_config()

    assert endpoint[:https] == [
             ip: {0, 0, 0, 0},
             port: 4443,
             cipher_suite: :strong,
             certfile: certfile,
             keyfile: keyfile
           ]
  end

  test "production rejects an incomplete direct TLS configuration" do
    System.put_env("TLS_CERT_PATH", "/run/secrets/textbin-cert.pem")

    assert_raise RuntimeError,
                 ~r/TLS_CERT_PATH and TLS_KEY_PATH must be set together/,
                 &production_endpoint_config/0
  end

  test "production rejects an invalid HTTPS port" do
    System.put_env("HTTPS_PORT", "70000")

    assert_raise RuntimeError, ~r/HTTPS_PORT must be an integer from 1 to 65535/, fn ->
      production_endpoint_config()
    end
  end

  test "production rejects missing TLS files" do
    System.put_env(%{
      "TLS_CERT_PATH" => "/run/secrets/missing-textbin-cert.pem",
      "TLS_KEY_PATH" => "/run/secrets/missing-textbin-key.pem"
    })

    assert_raise RuntimeError, ~r/TLS_CERT_PATH must point to a readable regular file/, fn ->
      production_endpoint_config()
    end
  end

  test "production rejects invalid HTTP port and database pool values" do
    System.put_env("PORT", "not-a-port")

    assert_raise RuntimeError, ~r/PORT must be an integer from 1 to 65535/, fn ->
      production_endpoint_config()
    end

    System.delete_env("PORT")
    System.put_env("POOL_SIZE", "0")

    assert_raise RuntimeError, ~r/POOL_SIZE must be a positive integer/, fn ->
      production_endpoint_config()
    end
  end

  defp production_endpoint_config do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod)
    |> get_in([:textbin, TextbinWeb.Endpoint])
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
