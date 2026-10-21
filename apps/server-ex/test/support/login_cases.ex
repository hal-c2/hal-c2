defmodule HalC2.Test.LoginCases do
  @moduledoc """
  The one list of good and bad GitHub logins, shared by the host's assignee
  tests (`HalC2.IssuesTest`) and the planner's owner tests
  (`HalC2.PlannerTest`). The login shape itself is duplicated across the
  plugin boundary, so both suites run against these same cases: a drift in
  either copy of the shape fails both.
  """

  # Shape cases only: a blank login is refused by the host but clears a
  # task's owner, so each suite keeps that case of its own.
  def bad,
    do: [
      "da na",
      "a/b",
      "..",
      "-dana",
      "dana-",
      "da--na",
      "dana!",
      String.duplicate("a", 40)
    ]

  def good, do: ["dana", "Dana", "copilot[bot]", String.duplicate("a", 39)]
end
