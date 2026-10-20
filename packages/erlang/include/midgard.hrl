-record(midgard_request, {
    method = <<>> :: binary(),
    path = <<>> :: binary(),
    query_string = <<>> :: binary(),
    headers = [] :: [{binary(), binary()}],
    body = <<>> :: binary()
}).

-record(midgard_response, {
    status :: 100..599,
    body :: binary()
}).
