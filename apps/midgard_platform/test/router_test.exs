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

  test "container dashboard does not advertise a working create path" do
    System.put_env("MIDGARD_CONTAINER_HTTP", "1")
    on_exit(fn -> System.delete_env("MIDGARD_CONTAINER_HTTP") end)

    html = response(:get, "/").resp_body
    assert html =~ "href='/workers/new'"
    assert html =~ "Build locally with Midgard"
    assert response(:get, "/workers/new").resp_body =~ "mix midgard.new hello_worker"
  end

  test "the local dashboard creates a worker and escapes source in the editor" do
    assert response(:get, "/").status == 200
    assert response(:get, "/workers/new").resp_body =~ "mix midgard.deploy"

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

  test "inventory sorts verified languages and does not claim an unimplemented example path" do
    slug = "hello_joe_0123456789abcdef"

    record = %{
      slug: slug,
      live: %{
        modules: 342,
        digest: String.duplicate("a", 64),
        protocol: :midgard,
        language: :elixir
      },
      origin: :cli,
      invocations: 0,
      last_invoked_at: nil
    }

    html = Midgard.Platform.Page.index([record])
    refute html =~ "<th scope='col'>Route prefix</th>"
    refute html =~ "<code class='route'>/run/"
    assert html =~ "sort=language"
    assert html =~ "<td>Elixir</td>"
    refute html =~ "Try /hello"
    assert html =~ "href='/workers/#{slug}'"

    erlang = %{
      record
      | slug: "z_erlang",
        live: %{record.live | language: :erlang, protocol: :raw}
    }

    gleam = %{record | slug: "a_gleam", live: %{record.live | language: :gleam, protocol: :raw}}
    draft = %{record | slug: "b_draft", live: nil}
    sorted = Midgard.Platform.Page.index([draft, gleam, erlang, record], %{"sort" => "language"})
    {elixir_at, _} = :binary.match(sorted, "href='/workers/#{slug}'")
    {erlang_at, _} = :binary.match(sorted, "href='/workers/z_erlang'")
    {gleam_at, _} = :binary.match(sorted, "href='/workers/a_gleam'")
    {draft_at, _} = :binary.match(sorted, "href='/workers/b_draft'")
    assert elixir_at < erlang_at and erlang_at < gleam_at and gleam_at < draft_at

    details = Midgard.Platform.Page.uploaded_worker(slug, record, 4000)
    assert details =~ "http://127.0.0.1:4000/run/#{slug}/"
    refute details =~ "Try GET /hello"

    raw_details = Midgard.Platform.Page.uploaded_worker("z_erlang", erlang, 4000)
    assert raw_details =~ "Open text preview"
    assert raw_details =~ "POST to the route root"
    assert raw_details =~ "--data-binary 'hello'"
    assert sorted =~ "href='/run/z_erlang/'"
    assert raw_details =~ "http://127.0.0.1:4000/run/z_erlang/"
  end

  test "raw-byte workers serve a text GET preview and bounded exact binary POSTs", %{root: root} do
    source = Path.join(root, "raw_echo.erl")
    File.write!(source, "-module(raw_echo).\n-export([handle/1]).\nhandle(Bytes) -> Bytes.\n")
    assert {:ok, :raw_echo, beam} = :compile.file(String.to_charlist(source), [:binary])
    shipment = Path.join(root, "raw_echo.midgard")

    assert {:ok, ^shipment} =
             Packer.Artifact.build(
               shipment,
               "raw_echo",
               "raw_echo",
               [
                 %{name: "raw_echo", owner: "raw_echo", bytes: beam}
               ],
               [],
               function: "handle",
               protocol: "raw.bytes.v1"
             )

    assert {:ok, %{protocol: :raw, language: :erlang}} =
             Midgard.Platform.Shipment.read(shipment)

    {:ok, platform} = Midgard.Platform.start_link()
    Process.unlink(platform)
    on_exit(fn -> if Process.alive?(platform), do: Supervisor.stop(platform) end)
    assert :ok = Workspace.begin_upload("raw_echo")
    assert {:ok, digest} = Midgard.Platform.deploy("raw_echo", shipment)

    assert {:ok, nil} =
             Workspace.finish_deploy(
               "raw_echo",
               {:ok,
                %{id: "raw_echo", digest: digest, modules: 1, protocol: :raw, language: :erlang}}
             )

    route = "http://127.0.0.1/run/raw_echo/"
    input = <<0, 255, "hello">>

    reply = Plug.Test.conn(:post, route, input) |> Router.call(Router.init([]))
    assert reply.status == 200
    assert reply.resp_body == input

    assert Plug.Conn.get_resp_header(reply, "content-type") == ["application/octet-stream"]

    preview = Plug.Test.conn(:get, route) |> Router.call(Router.init([]))
    assert preview.status == 200
    assert preview.resp_body == "hello"
    assert Plug.Conn.get_resp_header(preview, "content-type") == ["text/plain; charset=utf-8"]

    named = Plug.Test.conn(:get, route <> "?input=Hello%20Joe") |> Router.call(Router.init([]))
    assert named.status == 200
    assert named.resp_body == "Hello Joe"

    binary = Plug.Test.conn(:get, route <> "?input=%00") |> Router.call(Router.init([]))
    assert binary.status == 200
    assert binary.resp_body == "Binary response (hex): 00\n"

    method = Plug.Test.conn(:put, route) |> Router.call(Router.init([]))
    assert method.status == 405
    assert Plug.Conn.get_resp_header(method, "allow") == ["GET, POST"]

    assert Plug.Test.conn(:post, route <> "hello", input)
           |> Router.call(Router.init([]))
           |> Map.get(:status) == 404

    assert Plug.Test.conn(:get, route <> "?q=1")
           |> Router.call(Router.init([]))
           |> Map.get(:status) == 400

    assert Plug.Test.conn(:post, route <> "?q=1", input)
           |> Router.call(Router.init([]))
           |> Map.get(:status) == 400

    assert Plug.Test.conn(:post, route, :binary.copy("x", 32_769))
           |> Router.call(Router.init([]))
           |> Map.get(:status) == 413

    assert [%{invocations: 4}] = Workspace.list()

    old_container = System.get_env("MIDGARD_CONTAINER_HTTP")
    old_key = System.get_env("MIDGARD_INTERNAL_UPLOAD_KEY")
    key = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    System.put_env("MIDGARD_CONTAINER_HTTP", "1")
    System.put_env("MIDGARD_INTERNAL_UPLOAD_KEY", key)

    on_exit(fn ->
      if old_container,
        do: System.put_env("MIDGARD_CONTAINER_HTTP", old_container),
        else: System.delete_env("MIDGARD_CONTAINER_HTTP")

      if old_key,
        do: System.put_env("MIDGARD_INTERNAL_UPLOAD_KEY", old_key),
        else: System.delete_env("MIDGARD_INTERNAL_UPLOAD_KEY")
    end)

    state_url = "http://127.0.0.1/api/deployments/state"

    assert Plug.Test.conn(:get, state_url) |> Router.call(Router.init([])) |> Map.get(:status) ==
             403

    state =
      Plug.Test.conn(:get, state_url)
      |> Plug.Conn.put_req_header("x-midgard-internal-upload", "Bearer " <> key)
      |> Router.call(Router.init([]))

    assert state.status == 200
    assert [%{"slug" => "raw_echo", "digest" => ^digest}] = :json.decode(state.resp_body)

    assert :ok = Midgard.Platform.stop("raw_echo")

    stale =
      Plug.Test.conn(:get, state_url)
      |> Plug.Conn.put_req_header("x-midgard-internal-upload", "Bearer " <> key)
      |> Router.call(Router.init([]))

    assert stale.status == 503
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

  test "shipment upload rejects unauthenticated or malformed input before creating a worker" do
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    System.put_env("MIDGARD_DEPLOY_TOKEN", token)
    on_exit(fn -> System.delete_env("MIDGARD_DEPLOY_TOKEN") end)

    url = "http://127.0.0.1/api/deployments/demo"
    payload = <<"MIDGARD-SHIPMENT-1\n", 0::32, 0::16>>

    unauthenticated =
      Plug.Test.conn(:post, url, payload)
      |> Plug.Conn.put_req_header("content-type", Packer.ShipmentUpload.content_type())
      |> Router.call(Router.init([]))

    assert unauthenticated.status == 401
    assert Workspace.list() == []

    malformed =
      Plug.Test.conn(:post, url, payload)
      |> Plug.Conn.put_req_header("content-type", Packer.ShipmentUpload.content_type())
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert malformed.status == 422
    assert Workspace.list() == []
  end

  test "the container gateway removes uploaded workers, and nobody else can" do
    gateway = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    System.put_env("MIDGARD_CONTAINER_HTTP", "1")
    System.put_env("MIDGARD_INTERNAL_UPLOAD_KEY", gateway)

    on_exit(fn ->
      System.delete_env("MIDGARD_CONTAINER_HTTP")
      System.delete_env("MIDGARD_INTERNAL_UPLOAD_KEY")
    end)

    remove = fn slug, key ->
      conn = Plug.Test.conn(:delete, "http://127.0.0.1/api/deployments/" <> slug)

      conn =
        if key,
          do: Plug.Conn.put_req_header(conn, "x-midgard-internal-upload", "Bearer " <> key),
          else: conn

      Router.call(conn, Router.init([])).status
    end

    assert :ok = Workspace.begin_upload("uploaded_0123456789abcdef")
    assert remove.("uploaded_0123456789abcdef", gateway) == 409
    assert {:ok, nil} = Workspace.finish_deploy("uploaded_0123456789abcdef", :failed)
    assert :ok = Workspace.create("edited")

    assert remove.("uploaded_0123456789abcdef", nil) == 403
    assert remove.("uploaded_0123456789abcdef", String.duplicate("0", 64)) == 403
    assert remove.("edited", gateway) == 409
    assert remove.("missing_0123456789abcdef", gateway) == 404
    assert remove.("uploaded_0123456789abcdef", gateway) == 204
    assert Enum.map(Workspace.list(), & &1.slug) == ["edited"]
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
