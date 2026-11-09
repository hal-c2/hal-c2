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

  @fake_claude Path.expand("../../test/support/fake_claude_text.sh", __DIR__)

  setup_all do
    keys = [:text_claude_command, :text_codex_command, :gh_command]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:hal_c2, &1)})
    # No real agent writes the text, and no real `gh` opens a pull request.
    Application.put_env(:hal_c2, :text_claude_command, @fake_claude)
    Application.put_env(:hal_c2, :text_codex_command, "hal-c2-no-such-codex")
    Application.put_env(:hal_c2, :gh_command, "hal-c2-no-such-gh")

    on_exit(fn ->
      for {key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  # What the promise says, written apart from the socket's own table.
  defp required(action, thread) when action in @pr_actions and is_binary(thread),
    do: ["orchestration:operate", "orchestration:read"]

  defp required(_action, _thread), do: ["orchestration:operate"]

  # The action runs in a process of its own (`GitActions.start/2`) that the socket's caller
  # is not given. Waits for its last event, then for the process to be gone, so the case
  # never returns while it still reads the scratch home and environment. The worker is the
  # process holding `GitActions.run/2`'s `:git_action_thread` entry; it puts it before its
  # first event, so it is in view by the time the last one arrives.
  defp await_git_action(action_id) do
    receive do
      {:hal_c2_git_action, ^action_id, %{"kind" => kind}}
      when kind in ["action_finished", "action_failed"] ->
        for pid <- Process.list(),
            {:dictionary, dict} <- [Process.info(pid, :dictionary)],
            List.keymember?(dict, :git_action_thread, 0) do
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            10_000 -> flunk("the git action worker did not exit")
          end
        end

        true

      {:hal_c2_git_action, ^action_id, _event} ->
        await_git_action(action_id)
    after
      10_000 -> false
    end
  end

  property "a git action subscription is dispatched exactly when its scopes are all granted",
    numtests: HalC2.Prop.numtests(200) do
    forall {granted, action, thread} <- {
             let(l <- list(oneof(@scopes)), do: Enum.uniq(l)),
             oneof(@actions),
             oneof([nil, "th-1"])
           } do
      trap_exit do
        # The action commits and pushes: it runs in a repository of the case's own, with
        # a bare origin beside it, and its text comes from a fake agent, never a real one.
        {_home, home} = HalC2.Prop.scratch_repo("socket-git-scopes")
        File.write!(Path.join(home, "change.txt"), "change\n")

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
              started? = await_git_action(action_id)

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
