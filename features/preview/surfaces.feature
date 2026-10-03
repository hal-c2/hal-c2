# Sources:
#   docs/user/browser-import.md
#   docs/user/keybindings.md (previewOpen and previewFocus contexts)
#   packages/contracts/src/preview.ts (PreviewOpenInput, PreviewNavigateInput, PreviewReportStatusInput, PreviewResizeInput, PreviewEvent, viewport limits and presets, zoom ladder, DiscoveredLocalServerList)
#   apps/server-ex/lib/hal_c2/preview.ex (tab snapshots, serverEpoch, revision, lookup errors)
#   apps/server-ex/lib/hal_c2/local_servers.ex (subscribeDiscoveredLocalServers)
#   apps/server-ex/lib/hal_c2/rpc.ex (preview.open, navigate, reportStatus, resize, refresh, close, list)
#   apps/server-ex/test/hal_c2/preview_test.exs
#   apps/desktop-qt/qml/HalC2/Bricks/RightPanel.qml (add menu has no browser entry)
#   apps/desktop-qt/src/native/ThreadPreviews.cpp (the right panel's Previews tab)
#   apps/desktop-qt/qml/HalC2/Bricks/PreviewsPanel.qml
#   apps/desktop-qt/tests/native/features/PreviewSteps.cpp
#   apps/desktop-qt/parity/features.backlog.test.ts (in-app-preview)
#   apps/tui/src/features.backlog.test.ts (preview-surface)
#   apps/desktop/src/preview/Manager.ts (webview host, zoom, mute, popups)
#   apps/web/src/components/preview/PreviewView.tsx
#   apps/web/src/components/preview/PreviewPanelShell.tsx
#   apps/web/src/components/preview/PreviewChromeRow.tsx
#   apps/web/src/components/preview/PreviewMoreMenu.tsx
#   apps/web/src/components/preview/PreviewEmptyState.tsx, previewEmptyStateLogic.ts
#   apps/web/src/components/preview/PreviewUnreachable.tsx, errorCodeMessages.ts, previewConstants.ts
#   apps/web/src/components/preview/useDiscoveredLocalServers.ts
#   apps/web/src/components/preview/openPreviewSession.ts, closePreviewSession.ts, addBrowserSurface.ts
#   apps/web/src/components/preview/previewViewportRollback.ts
#   apps/web/src/components/preview/ThreadPreviewMiniPlayer.tsx, previewMiniPlayerLayout.ts
#   apps/web/src/components/RightPanelTabs.tsx
#   Cross-domain: settings/ owns browser profiles, browser import and preview defaults;
#   files/ owns project scripts with preview URLs; navigation/ owns preview key chords.

Feature: In-app preview browser
  A thread can keep browser tabs beside it for the app it is building. The MC remembers each
  tab's page and state so every window and every reconnect sees the same tabs; the desktop draws
  the page itself.

  Rule: The MC keeps each thread's browser tabs

    @mc
    Scenario: Opening a tab with an address starts it loading
      When a client opens a browser tab for the thread at "http://localhost:5173"
      Then the thread has a new tab loading "http://localhost:5173"
      And every watching client is told the tab opened

    @mc
    Scenario: Opening a tab without an address leaves it idle
      When a client opens a browser tab for the thread without an address
      Then the thread has a new idle tab
      And the tab fills the space it is given

    @mc
    Scenario: A tab opens under the requested browser profile
      When a client opens a browser tab under the profile "work"
      Then the tab remembers the profile "work"

    @mc
    Scenario: Navigating a tab records its page
      Given a browser tab showing "http://localhost:5173"
      When the desktop reports it navigated to "http://localhost:5173/login" titled "Sign in"
      Then the tab shows "http://localhost:5173/login" titled "Sign in"
      And every watching client is told the tab navigated

    @mc
    Scenario: A navigation without a title keeps the page's previous title
      Given a browser tab showing a page titled "Dashboard"
      When the desktop reports a navigation without a title
      Then the tab keeps the title "Dashboard"

    @mc
    Scenario: A page that fails to load is reported to every client
      Given a browser tab loading "http://localhost:9999"
      When the desktop reports the load failed with "ERR_CONNECTION_REFUSED"
      Then every watching client is told the tab failed with that error

    @mc
    Scenario: A tab remembers whether it can go back and forward
      Given a browser tab that has visited two pages
      When the desktop reports it can go back but not forward
      Then every client sees that the tab can go back but not forward

    @mc
    Scenario: Resizing a tab records its viewport
      Given a browser tab that fills its space
      When a client resizes the tab to the "iphone-se" preset
      Then the tab's viewport is the "iphone-se" preset
      And every watching client is told the tab resized

    @mc
    Scenario: Refreshing a tab leaves reloading to the desktop
      Given a browser tab showing a page
      When a client refreshes the tab
      Then the request succeeds without changing the tab
      And the desktop reports the reload as it happens

    @mc
    Scenario: Closing one tab leaves the thread's other tabs open
      Given a thread with two browser tabs
      When a client closes the first tab
      Then only the second tab remains
      And every watching client is told the first tab closed

    @mc
    Scenario: Closing without naming a tab closes every tab of the thread
      Given a thread with two browser tabs
      When a client closes the thread's browser tabs without naming one
      Then the thread has no browser tabs

    @mc
    Scenario: Listing a thread's tabs returns them oldest change first
      Given a thread with two browser tabs, the second changed most recently
      When a client lists the thread's browser tabs
      Then it receives both tabs with the second one last
      And the list carries the MC's run and change numbers

    @mc
    Scenario: Every change carries a higher change number
      Given a client is watching browser tab changes
      When a tab opens, navigates and closes
      Then each event carries a higher change number than the one before

    @mc
    Scenario: Browser tabs do not survive an MC restart
      Given a thread with a browser tab
      When the MC restarts
      Then the thread has no browser tabs
      And the MC reports a different run number so clients drop their old tabs

    @mc
    Scenario Outline: Acting on a tab the thread does not have is refused
      When a client asks to <action> a tab the thread does not have
      Then the request fails naming the thread and the unknown tab

      Examples:
        | action           |
        | navigate         |
        | report status on |
        | resize           |
        | refresh          |

  Rule: The MC suggests local web servers to preview

    @mc
    Scenario: Web servers listening on the MC's machine are suggested
      Given a dev server is serving HTML on port 5173 of the MC's machine
      When a client watches for local servers
      Then "http://localhost:5173" is suggested with the name of the process serving it

    @mc
    Scenario Outline: Only listeners that serve web pages are suggested
      Given a program listening on port <port> that answers with <answer>
      When a client watches for local servers
      Then port <port> <outcome>

      Examples:
        | port | answer                     | outcome                |
        | 5173 | an HTML page               | is suggested           |
        | 3000 | a redirect                 | is suggested           |
        | 5432 | no HTTP at all             | is not suggested       |
        | 8080 | JSON                       | is not suggested       |
        | 9000 | an empty 204 response      | is not suggested       |

    @mc
    Scenario: The MC's own port is never suggested
      When a client watches for local servers
      Then the MC's own port is not among the suggestions

    @mc
    Scenario: Suggestions follow servers starting and stopping
      Given a client is watching for local servers
      When a new dev server starts serving HTML on port 4321
      Then within a few seconds the client is told the list now includes port 4321

    @mc
    Scenario: The MC stops scanning when nobody is watching
      Given the last client stops watching for local servers
      Then the MC no longer scans for listening ports

    @mc
    Scenario: A machine without a port listing tool suggests nothing
      Given the MC's machine cannot list listening ports
      When a client watches for local servers
      Then the suggestion list is empty

  Rule: The desktop shows the page beside the thread

    # The desktop embeds no browser: drawing the page needs QtWebEngine or
    # QtWebView, which on Linux is WebEngine underneath and has no input, zoom or
    # popup control. Until one is chosen the Previews tab lists
    # the thread's browser tabs and opens them in the user's browser, and the
    # scenarios that draw the page wait (@backlog-desktop).

    @desktop @backlog-desktop
    Scenario: The user opens a local dev server in a browser tab beside the thread
      Given the thread's dev server is listening locally
      When the user opens the preview
      Then the page opens in a browser tab beside the thread instead of a desktop-only notice

    @desktop @backlog-desktop
    Scenario: The user adds a browser tab from the side panel
      Given the side panel is open
      When the user opens the side panel's add menu
      Then it offers a browser tab next to diff, files, terminal and pull request

    @desktop @backlog-desktop
    Scenario: A new browser tab offers local servers and recent pages
      Given the thread's project has a dev server running and recently visited pages
      When the user opens a new browser tab
      Then the tab suggests the running servers, configured preview addresses and up to 10 recent pages

    @desktop @backlog-desktop
    Scenario Outline: An unreachable page explains the failure in plain words
      Given a browser tab whose page fails with <code>
      Then the tab says "This site can't be reached" and "<explanation>"
      And the user can reload the page

      Examples:
        | code                        | explanation                            |
        | ERR_NAME_NOT_RESOLVED       | DNS address could not be found         |
        | ERR_CONNECTION_REFUSED      | Connection refused                     |
        | ERR_CONNECTION_TIMED_OUT    | Connection timed out                   |
        | ERR_INTERNET_DISCONNECTED   | No internet connection                 |
        | ERR_CERT_AUTHORITY_INVALID  | Certificate authority is not trusted   |
        | ERR_TOO_MANY_REDIRECTS      | Too many redirects                     |

    @desktop @backlog-desktop
    Scenario: The user reloads a page after the dev server restarts
      Given a browser tab showing the thread's dev server
      When the agent restarts the dev server and the user reloads the tab
      Then the page reloads without the user leaving the thread

    @desktop @backlog-desktop
    Scenario Outline: The user zooms a page through the preset steps
      Given a browser tab at <from> zoom
      When the user zooms <direction>
      Then the tab is at <to> zoom

      Examples:
        | from | direction | to   |
        | 100% | in        | 110% |
        | 100% | out       | 90%  |
        | 500% | in        | 500% |
        | 25%  | out       | 25%  |
        | 150% | reset     | 100% |

    @desktop @backlog-desktop
    Scenario: The user previews the page at a device size
      Given a browser tab that fills its space
      When the user picks the "Pixel 7" device size
      Then the page renders at that device's size

    @desktop @backlog-desktop
    Scenario: A device size that times out is undone
      Given the user picks a device size for a tab
      When the MC does not confirm the resize in time
      Then the tab returns to its previous size unless a newer size was chosen

    @desktop
    Scenario: A closed browser tab stays closed while the close is in flight
      When the user closes a browser tab
      Then the tab disappears at once, even if an older update about it arrives

    @desktop
    Scenario: A browser tab whose close fails comes back
      Given the MC refuses to close a browser tab
      When the user closes the tab
      Then the tab returns as it was

    @desktop @backlog-desktop
    Scenario: The user floats a preview over the conversation
      Given a browser tab the agent is using
      When the user floats the preview
      Then a small player shows the page above the composer at the page's aspect ratio
      And it never covers the composer

    @desktop @backlog-desktop
    Scenario: The user mutes a tab that plays sound
      Given a browser tab playing audio
      When the user mutes the tab
      Then the tab stays silent until the user unmutes it
      And the tab still shows that its page is playing sound

    @desktop @backlog-desktop
    Scenario: A sign-in popup opens in its own window
      Given a page in a browser tab starts a sign-in flow in a popup
      Then the popup opens as a real window that can report back to the page

    @desktop @backlog-desktop
    Scenario: A link that targets a new window stays in the tab
      When the user follows a link on the page that targets a new window
      Then the page loads in the same browser tab

    @desktop @backlog-desktop
    Scenario: A popup cannot open further popups
      Given a sign-in popup opened by a page in a browser tab
      When the popup tries to open another popup
      Then the second popup is refused

    @desktop
    Scenario: The desktop lists the thread's browser tabs to open in the browser
      Given the thread has browser tabs at "http://localhost:5173" and "http://localhost:6006"
      When the user shows the thread's previews
      Then "http://localhost:5173" and "http://localhost:6006" are listed
      When the user opens "http://localhost:5173" from the previews
      Then the browser opens "http://localhost:5173"

    @desktop
    Scenario: The desktop's list of browser tabs follows the MC
      Given the user is showing the thread's previews
      When the agent opens a browser tab at "http://localhost:5173"
      Then "http://localhost:5173" is listed
      When the page at "http://localhost:5173" fails to load
      Then the previews say "http://localhost:5173" failed to load
      When the tab at "http://localhost:5173" is closed on the MC
      Then no browser tabs are listed

    @tui
    Scenario: The terminal client lists preview addresses without an embedded browser
      Given a project with configured and discovered preview addresses
      When the user opens previews in the terminal client
      Then the addresses are listed with ways to open or copy each one

    @tui
    Scenario: The terminal client refreshes or closes existing preview tabs
      Given the thread has preview tabs
      When the user refreshes or closes one in the terminal client
      Then the MC's tab list updates and unreachable pages are reported
