defmodule Midgard.Platform.Page do
  @moduledoc false
  alias Plug.HTML

  @page_size 25

  def index(workers, params \\ %{}) do
    filters = filters(params)
    matching = workers |> filter_workers(filters) |> sort_workers(filters.sort)
    pages = max(1, div(length(matching) + @page_size - 1, @page_size))
    page = min(filters.page, pages)
    visible = Enum.slice(matching, (page - 1) * @page_size, @page_size)

    layout("Workers", [
      "<section class='page-head'><div><h1>Workers</h1><p>Your local worker inventory</p></div>",
      "<a class='button primary' href='/workers/new'>Create worker</a></section>",
      "<section class='registry' aria-label='Worker inventory'>",
      "<div class='registry-toolbar'><form class='search-form' action='/' method='get' role='search'>",
      "<label class='sr-only' for='worker-search'>Search workers</label>",
      "<input id='worker-search' name='q' type='search' value='",
      safe(filters.q),
      "' placeholder='Search by name or route' maxlength='80'>",
      "<input type='hidden' name='status' value='",
      safe(filters.status),
      "'>",
      "<input type='hidden' name='sort' value='",
      safe(filters.sort),
      "'>",
      "<button class='button secondary' type='submit'>Search</button></form>",
      "<nav class='filters' aria-label='Worker status'>",
      filter_link("All", "all", filters),
      filter_link("Deployed", "deployed", filters),
      filter_link("Drafts", "drafts", filters),
      "<span class='result-count'>",
      Integer.to_string(length(matching)),
      if(length(matching) == 1, do: " worker", else: " workers"),
      "</span></nav></div>",
      if(workers == [],
        do: empty(),
        else: table(visible, filters, page, pages, length(matching))
      ),
      "</section>",
      "<p class='footnote'>Invocation counts are per worker across redeployments. They include valid requests routed to a live worker, including failures. Local development only.</p>"
    ])
  end

  def new_worker(token, error \\ nil) do
    layout("Create worker", [
      crumb("New worker"),
      "<section class='page-head detail-head'><div><h1>Create worker</h1><p>Name your worker, then edit its starter source before deploying.</p></div></section>",
      error_notice(error, "Could not create worker."),
      "<form class='create-form' method='post' action='/workers'>",
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
      crumb(slug),
      "<section class='page-head detail-head'><div><div class='title-row'><h1>",
      safe(slug),
      "</h1><span class='badge #{if live, do: "live", else: "draft"}'>",
      status,
      "</span></div>",
      "<p>Write <code>handle_request/1</code>, then compile and deploy to a libbeam Isolate.</p></div></section>",
      error_notice(error),
      if(live,
        do: live_panel(address, live),
        else:
          "<div class='hint'>Not deployed yet. Edit the source below, then deploy to make the route callable.</div>"
      ),
      "<form method='post' action='/workers/",
      safe(slug),
      "/deploy' class='editor-form'>",
      hidden_token(token),
      "<div class='editor-heading'><div><label for='source'>Elixir source</label><p>Changes are saved when you deploy. Macros run inside the isolated compiler container.</p></div>",
      "<button class='button primary' type='submit'",
      if(record.busy, do: " disabled", else: ""),
      ">Compile &amp; deploy</button></div>",
      "<textarea id='source' name='source' wrap='off' spellcheck='false' autocapitalize='off' autocomplete='off' autocorrect='off' required aria-describedby='editor-note'>",
      safe(source),
      "</textarea>",
      "<div id='editor-note' class='editor-footer'><span>Elixir · max 64 KiB</span><span>One worker module and its nested modules</span></div></form>",
      "<p class='footnote'>Trusted local workspace · An existing deployment stays callable if this revision fails.</p>"
    ])
  end

  def not_found do
    layout("Not found", [
      "<section class='page-head detail-head'><div><h1>Worker not found</h1><p>This worker isn't in your local workspace.</p></div></section>",
      "<a class='button primary' href='/'>Back to workers</a>"
    ])
  end

  defp filters(params) do
    q = if is_binary(params["q"]), do: String.slice(params["q"], 0, 80), else: ""
    status = if params["status"] in ["deployed", "drafts"], do: params["status"], else: "all"
    sort = if params["sort"] in ["invocations", "recent"], do: params["sort"], else: "name"

    page_input = if is_binary(params["page"]), do: params["page"], else: "1"

    page =
      case Integer.parse(page_input) do
        {n, ""} when n in 1..1000 -> n
        _ -> 1
      end

    %{q: q, status: status, sort: sort, page: page}
  end

  defp filter_workers(workers, filters) do
    query = String.downcase(filters.q)

    Enum.filter(workers, fn worker ->
      (query == "" or String.contains?(worker.slug, query) or
         String.contains?("/run/#{worker.slug}/", query)) and
        case filters.status do
          "deployed" -> not is_nil(worker.live)
          "drafts" -> is_nil(worker.live)
          _ -> true
        end
    end)
  end

  defp sort_workers(workers, "invocations"),
    do: Enum.sort_by(workers, &{-(Map.get(&1, :invocations) || -1), &1.slug})

  defp sort_workers(workers, "recent"),
    do: Enum.sort_by(workers, &{-(Map.get(&1, :last_invoked_at) || -1), &1.slug})

  defp sort_workers(workers, _), do: Enum.sort_by(workers, & &1.slug)

  defp table([], _filters, _page, _pages, _total) do
    "<div class='empty-state'><h2>No matching workers</h2><p>Try another name or status.</p><a href='/'>Clear filters</a></div>"
  end

  defp table(workers, filters, page, pages, total) do
    [
      "<div class='table-scroll'><table class='worker-table'><thead><tr>",
      "<th scope='col'>",
      sort_link("Worker", "name", filters),
      "</th>",
      "<th scope='col'>Status</th>",
      "<th scope='col' class='numeric'>",
      sort_link("Invocations", "invocations", filters),
      "</th>",
      "<th scope='col'>",
      sort_link("Last invoked", "recent", filters),
      "</th>",
      "<th scope='col'>Route prefix</th><th scope='col'><span class='sr-only'>Open worker</span></th>",
      "</tr></thead><tbody>",
      Enum.map(workers, &worker_row/1),
      "</tbody></table></div><div class='table-footer'><span>Showing ",
      Integer.to_string((page - 1) * @page_size + 1),
      "–",
      Integer.to_string(min(page * @page_size, total)),
      " of ",
      Integer.to_string(total),
      "</span><nav class='pagination' aria-label='Worker pages'>",
      if(page > 1, do: page_link("Previous", page - 1, filters), else: "<span>Previous</span>"),
      if(page < pages, do: page_link("Next", page + 1, filters), else: "<span>Next</span>"),
      "</nav></div>"
    ]
  end

  defp worker_row(worker) do
    [
      "<tr><td><a class='worker-name' href='/workers/",
      safe(worker.slug),
      "'>",
      safe(worker.slug),
      "</a><small class='worker-type'>Elixir</small></td>",
      "<td><span class='badge #{if worker.live, do: "live", else: "draft"}'>",
      if(worker.live, do: "Deployed", else: "Draft"),
      "</span></td>",
      "<td class='numeric traffic'>",
      count(worker.invocations),
      "</td>",
      "<td>",
      if(is_nil(worker.invocations),
        do: "<span class='muted'>Unavailable</span>",
        else: last_invoked(worker.last_invoked_at)
      ),
      "</td>",
      "<td>",
      if(worker.live,
        do: ["<code class='route'>/run/", safe(worker.slug), "/</code>"],
        else: "<span class='muted'>Not deployed</span>"
      ),
      "</td>",
      "<td class='open-cell'><a href='/workers/",
      safe(worker.slug),
      "' aria-label='Open ",
      safe(worker.slug),
      "'>Open <span aria-hidden='true'>→</span></a></td></tr>"
    ]
  end

  defp count(nil), do: "<span class='muted' title='Invocation history unavailable'>—</span>"
  defp count(value), do: value |> Integer.to_string() |> group_digits() |> safe()

  defp group_digits(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp last_invoked(nil), do: "<span class='muted'>Never</span>"

  defp last_invoked(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, date} ->
        seconds = max(0, DateTime.diff(DateTime.utc_now(), date))

        label =
          cond do
            seconds < 60 -> "Just now"
            seconds < 3600 -> "#{div(seconds, 60)} min ago"
            seconds < 86_400 -> "#{div(seconds, 3600)} hours ago"
            true -> "#{div(seconds, 86_400)} days ago"
          end

        ["<time datetime='", safe(DateTime.to_iso8601(date)), "'>", safe(label), "</time>"]

      _ ->
        "<span class='muted'>Unavailable</span>"
    end
  end

  defp filter_link(label, status, filters) do
    [
      "<a class='filter",
      if(filters.status == status, do: " active", else: ""),
      "' href='",
      safe(url(%{filters | status: status, page: 1})),
      "'",
      if(filters.status == status, do: " aria-current='page'", else: ""),
      ">",
      label,
      "</a>"
    ]
  end

  defp sort_link(label, sort, filters) do
    [
      "<a href='",
      safe(url(%{filters | sort: sort, page: 1})),
      "'",
      if(filters.sort == sort, do: " aria-label='#{label}, sorted'", else: ""),
      ">",
      label,
      if(filters.sort == sort, do: " <span aria-hidden='true'>↓</span>", else: ""),
      "</a>"
    ]
  end

  defp page_link(label, page, filters),
    do: ["<a href='", safe(url(%{filters | page: page})), "'>", label, "</a>"]

  defp url(filters),
    do:
      "/?" <>
        URI.encode_query(%{
          q: filters.q,
          status: filters.status,
          sort: filters.sort,
          page: filters.page
        })

  defp empty do
    "<div class='empty-state'><h2>No workers yet</h2><p>Create your first worker to write source, deploy to an Isolate, and call its local route.</p><a href='/workers/new'>Create your first worker</a></div>"
  end

  defp crumb(label),
    do: [
      "<nav class='crumb' aria-label='Breadcrumb'><a href='/'>Workers</a><span aria-hidden='true'>/</span><span>",
      safe(label),
      "</span></nav>"
    ]

  defp live_panel(address, live) do
    [
      "<section class='live-panel' aria-label='Live deployment'><div><div class='live-label'><span class='status-dot' aria-hidden='true'></span> Live endpoint</div>",
      "<a class='endpoint' href='",
      safe(address),
      "' target='_blank' rel='noopener noreferrer'>",
      safe(address),
      "</a>",
      "<p>Open this URL or call it with curl. The path after the worker name becomes the worker's request path.</p></div>",
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
      "<div class='shell'><aside class='sidebar' aria-label='Product navigation'>",
      "<a class='brand' href='/' aria-label='Midgard workers'><span class='brand-emblem' aria-hidden='true'>m</span><span>midgard</span></a>",
      "<nav aria-label='Tools'><div class='nav-group'>Compute</div><a class='nav-link' href='/' aria-current='page'>Workers<span class='nav-indicator' aria-hidden='true'></span></a></nav>",
      "<div class='sidebar-spacer'></div><div class='local-chip'><span aria-hidden='true'></span>Local workspace</div></aside>",
      "<main class='main' id='main-content'>",
      content,
      "</main></div></body></html>"
    ])
  end
end
