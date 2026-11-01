# Sources:
#   features/space/beyond-pages.feature (the entry these scenarios replace)
#   spaces-feature-bdd-tests branch, apps/desktop-qt/qml/HalC2/Bricks/VisualizationCard.qml
#     (a hard-coded demo; read for its looks only)
#   packages/contracts/src/space.ts (SpaceChart, space.block.visualize)
#   apps/server-ex/lib/hal_c2/space/chart.ex, apps/server-ex/lib/hal_c2/space/visualize.ex

Feature: Charts on a page
  A user asks for a chart on a page and our own built-in chart draws it. The model only
  describes a chart: its type, labels, series and values, as data. No generated code runs
  on any client. The numbers are real or there is no chart: they are counted by the MC, or
  every one of them is on the page. A chart says where its numbers came from, and reading
  it needs no provider because it is stored on the page like any other block.

  Background:
    Given a connected environment
    And the Space "Research" with the page "Status"

  @mc @desktop @mobile @tui
  Rule: Asking for a chart

    Scenario: The user visualises data on a page
      Given this MC's threads took turns this week
      And text generation charts the request from the MC's threads
      When the user asks for "/visualize weekly turns" on the page "Status"
      Then the page shows a bar chart titled "Weekly turns"
      And the chart says its numbers came from this MC's threads

    Scenario: A client watching the Space sees the chart land
      Given a second client watching the Space "Research"
      And this MC's threads took turns this week
      And text generation charts the request from the MC's threads
      When the user asks for "/visualize weekly turns" on the page "Status"
      Then the second client sees a chart titled "Weekly turns"

    Scenario: A chart is a line when that is what was asked for
      Given "Status" has the blocks "Signups were 3 in May, 5 in June"
      And text generation answers with a line chart of "May" 3 and "June" 5
      When the user asks for "/visualize signups over time" on the page "Status"
      Then the page shows a line chart titled "Signups"
      And the chart says its numbers came from this page

    Scenario: The user sees the numbers behind a chart
      Given the page "Status" has a chart of "May" 3 and "June" 5
      When the user asks to see the numbers behind the chart
      Then the numbers read "May" 3 and "June" 5

    Scenario: Reading a chart needs no provider
      Given the page "Status" has a chart of "May" 3 and "June" 5
      And no text generation provider is available
      When the user asks to see the numbers behind the chart
      Then the numbers read "May" 3 and "June" 5

  @mc @desktop @mobile @tui
  Rule: Asking again, deleting and restoring

    Background:
      Given the page "Status" has the blocks "Before" and a chart of "May" 3 and "June" 5 and the blocks "After"

    Scenario: Asking again replaces the chart where it is
      Given "Status" also says "July was 8"
      And text generation answers with a bar chart of "July" 8
      When the user asks again for "/visualize july"
      Then the numbers read "July" 8
      And the page shows one chart, between "Before" and "After"

    Scenario: A failed second ask keeps the chart
      Given text generation fails
      When the user asks again for "/visualize july"
      Then the user is told no chart was drawn
      And the numbers read "May" 3 and "June" 5

    Scenario: The user deletes a chart
      When the user deletes the chart
      Then the page shows no chart

    Scenario: A chart comes back with its page from the trash
      When the user moves the page "Status" to the trash
      And the user restores the page "Status"
      Then the numbers read "May" 3 and "June" 5

  @mc @desktop @mobile @tui
  Rule: No numbers, no chart

    Scenario: A request the MC's data cannot answer draws nothing
      Given text generation says the request cannot be answered
      When the user asks for "/visualize revenue" on the page "Status"
      Then the user is told no chart was drawn
      And the page shows no chart

    Scenario: Without a provider nothing is drawn
      Given no text generation provider is available
      When the user asks for "/visualize weekly turns" on the page "Status"
      Then the user is told no chart was drawn
      And the page shows no chart

  @mc
  Rule: The numbers are honest

    Scenario: A number the page does not state draws nothing
      Given "Status" has the blocks "Signups were 3 in May"
      And text generation answers with a bar chart of "May" 3 and "June" 5
      When the user asks for "/visualize signups" on the page "Status"
      Then the user is told no chart was drawn
      And the page shows no chart

    Scenario: A number inside a longer one does not count
      Given "Status" has the blocks "We had 350 signups"
      And text generation answers with a bar chart of "May" 35
      When the user asks for "/visualize signups" on the page "Status"
      Then the user is told no chart was drawn

    Scenario: The MC counts its threads; the model only picks what to count
      Given this MC's threads took turns this week
      And text generation charts the request from the MC's threads and invents the values
      When the user asks for "/visualize weekly turns" on the page "Status"
      Then the chart holds the turns the MC counted

    Scenario Outline: The MC answers from what it counts
      Given this MC's threads took turns this week
      And text generation charts the request from the dataset "<dataset>"
      When the user asks for "/visualize it" on the page "Status"
      Then the chart's series is "<series>" with a value for "<label>"

      Examples:
        | dataset           | series  | label |
        | turns_by_thread   | Turns   | Work  |
        | turns_by_project  | Turns   | shop  |
        | threads_by_project | Threads | shop  |

    Scenario: With nothing to count nothing is drawn
      Given text generation charts the request from the MC's threads
      When the user asks for "/visualize weekly turns" on the page "Status"
      Then the user is told no chart was drawn
      And the page shows no chart

    Scenario: The model is shown the page but no project's folder
      Given "Status" has the blocks "Signups were 3 in May"
      And text generation answers with a bar chart of "May" 3
      When the user asks for "/visualize signups" on the page "Status"
      Then the request and the page's text went to the model outside any project's folder

  # The MC refuses such a chart. A client does not take that on trust: a missing number
  # drawn would read as zero against its label.
  @desktop @mobile @tui
  Rule: A number is never shown against the wrong label

    Scenario: A chart whose numbers do not match its labels is not drawn
      Given the page "Status" has a chart with 2 labels and 1 number
      Then the chart's numbers are not shown

  @mc
  Rule: A chart is data and nothing else

    Scenario Outline: A description that is not a plain chart is refused whole
      Given "Status" has the blocks "1 2 3"
      And text generation answers with the chart <chart>
      When the user asks for "/visualize it" on the page "Status"
      Then the user is told no chart was drawn
      And the page shows no chart

      Examples: what it may not carry
        | chart                                                                                                       |
        | {"labels":["a"],"series":[{"name":"s","values":[1],"url":"x"}]}                                             |
        | {"labels":["a"],"series":[{"name":"s","values":[1]}],"script":"x"}                                          |
        | {"labels":["https://evil.example"],"series":[{"name":"s","values":[1]}]}                                    |
        | {"labels":["<b>a</b>"],"series":[{"name":"s","values":[1]}]}                                                |
        | {"labels":["a"],"series":[{"name":"[s](x)","values":[1]}]}                                                  |
        | {"labels":["a"],"series":[{"name":"s","values":["1"]}]}                                                     |

      Examples: what does not fit
        | chart                                                                                                       |
        | {"labels":["a","b"],"series":[{"name":"s","values":[1]}]}                                                   |
        | {"labels":[],"series":[]}                                                                                   |
        | {"labels":["a"],"series":[{"name":"s","values":[-1]}]}                                                      |

    Scenario Outline: A chart has hard limits
      Given "Status" has the blocks "1"
      And text generation answers with a chart with <what>
      When the user asks for "/visualize it" on the page "Status"
      Then the user is told no chart was drawn

      Examples:
        | what             |
        | 25 labels        |
        | 5 series         |
        | a 41 byte label  |
        | a 121 byte title |

    Scenario: A request is plain words
      Given text generation answers with a bar chart of "May" 3
      When the user asks for "/visualize https://evil.example" on the page "Status"
      Then the page request is refused

    Scenario: The largest chart stays small on the Space's stream
      Then the largest chart a page can hold takes under 8 KiB on the Space's stream

    Scenario: A chart cannot be written directly
      When the user adds a chart block "Numbers" to "Status"
      Then the page request is refused

    Scenario: A chart's text cannot be edited
      Given the page "Status" has a chart of "May" 3 and "June" 5
      When the user edits the text of the chart
      Then the page request is refused
      And the numbers read "May" 3 and "June" 5

    Scenario: A chart cannot be asked for on a page in the trash
      Given the page "Status" is in the trash
      When the user asks for "/visualize signups" on the page "Status"
      Then the page request is refused

    Scenario: A chart survives a restart
      Given the page "Status" has a chart of "May" 3 and "June" 5
      When the MC restarts
      Then the numbers read "May" 3 and "June" 5

  @mc
  Rule: A chart outside the clients that draw it

    Scenario: A client that does not know charts reads what it is
      Given the page "Status" has a chart of "May" 3 and "June" 5
      Then the chart's text says "Signups" is a chart and where its numbers came from

    Scenario: A chart exports to Markdown as a table
      Given the page "Status" has a chart of "May" 3 and "June" 5
      When the user exports "Status" as Markdown
      Then the Markdown is:
        """
        # Status

        Signups (bar chart)

        |  | Signups |
        | --- | --- |
        | May | 3 |
        | June | 5 |

        Numbers from this page
        """

  # Each of these runs something the model wrote. They need a real sandbox first, one
  # we can show holds on every client; a chart's description cannot grow into them.
  @backlog @mc @shared
  Rule: What a chart is not

    Scenario: The user asks for a generated applet
      When the user asks for "/visualize a mortgage calculator" on the page "Status"
      Then the page shows an applet the model wrote, running in a sandbox

    Scenario: The user asks for custom sliders
      When the user asks for "/visualize turns with a slider for the week" on the page "Status"
      Then the page shows a slider that redraws the chart

    Scenario: The user asks for a simulator
      When the user asks for "/visualize a queue simulator" on the page "Status"
      Then the page shows a simulator the model wrote, running in a sandbox
