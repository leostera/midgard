defmodule Libbeam.Isolate do
  @moduledoc "A handle scoped to its owning Engine process; never survives a Port restart."
  @enforce_keys [:engine, :id]
  defstruct [:engine, :id]

  def load_modules(isolate, beams, options \\ []),
    do: Libbeam.Engine.load_modules(isolate, beams, options)

  def call(isolate, module, function, input),
    do: Libbeam.Engine.call(isolate, module, function, input)

  def stop(isolate), do: Libbeam.Engine.stop_isolate(isolate)
end
