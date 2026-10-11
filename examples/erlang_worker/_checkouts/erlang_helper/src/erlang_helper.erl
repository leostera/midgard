-module(erlang_helper).
-export([echo/1]).

echo(Bytes) when is_binary(Bytes) -> Bytes.
