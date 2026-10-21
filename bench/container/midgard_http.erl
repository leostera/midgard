%% Minimal HTTP/1.1 front for a Midgard worker entrypoint, used to run the
%% exact same shipment modules in an ordinary container for comparison.
%% It frames each request as midgard.bytes.v1, calls Module:Function/1, and
%% writes the decoded response. One request per connection; no keep-alive.
-module(midgard_http).
-export([start/0]).

start() ->
    Module = list_to_atom(os:getenv("MIDGARD_ENTRY_MODULE")),
    Function = list_to_atom(os:getenv("MIDGARD_ENTRY_FUNCTION", "handle")),
    Port = list_to_integer(os:getenv("PORT", "8080")),
    {ok, Listen} = gen_tcp:listen(Port, [binary, {packet, http_bin}, {active, false},
                                         {reuseaddr, true}, {backlog, 128}]),
    accept(Listen, Module, Function).

accept(Listen, Module, Function) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Pid = spawn(fun() -> receive go -> serve(Socket, Module, Function) end end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! go,
    accept(Listen, Module, Function).

serve(Socket, Module, Function) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_request, Method, {abs_path, Target}, _Version}} ->
            {Headers, Length} = headers(Socket, [], 0),
            ok = inet:setopts(Socket, [{packet, raw}]),
            Body = case Length of 0 -> <<>>; _ -> {ok, B} = gen_tcp:recv(Socket, Length, 5000), B end,
            {Path, Query} = case binary:split(Target, <<"?">>) of [P, Q] -> {P, Q}; [P] -> {P, <<>>} end,
            Frame = frame(method(Method), Path, Query, Headers, Body),
            <<2, Status:16, Size:16, Out:Size/binary>> = Module:Function(Frame),
            gen_tcp:send(Socket, [<<"HTTP/1.1 ">>, integer_to_binary(Status),
                                  <<" OK\r\ncontent-type: text/plain\r\ncontent-length: ">>,
                                  integer_to_binary(Size), <<"\r\nconnection: close\r\n\r\n">>, Out]);
        _ ->
            ok
    end,
    gen_tcp:close(Socket).

headers(Socket, Acc, Length) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(header_name(Name)),
            Next = case Key of <<"content-length">> -> binary_to_integer(Value); _ -> Length end,
            headers(Socket, [{Key, Value} | Acc], Next);
        {ok, http_eoh} ->
            {lists:sublist(lists:reverse(Acc), 32), Length}
    end.

header_name(Name) when is_atom(Name) -> atom_to_binary(Name);
header_name(Name) -> Name.

method(Method) when is_atom(Method) -> atom_to_binary(Method);
method(Method) -> Method.

frame(Method, Path, Query, Headers, Body) ->
    Encoded = [<<(byte_size(K)):8, (byte_size(V)):16, K/binary, V/binary>> || {K, V} <- Headers],
    iolist_to_binary([<<1, (byte_size(Method)):8, (byte_size(Path)):16, (byte_size(Query)):16,
                        (length(Headers)):8, (byte_size(Body)):16>>,
                      Method, Path, Query, Encoded, Body]).
