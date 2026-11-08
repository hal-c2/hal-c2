defmodule HalC2.ThreadFilesPropTest do
  @moduledoc """
  A state machine over the files a thread's messages carry, through the real
  `thread.fork` and `thread.delete`: a message too long to send whole, saved as a file
  (`HalC2.Attachments.fold_long_text/3`) before its message is written, as a send does,
  or one with a file attached; forks, forks of forks, and deletes in any order.

  The model is what each live thread's messages say, in order, with the contents of
  their files. After each command every live thread has those messages, and each of
  their files is on disk, holds what the model says, and is the thread's own (its id
  names the thread), so deleting any other thread leaves it alone.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Attachments, StreamState}

  @moduletag timeout: :infinity

  # Short of the limit by one, and past it: the second is folded into a file.
  @long 120_001

  property "a thread's files stay with it through forks and deletes",
    numtests: HalC2.Prop.numtests(50),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("thread-files")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell
        ])

        {:ok, _} =
          HalC2.Projects.mutate(%{
            "type" => "project.create",
            "projectId" => "demo",
            "title" => "demo",
            "workspaceRoot" => home
          })

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # live: each live thread's messages, oldest first, as {text, [file contents]}.
  # gone: the ids no thread may be created under again.
  def initial_state, do: %{live: %{}, gone: MapSet.new(), next: 1}

  def command(%{live: live} = state) do
    fresh = {:call, __MODULE__, :create, ["t#{state.next}"]}

    if live == %{} do
      fresh
    else
      ids = Map.keys(live)

      frequency([
        {1, fresh},
        {4, {:call, __MODULE__, :send, [oneof(ids), oneof([:long, :file, :short]), state.next]}},
        {2, {:call, __MODULE__, :fork, [oneof(ids), "t#{state.next}"]}},
        {2, {:call, __MODULE__, :delete, [oneof(ids)]}}
      ])
    end
  end

  def precondition(%{live: live, gone: gone}, {:call, _, :create, [id]}),
    do: not Map.has_key?(live, id) and id not in gone

  def precondition(%{live: live, gone: gone}, {:call, _, :fork, [source, target]}),
    do: live[source] not in [nil, []] and not Map.has_key?(live, target) and target not in gone

  def precondition(%{live: live}, {:call, _, _, [id | _]}), do: Map.has_key?(live, id)

  def next_state(state, _result, {:call, _, :create, [id]}),
    do: %{state | live: Map.put(state.live, id, []), next: state.next + 1}

  def next_state(state, _result, {:call, _, :send, [id, kind, n]}),
    do: %{
      state
      | live: Map.update!(state.live, id, &(&1 ++ [said(kind, n)])),
        next: state.next + 1
    }

  def next_state(state, _result, {:call, _, :fork, [source, target]}),
    do: %{state | live: Map.put(state.live, target, state.live[source]), next: state.next + 1}

  def next_state(state, _result, {:call, _, :delete, [id]}),
    do: %{state | live: Map.delete(state.live, id), gone: MapSet.put(state.gone, id)}

  def postcondition(state, call, result) do
    live = next_state(state, result, call).live

    failed =
      for {id, messages} <- live, problem = problem(id, messages), do: {id, problem}

    unless failed == [], do: IO.puts("after #{inspect(call)}: #{inspect(failed)}")
    failed == [] and result == :ok
  end

  # What a send of `kind` leaves in the thread: the text the thread shows and what its
  # files hold.
  defp said(:short, n), do: {text(:short, n), []}
  defp said(:file, n), do: {text(:file, n), ["notes #{n}"]}

  defp said(:long, n) do
    whole = text(:long, n)
    {fold(whole), [whole]}
  end

  defp text(:long, n), do: String.pad_trailing("message #{n} ", @long, "x")
  defp text(_kind, n), do: "message #{n}"

  # What the thread shows of a long message: its ends around what was cut.
  defp fold(text) do
    chars = String.length(text)

    String.slice(text, 0, 8_000) <>
      "\n\n[... #{chars - 10_000} characters cut here; the whole message is in the attached message.txt ...]\n\n" <>
      String.slice(text, chars - 2_000, 2_000)
  end

  defp problem(id, expected) do
    messages =
      HalC2.Streams.state(id)
      |> StreamState.list("message")
      |> Enum.sort_by(& &1["createdAt"])

    files = for message <- messages, do: Enum.map(message["attachments"] || [], &contents(id, &1))

    cond do
      Enum.map(messages, & &1["text"]) != Enum.map(expected, &elem(&1, 0)) -> :messages
      files != Enum.map(expected, &elem(&1, 1)) -> {:files, files}
      true -> nil
    end
  end

  # A file's contents, or why it is not the thread's own.
  defp contents(id, attachment) do
    path = Attachments.path(attachment)

    cond do
      path == nil ->
        :missing

      not String.starts_with?(attachment["id"], Attachments.thread_segment(id) <> "-") ->
        :borrowed

      true ->
        File.read!(path)
    end
  end

  # --- the real thing -------------------------------------------------------------

  def create(id) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => id,
        "projectId" => "demo",
        "title" => id,
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
      })

    :ok
  end

  # A message and the finished run it opened, its files saved before it is written, as
  # `message.dispatch` saves them before its stream writes the message.
  def send(id, kind, n) do
    {:ok, text, attachments} =
      case kind do
        :long ->
          Attachments.fold_long_text(id, text(:long, n), [])

        :file ->
          file = "#{Attachments.thread_segment(id)}-#{HalC2.Environment.uuid4()}"
          File.mkdir_p!(Attachments.dir())
          File.write!(Path.join(Attachments.dir(), file <> ".txt"), "notes #{n}")
          {:ok, text(:file, n), [%{"type" => "file", "id" => file, "name" => "notes.txt"}]}

        :short ->
          {:ok, text(:short, n), []}
      end

    at = DateTime.utc_now() |> DateTime.add(n, :millisecond) |> DateTime.to_iso8601()
    run = "run-#{n}"

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [
        {"run", run,
         %{
           "s" => %{
             "id" => run,
             "threadId" => id,
             "ordinal" => n,
             "status" => "completed",
             "userMessageId" => "msg-#{n}",
             "requestedAt" => at,
             "startedAt" => at,
             "completedAt" => at
           }
         }},
        {"message", "msg-#{n}",
         %{
           "s" => %{
             "id" => "msg-#{n}",
             "threadId" => id,
             "runId" => run,
             "role" => "user",
             "text" => text,
             "attachments" => attachments,
             "createdAt" => at,
             "updatedAt" => at
           }
         }}
      ])

    :ok
  end

  def fork(source, target) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "fork-#{target}",
        "createdBy" => "user",
        "creationSource" => "web",
        "sourceThreadId" => source,
        "targetThreadId" => target,
        "title" => target
      })

    :ok
  end

  def delete(id) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.delete",
        "commandId" => "delete-#{id}",
        "threadId" => id
      })

    :ok
  end
end
