defmodule HalC2.Steps.Space.PageHistory do
  @moduledoc """
  Steps for `features/space/page-history.feature`. "A while passes" moves the Space's
  events back in the log, past the gap that ends a version, so nothing sleeps. The list
  last fetched is `context.versions`; "the version N back" counts from the newest.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Exqlite.Sqlite3
  alias HalC2.{Space, Store, Streams}
  alias HalC2.Space.Images
  alias HalC2.Test.Mc.World

  step "a while passes", context do
    {:ok, db} = Sqlite3.open(Store.path())

    :ok =
      Sqlite3.execute(db, """
      UPDATE events SET at = at - 600000
      WHERE stream = (SELECT key FROM streams WHERE id = '#{Space.stream_id(context.space)}')
      """)

    :ok = Sqlite3.close(db)
    context
  end

  step "the user opens the history of {string}", %{args: [title]} = context do
    open(context, page_id(context, title))
  end

  step "the user keeps the id of {string}", %{args: [title]} = context do
    Map.put(context, :kept_page, page_id(context, title))
  end

  step "the user opens the history of the kept page", context do
    {reply, context} =
      World.call(context, "space.page.history", %{
        "spaceId" => context.space,
        "pageId" => context.kept_page
      })

    Map.put(context, :space_reply, reply)
  end

  step "the history has {int} version(s)", %{args: [count]} = context do
    context = reopen(context)
    assert length(context.versions) == count
    context
  end

  step "each version says when it was written and by the user", context do
    for version <- context.versions do
      assert {:ok, _, _} = DateTime.from_iso8601(version["at"])
      assert version["author"] == %{"type" => "user"}
    end

    context
  end

  step "the newest version is the page as it is now", context do
    assert version_texts(context, hd(context.versions)["version"]) == "Final"
    context
  end

  step "the newest version was written by the thread {string}", %{args: [thread]} = context do
    assert_written_by(context, hd(context.versions), thread)
  end

  step "the newest version was written by the user", context do
    assert hd(context.versions)["author"] == %{"type" => "user"}
    context
  end

  step "the newest version was written by the page's update", context do
    assert hd(context.versions)["author"] == %{"type" => "schedule"}
    context
  end

  step "the version {int} back was written by the thread {string}",
       %{args: [back, thread]} = context do
    assert_written_by(context, Enum.at(context.versions, back), thread)
  end

  step "the user reads the version {int} back on {string}", %{args: [back, title]} = context do
    context = open(context, page_id(context, title))
    version = Enum.at(context.versions, back)["version"]
    {read, context} = World.call!(context, "space.page.version", version_ref(context, version))
    Map.put(context, :reading, read)
  end

  step "the version reads {string}", %{args: [text]} = context do
    assert texts_of(context.reading) == text
    context
  end

  step "the version draws a chart of {string} {int} and {string} {int}",
       %{args: [first, a, next, b]} = context do
    chart = Enum.find(context.reading["blocks"], &(&1["kind"] == "chart"))["chart"]
    assert numbers(chart) == [{first, a}, {next, b}]
    context
  end

  step "the chart on {string} is drawn again with {string} {int} and {string} {int}",
       %{args: [title, first, a, next, b]} = context do
    block = chart_block(context)
    series = [%{hd(block["chart"]["series"]) | "values" => [a, b]}]
    chart = %{block["chart"] | "labels" => [first, next], "series" => series}
    id = page_id(context, title)
    assert {:ok, _} = Space.put_chart(context.space, id, chart, block["id"])
    context
  end

  step "the chart holds {string} {int} and {string} {int}",
       %{args: [first, a, next, b]} = context do
    assert numbers(chart_block(context)["chart"]) == [{first, a}, {next, b}]
    context
  end

  step "the version shows the image {string}", %{args: [name]} = context do
    assert image_in_version(context, name)["imageId"] == Map.fetch!(context.image_ids, name)
    context
  end

  # The version holds the block; what the block says of the image is the image's own.
  step "the version says the image {string} is in the trash", %{args: [name]} = context do
    id = Map.fetch!(context.image_ids, name)
    assert image_in_version(context, name)["imageId"] == id
    assert Images.get(Streams.state(Space.stream_id(context.space)), id)["trashedAt"] != nil
    context
  end

  step "the version {int} back reads {string}", %{args: [back, text]} = context do
    version = Enum.at(context.versions, back)["version"]
    assert version_texts(context, version) == text
    context
  end

  step "the user goes back to the list of versions", context do
    Map.put(context, :reading, nil)
  end

  step "no version is being read", context do
    assert context.reading == nil
    context
  end

  step "the user restores the version {int} back on {string}", %{args: [back, title]} = context do
    context = open(context, page_id(context, title))
    version = Enum.at(context.versions, back)["version"]

    {_, context} =
      World.call!(context, "space.page.restoreVersion", version_ref(context, version))

    context
  end

  step "the newest version says it restored an earlier one", context do
    [newest | older] = context.versions
    assert newest["restoredFromAt"] == List.last(older)["at"]
    context
  end

  step "the user cannot restore a version of {string}", %{args: [title]} = context do
    version = hd(context.versions)["version"]
    ref = version_ref(context, version) |> Map.put("pageId", page_id(context, title))
    {reply, context} = World.call(context, "space.page.restoreVersion", ref)
    assert {:error, _, %{"reason" => "trashed"}} = reply
    context
  end

  step "the user asks for {int} versions of {string}", %{args: [limit, title]} = context do
    id = page_id(context, title)
    context = Map.put(context, :history_page, id)

    {reply, context} =
      World.call!(context, "space.page.history", %{
        "spaceId" => context.space,
        "pageId" => id,
        "limit" => limit
      })

    Map.put(context, :stretch, reply)
  end

  step "the user asks for the versions after those", context do
    {reply, context} =
      World.call!(context, "space.page.history", %{
        "spaceId" => context.space,
        "pageId" => context.history_page,
        "before" => context.stretch["nextBefore"]
      })

    Map.put(context, :stretch, reply)
  end

  step "{int} version(s) come(s), and there are more", %{args: [count]} = context do
    assert length(context.stretch["versions"]) == count
    assert is_integer(context.stretch["nextBefore"])
    context
  end

  step "{int} version(s) come(s), and there are no more", %{args: [count]} = context do
    assert length(context.stretch["versions"]) == count
    assert context.stretch["nextBefore"] == nil
    context
  end

  step "the block {string} has no comments", %{args: [text]} = context do
    {:ok, state} = Space.state(context.space)
    block = block_named(state, text)
    assert for(%{"blockId" => id} = c <- comments(state), id == block["id"], do: c) == []
    context
  end

  step "the page {string} still has the comment {string}", %{args: [title, body]} = context do
    {:ok, state} = Space.state(context.space)
    page = page_id(context, title)
    assert Enum.any?(comments(state), &(&1["pageId"] == page and &1["body"] == body))
    context
  end

  defp open(context, id) do
    {reply, context} =
      World.call!(context, "space.page.history", %{"spaceId" => context.space, "pageId" => id})

    Map.merge(context, %{history_page: id, versions: reply["versions"]})
  end

  # The steps after an edit see what the edit made.
  defp reopen(%{history_page: id} = context), do: open(context, id)

  defp reopen(context), do: context

  defp version_ref(context, version) do
    %{"spaceId" => context.space, "pageId" => context.history_page, "version" => version}
  end

  defp version_texts(context, version) do
    {read, _} = World.call!(context, "space.page.version", version_ref(context, version))
    texts_of(read)
  end

  defp image_in_version(context, name),
    do: Enum.find(context.reading["blocks"], &(&1["kind"] == "image" and &1["text"] == name))

  defp chart_block(context) do
    {:ok, state} = Space.state(context.space)
    Enum.find(HalC2.StreamState.list(state, "block"), &(&1["kind"] == "chart"))
  end

  defp numbers(%{"labels" => labels, "series" => [%{"values" => values}]}),
    do: Enum.zip(labels, values)

  defp texts_of(read), do: Enum.map_join(read["blocks"], ", ", & &1["text"])

  defp assert_written_by(context, version, thread) do
    assert version["author"]["threadId"] == World.thread_id(context, thread)
    assert version["threadTitle"] == thread
    context
  end

  defp comments(state), do: state |> HalC2.StreamState.list("comment")

  defp block_named(state, text) do
    Enum.find(HalC2.StreamState.list(state, "block"), &(&1["text"] == text))
  end

  defp page_id(context, title) do
    {:ok, state} = Space.state(context.space)
    Enum.find(HalC2.StreamState.list(state, "page"), &(&1["title"] == title))["id"]
  end
end
