defmodule HalC2.Orchestration.SessionTransition do
  @moduledoc """
  What a change of model, instance, runtime mode, interaction mode or
  workspace does to a thread's live provider session: reuse it, switch the
  model inside it, restart it on the same native conversation, start a new
  conversation with the history handed over, or refuse the change.

  Ported from upstream T3 Code's
  `orchestration-v2/ProviderSessionTransitionPolicy.ts`
  (`decideProviderSessionTransition`).
  """

  @type state :: %{
          driver: String.t(),
          continuation: String.t(),
          selection: map,
          runtime_mode: String.t() | nil,
          workspace: String.t() | nil
        }

  @type transition ::
          :reuse
          | :switch_model_in_session
          | :restart_and_resume
          | :create_with_handoff
          | {:reject, String.t()}

  @doc """
  The transition from `current` (nil when the thread has no session yet) to
  `target`. `target` also carries `available`, and `selection`, what a
  selection change on the same instance does there: `:apply_on_next_turn`,
  `:restart_session`, `:create_with_handoff` or `{:reject, reason}`.
  Interaction mode is turn-scoped: changing it alone reuses the session.
  """
  @spec decide(state | nil, state, boolean, atom | {:reject, String.t()}) :: transition
  def decide(current, target, available, selection \\ :apply_on_next_turn)

  def decide(_current, _target, false, _selection),
    do: {:reject, "The target provider instance is unavailable."}

  def decide(nil, _target, _available, _selection), do: :create_with_handoff

  def decide(current, target, _available, selection) do
    instance_changed? =
      current.selection["instanceId"] != target.selection["instanceId"]

    cond do
      current.driver != target.driver or current.continuation != target.continuation ->
        :create_with_handoff

      # A selection change the adapter refuses (or answers with a handoff)
      # settles the change before anything restarts.
      not instance_changed? and selection_changed?(current, target) and
          selection in [:create_with_handoff] ->
        :create_with_handoff

      not instance_changed? and selection_changed?(current, target) and
          match?({:reject, _}, selection) ->
        selection

      instance_changed? or current.runtime_mode != target.runtime_mode or
          current.workspace != target.workspace ->
        :restart_and_resume

      selection_changed?(current, target) ->
        case selection do
          :restart_session -> :restart_and_resume
          :create_with_handoff -> :create_with_handoff
          {:reject, _} = reject -> reject
          _ -> :switch_model_in_session
        end

      true ->
        :reuse
    end
  end

  @doc "Whether two session states name different model selections, options included."
  def selection_changed?(current, target),
    do: canonical(current.selection) != canonical(target.selection)

  defp canonical(selection) do
    options =
      (selection["options"] || [])
      |> Enum.map(&{&1["id"], &1["value"]})
      |> Enum.sort()

    {selection["instanceId"], selection["model"], options}
  end

  @doc """
  The continuation group of a provider instance: sessions in one group can
  resume each other's native conversations. Codex instances share a group
  per Codex home (a shadow account shares its home's), Claude instances per
  config directory; every other instance is its own group.
  """
  def continuation("codex", instance) do
    home =
      HalC2.Codex.Home.shared(instance) || Path.join(HalC2.Paths.user_home(), ".codex")

    "codex:home:#{home}"
  end

  def continuation("claudeAgent", instance) do
    "claude:home:#{HalC2.Claude.Provider.config_dir(instance, File.cwd!())}"
  end

  def continuation(driver, instance), do: "#{driver}:instance:#{instance}"
end
