defmodule HalC2.Space do
  @moduledoc """
  Spaces: Pages that people and agents write together (`features/space/`).

  The `spaces` stream indexes the Spaces, one `space` entity each, and each Space's
  own `space:<id>` stream holds its `page`, `block` and `comment` entities. Every
  change is a `HalC2.Streams.transact/3` on one of them, so the event log is the
  only record and clients follow both streams through the stream shape. The
  decisions live in `HalC2.Space.Pages` and `HalC2.Space.Blocks`.

  Replies are `{:ok, value}` or `{:error, reason, message}`; an author is
  `%{"type" => "user"}` or `%{"type" => "agent", "threadId" => id}`.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState, Streams}
  alias HalC2.Space.{Blocks, Markdown, Pages}

  @index "spaces"

  @doc "The stream that lists the Spaces."
  def index, do: @index

  @doc "The stream of the Space `id`."
  def stream_id(id), do: "space:" <> id

  @user %{"type" => "user"}

  @doc "The author of an edit the user makes."
  def user, do: @user

  @doc "The author of an edit the agent of `thread_id` makes."
  def agent(thread_id), do: %{"type" => "agent", "threadId" => thread_id}

  # --- Spaces -------------------------------------------------------------------------

  @doc "The Spaces in the order they were made; Personal first, made when there are none."
  def list do
    Streams.transact(@index, :space, fn state ->
      {changes, spaces} = seeded(state)
      {changes, {:ok, spaces}}
    end)
  end

  def create(name) do
    with {:ok, name} <- name(name) do
      space = new_space(name)

      Streams.transact(@index, :space, fn state ->
        {changes, _} = seeded(state)
        {changes ++ [{"space", space["id"], Patch.diff(nil, space)}], {:ok, space}}
      end)
    end
  end

  # The Spaces of the index, with the change that makes Personal when there are none:
  # whoever looks first, by listing or by making a Space, finds Personal there.
  defp seeded(state) do
    case StreamState.list(state, "space") do
      [] ->
        space = new_space("Personal")
        {[{"space", space["id"], Patch.diff(nil, space)}], [space]}

      spaces ->
        {[], spaces}
    end
  end

  def rename(id, name) do
    with {:ok, name} <- name(name) do
      Streams.transact(@index, :space, fn state ->
        case StreamState.get(state, "space")[id] do
          nil ->
            {[], no_space(id)}

          %{"name" => ^name} = space ->
            {[], {:ok, space}}

          space ->
            next = %{space | "name" => name, "updatedAt" => Entities.now()}
            {[{"space", id, Patch.diff(space, next)}], {:ok, next}}
        end
      end)
    end
  end

  @doc "Deletes a Space with no pages, in the trash or out of it."
  def delete(id) do
    # Decided in the Space's stream, so no page can be made in it meanwhile.
    Streams.transact(stream_id(id), :space, fn state ->
      if StreamState.get(state, "page") == %{} do
        reply =
          Streams.transact(@index, :space, fn index ->
            if StreamState.get(index, "space")[id],
              do: {[{"space", id, Patch.delete()}], {:ok, id}},
              else: {[], no_space(id)}
          end)

        {[], reply}
      else
        {[], {:error, :not_empty, "Empty the Space, trash included, before deleting it."}}
      end
    end)
  end

  defp new_space(name) do
    at = Entities.now()
    %{"id" => HalC2.Environment.uuid4(), "name" => name, "createdAt" => at, "updatedAt" => at}
  end

  defp name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :invalid, "A Space needs a name."}
      name -> {:ok, name}
    end
  end

  defp name(_), do: {:error, :invalid, "A Space needs a name."}

  defp no_space(id), do: {:error, :not_found, "There is no Space #{id}."}

  # --- pages, blocks and comments -----------------------------------------------------

  @doc """
  Decides `fun.(state)` in the Space's stream, refusing a Space that does not exist.
  `fun` returns `{changes, reply}`, as `HalC2.Space.Pages` commands do.
  """
  def transact(space_id, fun) when is_binary(space_id) do
    Streams.transact(stream_id(space_id), :space, fn state ->
      # The index is asked from inside the Space's stream: a delete decides there too.
      if Streams.get(@index, "space", space_id), do: fun.(state), else: {[], no_space(space_id)}
    end)
  end

  def transact(_space_id, _fun), do: {:error, :invalid, "spaceId is required."}

  @doc "The Space's stream state, for reads."
  def state(space_id) do
    if Streams.get(@index, "space", space_id),
      do: {:ok, Streams.state(stream_id(space_id))},
      else: no_space(space_id)
  end

  def create_page(space_id, title, parent_id \\ nil),
    do: transact(space_id, &Pages.create(&1, space_id, title, parent_id))

  def rename_page(space_id, id, title), do: transact(space_id, &Pages.rename(&1, id, title))
  def move_page(space_id, id, parent_id), do: transact(space_id, &Pages.move(&1, id, parent_id))
  def trash_page(space_id, id), do: transact(space_id, &Pages.trash(&1, id))
  def restore_page(space_id, id), do: transact(space_id, &Pages.restore(&1, id))
  def delete_page(space_id, id), do: transact(space_id, &Pages.delete(&1, id))

  def insert_block(space_id, page_id, spec, after_id \\ :last, author \\ @user),
    do: transact(space_id, &Blocks.insert(&1, page_id, spec, after_id, author))

  def update_block(space_id, id, text, author \\ @user),
    do: transact(space_id, &Blocks.update_text(&1, id, text, author))

  def set_checked(space_id, id, checked, author \\ @user),
    do: transact(space_id, &Blocks.set_checked(&1, id, checked, author))

  def move_block(space_id, id, after_id, author \\ @user),
    do: transact(space_id, &Blocks.move(&1, id, after_id, author))

  def delete_block(space_id, id), do: transact(space_id, &Blocks.delete(&1, id))

  def add_comment(space_id, page_id, block_id, body, author \\ @user),
    do: transact(space_id, &Blocks.comment(&1, page_id, block_id, body, author))

  def resolve_comment(space_id, id), do: transact(space_id, &Blocks.resolve(&1, id))
  def reopen_comment(space_id, id), do: transact(space_id, &Blocks.reopen(&1, id))

  @doc "A page with its blocks and comments, trashed or not."
  def page(space_id, page_id) do
    with {:ok, state} <- state(space_id) do
      case Pages.get(state, page_id) do
        nil ->
          {:error, :not_found, "There is no page #{page_id} in this Space."}

        page ->
          {:ok,
           %{
             page: page,
             blocks: Blocks.of_page(state, page_id),
             comments: Blocks.comments(state, page_id)
           }}
      end
    end
  end

  # --- Markdown and threads -----------------------------------------------------------

  def export_markdown(space_id, page_id) do
    with {:ok, state} <- state(space_id),
         %{} = page <-
           Pages.get(state, page_id) ||
             {:error, :not_found, "There is no page #{page_id} in this Space."} do
      title_of = &(Pages.get(state, &1) || %{})["title"]
      {:ok, Markdown.export(page, Blocks.of_page(state, page_id), title_of)}
    end
  end

  @doc "A new page from Markdown: its `# ` title unless `title` is given, else \"Untitled\"."
  def import_markdown(
        space_id,
        markdown,
        title \\ nil,
        parent_id \\ nil,
        extra \\ %{},
        author \\ @user
      )

  def import_markdown(space_id, markdown, title, parent_id, extra, author)
      when is_binary(markdown) do
    {heading, specs} = Markdown.parse(markdown)
    title = title || heading || "Untitled"

    transact(space_id, fn state ->
      with {page_changes, {:ok, page}} <- Pages.create(state, space_id, title, parent_id, extra),
           # The new page is not in `state` yet: its blocks are decided on a state that has it.
           state = with_changes(state, page_changes),
           {block_changes, {:ok, _}} <-
             Blocks.insert_all(
               state,
               page["id"],
               Enum.map(specs, &links(state, &1)),
               :last,
               author
             ) do
        {page_changes ++ block_changes, {:ok, page}}
      end
    end)
  end

  def import_markdown(_, _, _, _, _, _), do: {:error, :invalid, "markdown is a string."}

  # `state` as if `changes` were committed, to decide what follows them in one step.
  defp with_changes(state, changes) do
    Enum.reduce(changes, state, fn {kind, id, patch}, state ->
      StreamState.apply_event(state, %{seq: state.seq, kind: kind, entity: id, patch: patch})
    end)
  end

  # A link to a page this Space does not have is kept as a paragraph.
  defp links(state, %{"kind" => "subpage_link"} = spec) do
    if Pages.get(state, spec["linkedPageId"]),
      do: spec,
      else: %{
        spec
        | "kind" => "paragraph",
          "text" => "[#{spec["text"]}](##{spec["linkedPageId"]})",
          "linkedPageId" => nil
      }
  end

  defp links(_state, spec), do: spec

  @doc """
  A new page summarising a thread of this MC, written by text generation in the
  thread's checkout. With no provider to write it, or one that fails, there is no page.
  """
  def create_page_from_thread(space_id, thread_id, parent_id \\ nil) do
    with {:ok, _} <- state(space_id),
         {:ok, cwd, context} <- thread_context(thread_id) do
      case HalC2.TextGeneration.page_from_thread(cwd, context) do
        {:ok, %{"title" => title, "markdown" => markdown}} ->
          extra = %{"sourceThreadId" => thread_id}
          import_markdown(space_id, markdown, nonblank(title), parent_id, extra, agent(thread_id))

        {:error, {:unavailable, message}} ->
          {:error, :generation_unavailable, message}

        {:error, message} ->
          {:error, :generation_failed, message}
      end
    end
  end

  defp nonblank(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp thread_context(thread_id) when is_binary(thread_id) do
    with {"thread", row} <- HalC2.Shell.row(node(), thread_id),
         root when is_binary(root) <- row["worktreePath"] || project_root(row["projectId"]) do
      messages =
        thread_id
        |> Streams.state()
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] in ["user", "assistant"] and &1["streaming"] != true))

      case HalC2.TextGeneration.Prompts.thread_context(messages) do
        {"", _} -> {:error, :invalid, "The thread has nothing to summarise yet."}
        {text, _attachments} -> {:ok, root, text}
      end
    else
      _ ->
        {:error, :not_found, "There is no thread #{thread_id} with a project folder on this MC."}
    end
  end

  defp thread_context(_), do: {:error, :invalid, "threadId is required."}

  defp project_root(nil), do: nil

  defp project_root(project_id) do
    case HalC2.Shell.row(node(), project_id) do
      {"project", row} -> row["workspaceRoot"]
      _ -> nil
    end
  end
end
