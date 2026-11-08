defmodule HalC2.Codex.GoalsTest do
  use ExUnit.Case, async: true

  alias HalC2.Codex.Goals

  test "a message is a goal command only as the user's own /goal words" do
    assert Goals.parse("/goal") == :show
    assert Goals.parse("  /goal edit ") == :show
    assert Goals.parse("/goal PAUSE") == :pause
    assert Goals.parse("/goal resume") == :resume
    assert Goals.parse("/goal clear") == :clear
    assert Goals.parse("/goal ship the fix\nand test it") == {:set, "ship the fix\nand test it"}
    assert Goals.parse("/goals are nice") == nil
    assert Goals.parse("please /goal ship") == nil
    assert Goals.command(%{user_text: "/goal", attachments: [%{"type" => "image"}]}) == nil
  end

  test "an objective is limited as Codex counts it, in characters, not bytes" do
    assert Goals.check(String.duplicate("é", 4_000)) == :ok
    assert {:error, message} = Goals.check(String.duplicate("é", 4_100))
    assert message =~ "4,100 characters"
    assert message =~ "at most 4,000"
  end

  test "a goal shows as the provider thread keeps it" do
    assert %{"status" => "budget_limited", "objective" => "ship"} =
             Goals.from_codex(%{"objective" => " ship ", "status" => "budgetLimited"})

    assert Goals.from_codex(%{"objective" => "  "}) == nil

    assert Goals.describe(%{"status" => "usage_limited", "objective" => "ship"}) ==
             "Goal usage limited: ship"
  end
end
