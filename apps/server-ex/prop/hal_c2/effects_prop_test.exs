defmodule HalC2.EffectsPropTest do
  @moduledoc """
  The recorded side effects of accepted commands (`HalC2.Orchestration.Effects`):
  a thread's effects run in the order they were recorded on their lane and every
  one settles, and a worker that starts over work a lost server process left
  behind cancels what was tied to its provider processes — with the reason
  recorded, its tries untouched — and runs what is safe to repeat again.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Orchestration.{Effects, Entities}

  @moduletag timeout: :infinity

  @threads ~w(t1 t2)
  @bound ~w(provider-turn.start provider-turn.interrupt provider-turn.steer
            provider-turn.restart runtime-request.respond)
  @safe ~w(provider-runtime.continue provider-session.detach provider-thread.rollback
           checkpoint.capture terminal.cleanup attachment.cleanup thread-title.generate)
  @process_ended "Cancelled because the server process ended before the effect completed."

  # The effects hook: what ran, in the order it ran.
  def note(test, :execute, record), do: send(test, {:executed, record["id"]})

  property "effects run in lane order and settle", numtests: HalC2.Prop.numtests(25) do
    forall work <-
             list(
               {oneof(Enum.map(@threads, &exactly/1)),
                oneof([
                  exactly("terminal.cleanup"),
                  exactly("checkpoint.capture"),
                  exactly("unknown.kind")
                ])}
             ) do
      trap_exit do
        home = services()
        Application.put_env(:hal_c2, :effects_hook, {__MODULE__, :note, [self()]})

        enqueued =
          for {thread, type} <- work do
            {:ok, id} = Effects.enqueue(thread, type, args(type, thread, home))
            {thread, type, id}
          end

        :ok = Effects.drain(nil, 30_000)
        executed = collect_executed([])

        in_order =
          Enum.all?(@threads, fn thread ->
            mine = for {^thread, _type, id} <- enqueued, do: id
            Enum.filter(executed, &(&1 in mine)) == mine
          end)

        settled =
          Enum.all?(enqueued, fn {thread, type, id} ->
            case Enum.find(Effects.effects(thread), &(&1["id"] == id)) do
              nil -> type != "unknown.kind"
              %{"status" => "failed", "attempts" => 1} -> type == "unknown.kind"
              _ -> false
            end
          end)

        Application.delete_env(:hal_c2, :effects_hook)
        HalC2.Prop.stop_services()
        in_order and settled
      end
    end
  end

  property "a restart cancels provider-bound work and replays safe work",
    numtests: HalC2.Prop.numtests(25) do
    forall left <-
             list(
               {oneof(Enum.map(@bound ++ @safe, &exactly/1)),
                oneof([exactly("pending"), exactly("running")]), integer(0, 2)}
             ) do
      trap_exit do
        home = services()
        sup = Process.get({HalC2.Prop, :services})
        :ok = Supervisor.terminate_child(sup, HalC2.Orchestration.Effects)

        fabricated =
          left
          |> Enum.with_index(1)
          |> Enum.map(fn {{type, status, attempts}, index} ->
            record = %{
              "id" => "effect:left-#{index}",
              "threadId" => "t1",
              "type" => type,
              "lane" => if(type == "thread-title.generate", do: "title", else: "provider"),
              "status" => status,
              "attempts" => attempts,
              "delays" => [],
              "error" => nil,
              "args" => args(type, "t1", home),
              "createdAt" => Entities.now(),
              "updatedAt" => Entities.now()
            }

            HalC2.Store.put_meta("effect:t1:#{record["id"]}", JSON.encode!(record))
            record
          end)

        {:ok, _} = Supervisor.restart_child(sup, HalC2.Orchestration.Effects)
        :ok = Effects.drain(nil, 30_000)
        records = Effects.effects("t1")

        classified =
          Enum.all?(fabricated, fn record ->
            after_restart = Enum.find(records, &(&1["id"] == record["id"]))

            if record["type"] in @bound do
              after_restart != nil and after_restart["status"] == "cancelled" and
                after_restart["error"] == @process_ended and
                after_restart["attempts"] == record["attempts"]
            else
              # Ran again: done (its record is deleted) or failed with a try spent.
              after_restart == nil or
                (after_restart["status"] == "failed" and
                   after_restart["attempts"] > record["attempts"])
            end
          end)

        HalC2.Prop.stop_services()
        classified
      end
    end
  end

  property "a boot keeps a thread's newest settled failures, none older than a week",
    numtests: HalC2.Prop.numtests(25) do
    forall settled <-
             let(
               count <- integer(0, 130),
               do:
                 vector(
                   count,
                   {oneof([exactly("failed"), exactly("cancelled")]),
                    oneof(Enum.map([0, 1, 6, 8, 10], &exactly/1))}
                 )
             ) do
      trap_exit do
        _home = services()
        sup = Process.get({HalC2.Prop, :services})
        :ok = Supervisor.terminate_child(sup, HalC2.Orchestration.Effects)
        now = DateTime.utc_now()

        fabricated =
          settled
          |> Enum.with_index(1)
          |> Enum.map(fn {{status, days}, index} ->
            at =
              now
              |> DateTime.add(-days, :day)
              |> DateTime.add(-index, :minute)
              |> DateTime.truncate(:millisecond)

            record = %{
              "id" => "effect:settled-#{index}",
              "threadId" => "t1",
              "type" => "terminal.cleanup",
              "lane" => "provider",
              "status" => status,
              "attempts" => 1,
              "delays" => [],
              "error" => "earlier",
              "args" => %{},
              "createdAt" => DateTime.to_iso8601(at),
              "updatedAt" => DateTime.to_iso8601(at)
            }

            HalC2.Store.put_meta("effect:t1:#{record["id"]}", JSON.encode!(record))
            record
          end)

        {:ok, _} = Supervisor.restart_child(sup, HalC2.Orchestration.Effects)
        # Through the worker, so its boot sweep has run before rows are read.
        :ok = Effects.drain(nil, 30_000)

        want =
          fabricated
          |> Enum.sort_by(& &1["updatedAt"], :desc)
          |> Enum.take(100)
          |> Enum.filter(fn record ->
            {:ok, at, _} = DateTime.from_iso8601(record["updatedAt"])
            DateTime.diff(now, at, :millisecond) <= 7 * 24 * 60 * 60 * 1000
          end)
          |> MapSet.new(& &1["id"])

        kept = MapSet.new(Effects.effects("t1"), & &1["id"])
        :ok = Effects.drop_thread("t1")
        dropped = Effects.effects("t1") == []

        HalC2.Prop.stop_services()
        kept == want and dropped
      end
    end
  end

  defp collect_executed(acc) do
    receive do
      {:executed, id} -> collect_executed([id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The least each kind needs to run against an empty thread in a scratch home.
  defp args("checkpoint.capture", _thread, home) do
    %{
      "cwd" => home,
      "scopeId" => "scope",
      "runOrdinal" => 1,
      "runId" => "run-x",
      "rootNodeId" => "node-x",
      "at" => Entities.now()
    }
  end

  defp args("provider-runtime.continue", thread, _home),
    do: %{
      "command" => %{
        "type" => "thread.visit",
        "threadId" => thread,
        "visitedAt" => Entities.now()
      }
    }

  defp args("provider-thread.rollback", thread, _home) do
    %{
      "command" => %{
        "type" => "checkpoint.rollback",
        "threadId" => thread,
        "scopeId" => "scope",
        "checkpointId" => "checkpoint"
      }
    }
  end

  defp args("thread-title.generate", _thread, _home),
    do: %{"text" => "hi", "attachments" => [], "previous" => "Old title"}

  defp args(type, _thread, _home) when type in @bound,
    do: %{"runId" => "run-x", "requestId" => "request-x"}

  defp args(_type, _thread, _home), do: %{}

  defp services do
    home = HalC2.Prop.scratch_home("effects")

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Settings,
      HalC2.Orchestration.TurnWatch,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
        id: :pi_registry
      ),
      HalC2.Orchestration.Effects
    ])

    home
  end
end
