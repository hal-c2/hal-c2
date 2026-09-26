# Sources:
#   apps/server-ex/lib/hal_c2/preview_automation.ex (host registration, routing, timeouts, current tab, error messages)
#   apps/server-ex/lib/hal_c2/mcp/preview.ex (preview_* MCP tools, timed tools, snapshot bounds, screenshots, recordings, tool icon)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (hal_c2_preview_list, hal_c2_preview_close)
#   apps/server-ex/lib/hal_c2/web/socket.ex (previewAutomation shape, previewAutomation.respond, previewAutomation.focusHost)
#   apps/server-ex/test/hal_c2/preview_automation_test.exs
#   packages/contracts/src/previewAutomation.ts
#   apps/web/src/components/preview/PreviewAutomationHosts.tsx
#   apps/web/src/components/preview/previewAutomationRequestConsumer.ts
#   apps/web/src/components/preview/previewAutomationHostBudget.ts
#   apps/web/src/components/preview/previewAutomationOpenReadiness.ts
#   apps/web/src/components/preview/AgentBrowserCursor.tsx, agentBrowserCursorLogic.ts
#   apps/desktop/src/preview/Manager.ts (recording, snapshots, input guard)
#   Cross-domain: settings/ owns the preference for whether agent-opened previews come to the front.

Feature: Agents drive the preview browser
  An agent can open, read and operate the thread's browser tabs through its preview tools. The
  node routes each action to a desktop that is showing the thread's browser, so the agent works
  in the same browser the user can watch.

  Rule: The node routes each action to one browser host

    @node
    Scenario: A desktop registers as a browser host
      When a desktop offers its browser to the node
      Then the node confirms the connection
      And the desktop receives the agent's browser actions from then on

    @node
    Scenario: An agent's actions stay in the browser it last used
      Given an agent has already acted in the browser of one desktop
      And a second desktop is also available
      When the agent takes another browser action
      Then the action goes to the same desktop as before

    @node
    Scenario: A new agent session goes to the most capable, focused browser
      Given two desktops offer their browsers
      And only one of them has its window focused
      When an agent takes its first browser action
      Then the action goes to the desktop that can do the most, preferring the focused one

    @node
    Scenario: An action nobody can host fails with guidance
      Given no desktop is offering its browser
      When an agent asks to take a snapshot
      Then the tool fails with "No preview automation host is available for snapshot. Open HAL-C2's desktop app with this thread's browser panel available."

    @node
    Scenario: A browser that cannot do an action is not swapped for another mid-task
      Given an agent is working in a desktop browser that cannot record
      When the agent asks to start a recording
      Then the tool fails saying no host is available for that action
      And the agent's later actions still go to the same browser

    @node
    Scenario: A browser that does not answer in time is dropped
      Given an agent is working in a desktop browser
      When the desktop does not answer an action within its time limit
      Then the tool fails with "Preview automation click timed out after 15000ms."
      And the node drops that desktop so it has to register again
      And the action is not tried a second time

    @node
    Scenario: A browser that disconnects fails its unanswered actions
      Given an agent is waiting on an action in a desktop browser
      When that desktop disconnects
      Then the tool fails saying the client disconnected during the action

    @node
    Scenario: A desktop that registers again replaces its old connection
      Given a desktop is registered as a browser host
      When the same desktop registers again
      Then only the new connection receives actions
      And actions pending on the old connection fail as disconnected

    @node
    Scenario: The tab an agent last touched is its current tab
      Given an agent navigated a specific browser tab
      When the agent takes a snapshot without naming a tab
      Then the snapshot is of the tab the agent last touched

    @node
    Scenario: A background page check does not move the agent's current tab
      Given an agent's current tab is its first browser tab
      When the node checks another tab's page for a tool result
      Then the agent's current tab stays the first one

    @node
    Scenario Outline: Browser failures reach the agent in plain words
      Given the desktop browser answers the agent's action with <failure>
      Then the tool fails with "<message>"

      Examples:
        | failure                       | message                                                                       |
        | an unsupported action         | Preview automation client desktop-1 does not support scroll.                  |
        | a missing named tab           | Preview tab tab-9 was not found for click.                                    |
        | no active tab                 | No active preview tab was found for click.                                    |
        | a failure without any details | Preview automation client desktop-1 returned a malformed response for click. |

  Rule: Agents use the preview tools

    @node
    Scenario: An agent opens a preview and it follows the user's preference
      When an agent opens a preview without saying whether to show it
      Then whether the browser comes to the front follows the user's desktop preference
      And an existing tab for the same page is reused

    @node
    Scenario: An agent asks to show the preview
      When an agent opens a preview and asks to show it
      Then the browser comes to the front with the page

    @node
    Scenario: An action reports the page it left the tab on
      Given an agent's current tab shows "http://localhost:5173/cart"
      When the agent clicks a button on the page
      Then the tool result names the page "http://localhost:5173/cart"

    @node
    Scenario: A page that is not a website is not named in the result
      Given an agent's current tab shows a blank page
      When the agent presses a key on the page
      Then the tool result does not name a page

    @node
    Scenario: A snapshot returns the page text and a screenshot
      Given an agent's current tab shows a page
      When the agent takes a snapshot
      Then the tool returns the page's address, its text and its interactive elements
      And the tool returns the page's screenshot

    @node
    Scenario: An agent takes a snapshot without the image
      When an agent takes a snapshot and asks for no image
      Then the tool returns the page's text without the screenshot

    @node
    Scenario Outline: A large snapshot is cut down and says what was left out
      Given the page has <content>
      When an agent takes a snapshot
      Then the snapshot keeps <kept>
      And the snapshot says what it left out

      Examples:
        | content                                  | kept                                       |
        | visible text longer than 8000 characters | the first 8000 characters of visible text  |
        | an element named with 500 characters     | the first 200 characters of the name       |
        | 100 console messages                     | the newest 40 console messages             |
        | an accessibility tree                    | the interactive elements without the tree  |

    @node
    Scenario: A snapshot without a screenshot fails
      Given the desktop sends a snapshot with no screenshot
      Then the tool fails with "Preview snapshot failed: the page sent no screenshot."

    @node
    Scenario: An agent saves a screenshot to disk
      Given an agent's current tab shows "https://example.com"
      When the agent takes a snapshot and asks to save it
      Then the screenshot is saved under the node's browser artifacts named for "example-com"
      And the tool result gives the saved file's path

    @node
    Scenario: A screenshot that cannot be saved fails the snapshot
      Given the node cannot write its browser artifacts folder
      When an agent takes a snapshot and asks to save it
      Then the tool fails saying it could not save the preview screenshot to that path

    @node
    Scenario: A stopped recording becomes a thread attachment
      Given an agent is recording the preview
      When the agent stops the recording
      Then the recording is attached to the thread
      And the tool result gives the attachment's path

    @node
    Scenario Outline: A recording that cannot be brought to the node fails clearly
      Given an agent is recording the preview
      And <situation>
      When the agent stops the recording
      Then the tool fails with "<message>"

      Examples:
        | situation                               | message                                                             |
        | the recording upload cannot be claimed  | The preview recording could not be transferred to this environment. |
        | the desktop app is too old to upload it | Update HAL-C2's desktop app to transfer preview recordings.        |

    @node
    Scenario Outline: An agent's request to <action> reaches the browser
      Given an agent's current tab shows a page
      When the agent asks to <action>
      Then the desktop browser carries out <operation> on that tab
      And the result reaches the agent

      Examples:
        | action                                 | operation             |
        | read the tab's status                  | a status read         |
        | navigate to another address            | a navigation          |
        | resize the page                        | a resize              |
        | switch the page between light and dark | a color scheme change |
        | type text into a field                 | typing                |
        | scroll the page                        | a scroll              |
        | wait for text to appear                | a wait                |
        | evaluate a script in the page          | an evaluation         |
        | start a recording                      | a recording start     |

    @node
    Scenario Outline: A slow <action> may wait as long as the agent allows
      Given an agent's current tab shows a slow page
      When the agent asks to <action> allowing 30 seconds
      Then the node waits up to 30 seconds for the desktop browser to answer

      Examples:
        | action                  |
        | navigate                |
        | resize the page         |
        | click a button          |
        | type text into a field  |
        | wait for text to appear |

    @node
    Scenario: An agent pages through the thread's preview tabs
      Given the thread has 25 browser tabs
      When an agent lists the thread's preview tabs
      Then it receives the first 20 tabs and a cursor for the rest
      And listing again from that cursor returns the last 5 with no further cursor

    @node
    Scenario: An agent closes a preview tab
      Given the thread has a browser tab the agent opened
      When the agent closes that tab
      Then the tab is gone for every client

  Rule: The desktop hosts the agent's browser

    @backlog @desktop
    Scenario: The desktop offers the thread's browser to agents
      Given the user has the thread's browser available on the desktop
      Then agents in that thread can open and operate browser tabs there

    @backlog @desktop
    Scenario: The user sees where the agent is acting
      Given an agent is clicking through a page in the thread's browser
      Then the user sees the agent's pointer move to each element it acts on

    @backlog @desktop
    Scenario: The user taking over interrupts the agent's action
      Given an agent is typing into a page
      When the user clicks inside the page
      Then the agent's action stops
      And the agent is told its action was interrupted by human input in that tab

    @backlog @desktop
    Scenario: A desktop focusing its window becomes the preferred browser
      Given two desktops offer their browsers
      When the user focuses the second desktop's window
      Then a new agent session's first action goes to the second desktop
