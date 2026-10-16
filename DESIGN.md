# Midgard local platform UI

The local workspace is an **Operate** surface: worker status, source and callable URL are visible without navigating through abstractions. The design records what is currently shipped in `apps/midgard_platform/lib/midgard/platform/page.ex` and `priv/static/app.css`; it is not a production branding claim.

- A deep green header anchors the local-only context. Mist-tinted page ground, paper-white working surfaces and green call-to-action make live/draft status distinct without relying on colour alone.
- Self-hosted Barlow Condensed is used for headings and product wordmark. System sans carries controls and explanations; monospace is reserved for source, code identifiers and hashes.
- The workspace listing is a single scannable row list. The editor owns the main working area; the live endpoint appears above it, so a deployed URL is not hidden below code. Compile/admission errors stay next to the editor and the prior URL remains callable.
- Creation uses a standard named form, not a modal. The editor is a labelled textarea, usable with keyboard and without JavaScript. Focus is visible, content is HTML-escaped, mobile controls stack without horizontal scrolling, and reduced-motion preference is respected.
- Local-only context is always visible. A green live badge and endpoint are shown only after native Isolate admission; an unadmitted or restarted worker is a draft, not a fabricated deployment.

Visual QA: `platform-empty-desktop.png`, `platform-deployed-desktop.png` and `platform-deployed-mobile.png` were captured in `.impeccable/review/` during the browser flow. The screenshots are working evidence, not shipped application assets.
