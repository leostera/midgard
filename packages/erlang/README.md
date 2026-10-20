# Midgard for Erlang

The `midgard` Erlang application provides framework-level request and response types for Erlang workers. Include `midgard/include/midgard.hrl` to use `#midgard_request{}` and `#midgard_response{}`. Pass a response record to `midgard:encode_response/1` to produce a `midgard.bytes.v1` frame.

Worker-specific route matching and response content belong in the worker application. The current binary example parses requests in its own entrypoint; it does not move application behavior into the SDK.
