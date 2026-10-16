# Midgard

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

A developer working locally who wants to write an Elixir worker in a browser, deploy it, and call its URL.

## Product Purpose

Show deployed workers, let the developer create and edit an Elixir worker, deploy it into libbeam, and provide a callable URL for each deployment.

## Operating Context

Development starts with `iex -S mix` and opens a local browser. The developer submits source from the local web UI. The source is compiled in a separate restricted compiler container; BEAMs are shipped as a verified `.midgard/` artifact and executed by libbeam Isolates through the supervised Port binding.

## Capabilities and Constraints

- This first UI is a trusted local development tool bound to loopback, not a multi-user public code execution service.
- Browser-submitted Elixir source must never be compiled inside the platform's serving BEAM VM. Compiler-container failure must fail closed.
- libbeam Isolates execute unchanged BEAMs; they do not currently compile Elixir source. Each deployment has a separate runtime Isolate.
- Exact module names, dependency closure, artifact checksums and strict native admission remain required. Do not substitute the temporary 381-BEAM test bundle for a published artifact.
- The platform URL must route HTTP requests to the deployed worker and show meaningful compilation/admission errors.

## Evidence on Hand

The supervised Port binding and platform registry are in `apps/libbeam_elixir/` and `apps/midgard_platform/`. The full HelloWorker bundle runs at default limits as a temporary test bundle; its present 32-BEAM `.midgard/` package is incomplete. The existing Packer produces versioned `.midgard/` directories. No public authentication, upload security model, or production native ABI is established.

## Product Principles

1. A deploy button means verified code is actually admitted and callable, not merely compiled.
2. Keep compilation authority separate from the runtime Isolate and serving BEAM VM.
3. Fail visibly and safely at each boundary; never silently fall back to host compilation or fixture bundles.
4. Make the local edit → deploy → call loop direct, while naming its trusted-development scope.
