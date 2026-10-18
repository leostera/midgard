-module(erlang_helper).
-export([echo/1, hello/1]).

echo(Bytes) when is_binary(Bytes) -> Bytes.
hello(Name) when is_binary(Name) -> <<"hello, ", Name/binary, "!">>.
