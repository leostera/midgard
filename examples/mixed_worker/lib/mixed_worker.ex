defmodule MixedWorker do
  @moduledoc "Minimal mixed-language binary entrypoint fixture; not an HTTP SDK."

  def __midgard_call__(bytes) when is_binary(bytes), do: :mixed_helper.echo(bytes)
end
