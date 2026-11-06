defmodule HalC2.ProviderUsageLimits.ClaudeResetsTest do
  use ExUnit.Case, async: true

  alias HalC2.ProviderUsageLimits.ClaudeResets

  @now ~U[2026-09-21 12:00:00Z]

  defp grant(id, extra \\ %{}),
    do:
      Map.merge(
        %{
          "id" => id,
          "resets_left" => 1,
          "usable_now" => true,
          "ends_at" => "2026-10-01T00:00:00Z"
        },
        extra
      )

  test "counts the live grants and names the one Claude would claim next" do
    block = %{
      "eligible" => true,
      "next_grant_id" => "grant_2",
      "grants" => [grant("grant_1", %{"resets_left" => 2}), grant("grant_2")]
    }

    assert ClaudeResets.credits(block, @now) == %{
             "availableCount" => 3,
             "nextCreditId" => "grant_2",
             "nextExpiresAt" => "2026-10-01T00:00:00.000Z"
           }
  end

  test "paused, unusable, expired and malformed grants do not count" do
    block = %{
      "eligible" => true,
      "next_grant_id" => "grant_1",
      "grants" => [
        grant("grant_1"),
        grant("paused", %{"paused" => true}),
        grant("later", %{"usable_now" => false}),
        grant("gone", %{"ends_at" => "2026-09-01T00:00:00Z"}),
        grant("Bad Id!")
      ]
    }

    assert %{"availableCount" => 1, "nextCreditId" => "grant_1"} =
             ClaudeResets.credits(block, @now)
  end

  test "a next grant that cannot be claimed leaves nothing to redeem" do
    block = %{
      "eligible" => true,
      "next_grant_id" => "gone",
      "grants" => [grant("gone", %{"ends_at" => "2026-09-01T00:00:00Z"})]
    }

    assert ClaudeResets.credits(block, @now) == %{"availableCount" => 0}
  end

  test "an account that is not eligible has no reset credits" do
    assert ClaudeResets.credits(%{"eligible" => false}, @now) == nil
    assert ClaudeResets.credits(nil, @now) == nil
  end

  test "nothing is claimed for an id that is not a grant's" do
    assert {:error, "Claude returned a malformed reset credit.", true} =
             ClaudeResets.consume("claudeAgent", "../etc", "request-1")
  end
end
