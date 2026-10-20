# Midgard for Gleam

This Erlang-target Gleam package provides framework-level `midgard.Request` and `midgard.Response` types for Gleam workers. `midgard.encode_response` encodes a framework response value as a `midgard.bytes.v1` frame.

Worker-specific route matching and response content belong in the worker application. The current binary example parses requests in its own entrypoint; it does not move application behavior into the SDK.
