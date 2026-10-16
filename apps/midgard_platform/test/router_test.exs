defmodule MidgardPlatformRouterTest do
  use ExUnit.Case, async: false
  alias Midgard.Platform.{BuildInfo, Router, Traffic, Workspace}

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

    {:ok, root: root}
  end

  test "the local dashboard creates a worker and escapes source in the editor" do
    assert response(:get, "/").status == 200
    assert response(:get, "/workers/new").resp_body =~ "Create worker"

    assert :ok = Workspace.create("hello_local")

    assert {:ok, %{source: source}} = Workspace.read("hello_local")
    assert source =~ "defmodule HelloLocal do"
    assert source =~ ~S(path: "/hello/" <> name)
    assert source =~ ~S(Hello, #{name}!)

    editor = response(:get, "/workers/hello_local")
    assert editor.resp_body =~ "Compile &amp; deploy"
    assert editor.resp_body =~ "src='/assets/editor.js'"
    refute response(:get, "/").resp_body =~ "src='/assets/editor.js'"
    assert response(:get, "/assets/editor.js").status == 200

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

  test "sidebar links to the current Midgard GitHub commit and omits invalid checkout data", %{
    root: root
  } do
    assert %{sha: sha, short: short, url: url} = BuildInfo.current_commit()
    assert Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)
    assert short == String.slice(sha, 0, 7)
    assert url == "https://github.com/leostera/midgard/commit/" <> sha

    html = response(:get, "/").resp_body
    assert html =~ "href='#{url}'"
    assert html =~ "Commit <code>#{short}</code>"
    refute html =~ "Local workspace"

    assert BuildInfo.current_commit(root) == nil
  end

  test "a packaged source revision overrides Git lookup and rejects invalid labels", %{root: root} do
    original = System.get_env("MIDGARD_SOURCE_COMMIT")

    on_exit(fn ->
      if original,
        do: System.put_env("MIDGARD_SOURCE_COMMIT", original),
        else: System.delete_env("MIDGARD_SOURCE_COMMIT")
    end)

    sha = String.duplicate("a", 40)
    System.put_env("MIDGARD_SOURCE_COMMIT", sha)
    assert %{sha: ^sha, short: "aaaaaaa"} = BuildInfo.current_commit(root)

    System.put_env("MIDGARD_SOURCE_COMMIT", "../other-checkout")
    assert BuildInfo.current_commit() == nil
  end

  test "invalid forms and cross-host requests cannot create or compile workers" do
    assert response(:post, "/workers", %{"csrf" => "wrong", "name" => "attack"}).status == 422

    assert response(:post, "/workers", %{"csrf" => "test-token", "name" => "../attack"}).status ==
             422

    assert :ok = Workspace.create("worker")

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

  test "search, status filters, sorting and pagination work without JavaScript" do
    for n <- 1..30 do
      assert :ok = Workspace.create("worker_#{n}")
    end

    assert :ok = Workspace.record_invocation("worker_29")
    assert :ok = Workspace.record_invocation("worker_29")
    assert :ok = Workspace.record_invocation("worker_1")

    first = response(:get, "/")
    assert first.resp_body =~ "Showing 1–25 of 30"
    assert first.resp_body =~ "Next"
    refute first.resp_body =~ "href='/workers/worker_9'"

    second = response(:get, "/?page=2")
    assert second.resp_body =~ "Showing 26–30 of 30"
    assert second.resp_body =~ "href='/workers/worker_9'"

    searched = response(:get, "/?q=worker_29&sort=invocations")
    assert searched.resp_body =~ "Showing 1–1 of 1"
    assert searched.resp_body =~ "href='/workers/worker_29'"
    refute searched.resp_body =~ "href='/workers/worker_1'"

    filtered = response(:get, "/?q=worker_29&status=deployed")
    assert filtered.resp_body =~ "No matching workers"
    assert response(:get, "/?q=worker_29&status=drafts").resp_body =~ "href='/workers/worker_29'"
    assert response(:get, "/?q=%3Cscript%3E").resp_body =~ "No matching workers"
    refute response(:get, "/?q=%3Cscript%3E").resp_body =~ "<script>"
  end

  test "invocation totals survive workspace restarts and malformed files are not reported as zero",
       %{root: root} do
    assert :ok = Workspace.create("counted")
    assert %{invocations: 0, last_invoked_at: nil} = elem(Traffic.read(root, "counted"), 1)
    assert :ok = Workspace.record_invocation("counted")
    assert :ok = Workspace.record_invocation("counted")
    assert [%{invocations: 2, last_invoked_at: last}] = Workspace.list()
    assert is_integer(last)
    assert response(:get, "/").resp_body =~ "Invocations"

    GenServer.stop(Process.whereis(Workspace))
    {:ok, _workspace} = Workspace.start_link(root: root)
    assert [%{invocations: 2, last_invoked_at: ^last}] = Workspace.list()
    assert :ok = Workspace.record_invocation("counted")
    assert [%{invocations: 3}] = Workspace.list()

    File.write!(Path.join([root, "workers", "counted", "traffic.tsv"]), "invalid")
    assert {:error, :invalid_traffic_file} = Workspace.record_invocation("counted")
    assert [%{invocations: nil}] = Workspace.list()
    assert response(:get, "/").resp_body =~ "Invocation history unavailable"
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
