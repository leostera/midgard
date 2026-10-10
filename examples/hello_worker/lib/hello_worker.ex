defmodule HelloWorker do
  @moduledoc "A standalone example worker with a local helper module."
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/hello"} = request) do
    name = URI.decode_query(request.query_string) |> Map.get("name", "world")
    {200, HelloWorker.Greeter.hello(name)}
  end

  def handle_request(%Midgard.Request{method: "POST", path: "/json", body: body}) do
    case Jason.decode(body) do
      {:ok, %{"name" => name}} when is_binary(name) ->
        {200, Jason.encode!(%{"greeting" => HelloWorker.Greeter.hello(name)})}

      _ ->
        {400, "Invalid JSON\n"}
    end
  end

  def handle_request(%Midgard.Request{method: "POST", path: "/echo", body: body}) do
    {200, body}
  end

  def handle_request(_request), do: {404, "Not found\n"}
end
