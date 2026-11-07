defmodule HalC2.Orchestration.UserFacingErrorsTest do
  use ExUnit.Case, async: true

  import HalC2.Orchestration.UserFacingErrors, only: [sanitize_failure: 1]

  test "a key under a provider's prefix is redacted, its name kept" do
    assert sanitize_failure("OPENAI_API_KEY=sk-abc is invalid") ==
             "OPENAI_API_KEY=[REDACTED] is invalid"

    assert sanitize_failure("set ANTHROPIC_API_KEY: sk-ant-123 first") ==
             "set ANTHROPIC_API_KEY: [REDACTED] first"

    assert sanitize_failure("GITHUB_TOKEN=ghp_x x-auth: abc") ==
             "GITHUB_TOKEN=[REDACTED] x-auth: [REDACTED]"
  end

  test "client secrets, refresh tokens and auth values are redacted, also in JSON" do
    assert sanitize_failure("client_secret=abc&grant=x") == "client_secret=[REDACTED]&grant=x"

    assert sanitize_failure(~s({"refresh_token":"abc","expires":3})) ==
             ~s({"refresh_token":"[REDACTED]","expires":3})

    assert sanitize_failure("auth=xyz") == "auth=[REDACTED]"
  end

  test "an authorization header loses its value and keeps its scheme" do
    assert sanitize_failure("Authorization: Bearer abc") == "Authorization: Bearer [REDACTED]"
    assert sanitize_failure(~s("authorization": "sk-1")) == ~s("authorization": "[REDACTED]")
  end

  test "a bearer or basic credential outside a header is redacted when token-shaped" do
    assert sanitize_failure("sent Basic dXNlcjpwYXNz and bearer abc123def") ==
             "sent Basic [REDACTED] and bearer [REDACTED]"
  end

  test "prose that says basic or bearer reads as written" do
    for text <- [
          "basic auth failed",
          "Basic plan quota exceeded",
          "Basic Authentication is not enabled",
          "a bearer token is required"
        ],
        do: assert(sanitize_failure(text) == text)
  end

  test "a file URL keeps its path; other URLs lose credentials and query" do
    assert sanitize_failure("cannot read file:///home/me/project/mise.toml") ==
             "cannot read file:///home/me/project/mise.toml"

    assert sanitize_failure("GET https://bob:pw@example.com/v1?key=1#x failed") ==
             "GET https://example.com/v1 failed"

    assert sanitize_failure("could not reach http://[::1 broken") ==
             "could not reach [REDACTED_URL] broken"
  end

  test "a structured failure is cleaned in its message, a long one is cut" do
    assert %{"class" => "provider_error", "message" => "password=[REDACTED]"} =
             sanitize_failure(%{"class" => "provider_error", "message" => "password=hunter2"})

    cut = sanitize_failure(String.duplicate("a", 5_000))
    assert String.length(cut) == 4_096 and String.ends_with?(cut, "…")
    assert sanitize_failure(nil) == nil
  end
end
