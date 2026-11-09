defmodule HalC2.Acp.OpenCodeTest do
  use ExUnit.Case, async: true

  alias HalC2.Acp.OpenCode
  alias HalC2.Test.FakeHttp

  defp message(id, role), do: %{"info" => %{"id" => id, "role" => role}, "parts" => []}

  @source for {id, role} <- [
                {"msg_1", "user"},
                {"msg_2", "assistant"},
                {"msg_3", "user"},
                {"msg_4", "user"},
                {"msg_5", "assistant"}
              ],
              do: %{"info" => %{"id" => id, "role" => role}, "parts" => []}

  defp server(routes) do
    {url, log} = FakeHttp.start(routes)
    {%{url: url, password: "pw"}, log}
  end

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
    {server, _} = server(%{"/session/ses_a/message" => newest(@source)})

    assert OpenCode.leaf(server, "ses_a") == "msg_5"
    assert OpenCode.turn_message(server, "ses_a", "msg_2") == "msg_3"
    assert OpenCode.turn_message(server, "ses_a", nil) == "msg_1"
    assert OpenCode.turn_message(server, "ses_a", "msg_5") == nil
  end

  test "steering sends the text with the session's model, agent and variant" do
    {server, log} = server(%{"/session/ses_a/prompt_async" => {204, nil}})

    assert :ok =
             OpenCode.steer(server, "ses_a", "look here",
               model: "anthropic/claude-sonnet-4",
               agent: "plan"
             )

    assert [%{"body" => body}] = FakeHttp.requests(log)

    assert JSON.decode!(body) == %{
             "parts" => [%{"type" => "text", "text" => "look here"}],
             "model" => %{"providerID" => "anthropic", "modelID" => "claude-sonnet-4"},
             "agent" => "plan"
           }

    assert {:error, "OpenCode steering requires text or an attachment"} =
             OpenCode.steer(server, "ses_a", "  ")
  end

  test "a refused request says what failed" do
    {server, _} =
      server(%{"/session/ses_a/prompt_async" => {400, %{"data" => %{"message" => "busy"}}}})

    assert {:error, "OpenCode could not steer the turn (HTTP 400): busy"} =
             OpenCode.steer(server, "ses_a", "hi")
  end
end
