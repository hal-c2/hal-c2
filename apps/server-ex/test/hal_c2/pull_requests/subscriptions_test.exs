defmodule HalC2.PullRequests.SubscriptionsTest do
  @moduledoc """
  A link's `notify` in `HalC2.PullRequests.Wakes.hear/4`: only the kinds of news it
  names wake the thread, the rest is heard without telling, and no `notify` is
  every kind.
  """

  use ExUnit.Case, async: true

  alias HalC2.PullRequests.Wakes

  @heard %{
    "state" => "open",
    "checksState" => "passing",
    "mergeability" => "mergeable",
    "checksFailed" => false,
    "activityAt" => nil
  }

  defp link(notify, snapshot) do
    %{
      "host" => "codeberg.org",
      "repository" => "acme/shop",
      "number" => 7,
      "url" => "https://codeberg.org/acme/shop/pulls/7",
      "source" => "agent",
      "heard" => @heard,
      "snapshot" =>
        Map.merge(
          %{"state" => "open", "checksState" => "failing", "mergeability" => "mergeable"},
          snapshot
        )
    }
    |> then(&if(notify == :all, do: &1, else: Map.put(&1, "notify", notify)))
  end

  @review %{"at" => "2030-01-01T00:00:10Z", "author" => "maint", "kind" => "review"}

  test "without notify every kind of news wakes the thread" do
    assert {_, _, [{_, [:checks_failing, {:activity, @review}]}]} =
             Wakes.hear([link(:all, %{"activity" => @review})], false, true)
  end

  test "a subscription to reviews tells the review and hears the failing checks quietly" do
    {quiet, told, [{_, changes}]} =
      Wakes.hear([link(["reviews"], %{"activity" => @review})], false, true)

    assert changes == [{:activity, @review}]
    assert [%{"heard" => %{"checksState" => "failing", "checksFailed" => true}}] = told
    assert quiet == [link(["reviews"], %{"activity" => @review})]
  end

  test "news no subscription names is heard without a wake, and is not told later" do
    assert {[quiet], [quiet], []} = Wakes.hear([link([], %{"activity" => @review})], false, true)
    assert quiet["heard"]["checksState"] == "failing"
    assert quiet["heard"]["activityAt"] == @review["at"]

    resubscribed = Map.delete(quiet, "notify")
    assert {_, _, []} = Wakes.hear([resubscribed], false, true)
  end

  test "a busy thread hears unsubscribed news at once and keeps subscribed news for later" do
    assert {[%{"heard" => %{"checksState" => "failing"}}], _, []} =
             Wakes.hear([link(["comments"], %{})], false, false)

    assert {[%{"heard" => @heard}], _, []} = Wakes.hear([link(["checks"], %{})], false, false)
  end

  test "notify names known kinds in their order, and refuses others" do
    assert Wakes.notify(["merged", "reviews", "merged"]) == {:ok, ["reviews", "merged"]}
    assert Wakes.notify(nil) == {:ok, nil}
    assert {:error, message} = Wakes.notify(["reviews", "pushes"])
    assert message =~ "pushes"
  end

  test "a review and a comment are told apart" do
    assert Wakes.event({:activity, @review}) == "reviews"
    assert Wakes.event({:activity, %{@review | "kind" => "comment"}}) == "comments"
  end
end
