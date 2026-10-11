defmodule TextbinWeb.ApiResponseCheck do
  @moduledoc """
  Hands every API response to a checker just before it is sent, so the test
  suite can hold each one to the operation its action declares.

  It does nothing unless `config :textbin, :api_response_check` names a
  checker module, which only the test environment does; the value is read at
  compile time, so production carries no cost. The checker gets the conn in a
  `register_before_send/2` callback and raises on a mismatch, which fails
  whichever test made the request.

  It sits in the `:api` pipeline rather than the controllers so responses
  from the pipeline itself, such as a missing token's 401, are checked too.
  """

  @behaviour Plug

  @checker Application.compile_env(:textbin, :api_response_check)

  @impl Plug
  def init(opts), do: opts

  if @checker do
    @impl Plug
    def call(conn, _opts),
      do: Plug.Conn.register_before_send(conn, fn conn -> @checker.check_response!(conn) end)
  else
    @impl Plug
    def call(conn, _opts), do: conn
  end
end
