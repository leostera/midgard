defmodule TodoWeb.RouterTest do
  use ExUnit.Case, async: false

  @token "test-csrf-token"

  setup do
    Enum.each(:todo_store.list(), fn %{id: id} -> :ok = :todo_store.delete(id) end)
    :ok
  end

  test "local JSON API creates, lists, completes, edits and deletes tasks" do
    response = request(:post, "/api/todos", Jason.encode!(%{title: "  Draft release  "}))
    assert response.status == 201

    assert %{"todo" => %{"id" => id, "title" => "Draft release", "completed" => false}} =
             Jason.decode!(response.resp_body)

    response = request(:get, "/api/todos")
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["todos"] |> length() == 1

    response =
      request(
        :patch,
        "/api/todos/#{id}",
        Jason.encode!(%{completed: true, title: "Ship release"})
      )

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["todo"]["completed"] == true

    response = request(:delete, "/api/todos/#{id}")
    assert response.status == 204
    assert request(:get, "/api/todos").resp_body |> Jason.decode!() |> Map.fetch!("todos") == []
  end

  test "page renders current tasks safely with a token and serves local assets" do
    {:ok, _todo} = :todo_store.create("<img src=x onerror=alert(1)>")
    page = request(:get, "/")
    assert page.status == 200
    assert page.resp_body =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute page.resp_body =~ "<img src=x onerror=alert(1)>"
    assert page.resp_body =~ ~s(name="csrf-token" content="#{@token}")
    assert page.resp_body =~ "1 open · 0 done"
    assert Plug.Conn.get_resp_header(page, "content-security-policy") != []

    assert request(:get, "/app.css").status == 200
    assert request(:get, "/app.js").status == 200
    assert request(:get, "/favicon.svg").status == 200
    assert request(:get, "/favicon.ico").status == 204
    assert request(:get, "/fonts/BarlowCondensed-Bold.ttf").status == 200
    assert request(:get, "/fonts/../../mix.exs").status == 404
  end

  test "mutations require token and same origin" do
    missing_token = request(:post, "/api/todos", ~s({"title":"Denied"}), csrf: nil)
    assert missing_token.status == 403

    wrong_origin =
      request(:post, "/api/todos", ~s({"title":"Denied"}), origin: "http://evil.example")

    assert wrong_origin.status == 403
    assert request(:get, "/api/todos").resp_body |> Jason.decode!() |> Map.fetch!("todos") == []
  end

  test "rejects foreign hosts, malformed and oversized requests" do
    conn = Plug.Test.conn(:get, "http://evil.example/api/todos")
    assert TodoWeb.Router.call(conn, TodoWeb.Router.init(csrf_token: @token)).status == 403

    assert request(:post, "/api/todos", "{broken").status == 400
    assert request(:post, "/api/todos", String.duplicate("x", 32_769)).status == 413

    assert request(:post, "/api/todos", Jason.encode!(%{title: String.duplicate("x", 161)})).status ==
             400
  end

  defp request(method, path, body \\ "", options \\ []) do
    conn = Plug.Test.conn(method, "http://127.0.0.1:4100#{path}", body)
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")

    conn =
      if Keyword.get(options, :csrf, @token) do
        Plug.Conn.put_req_header(conn, "x-csrf-token", Keyword.get(options, :csrf, @token))
      else
        conn
      end

    conn =
      case Keyword.get(options, :origin, "http://127.0.0.1:4100") do
        nil -> conn
        origin -> Plug.Conn.put_req_header(conn, "origin", origin)
      end

    TodoWeb.Router.call(conn, TodoWeb.Router.init(csrf_token: @token))
  end
end
