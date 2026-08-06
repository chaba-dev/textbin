defmodule Textbin.Storage.IntegrityError do
  defexception [:storage_key]

  @impl true
  def message(%__MODULE__{storage_key: storage_key}) do
    "stored paste content integrity check failed for #{inspect(storage_key)}"
  end
end
