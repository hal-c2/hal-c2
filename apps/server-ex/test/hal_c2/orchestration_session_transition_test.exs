defmodule HalC2.Orchestration.SessionTransitionTest do
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.SessionTransition

  defp session(overrides \\ %{}) do
    Map.merge(
      %{
        driver: "codex",
        continuation: "codex:home:/home/user/.codex",
        selection: %{"instanceId" => "codex", "model" => "gpt-a"},
        runtime_mode: "full-access",
        workspace: "/work"
      },
      overrides
    )
  end

  test "an unavailable target is refused" do
    assert {:reject, "The target provider instance is unavailable."} =
             SessionTransition.decide(session(), session(), false)
  end

  test "no session yet starts one with a handoff" do
    assert SessionTransition.decide(nil, session(), true) == :create_with_handoff
  end

  test "another driver, or another continuation group, starts over with a handoff" do
    assert SessionTransition.decide(session(), session(%{driver: "claudeAgent"}), true) ==
             :create_with_handoff

    assert SessionTransition.decide(
             session(),
             session(%{continuation: "codex:home:/other"}),
             true
           ) ==
             :create_with_handoff
  end

  test "runtime mode, workspace and a same-home instance restart on the same conversation" do
    assert SessionTransition.decide(
             session(),
             session(%{runtime_mode: "approval-required"}),
             true
           ) ==
             :restart_and_resume

    assert SessionTransition.decide(session(), session(%{workspace: "/elsewhere"}), true) ==
             :restart_and_resume

    other = session(%{selection: %{"instanceId" => "codex-work", "model" => "gpt-a"}})
    assert SessionTransition.decide(session(), other, true) == :restart_and_resume
  end

  test "a model or options change on the same instance switches inside the session" do
    other = session(%{selection: %{"instanceId" => "codex", "model" => "gpt-b"}})
    assert SessionTransition.decide(session(), other, true) == :switch_model_in_session

    options =
      session(%{
        selection: %{
          "instanceId" => "codex",
          "model" => "gpt-a",
          "options" => [%{"id" => "effort", "value" => "high"}]
        }
      })

    assert SessionTransition.decide(session(), options, true) == :switch_model_in_session
  end

  test "a selection change the adapter refuses is refused" do
    other = session(%{selection: %{"instanceId" => "codex", "model" => "gpt-b"}})

    assert {:reject, "no switching"} =
             SessionTransition.decide(session(), other, true, {:reject, "no switching"})
  end

  test "nothing changing reuses the session" do
    assert SessionTransition.decide(session(), session(), true) == :reuse
  end
end
