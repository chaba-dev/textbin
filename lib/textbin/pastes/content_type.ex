defmodule Textbin.Pastes.ContentType do
  @moduledoc """
  Normalizes untrusted media types and classifies paste bodies for safe storage
  and rendering.
  """

  @default "text/plain"
  @binary "application/octet-stream"
  @active_types MapSet.new(["application/xhtml+xml", "image/svg+xml", "text/html"])
  @textual_application_types MapSet.new([
                               "application/graphql",
                               "application/javascript",
                               "application/json",
                               "application/sql",
                               "application/xml",
                               "application/x-httpd-php",
                               "application/x-sh"
                             ])

  def default, do: @default
  def binary, do: @binary

  def normalize(_content_type, false), do: @binary
  def normalize(nil, true), do: @default
  def normalize("", true), do: @default

  def normalize(content_type, true) when is_binary(content_type) do
    case parse(content_type) do
      {:ok, type, subtype, _params} -> "#{type}/#{subtype}"
      :error -> content_type
    end
  end

  def valid?(content_type) when is_binary(content_type) do
    match?({:ok, _type, _subtype, _params}, parse(content_type))
  end

  def valid?(_content_type), do: false

  def textual?(content_type) when is_binary(content_type) do
    case parse(content_type) do
      {:ok, "text", _subtype, _params} ->
        true

      {:ok, "application", subtype, _params} ->
        MapSet.member?(@textual_application_types, "application/#{subtype}") or
          String.ends_with?(subtype, "+json") or String.ends_with?(subtype, "+xml")

      _result ->
        false
    end
  end

  def textual?(_content_type), do: false

  def active?(content_type), do: MapSet.member?(@active_types, content_type)

  def text_safe?(data) when is_binary(data) do
    String.valid?(data) and :binary.match(data, <<0>>) == :nomatch
  end

  def text_safe?(_data), do: false

  def text_safe_file(path) when is_binary(path) do
    case File.open(path, [:read, :binary], fn file ->
           file
           |> IO.binstream(64_000)
           |> Enum.reduce_while(<<>>, &validate_chunk/2)
           |> then(&(&1 == <<>>))
         end) do
      {:ok, text_safe?} -> {:ok, text_safe?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_chunk(_chunk, false), do: {:halt, false}

  defp validate_chunk(chunk, pending) do
    if :binary.match(chunk, <<0>>) == :nomatch do
      validate_utf8(pending <> chunk)
    else
      {:halt, false}
    end
  end

  defp validate_utf8(data) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      converted when is_binary(converted) -> {:cont, <<>>}
      {:incomplete, _converted, pending} -> {:cont, pending}
      {:error, _converted, _rest} -> {:halt, false}
    end
  end

  defp parse(content_type) do
    case Plug.Conn.Utils.content_type(content_type) do
      {:ok, type, subtype, _params} = parsed when type != "" and subtype != "" -> parsed
      _result -> :error
    end
  end
end
