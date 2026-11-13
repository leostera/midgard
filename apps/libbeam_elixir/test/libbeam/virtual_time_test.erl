-module(virtual_time_test).
-export([run/1, manual_advance/1]).

run(_) ->
    946684800000 = erlang:system_time(millisecond),
    0 = erlang:monotonic_time(millisecond),
    StartedAt = erlang:monotonic_time(millisecond),
    receive after 25 ->
        25 = erlang:monotonic_time(millisecond) - StartedAt
    end,
    <<"ok">>.

manual_advance(_) ->
    946684800025 = erlang:system_time(millisecond),
    25 = erlang:monotonic_time(millisecond),
    <<"ok">>.
