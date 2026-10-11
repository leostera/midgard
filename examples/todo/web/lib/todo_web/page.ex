defmodule TodoWeb.Page do
  @moduledoc "Server-rendered local to-do workspace; task text is HTML-escaped."

  def render(token, todos) when is_binary(token) and is_list(todos) do
    completed = Enum.count(todos, & &1.completed)
    open = length(todos) - completed
    progress = if todos == [], do: 0, else: round(completed * 100 / length(todos))
    rows = Enum.map_join(todos, "\n", &task_row/1)
    empty = if todos == [], do: "", else: " hidden"

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="csrf-token" content="#{escape(token)}">
      <meta name="theme-color" content="#20383b">
      <title>Tasks · Midgard</title>
      <link rel="icon" type="image/svg+xml" href="/favicon.svg">
      <link rel="stylesheet" href="/app.css">
      <script src="/app.js" defer></script>
    </head>
    <body>
      <a class="skip-link" href="#tasks">Skip to tasks</a>
      <header class="masthead">
        <div class="masthead-inner frame">
          <a class="brand" href="/" aria-label="Midgard Tasks home"><span class="brand-mark" aria-hidden="true">M</span><span>Midgard <strong>Tasks</strong></span></a>
          <span class="session-status"><span class="status-dot" aria-hidden="true"></span>Local session</span>
        </div>
      </header>
      <main class="frame workspace">
        <div class="workspace-grid">
          <section class="main-column" aria-labelledby="page-title">
            <div class="intro">
              <h1 id="page-title">The work in front of you.</h1>
              <p>One place for the next small thing. Your list lives in memory and starts fresh when this local server restarts.</p>
            </div>
            <form id="create-form" class="create-form" autocomplete="off">
              <label for="new-title">Add a task</label>
              <div class="create-line">
                <input id="new-title" name="title" type="text" maxlength="160" placeholder="What needs doing?" required>
                <button id="create-button" class="button button-primary" type="submit">Add task</button>
              </div>
              <p class="form-hint">Keep it short and actionable. Maximum 160 bytes.</p>
            </form>
            <section id="tasks" class="task-section" aria-labelledby="tasks-heading">
              <div class="task-heading"><div><h2 id="tasks-heading">Your tasks</h2><p class="task-subtitle" id="task-count" aria-live="polite">#{open} open · #{completed} done</p></div><span class="list-label">SESSION LIST</span></div>
              <div class="task-list-wrap">
                <ol id="task-list" class="task-list" aria-live="polite">#{rows}</ol>
                <div id="empty-state" class="empty-state"#{empty}><span class="empty-emblem" aria-hidden="true"></span><h3>Nothing on the list yet.</h3><p>Add one task above. You can change it, finish it, or remove it whenever you like.</p></div>
              </div>
              <p id="feedback" class="feedback" role="status" aria-live="polite"></p>
            </section>
          </section>
          <aside class="summary" aria-label="Session progress">
            <div class="summary-top"><h2>Work order</h2><span class="summary-number"><span id="session-number">#{String.pad_leading(Integer.to_string(length(todos)), 2, "0")}</span> TASKS</span></div>
            <p class="summary-claim">Making progress<br>is enough.</p>
            <p class="summary-description">Keep the list honest. No streaks, no deadlines, just what is done and what is next.</p>
            <div class="progress-info"><span id="progress-count">#{completed} of #{length(todos)} complete</span><strong id="progress-percent">#{progress}%</strong></div>
            <progress id="progress-track" class="progress-track" aria-label="Tasks completed" max="100" value="#{progress}">#{progress}%</progress>
            <div class="summary-bottom"><span>IN MEMORY</span><span>ORDINARY OTP</span></div>
          </aside>
        </div>
      </main>
      <footer class="site-footer frame"><span>Midgard · a local Elixir / Erlang example</span><span>Closing this server clears the list.</span></footer>
      <template id="task-template">
        <li class="task-row" data-id="">
          <button type="button" class="task-toggle" data-action="toggle" aria-label="Mark task complete" aria-pressed="false"><span class="toggle-mark" aria-hidden="true"></span></button>
          <div class="task-content"><span class="task-title"></span><span class="done-stamp" aria-hidden="true">DONE</span><form class="edit-form" hidden><label class="visually-hidden" for="edit-title-template">Edit task title</label><input class="edit-input" id="edit-title-template" type="text" maxlength="160" required><button class="button button-small" type="submit">Save</button><button class="text-button" type="button" data-action="cancel">Cancel</button></form></div>
          <div class="task-actions"><button type="button" class="text-button" data-action="edit">Edit</button><button type="button" class="text-button text-button-danger" data-action="delete">Remove</button></div>
        </li>
      </template>
    </body>
    </html>
    """
  end

  defp task_row(%{id: id, title: title, completed: completed}) do
    done_class = if completed, do: " is-done", else: ""
    checked = if completed, do: "true", else: "false"
    action = if completed, do: "Mark task incomplete", else: "Mark task complete"

    """
    <li class="task-row#{done_class}" data-id="#{id}">
      <button type="button" class="task-toggle" data-action="toggle" aria-label="#{action}: #{escape(title)}" aria-pressed="#{checked}"><span class="toggle-mark" aria-hidden="true"></span></button>
      <div class="task-content"><span class="task-title">#{escape(title)}</span><span class="done-stamp" aria-hidden="true">DONE</span><form class="edit-form" hidden><label class="visually-hidden" for="edit-title-#{id}">Edit task title</label><input class="edit-input" id="edit-title-#{id}" type="text" maxlength="160" value="#{escape(title)}" required><button class="button button-small" type="submit">Save</button><button class="text-button" type="button" data-action="cancel">Cancel</button></form></div>
      <div class="task-actions"><button type="button" class="text-button" data-action="edit">Edit</button><button type="button" class="text-button text-button-danger" data-action="delete">Remove</button></div>
    </li>
    """
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
