defmodule TextbinWeb.ApiContract do
  @moduledoc """
  Holds every API response the test suite produces to the operation its
  action declares in `TextbinWeb.ApiSpec`.

  `TextbinWeb.ApiResponseCheck` calls `check_response!/1` just before each
  API response is sent (test config enables it), so any test that makes an
  API request also checks the contract. The status must be one the operation
  documents, and a JSON body must validate against its schema without type
  coercion. Response schemas are closed, so an undocumented field fails as
  surely as a missing one.

  Each checked response is recorded, and after a full run the suite fails if
  a documented response was never produced, so the document cannot keep
  statuses or operations the server no longer has.
  """

  alias OpenApiSpex.{MediaType, Operation, Reference, Response, Schema}
  alias TextbinWeb.ApiSpec

  @coverage __MODULE__.Coverage
  @pending_failure {__MODULE__, :pending_failure}

  # Documented responses Plug.Test cannot produce, with the reason. Keep this
  # short: an entry that stops being documented fails the check as well.
  @not_producible_in_tests %{
    {"createPaste", 400} =>
      "a request body the server fails to read (socket timeout or a client that disconnects mid-upload)"
  }

  @doc "Raises when `conn`'s response does not match its action's operation."
  def check_response!(%Plug.Conn{} = conn) do
    # A failed check raises inside the response, so Phoenix renders a 500
    # page, which comes back through here; report the original failure.
    if message = Process.delete(@pending_failure), do: raise(message)

    # Responses from the pipeline, such as a missing token's 401, are sent
    # before Phoenix records the controller, so look the route up instead.
    case Phoenix.Router.route_info(TextbinWeb.Router, conn.method, conn.request_path, conn.host) do
      %{plug: controller, plug_opts: action} -> check_operation!(conn, controller, action)
      # No route, so no operation to hold the response to.
      :error -> :ok
    end

    conn
  end

  defp check_operation!(conn, controller, action) do
    case controller.open_api_operation(action) do
      %Operation{} = operation ->
        record(operation.operationId, conn.status)
        verify!(conn, operation)

      _undocumented ->
        raise "#{inspect(controller)}.#{action} has no `operation` spec"
    end
  end

  defp verify!(conn, operation) do
    id = operation.operationId

    response =
      Map.get(operation.responses, conn.status) ||
        fail!(
          "#{id} returned #{conn.status}, which its operation does not document " <>
            "(documented: #{operation.responses |> Map.keys() |> Enum.sort() |> inspect()}). " <>
            "Body: #{conn.resp_body}"
        )

    case response do
      %Response{content: %{"application/json" => %MediaType{schema: schema}}} ->
        verify_body!(id, conn, schema)

      %Response{content: nil} ->
        if conn.resp_body != "",
          do: fail!("#{id} #{conn.status} is documented without a body but sent one")

      %Response{} ->
        :ok
    end
  end

  defp verify_body!(id, conn, schema) do
    spec = spec()
    body = Jason.decode!(conn.resp_body)

    # Casting enforces closed objects and formats but accepts quoted
    # booleans and numbers, so validate the wire types first.
    with {:error, detail} <-
           Schema.validate(json_keys(schema), body, json_keys(spec.components.schemas)) do
      fail!("#{id} #{conn.status}: #{detail}\n\nBody: #{conn.resp_body}")
    end

    with {:error, errors} <- OpenApiSpex.cast_value(body, schema, spec) do
      details = Enum.map_join(errors, "\n", &"  #{&1}")

      fail!(
        "#{id} #{conn.status} response does not match its operation:\n#{details}\n\n" <>
          "Body: #{conn.resp_body}"
      )
    end

    :ok
  end

  defp fail!(message) do
    Process.put(@pending_failure, message)
    raise message
  end

  ## Coverage

  def start_coverage, do: :ets.new(@coverage, [:named_table, :public, :set])

  # A workspace-scoped paste operation runs its personal operation's action,
  # so the pair shares coverage: a status counts once either one produces it.
  defp record(operation_id, status) do
    if :ets.whereis(@coverage) != :undefined,
      do: :ets.insert(@coverage, {{coverage_key(operation_id), status}})
  end

  defp coverage_key(operation_id), do: String.replace_suffix(operation_id, "InWorkspace", "")

  @doc """
  Documented API responses no test produced. Only the API pipeline is
  checked, so the raw paste route is left out.
  """
  def uncovered_responses do
    documented =
      for {_method, "/api/" <> _ = _path, operation} <- ApiSpec.operations(),
          status <- Map.keys(operation.responses),
          into: MapSet.new(),
          do: {coverage_key(operation.operationId), status}

    missing =
      for {key, status} = response <- documented,
          not :ets.member(@coverage, response),
          not Map.has_key?(@not_producible_in_tests, response),
          do: "#{key} #{status}"

    stale_exemptions =
      for {key, status} = response <- Map.keys(@not_producible_in_tests),
          not MapSet.member?(documented, response),
          do: "#{key} #{status} (exempted in TextbinWeb.ApiContract but no longer documented)"

    missing ++ stale_exemptions
  end

  @doc """
  After a full run, fails the suite when a documented response was never
  produced. A run narrowed to some files or tags would always miss some, so
  it only reports then.
  """
  def report_coverage(argv) do
    missing = Enum.sort(uncovered_responses())

    if missing != [] and full_run?(argv), do: fail_suite(missing)
  end

  defp fail_suite(missing) do
    message =
      "Documented API responses no test produced:\n" <>
        Enum.map_join(missing, "\n", &"  #{&1}") <>
        "\nAdd a test that produces each one, or remove it from the operation."

    IO.puts(:stderr, IO.ANSI.format([:red, message]))
    # ExUnit has already counted failures; this turns the run red regardless.
    System.at_exit(fn _status -> System.halt(1) end)
  end

  defp full_run?(argv) do
    not Enum.any?(argv, fn arg ->
      arg in ~w(--only --failed --stale) or String.starts_with?(arg, "test/") or
        String.ends_with?(arg, ".exs") or arg =~ ~r/\.exs:\d+$/
    end)
  end

  defp json_keys(%Schema{} = schema) do
    normalized = schema |> Map.from_struct() |> json_keys() |> then(&struct!(Schema, &1))

    %{
      normalized
      | properties:
          Map.new(normalized.properties || %{}, fn {key, value} -> {to_string(key), value} end),
        required: Enum.map(normalized.required || [], &to_string/1)
    }
  end

  defp json_keys(%Reference{} = reference), do: reference

  defp json_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_keys(value)} end)

  defp json_keys(list) when is_list(list), do: Enum.map(list, &json_keys/1)
  defp json_keys(value), do: value

  # Building the spec is pure but not free; every check shares one copy.
  defp spec do
    case :persistent_term.get({__MODULE__, :spec}, nil) do
      nil ->
        spec = ApiSpec.spec()
        :persistent_term.put({__MODULE__, :spec}, spec)
        spec

      spec ->
        spec
    end
  end
end
