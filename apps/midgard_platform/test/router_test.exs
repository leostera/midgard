defmodule MidgardPlatformRouterTest do
  use ExUnit.Case, async: false
  alias Midgard.Platform.{Router, Workspace}

  setup do
    root =
      Path.join(System.tmp_dir!(), "midgard-router-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old = Application.get_env(:midgard_platform, :workspace)
    Application.put_env(:midgard_platform, :workspace, root)
    :persistent_term.put({Midgard.Platform, :csrf}, "test-token")
    {:ok, _store} = Workspace.start_link(root: root)

    on_exit(fn ->
      File.rm_rf!(root)
      :persistent_term.erase({Midgard.Platform, :csrf})

      if old,
        do: Application.put_env(:midgard_platform, :workspace, old),
        else: Application.delete_env(:midgard_platform, :workspace)
    end)

    :ok
  end

  test "the local dashboard creates a worker and escapes source in the editor" do
    assert response(:get, "/").status == 200
    assert response(:get, "/workers/new").resp_body =~ "Create worker"

    assert response(:post, "/workers", %{"csrf" => "test-token", "name" => "hello_local"}).status ==
             303

    assert {:ok, %{source: source}} = Workspace.read("hello_local")
    assert source =~ "defmodule HelloLocal do"

    assert response(:get, "/workers/hello_local").resp_body =~ "Compile &amp; deploy"

    html =
      Midgard.Platform.Page.editor(
        "hello_local",
        "</textarea><script>alert(1)</script>",
        %{busy: false, live: nil},
        "test-token",
        4000
      )

    refute html =~ "</textarea><script>"
    assert html =~ "&lt;/textarea&gt;&lt;script&gt;"
  end

  test "invalid forms and cross-host requests cannot create or compile workers" do
    assert response(:post, "/workers", %{"csrf" => "wrong", "name" => "attack"}).status == 422

    assert response(:post, "/workers", %{"csrf" => "test-token", "name" => "../attack"}).status ==
             422

    assert response(:post, "/workers", %{"csrf" => "test-token", "name" => "worker"}).status ==
             303

    assert response(:post, "/workers/worker/deploy", %{"csrf" => "wrong", "source" => "x"}).status ==
             422

    assert %{record: %{busy: false, live: nil}} = elem(Workspace.read("worker"), 1)

    forbidden =
      Plug.Test.conn(
        :post,
        "http://outside.example/workers",
        URI.encode_query(%{"csrf" => "test-token", "name" => "elsewhere"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Router.call(Router.init([]))

    assert forbidden.status == 403
    assert {:error, :not_found} = Workspace.read("elsewhere")
  end

  test "deployment lock prevents overlapping publishes of the same URL" do
    assert :ok = Workspace.create("single_owner")
    assert :ok = Workspace.begin_deploy("single_owner", "defmodule SingleOwner do end")

    assert {:error, :already_deploying} =
             Workspace.begin_deploy("single_owner", "defmodule SingleOwner do end")

    assert {:ok, nil} = Workspace.finish_deploy("single_owner", :failed)
    assert :ok = Workspace.begin_deploy("single_owner", "defmodule SingleOwner do end")
  end

  defp response(:get, path),
    do: Plug.Test.conn(:get, "http://127.0.0.1" <> path) |> Router.call(Router.init([]))

  defp response(:post, path, fields) do
    Plug.Test.conn(:post, "http://127.0.0.1" <> path, URI.encode_query(fields))
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(Router.init([]))
  end
end
