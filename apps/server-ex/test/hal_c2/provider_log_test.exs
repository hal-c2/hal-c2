defmodule HalC2.ProviderLogTest do
  use ExUnit.Case, async: true

  alias HalC2.ProviderLog

  test "whatever sits under a credential key is redacted, whatever its shape" do
    event = %{
      "apiKey" => %{"value" => "sk-live-1"},
      "authorization" => %{"type" => "bearer", "credentials" => "sk-live-1"},
      "tokens" => ["kept"],
      "refresh_token" => ["sk-live-1"]
    }

    assert ProviderLog.redact(event) == %{
             "apiKey" => "[REDACTED]",
             "authorization" => "[REDACTED]",
             "tokens" => ["kept"],
             "refresh_token" => "[REDACTED]"
           }
  end

  test "a bearer token is redacted wherever it sits in a string" do
    redacted =
      ProviderLog.redact(%{
        "command" => "curl -H 'Authorization: Bearer sk-live-1' https://example.test",
        "output" => ~s({"headers":"authorization: bearer sk-live-2"}),
        "start" => "Bearer sk-live-3"
      })

    refute JSON.encode!(redacted) =~ "sk-live"

    assert redacted["command"] ==
             "curl -H 'Authorization: Bearer [REDACTED]' https://example.test"

    assert redacted["start"] == "[REDACTED]"
    assert ProviderLog.redact(redacted) == redacted
  end
end
