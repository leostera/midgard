-module(erlang_worker).
-export([handle/1]).

handle(Bytes) when is_binary(Bytes) ->
    erlang_helper:echo(Bytes).
