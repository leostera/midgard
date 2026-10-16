/// <reference types="vite/client" />
import css from "./app.css?raw";
import favicon from "./favicon.svg?raw";

// Until public compilation and exact-shipment admission are isolated, this
// inventory intentionally has no fake rows or writable forms.
export const dashboardCss = css;
export const dashboardFavicon = favicon;

export const dashboardHtml = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>Workers · Midgard</title>
<link rel="icon" type="image/svg+xml" href="/assets/favicon.svg">
<link rel="stylesheet" href="/assets/app.css">
</head>
<body>
<div class="shell">
  <aside class="sidebar" aria-label="Product navigation">
    <a class="brand" href="/" aria-label="Midgard workers"><span class="brand-emblem" aria-hidden="true">m</span><span>midgard</span></a>
    <nav aria-label="Tools"><div class="nav-group">Compute</div><a class="nav-link" href="/" aria-current="page">Workers<span class="nav-indicator" aria-hidden="true"></span></a></nav>
    <div class="sidebar-spacer"></div>
    <div class="local-chip"><a href="https://github.com/leostera/midgard" rel="noopener noreferrer">Midgard on GitHub</a></div>
  </aside>
  <main class="main" id="main-content">
    <section class="page-head"><div><h1>Workers</h1><p>Public worker inventory</p></div><span class="button secondary" aria-disabled="true">Create worker · Not yet available</span></section>
    <section class="registry" aria-label="Worker inventory">
      <div class="registry-toolbar"><span class="result-count">0 workers</span></div>
      <div class="table-scroll"><table class="worker-table"><thead><tr><th scope="col">Worker</th><th scope="col">Status</th><th scope="col" class="numeric">Invocations</th><th scope="col">Last invoked</th><th scope="col">Route prefix</th></tr></thead></table></div>
      <div class="empty-state"><h2>No public workers yet</h2><p>Source compilation and deployment are being isolated before public creation opens. There are no callable worker routes yet.</p></div>
    </section>
    <p class="footnote">The native container is deployed for staging checks. A container boot does not mean a worker has been admitted or deployed.</p>
  </main>
</div>
</body>
</html>`;
