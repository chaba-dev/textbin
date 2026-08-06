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
  def put_file(storage_key, path, metadata, opts) do
    case File.open(path, [:read, :binary], fn file ->
           put_open_file(storage_key, file, metadata, opts)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
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
      {:ok, %{status: status}} when status in 200..299 -> :ok
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

  defp put_open_file(storage_key, file, expected_metadata, opts) do
    metadata = Textbin.Storage.calculate_metadata(IO.binstream(file, 64_000))

    if metadata == expected_metadata do
      {:ok, _position} = :file.position(file, :bof)
      put_signed_file(storage_key, file, metadata, opts)
    else
      {:error, :metadata_mismatch}
    end
  end

  defp put_signed_file(storage_key, file, metadata, opts) do
    url = object_url(storage_key, opts)
    headers = [{"content-length", Integer.to_string(metadata.size_bytes)}]

    signed_headers =
      Req.Utils.aws_sigv4_headers(
        access_key_id: Keyword.fetch!(opts, :access_key_id),
        secret_access_key: Keyword.fetch!(opts, :secret_access_key),
        region: Keyword.get(opts, :region, "us-east-1"),
        service: :s3,
        datetime: DateTime.utc_now(),
        method: :put,
        url: url,
        headers: headers,
        body: "",
        body_digest: Base.encode16(metadata.sha256, case: :lower)
      )

    request = Req.new(Keyword.get(opts, :req_options, []))

    case Req.put(request,
           url: url,
           headers: signed_headers,
           body: IO.binstream(file, 64_000),
           redirect: false,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, metadata}
      result -> response_error(result)
    end
  end

  defp object_url(storage_key, opts) do
    endpoint = opts |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    bucket = Keyword.fetch!(opts, :bucket)
    "#{endpoint}/#{bucket}/#{storage_key}"
  end

  defp response_error({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp response_error({:error, exception}), do: {:error, exception}
end
