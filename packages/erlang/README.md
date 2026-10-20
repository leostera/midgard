# Midgard for Erlang

The `midgard` Erlang application provides framework-level response types and protocol encoding for Erlang workers. Include `midgard/include/midgard.hrl` to use `#midgard_response{status, body}` and pass it to `midgard:encode_response/1` to produce a `midgard.bytes.v1` frame.

Worker-specific route matching and response content belong in the worker application. Request-frame parsing and route dispatch remain ordinary Erlang code in the worker.
