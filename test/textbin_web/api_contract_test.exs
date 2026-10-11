defmodule TextbinWeb.ApiContractTest do
  @moduledoc """
  Keeps `TextbinWeb.ApiSpec` and the server in step: every API action
  declares its operation and `priv/openapi.json` is current.

  Responses themselves are checked in every test by `TextbinWeb.ApiContract`.
  The tests below produce the responses every operation shares (401, 422 and
  the documented 404s) across the whole API, plus the ones no feature test
  reaches, so that the suite's coverage check passes.
  """

  use TextbinWeb.ConnCase, async: false

  import Textbin.AccountsFixtures

  alias OpenApiSpex.{MediaType, Reference, RequestBody}
  alias Textbin.Accounts
  alias Textbin.Pastes
  alias Textbin.Storage
  alias TextbinWeb.ApiSpec

  @exported_spec Path.expand("../../priv/openapi.json", __DIR__)

  describe "the document" do
    test "every API route's action declares its operation" do
      # The document is built from the router, so an action without an
      # `operation` would silently drop out of it instead of failing.
      for route <- Phoenix.Router.routes(TextbinWeb.Router),
          String.starts_with?(route.path, "/api/") or route.path == "/pastes/:id/raw" do
        assert function_exported?(route.plug, :open_api_operation, 1) and
                 match?(%OpenApiSpex.Operation{}, route.plug.open_api_operation(route.plug_opts)),
               "#{inspect(route.plug)}.#{route.plug_opts} (#{route.verb} #{route.path}) has no `operation` spec"
      end
    end

    test "gives each operation a unique id and resolves every schema reference" do
      operation_ids =
        for {_method, _path, operation} <- ApiSpec.operations(), do: operation.operationId

      assert Enum.uniq(operation_ids) == operation_ids

      spec = ApiSpec.spec()
      known = Map.keys(spec.components.schemas)

      for ref <- references(spec) do
        assert "#/components/schemas/" <> title = ref
        assert title in known, "#{ref} does not resolve"
      end
    end

    test "priv/openapi.json is the exported spec" do
      current =
        ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map() |> Jason.encode!() |> Jason.decode!()

      assert File.exists?(@exported_spec), "run `mix openapi.export` to create priv/openapi.json"

      assert Jason.decode!(File.read!(@exported_spec)) == current,
             "priv/openapi.json is out of date; run `mix openapi.export`"
    end
  end

  describe "every operation" do
    setup :api_token

    test "answers a request without a token with 401" do
      for {method, path, operation} <- api_operations(), operation.security != [] do
        conn = request(json_conn(), method, path, operation)
        assert conn.status == 401, "#{operation.operationId} answered #{conn.status}"
      end
    end

    test "rejects query parameters it does not declare with 422", %{token: token} do
      for {method, path, operation} <- api_operations() do
        conn = request(authorized(token), method, path <> "?undeclared=1", operation)
        assert conn.status == 422, "#{operation.operationId} answered #{conn.status}"
      end
    end

    test "bodyless mutation operations reject both JSON and unread raw bodies", %{token: token} do
      for {method, path, operation} <- api_operations(),
          method in [:post, :delete],
          is_nil(operation.requestBody),
          {content_type, bytes} <- [
            {"application/json", Jason.encode!(%{workspace_id: Ecto.UUID.generate()})},
            {"application/octet-stream", "undeclared body"}
          ] do
        path = Regex.replace(~r/\{\w+\}/, path, fn _ -> Ecto.UUID.generate() end)

        conn =
          authorized(token)
          |> put_req_header("content-type", content_type)
          |> dispatch(@endpoint, method, path, bytes)

        assert conn.status == 422, "#{operation.operationId} answered #{conn.status}"
      end
    end

    test "answers unknown ids with each documented 404", %{token: token} do
      for {method, path, operation} <- api_operations(), Map.has_key?(operation.responses, 404) do
        conn = request(authorized(token), method, path, operation)
        assert conn.status == 404, "#{operation.operationId} answered #{conn.status}"
      end
    end
  end

  describe "responses no feature test reaches" do
    setup :api_token

    test "purgePaste answers 503 when stored content cannot be deleted", %{
      token: token,
      user: user
    } do
      scope = user_scope_fixture(user)
      # Larger than the inline limit, so the content lives in storage.
      data = String.duplicate("a", Application.fetch_env!(:textbin, :inline_paste_bytes) + 1)
      {:ok, paste} = Pastes.create_paste(scope, %{data: data})
      assert paste.storage_key
      {:ok, _removed} = Pastes.delete_paste(scope, paste)

      delegate = Application.fetch_env!(:textbin, Storage)
      on_exit(fn -> Application.put_env(:textbin, Storage, delegate) end)

      Application.put_env(:textbin, Storage,
        adapter: Textbin.FailingDeleteStorage,
        opts: [test_pid: self(), delegate: delegate]
      )

      conn = delete(authorized(token), ~p"/api/v1/pastes/deleted/#{paste.id}")
      assert %{"errors" => %{"detail" => _detail}} = json_response(conn, 503)
    end
  end

  defp api_token(_context) do
    user = user_fixture()
    {:ok, {token, _user_token}} = Accounts.create_user_api_token(user, %{"name" => "Contract"})
    %{token: token, user: user}
  end

  defp authorized(token), do: put_req_header(json_conn(), "authorization", "Bearer #{token}")

  defp api_operations do
    for {method, "/api/" <> _ = path, operation} <- ApiSpec.operations(),
        do: {method, path, operation}
  end

  # Fills every path parameter with an id nothing has, and sends the smallest
  # valid JSON body when the operation takes one, so the only thing wrong with
  # the request is what each test varies.
  defp request(conn, method, path, operation) do
    path = Regex.replace(~r/\{\w+\}/, path, fn _ -> Ecto.UUID.generate() end)
    dispatch(conn, @endpoint, method, path, body(operation))
  end

  defp body(%{requestBody: %RequestBody{content: %{"application/json" => %MediaType{} = media}}}) do
    case media.schema do
      %Reference{"$ref": "#/components/schemas/CreatePasteRequest"} ->
        %{data: "contract"}

      %Reference{"$ref": "#/components/schemas/CreateTokenRequest"} ->
        %{email: "x@example.com", password: "x"}
    end
  end

  defp body(_operation), do: nil

  defp references(%Reference{"$ref": ref}), do: [ref]
  defp references(%_struct{} = struct), do: struct |> Map.from_struct() |> references()
  defp references(map) when is_map(map), do: Enum.flat_map(Map.values(map), &references/1)
  defp references(list) when is_list(list), do: Enum.flat_map(list, &references/1)
  defp references(_value), do: []
end
