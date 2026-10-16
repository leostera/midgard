defmodule Midgard.Platform.Page do
  @moduledoc false
  alias Plug.HTML

  def index(workers) do
    content = [
      "<section class='page-head'><div><h1>Workers</h1><p>Create an Elixir worker, deploy it into its own Isolate, then call its local URL.</p></div>",
      "<a class='button primary' href='/workers/new'>Create worker</a></section>",
      "<section class='workspace'><div class='section-head'><h2>Your workspace</h2><span class='count'>#{length(workers)} #{if length(workers) == 1, do: "worker", else: "workers"}</span></div>",
      if(workers == [], do: empty(), else: table(workers)),
      "</section>",
      "<p class='footnote'>Local development only · Source compiles in a restricted container · Deployed BEAMs run in libbeam Isolates</p>"
    ]

    layout("Workers", content)
  end

  def new_worker(token, error \\ nil) do
    layout("Create worker", [
      "<nav class='crumb'><a href='/'>Workers</a><span aria-hidden='true'>/</span><span>New worker</span></nav>",
      "<section class='page-head'><div><h1>Create worker</h1><p>Give it a URL-safe name. We’ll prepare an Elixir starter you can edit before deploying.</p></div></section>",
      error_notice(error, "Could not create worker."),
      "<form class='create-form workspace' method='post' action='/workers'>",
      hidden_token(token),
      "<label for='name'>Worker name</label><input id='name' name='name' type='text' required autofocus maxlength='40' pattern='[a-z][a-z0-9_]*' placeholder='hello_world' autocomplete='off' aria-describedby='name-help'>",
      "<p id='name-help' class='field-help'>Lowercase letters, numbers and underscores. Starts with a letter.</p>",
      "<div class='form-actions'><button class='button primary' type='submit'>Create worker</button><a class='button quiet' href='/'>Cancel</a></div></form>"
    ])
  end

  def editor(slug, source, record, token, port, error \\ nil) do
    live = record.live

    status =
      cond do
        record.busy -> "Deploying"
        live -> "Deployed"
        true -> "Draft"
      end

    address = "http://127.0.0.1:#{port}/run/#{slug}/hello"

    layout(slug, [
      "<nav class='crumb'><a href='/'>Workers</a><span aria-hidden='true'>/</span><span>",
      safe(slug),
      "</span></nav>",
      "<section class='page-head'><div><div class='title-row'><h1>",
      safe(slug),
      "</h1><span class='badge #{if live, do: "live", else: "draft"}'>",
      status,
      "</span></div>",
      "<p>Write <code>handle_request/1</code>. Deployment compiles your source separately, checks its complete BEAM closure, then starts an Isolate.</p></div></section>",
      error_notice(error),
      if(live,
        do: live_panel(address, live),
        else:
          "<div class='hint'>Not deployed yet. Edit the starter below, then deploy to create a callable URL.</div>"
      ),
      "<form method='post' action='/workers/",
      safe(slug),
      "/deploy' class='editor-form'>",
      hidden_token(token),
      "<div class='editor-heading'><div><label for='source'>Elixir source</label><p>Changes are saved when you deploy. Compilation can run Elixir macros inside the isolated compiler container.</p></div>",
      "<button class='button primary' type='submit'",
      if(record.busy, do: " disabled", else: ""),
      ">Compile &amp; deploy</button></div>",
      "<textarea id='source' name='source' spellcheck='false' autocapitalize='off' autocomplete='off' autocorrect='off' required aria-describedby='editor-note'>",
      safe(source),
      "</textarea>",
      "<div id='editor-note' class='editor-footer'><span>Elixir · max 64 KiB</span><span>One worker module and its nested modules</span></div></form>",
      "<p class='footnote'>Trusted local workspace · Existing deployments remain callable if compilation or admission fails.</p>"
    ])
  end

  def not_found do
    layout("Not found", [
      "<section class='page-head'><div><h1>Worker not found</h1><p>This worker isn't in your local workspace.</p></div></section>",
      "<a class='button primary' href='/'>Back to workers</a>"
    ])
  end

  defp table(workers) do
    ["<div class='worker-list' role='list'>", Enum.map(workers, &worker_row/1), "</div>"]
  end

  defp worker_row(worker) do
    [
      "<a class='worker-row' role='listitem' href='/workers/",
      safe(worker.slug),
      "'>",
      "<span class='worker-mark' aria-hidden='true'>",
      String.first(worker.slug) |> String.upcase() |> safe(),
      "</span>",
      "<span class='worker-name'><strong>",
      safe(worker.slug),
      "</strong><small>",
      if(worker.live, do: "Ready to receive requests", else: "Source saved · not deployed"),
      "</small></span>",
      "<span class='badge #{if worker.live, do: "live", else: "draft"}'>",
      if(worker.live, do: "Deployed", else: "Draft"),
      "</span>",
      "<span class='row-action'>Open</span></a>"
    ]
  end

  defp empty do
    "<div class='empty-state'><h3>Nothing deployed. Plenty of room.</h3><p>Your workers will appear here as you create them. Each gets its own source, deployment and URL.</p><a href='/workers/new'>Create your first worker</a></div>"
  end

  defp live_panel(address, live) do
    [
      "<section class='live-panel' aria-label='Live deployment'><div><div class='live-label'><span class='status-dot' aria-hidden='true'></span> Live endpoint</div>",
      "<a class='endpoint' href='",
      safe(address),
      "' target='_blank' rel='noopener noreferrer'>",
      safe(address),
      "</a>",
      "<p>Open this URL or call it with curl. The path after the worker name becomes your worker’s request path.</p></div>",
      "<div class='deployment-meta'><span>",
      Integer.to_string(live.modules),
      " BEAMs</span><span>SHA ",
      safe(String.slice(live.digest, 0, 12)),
      "</span></div></section>"
    ]
  end

  defp error_notice(reason, title \\ "Couldn't deploy this change.")
  defp error_notice(nil, _title), do: ""

  defp error_notice(reason, title) do
    message =
      case reason do
        value when is_binary(value) -> value
        value when is_atom(value) -> value |> Atom.to_string() |> String.replace("_", " ")
        _ -> "Could not complete this action. Please try again."
      end

    [
      "<div class='error-notice' role='alert'><strong>",
      safe(title),
      "</strong><pre>",
      safe(message),
      "</pre></div>"
    ]
  end

  defp hidden_token(token), do: ["<input type='hidden' name='csrf' value='", safe(token), "'>"]
  defp safe(value), do: HTML.html_escape_to_iodata(value)

  defp layout(title, content) do
    IO.iodata_to_binary([
      "<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>",
      "<meta name='color-scheme' content='light'><title>",
      safe(title),
      " · Midgard</title>",
      "<link rel='icon' type='image/svg+xml' href='/assets/favicon.svg'><link rel='stylesheet' href='/assets/app.css'></head><body>",
      "<header class='site-header'><a class='brand' href='/' aria-label='Midgard workers'><span class='brand-emblem' aria-hidden='true'>m</span><span>midgard</span></a><span class='local-chip'><span aria-hidden='true'></span> Local workspace</span></header>",
      "<main class='main'>",
      content,
      "</main></body></html>"
    ])
  end
end
