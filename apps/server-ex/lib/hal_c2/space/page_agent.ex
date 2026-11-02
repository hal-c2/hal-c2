defmodule HalC2.Space.PageAgent do
  @moduledoc """
  The agent a user asks from inside a page (`features/space/agent-in-page.feature`).

  An ask starts an ordinary thread (`HalC2.Orchestration.launch_thread/2`) and records
  a `pageAgent` entity in the Space's stream, one per page and keyed by it, which is
  how every client sees the agent work and end. The agent's edits are the
  `hal_c2_page_*` tools' edits, so page history names its thread; the entity holds no
  page content and the history fold never reads it.

  The thread carries `spacePage`, naming the page back. When a run of a thread that has
  one ends (`report/1`) and the thread is quiet, the entity settles: what the run ended
  as says how it ended, unless the user already asked it to stop. Only the thread named
  by the page's current entity settles it, so forks and earlier asks do nothing.

  Nothing else leaves a page saying it is working. Deleting the thread and moving it off
  this MC report too, and `error` says why an agent stopped when the page did not ask. What
  a crash lost (a launch, a report) `reconcile/1` settles at the next start.
  """

  require Logger

  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Delegation, Entities, TurnWatch, TurnWriter}
  alias HalC2.{Patch, StreamState, Streams}
  alias HalC2.Space
  alias HalC2.Space.{History, Pages}

  @kind "pageAgent"
  @active ~w(running stopping)
  @run_active ~w(preparing starting running waiting)
  @never_started "the MC restarted before its thread could start"
  # A restart, a continuation that could not start and an interrupt in the thread itself
  # all leave the same run behind. A stop from the page never says this.
  @interrupted "its run was interrupted"

  @doc "Whether an entity's agent is still at work."
  def active?(%{"status" => status}), do: status in @active
  def active?(_), do: false

  # What the page's prompt may choose for an ask, as `space.page.askAgent` names them.
  @choices ~w(projectId modelSelection runtimeMode interactionMode attachments context)

  @doc "The fields of `space.page.askAgent` an ask may choose (`ask/5`)."
  def choices, do: @choices

  @doc """
  Asks an agent to do `request` to a page: an optional leading `@agent` is not part of
  what is asked. The reply does not wait for the provider to start; a thread that cannot
  start fails on the page. `choices` are what the page's prompt chose (`choices/0`); each
  one left out is made as for a new thread where the user last worked. `target` turns
  them into where it runs.
  """
  def ask(space_id, page_id, request, choices \\ %{}, target \\ &target/1) do
    thread_id = HalC2.Environment.uuid4()

    with {:ok, request} <- request(request),
         {:ok, target} <- target.(choices),
         {:ok, attachments} <- attachments(thread_id, choices["attachments"]),
         {:ok, agent, page, space} <- record(space_id, page_id, request, thread_id) do
      message = %{"attachments" => attachments, "context" => choices["context"]}
      launch(agent, page, space, target, message)
      {:ok, agent}
    else
      refused ->
        # Images it saved for a thread that will never be.
        HalC2.Attachments.delete_thread(thread_id)
        refused
    end
  end

  @doc """
  The project an ask that picks none runs in, for the page's prompt to show:
  `%{"projectId" => id}`, nil when this MC has no project to run in.
  """
  def default_project do
    case last_worked() do
      {:ok, project_id, _project, _last} -> {:ok, %{"projectId" => project_id}}
      {:error, _, _} -> {:ok, %{"projectId" => nil}}
    end
  end

  @doc """
  Stops a page's agent: its runs are interrupted and it says `stopped` once they end, at
  once when nothing is left to end. An agent no longer at work is left as it is.
  """
  def stop(space_id, page_id) do
    marked =
      Space.transact(space_id, fn state ->
        case entity(state, page_id) do
          %{"status" => "running"} = agent ->
            change(agent, %{"status" => "stopping"})

          %{} = agent ->
            {[], {:ok, agent}}

          nil ->
            {[], no_agent(page_id)}
        end
      end)

    with {:ok, %{"status" => "stopping"} = agent} <- marked do
      stop_thread(agent["threadId"])
      settle(space_id, page_id, agent["threadId"])
      {:ok, entity(Streams.state(Space.stream_id(space_id)), page_id)}
    end
  end

  @doc "Takes away what a page says about an agent that is no longer at work."
  def dismiss(space_id, page_id) do
    Space.transact(space_id, fn state ->
      case entity(state, page_id) do
        nil ->
          {[], no_agent(page_id)}

        %{"status" => status} when status in @active ->
          {[], {:error, :invalid, "The agent is still working on this page. Stop it first."}}

        _ ->
          {[{@kind, page_id, Patch.delete()}], {:ok, page_id}}
      end
    end)
  end

  @doc """
  Called when `thread_id` may have nothing left to do for its page: a run or its background
  work ended, or the thread was deleted, moved off this MC or kept here after all.
  """
  def report(thread_id) do
    retrying(thread_id, fn ->
      with %{"spacePage" => %{"spaceId" => space_id, "pageId" => page_id}} <-
             Streams.get(thread_id, "thread", thread_id) do
        settle(space_id, page_id, thread_id)
      end
    end)
  end

  @doc """
  Called once at the start of an MC, after restarted turns have settled: every page still
  saying its agent is working is settled if its thread has nothing left to do, whatever
  the crash lost on the way. `continued` are the threads about to go on, whose runs do not
  exist yet. A stop the crash cut short is finished here, as nothing else will repeat it:
  what the restart put back in the queue goes with it.

  An ask this start of the MC took (`boot/0`) is left alone: the MC listens before this
  runs, and its launch may still be writing its thread.
  """
  def reconcile(continued \\ []) do
    boot = :persistent_term.get({__MODULE__, :boot}, nil)

    for %{"id" => space_id} <- StreamState.list(Streams.state(Space.index()), "space"),
        %{"pageId" => page_id, "threadId" => thread_id, "status" => status} = agent <-
          working(space_id),
        boot == nil or agent["boot"] != boot,
        status == "stopping" or thread_id not in continued do
      retrying(thread_id, fn ->
        if status == "stopping", do: stop_thread(thread_id)
        settle(space_id, page_id, thread_id)
      end)

      # No launch from before this start is under way, so one with no thread never will be.
      drop_unstarted(thread_id)
    end

    :ok
  end

  @doc """
  Takes a new token for this start of the MC, before it listens. Every ask is stamped
  with it, so the reconciliation can tell the asks this start took from those it lost; one
  from before there were tokens has none, and is from an earlier start.
  """
  def boot do
    token = HalC2.Environment.uuid4()
    :persistent_term.put({__MODULE__, :boot}, token)
    token
  end

  @doc "Whether the page `thread_id` works on asked it to stop: a restart does not start it again."
  def stopping?(thread_id) do
    with %{"spacePage" => %{"spaceId" => space_id, "pageId" => page_id}} <-
           Streams.get(thread_id, "thread", thread_id),
         %{"threadId" => ^thread_id, "status" => "stopping"} <-
           entity(Streams.state(Space.stream_id(space_id)), page_id) do
      true
    else
      _ -> false
    end
  catch
    kind, reason ->
      Logger.warning("page agent of #{thread_id} not read: #{inspect({kind, reason})}")
      false
  end

  defp working(space_id) do
    space_id
    |> Space.stream_id()
    |> Streams.state()
    |> StreamState.list(@kind)
    |> Enum.filter(&active?/1)
  catch
    kind, reason ->
      Logger.warning("page agents of #{space_id} not read: #{inspect({kind, reason})}")
      []
  end

  # Retries like the delegated task's report, so a Space stream that is briefly busy cannot
  # lose it.
  defp retrying(thread_id, fun, attempts \\ 6, backoff \\ 2_000) do
    fun.()
    :ok
  catch
    _kind, reason when attempts > 0 ->
      Logger.warning("page agent report for #{thread_id} retried: #{inspect(reason)}")
      Process.sleep(backoff)
      retrying(thread_id, fun, attempts - 1, backoff * 2)
  end

  # Settles the page's entity if `thread_id` is still its agent and has nothing left to do.
  # A thread stays marked for its page after it settled, and `edited?/3` folds the Space's
  # log, so a thread no longer this page's agent stops at the first read.
  defp settle(space_id, page_id, thread_id) do
    with %{"threadId" => ^thread_id, "status" => status} when status in @active <-
           entity(Streams.state(Space.stream_id(space_id)), page_id),
         {ended, error} <- ended(thread_id, status == "stopping") do
      edited = edited?(space_id, page_id, thread_id)

      Space.transact(space_id, fn state ->
        case entity(state, page_id) do
          %{"threadId" => ^thread_id, "status" => status} = agent when status in @active ->
            change(agent, %{
              "status" => if(status == "stopping", do: "stopped", else: ended),
              "edited" => edited,
              "error" => if(status == "stopping", do: nil, else: error),
              "endedAt" => Entities.now()
            })

          _ ->
            {[], :ok}
        end
      end)
    else
      _ -> :ok
    end
  end

  # How the thread's work ended and why it did, or nil while it is not over. A stop settles
  # a launch still under way; nothing else gets here with a thread or run missing unless
  # the launch died with the MC. A stop waits for the runs, not for what they left in the
  # background: that can go on for as long as a dev server does, and the page would have
  # no way out.
  defp ended(thread_id, stopping?) do
    stream = Streams.state(thread_id)
    thread = StreamState.get(stream, "thread")[thread_id]
    runs = StreamState.list(stream, "run")

    cond do
      thread == nil -> {"failed", @never_started}
      thread["deletedAt"] != nil -> {"stopped", "its thread was deleted"}
      moved = thread["movedTo"] -> {"stopped", moved_away(moved)}
      thread["moving"] != nil -> nil
      runs == [] -> {"failed", @never_started}
      stopping? and Enum.any?(runs, &run_to_end?/1) -> nil
      not stopping? and not Delegation.settled?(stream) -> nil
      true -> run_end(stream, runs)
    end
  end

  defp run_to_end?(%{"status" => "queued"} = run), do: run["queueHeld"] != true
  defp run_to_end?(run), do: run["status"] in @run_active

  # Spaces stay on their MC: the agent can go on over there, but not on this page.
  defp moved_away(%{"label" => label}),
    do: "its thread moved to #{label}, where it can no longer edit this page"

  # Of the runs that began: one cancelled reached here from the queue, and says nothing of
  # how the work ended.
  defp run_end(stream, runs) do
    case runs
         |> Enum.reject(&(&1["status"] in ~w(rolled_back queued cancelled)))
         |> HalC2.Projection.Shell.latest_run() do
      %{"status" => "completed"} -> {"completed", nil}
      %{"status" => "failed"} = run -> {"failed", failure(stream, run)}
      _ -> {"stopped", @interrupted}
    end
  end

  # A failed run's own word on why: its latest error item, or for a plain failure, what
  # its provider session last said.
  defp failure(stream, %{"id" => run_id}) do
    stream
    |> StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == "error" and &1["runId"] == run_id))
    |> Enum.sort_by(&(&1["ordinal"] || 0))
    |> List.last(%{})
    |> Map.get("failure")
    |> case do
      %{"message" => message} when is_binary(message) and message != "" -> message
      message when is_binary(message) and message != "" -> message
      _ -> last_session_error(stream) || "The agent's turn failed."
    end
  end

  defp last_session_error(stream) do
    stream
    |> StreamState.list("provider-session")
    |> Enum.filter(&is_binary(&1["lastError"]))
    |> Enum.max_by(&(&1["updatedAt"] || ""), fn -> %{} end)
    |> Map.get("lastError")
  end

  defp edited?(space_id, page_id, thread_id) do
    case History.versions(space_id, page_id, nil, 100) do
      {:ok, %{versions: versions}} ->
        Enum.any?(versions, &(&1.author == Space.agent(thread_id)))

      _ ->
        false
    end
  end

  defp stop_thread(thread_id) do
    # Queued runs first, or the end of the active one would start the next.
    runs = thread_id |> Streams.state() |> StreamState.list("run")

    for %{"id" => run_id, "status" => status} <- Enum.sort_by(runs, &(&1["status"] != "queued")),
        status == "queued" or status in @run_active do
      type = if status == "queued", do: "queued-run.cancel", else: "run.interrupt"
      _ = Orchestration.dispatch(%{"type" => type, "threadId" => thread_id, "runId" => run_id})

      # A run still only starting with nothing driving it never reaches `begin_turn`
      # (`HalC2.ScheduledTasks` has the same case), so nothing else would end it.
      if status in ~w(starting preparing) and not TurnWatch.driven?(run_id),
        do: TurnWriter.abandon(thread_id, run_id, "interrupted", nil)
    end

    :ok
  end

  # --- the ask ------------------------------------------------------------------------

  defp request(request) when is_binary(request) do
    case request |> String.trim() |> String.replace(~r/^@agent\b/i, "") |> String.trim() do
      "" -> {:error, :invalid, "Say what the agent should do to this page."}
      request -> {:ok, request}
    end
  end

  defp request(_), do: {:error, :invalid, "Say what the agent should do to this page."}

  # In one step with the check on the page, so of two asks at once only one has a thread.
  defp record(space_id, page_id, request, thread_id) do
    Space.transact(space_id, fn state ->
      with {:ok, page} <- Pages.fetch_live(state, page_id),
           :ok <- free(state, page_id) do
        at = Entities.now()

        agent = %{
          "id" => page_id,
          "pageId" => page_id,
          "threadId" => thread_id,
          "request" => request,
          "status" => "running",
          "edited" => false,
          "error" => nil,
          "startedAt" => at,
          "endedAt" => nil,
          "boot" => :persistent_term.get({__MODULE__, :boot}, nil)
        }

        previous = entity(state, page_id)

        {[{@kind, page_id, Patch.diff(previous, agent)}],
         {:ok, agent, page, space_name(space_id)}}
      else
        refused -> {[], refused}
      end
    end)
  end

  defp free(state, page_id) do
    if active?(entity(state, page_id)),
      do: {:error, :invalid, "An agent is already working on this page. Wait for it or stop it."},
      else: :ok
  end

  defp space_name(space_id), do: (Streams.get(Space.index(), "space", space_id) || %{})["name"]

  # Starting a thread can wait on the provider, so it happens off the caller. What it
  # could not start fails on the page, and an agent stopped meanwhile stops here: its
  # thread did not exist yet when the stop looked for it.
  defp launch(agent, page, space, target, message) do
    Task.start(fn ->
      launched =
        try do
          launcher().(input(agent, page, space, target, message))
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end

      space_id = page["spaceId"]

      case launched do
        {:ok, _} -> after_launch(space_id, agent)
        {:error, reason} -> not_started(space_id, agent, reason)
        {:error, _, reason} -> not_started(space_id, agent, reason)
      end
    end)
  end

  # Images the ask saved for a thread that was never written: nothing else would ever
  # delete them. Not on a stop, which can come while the launch is still writing it.
  defp drop_unstarted(thread_id) do
    if Streams.get(thread_id, "thread", thread_id) == nil,
      do: HalC2.Attachments.delete_thread(thread_id)
  end

  defp launcher, do: Application.get_env(:hal_c2, :page_agent_launch, &launch_thread/1)
  defp launch_thread(input), do: Orchestration.launch_thread(input)

  defp after_launch(space_id, %{"pageId" => page_id, "threadId" => thread_id}) do
    retrying(thread_id, fn ->
      case entity(Streams.state(Space.stream_id(space_id)), page_id) do
        %{"threadId" => ^thread_id, "status" => "running"} ->
          :ok

        %{"threadId" => ^thread_id, "status" => "stopping"} ->
          stop_thread(thread_id)
          settle(space_id, page_id, thread_id)

        _ ->
          stop_thread(thread_id)
      end
    end)
  end

  defp not_started(space_id, %{"pageId" => page_id, "threadId" => thread_id}, reason) do
    drop_unstarted(thread_id)

    retrying(thread_id, fn ->
      Space.transact(space_id, fn state ->
        case entity(state, page_id) do
          %{"threadId" => ^thread_id, "status" => status} = agent when status in @active ->
            stopping? = status == "stopping"

            change(agent, %{
              "status" => if(stopping?, do: "stopped", else: "failed"),
              "error" => if(stopping?, do: nil, else: reason_text(reason)),
              "endedAt" => Entities.now()
            })

          _ ->
            {[], :ok}
        end
      end)
    end)
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(%{"message" => message}) when is_binary(message), do: message
  defp reason_text(reason), do: inspect(reason)

  defp input(agent, page, space, target, message) do
    thread_id = agent["threadId"]

    %{
      "commandId" => "page-agent:#{thread_id}",
      "threadId" => thread_id,
      "projectId" => target.project_id,
      "title" => title(page, agent["request"]),
      "modelSelection" => target.model,
      "runtimeMode" => target.runtime_mode,
      "interactionMode" => target.interaction_mode,
      "workspaceStrategy" => %{"type" => "root"},
      "createdBy" => "user",
      "creationSource" => "server",
      "spacePage" => %{"spaceId" => page["spaceId"], "pageId" => page["id"]},
      "initialMessage" =>
        %{
          "messageId" => "page-agent-message:#{thread_id}",
          "text" => prompt(agent["request"], page, space),
          "attachments" => message["attachments"]
        }
        |> then(&if(message["context"], do: Map.put(&1, "context", message["context"]), else: &1))
    }
  end

  # An image sent inline is saved for the thread, as `assets.persistChatAttachments` does
  # for a turn; what the MC already holds, such as an uploaded file, is claimed at launch.
  defp attachments(_thread_id, nil), do: {:ok, []}

  defp attachments(thread_id, attachments) when is_list(attachments) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn
      %{"dataUrl" => _} = image, {:ok, acc} ->
        case HalC2.Attachments.persist(%{"threadId" => thread_id, "attachments" => [image]}) do
          {:ok, %{"attachments" => [stored]}} -> {:cont, {:ok, [stored | acc]}}
          {:error, %{"message" => message}} -> {:halt, {:error, :invalid, message}}
        end

      %{} = held, {:ok, acc} ->
        {:cont, {:ok, [held | acc]}}

      _, _ ->
        {:halt, {:error, :invalid, "An attachment of the ask is not one."}}
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      refused -> refused
    end
  end

  defp attachments(_thread_id, _), do: {:error, :invalid, "The ask's attachments are not a list."}

  defp title(page, request), do: String.slice("#{page["title"]}: #{request}", 0, 80)

  # The request comes first: it is what the user asked, and what the thread opens with.
  defp prompt(request, page, space) do
    """
    #{request}

    This is about the page "#{page["title"]}" (pageId #{page["id"]}) in the Space \
    "#{space}" (spaceId #{page["spaceId"]}). Read it with hal_c2_page_read and change it \
    with hal_c2_page_block_insert, hal_c2_page_block_update and hal_c2_page_block_delete. \
    Your edits appear on the page as you make them, and its history names this thread. \
    If those tools are not available to you, say so plainly instead of answering with \
    the text you would have written.
    """
  end

  # --- which project and model --------------------------------------------------------

  # Where an ask runs: what the prompt chose, else as a new thread where the user last
  # worked would.
  defp target(choices) do
    with {:ok, project_id, project, last} <- project(choices["projectId"]) do
      settings = HalC2.Settings.for_project(project_id)

      if settings["enableAgentBrowserAccess"] == false do
        {:error, :invalid,
         "The HAL-C2 tools are off for the project \"#{project["title"]}\", so an agent could not edit this page."}
      else
        with {:ok, model} <- model(choices["modelSelection"], settings, project, last) do
          {:ok,
           %{
             project_id: project_id,
             model: model,
             runtime_mode:
               choices["runtimeMode"] || settings["defaultRuntimeMode"] || "full-access",
             interaction_mode: choices["interactionMode"] || "default"
           }}
        end
      end
    end
  end

  defp project(nil), do: last_worked()

  # A project the prompt picked, with the thread the user worked in last there, so its
  # model is the one an ask that picked none would use in the same project.
  defp project(project_id) do
    {threads, projects} = local_rows()

    case Enum.find(projects, &(&1["id"] == project_id)) do
      nil ->
        {:error, :invalid, "That project is not on this MC, so an agent cannot run in it."}

      project ->
        last = threads |> Enum.filter(&(&1["projectId"] == project_id)) |> latest()
        {:ok, project_id, project, last}
    end
  end

  # The project of the thread the user worked in last, else the project made last: a page
  # belongs to no project, and this is where the user is most likely working. What plugins
  # and agents started in the background says nothing about that.
  defp last_worked do
    {threads, projects} = local_rows()
    known = MapSet.new(projects, & &1["id"])

    last = threads |> Enum.filter(&(&1["projectId"] in known)) |> latest()

    case (last && last["projectId"]) || (latest(projects) || %{})["id"] do
      nil ->
        {:error, :invalid, "Add a project first: an agent needs one to run in."}

      project_id ->
        {:ok, project_id, Enum.find(projects, &(&1["id"] == project_id)), last}
    end
  end

  defp local_rows do
    rows = HalC2.Shell.rows() |> Enum.flat_map(&local_row/1)
    threads = for {"thread", row} <- rows, row["deletedAt"] == nil, by_user?(row), do: row
    projects = for {"project", row} <- rows, row["deletedAt"] == nil, do: row
    {threads, projects}
  end

  defp by_user?(thread), do: thread["createdBy"] in ["user", nil]

  # A model the prompt chose is the user's word: one that cannot run is refused, not
  # swapped for another behind their back.
  defp model(%{"instanceId" => instance} = chosen, _settings, _project, _last) do
    if runs?(chosen, HalC2.Environment.providers()),
      do: {:ok, chosen},
      else:
        {:error, :invalid,
         "#{instance} is turned off or cannot start an agent right now. Choose another model."}
  end

  # The clients' order for a new thread, then the model last used, then the first
  # provider that can run at all. A model on a provider that can't run gives way.
  defp model(_none, settings, project, last) do
    providers = HalC2.Environment.providers()

    candidates = project_models(settings, project) ++ [last && last["modelSelection"]]

    case Enum.find(candidates, &runs?(&1, providers)) || first_model(providers) do
      nil -> {:error, :invalid, "No provider can start an agent right now."}
      model -> {:ok, model}
    end
  end

  # `settings` is already `HalC2.Settings.for_project/1`'s: the project's override is its
  # default only if its provider is enabled, and then it comes before the project's own.
  defp project_models(settings, project) do
    default = settings["defaultModelSelection"]

    override =
      get_in(settings, ["projectSettingsOverrides", project["id"], "defaultModelSelection"])

    if override == default,
      do: [default, project["defaultModelSelection"]],
      else: [project["defaultModelSelection"], default]
  end

  defp runs?(%{"instanceId" => instance}, providers) do
    Enum.any?(providers, fn provider ->
      provider["instanceId"] == instance and HalC2.Mcp.Tools.Threads.constraints(provider) == []
    end)
  end

  defp runs?(_model, _providers), do: false

  defp first_model(providers) do
    Enum.find_value(providers, fn provider ->
      with [] <- HalC2.Mcp.Tools.Threads.constraints(provider),
           %{"slug" => slug} <- get_in(provider, ["models", Access.at(0)]) do
        %{"instanceId" => provider["instanceId"], "model" => slug}
      else
        _ -> nil
      end
    end)
  end

  defp local_row({{mc, _id}, kind_row}) when mc == node(), do: [kind_row]
  defp local_row(_), do: []

  defp latest([]), do: nil
  defp latest(rows), do: Enum.max_by(rows, &(&1["updatedAt"] || ""))

  # --- the entity ---------------------------------------------------------------------

  defp entity(state, page_id), do: StreamState.get(state, @kind)[page_id]

  defp change(agent, fields) do
    next = Map.merge(agent, fields)
    {[{@kind, agent["id"], Patch.diff(agent, next)}], {:ok, next}}
  end

  defp no_agent(page_id),
    do: {:error, :not_found, "No agent has been asked on the page #{page_id}."}
end
