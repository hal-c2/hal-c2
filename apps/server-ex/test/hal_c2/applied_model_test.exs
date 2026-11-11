defmodule HalC2.Orchestration.AppliedModelTest do
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.AppliedModel

  test "a dated or suffixed name is its model's" do
    assert AppliedModel.same?("claude-opus-4-5", "claude-opus-4-5-20251101")
    assert AppliedModel.same?("opus[1m]", "opus")
    assert AppliedModel.same?("GPT-5.4", "gpt-5.4")
  end

  test "a family alias is any model of that family" do
    assert AppliedModel.same?("opus", "claude-opus-4-5-20251101")
    refute AppliedModel.same?("opus", "claude-sonnet-4-5-20250929")
  end

  test "a name that leaves the choice to the provider, or none, is any model" do
    for open <- ["default", "auto", "", nil] do
      assert AppliedModel.same?(open, "gpt-5.4-mini")
    end
  end

  test "another versioned model is not the selected one" do
    refute AppliedModel.same?("gpt-5.4", "gpt-5.4-mini")
    refute AppliedModel.same?("claude-opus-4-5", "claude-sonnet-4-5-20250929")
  end
end
