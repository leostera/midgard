defmodule TodoWorkerTest do
  use ExUnit.Case, async: false

  alias Midgard.{Protocol, Request}

  setup do
    {:ok, pid} = :todo_store.start_link()
    Process.unlink(pid)

    on_exit(fn ->
      if pid = Process.whereis(:todo_store) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  test "binary entrypoint creates, lists, updates and deletes tasks" do
    assert {200, %{"todos" => []}} = call("GET", "/api/todos")

    assert {201, %{"todo" => created}} = call("POST", "/api/todos", %{title: "  Write tests  "})
    assert created == %{"id" => 1, "title" => "Write tests", "completed" => false}
    assert {200, %{"todos" => [^created]}} = call("GET", "/api/todos")

    assert {200, %{"todo" => done}} =
             call("PATCH", "/api/todos/1", %{completed: true, title: "Ship tests"})

    assert done == %{"id" => 1, "title" => "Ship tests", "completed" => true}
    assert {204, ""} = call("DELETE", "/api/todos/1")
    assert {200, %{"todos" => []}} = call("GET", "/api/todos")
    assert {404, _} = call("DELETE", "/api/todos/1")
  end

  test "malformed inputs and unknown items do not mutate store" do
    assert {400, _} = call("POST", "/api/todos", %{title: "   "})
    assert {400, _} = call("POST", "/api/todos", %{title: String.duplicate("x", 161)})
    assert {400, _} = call("POST", "/api/todos", %{title: "Valid", owner: "admin"})
    assert {400, _} = call("POST", "/api/todos", "{not-json")
    assert {400, _} = call("PATCH", "/api/todos/1", %{completed: "true"})
    assert {400, _} = call("PATCH", "/api/todos/1", %{id: 50})
    assert {400, _} = call("DELETE", "/api/todos/not-a-number")
    assert {404, _} = call("PATCH", "/api/todos/2", %{completed: true})
    assert {404, _} = call("GET", "/not-a-route")
    assert {200, %{"todos" => []}} = call("GET", "/api/todos")
  end

  test "concurrent updates are serialized by Erlang and restart clears state" do
    results =
      1..60
      |> Task.async_stream(fn number -> :todo_store.create("Item #{number}") end,
        max_concurrency: 15,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, todo}} -> todo.id end)

    assert length(Enum.uniq(results)) == 60
    assert Enum.sort(results) == Enum.to_list(1..60)
    assert length(:todo_store.list()) == 60

    assert {409, %{"error" => "List full (60 tasks). Remove one to add another."}} =
             call("POST", "/api/todos", %{title: "Too many"})

    :ok = :todo_store.delete(1)

    assert {201, %{"todo" => %{"id" => 61}}} =
             call("POST", "/api/todos", %{title: "A new slot"})

    assert {:error, :invalid_title} = :todo_store.create(<<255>>)
    assert length(:todo_store.list()) == 60

    GenServer.stop(Process.whereis(:todo_store))
    {:ok, pid} = :todo_store.start_link()
    Process.unlink(pid)
    assert :todo_store.list() == []
  end

  test "the full list stays within the bounded binary response" do
    worst_case = String.duplicate(<<1>>, 160)

    for _ <- 1..60 do
      assert {201, _} = call("POST", "/api/todos", %{title: worst_case})
    end

    assert {200, %{"todos" => todos}} = call("GET", "/api/todos")
    assert length(todos) == 60
  end

  defp call(method, path, payload \\ "") do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    request = %Request{method: method, path: path, body: body}
    assert {:ok, frame} = Protocol.request(request)

    assert {:ok, {status, response}} =
             frame |> TodoWorker.__midgard_call__() |> Protocol.decode_response()

    {status, if(response == "", do: "", else: Jason.decode!(response))}
  end
end
