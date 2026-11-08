defmodule HalC2.SocketGitActionScopesPropTest do
  @moduledoc """
  Which scopes a git action subscription on the WebSocket needs: every action needs
  `orchestration:operate`, and a pull request action for a thread (`create_pr`,
  `commit_push_pr`) needs `orchestration:read` too, because its text is written from the
  thread's history. Commit and push stay operate-only, with or without a thread. A
  subscription that lacks a scope is answered with an error naming it and changes
  nothing, so it never starts the action; one that holds them all starts it.

  Over every subset of the scopes a session can hold, and every action with and
  without a thread.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Web.Socket

  @moduletag timeout: :infinity

  @scopes ~w(orchestration:read orchestration:operate terminal:operate)
  @actions ~w(commit push commit_push create_pr commit_push_pr)
  @pr_actions ~w(create_pr commit_push_pr)

  # What the promise says, written apart from the socket's own table.
  defp required(action, thread) when action in @pr_actions and is_binary(thread),
    do: ["orchestration:operate", "orchestration:read"]

  defp required(_action, _thread), do: ["orchestration:operate"]

  property "a git action subscription is dispatched exactly when its scopes are all granted",
    numtests: HalC2.Prop.numtests(200) do
    forall {granted, action, thread} <- {
             let(l <- list(oneof(@scopes)), do: Enum.uniq(l)),
             oneof(@actions),
             oneof([nil, "th-1"])
           } do
      trap_exit do
        home = HalC2.Prop.scratch_home("socket-git-scopes")

        {:push, _hello, state} = Socket.init([])
        state = %{state | scopes: granted}
        id = 7
        action_id = "act-1"

        input =
          %{"actionId" => action_id, "cwd" => home, "action" => action}
          |> then(&if(thread, do: Map.put(&1, "threadId", thread), else: &1))

        frame =
          JSON.encode!(%{
            "t" => "sub",
            "id" => id,
            "shape" => %{"type" => "gitAction", "mc" => Atom.to_string(node()), "input" => input}
          })

        missing = Enum.find(required(action, thread), &(&1 not in granted))
        result = Socket.handle_in({frame, [opcode: :text]}, state)

        ok? =
          case {missing, result} do
            {nil, {:ok, next}} ->
              # Started: the action answers with its events, and the socket follows it.
              started? =
                receive do
                  {:hal_c2_git_action, ^action_id, _event} -> true
                after
                  10_000 -> false
                end

              started? and next.by_terminal[{:git_action, action_id}] == id and
                Map.has_key?(next.subs, id)

            {scope, {:push, {:text, reply}, next}} when is_binary(scope) ->
              %{"t" => "error", "id" => ^id, "reason" => reason} =
                reply |> IO.iodata_to_binary() |> JSON.decode!()

              next == state and reason =~ scope

            _ ->
              false
          end

        ok?
        |> when_fail(
          IO.puts(
            "granted #{inspect(granted)} action #{action} thread #{inspect(thread)}: #{inspect(result)}"
          )
        )
        |> aggregate([{action, thread != nil, missing == nil}])
      end
    end
  end
end
