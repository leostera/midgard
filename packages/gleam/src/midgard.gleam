/// A framework request passed to a worker handler.
pub type Request {
  Request(
    method: BitArray,
    path: BitArray,
    query_string: BitArray,
    headers: List(#(BitArray, BitArray)),
    body: BitArray,
  )
}

/// A framework response returned by a worker handler.
pub type Response {
  Response(status: Int, body: BitArray)
}

/// Encodes a response as a `midgard.bytes.v1` binary frame.
pub fn encode_response(response: Response) -> BitArray {
  case response {
    Response(status, body) -> <<2, status:16, byte_size(body):16, body:bits>>
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(bytes: BitArray) -> Int
