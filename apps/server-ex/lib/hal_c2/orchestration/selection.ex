defmodule HalC2.Orchestration.Selection do
  @moduledoc """
  What a thread runs on, and who may change it.

  A thread's model selection, provider instance, runtime mode and interaction mode
  share one counter, `selectionRevision`, which every change to any of them moves on.
  `stamp/2` keeps it, and the queue that follows it, for every commit to a thread's
  stream (`HalC2.Streams.Server`), so no writer can forget to: one that sets a field
  bumps the counter, one that brings a thread from elsewhere (a move, an import)
  carries its counter, and the counter never goes backwards.

  A client that shows the user a choice sends the revision it showed with what the
  user picked (`selectionBase`). `stale/2` refuses that pick once the thread has
  moved on to something else: the newest deliberate choice wins, and nothing a client
  did not show can win. A command without a base (an older client, an agent's tools)
  is taken as before.

  A queued message's run says what it will run on. One the user picked a choice for
  (`selectionPicked`) keeps it until the thread's choice changes some other way, and
  then gives way to it; one without a pick follows the thread. The MC's own messages
  name nothing and are left alone. `proof/models/model_selection.maude` models the
  protocol; `features/composer/model-and-mode.feature` names what it promises.
  """

  alias HalC2.{Patch, StreamState}
  alias HalC2.Orchestration.Entities

  @fields ~w(modelSelection providerInstanceId runtimeMode interactionMode)
  @picks ~w(modelSelection runtimeMode interactionMode)

  @doc "A thread's selection revision; 0 for a thread from before there was one."
  @spec revision(map | nil) :: non_neg_integer
  def revision(%{"selectionRevision" => rev}) when is_integer(rev) and rev >= 0, do: rev
  def revision(_thread), do: 0

  @doc """
  `changes`, about to be committed to a thread's stream in `state`, with the thread's
  `selectionRevision` kept: one more when the commit changes what the thread runs on,
  never less than the thread had or than the commit brings. When the choice changed,
  queued runs follow it, or give way to it: a run whose message picked a choice keeps
  it only when the change is a queued run's own pick taken at its start, decided before
  any later pick.
  """
  @spec stamp(StreamState.t(), [tuple]) :: [tuple]
  def stamp(state, changes) do
    changes
    |> Enum.flat_map(fn
      {"thread", id, _} -> [id]
      {"thread", id, _, _} -> [id]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.reduce(changes, &stamp_thread(state, &1, &2))
  end

  defp stamp_thread(state, id, changes) do
    case next(state, id, changes) do
      nil ->
        changes

      {thread, rev, changed?} ->
        changes =
          if thread["selectionRevision"] == rev,
            do: changes,
            else: changes ++ [{"thread", id, %{"s" => %{"selectionRevision" => rev}}}]

        if changed?, do: changes ++ queue_changes(state, thread, changes), else: changes
    end
  end

  @doc """
  The revision thread `id` moves to when `changes` are committed in `state`, when they
  change what it runs on; nil when they leave it be. A command's reply carries it
  (`selectionRevision`), so the client that sent it can tell its own change from one
  made elsewhere: a pick shown at `r` stays current at `r + 1` only when its own
  command moved the thread there.
  """
  @spec moved(StreamState.t(), String.t(), [tuple]) :: non_neg_integer | nil
  def moved(state, id, changes) do
    case next(state, id, changes) do
      {_thread, rev, true} -> rev
      _ -> nil
    end
  end

  # The thread once `changes` apply, the revision it then has, and whether they
  # changed what it runs on.
  defp next(state, id, changes) do
    before = StreamState.get(state, "thread")[id]

    case folded(before, "thread", id, changes) do
      nil ->
        nil

      thread ->
        changed? = before != nil and Map.take(before, @fields) != Map.take(thread, @fields)

        rev =
          cond do
            before == nil -> revision(thread)
            changed? -> max(revision(before) + 1, revision(thread))
            true -> max(revision(before), revision(thread))
          end

        {thread, rev, changed?}
    end
  end

  # The queued runs of the thread, once `changes` apply, that now say something else.
  defp queue_changes(state, thread, changes) do
    runs = StreamState.get(state, "run")

    touched =
      for change <- changes, elem(change, 0) == "run", uniq: true, do: elem(change, 1)

    after_runs =
      Enum.reduce(touched, runs, fn id, acc ->
        Map.put(acc, id, folded(runs[id], "run", id, changes))
      end)

    # A queued run that leaves the queue in this commit took its own pick: those queued
    # behind it were picked after it, and stay picked.
    taken? =
      Enum.any?(touched, fn id ->
        get_in(runs, [id, "status"]) == "queued" and
          get_in(after_runs, [id, "status"]) not in [nil, "queued"]
      end)

    for {id, run} <- after_runs,
        run != nil and run["status"] == "queued" and run["threadId"] == thread["id"],
        Map.has_key?(run, "selectionPicked"),
        next = queued(run, thread, taken?),
        %{} = patch <- [Patch.diff(run, next)],
        do: {"run", id, patch}
  end

  defp queued(%{"selectionPicked" => true} = run, _thread, true), do: run

  defp queued(run, thread, _taken?) do
    selection = thread["modelSelection"]
    instance = (selection || %{})["instanceId"] || thread["providerInstanceId"] || "codex"

    run
    |> Map.drop(["runtimeMode", "interactionMode"])
    |> Map.merge(%{
      "modelSelection" => selection,
      "providerInstanceId" => instance,
      "providerThreadId" => Entities.provider_thread_id(instance, thread["id"]),
      "selectionPicked" => false
    })
  end

  defp folded(entity, kind, id, changes) do
    Enum.reduce(changes, entity, fn
      {^kind, ^id, patch}, acc -> Patch.apply(acc, patch)
      {^kind, ^id, patch, _at}, acc -> Patch.apply(acc, patch)
      _, acc -> acc
    end)
  end

  @doc """
  The refusal of a command whose pick was made against a revision the thread has
  moved on from, when the pick is not what the thread now has; nil otherwise, and
  for a command with no `selectionBase`.
  """
  @spec stale(map, map) :: {:error, map} | nil
  def stale(%{"selectionBase" => base} = command, thread) when is_integer(base) do
    if base != revision(thread) and not Enum.all?(picked(command), &(same?(&1, thread))),
      do: {:error, refusal(thread)}
  end

  def stale(_command, _thread), do: nil

  @doc "The choices a command carries, by field: what a client's user picked."
  @spec picked(map) :: [{String.t(), term}]
  def picked(command) do
    for field <- @picks, value = command[field], value != nil, do: {field, value}
  end

  defp same?({"modelSelection", picked}, thread),
    do: same_selection?(picked, thread["modelSelection"])

  defp same?({field, value}, thread), do: thread[field] == value

  @doc "Whether two model selections run the same: instance, model and options."
  @spec same_selection?(map | nil, map | nil) :: boolean
  def same_selection?(a, b), do: normal(a) == normal(b)

  defp normal(nil), do: nil

  defp normal(selection) when is_map(selection) do
    options =
      (selection["options"] || [])
      |> List.wrap()
      |> Enum.sort_by(&(is_map(&1) && &1["id"]))

    {selection["instanceId"] || selection["provider"], selection["model"], options}
  end

  defp normal(other), do: other

  # Names what the thread now runs on, so a client can show it and ask again.
  defp refusal(thread) do
    selection = thread["modelSelection"] || %{}
    instance = selection["instanceId"] || thread["providerInstanceId"] || "codex"
    provider = HalC2.Orchestration.UserFacingErrors.provider_display_name(instance)
    model = selection["model"]
    where = if is_binary(model), do: "#{model} on #{provider}", else: provider

    %{
      "code" => "selection-stale",
      "message" => "This thread moved to #{where} elsewhere. Check it and send again.",
      "selectionRevision" => revision(thread),
      "modelSelection" => thread["modelSelection"],
      "providerInstanceId" => thread["providerInstanceId"] || instance,
      "runtimeMode" => thread["runtimeMode"],
      "interactionMode" => thread["interactionMode"]
    }
  end
end
