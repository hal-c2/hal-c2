defmodule HalC2.Steps.Space.Diagrams do
  @moduledoc """
  Steps for `features/space/diagrams.feature`. Diagrams are drawn over the socket with
  `mermaid.render` by the real helper (native/mermaid); a scenario counts its drawings by
  wrapping `HalC2.Mermaid.draw/1`. The last answer is `context.diagram`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # Synthetic diagrams of the shapes the reference corpus holds.
  @diagrams %{
    "flowchart" =>
      "flowchart TD\n  A[Start] --> B{Ready?}\n  B -->|yes| C[Ship]\n  B -->|no| A\n",
    "graph" => "graph LR\n  A[Client] --> B[MC]\n  B --> C[(Store)]\n",
    "sequenceDiagram" =>
      "sequenceDiagram\n  User->>MC: send turn\n  MC->>Provider: start\n  Provider-->>MC: delta\n  MC-->>User: patch\n",
    "stateDiagram-v2" =>
      "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running: start\n  Running --> Idle: done\n  Running --> [*]\n",
    "gantt" =>
      "gantt\n  title Release\n  dateFormat YYYY-MM-DD\n  section Build\n  Renderer :a1, 2026-01-01, 5d\n  Clients :after a1, 7d\n",
    "classDiagram" => "classDiagram\n  Animal <|-- Dog\n  Animal : +String name\n",
    "erDiagram" => "erDiagram\n  CUSTOMER ||--o{ ORDER : places\n",
    "pie" => "pie title Pets\n  \"Dogs\" : 9\n  \"Cats\" : 2\n",
    "block-beta" => "block-beta\n  columns 2\n  A B\n"
  }
  @unclosed "flowchart TD\n  A[Start --> B\n"

  step "a client asks the MC to draw a {string} diagram", %{args: [type]} = context do
    draw(context, %{"source" => diagram(type)})
  end

  step "a client asked the MC to draw a {string} diagram", %{args: [type]} = context do
    draw(context, %{"source" => diagram(type)})
  end

  step "a client in a dark theme asks the MC to draw a {string} diagram",
       %{args: [type]} = context do
    draw(context, %{"source" => diagram(type), "theme" => "dark"})
  end

  step "the terminal asks the MC to draw a {string} diagram", %{args: [type]} = context do
    draw(context, %{"source" => diagram(type), "format" => "text"})
  end

  step "a client asks the MC to draw a flowchart with an unclosed bracket", context do
    draw(context, %{"source" => @unclosed})
  end

  step "a client asks the MC to draw {string}", %{args: [source]} = context do
    draw(context, %{"source" => source})
  end

  step "another client asks the MC to draw the same diagram", context do
    context
    |> Map.put(:first_diagram, context.diagram)
    |> draw(context.diagram_request, "another")
  end

  step "the MC answers with a picture of the {string} diagram and its size",
       %{args: [type]} = context do
    assert %{"status" => "drawn", "kind" => ^type, "svg" => svg} = context.diagram
    assert svg =~ "<svg"
    assert context.diagram["width"] > 0 and context.diagram["height"] > 0
    context
  end

  step "the picture is not the one drawn for a light theme", context do
    {light, context} = render(context, %{context.diagram_request | "theme" => "light"})
    assert light["status"] == "drawn"
    refute light["svg"] == context.diagram["svg"]
    context
  end

  step "the MC answers with the {string} diagram drawn in characters",
       %{args: [type]} = context do
    assert %{"status" => "drawn", "kind" => ^type, "text" => text} = context.diagram
    # The flowchart's nodes, boxed in characters.
    for label <- ~w(Start Ready? Ship), do: assert(text =~ label)
    refute Map.has_key?(context.diagram, "svg")
    context
  end

  step "the MC answers that the diagram is not drawn because {string}",
       %{args: [reason]} = context do
    assert %{"status" => "unsupported", "reason" => ^reason} = context.diagram
    context
  end

  step "the MC answers that the diagram has a mistake on line {int}",
       %{args: [line]} = context do
    assert %{"status" => "invalid", "line" => ^line, "reason" => reason} = context.diagram
    assert reason != ""
    context
  end

  step "the MC answers that the diagram has a mistake", context do
    assert %{"status" => "invalid", "reason" => reason} = context.diagram
    assert reason != ""
    context
  end

  step "the MC answers with the same picture", context do
    assert context.diagram["status"] == "drawn"
    assert context.diagram == context.first_diagram
    context
  end

  step "the diagram was drawn once", context do
    assert :counters.get(context.drawings, 1) == 1
    context
  end

  # --- helpers ---------------------------------------------------------------------

  defp diagram(type), do: Map.fetch!(@diagrams, type)

  defp draw(context, request, client \\ "default") do
    {result, context} = render(context, request, client)
    Map.merge(context, %{diagram: result, diagram_request: request})
  end

  defp render(context, request, client \\ "default") do
    context = start_renderer(context)
    {result, context} = World.call!(context, "mermaid.render", request, client)
    {result, context}
  end

  # The real renderer, counted. The helper must be built (`vp run build:mermaid`).
  defp start_renderer(%{drawings: _} = context), do: context

  defp start_renderer(context) do
    assert HalC2.Mermaid.helper(), "build the Mermaid helper first: vp run build:mermaid"
    drawings = :counters.new(1, [])

    draw = fn request ->
      :counters.add(drawings, 1, 1)
      HalC2.Mermaid.draw(request)
    end

    Mc.ensure({HalC2.Mermaid, draw: draw})
    Map.put(context, :drawings, drawings)
  end
end
