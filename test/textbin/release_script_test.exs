defmodule Textbin.ReleaseScriptTest do
  use ExUnit.Case, async: true

  @script "rel/overlays/bin/grant-platform-admin"

  setup do
    directory = Path.join(System.tmp_dir!(), "textbin-release-script-#{System.unique_integer()}")
    File.mkdir_p!(directory)
    File.cp!(@script, Path.join(directory, "grant-platform-admin"))

    File.write!(Path.join(directory, "textbin"), """
    #!/bin/sh
    printf '%s\n' "$@"
    exit "${FAKE_EXIT_STATUS:-0}"
    """)

    File.chmod!(Path.join(directory, "grant-platform-admin"), 0o700)
    File.chmod!(Path.join(directory, "textbin"), 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    %{script: Path.join(directory, "grant-platform-admin")}
  end

  test "transports the email in the RPC expression without relying on server environment", %{
    script: script
  } do
    email = ~S(admin+"quoted"@example.com)

    assert {output, 0} = System.cmd(script, [email])
    assert ["rpc", expression] = String.split(output, "\n", trim: true)
    assert expression =~ "Base.decode64!(\"#{Base.encode64(email)}\")"
    assert expression =~ "raise \"grant-platform-admin failed:"
    refute expression =~ email
    refute expression =~ "System.fetch_env!"
  end

  test "returns the release RPC exit status", %{script: script} do
    assert {_output, 17} =
             System.cmd(script, ["admin@example.com"], env: [{"FAKE_EXIT_STATUS", "17"}])
  end

  test "rejects an invalid argument count", %{script: script} do
    assert {output, 64} = System.cmd(script, [], stderr_to_stdout: true)
    assert output =~ "usage:"
  end
end
