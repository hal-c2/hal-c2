defmodule HalC2.ProviderCompatibilityTest do
  use ExUnit.Case, async: true

  alias HalC2.ProviderCompatibility, as: Compatibility

  @policies [
    %{
      "driver" => "opencode",
      "halC2Range" => ">=0.0.42 <0.1 || ^1",
      "recommendedRange" => ">=1.14.19",
      "ranges" => [
        %{"range" => "<1.14.19", "status" => "broken"},
        %{"range" => "^1.14.19", "status" => "supported"},
        %{"range" => ">=2 <3", "status" => "graceful"},
        %{"range" => ">=3", "status" => "unsupported"}
      ]
    }
  ]

  test "a range is comparators in groups, with a missing minor or patch read as 0" do
    assert Compatibility.satisfies?("v1.14.19", ">=1.14.19")
    refute Compatibility.satisfies?("1.14.18", ">=1.14.19")
    assert Compatibility.satisfies?("2.5.0", ">=2 <3")
    refute Compatibility.satisfies?("3.0.0", ">=2 <3")
    assert Compatibility.satisfies?("3.0.0", ">=2 <3 || =3")
    assert Compatibility.satisfies?("1.20.0", "^1.14.19")
    refute Compatibility.satisfies?("2.0.0", "^1.14.19")
    assert Compatibility.satisfies?("0.2.9", "^0.2.3")
    refute Compatibility.satisfies?("0.3.0", "^0.2.3")
    refute Compatibility.satisfies?("0.0.4", "^0.0.3")
    assert Compatibility.satisfies?("1.2", "1.2.0")
    refute Compatibility.satisfies?("nightly", ">=0")
    refute Compatibility.satisfies?("1.0.0", "~>1.0")
    refute Compatibility.satisfies?("1.0.0", "")
  end

  test "a space after an operator and build metadata on a version are read through" do
    assert Compatibility.satisfies?("1.14.19", ">= 1.14.19")
    refute Compatibility.satisfies?("3.0.0", ">= 2 < 3")
    assert Compatibility.satisfies?("3.0.0", ">= 2 < 3 || = 3")
    assert Compatibility.satisfies?("1.14.19+build.5", ">=1.14.19")
    assert Compatibility.satisfies?("1.15.0-beta.1+sha.abc", ">=1.14.19")
  end

  test "the first range a stable version is in decides its status" do
    for {version, status} <- [
          {"1.14.18", "broken"},
          {"v1.15.0", "supported"},
          {"1.15.0+build.5", "supported"},
          {"2.1.0", "graceful"},
          {"3.0.0", "unsupported"}
        ] do
      assert %{"status" => ^status, "recommendedRange" => ">=1.14.19"} =
               Compatibility.advisory(@policies, "opencode", version, "0.0.42")
    end

    assert %{
             "message" =>
               "This provider version has limited compatibility with this HAL-C2 release. Use >=1.14.19."
           } = Compatibility.advisory(@policies, "opencode", "2.1.0", "0.0.42")

    assert %{"status" => "supported", "message" => nil, "recommendedVersion" => nil} =
             Compatibility.advisory(@policies, "opencode", "1.15.0", "1.2.0")
  end

  test "a prerelease or unreadable version is unknown, not judged" do
    for version <- ["1.14.0-beta.1", "nightly", nil] do
      assert %{"status" => "unknown", "message" => nil} =
               Compatibility.advisory(@policies, "opencode", version, "0.0.42")
    end
  end

  test "no advisory without a policy for the driver on this release" do
    assert Compatibility.advisory(@policies, "codex", "1.0.0", "0.0.42") == nil
    assert Compatibility.advisory(@policies, "opencode", "1.0.0", "0.5.0") == nil
  end

  test "only an enabled, installed provider is judged" do
    # The bundled manifest's OpenCode policy.
    entry = %{"driver" => "opencode", "version" => "1.0.0"}

    assert %{"compatibilityAdvisory" => %{"status" => "broken"}} = Compatibility.put(entry)
    assert Compatibility.put(Map.put(entry, "enabled", false)) == Map.put(entry, "enabled", false)
    assert Compatibility.put(Map.put(entry, "installed", false))["compatibilityAdvisory"] == nil
  end
end
