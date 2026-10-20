# Midgard for Gleam

This Erlang-target Gleam package provides framework-level response types and protocol encoding for Gleam workers. Construct `midgard.Response(status, body)` and pass it to `midgard.encode_response` to produce a `midgard.bytes.v1` frame.

Worker-specific route matching and response content belong in the worker application. Request-frame parsing and route dispatch remain ordinary Gleam code in the worker.
