defmodule HalC2.Acp.OpenCodeTest do
  use ExUnit.Case, async: true

  alias HalC2.Acp.OpenCode
  alias HalC2.Test.FakeHttp

  defp message(id, role), do: %{"info" => %{"id" => id, "role" => role}, "parts" => []}

  @source [
    %{"info" => %{"id" => "msg_1", "role" => "user"}, "parts" => []},
    %{"info" => %{"id" => "msg_2", "role" => "assistant"}, "parts" => []},
    %{"info" => %{"id" => "msg_3", "role" => "user"}, "parts" => []},
    %{"info" => %{"id" => "msg_4", "role" => "user"}, "parts" => []},
    %{"info" => %{"id" => "msg_5", "role" => "assistant"}, "parts" => []}
  ]

  defp server(routes) do
    {url, log} = FakeHttp.start(routes)
    {%{url: url, password: "pw"}, log}
  end

  # OpenCode's `?limit=n`: the newest n, oldest first.
  defp newest(list), do: fn conn -> {200, limit(list, conn.query_string)} end
  defp limit(list, "limit=" <> n), do: Enum.take(list, -String.to_integer(n))
  defp limit(list, _), do: list

  test "a fork maps each kept message to its copy, cut before the boundary" do
    {server, log} =
      server(%{
        "/session/ses_a/message" => newest(@source),
        "/session/ses_a/fork" => {200, %{"id" => "ses_b"}},
        "/session/ses_b/message" =>
          newest([message("msg_6", "user"), message("msg_7", "assistant")])
      })

    assert {:ok, "ses_b", %{"msg_1" => "msg_6", "msg_2" => "msg_7"}} =
             OpenCode.fork(server, "ses_a", "msg_3")

    fork = Enum.find(FakeHttp.requests(log), &(&1["path"] == "/session/ses_a/fork"))
    assert JSON.decode!(fork["body"]) == %{"messageID" => "msg_3"}
    assert fork["authorization"] == "Basic " <> Base.encode64("opencode:pw")
  end

  test "a boundary the session no longer has, or a fork that lost messages, is refused" do
    {server, log} =
      server(%{
        "/session/ses_a/message" => newest(@source),
        "/session/ses_a/fork" => {200, %{"id" => "ses_b"}},
        "/session/ses_b/message" => newest([message("msg_6", "user")])
      })

    assert {:error, "The OpenCode rewind boundary is no longer available."} =
             OpenCode.fork(server, "ses_a", "msg_gone")

    refute Enum.any?(FakeHttp.requests(log), &(&1["path"] == "/session/ses_a/fork"))

    assert {:error, "OpenCode did not preserve the requested rewind boundary."} =
             OpenCode.fork(server, "ses_a", "msg_3")
  end

  test "a turn's message is the first user message after the leaf it started from" do
    {server, _} =
      server(%{
        "/session/ses_a/message" => newest(@source),
        "/session/ses_empty/message" => {200, []},
        "/session/ses_gone/message" => {404, %{"data" => %{"message" => "no such session"}}}
      })

    assert OpenCode.leaf(server, "ses_a") == {:ok, "msg_5"}
    assert OpenCode.leaf(server, "ses_empty") == {:ok, nil}

    assert {:error, "OpenCode could not read the session (HTTP 404): no such session"} =
             OpenCode.leaf(server, "ses_gone")

    assert OpenCode.turn_message(server, "ses_a", "msg_2") == "msg_3"
    assert OpenCode.turn_message(server, "ses_a", nil) == "msg_1"
    assert OpenCode.turn_message(server, "ses_a", "msg_5") == nil
  end
end
