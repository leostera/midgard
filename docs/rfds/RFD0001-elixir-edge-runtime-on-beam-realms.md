# RFD0001 - Elixir edge runtime on BEAM Realms

- Feature Name: `elixir-edge-runtime`
- Status: Superseded historical proposal; see [the libbeam artifact contract](../libbeam-artifact-contract.md). The Realm prototype and its Phoenix runtime were removed. The Realm APIs described below do not exist in the current libbeam checkout.
- Author: Leandro Ostera
- Start Date: 2026-10-07

## Summary

Build a Workers-like service platform in Elixir on top of the Realm-enabled OTP fork. A trusted Elixir host accepts HTTP requests, selects a versioned deployment, activates and supervises a warm Realm instance, and invokes a handler through explicit, bounded host-to-Realm channels. The Realm is the execution unit; deployment identity, routing, storage, and host capabilities belong to the platform. The first implementation runs **trusted, preloaded fixtures only**. Uploading mutually untrusted deployments to a shared VM is gated on the OTP fork's isolation, private code environments, and security validation; this RFD does not assert that those exist today.

## Motivation

A warm BEAM can host many lightweight processes, but ordinary OTP applications do not isolate independently operated services. The OTP fork proposes Realms as the unit of process identity, lifecycle, and eventual resource and authority isolation. We need a platform above that primitive: a way to package a handler, select a version for a request, start it without giving it host authority, exchange request/response bytes, and replace or stop it cleanly. Operators should be able to deploy two versions, route traffic to one, roll back, and observe what happened without managing raw PIDs or Realm handles.

Today this repository has no application implementation or deployment contract. The fork's experimental APIs provide Realm creation, inherited process membership, stop, and bounded byte channels, but not independent code loading or a sandbox. Starting from HTTP routing and a trusted fixture lets us test the platform lifecycle without mistaking the prototype for a safe multi-tenant runtime.

## Goals

- Specify a small Elixir handler and deployment contract for request/response services.
- Separate trusted host control from Realm execution and host-mediated services.
- Support one warm Realm instance serving multiple bounded, concurrent requests, with versioned activation, draining, and rollback.
- Make failures, resource ownership, and the trust level of each rollout stage explicit.
- Keep protocol and deployment concepts independent of experimental `erts_internal` names where possible.

## Non-goals

- Claiming that the current OTP fork safely executes hostile code.
- Implementing private code environments, BIF/native restrictions, or Realm resource isolation in Elixir.
- A distributed Realm, live migration, transparent distributed Erlang, or one Realm per request.
- Durable actor semantics, globally consistent state, automatic retries of side-effecting requests, or full Cloudflare Workers API compatibility.
- Streaming bodies, WebSockets, and arbitrary outbound network/OS access in the first slice.

## Guide-level explanation

A **deployment** is an immutable version of a service: code artifact, handler entry point, configuration, requested capabilities, and resource policy. A **route** selects a deployment version. A **Realm instance** is an ephemeral activation of that version on one BEAM node; multiple instances may serve the same deployment. A request is not a Realm. User state that must survive an instance restart lives in an external service, not in its process heap.

The host owns the listener, deployment metadata, Realm management handles, route table, and capability brokers. A deployment handler sees a validated request and returns a response; it does not receive a host PID or a management handle. A host-mediated service, when implemented, authorizes operations using the runtime-bound Realm and a host-owned grant, never a claimed identity in request bytes.

### Example flow

1. An operator registers version `v2` of `hello` with handler `Hello.Handler` and an HTTP route. In the first slice the module is a **preloaded trusted fixture**; registering arbitrary uploaded BEAM files is unsupported.
2. The host prepares a Realm and bounded `to_realm`/`to_host` endpoints, then starts its root. The host does not execute the handler with control-plane authority. The root runs a local request dispatcher.
3. An HTTP request arrives. The router pins its selected deployment version, applies body/deadline/admission limits, and assigns a host-generated request ID.
4. The host sends a framed byte request to the instance; the dispatcher runs the handler within the Realm and returns a framed byte response. The host maps that response to the waiting HTTP request.
5. When `v3` replaces `v2`, new requests select `v3`; `v2` stops accepting new requests, completes or times out its in-flight work, and is stopped. A rollback changes the route back to an available version or reactivates it.

Conceptual future handler contract (the current prototype implements `Midgard.Request` and `Midgard.Worker.handle_request/1`, returning `{status, body}`, but does not implement a response struct or activation context):

```elixir
defmodule Hello.Handler do
  @behaviour Midgard.Handler

  @impl true
  def handle(%Midgard.Request{method: "GET", path: "/hello"}, _context) do
    %Midgard.Response{status: 200, headers: [{"content-type", "text/plain"}], body: "hello"}
  end
end
```

`Midgard.Handler` and `Midgard.Response` are proposed names, not implemented modules; `Midgard.Request` exists in the prototype. The first contract accepts bounded, complete request and response bodies. Configuration and grants are explicit fields of the activation context; the context must not contain host management handles or unrestricted Erlang endpoints.

## Reference-level explanation

### Architecture and boundaries

```text
HTTP client
    │
trusted Elixir host: listener → router → invocation coordinator
                            │              │
                      deployment store     instance manager → Realm handle
                                           │                  │
                                     byte transport ⇄ Realm dispatcher → handler
                                           │
                                    future capability brokers
```

- **Deployment store:** authoritative artifact/version metadata and requested policy. An immutable artifact digest identifies the exact version selected by a route. Storage implementation is deferred; in-memory metadata suffices for the fixture slice.
- **Router:** maps host/path to a version and snapshots the choice for each request; changing a route never silently switches an in-flight invocation.
- **Instance manager:** runs only in the host. Owns handles, endpoint references, capacity, health, in-flight accounting, activation, close, and stop. A crashed manager must be recoverable by an authorized host supervisor that retains or rediscovers its handles; persistence/recovery of handles across host VM restart is impossible and not required.
- **Invocation coordinator:** assigns request IDs, enforces per-request deadlines and admission, frames bytes, and matches replies. Caller death must remove its waiter and eventually cancel or discard its work.
- **Realm dispatcher:** trusted bootstrap code in the target Realm that receives framed requests, invokes handler code with Realm authority, and serializes bounded responses. Its workers use ordinary local spawn and therefore inherit membership. It never calls host-management operations.
- **Brokers:** later host-controlled operations such as storage or fetch. Grant checks and input validation occur in trusted host code; no direct privileged OTP mailbox is exposed as a capability.

The host must use the checked-out fork's runtime and match its experimental API contract. A stock OTP VM is not a supported Realm execution target.

### Transport and data contract

The fork currently exposes `erts_internal:realm_create/1`, `realm_spawn_root/4`, `realm_stop/1`, and `realm_endpoint_create/4`, `realm_endpoint_send/2`, `realm_endpoint_receive/1`, `realm_endpoint_revoke/1`. Endpoint direction is bound to exactly one Realm; queues accept copied binaries only and are polled, not push-notified. Per queue bounds are at most 1024 messages and 1 MiB, with at most 64 KiB per message. `send` can return `ok`, `full`, or `closed`; `receive` can return `{ok, bytes}`, `empty`, or `closed`. These APIs are experimental. The host adapter owns their use; callers do not depend on their return shapes.

For the first slice use a versioned, length-checked binary frame with message kind (`request`, `response`, `cancel`), a host-generated correlation ID, deadline, and bounded HTTP fields/body. Exact wire encoding is an implementation-time decision. Decode using bounded, non-atom-creating parsers; do not use unrestricted `binary_to_term` on ingress. Both sides reject unknown versions, malformed frames, oversized fields, and duplicate or unsolicited replies. Treat IDs inside frames as correlation only, never proof of authority.

One endpoint pair per Realm implies a shared transport: only one host-side poller consumes `to_host` and one Realm-side dispatcher consumes `to_realm`; they demultiplex correlation IDs to in-flight tasks. The host must enforce a smaller explicit in-flight bound and byte limit than queue capacity permits, and apply backpressure rather than spawning unbounded waiters. `full` means wait within a finite deadline or reject before acceptance; `closed` fails the invocation. Polling must use bounded batches and a scheduler-friendly wait strategy; busy-spinning is not acceptable. If polling overhead is unacceptable, add an authenticated wakeup primitive in the fork rather than treating an unrestricted cross-Realm Erlang message as safe.

The initial API rejects bodies or encoded frames larger than one endpoint message; chunking and streaming require a later protocol with aggregate limits and cancellation. HTTP response header validation, hop-by-hop filtering, and maximum response size are host responsibilities. No execution of externally supplied serialized Erlang terms is allowed.

### Lifecycle and failure semantics

An instance moves through `preparing → ready → draining → stopped` (or `failed`). Preparation validates a deployment and policy, creates an empty Realm, creates endpoints, then starts a root. It becomes ready only after a bounded bootstrap handshake. Any preparation failure revokes endpoints and stops the Realm; a failure to stop is surfaced as an operational incident, not reported as successful cleanup. The host never admits requests before ready.

A request is either rejected before admission (no instance/capacity, oversized input, or deadline already passed), or assigned to one ready instance. Once dispatched, handler execution may fail, the instance may stop, or a response may be lost. The caller receives a bounded error/timeout; the host does **not** transparently retry dispatched requests, because the handler may have performed side effects. A late reply is discarded and counted. Cancellation is best effort until the protocol and runtime can prove cancellation of Realm work and consumed broker operations; timeout does not imply those effects were undone.

Draining removes an instance from new routing, waits until the in-flight count reaches zero or a finite drain deadline, then calls `realm_stop/1`. Stop is idempotent/resumable at the fork level but can be delayed indefinitely by native work; the platform needs an operational escalation (including terminating a separate VM when that is the deployment boundary), not an invented hard stop guarantee. Routes refer to immutable versions rather than PIDs or handles. An unhandled handler crash fails that invocation, not the host listener; dispatcher/supervisor failure marks the instance unhealthy and causes cleanup.

### Invariants

- Only trusted host processes hold Realm management handles and grant endpoints; no tenant request can select its Realm by ID or PID.
- One invocation belongs to exactly one selected deployment version and one instance; correlation IDs are unique among that instance's active requests.
- Every admitted request has a finite deadline and a bounded total memory/queue reservation in the host.
- Instance closure prevents new platform admissions before stop; already accepted requests either complete or fail by their deadlines.
- Handler code always executes under the target Realm's identity, including bootstrap and any future loader callbacks; mere access to a host module does not confer host authority.
- Protocol data and application claims are not authorization. Endpoint handle validation in ERTS and host-owned grants determine authority.
- Stopping a Realm is not assumed to undo external effects or cancel work already consumed by a broker.

### Compatibility and security

The initial fixture stage allows only trusted, preloaded modules, even though the endpoint exchange itself is bounded. The current Realm prototype does **not** restrict ordinary cross-Realm messages, shared ETS/persistent terms, native operations, distribution, or global code loading. An Elixir wrapper cannot close those gaps. The host and fixtures therefore share a trust domain for this stage; do not expose an upload endpoint or market it as multi-tenant isolation.

Independent uploads require at least: private code resolution/loading (including duplicate module names and upgrades), process communication/visibility controls, restrictions on native/internal/OS effects and distribution, scoped or denied shared facilities, aggregate resource enforcement, complete enough teardown, and an explicit security review of the supported profile. Also establish how Elixir/OTP services such as application config, logger, and group-leader I/O work without implicitly bridging to the host. Until then, use separately sandboxed BEAM VMs for genuinely untrusted deployments.

Log deployment digest, route version, instance/Realm diagnostic identity, request ID, admission outcome, duration, byte counts, failures, and cleanup results on the host. Do not log request bodies or secrets by default. Measure queue occupancy, polling overhead, activations, deadline expirations, late replies, in-flight requests, and retained Realm resources. No performance or density claim is made in this RFD.

### Rollout and validation

1. **Trusted fixture vertical slice:** boot the forked BEAM, activate one preloaded Elixir handler, exchange a bounded HTTP request/response via endpoints, and stop the instance. No uploaded code.
2. **Platform lifecycle:** concurrency and admission limits, version pinning, drain/rollback, handler crashes, queue saturation, timeouts, host supervisor restarts, and repeated activation/cleanup. Keep execution trusted.
3. **Independent deployments:** only after the fork supports private code environments and required OTP services; demonstrate conflicting module names/config and independent upgrades. Still no untrusted-code claim.
4. **Restricted tenant profile:** after the fork meets its process-boundary, host-effects, resource, and security validation gates. Explicitly decide whether shared-VM hostile deployments are acceptable; otherwise keep the separate-VM backend.

Tests must cover malformed/oversized frames, duplicate and late replies, cancellation races, `full`/`closed` queues, a root dying during bootstrap, slow/blocked handlers, concurrent deploy and rollback, caller disconnects, repeated create/stop churn, and authorization bypass attempts against the eventual restricted profile. Measure a stock/forked baseline before claiming latency or density improvements. A release gate for hostile workloads requires an independent security go/no-go, not merely green platform tests.

## Drawbacks

- The platform and fork must evolve together; experimental ERTS APIs may change.
- Byte-only polling channels complicate request multiplexing and can add latency and copying costs.
- Elixir/OTP dependencies may assume node-wide code, names, application config, logging, and native services, constraining compatibility.
- A shared BEAM expands the security review surface and permits noisy neighbors until aggregate accounting is enforced; separate VMs may remain the better production tradeoff.

## Rationale and alternatives

A warm Realm per deployment instance amortizes startup and preserves normal BEAM concurrency within a service. Keeping routing, policy, and durable state outside the Realm makes instance replacement practical and avoids equating an in-memory PID with a deployment or durable actor.

- **Simpler trusted-only OTP app:** enough to prototype HTTP handlers, but cannot validate Realm activation, endpoint admission, or shutdown. Useful as a control/baseline, not the intended platform contract.
- **One Realm per request:** simpler request cleanup but loses warm-instance economics and makes deployment-level background work awkward. Can be revisited for special workload classes.
- **Separate sandboxed BEAM per deployment:** stronger existing OS-level boundary and better compatibility at greater per-deployment overhead. This is the fallback and may remain the production choice after measurements.
- **Do nothing:** the fork remains a VM primitive without the deployment, invocation, and operational contracts needed for a Workers-like product.

## Prior art

The OTP fork's `rfd/0001-beam-realms.md`, `rfd/0001-implementation.md`, and `rfd/0001-api-contract.md` (in the separate `otp` repository) specify the primitive and its current limits; this RFD specifies the platform above it. Cloudflare Workers/workerd motivates separating deployment, invocation, and host bindings, not a claim of equivalent security, APIs, or density. Conventional OTP supervision informs host recovery but is not a tenant security boundary.

## Unresolved questions

### Before acceptance

- Is the first public product contract HTTP-only, and what limits should it promise for bodies, deadlines, and per-instance concurrency?
- What is the supported Elixir version and minimum viable handler dependency profile while Realm-local OTP services remain absent?
- Should untrusted deployments always use the separate-VM backend until an independent shared-VM security go/no-go?

### During implementation

- Which binary framing and scheduler-friendly polling approach meet latency targets without a Realm-unsafe wakeup path?
- Where will deployment artifacts, route metadata, and host grants live, and how will a node restart reconstruct active routes?
- What are the exact bootstrap handshake, error mapping, supervisor handoff, and reactivation rules?

### Out of scope

- Durable actors, placement across nodes, streaming/WebSockets, and transparent compatibility with arbitrary Elixir releases.

## Future possibilities

After the restricted profile is validated, add streaming frames, authenticated broker grants for fetch/storage, event triggers, and placement across hosts. Each needs its own contract and validation; none is implied by this proposal.
