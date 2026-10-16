defmodule Libbeam.Error do
  @moduledoc "An error returned by the native libbeam host or its Port boundary."
  defexception [:code, :message]

  @impl true
  def exception(options) do
    %__MODULE__{code: Keyword.fetch!(options, :code), message: Keyword.fetch!(options, :message)}
  end
end
