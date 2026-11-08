defmodule HalC2.ModelManifestBadgeTest do
  use ExUnit.Case, async: true

  alias HalC2.ModelManifest

  @day 24 * 60 * 60 * 1000
  @now 1_800_000_000_000

  defp badge(released, status \\ "current") do
    model = %{"slug" => "m", "status" => status}
    model = if released, do: Map.put(model, "releasedAt", released), else: model

    %{"models" => [model]}
    |> ModelManifest.badged(@now)
    |> Map.fetch!("models")
    |> hd()
    |> Map.get("badge")
  end

  defp at(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  test "a model is new from its release until seven days after" do
    assert badge(at(@now)) == "new"
    assert badge(at(@now - 7 * @day + 1)) == "new"
    assert badge(at(@now - 7 * @day)) == nil
  end

  test "no badge for a future, missing, invalid or legacy release" do
    assert badge(at(@now + 1)) == nil
    assert badge(nil) == nil
    assert badge("last tuesday") == nil
    assert badge(at(@now), "legacy") == nil
  end

  test "a date counts from midnight UTC" do
    {:ok, midnight, _} = DateTime.from_iso8601("2027-01-15T00:00:00Z")
    ms = DateTime.to_unix(midnight, :millisecond)

    assert %{"models" => [%{"badge" => "new"}]} =
             ModelManifest.badged(
               %{"models" => [%{"status" => "current", "releasedAt" => "2027-01-15"}]},
               ms
             )

    assert %{"models" => [model]} =
             ModelManifest.badged(
               %{"models" => [%{"status" => "current", "releasedAt" => "2027-01-15"}]},
               ms - 1
             )

    refute Map.has_key?(model, "badge")
  end

  test "a hand-set badge is not kept" do
    assert %{"models" => [model]} =
             ModelManifest.badged(
               %{"models" => [%{"status" => "current", "badge" => "new"}]},
               @now
             )

    refute Map.has_key?(model, "badge")
  end
end
