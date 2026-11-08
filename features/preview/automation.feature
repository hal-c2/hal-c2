# Sources:
#   https://github.com/pingdotgg/t3code/pull/23489
#   https://github.com/pingdotgg/t3code/pull/23396
#   https://github.com/pingdotgg/t3code/pull/22062
#   https://github.com/pingdotgg/t3code/pull/22302
#   https://github.com/pingdotgg/t3code/pull/25436
#   https://github.com/pingdotgg/t3code/pull/27456
#   https://github.com/pingdotgg/t3code/pull/16941
#   https://github.com/pingdotgg/t3code/pull/19931
#   https://github.com/pingdotgg/t3code/pull/19913
#   https://github.com/pingdotgg/t3code/pull/22877
#   https://github.com/pingdotgg/t3code/pull/20994
#   https://github.com/pingdotgg/t3code/pull/24056
#   https://github.com/pingdotgg/t3code/pull/24356
#   https://github.com/pingdotgg/t3code/pull/23895
#   https://github.com/pingdotgg/t3code/pull/18146
#   https://github.com/pingdotgg/t3code/pull/17429
#   https://github.com/pingdotgg/t3code/pull/20085
#   https://github.com/pingdotgg/t3code/pull/19737
#   https://github.com/pingdotgg/t3code/pull/20446
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
#   https://github.com/pingdotgg/t3code/pull/25184
#   https://github.com/pingdotgg/t3code/pull/24618
#   https://github.com/pingdotgg/t3code/pull/22156
#   https://github.com/pingdotgg/t3code/pull/25028
#   https://github.com/pingdotgg/t3code/pull/28027
#   https://github.com/pingdotgg/t3code/pull/28549
#   https://github.com/pingdotgg/t3code/pull/21745
#   https://github.com/pingdotgg/t3code/pull/23461
#   https://github.com/pingdotgg/t3code/pull/29614
#   https://github.com/pingdotgg/t3code/pull/29885
#   https://github.com/pingdotgg/t3code/pull/24186
#   https://github.com/pingdotgg/t3code/pull/28613
#   https://github.com/pingdotgg/t3code/pull/29600
#   https://github.com/pingdotgg/t3code/pull/29865

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

    @mc @desktop @backlog-desktop
    Scenario: A new agent session goes to the desktop showing the tab it is asked about
      Given the first desktop has its window focused
      And the second desktop is showing the tab the agent is asked about
      When an agent takes its first browser action on that tab
      Then the action goes to the second desktop

    @mc @desktop @backlog-desktop
    Scenario: A new agent session goes to a desktop with a live copy of the tab before the focused one
      Given the first desktop has its window focused
      And the second desktop has a live copy of the tab the agent is asked about
      When an agent takes its first browser action on that tab
      Then the action goes to the second desktop

    @mc @desktop @backlog-desktop
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
    @mc
    Scenario: A browser that reports its own page timeout stays connected
      Given an agent is waiting for a page in a desktop browser
      When the page wait times out and the browser says so within a second of the time limit
      Then the tool fails with the browser's timeout
      And the agent's next action goes to the same browser

    # Upstream #23489: a click that timed out said only that it timed out, even when its selector
    # matched nothing.
    @mc
    Scenario Outline: A click that times out names its target and whether it is on the page
      Given an agent is working in a desktop browser
      When the agent clicks <target> and the click times out
      Then the tool fails naming that target and saying it <matches>
      And it warns that the click may still have happened

      Examples:
        | target                                       | matches                       |
        | the selector ".definitely-no-such-target"    | matches no element            |
        | a locator for a button behind an open dialog | matches an element on the page |

    # Upstream #24356: preview_open named the 660000ms request budget when navigation stopped at 15000ms.
    @mc
    Scenario: A page that does not load in time names the wait that ran out
      Given the page an agent opens takes 20 seconds to answer
      When the agent opens it with preview_open
      Then the tool fails saying the navigation timed out after 15000ms

    # Upstream #16941: queued actions ran after their caller timed out, clicking stale pages.
    @backlog @mc @priority-high
    Scenario: A queued browser action whose caller gave up is not started
      Given an agent's click is queued behind another action in the same browser
      When the click's time limit passes before its turn comes
      Then the click is never performed
      But a queued stop of a recording still runs, so the capture is cleaned up

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

    # Upstream #28027: preview_open dropped a dev-server target and opened a blank tab, so agents
    # needed a second preview_navigate.
    @mc
    Scenario: An agent opens a dev server's port in one step
      When an agent opens a preview of port 6381 in its environment
      Then the tab opens on that environment's port 6381
      And the agent did not have to navigate the tab afterwards

    # Upstream #28027: a dev-server target knows the environment, so it wins over an address.
    @mc
    Scenario: A dev-server port wins over an address given with it
      When an agent opens a preview of port 6381 in its environment and also gives the address "http://localhost:3000"
      Then the tab opens on that environment's port 6381

    # Upstream #29865: a preview_open whose first load failed left a hidden tab the agent never heard
    # of; it counted toward the agent's tabs and made the next open ask which tab to reuse.
    @backlog @mc
    Scenario: A new tab whose first load fails is closed
      Given the agent's dev server on port 6381 is not running yet
      When the agent opens a preview of "http://localhost:6381" and the load is refused
      Then the agent is told the load failed and no tab of that open is left
      When the dev server starts and the agent opens the preview again, and then once more
      Then both opens reuse the one tab the agent has

    # Upstream #29614: "about:blank" failed with an error naming neither the input nor the problem,
    # and "mailto:" was read as a web address with credentials.
    @mc
    Scenario Outline: An agent opening an address the preview cannot show is told its protocol is unsupported
      When an agent opens a preview with <address>
      Then <outcome>

      Examples:
        | address                            | outcome                                                     |
        | the address "about:blank"          | the open fails saying the protocol "about:" is unsupported  |
        | the address "mailto:a@example.com" | the open fails saying the protocol "mailto:" is unsupported |
        | the address "localhost:3000"       | the tab opens on "http://localhost:3000"                    |
        | no address                         | a blank tab opens                                           |

    # Upstream #23396: a rejected address or locator answered with an internal detail, or only the
    # field and its length, so the agent could not tell what to send instead.
    @mc
    Scenario Outline: An agent whose <input> is rejected is told what it accepts
      When an agent sends <sent>
      Then the tool fails explaining <guidance>

      Examples:
        | input        | sent                                         | guidance                                                                |
        | address      | preview_open with the address "about:blank"  | the address forms it accepts, and that a blank tab comes from preview_open with no address |
        | locator      | preview_click with a locator it cannot parse | the locator forms it accepts                                            |
        | CSS selector | preview_click with an invalid CSS selector   | how to write a CSS selector or use a locator instead                    |

    # Upstream #16956: agents saw only the tabs they opened, so "what is on this page?" failed.
    @mc
    Scenario: An agent sees every browser tab of its thread and who has each
      Given the thread has a tab the user opened, a tab this agent opened and a tab another agent session opened
      When the agent asks for the preview status
      Then every tab is listed with whether a person, an agent or nobody has it, whether it is this agent's, whether it is shown and its profile

    # Upstream #27456: a desktop tab whose page loaded before the server attached stayed
    # "Loading" with no title in the tab list, while its status said it had loaded.
    @mc @desktop @backlog-desktop
    Scenario: A desktop tab that loaded before the MC attached is listed as loaded
      Given an agent opens a tab that the desktop shows
      And the page finishes loading before the MC is attached to it
      When the agent lists the thread's tabs
      Then the tab is listed with the page's title and as loaded
      And the list agrees with the tab's own status

    # Upstream #22877: the MC waits 10 seconds for the desktop to attach a tab's page, then opens its
    # own; a desktop that attached later showed a second page the agent did not drive.
    @backlog @mc @desktop @priority-high
    Scenario: A desktop that attaches late shows the page the agent drives
      Given an agent opens a tab that the desktop shows
      And the desktop has not attached the page within 10 seconds
      When the desktop attaches
      Then the desktop shows the MC's own page for that tab
      And the agent and the user see the same page

    # Upstream #18146: threads that share a provider session keep their browser tabs apart.
    @mc
    Scenario: Threads sharing a provider session keep their own browser tabs
      Given the threads "Tax fix" and "Docs" share one provider session
      And "Tax fix" has the browser tab "Checkout"
      When the agent in "Docs" lists its browser tabs
      Then "Checkout" is not listed

    @mc
    Scenario: An agent reads the user's tab while the user is using it
      Given the user is typing in a tab the user opened
      When an agent takes a snapshot of that tab by its id
      Then the tool returns the page without waiting for the user's input to finish

    @mc
    Scenario: An agent with no tab of its own reads the one the user is looking at
      Given the agent has opened no tab and the user is looking at "http://localhost:5173/cart"
      When the agent takes a snapshot without naming a tab
      Then the tool returns "http://localhost:5173/cart"

    @mc
    Scenario Outline: An agent acts on a tab it did not open only while no one else has it
      Given a tab <tab>
      When an agent clicks on that tab by its id
      Then <outcome>

      Examples:
        | tab                                      | outcome                                                      |
        | the user opened and is not using         | the click happens                                            |
        | the user opened and is using             | the tool fails saying a person is in control of the tab      |
        | another agent session opened             | the tool fails saying the tab belongs to another agent       |

    @mc
    Scenario: Only the agent session that opened a tab can close it
      Given a tab the user opened
      When an agent closes that tab
      Then the tab stays open and the agent is told it did not open it

    @mc
    Scenario Outline: An agent's open that reuses the user's tab does not make it the agent's
      Given a tab the user opened
      When the agent opens a preview on that tab <how>
      And an agent closes that tab
      Then the tab stays open and the agent is told it did not open it

      Examples:
        | how              |
        | by naming it     |
        | after reading it |

    # Ownership belongs to the tab, not to the desktop's connection.
    @mc
    Scenario: An agent still owns its tab after its browser is dropped and registers again
      Given the thread has a browser tab the agent opened
      And the desktop does not answer an action within its time limit
      And the MC drops that desktop so it has to register again
      When the desktop registers again after being dropped
      And the agent closes that tab
      Then the tab is gone for every client

    # Upstream #17429: closing another session's tab says why it was refused.
    @mc
    Scenario: An agent refused a tab it did not open is told whose it is
      Given another agent session opened the browser tab "Checkout"
      When an agent asks to close "Checkout"
      Then the agent is told the tab belongs to another agent session

    @mc @priority-low
    Scenario: An agent's new tab opens in the user's default browser profile
      Given the desktop reports the profiles "Default" and "Work", with "Work" the default
      When an agent opens a preview without naming a profile
      Then the tab opens in the profile "Work"

    @mc @priority-low
    Scenario Outline: An agent can name the profile a new tab opens in
      Given the desktop reports the profiles "Default" and "Work"
      When an agent opens a preview in the profile "<named>"
      Then <outcome>

      Examples:
        | named    | outcome                                                          |
        | work     | the tab opens in the profile "Work"                              |
        | personal | the tool fails and lists "Default" and "Work" as the profiles to use |

    # Upstream #21745: the MC kept only the last client's profiles, so other clients' profiles vanished.
    @mc
    Scenario: Browser profiles reported by several clients are all offered to agents
      Given one desktop reports the profiles "Default" and "Work"
      And another desktop connected to the same MC reports only "Default"
      When an agent opens a preview in the profile "Work"
      Then the tab opens in the profile "Work"

    # Upstream #23461: one oversized page event took down the whole desktop app.
    @backlog @desktop @priority-high
    Scenario: A page that sends an agent an oversized event loses only its own tab
      Given an agent is driving a browser tab
      When the page sends the agent an event too large to pass on
      Then the agent loses control of that tab until it is opened again
      And the app, its other tabs and its threads keep running

    # Upstream #23461: an oversized reply fails only the command that asked for it.
    @backlog @desktop
    Scenario: An oversized reply to an agent's browser command fails only that command
      Given an agent is driving a browser tab
      When the reply to one of its commands is too large to pass on
      Then that command fails saying the reply is too large
      And the agent's next command on the tab works

    @mc
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

    # Upstream #16956: providers replay a tool's images on every later request, and some refuse
    # them, so the screenshot is only sent when asked for.
    @mc
    Scenario: A snapshot returns the page text and leaves the screenshot out unless asked
      Given an agent's current tab shows a page
      When the agent takes a snapshot
      Then the tool returns the page's address, its text and its interactive elements
      And the tool returns no screenshot
      When the agent takes a snapshot and asks for the image
      Then the tool returns the page's screenshot

    @mc
    Scenario: A snapshot saved as a file returns only the address and the path unless the image is asked for
      Given an agent's current tab shows a page
      When the agent takes a snapshot and saves the screenshot
      Then the tool returns only the page's address and the saved file's path

    @mc
    Scenario: An agent takes a snapshot without the image
      When an agent takes a snapshot and asks for no image
      Then the tool returns the page's text without the screenshot

    # Upstream #24618: a scaled capture drew blurred backdrops wrong; snapshots are now taken at
    # full scale and shrunk afterwards.
    @backlog @mc @desktop @priority-low
    Scenario: A snapshot's screenshot shows blurred backdrops as the page draws them
      Given an agent's current tab shows a page with a blurred panel over its content
      And the page is zoomed to 125%
      When the agent takes a snapshot and asks for the image
      Then the screenshot shows the panel blurred as it is on screen
      And the screenshot has no black padding

    # Upstream #19913: at 150% display scale a 1280×800 page gave a 960×600 image labelled 1280×800.
    @backlog @mc @desktop
    Scenario: A snapshot's screenshot matches the page's viewport and the display's scale
      Given an agent's current tab is 1280×800 on a display scaled to 150%
      When the agent takes a snapshot and asks for the image
      Then the screenshot covers the whole 1280×800 viewport
      And the size the snapshot reports is the image's own size

    # Upstream #19931: a hidden or minimized preview returned stale pixels or failed.
    @backlog @desktop
    Scenario: A snapshot of a preview the user cannot see shows the page as it is now
      Given an agent's current tab is hidden behind another tab or the window is minimized
      And the page changed since it was last on screen
      When the agent takes a snapshot and asks for the image
      Then the screenshot shows the page as it is now, not as it was last drawn

    # Upstream #20446: snapshots mask what password fields hold, in every frame.
    @backlog @mc @desktop @priority-high
    Scenario: A snapshot never shows what a password field holds
      Given an agent's current tab shows a sign-in form with a password typed in
      When the agent takes a snapshot
      Then the snapshot shows the password field with its value masked
      And the password appears nowhere in the page text, including fields drawn as dots

    # Upstream #20446: a snapshot it cannot vouch for fails instead of risking a leak.
    @backlog @mc @desktop
    Scenario: A snapshot of a page that changes while it is read fails instead of leaking
      Given an agent's current tab shows a password field whose value changes while the snapshot is taken
      When the agent takes a snapshot
      Then the tool fails saying the page was too busy to read safely
      And it answers within 10 seconds

    # Upstream #13558: a save-only snapshot returns the path, not the page metadata.
    @mc
    Scenario: A snapshot saved as a file without its image returns only the address and the file's path
      Given an agent's current tab shows a page
      When the agent takes a snapshot with no image and saves the screenshot
      Then the tool returns only the page's address and the saved file's path

    # Upstream #13559: a missing preview tab says what to do next, not just that it is missing.
    @mc
    Scenario: An agent that names a tab which is not open is told to open a preview first
      When an agent takes a snapshot of a tab that is not open
      Then the tool fails saying to open a preview with preview_open first

    # Upstream #19737: preview_open refuses a tab id that is not open
    @mc
    Scenario: Opening a preview on a tab that is not open fails instead of opening a new tab
      Given the thread has no browser tab "tab-9"
      When an agent opens a preview naming the tab "tab-9"
      Then the agent is told the tab is not open
      And no new tab is opened

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

    # Upstream #29600: a cut landing inside an emoji left half of it, which strict JSON readers
    # such as Codex's refused, failing the whole tool result.
    @mc
    Scenario: A snapshot cut never splits an emoji
      Given the page's visible text has an emoji where the snapshot cuts it
      When an agent takes a snapshot
      Then the snapshot's text ends on a whole character
      And Codex reads the tool result

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

    # Upstream #23895: agent recordings were captured at 30 fps whatever the setting said.
    @backlog @mc @desktop
    Scenario: An agent's recording uses the recording frame rate the user chose
      Given the user's default recording frame rate is 60 fps
      When an agent records the preview
      Then the recording is captured at up to 60 frames a second

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

    @mc
    Scenario Outline: A recording that cannot be transferred says the desktop keeps its copy
      Given an agent is recording the preview
      And <situation>
      When the agent stops the recording
      Then the tool fails with "<message>"

      Examples:
        | situation                                  | message                                                                |
        | the recording is larger than 50 MiB        | The recording exceeds 50 MiB. The saved copy remains on the desktop.   |
        | the transfer is not finished in time       | The recording transfer deadline expired. The saved copy remains on the desktop. |

    @backlog @desktop @priority-low
    Scenario: Stopping a recording that was never started fails
      Given an agent's current tab is not being recorded
      When the agent stops the recording
      Then the tool fails saying no recording is active for that tab

    @backlog @desktop @priority-low
    Scenario: Only one tab is recorded at a time
      Given an agent is recording one tab of the thread
      When the agent starts a recording of another tab
      Then the tool fails saying the other tab cannot be recorded while the first is already being recorded

    @backlog @desktop @priority-low
    Scenario: Typing into something that cannot take text fails
      Given an agent's current tab has the focus on a page area that is not editable
      When the agent types text into the page
      Then the tool fails saying the action needs an editable target in that tab

    @backlog @desktop @priority-low
    Scenario: A page that never draws at the requested size fails the resize
      Given an agent's current tab shows a page
      When the agent resizes the page and the desktop never renders that size within the wait
      Then the tool fails saying the viewport was not rendered in time

    # Proved by tst_PreviewAutomationHostProp.cpp (an action on a tab with no page), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @priority-low
    Scenario: A browser that is not showing the tab in time fails the open
      When an agent opens a preview and the desktop does not show the page's browser within the wait
      Then the tool fails saying the browser did not register in time

    @backlog @desktop @priority-low
    Scenario: An action on a tab that was replaced by an MC restart fails
      Given an agent's current tab was opened before the MC restarted
      When the agent asks for an action on that tab after the restart
      Then the tool fails saying the tab is no longer available
      And the desktop does not act on the tab it had before the restart

    # Proved by tst_PreviewAutomationHostProp.cpp (the user closes the tab mid-action), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @priority-low
    Scenario: An action on a tab the user has since closed fails
      Given an agent's current tab shows a page
      When the user closes the tab before the agent's action reaches the desktop
      Then the tool fails saying the tab is no longer available

    @backlog @desktop @priority-low
    Scenario: A page the agent is waiting on is not acted on before its size is applied
      Given an agent has just opened a tab at a fixed size
      When the agent acts on the page before the desktop has rendered that size
      Then the desktop waits until the page is at the requested size, give or take a pixel
      And only then acts

    @backlog @desktop @priority-low
    Scenario: A tab that is not on screen is still recorded in full
      Given an agent is recording a tab the user is not looking at
      Then the recording has every frame of the page
      And it is not cut off because the tab is out of sight

    @backlog @desktop @priority-low
    Scenario: Closing a tab that is being recorded stops its recording first
      Given an agent is recording a tab
      When the user closes that tab
      Then the recording is stopped before the tab goes away

    @backlog @desktop @priority-low
    Scenario: A second tab cannot start recording while another is still starting
      Given an agent asked to record one tab and its recording has not started yet
      When the agent asks to record another tab within ten seconds
      Then the tool fails saying the first tab is still claiming the capture stream
      And the first tab's recording is not disturbed

    @backlog @desktop @priority-low
    Scenario: A recording that was asked for but never started frees the way after ten seconds
      Given an agent asked to record a tab and the recording never started
      When ten seconds pass
      Then the agent can record another tab

    # Upstream #20085: a recording warmup that never settles no longer holds up stopping
    @backlog @desktop @priority-low
    Scenario: A recording whose warmup never settles can still be stopped
      Given a recording of the preview has started and its warmup never settles
      When the recording is stopped
      Then it stops without waiting for the warmup

    @backlog @desktop @priority-low
    Scenario: A recording is not started while the app window is closed
      Given the desktop's main window is closed
      When an agent asks to record a tab
      Then the tool fails saying recording cannot start while the main window is closed

    # Proved by tst_PreviewAutomationWeb.cpp (keepsOffDevTools), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @priority-low
    Scenario: An agent cannot control a tab while its developer tools are open
      Given the user has the developer tools open on a tab
      When an agent acts on that tab
      Then the tool fails saying to close the preview's developer tools before using agent browser control

    @backlog @desktop @priority-low
    Scenario: An agent cannot control a tab another debugger is attached to
      Given another debugger is attached to a tab's page
      When an agent acts on that tab
      Then the tool fails saying agent control cannot attach because another debugger owns the page

    # Proved by tst_PreviewAutomationWeb.cpp (keepsOffDevTools), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @priority-low
    Scenario: Agent control comes back once the developer tools are closed
      Given an agent was refused because the developer tools were open on a tab
      When the user closes the developer tools
      Then the agent's next action on that tab goes through

    # Upstream #28549: agent clicks could move the keyboard focus out of the composer, even when the
    # preview floated over the chat or was hidden.
    @backlog @desktop
    Scenario Outline: An agent's click in the preview leaves the user's typing where it was
      Given the user is typing in the composer and the preview is <shown>
      When an agent clicks and types in the preview
      Then the composer still has the focus
      And the agent's clicks reach the page in the order it made them

      Examples:
        | shown                  |
        | beside the chat        |
        | floating over the chat |
        | hidden                 |

    # Upstream #28613: an agent revealing a tab moved the focus into the side panel, and clicks
    # in two tabs at once could leave the focus in the first tab's page.
    @backlog @desktop
    Scenario Outline: The composer keeps the focus while agents <action>
      Given the user is typing in the composer
      When <what>
      Then the composer still has the focus

      Examples:
        | action                    | what                                                          |
        | reveal a tab              | an agent in another thread reveals a tab already in the panel |
        | click in two tabs at once | agents click in two browser tabs at the same time             |

    # Upstream #28613: each tab keeps its own queue, so a press held open by a page's confirm
    # dialog does not block its siblings.
    @backlog @desktop @priority-low
    Scenario: A click held open by a page's dialog does not hold up the other tabs
      Given an agent's click in one tab is waiting on a confirm dialog the page opened
      When an agent clicks in another tab
      Then that click reaches its page

    @backlog @desktop @priority-low
    Scenario: A click outside the page is refused with the page's size
      Given an agent's current tab is rendered at 1280 by 800
      When the agent clicks at a point beyond the page's edge
      Then the tool fails naming the point and saying it is outside the 1280x800 viewport

    @backlog @desktop @priority-low
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

    @backlog @desktop @priority-low
    Scenario: A target the agent describes badly is rejected with the reason
      Given an agent's current tab shows a page
      When the agent clicks a target written in a way the page cannot understand
      Then the tool fails saying the target was rejected
      And the reason the page gave is reported

    # Proved by tst_PreviewAutomationWeb.cpp (evaluates), not yet by a step (hal-c2/hal-c2#213).
    @desktop @backlog-desktop @priority-low
    Scenario: A script that throws reports what it threw
      Given an agent's current tab shows a page
      When the agent evaluates a script that throws an error
      Then the tool fails saying the evaluation failed
      And the error's own message is reported

    @backlog @desktop @priority-low
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
    @backlog @desktop @priority-low
    Scenario: A drag that times out fails without taking the browser down
      Given an agent's current tab shows a page
      When the agent drags an element and the drag times out while the cursor is still moving
      Then the tool fails with the drag's error
      And the desktop and the MC keep running with the thread's work untouched

    @backlog @desktop @priority-low
    Scenario: Waiting for text gives up after fifteen seconds by default
      Given an agent's current tab shows a page without the text the agent waits for
      When the agent waits for that text without saying how long
      Then the tool fails after fifteen seconds saying the condition did not match in time

    @backlog @desktop @priority-low
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

    # Upstream #25028: concurrent opens could pass the tab limits, and a failed launch left a session behind.
    @backlog @mc @priority-low
    Scenario: Opens racing each other stay within the agent's tab limit
      Given an agent has 7 browser tabs open
      When the agent opens two more tabs at the same moment
      Then one tab opens and the other is refused for the tab limit
      And no more than 32 agent tabs are open across the MC

    # Upstream #25028
    @backlog @mc @priority-low
    Scenario: A browser tab that fails to launch leaves nothing behind
      When an agent opens a tab and the browser fails to launch it
      Then the open fails
      And the tab is not listed and does not count toward the tab limit

    # Upstream #29885: a tab whose setup failed partway left its page open, and every retry left
    # another one.
    @backlog @desktop @priority-low
    Scenario: A browser tab that fails while it is being set up closes its page
      When an agent opens a tab and the page closes before the tab is set up
      Then the open fails and the page is closed
      And opening the tab again leaves only the new tab's page open

    # Upstream #24186: with every slot held by idle agent tabs, a new agent's open was refused until
    # tabs were closed by hand or the app restarted.
    @backlog @mc @desktop
    Scenario Outline: An agent's open at the 32-tab limit reclaims the longest idle agent tab nobody sees
      Given 32 agent tabs are open across the MC and the newest agent has fewer than 8
      And the longest idle agent tab, idle for over 30 minutes, <state>
      When the newest agent opens a tab
      Then <outcome>

      Examples:
        | state                         | outcome                                                    |
        | is hidden and agent-owned     | that tab is closed and the new tab opens                   |
        | is shown to the user          | that tab stays and the open is refused for the tab limit   |
        | is the user's own             | that tab stays and the open is refused for the tab limit   |

    # Upstream #20994: file requests are intercepted only while an agent acts or a streamed
    # controller drives the tab; otherwise the desktop opens the system file picker.
    @backlog @desktop
    Scenario: A file input the user clicks opens the system file picker
      Given an agent has used the preview tab "Upload"
      And no agent action is running on "Upload"
      When the user clicks a file input on "Upload"
      Then the system file picker opens

    # Upstream #22062: a page's file request outlived the page, so the next page still asked for a file.
    @backlog @mc
    Scenario: A file request ends when its page is replaced
      Given a page on the preview tab "Upload" is asking for a file
      When the tab navigates to another page before the request is answered
      Then the tab no longer asks for a file
      And an agent that uploads a file there is told no file picker is open

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

    # Upstream #25184: driving a tab once kept it running at full speed long after anyone looked
    # at it, a preview tab of another thread waking about 20 times a second.
    @backlog @desktop @mc
    Scenario Outline: A preview tab out of sight slows down like a background page
      Given a preview tab of "Checkout" is not on screen
      And <use>
      Then the tab <runs>

      Examples:
        | use                                                       | runs                                                       |
        | nothing has used it for five seconds                      | slows its timers down like a background page               |
        | the agent of "Checkout" used it during the running turn   | keeps running at full speed until that turn ends           |
        | an agent's action on it has not answered yet              | keeps running at full speed until the action answers       |
        | it is being streamed or recorded                          | keeps running at full speed until the stream stops         |

    # Upstream #24056: a tab's renderer dying while overlapping screenshots were pending crashed the
    # whole desktop app and the MC with it.
    @backlog @desktop
    Scenario: A preview tab takes one agent screenshot at a time
      Given an agent's snapshot of a stalled preview tab timed out with its screenshot still pending
      When the agent takes another snapshot of that tab
      Then its screenshot waits until the pending one answers or the tab loads a new page
      And a screenshot left waiting for a tab the agent let go of is never taken

    # Upstream #25184: a hidden tab keeps painting until a capture of it finishes.
    @backlog @desktop @mc
    Scenario: A screenshot of a preview tab out of sight shows the page as it is now
      Given a preview tab of "Checkout" is not on screen and has slowed down
      When an agent takes a snapshot of it and asks for the image
      Then the screenshot shows the page's current content

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

    @backlog @desktop @priority-low
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

    @backlog @desktop @priority-low
    Scenario: An agent acting on a tab brings the floating preview into view
      Given auto-show floating preview is on
      And an agent opened a preview tab and did not ask to hide it
      When the agent clicks on the page after the user closed the floating preview
      Then the floating preview shows again

    @backlog @desktop @priority-low
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

    @backlog @desktop @priority-low
    Scenario: The agent's pointer shows where it last acted and fades when idle
      Given an agent clicked an element of a page in the thread's browser
      Then the agent's pointer rests on that element, brighter for a moment after the click
      And it fades when the agent is idle, more so while the user is in control

    @backlog @desktop @priority-low
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

    @backlog @desktop @priority-low
    Scenario: A screenshot for a snapshot is no wider than 1280 pixels
      Given a page rendered 1920 pixels wide
      When an agent takes a snapshot
      Then the screenshot is scaled down to 1280 pixels wide
      And a page narrower than that is not scaled

    @backlog @desktop @priority-low
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

    @backlog @desktop @priority-high
    Scenario: An agent typing in a preview tab does not type into the app the user is using
      Given the user is typing in the composer
      And an agent's current tab shows a page with a focused text field
      When the agent types "pairing-code" and presses Enter in the tab
      Then the page's field holds "pairing-code" and receives the Enter
      And the composer keeps its text and its focus

    @backlog @desktop @priority-low
    Scenario: An agent's copy, cut and paste keys in a preview tab without focus are ignored
      Given the preview tab does not have the focus
      When the agent presses the copy, cut or paste key in the tab
      Then nothing is copied, cut or pasted
      And the user's clipboard is unchanged

    @backlog @desktop @priority-low
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

  # Upstream #25436: downloads saved by tabs still open when the server stopped stayed on disk with no way to reach them.
  @backlog @mc @priority-low
  Scenario: Downloads no tab can reach are cleared when the MC starts
    Given a browser tab the MC runs saved a download
    And the MC stopped while that tab was open
    When the MC starts again
    Then the saved download is removed before any tab opens

  # Upstream #22156: a data: address is the file's contents, so reporting it echoed the whole
  # file into every later tool result and the event log.
  @backlog @desktop
  Scenario: A download from a data address is reported by its media type alone
    Given the agent's page downloaded a file from a "data:text/plain" address
    When the agent reads the browser's status, navigates or takes a snapshot
    Then the download, navigation reports, network entries and link targets show "data:text/plain,…"
    And none of them holds the file's contents

  # Upstream #22302: a tab showing a data: page echoed the page through its address.
  @backlog @desktop
  Scenario: A tab showing a data page is reported by its media type alone
    Given a browser tab shows a page loaded from a "data:text/html" address
    When the agent reads the browser's status, its load reports or a snapshot
    Then the tab's address reads "data:text/html,…"
    And a crashed tab on that page reopens at that address

  # Upstream #22156: only messages the browser writes itself are redacted; the page's own logs stay.
  @backlog @desktop @priority-low
  Scenario: A page's own console output keeps any data address it wrote
    Given the agent's page logs a message containing a "data:" address
    And the browser blocked a navigation to a "data:" address
    When the agent reads the console
    Then the page's message is as it was written
    And the browser's own message shows only the address's media type

  # Upstream #22156: downloads were written with the process umask.
  @backlog @desktop
  Scenario: Files the agent's browser downloads are readable by the user alone
    When the agent's page downloads a file
    Then the file and the folder it is saved in can be read only by the user

  @backlog @desktop @priority-high
  Scenario: Agent clicks do not steal composer focus
    Given the user is typing in the composer
    When the agent clicks in the preview
    Then the composer keeps keyboard focus
