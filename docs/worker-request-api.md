# Worker request API — provisional binary bridge

A worker uses `Midgard.Worker`, implements `handle_request(%Midgard.Request{}) :: {integer_status, binary_body}`, and gets a generated binary arity-one `__midgard_call__/1` wrapper. This runs in unit tests on normal OTP. **It has not executed inside libbeam**: the current limited core does not support maps/structs or broad Elixir/OTP imports. The future host would supply/receive byte frames, not Plug connections, PIDs or Erlang terms.

| Field | Representation / limit |
| --- | --- |
| `method` | Uppercase ASCII letters, 1–16 bytes. No HTTP method routing policy is enforced by the codec. |
| `path` | Starts with `/`, 1–2048 bytes. URL origin and route mapping belong to a future host. |
| `query_string` | Raw bytes without leading `?`, up to 2048 bytes. |
| `headers` | Ordered lowercase ASCII `{name, value}` pairs, duplicates preserved; at most 32 entries and 8192 encoded bytes. Values cannot contain CR/LF. **No control-plane header filtering exists here**; a future host must explicitly decide what to forward. |
| `body` | Complete binary, up to 32 KiB. No streaming, content decoding or arbitrary body objects. |

The `midgard.bytes.v1` request frame is `<<1, method_len::8, path_len::16, query_len::16, header_count::8, body_len::16, method, path, query, headers, body>>` with big-endian lengths. Each header is `<<name_len::8, value_len::16, name, value>>`. The entire frame fits 64 KiB. The response frame is `<<2, status::16, body_len::16, body>>`, with status 100..599, complete body ≤65,531 bytes and no custom headers. No Erlang term deserialization or implicit resources are part of the wire. Invalid request frames yield a bounded 400 response; malformed worker returns or ordinary exceptions yield a bounded 500 response in the provisional wrapper. This does not replace host error isolation or scheduling.

Unlike Cloudflare Workers' [Fetch handler](https://developers.cloudflare.com/workers/runtime-apis/handlers/fetch/), Midgard has no `env`, `ctx`, streams, `fetch`, async lifetime API, storage bindings, custom response headers or geographic metadata. No filesystem/network access is promised. A future host must design an explicit capability broker, origin/authorization filtering, response header policy, timeouts, resource accounting and admission before this can be an HTTP service. The [artifact manifest](libbeam-artifact-contract.md) always declares `required_capabilities: []` in v1.
