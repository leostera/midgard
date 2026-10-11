-module(erlang_worker_tests).
-include_lib("eunit/include/eunit.hrl").

binary_entry_test() ->
    ?assertEqual(<<0, 255, "hi">>, erlang_worker:handle(<<0, 255, "hi">>)).
