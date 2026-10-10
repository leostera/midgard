defmodule Midgard.RequestTest do
  use ExUnit.Case, async: true

  test "request fields and case-insensitive header lookup are available without the runtime" do
    request = %Midgard.Request{
      method: "POST",
      path: "/echo",
      headers: [{"x-example", "first"}, {"x-example", "second"}],
      body: "hello"
    }

    assert Midgard.Request.header(request, "X-Example") == "first"
    assert Midgard.Request.header(request, "missing") == nil
    assert request.body == "hello"
  end
end
