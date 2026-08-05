defmodule Textbin.Storage.S3 do
  @moduledoc """
  Stores paste bodies through the path-style S3 HTTP API.

  Only basic object operations are used so the adapter remains compatible with
  lightweight self-hosted services such as SeaweedFS and Garage.
  """

  @behaviour Textbin.Storage

  @impl true
  def put(storage_key, data, opts) when is_binary(data) do
    case Req.put(request(opts), url: object_url(storage_key, opts), body: data) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}}

      result ->
        response_error(result)
    end
  end

  @impl true
  def get(storage_key, opts) do
    case Req.get(request(opts), url: object_url(storage_key, opts)) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      result ->
        response_error(result)
    end
  end

  @impl true
  def delete(storage_key, opts) do
    case Req.delete(request(opts), url: object_url(storage_key, opts)) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      result -> response_error(result)
    end
  end

  defp request(opts) do
    req_options = Keyword.get(opts, :req_options, [])

    Req.new(
      Keyword.merge(req_options,
        aws_sigv4: [
          access_key_id: Keyword.fetch!(opts, :access_key_id),
          secret_access_key: Keyword.fetch!(opts, :secret_access_key),
          region: Keyword.get(opts, :region, "us-east-1"),
          service: :s3
        ]
      )
    )
  end

  defp object_url(storage_key, opts) do
    endpoint = opts |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    bucket = Keyword.fetch!(opts, :bucket)
    "#{endpoint}/#{bucket}/#{storage_key}"
  end

  defp response_error({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp response_error({:error, exception}), do: {:error, exception}
end
