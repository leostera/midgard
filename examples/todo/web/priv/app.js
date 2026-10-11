(() => {
  "use strict";

  const token = document.querySelector('meta[name="csrf-token"]').content;
  const form = document.getElementById("create-form");
  const input = document.getElementById("new-title");
  const createButton = document.getElementById("create-button");
  const list = document.getElementById("task-list");
  const template = document.getElementById("task-template");
  const emptyState = document.getElementById("empty-state");
  const feedback = document.getElementById("feedback");
  const pending = new Set();

  function announce(message, error = false) {
    feedback.textContent = message;
    feedback.classList.toggle("is-error", error);
    feedback.setAttribute("role", error ? "alert" : "status");
  }

  function validTitle(value) {
    const title = value.trim();
    if (!title || new TextEncoder().encode(title).length > 160 || /[\r\n\0]/.test(title)) {
      throw new Error("Use a title of 1–160 bytes without a line break.");
    }
    return title;
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
      method: options.method || "GET",
      headers: {
        accept: "application/json",
        ...(options.body ? { "content-type": "application/json" } : {}),
        ...(options.method && options.method !== "GET" ? { "x-csrf-token": token } : {})
      },
      body: options.body ? JSON.stringify(options.body) : undefined,
      cache: "no-store",
      credentials: "same-origin"
    });

    if (response.status === 204) return null;

    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "The request did not complete. Try again.");
    return data;
  }

  function taskRow(todo) {
    const row = template.content.firstElementChild.cloneNode(true);
    row.dataset.id = String(todo.id);
    row.classList.toggle("is-done", todo.completed);
    row.querySelector(".task-title").textContent = todo.title;
    const toggle = row.querySelector('[data-action="toggle"]');
    toggle.setAttribute("aria-pressed", String(todo.completed));
    toggle.setAttribute("aria-label", `${todo.completed ? "Mark task incomplete" : "Mark task complete"}: ${todo.title}`);
    const editInput = row.querySelector(".edit-input");
    editInput.id = `edit-title-${todo.id}`;
    editInput.value = todo.title;
    row.querySelector(".edit-form label").htmlFor = editInput.id;
    return row;
  }

  function render(todos) {
    const fragment = document.createDocumentFragment();
    for (const todo of todos) fragment.append(taskRow(todo));
    list.replaceChildren(fragment);
    emptyState.hidden = todos.length > 0;

    const done = todos.filter((todo) => todo.completed).length;
    const percent = todos.length ? Math.round((done / todos.length) * 100) : 0;
    document.getElementById("task-count").textContent = `${todos.length - done} open · ${done} done`;
    document.getElementById("progress-count").textContent = `${done} of ${todos.length} complete`;
    document.getElementById("progress-percent").textContent = `${percent}%`;
    document.getElementById("progress-track").value = percent;
    document.getElementById("session-number").textContent = String(todos.length).padStart(2, "0");
  }

  async function refresh() {
    const { todos } = await api("/api/todos");
    render(todos);
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      const title = validTitle(input.value);
      createButton.disabled = true;
      await api("/api/todos", { method: "POST", body: { title } });
      input.value = "";
      await refresh();
      announce("Task added.");
      input.focus();
    } catch (error) {
      announce(error.message || "Could not add the task.", true);
    } finally {
      createButton.disabled = false;
    }
  });

  list.addEventListener("click", async (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) return;
    const row = button.closest(".task-row");
    if (!row) return;
    const id = row.dataset.id;
    if (pending.has(id)) return;

    const action = button.dataset.action;
    if (action === "edit") {
      row.querySelector(".task-title").hidden = true;
      row.querySelector(".edit-form").hidden = false;
      row.querySelector(".edit-input").focus();
      return;
    }
    if (action === "cancel") {
      row.querySelector(".edit-form").hidden = true;
      row.querySelector(".task-title").hidden = false;
      return;
    }
    if (action === "delete" && button.dataset.confirm !== "true") {
      button.dataset.confirm = "true";
      button.classList.add("is-confirming");
      button.textContent = "Confirm remove";
      window.setTimeout(() => {
        if (button.isConnected) {
          button.dataset.confirm = "false";
          button.classList.remove("is-confirming");
          button.textContent = "Remove";
        }
      }, 4000);
      return;
    }

    pending.add(id);
    button.disabled = true;
    try {
      if (action === "toggle") {
        const completed = button.getAttribute("aria-pressed") !== "true";
        await api(`/api/todos/${id}`, { method: "PATCH", body: { completed } });
        announce(completed ? "Task marked done." : "Task returned to open.");
      } else if (action === "delete") {
        await api(`/api/todos/${id}`, { method: "DELETE" });
        announce("Task removed.");
      }
      await refresh();
    } catch (error) {
      announce(error.message || "Could not update the task.", true);
      button.disabled = false;
    } finally {
      pending.delete(id);
    }
  });

  list.addEventListener("submit", async (event) => {
    if (!event.target.matches(".edit-form")) return;
    event.preventDefault();
    const row = event.target.closest(".task-row");
    const id = row.dataset.id;
    if (pending.has(id)) return;
    pending.add(id);
    const save = event.target.querySelector('button[type="submit"]');
    try {
      const title = validTitle(event.target.querySelector(".edit-input").value);
      save.disabled = true;
      await api(`/api/todos/${id}`, { method: "PATCH", body: { title } });
      await refresh();
      announce("Task updated.");
    } catch (error) {
      announce(error.message || "Could not save the task.", true);
      save.disabled = false;
    } finally {
      pending.delete(id);
    }
  });

  refresh().catch((error) => announce(error.message || "Could not load tasks. Reload to try again.", true));
})();
