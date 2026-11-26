defmodule HalC2.ModelManifestTest do
  use ExUnit.Case, async: true

  alias HalC2.ModelManifest

  defp manifest(model, profile \\ %{}) do
    %{
      "version" => 1,
      "currentModels" => %{"claudeAgent" => [model["slug"]]},
      "providers" => %{
        "claudeAgent" => %{"profiles" => %{"p" => profile}, "models" => [model]}
      }
    }
  end

  defp model(claude) do
    %{
      "slug" => "claude-x",
      "name" => "Claude X",
      "status" => "current",
      "profile" => "p",
      "adapter" => %{"claudeCode" => claude}
    }
  end

  test "the bundled manifest is usable" do
    assert ModelManifest.valid?(ModelManifest.bundled())
  end

  test "a Claude model gated by a version that is not a semantic version is refused" do
    refute ModelManifest.valid?(manifest(model(%{"minVersion" => "not-a-version"})))
    assert ModelManifest.valid?(manifest(model(%{"minVersion" => "2.1.0"})))
  end

  test "a Claude model whose minimum version is not below its maximum is refused" do
    refute ModelManifest.valid?(
             manifest(model(%{"minVersion" => "2.0.0", "maxVersion" => "2.0.0"}))
           )

    assert ModelManifest.valid?(
             manifest(model(%{"minVersion" => "2.0.0", "maxVersion" => "3.0.0"}))
           )
  end

  test "a profile with a malformed effort or context window map is refused" do
    effort = %{"adapter" => %{"claudeCode" => %{"effortMap" => %{"high" => 42}}}}
    window = %{"adapter" => %{"claudeCode" => %{"contextWindowTokens" => %{"1m" => "lots"}}}}

    refute ModelManifest.valid?(manifest(model(%{}), effort))
    refute ModelManifest.valid?(manifest(model(%{}), window))

    sound = %{
      "adapter" => %{
        "claudeCode" => %{
          "effortMap" => %{"ultrathink" => nil},
          "contextWindowTokens" => %{"1m" => 1_000_000}
        }
      }
    }

    assert ModelManifest.valid?(manifest(model(%{}), sound))
  end

  test "a claudeCode that is present and not a map is refused, on a model and on a profile" do
    refute ModelManifest.valid?(manifest(model("x")))
    refute ModelManifest.valid?(manifest(model(42)))

    profile = %{"adapter" => %{"claudeCode" => "x"}}
    refute ModelManifest.valid?(manifest(model(%{}), profile))

    assert ModelManifest.valid?(manifest(model(nil)))
    assert ModelManifest.valid?(manifest(model(%{}), %{"adapter" => %{"claudeCode" => nil}}))
  end
end
