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
    "activityAt" => nil,
    "commentEditAt" => nil
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

  @comment %{"at" => "2030-01-01T00:00:20Z", "author" => "maint", "kind" => "comment"}

  defp both(review, comment),
    do: %{"activity" => comment, "activities" => Enum.reject([review, comment], &is_nil/1)}

  test "a review followed by a comment still wakes a subscription to reviews" do
    {_, [told], [{_, changes}]} =
      Wakes.hear([link(["reviews"], both(@review, @comment))], false, true)

    assert changes == [{:activity, @review}]

    assert %{
             "activityAt" => "2030-01-01T00:00:20Z",
             "reviewActivityAt" => "2030-01-01T00:00:10Z",
             "commentActivityAt" => "2030-01-01T00:00:20Z"
           } = told["heard"]

    assert {_, _, []} = Wakes.hear([told], false, true)
  end

  test "a comment followed by a review still wakes a subscription to comments" do
    review = %{@review | "at" => "2030-01-01T00:00:30Z"}

    assert {_, _, [{_, [{:activity, @comment}]}]} =
             Wakes.hear(
               [link(["comments"], %{both(review, @comment) | "activity" => review})],
               false,
               true
             )
  end

  test "a comment heard quietly does not hide a review that lands while the thread is busy" do
    {[quiet], _, []} = Wakes.hear([link(["reviews"], both(nil, @comment))], false, true)
    assert quiet["heard"]["commentActivityAt"] == @comment["at"]
    assert quiet["heard"]["reviewActivityAt"] == nil

    review = %{@review | "at" => "2030-01-01T00:00:15Z"}
    later = %{quiet | "snapshot" => Map.merge(quiet["snapshot"], both(review, @comment))}

    assert {[^later], _, []} = Wakes.hear([later], false, false)
    assert {_, _, [{_, [{:activity, ^review}]}]} = Wakes.hear([later], false, true)
  end

  test "a link heard before the kinds were kept apart hears from its one marker" do
    heard = %{@heard | "activityAt" => @review["at"]}
    old = %{link(["comments"], both(@review, @comment)) | "heard" => heard}

    assert {_, [told], [{_, [{:activity, @comment}]}]} = Wakes.hear([old], false, true)
    assert told["heard"]["reviewActivityAt"] == @review["at"]
  end

  test "enabling a kind hears what arrived while it was muted; news already subscribed to stays" do
    # Busy: subscribed only to reviews, the failing checks and the review wait unheard.
    waiting = link(["reviews"], %{"activity" => @review})
    assert {[^waiting], _, []} = Wakes.hear([waiting], false, false)

    both = Wakes.resubscribe(waiting, ["reviews", "checks"])
    assert both["notify"] == ["reviews", "checks"]

    assert %{"checksState" => "failing", "checksFailed" => true, "reviewActivityAt" => nil} =
             both["heard"]

    assert {_, _, [{_, [{:activity, @review}]}]} = Wakes.hear([both], false, true)

    every = Wakes.resubscribe(waiting, nil)
    refute Map.has_key?(every, "notify")
    assert {_, _, [{_, [{:activity, @review}]}]} = Wakes.hear([every], false, true)

    assert Wakes.resubscribe(waiting, ["reviews"])["heard"] == @heard
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
