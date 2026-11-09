defmodule HalC2.CodexSharingLimitTest do
  use ExUnit.Case, async: true

  alias HalC2.Codex.SharingLimit

  @personal "subscription_sharing_usage_limit_exceeded"
  @workspace "subscription_sharing_workplace_individual_usage_limit_exceeded"

  test "finds ChatGPT's code wherever Codex puts it" do
    assert SharingLimit.code(%{"code" => @workspace}) == @workspace
    assert SharingLimit.code(%{"message" => "x", "additionalDetails" => @workspace}) == @workspace

    json = JSON.encode!(%{"error" => %{"code" => @workspace, "message" => "limit"}})
    assert SharingLimit.code(%{"message" => json}) == @workspace
    assert SharingLimit.code(json) == @workspace
    assert SharingLimit.code(%{"error" => %{"code" => @personal}}) == @personal
  end

  test "ChatGPT's prose names a personal plan's limit" do
    assert SharingLimit.code(%{
             "message" => "The user has reached their Subscription Sharing usage limit."
           }) == @personal
  end

  test "other errors are not sharing limits" do
    assert SharingLimit.code(%{"message" => "You've hit your usage limit."}) == nil
    assert SharingLimit.code(%{"code" => "usageLimitExceeded"}) == nil
    assert SharingLimit.code(%{"message" => "{not json"}) == nil
    assert SharingLimit.code(nil) == nil
  end

  test "a sharing limit is a usage limit with no reset of its own" do
    assert %{"class" => "usage_limit", "code" => @workspace, "resetAt" => nil, "message" => m} =
             SharingLimit.failure(@workspace)

    assert m =~ "workspace admin"
  end
end
