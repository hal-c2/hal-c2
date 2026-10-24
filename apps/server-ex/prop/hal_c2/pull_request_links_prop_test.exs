defmodule HalC2.PullRequestLinksPropTest do
  @moduledoc """
  A state machine over one thread's pull request links
  (`features/mc/orchestration/pull-request-links.feature`): links made by the user, an
  agent and a pull request the thread created (`thread.pull-request.link`), unlinks, the
  links the MC makes when it finds a pull request the thread opened
  (`HalC2.PullRequests.Opened.link/2`, from the turn writer and discovery), and a
  restart of the streams.

  The model keeps each pull request as shown with the source it was linked by, as a
  tombstone, or absent. A link of one already there changes nothing; unlinking one
  the thread created leaves a tombstone, which only the user or an agent bring back;
  the MC never links one the thread carries, tombstones included. After every command
  the test compares the thread's links with the model and checks that a command the
  model says changes nothing appended no event.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration
  alias HalC2.Projection.PullRequests, as: Links
  alias HalC2.StreamState

  @moduletag timeout: :infinity

  @thread "t1"
  @numbers [1, 2, 3]
  @sources ~w(manual agent created)

  property "a thread's pull request links follow the model, tombstones included",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("pull-request-links")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams
        ])

        {:ok, _} =
          Orchestration.dispatch(%{
            "type" => "thread.create",
            "threadId" => @thread,
            "projectId" => "project-1",
            "title" => "Links",
            "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
            "branch" => "feature/x"
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

  # number -> {:shown, source} | :tombstone; absent numbers are not linked.
  def initial_state, do: %{}

  def command(_links) do
    n = oneof(@numbers)

    frequency([
      {4, {:call, __MODULE__, :link, [n, oneof(@sources)]}},
      {3, {:call, __MODULE__, :unlink, [n]}},
      {4, {:call, __MODULE__, :found, [n]}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  def precondition(_links, _call), do: true

  def next_state(links, _result, {:call, _, :link, [n, source]}) do
    case links[n] do
      nil -> Map.put(links, n, {:shown, source})
      :tombstone -> Map.put(links, n, {:shown, source})
      {:shown, _} -> links
    end
  end

  def next_state(links, _result, {:call, _, :unlink, [n]}) do
    case links[n] do
      {:shown, "created"} -> Map.put(links, n, :tombstone)
      {:shown, _} -> Map.delete(links, n)
      _ -> links
    end
  end

  def next_state(links, _result, {:call, _, :found, [n]}),
    do: Map.put_new(links, n, {:shown, "created"})

  def next_state(links, _result, {:call, _, :restart, []}), do: links

  def postcondition(before, call, {reply, seq_before, seq_after, actual}) do
    expected = next_state(before, nil, call)
    unchanged? = expected == before and not match?({:call, _, :restart, _}, call)

    match?({:ok, _}, reply) and actual == expected and
      (not unchanged? or seq_after == seq_before)
  end

  # --- the real side ----------------------------------------------------------------

  def link(n, source) do
    observe(fn ->
      Orchestration.dispatch(
        Map.merge(key(n), %{
          "type" => "thread.pull-request.link",
          "url" => url(n),
          "source" => source
        })
      )
    end)
  end

  def unlink(n),
    do:
      observe(fn ->
        Orchestration.dispatch(Map.put(key(n), "type", "thread.pull-request.unlink"))
      end)

  def found(n), do: observe(fn -> {HalC2.PullRequests.Opened.link(@thread, [url(n)]), :ok} end)

  def restart do
    observe(fn ->
      HalC2.Prop.restart_service(HalC2.Streams)
      {:ok, %{}}
    end)
  end

  # `{reply, seq before, seq after, links as the model keeps them}`.
  defp observe(fun) do
    before = seq()
    reply = fun.()
    {reply, before, seq(), links()}
  end

  defp seq, do: HalC2.Streams.state(@thread).seq

  defp links do
    thread = StreamState.get(HalC2.Streams.state(@thread), "thread")[@thread]

    Map.new(Links.of(thread), fn link ->
      {link["number"],
       if(link["source"] == "stack-dismissed", do: :tombstone, else: {:shown, link["source"]})}
    end)
  end

  defp key(n),
    do: %{
      "threadId" => @thread,
      "host" => "github.com",
      "repository" => "acme/app",
      "number" => n
    }

  defp url(n), do: "https://github.com/acme/app/pull/#{n}"
end
