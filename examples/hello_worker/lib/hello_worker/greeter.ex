defmodule HelloWorker.Greeter do
  @moduledoc "A local module included in the packed worker source."

  def hello(name), do: "Hello, #{name}!\n"
end
