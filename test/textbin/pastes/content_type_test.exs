defmodule Textbin.Pastes.ContentTypeTest do
  use ExUnit.Case, async: true

  alias Textbin.Pastes.ContentType

  test "normalizes valid media types without untrusted parameters" do
    assert ContentType.normalize("TEXT/HTML; charset=iso-8859-1", true) == "text/html"
    assert ContentType.normalize(nil, true) == "text/plain"
    assert ContentType.normalize("image/png", false) == "application/octet-stream"
  end

  test "rejects media types with an empty type or subtype" do
    refute ContentType.valid?("text/")
    refute ContentType.valid?("/plain")
    refute ContentType.textual?("text/")
  end

  test "classifies textual and active media types" do
    assert ContentType.textual?("text/html")
    assert ContentType.textual?("application/problem+json")
    refute ContentType.textual?("application/octet-stream")
    assert ContentType.active?("text/html")
    assert ContentType.active?("image/svg+xml")
  end

  test "validates UTF-8 across file chunk boundaries" do
    path = Path.join(System.tmp_dir!(), "textbin-content-type-#{Ecto.UUID.generate()}")
    File.write!(path, String.duplicate("a", 63_999) <> "😀")
    on_exit(fn -> File.rm(path) end)

    assert ContentType.text_safe_file(path) == {:ok, true}

    File.write!(path, <<"text", 0, "data">>)
    assert ContentType.text_safe_file(path) == {:ok, false}

    File.write!(path, <<255, 254>>)
    assert ContentType.text_safe_file(path) == {:ok, false}
  end
end
