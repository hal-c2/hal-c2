# Sources:
#   https://github.com/pingdotgg/t3code/pull/16956
#   https://github.com/pingdotgg/t3code/pull/16963
#   https://github.com/pingdotgg/t3code/pull/17360
#   https://github.com/pingdotgg/t3code/pull/17693
#   https://github.com/pingdotgg/t3code/pull/18556
#   https://github.com/pingdotgg/t3code/pull/13559
#   https://github.com/pingdotgg/t3code/pull/13558
#   https://github.com/pingdotgg/t3code/pull/13064
#   https://github.com/pingdotgg/t3code/pull/2829
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
#   apps/web/src/components/preview/previewAutomationErrors.ts, previewAutomationTarget.ts
#   apps/web/src/browser/browserPointerStore.ts, browserRecording.ts
#   apps/web/src/browser/previewRuntimeTabId.ts, desktopTabLifetime.ts, browserViewportActions.ts, browserRecordingScope.ts
#   apps/web/src/components/preview/previewNavigationReadiness.ts, previewViewportReadiness.ts
#   packages/contracts/src/previewAutomation.ts (recording transfer errors)
#   apps/desktop/src/preview/Manager.ts (recording, snapshots, input guard, agent control errors and limits)
#   apps/desktop/src/preview/PlaywrightInjectedRuntime.ts (locator parsing injected into the page)
#   Cross-domain: settings/ owns the preference for whether agent-opened previews come to the front.
#   https://github.com/pingdotgg/t3code/pull/14573
#   https://github.com/pingdotgg/t3code/pull/15008

Feature: Agents drive the preview browser
  An agent can open, read and operate the thread's browser tabs through its preview tools. The
  MC routes each action to a desktop that is showing the thread's browser, so the agent works
  in the same browser the user can watch.

  Rule: The MC routes each action to one browser host

    @mc
    Scenario: A desktop registers as a browser host
      When a desktop offers its browser to the MC
      Then the MC confirms the connection
      And the desktop receives the agent's browser actions from then on

    @mc
    Scenario: An agent's actions stay in the browser it last used
      Given an agent has already acted in the browser of one desktop
      And a second desktop is also available
      When the agent takes another browser action
      Then the action goes to the same desktop as before

    @mc
    Scenario: A new agent session goes to the most capable, focused browser
      Given two desktops offer their browsers
      And only one of them has its window focused
      When an agent takes its first browser action
      Then the action goes to the desktop that can do the most, preferring the focused one

    @backlog @mc @desktop
    Scenario: A new agent session goes to the desktop showing the tab it is asked about
      Given the first desktop has its window focused
      And the second desktop is showing the tab the agent is asked about
      When an agent takes its first browser action on that tab
      Then the action goes to the second desktop

    @backlog @mc @desktop
    Scenario: A new agent session goes to a desktop with a live copy of the tab before the focused one
      Given the first desktop has its window focused
      And the second desktop has a live copy of the tab the agent is asked about
      When an agent takes its first browser action on that tab
      Then the action goes to the second desktop

    @backlog @mc @desktop
    Scenario: A desktop that only has a snapshot of a browser is not offered for a new agent session
      Given the first desktop has its window focused
      And the second desktop has only a snapshot of its browser
      When an agent takes its first browser action
      Then the action goes to the first desktop

    @mc
    Scenario: An action nobody can host fails with guidance
      Given no desktop is offering its browser
      When an agent asks to take a snapshot
      Then the tool fails with "No preview automation host is available for snapshot. Open HAL-C2's desktop app with this thread's browser panel available."

    @mc
    Scenario: A browser that cannot do an action is not swapped for another mid-task
      Given an agent is working in a desktop browser that cannot record
      When the agent asks to start a recording
      Then the tool fails saying no host is available for that action
      And the agent's later actions still go to the same browser

    @mc
    Scenario: A browser that does not answer in time is dropped
      Given an agent is working in a desktop browser
      When the desktop does not answer an action within its time limit
      Then the tool fails with "Preview automation click timed out after 15000ms."
      And the MC drops that desktop so it has to register again
      And the action is not tried a second time

    # Upstream #17693: the MC gave up at the same moment the page did, so the browser's own
    # timeout answer, a few milliseconds late, cost the agent its browser.
    @backlog @mc
    Scenario: A browser that reports its own page timeout stays connected
      Given an agent is waiting for a page in a desktop browser
      When the page wait times out and the browser says so within a second of the time limit
      Then the tool fails with the browser's timeout
      And the agent's next action goes to the same browser

    @mc
    Scenario: A browser that disconnects fails its unanswered actions
      Given an agent is waiting on an action in a desktop browser
      When that desktop disconnects
      Then the tool fails saying the client disconnected during the action

    @mc
    Scenario: A desktop that registers again replaces its old connection
      Given a desktop is registered as a browser host
      When the same desktop registers again
      Then only the new connection receives actions
      And actions pending on the old connection fail as disconnected

    @mc
    Scenario: The tab an agent last touched is its current tab
      Given an agent navigated a specific browser tab
      When the agent takes a snapshot without naming a tab
      Then the snapshot is of the tab the agent last touched

    @mc
    Scenario: A background page check does not move the agent's current tab
      Given an agent's current tab is its first browser tab
      When the MC checks another tab's page for a tool result
      Then the agent's current tab stays the first one

    @mc
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

    @mc
    Scenario: An agent opens a preview and it follows the user's preference
      When an agent opens a preview without saying whether to show it
      Then whether the browser comes to the front follows the user's desktop preference
      And an existing tab for the same page is reused

    @mc
    Scenario: An agent asks to show the preview
      When an agent opens a preview and asks to show it
      Then the browser comes to the front with the page

    # Upstream #16956: agents saw only the tabs they opened, so "what is on this page?" failed.
    @backlog @mc
    Scenario: An agent sees every browser tab of its thread and who has each
      Given the thread has a tab the user opened, a tab this agent opened and a tab another agent session opened
      When the agent asks for the preview status
      Then every tab is listed with whether a person, an agent or nobody has it, whether it is this agent's, whether it is shown and its profile

    @backlog @mc
    Scenario: An agent reads the user's tab while the user is using it
      Given the user is typing in a tab the user opened
      When an agent takes a snapshot of that tab by its id
      Then the tool returns the page without waiting for the user's input to finish

    @backlog @mc
    Scenario: An agent with no tab of its own reads the one the user is looking at
      Given the agent has opened no tab and the user is looking at "http://localhost:5173/cart"
      When the agent takes a snapshot without naming a tab
      Then the tool returns "http://localhost:5173/cart"

    @backlog @mc
    Scenario Outline: An agent acts on a tab it did not open only while no one else has it
      Given a tab <tab>
      When an agent clicks on that tab by its id
      Then <outcome>

      Examples:
        | tab                                      | outcome                                                      |
        | the user opened and is not using         | the click happens                                            |
        | the user opened and is using             | the tool fails saying a person is in control of the tab      |
        | another agent session opened             | the tool fails saying the tab belongs to another agent       |

    @backlog @mc
    Scenario: Only the agent session that opened a tab can close it
      Given a tab the user opened
      When an agent closes that tab
      Then the tab stays open and the agent is told it did not open it

    @backlog @mc
    Scenario: An agent's new tab opens in the user's default browser profile
      Given the desktop reports the profiles "Default" and "Work", with "Work" the default
      When an agent opens a preview without naming a profile
      Then the tab opens in the profile "Work"

    @backlog @mc
    Scenario Outline: An agent can name the profile a new tab opens in
      Given the desktop reports the profiles "Default" and "Work"
      When an agent opens a preview in the profile "<named>"
      Then <outcome>

      Examples:
        | named    | outcome                                                          |
        | work     | the tab opens in the profile "Work"                              |
        | personal | the tool fails and lists "Default" and "Work" as the profiles to use |

    @backlog @mc
    Scenario Outline: An agent's instructions let it use another browser only when the preview cannot do the job
      When <situation>
      Then the agent's instructions let it use another browser <how>

      Examples:
        | situation                                                              | how                                         |
        | the user invokes a skill or written workflow that names another browser | and report any missing prerequisite         |
        | the preview fails twice on the same step of an open tab                | after quoting the error, without asking     |
        | the preview works                                                      | not at all, the preview stays the default   |

    @mc
    Scenario: An action reports the page it left the tab on
      Given an agent's current tab shows "http://localhost:5173/cart"
      When the agent clicks a button on the page
      Then the tool result names the page "http://localhost:5173/cart"

    @mc
    Scenario: A page that is not a website is not named in the result
      Given an agent's current tab shows a blank page
      When the agent presses a key on the page
      Then the tool result does not name a page

    @mc
    Scenario: A snapshot returns the page text and a screenshot
      Given an agent's current tab shows a page
      When the agent takes a snapshot
      Then the tool returns the page's address, its text and its interactive elements
      And the tool returns the page's screenshot

    # Upstream #16956: providers replay a tool's images on every later request, and some refuse
    # them, so the screenshot is only sent when asked for. Replaces the scenario above once the
    # MC carries it.
    @backlog @mc
    Scenario: A snapshot returns the page text and leaves the screenshot out unless asked
      Given an agent's current tab shows a page
      When the agent takes a snapshot
      Then the tool returns the page's address, its text and its interactive elements
      And the tool returns no screenshot
      When the agent takes a snapshot and asks for the image
      Then the tool returns the page's screenshot

    @backlog @mc
    Scenario: A snapshot saved as a file returns only the address and the path unless the image is asked for
      Given an agent's current tab shows a page
      When the agent takes a snapshot and saves the screenshot
      Then the tool returns only the page's address and the saved file's path

    @mc
    Scenario: An agent takes a snapshot without the image
      When an agent takes a snapshot and asks for no image
      Then the tool returns the page's text without the screenshot

    # Upstream #13558: a save-only snapshot returns the path, not the page metadata.
    @mc @backlog
    Scenario: A snapshot saved as a file without its image returns only the address and the file's path
      Given an agent's current tab shows a page
      When the agent takes a snapshot with no image and saves the screenshot
      Then the tool returns only the page's address and the saved file's path

    # Upstream #13559: a missing preview tab says what to do next, not just that it is missing.
    @mc @backlog
    Scenario: An agent that names a tab which is not open is told to open a preview first
      When an agent takes a snapshot of a tab that is not open
      Then the tool fails saying to open a preview with preview_open first

    @mc
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

    @mc
    Scenario: A snapshot without a screenshot fails
      Given the desktop sends a snapshot with no screenshot
      Then the tool fails with "Preview snapshot failed: the page sent no screenshot."

    @mc
    Scenario: An agent saves a screenshot to disk
      Given an agent's current tab shows "https://example.com"
      When the agent takes a snapshot and asks to save it
      Then the screenshot is saved under the MC's browser artifacts named for "example-com"
      And the tool result gives the saved file's path

    @mc
    Scenario: A screenshot that cannot be saved fails the snapshot
      Given the MC cannot write its browser artifacts folder
      When an agent takes a snapshot and asks to save it
      Then the tool fails saying it could not save the preview screenshot to that path

    @mc
    Scenario: A stopped recording becomes a thread attachment
      Given an agent is recording the preview
      When the agent stops the recording
      Then the recording is attached to the thread
      And the tool result gives the attachment's path

    @mc
    Scenario Outline: A recording that cannot be brought to the MC fails clearly
      Given an agent is recording the preview
      And <situation>
      When the agent stops the recording
      Then the tool fails with "<message>"

      Examples:
        | situation                               | message                                                             |
        | the recording upload cannot be claimed  | The preview recording could not be transferred to this environment. |
        | the desktop app is too old to upload it | Update HAL-C2's desktop app to transfer preview recordings.        |

    @backlog @mc
    Scenario Outline: A recording that cannot be transferred says the desktop keeps its copy
      Given an agent is recording the preview
      And <situation>
      When the agent stops the recording
      Then the tool fails with "<message>"

      Examples:
        | situation                                  | message                                                                |
        | the recording is larger than 50 MiB        | The recording exceeds 50 MiB. The saved copy remains on the desktop.   |
        | the transfer is not finished in time       | The recording transfer deadline expired. The saved copy remains on the desktop. |

    @backlog @desktop
    Scenario: Stopping a recording that was never started fails
      Given an agent's current tab is not being recorded
      When the agent stops the recording
      Then the tool fails saying no recording is active for that tab

    @backlog @desktop
    Scenario: Only one tab is recorded at a time
      Given an agent is recording one tab of the thread
      When the agent starts a recording of another tab
      Then the tool fails saying the other tab cannot be recorded while the first is already being recorded

    @backlog @desktop
    Scenario: Typing into something that cannot take text fails
      Given an agent's current tab has the focus on a page area that is not editable
      When the agent types text into the page
      Then the tool fails saying the action needs an editable target in that tab

    @backlog @desktop
    Scenario: A page that never draws at the requested size fails the resize
      Given an agent's current tab shows a page
      When the agent resizes the page and the desktop never renders that size within the wait
      Then the tool fails saying the viewport was not rendered in time

    # Proved by tst_PreviewAutomationHostProp.cpp (an action on a tab with no page), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: A browser that is not showing the tab in time fails the open
      When an agent opens a preview and the desktop does not show the page's browser within the wait
      Then the tool fails saying the browser did not register in time

    @backlog @desktop
    Scenario: An action on a tab that was replaced by an MC restart fails
      Given an agent's current tab was opened before the MC restarted
      When the agent asks for an action on that tab after the restart
      Then the tool fails saying the tab is no longer available
      And the desktop does not act on the tab it had before the restart

    # Proved by tst_PreviewAutomationHostProp.cpp (the user closes the tab mid-action), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: An action on a tab the user has since closed fails
      Given an agent's current tab shows a page
      When the user closes the tab before the agent's action reaches the desktop
      Then the tool fails saying the tab is no longer available

    @backlog @desktop
    Scenario: A page the agent is waiting on is not acted on before its size is applied
      Given an agent has just opened a tab at a fixed size
      When the agent acts on the page before the desktop has rendered that size
      Then the desktop waits until the page is at the requested size, give or take a pixel
      And only then acts

    @backlog @desktop
    Scenario: A tab that is not on screen is still recorded in full
      Given an agent is recording a tab the user is not looking at
      Then the recording has every frame of the page
      And it is not cut off because the tab is out of sight

    @backlog @desktop
    Scenario: Closing a tab that is being recorded stops its recording first
      Given an agent is recording a tab
      When the user closes that tab
      Then the recording is stopped before the tab goes away

    @backlog @desktop
    Scenario: A second tab cannot start recording while another is still starting
      Given an agent asked to record one tab and its recording has not started yet
      When the agent asks to record another tab within ten seconds
      Then the tool fails saying the first tab is still claiming the capture stream
      And the first tab's recording is not disturbed

    @backlog @desktop
    Scenario: A recording that was asked for but never started frees the way after ten seconds
      Given an agent asked to record a tab and the recording never started
      When ten seconds pass
      Then the agent can record another tab

    @backlog @desktop
    Scenario: A recording is not started while the app window is closed
      Given the desktop's main window is closed
      When an agent asks to record a tab
      Then the tool fails saying recording cannot start while the main window is closed

    # Proved by tst_PreviewAutomationWeb.cpp (keepsOffDevTools), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: An agent cannot control a tab while its developer tools are open
      Given the user has the developer tools open on a tab
      When an agent acts on that tab
      Then the tool fails saying to close the preview's developer tools before using agent browser control

    @backlog @desktop
    Scenario: An agent cannot control a tab another debugger is attached to
      Given another debugger is attached to a tab's page
      When an agent acts on that tab
      Then the tool fails saying agent control cannot attach because another debugger owns the page

    # Proved by tst_PreviewAutomationWeb.cpp (keepsOffDevTools), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: Agent control comes back once the developer tools are closed
      Given an agent was refused because the developer tools were open on a tab
      When the user closes the developer tools
      Then the agent's next action on that tab goes through

    @backlog @desktop
    Scenario: A click outside the page is refused with the page's size
      Given an agent's current tab is rendered at 1280 by 800
      When the agent clicks at a point beyond the page's edge
      Then the tool fails naming the point and saying it is outside the 1280x800 viewport

    @backlog @desktop
    Scenario Outline: A click on an element that cannot be clicked is reported as not found
      Given an agent's current tab shows a page with a button that is <state>
      When the agent clicks that button
      Then the tool fails saying it could not find the target in that tab
      And nothing on the page is clicked

      Examples:
        | state                 |
        | missing from the page |
        | hidden                |
        | disabled              |

    @backlog @desktop
    Scenario: A target the agent describes badly is rejected with the reason
      Given an agent's current tab shows a page
      When the agent clicks a target written in a way the page cannot understand
      Then the tool fails saying the target was rejected
      And the reason the page gave is reported

    # Proved by tst_PreviewAutomationWeb.cpp (evaluates), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: A script that throws reports what it threw
      Given an agent's current tab shows a page
      When the agent evaluates a script that throws an error
      Then the tool fails saying the evaluation failed
      And the error's own message is reported

    @backlog @desktop
    Scenario: A script result of more than sixty-four thousand bytes is refused
      Given an agent's current tab shows a page
      When the agent evaluates a script whose result is larger than 64,000 bytes
      Then the tool fails saying the result was too large and what the maximum is

    # Upstream #16963: a script that never returned held the tab's queue of actions.
    @backlog @desktop
    Scenario: A script that runs past the time limit is stopped
      Given an agent's current tab shows a page
      When the agent evaluates a script that never finishes
      Then the tool fails saying the evaluation timed out
      And the script is stopped in the page
      And the agent's next action on the tab runs at once

    # Upstream #17360: a drag that timed out before it finished took the whole server down.
    @backlog @desktop
    Scenario: A drag that times out fails without taking the browser down
      Given an agent's current tab shows a page
      When the agent drags an element and the drag times out while the cursor is still moving
      Then the tool fails with the drag's error
      And the desktop and the MC keep running with the thread's work untouched

    @backlog @desktop
    Scenario: Waiting for text gives up after fifteen seconds by default
      Given an agent's current tab shows a page without the text the agent waits for
      When the agent waits for that text without saying how long
      Then the tool fails after fifteen seconds saying the condition did not match in time

    @backlog @desktop
    Scenario: A key press the page never received is reported
      Given an agent's current tab shows a page
      When the agent presses a key and the page does not confirm having received it within five seconds
      Then the tool fails saying the condition did not match within 5000 ms
      And the key is not reported as pressed

    @mc
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

    @mc
    Scenario Outline: A slow <action> may wait as long as the agent allows
      Given an agent's current tab shows a slow page
      When the agent asks to <action> allowing 30 seconds
      Then the MC waits up to 30 seconds for the desktop browser to answer

      Examples:
        | action                  |
        | navigate                |
        | resize the page         |
        | click a button          |
        | type text into a field  |
        | wait for text to appear |

    @mc
    Scenario: An agent pages through the thread's preview tabs
      Given the thread has 25 browser tabs
      When an agent lists the thread's preview tabs
      Then it receives the first 20 tabs and a cursor for the rest
      And listing again from that cursor returns the last 5 with no further cursor

    @mc
    Scenario: An agent closes a preview tab
      Given the thread has a browser tab the agent opened
      When the agent closes that tab
      Then the tab is gone for every client

  Rule: The desktop hosts the agent's browser

    # Proved by tst_PreviewAutomationWeb.cpp (navigatesAndSnapshots, clicksTypesAndPresses), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: The desktop offers the thread's browser to agents
      Given the user has the thread's browser available on the desktop
      Then agents in that thread can open and operate browser tabs there

    # Proved by tst_AgentCue.qml, not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: The user sees where the agent is acting
      Given an agent is clicking through a page in the thread's browser
      Then the user sees the agent's pointer move to each element it acts on

    # Proved by tst_AgentCue.qml, not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: The user sees which tab an agent is using
      Given an agent is acting in one of the thread's browser tabs
      Then that tab shows that the agent is using it
      And the mark goes once the agent's action ends

    # Proved by tst_AgentCue.qml, not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: The agent's clicks do not animate when the user asks for less motion
      Given the user has asked for reduced motion
      When an agent clicks in a page
      Then the agent's pointer moves without animating and no ripple is drawn

    # Proved by tst_PreviewAutomationWeb.cpp (tellsTheUserFromTheAgent, yieldsToTheUser), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: The user taking over interrupts the agent's action
      Given an agent is typing into a page
      When the user clicks inside the page
      Then the agent's action stops
      And the agent is told its action was interrupted by human input in that tab

    # Proved by tst_PreviewAutomationHostProp.cpp (focus, blur) for the desktop's half, not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop
    Scenario: A desktop focusing its window becomes the preferred browser
      Given two desktops offer their browsers
      When the user focuses the second desktop's window
      Then a new agent session's first action goes to the second desktop

    @backlog @desktop
    Scenario: A tab an agent opens renders at a fixed size unless the user chose one
      Given the user has no default browser size
      When an agent opens a new preview tab
      Then the page renders at 1280 by 800
      Given the user's default browser size is 390 by 844
      When an agent opens another new preview tab
      Then that page renders at 390 by 844

    @backlog @desktop
    Scenario: An agent reusing a tab does not change its size
      Given a preview tab the user sized to 500 by 700
      When an agent opens the same page again
      Then the existing tab is reused at 500 by 700

    @backlog @desktop
    Scenario Outline: An agent can ask for the floating preview to show or stay hidden
      Given auto-show floating preview is <setting>
      When an agent opens a preview and says <request>
      Then the floating preview is <result>

      Examples:
        | setting | request              | result  |
        | on      | nothing              | shown   |
        | off     | nothing              | hidden  |
        | off     | to show it           | shown   |
        | on      | not to show it       | hidden  |

    @backlog @desktop
    Scenario: An agent acting on a tab brings the floating preview into view
      Given auto-show floating preview is on
      And an agent opened a preview tab and did not ask to hide it
      When the agent clicks on the page after the user closed the floating preview
      Then the floating preview shows again

    @backlog @desktop
    Scenario: An agent that asked not to show a preview is not shown one when it acts
      Given an agent opened a preview tab asking not to show it
      When the agent clicks on the page
      Then the floating preview stays hidden

    @backlog @desktop
    Scenario Outline: A navigation waits for the page to be as ready as the agent asked
      Given an agent navigates a tab asking to wait for <readiness>
      When the page reaches <readiness>
      Then the tool returns with the page

      Examples:
        | readiness            |
        | load                 |
        | DOM content loaded   |
        | nothing               |

    @backlog @desktop
    Scenario: A navigation that never reaches the readiness asked for fails in time
      Given an agent navigates a tab asking to wait for the page to load
      When the page does not finish loading within the agent's wait
      Then the tool fails saying the navigation did not reach load readiness in time
      And the failure arrives before the MC gives up on the browser

    @backlog @desktop
    Scenario: The agent's pointer shows where it last acted and fades when idle
      Given an agent clicked an element of a page in the thread's browser
      Then the agent's pointer rests on that element, brighter for a moment after the click
      And it fades when the agent is idle, more so while the user is in control

    @backlog @desktop
    Scenario: The agent's pointer is cleared when the page navigates
      Given the agent's pointer rests on an element of the page
      When the tab navigates to another page
      Then the pointer is no longer shown

    @backlog @desktop
    Scenario: The agent's own input does not count as the user taking over
      Given an agent is typing into a page
      When the page receives the agent's key presses and clicks
      Then the user is not shown as being in control
      And the agent's action is not interrupted

    @backlog @desktop
    Scenario: A page cannot fake the user taking over
      Given an agent is clicking through a page
      When a script on the page dispatches its own mouse and key events
      Then the user is not shown as being in control
      And the agent's action is not interrupted

    @backlog @desktop
    Scenario: The user is shown as in control for a moment after taking over
      Given the user clicked inside an agent's page
      When about three quarters of a second pass without further input
      Then the tab no longer shows the user as being in control

    @backlog @desktop
    Scenario: A snapshot is bounded in what the page can send
      Given a page with 300 interactive elements and 50,000 characters of visible text
      When an agent takes a snapshot
      Then it lists the first 200 interactive elements
      And it carries the first 20,000 characters of the visible text

    @backlog @desktop
    Scenario: A screenshot for a snapshot is no wider than 1280 pixels
      Given a page rendered 1920 pixels wide
      When an agent takes a snapshot
      Then the screenshot is scaled down to 1280 pixels wide
      And a page narrower than that is not scaled

    @backlog @desktop
    Scenario: A snapshot is retried when the page has no picture to give yet
      Given a page that cannot be captured on the first try
      When an agent takes a snapshot
      Then the capture is retried up to three times, each given one second
      And the snapshot fails only if all three fail

    @backlog @desktop
    Scenario: A snapshot reports the newest console messages and only the requests that failed
      Given a page that logged more than 200 console messages and made requests that succeeded and failed
      When an agent takes a snapshot
      Then the console messages are the newest 200
      And the requests listed are only those that came back with an error status or never completed

    @backlog @desktop
    Scenario: A snapshot reports what the agent has just done
      Given an agent has acted on a page more than 200 times
      When the agent takes a snapshot
      Then the actions listed are the last 200, each with how it ended

    @backlog @desktop
    Scenario Outline: An agent can point at an element in the way that suits it
      Given an agent's current tab shows a page with a "Send" button
      When the agent clicks it by <way>
      Then the button is clicked

      Examples:
        | way                                        |
        | its role and name                          |
        | its visible text                           |
        | a style selector                           |
        | the point where it is on the page          |

    @backlog @desktop
    Scenario: A click scrolls the element into view first
      Given an agent's current tab shows a page with a button below the fold
      When the agent clicks that button by its text
      Then the page scrolls until the button is in the middle of the view
      And the button is clicked where it is

    @backlog @desktop
    Scenario: Typing can replace what a field already holds
      Given an agent's current tab shows a field that already holds "old text"
      When the agent types "new text" into it and asks to clear it first
      Then the field holds "new text"
      When the agent types "!" into it without asking to clear it
      Then the field holds "new text!"

    @backlog @desktop
    Scenario: Typing without a target goes to the element that has the focus
      Given an agent's current tab has a text field with the focus
      When the agent types text without naming a target
      Then the text goes into the focused field

    @backlog @desktop
    Scenario: An agent typing in a preview tab does not type into the app the user is using
      Given the user is typing in the composer
      And an agent's current tab shows a page with a focused text field
      When the agent types "pairing-code" and presses Enter in the tab
      Then the page's field holds "pairing-code" and receives the Enter
      And the composer keeps its text and its focus

    @backlog @desktop
    Scenario: An agent's copy, cut and paste keys in a preview tab without focus are ignored
      Given the preview tab does not have the focus
      When the agent presses the copy, cut or paste key in the tab
      Then nothing is copied, cut or pasted
      And the user's clipboard is unchanged

    @backlog @desktop
    Scenario: Typing into a frame from another site fails clearly while the preview has no focus
      Given the preview tab does not have the focus
      And the page's focus is in a frame from another site
      When the agent types text in the tab
      Then the tool fails saying the text cannot reach that frame

    @backlog @desktop
    Scenario: Typing into a field that is read-only or disabled fails
      Given an agent's current tab shows a field that cannot be edited
      When the agent types text into it
      Then the tool fails saying the target was found but is not editable

    @backlog @desktop
    Scenario Outline: Waiting for the page can combine what it must show
      Given an agent's current tab shows a page
      When the agent waits for <condition>
      Then the wait ends once <result>

      Examples:
        | condition                     | result                                  |
        | an element to exist           | the element is on the page              |
        | text to appear                | the page's visible text includes it     |
        | the address to include a part | the page's address includes it          |
        | text and an address together  | both are true at the same moment        |

    @backlog @desktop
    Scenario: A wait of more than sixty seconds is refused
      Given an agent's current tab shows a page
      When the agent waits for text and allows ten minutes
      Then the tool refuses the request, saying the wait may be at most 60,000 milliseconds

  @backlog @desktop
  Scenario: Downloads from a page the agent drove save without a dialog
    Given the agent last drove the preview page
    When the page starts a download
    Then it is saved to the browser artifacts folder with no Save dialog
    And once the user clicks, types or navigates, downloads show the Save dialog again

  @backlog @desktop
  Scenario: Agent clicks do not steal composer focus
    Given the user is typing in the composer
    When the agent clicks in the preview
    Then the composer keeps keyboard focus
