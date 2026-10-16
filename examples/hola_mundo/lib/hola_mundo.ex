defmodule HolaMundo do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/hello/" <> name}) do
    {200, HolaMundo.Greeting.hello(name)}
  end

  def handle_request(_request), do: {404, "Not found\n"}
end
