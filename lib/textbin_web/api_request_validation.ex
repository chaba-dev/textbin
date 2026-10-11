defmodule TextbinWeb.ApiRequestValidation do
  @moduledoc """
  Rejects API requests that do not match the operation the action declares
  with `operation`, before the action runs.

  The operation is the contract: path and query parameters, and a JSON body,
  are validated against it, and anything it does not describe is rejected
  with a 422 in the `ValidationError` shape. That keeps the document and the
  accepted input from drifting apart, because an undocumented parameter
  simply does not work.

  Raw uploads are the one exception to body validation. Paste creation
  accepts the content itself with any content type (the type is stored with
  the paste), and open_api_spex only matches request bodies by exact content
  type, so a body whose type the operation lists only as `*/*` skips body
  validation; its query parameters are still checked.

  Validation leaves `conn.params` as the strings the action already expects.
  """

  @behaviour Plug

  import Plug.Conn

  alias OpenApiSpex.Cast.Error
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Plug.PutApiSpec
  alias OpenApiSpex.RequestBody

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{private: %{phoenix_controller: controller, phoenix_action: action}} = conn, _opts) do
    {spec, _operation_lookup} = PutApiSpec.get_spec_and_operation_lookup(conn)
    content_type = request_content_type(conn)
    operation = controller.open_api_operation(action) |> for_content_type(content_type)

    {conn, body_errors} = body_boundary(conn, operation)

    errors =
      case OpenApiSpex.cast_and_validate(spec, operation, conn, content_type,
             replace_params: false
           ) do
        {:ok, _conn} -> []
        {:error, errors} -> errors
      end

    case body_errors ++ errors ++ undeclared_query_errors(conn, operation) do
      [] -> conn
      errors -> reject(conn, errors)
    end
  end

  defp request_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value | _rest] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp for_content_type(
         %Operation{requestBody: %RequestBody{content: content}} = operation,
         content_type
       )
       when is_binary(content_type) do
    if Map.has_key?(content, content_type) or not Map.has_key?(content, "*/*"),
      do: operation,
      else: %{operation | requestBody: nil}
  end

  defp for_content_type(operation, _content_type), do: operation

  # Operation2 unwraps _json even when it was supplied as a real object key.
  # Our JSON contracts require flat objects, never Plug's scalar wrapper.
  defp body_boundary(%{body_params: %{"_json" => _}} = conn, %Operation{
         requestBody: %RequestBody{}
       }),
       do: {conn, [unexpected_body("_json")]}

  defp body_boundary(conn, %Operation{requestBody: nil}) do
    cond do
      conn.private[:raw_paste_upload] ->
        {conn, []}

      map_size(conn.body_params) > 0 ->
        {conn, [unexpected_body("body")]}

      true ->
        # Content-Type alone does not imply a body. Probe only one byte when
        # parsers left it unread, rejecting chunked/raw bodies without buffering.
        case read_body(conn, length: 1, read_length: 1) do
          {:ok, "", conn} -> {conn, []}
          {_state, _body, conn} -> {conn, [unexpected_body("body")]}
          {:error, _reason} -> {conn, [unexpected_body("body")]}
        end
    end
  end

  defp body_boundary(conn, _operation), do: {conn, []}

  defp unexpected_body(name), do: %Error{reason: :unexpected_field, name: name, path: [name]}

  # open_api_spex only checks query parameters for operations that declare
  # some; an operation that declares none should accept none either.
  defp undeclared_query_errors(conn, %Operation{parameters: parameters}) do
    if Enum.any?(parameters, &(&1.in == :query)) do
      []
    else
      conn = fetch_query_params(conn)

      for name <- Map.keys(conn.query_params) do
        %Error{reason: :unexpected_field, name: name, path: [name]}
      end
    end
  end

  defp reject(conn, errors) do
    body = %{
      errors:
        Enum.group_by(errors, &field/1, fn error ->
          error |> Error.message() |> String.trim()
        end)
    }

    conn
    |> put_status(:unprocessable_entity)
    |> Phoenix.Controller.json(body)
    |> halt()
  end

  defp field(%Error{path: [_ | _] = path}), do: Enum.map_join(path, ".", &to_string/1)
  defp field(%Error{name: name}) when not is_nil(name), do: to_string(name)
  defp field(%Error{}), do: "request"
end
