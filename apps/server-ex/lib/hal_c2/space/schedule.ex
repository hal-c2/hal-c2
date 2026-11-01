defmodule HalC2.Space.Schedule do
  @moduledoc """
  Pages that update themselves (`features/space/self-updating-pages.feature`).

  `HalC2.ScheduledTasks` keeps the one task of a page, `page:<pageId>`, and is the truth
  for its instruction, cadence and last run. It shows them on the page's `schedule` field
  (`view/1`, `show/2`), so a client reads a page's update from the stream it already
  follows; the field is never decided here. A run writes the generated part of the page
  (`HalC2.Space.Blocks.write_generated/4`) and `writtenAt` in one step, so a run that
  fails, or finds its page in the trash, leaves the page as it was.
  """

  alias HalC2.{Patch, ScheduledTasks, Shell, Space, StreamState, Streams, TextGeneration}
  alias HalC2.Space.{Blocks, Markdown, Pages}
  alias HalC2.TextGeneration.Prompts

  @author %{"type" => "schedule"}
  @recent_ms 2 * 86_400_000
  @recent_threads 20
  @thread_chars 1_500
  @page_chars 8_000

  @doc "Gives a live page its instruction and cadence, or changes them."
  def set(space_id, page_id, instruction, cadence) do
    with {:ok, instruction} <- instruction(instruction),
         {:ok, _} <- live(space_id, page_id),
         {:ok, _} <-
           scheduled(
             ScheduledTasks.put_page_task(%{
               "id" => task_id(page_id),
               "title" => "Page update",
               "page" => %{"spaceId" => space_id, "pageId" => page_id},
               "prompt" => instruction,
               "schedule" => cadence
             })
           ) do
      # The page may have gone to the trash since it was found live.
      :ok = ScheduledTasks.reconcile_pages(space_id)
      fresh(space_id, page_id)
    end
  end

  @doc "Pauses or resumes a live page's update. Resuming aims the next run afresh."
  def set_enabled(space_id, page_id, enabled) do
    with {:ok, _} <- live(space_id, page_id),
         {:ok, _} <-
           scheduled(
             ScheduledTasks.set_enabled(%{"id" => task_id(page_id), "enabled" => enabled})
           ),
         do: fresh(space_id, page_id)
  end

  @doc "Starts a run of a live page's update, paused or not. The page shows how it goes."
  def run_now(space_id, page_id) do
    with {:ok, _} <- live(space_id, page_id),
         {:ok, _} <- scheduled(ScheduledTasks.start(%{"id" => task_id(page_id)})),
         do: fresh(space_id, page_id)
  end

  @doc """
  Ends a live page's update. What it last wrote stays, as ordinary blocks the user can
  edit. A run under way ends with it.
  """
  def remove(space_id, page_id) do
    with {:ok, _} <- live(space_id, page_id),
         :ok <- has_task(page_id),
         {:ok, page} <- release_page(space_id, page_id),
         {:ok, _} <- scheduled(ScheduledTasks.delete(%{"id" => task_id(page_id)})) do
      # A run can land between the release and the delete, which ends it.
      release_page(space_id, page_id)
      {:ok, page}
    end
  end

  defp has_task(page_id) do
    if Enum.any?(ScheduledTasks.page_tasks(), &(&1["id"] == task_id(page_id))),
      do: :ok,
      else: {:error, :not_found, "This page has no update."}
  end

  # What the task wrote goes first: a task kept can still be removed, while a task gone
  # would leave a generated part nothing can release.
  defp release_page(space_id, page_id) do
    Space.transact(space_id, fn state ->
      with {:ok, page} <- Pages.fetch_live(state, page_id) do
        next = Map.merge(page, %{"schedule" => nil, "writtenAt" => nil})
        {page_change(page, next) ++ release(state, page_id), {:ok, next}}
      end
      |> Pages.refused()
    end)
  end

  defp page_change(page, next) do
    case Patch.diff(page, next) do
      :unchanged -> []
      patch -> [{"page", page["id"], patch}]
    end
  end

  defp release(state, page_id) do
    specs =
      case Enum.find(Blocks.of_page(state, page_id), &(&1["kind"] == "generated")) do
        nil -> []
        block -> block["text"] |> Markdown.blocks() |> Enum.map(&Space.links(state, &1))
      end

    Blocks.release_generated(state, page_id, specs, @author)
  end

  @doc "One run of a page's task: `{:ok, block}` once written, or `{:error, message}`."
  def run(%{"page" => %{"spaceId" => space_id, "pageId" => page_id}} = task) do
    with {:ok, state} <- Space.state(space_id),
         {:ok, page} <- Pages.fetch_live(state, page_id),
         {:ok, %{"markdown" => markdown}} <-
           TextGeneration.page_update(
             page["title"],
             task["prompt"],
             page_text(state, page),
             recent_threads()
           ),
         {:ok, markdown} <- written(markdown),
         {:ok, _} = done <- write(space_id, page_id, markdown) do
      done
    else
      {:error, _reason, message} -> {:error, message}
      {:error, {:unavailable, message}} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp written(markdown) do
    case String.trim(markdown) do
      "" -> {:error, "The run wrote nothing."}
      markdown -> {:ok, markdown}
    end
  end

  @doc "Writes a run's result as the generated part of a live page, and `writtenAt`, in one step."
  def write(space_id, page_id, markdown) do
    Space.transact(space_id, fn state ->
      with {:ok, page} <- Pages.fetch_live(state, page_id) do
        {changes, reply} = Blocks.write_generated(state, page_id, markdown, @author)
        next = Map.put(page, "writtenAt", HalC2.Orchestration.Entities.now())
        {page_change(page, next) ++ changes, reply}
      end
      |> Pages.refused()
    end)
  end

  defp page_text(state, page) do
    title_of = &(Pages.get(state, &1) || %{})["title"]

    page
    |> Markdown.export(Blocks.of_page(state, page["id"]), title_of)
    |> String.slice(0, @page_chars)
  end

  # Generators have no tools, so "yesterday's threads" reach them here: this MC's
  # threads active in the last two days, newest first, each cut to its latest part.
  defp recent_threads do
    since = DateTime.add(DateTime.utc_now(), -@recent_ms, :millisecond) |> DateTime.to_iso8601()

    rows =
      for {{mc, id}, {"thread", row}} <- Shell.rows(),
          mc == node(),
          row["deletedAt"] == nil and row["archivedAt"] == nil,
          is_binary(row["updatedAt"]) and row["updatedAt"] >= since,
          do: {id, row}

    rows
    |> Enum.sort_by(fn {_id, row} -> row["updatedAt"] end, :desc)
    |> Enum.take(@recent_threads)
    |> Enum.map_join("\n\n", fn {id, row} ->
      messages =
        id
        |> Streams.state()
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] in ["user", "assistant"] and &1["streaming"] != true))

      {text, _attachments} = Prompts.thread_context(messages)

      "Thread \"#{row["title"]}\" (#{row["updatedAt"]}):\n" <>
        String.slice(text, max(String.length(text) - @thread_chars, 0), @thread_chars)
    end)
  end

  @doc "What a page shows of its task."
  def view(task) do
    %{
      "instruction" => task["prompt"],
      "cadence" => task["schedule"],
      "enabled" => task["enabled"],
      "nextRunAt" => task["nextRunAt"],
      "lastRunAt" => task["lastRunAt"],
      "lastRunStatus" => task["lastRunStatus"],
      "lastRunError" => task["lastRunError"]
    }
  end

  @doc """
  Shows `view` (nil once the task is gone) on the page. A page that is gone needs
  nothing. `:error` when the Space's stream could not be written.
  """
  def show(%{"spaceId" => space_id, "pageId" => page_id}, view) do
    Space.transact(space_id, fn state ->
      case Pages.get(state, page_id) do
        nil ->
          {[], :ok}

        %{"schedule" => ^view} ->
          {[], :ok}

        page when view == nil and not is_map_key(page, "schedule") ->
          {[], :ok}

        page ->
          {[{"page", page_id, Patch.diff(page, Map.put(page, "schedule", view))}], :ok}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, :not_found, _} -> :ok
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  @doc "Whether a page's task should run: `:live`, `:held` in the trash, or `:gone`."
  def fate(%{"page" => %{"spaceId" => space_id, "pageId" => page_id}}) do
    with {:ok, state} <- Space.state(space_id),
         %{} = page <- Pages.get(state, page_id) do
      if Pages.live?(state, page), do: :live, else: :held
    else
      _ -> :gone
    end
  catch
    :exit, _ -> :unknown
  end

  defp task_id(page_id), do: "page:" <> page_id

  defp live(space_id, page_id) do
    with {:ok, state} <- Space.state(space_id), do: Pages.fetch_live(state, page_id)
  end

  defp fresh(space_id, page_id) do
    with {:ok, %{page: page}} <- Space.page(space_id, page_id), do: {:ok, page}
  end

  defp instruction(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :invalid, "A page's update needs an instruction."}
      text -> {:ok, text}
    end
  end

  defp instruction(_), do: {:error, :invalid, "A page's update needs an instruction."}

  defp scheduled({:ok, _} = ok), do: ok

  defp scheduled({:error, %{"message" => "Schedule task not found."}}),
    do: {:error, :not_found, "This page has no update."}

  defp scheduled({:error, %{"message" => message}}), do: {:error, :invalid, message}
end
