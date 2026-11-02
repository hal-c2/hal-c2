defmodule HalC2.MermaidTest do
  use ExUnit.Case, async: true

  alias HalC2.Mermaid

  @drawn %{"status" => "drawn", "kind" => "flowchart", "svg" => "<svg/>"}

  defp request(source, format \\ "svg"), do: %{source: source, format: format, theme: "light"}

  defp server(opts) do
    start_supervised!(Supervisor.child_spec({Mermaid, [name: nil] ++ opts}, id: make_ref()))
  end

  # A drawing that tells the test it started and waits for the outcome it is sent.
  defp gated do
    test = self()

    fn request ->
      send(test, {:drawing, request.source, self()})

      receive do
        {:outcome, outcome} -> outcome
      end
    end
  end

  defp render_async(server, source),
    do: Task.async(fn -> Mermaid.render(server, request(source)) end)

  defp counted(outcome) do
    counter = :counters.new(1, [])

    {counter,
     fn _request ->
       :counters.add(counter, 1, 1)
       outcome
     end}
  end

  test "a diagram is drawn once and kept for the next caller" do
    {count, draw} = counted({:ok, @drawn})
    server = server(draw: draw)

    assert Mermaid.render(server, request("flowchart TD\n A --> B")) == @drawn
    assert Mermaid.render(server, request("flowchart TD\n A --> B")) == @drawn
    assert :counters.get(count, 1) == 1

    # Another format is another drawing.
    Mermaid.render(server, request("flowchart TD\n A --> B", "text"))
    assert :counters.get(count, 1) == 2
  end

  test "callers asking for a diagram being drawn wait for that drawing" do
    server = server(draw: gated())
    callers = for _ <- 1..3, do: render_async(server, "graph LR\n A --> B")

    assert_receive {:drawing, _, drawer}
    send(drawer, {:outcome, {:ok, @drawn}})

    assert Enum.map(callers, &Task.await/1) == [@drawn, @drawn, @drawn]
    refute_received {:drawing, _, _}
  end

  test "no more than the limit are drawn at once, and the rest follow in order" do
    server = server(draw: gated(), limit: 2)
    callers = for source <- ~w(a b c), do: render_async(server, source)

    assert_receive {:drawing, "a", a}
    assert_receive {:drawing, "b", _b}
    refute_received {:drawing, "c", _}

    send(a, {:outcome, {:ok, @drawn}})
    assert_receive {:drawing, "c", c}
    send(c, {:outcome, {:ok, @drawn}})
    assert Task.await(Enum.at(callers, 0)) == @drawn
    assert Task.await(Enum.at(callers, 2)) == @drawn
  end

  test "a drawing that failed is not kept, so the next caller tries again" do
    failed = %{"status" => "failed", "kind" => nil, "reason" => "The diagram renderer failed."}
    {count, draw} = counted({:error, failed})
    server = server(draw: draw)

    assert Mermaid.render(server, request("pie\n \"a\" : 1")) == failed
    assert Mermaid.render(server, request("pie\n \"a\" : 1")) == failed
    assert :counters.get(count, 1) == 2
  end

  @tag :capture_log
  test "a drawing that crashes fails that diagram and not the server" do
    server = server(draw: fn _ -> raise "boom" end)

    assert %{"status" => "failed", "reason" => "The diagram renderer failed."} =
             Mermaid.render(server, request("graph LR\n A --> B"))

    assert Process.alive?(server)
  end

  test "a drawing that takes too long is stopped and the next one starts" do
    server = server(draw: gated(), limit: 1, timeout: 20)
    slow = render_async(server, "slow")
    next = render_async(server, "next")

    assert_receive {:drawing, "slow", drawer}
    ref = Process.monitor(drawer)

    assert %{"status" => "failed", "reason" => "This diagram took too long to draw."} =
             Task.await(slow)

    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert_receive {:drawing, "next", next_drawer}
    send(next_drawer, {:outcome, {:ok, @drawn}})
    assert Task.await(next) == @drawn
  end

  test "a diagram waiting too long for its turn is dropped and its callers told why" do
    server = server(draw: gated(), limit: 1, wait: 20)
    first = render_async(server, "first")
    assert_receive {:drawing, "first", drawer}
    waiting = render_async(server, "waiting")

    assert %{
             "status" => "failed",
             "reason" => "The MC is busy drawing other diagrams; try again."
           } =
             Task.await(waiting)

    # The one being drawn is not cut short, and the dropped one is never drawn.
    send(drawer, {:outcome, {:ok, @drawn}})
    assert Task.await(first) == @drawn
    :sys.get_state(server)
    refute_received {:drawing, "waiting", _}
  end

  test "a diagram whose callers have gone before its turn is never drawn" do
    server = server(draw: gated(), limit: 1)
    first = render_async(server, "first")
    assert_receive {:drawing, "first", drawer}

    test = self()

    gone =
      spawn(fn ->
        :gen_server.send_request(server, {:render, request("gone")})
        send(test, :asked)
        Process.sleep(:infinity)
      end)

    assert_receive :asked
    kept = render_async(server, "kept")
    assert "gone" in queued(server)
    monitor = Process.monitor(gone)
    Process.exit(gone, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    refute "gone" in dropped(server, "gone", 100)

    send(drawer, {:outcome, {:ok, @drawn}})
    assert Task.await(first) == @drawn
    assert_receive {:drawing, "kept", drawer}
    send(drawer, {:outcome, {:ok, @drawn}})
    assert Task.await(kept) == @drawn
    refute_received {:drawing, "gone", _}
  end

  test "a caller whose socket goes is let go, and its diagram is not drawn" do
    server = server(draw: gated(), limit: 1)
    first = render_async(server, "first")
    assert_receive {:drawing, "first", drawer}

    socket = spawn(fn -> Process.sleep(:infinity) end)
    caller = Task.async(fn -> Mermaid.render(server, request("closed"), socket) end)
    Process.exit(socket, :kill)

    assert %{"status" => "failed", "reason" => "The client asking for this diagram has gone."} =
             Task.await(caller)

    assert queued(server) == []
    send(drawer, {:outcome, {:ok, @drawn}})
    assert Task.await(first) == @drawn
    :sys.get_state(server)
    refute_received {:drawing, "closed", _}
  end

  defp queued(server),
    do:
      for({_, %{source: source}, _} <- :queue.to_list(:sys.get_state(server).queued), do: source)

  # The test's word that a caller went and the server's are two signals in no promised
  # order; each look is one more turn for the server to read its own.
  defp dropped(server, source, tries) do
    queued = queued(server)
    if source in queued and tries > 0, do: dropped(server, source, tries - 1), else: queued
  end

  test "the oldest drawing is forgotten past the cache's size" do
    {count, draw} = counted({:ok, @drawn})
    server = server(draw: draw, cache_size: 1)

    for source <- ~w(a b a), do: Mermaid.render(server, request(source))
    assert :counters.get(count, 1) == 3
  end

  test "a source too long to draw is a mistake, not a drawing" do
    long = "flowchart TD\n" <> String.duplicate("  A --> B\n", 7_000)

    assert %{"status" => "invalid", "reason" => "This diagram is too long to draw."} =
             Mermaid.render(:not_called, request(long))
  end

  test "a request takes svg and light unless it says otherwise" do
    assert Mermaid.request(%{"source" => "pie"}) ==
             {:ok, %{source: "pie", format: "svg", theme: "light"}}

    assert {:ok, %{format: "text", theme: "dark"}} =
             Mermaid.request(%{"source" => "pie", "format" => "text", "theme" => "dark"})

    assert {:error, _} = Mermaid.request(%{"source" => "pie", "format" => "png"})
    assert {:error, _} = Mermaid.request(%{"source" => "pie", "theme" => "blue"})
    assert {:error, _} = Mermaid.request(%{})
  end

  describe "the helper" do
    @describetag skip: is_nil(Mermaid.helper()) && "the helper is not built: vp run build:mermaid"

    test "draws a flowchart as a picture with its size" do
      assert {:ok, %{"status" => "drawn", "kind" => "flowchart", "svg" => svg} = result} =
               Mermaid.draw(request("flowchart TD\n  A[Start] --> B[Done]\n"))

      assert svg =~ "<svg" and svg =~ "Start"
      assert result["width"] > 0 and result["height"] > 0
    end

    test "says where a mistake is" do
      assert {:ok, %{"status" => "invalid", "kind" => "flowchart", "line" => 2}} =
               Mermaid.draw(request("flowchart TD\n  A[Start --> B\n"))
    end
  end
end
