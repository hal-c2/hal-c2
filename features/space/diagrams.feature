# Sources:
#   https://mermaid.js.org/intro/syntax-reference.html
#   https://github.com/1jehuang/mermaid-rs-renderer (mmdr: draws the pictures)
#   https://github.com/kevinswiber/mmdflux (mmdflux: checks flowcharts, draws terminal text)
#   packages/contracts/src/rpc.ts (mermaid.render), packages/contracts/src/mermaid.ts
#   apps/server-ex/lib/hal_c2/mermaid.ex, native/mermaid/src/main.rs
#   docs/internals/mermaid.md (why the MC draws them)

Feature: Mermaid diagrams drawn by the MC
  The MC draws every Mermaid diagram a client shows, in a page, a reply or a file, so
  each surface shows the same picture and none of them carries a renderer of its own.
  A client sends the diagram's source and gets back a picture, text for the terminal,
  or what kept it from being drawn. Where the clients show them is in
  space/markdown.feature, timeline/markdown.feature and
  files/file-viewer-and-editing.feature.

  Background:
    Given a connected environment

  @mc
  Scenario Outline: A <type> diagram is drawn
    When a client asks the MC to draw a "<type>" diagram
    Then the MC answers with a picture of the "<type>" diagram and its size

    Examples:
      | type            |
      | flowchart       |
      | graph           |
      | sequenceDiagram |
      | stateDiagram-v2 |
      | gantt           |
      | classDiagram    |
      | erDiagram       |
      | pie             |

  @mc
  Scenario: A diagram is drawn for a dark theme
    When a client in a dark theme asks the MC to draw a "flowchart" diagram
    Then the MC answers with a picture of the "flowchart" diagram and its size
    And the picture is not the one drawn for a light theme

  @mc
  Scenario: The terminal gets the diagram as text
    When the terminal asks the MC to draw a "flowchart" diagram
    Then the MC answers with the "flowchart" diagram drawn in characters

  @mc
  Scenario: A type with no text drawing says so to the terminal
    When the terminal asks the MC to draw a "gantt" diagram
    Then the MC answers that the diagram is not drawn because "gantt diagrams have no text drawing yet."

  @mc
  Scenario: A type the renderer cannot draw says why
    When a client asks the MC to draw a "block-beta" diagram
    Then the MC answers that the diagram is not drawn because "block-beta diagrams cannot be drawn yet."

  @mc
  Scenario: A mistake in the source says where it is
    When a client asks the MC to draw a flowchart with an unclosed bracket
    Then the MC answers that the diagram has a mistake on line 2

  @mc
  Scenario: Text that is no diagram says so
    When a client asks the MC to draw "just some words"
    Then the MC answers that the diagram has a mistake

  @mc
  Scenario: A diagram is drawn once, however often it is shown
    Given a client asked the MC to draw a "flowchart" diagram
    When another client asks the MC to draw the same diagram
    Then the MC answers with the same picture
    And the diagram was drawn once
