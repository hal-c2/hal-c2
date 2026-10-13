defmodule HalC2.AntigravityUsageLimitTest do
  use ExUnit.Case, async: true

  alias HalC2.Acp.Antigravity.Session

  @now 1_760_000_000_000
  @notice "Usage Limit Reached\n\nYou have reached your current quota for this period."

  defp turn(chunks, driver \\ "antigravity") do
    Enum.reduce(chunks, %{ids: %{driver: driver}}, &Session.reply(&2, &1))
  end

  defp reset_in(text) do
    %{"resetAt" => reset} = Session.usage_limit(turn([text]), @now)

    reset &&
      elem(DateTime.from_iso8601(reset), 1) |> DateTime.to_unix(:millisecond) |> Kernel.-(@now)
  end

  test "the reset is the time the notice names, in any units" do
    assert reset_in(@notice <> " Your limit will reset in 4 hours, 26 minutes.") ==
             (4 * 60 + 26) * 60_000

    assert reset_in(@notice <> " Your limit will reset in 1 day and 1 hour.") == 25 * 3_600_000
    assert reset_in(@notice <> " Your limit will reset in 45 seconds.") == 45_000
  end

  test "a notice without a reset time has none" do
    assert reset_in(@notice) == nil
  end

  test "the notice is found however the reply was cut into chunks" do
    limit =
      Session.usage_limit(
        turn([
          "Usage Limit",
          " Reached\n\nYou have reached your current quota",
          " for this period."
        ]),
        @now
      )

    assert %{"class" => "usage_limit", "message" => "You have reached" <> _} = limit
  end

  test "only a reply that is the notice is a usage limit" do
    assert Session.usage_limit(turn(["Done. " <> @notice]), @now) == nil
    assert Session.usage_limit(turn([@notice, String.duplicate(" more", 300)]), @now) == nil
    assert Session.usage_limit(turn([@notice], "grok"), @now) == nil
  end
end
