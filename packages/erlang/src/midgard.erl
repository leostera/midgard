-module(midgard).
-include("midgard.hrl").
-export([encode_response/1]).
-export_type([request/0, response/0]).

-type request() :: #midgard_request{}.
-type response() :: #midgard_response{}.

%% Encode a framework response as a midgard.bytes.v1 binary frame.
-spec encode_response(response()) -> binary().
encode_response(#midgard_response{status = Status, body = Body})
  when is_integer(Status), Status >= 100, Status =< 599,
       is_binary(Body), byte_size(Body) =< 65531 ->
    <<2, Status:16, (byte_size(Body)):16, Body/binary>>.
