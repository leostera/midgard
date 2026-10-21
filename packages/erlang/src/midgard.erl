-module(midgard).
-include("midgard.hrl").
-export([serve/2, decode_request/1, encode_response/1]).
-export_type([request/0, response/0]).

-type request() :: #midgard_request{}.
-type response() :: #midgard_response{}.

%% Run a request handler over a midgard.bytes.v1 frame. Malformed frames get a 400.
-spec serve(binary(), fun((request()) -> response())) -> binary().
serve(Input, Handler) ->
    case decode_request(Input) of
        {ok, Request} -> encode_response(Handler(Request));
        error -> encode_response(#midgard_response{status = 400, body = <<"Bad request\n">>})
    end.

%% Decode a midgard.bytes.v1 request frame into a framework request.
-spec decode_request(binary()) -> {ok, request()} | error.
decode_request(<<1, MethodSize:8, PathSize:16, QuerySize:16, HeaderCount:8,
                 BodySize:16, Rest/binary>>)
  when MethodSize > 0, PathSize > 0 ->
    case Rest of
        <<Method:MethodSize/binary, Path:PathSize/binary, Query:QuerySize/binary,
          HeadersAndBody/binary>> ->
            case decode_headers(HeaderCount, HeadersAndBody, []) of
                {ok, Headers, <<Body:BodySize/binary>>} ->
                    {ok, #midgard_request{method = Method, path = Path,
                                          query_string = Query,
                                          headers = Headers, body = Body}};
                _ ->
                    error
            end;
        _ ->
            error
    end;
decode_request(_) ->
    error.

decode_headers(0, Rest, Acc) ->
    {ok, reverse(Acc, []), Rest};
decode_headers(Count, <<NameSize:8, ValueSize:16, Name:NameSize/binary,
                        Value:ValueSize/binary, Rest/binary>>, Acc) when Count > 0 ->
    decode_headers(Count - 1, Rest, [{Name, Value} | Acc]);
decode_headers(_, _, _) ->
    error.

%% Kept local so the SDK needs no stdlib modules inside the worker shipment.
reverse([], Acc) -> Acc;
reverse([Head | Tail], Acc) -> reverse(Tail, [Head | Acc]).

%% Encode a framework response as a midgard.bytes.v1 binary frame.
-spec encode_response(response()) -> binary().
encode_response(#midgard_response{status = Status, body = Body})
  when is_integer(Status), Status >= 100, Status =< 599,
       is_binary(Body), byte_size(Body) =< 65531 ->
    <<2, Status:16, (byte_size(Body)):16, Body/binary>>.
