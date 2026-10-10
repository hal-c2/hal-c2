# Sources:
#   docs/user/browser-import.md
#   docs/user/keybindings.md (previewOpen and previewFocus contexts)
#   packages/contracts/src/preview.ts (PreviewOpenInput, PreviewNavigateInput, PreviewReportStatusInput, PreviewResizeInput, PreviewEvent, viewport limits and presets, zoom ladder, DiscoveredLocalServerList)
#   apps/server-ex/lib/hal_c2/preview.ex (tab snapshots, serverEpoch, revision, lookup errors)
#   apps/server-ex/lib/hal_c2/local_servers.ex (subscribeDiscoveredLocalServers)
#   apps/server/src/preview/PortScanner.ts (Windows listing, terminal-owned listeners, probe rules)
#   apps/server/src/preview/Manager.ts (open, navigate, reportStatus, resize, close, list; Manager.test.ts)
#   packages/shared/src/preview.ts (normalizePreviewUrl)
#   apps/server-ex/lib/hal_c2/rpc.ex (preview.open, navigate, reportStatus, resize, refresh, close, list)
#   apps/server-ex/test/hal_c2/preview_test.exs
#   apps/desktop-qt/qml/HalC2/Bricks/RightPanel.qml (the add menu's Browser tab)
#   apps/desktop-qt/src/native/ThreadPreviews.cpp (the right panel's Previews tab)
#   apps/desktop-qt/qml/HalC2/Bricks/PreviewsPanel.qml
#   apps/desktop-qt/tests/native/features/PreviewSteps.cpp
#   apps/desktop-qt/parity/features.backlog.test.ts (in-app-preview)
#   apps/tui/src/features.backlog.test.ts (preview-surface)
#   apps/desktop/src/preview/Manager.ts (webview host, zoom, mute, popups)
#   apps/desktop/src/preview/PickPreload.ts, PickedElementPayload.ts (annotation overlay: tools, picking, drawing, style edits, submit)
#   apps/desktop/src/preview/FaviconCapture.ts (icon limits and fetch rules)
#   apps/desktop/src/preview/BrowserSession.ts (page permissions, profile partitions, identity)
#   apps/desktop/src/preview/PreviewKeyboard.ts, AnnotationKeyboard.ts (page shortcuts and key delivery)
#   apps/desktop/src/preview/RecordingCursor.ts, RecordingInput.ts (recording cursor and key badges)
#   apps/web/src/components/preview/PreviewView.tsx
#   apps/web/src/components/preview/PreviewPanelShell.tsx
#   apps/web/src/components/preview/PreviewChromeRow.tsx
#   apps/web/src/components/preview/PreviewMoreMenu.tsx
#   apps/web/src/components/preview/PreviewEmptyState.tsx, previewEmptyStateLogic.ts
#   apps/web/src/components/preview/PreviewUnreachable.tsx, errorCodeMessages.ts, previewConstants.ts
#   apps/web/src/components/preview/useDiscoveredLocalServers.ts
#   apps/web/src/components/preview/openPreviewSession.ts, closePreviewSession.ts, addBrowserSurface.ts
#   apps/web/src/components/preview/previewViewportRollback.ts
#   apps/web/src/browser/BrowserDeviceToolbar.tsx, BrowserViewportResizeHandles.tsx, browserDeviceToolbarState.ts
#   apps/web/src/browser/webviewCrashRecovery.ts, browserLinkTarget.ts, openFileInPreview.ts
#   apps/web/src/browser/browserRecording.ts, browserTargetResolver.ts
#   apps/web/src/browserHistoryStore.ts, browserFaviconStore.ts, browserFaviconLogic.ts
#   apps/web/src/previewStateStore.ts, packages/shared/src/previewViewport.ts
#   apps/server/src/preview/PortScanner.ts (configured preview addresses, probe cache and rules; PortScanner.test.ts)
#   apps/web/src/components/preview/ThreadPreviewMiniPlayer.tsx, previewMiniPlayerLayout.ts
#   apps/web/src/components/RightPanelTabs.tsx
#   apps/web/src/browser/browserDefaults.ts, browserSurfaceStore.ts, desktopTabLifetime.ts, previewRuntimeTabId.ts
#   apps/web/src/browser/browserViewportLayout.ts, browserViewportActions.ts, useBrowserViewportResize.ts
#   apps/web/src/browser/recordingCompositor.ts, browserRecordingScope.ts, browserRecordingUpload.ts, useOpenLink.ts
#   apps/web/src/browser/HostedBrowserWebview.tsx, hostedBrowserWebviewStyle.ts, BrowserSurfaceSlot.tsx, ElectronBrowserHost.tsx
#   apps/web/src/components/preview/PreviewLocalServerCard.tsx, PreviewRecentUrlCard.tsx, ZoomIndicator.tsx, BrowserMockup.tsx
#   apps/web/src/components/preview/openDiscoveredPort.ts, openTerminalLinkInPreview.ts, previewActionBus.ts
#   apps/web/src/components/preview/previewNavigationReadiness.ts, previewViewportReadiness.ts, fileExplorerLabel.ts
#   apps/web/src/previewMiniPlayerStore.ts, portDiscoveryState.ts
#   apps/web/src/components/useThreadPanelClosing.ts, ChatView.logic.ts (closing a browser the agent is using)
#   apps/web/src/components/ChatView.tsx (an annotation sent at once while sending is unavailable)
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

    @backlog @desktop @tui
    Scenario Outline: A typed address gets the web scheme that fits the host it names
      When a client opens a browser tab for the thread at "<typed>"
      Then the thread has a new tab loading "<loaded>"

      Examples:
        | typed          | loaded                |
        | localhost:5173 | http://localhost:5173 |
        | 127.0.0.1:8080 | http://127.0.0.1:8080 |
        | example.com    | https://example.com   |

    @backlog @desktop @tui
    Scenario: A typed address with a scheme other than web is refused
      When a client opens a browser tab for the thread at "ftp://example.com/file"
      Then no tab opens
      And the client is told the address cannot be opened

    @mc
    Scenario: A tab opens under the requested browser profile
      When a client opens a browser tab under the profile "work"
      Then the tab remembers the profile "work"

    # Likely already implemented: apps/server-ex/lib/hal_c2/preview.ex (open takes the viewport)
    @backlog @mc
    Scenario: A tab can be opened at the size the client asks for
      When a client opens a browser tab for the thread at the "iphone-se" preset
      Then the tab's viewport is the "iphone-se" preset from the start

    # Likely already implemented: apps/server-ex/lib/hal_c2/preview.ex (snapshots are merged)
    @backlog @mc
    Scenario: A tab keeps its profile and size when it navigates and reports its status
      Given a browser tab under the profile "work" resized to 1024 by 768
      When the desktop reports it navigated to "http://localhost:5173/resized"
      And the desktop reports its status as loaded
      Then the tab still has the profile "work"
      And the tab still has the viewport 1024 by 768

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

    @backlog @mc
    Scenario Outline: A viewport outside what a page can be rendered at is refused
      Given a browser tab that fills its space
      When a client resizes the tab to <width> by <height>
      Then the MC refuses the resize
      And the tab keeps its viewport

      Examples:
        | width | height |
        | 239   | 800    |
        | 800   | 239    |
        | 3841  | 800    |
        | 3840  | 2161   |

    @backlog @mc
    Scenario Outline: A viewport at the edge of the limits is accepted
      Given a browser tab that fills its space
      When a client resizes the tab to <width> by <height>
      Then the tab's viewport is <width> by <height>

      Examples:
        | width | height |
        | 240   | 240    |
        | 3840  | 2160   |

    @backlog @mc
    Scenario: An address of more than 2048 characters is refused
      When a client opens a browser tab at an address of 2049 characters
      Then no tab opens
      And the client is told the address is too long

    @backlog @mc
    Scenario Outline: A refused address is described without repeating it
      When a client opens a browser tab at <address>
      Then no tab opens
      And the error says why the address was refused and how long it was
      And the error does not contain the address, its credentials, query or fragment

      Examples:
        | address                                                                  |
        | "   "                                                                    |
        | "https://user:password@example.com:bad/path?access_token=secret#fragment" |

    @backlog @mc
    Scenario: A page title of more than 512 characters is refused
      Given a browser tab showing a page
      When the desktop reports a navigation titled with 513 characters
      Then the tab keeps its previous page and title

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

    # Likely already implemented: apps/server-ex/lib/hal_c2/preview.ex (close)
    @backlog @mc
    Scenario Outline: Closing a tab or thread that has no tabs succeeds quietly
      When a client closes <what>
      Then the request succeeds
      And no watching client is told anything
      And the thread's other tabs are unchanged

      Examples:
        | what                                     |
        | a tab the thread does not have           |
        | the tabs of a thread that has none       |

    # Likely already implemented: apps/server-ex/lib/hal_c2/preview.ex (close emits one event per tab)
    @backlog @mc
    Scenario: Closing every tab of a thread gives each tab its own change number
      Given a thread with two browser tabs
      And a client is watching browser tab changes
      When a client closes the thread's browser tabs without naming one
      Then the client is told each tab closed
      And the second event's change number is higher than the first's
      And the list's change number is the second event's

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

    @backlog @mc
    Scenario: A dev server started in a thread's terminal is suggested for that thread
      Given a dev server is serving HTML on port 5173, started in a terminal of a thread
      When a client watches for local servers in that thread
      Then "http://localhost:5173" is suggested for that thread

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

      # No steps serve these answers yet. The MC suggests any 3xx
      # (apps/server-ex/lib/hal_c2/local_servers.ex:157-158), so it does not yet refuse
      # a redirect to nowhere or a 304.
      @backlog
      Examples:
        | port | answer                     | outcome                |
        | 9100 | a redirect to nowhere      | is not suggested       |
        | 9200 | a 304 not modified answer  | is not suggested       |
        | 9300 | an HTML 404 page           | is not suggested       |
        | 9400 | plain text                 | is not suggested       |
        | 9500 | an XHTML page              | is suggested           |

    # Not yet in apps/server-ex/lib/hal_c2/local_servers.ex: it only asks over plain HTTP.
    @backlog @mc
    Scenario: A listener that only speaks HTTPS is suggested with an https address
      Given a program listening on port 8443 that answers an HTML page over HTTPS only
      When a client watches for local servers
      Then "https://localhost:8443" is suggested

    # Likely already implemented: apps/server-ex/lib/hal_c2/local_servers.ex (autoredirect false)
    @backlog @mc
    Scenario: A listener that redirects elsewhere is suggested without following the redirect
      Given a program listening on port 3000 that redirects to "https://example.com"
      When a client watches for local servers
      Then port 3000 is suggested
      And the MC never asks "example.com" for anything

    # Likely already implemented: apps/server-ex/lib/hal_c2/local_servers.ex (probe timeout)
    @backlog @mc
    Scenario: A listener that does not answer within a second is not suggested
      Given a program listening on port 7000 that accepts connections and never answers
      When a client watches for local servers
      Then port 7000 is not suggested
      And the other suggestions are not held up for longer than the probe takes

    # Not yet in apps/server-ex/lib/hal_c2/local_servers.ex: it probes every port on every scan.
    @backlog @mc
    Scenario: A probe's answer is reused for fifteen seconds
      Given port 5173 was probed and answered with an HTML page
      When the list is scanned again within fifteen seconds
      Then the MC does not probe port 5173 again
      When the list is scanned again after fifteen seconds
      Then the MC probes port 5173 again
      And a port that failed its probe is also probed again only after fifteen seconds

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

    @backlog @mc
    Scenario: Web servers on a Windows MC are suggested too
      Given the MC runs on Windows
      And a dev server is serving HTML on port 5173 of the MC's machine
      When a client watches for local servers
      Then "http://localhost:5173" is suggested

    @backlog @mc
    Scenario: A configured preview address that serves a page is suggested as written
      Given a client names the configured address "http://localhost:3000/app" when it watches for local servers
      And the address answers with an HTML page
      Then "http://localhost:3000/app" is suggested with the path the project configured

    @backlog @mc
    Scenario: A configured preview address that serves no page is not suggested
      Given a client names the configured address "http://localhost:3000/app" when it watches for local servers
      And nothing answers there
      Then "http://localhost:3000/app" is not suggested

    @backlog @mc
    Scenario Outline: Only local web addresses are probed for the project's configured previews
      Given a client names the configured address "<address>" when it watches for local servers
      Then the MC does not probe "<address>"

      Examples:
        | address                  |
        | https://example.com      |
        | ftp://localhost/files    |
        | not a url                |

    @backlog @mc
    Scenario: A configured address on every interface is suggested as localhost
      Given a client names the configured address "http://0.0.0.0:3000" when it watches for local servers
      And the address answers with an HTML page
      Then "http://localhost:3000/" is suggested

    @backlog @mc
    Scenario: A configured address is suggested even when the server's root serves no page
      Given a client names the configured address "http://localhost:3000/docs" when it watches for local servers
      And "http://localhost:3000/" answers 404 but "http://localhost:3000/docs" serves an HTML page
      Then "http://localhost:3000/docs" is suggested as written

    @backlog @mc
    Scenario Outline: A configured address on this machine keeps its scheme and host
      Given a client names the configured address "<address>" when it watches for local servers
      And the address answers with an HTML page
      Then "<address>" is suggested as written

      Examples:
        | address                    |
        | https://127.0.0.1:8443/docs |
        | http://[::1]:3000/docs     |

    @backlog @mc
    Scenario: A configured address that is too long once rewritten as localhost is not probed
      Given a client names the configured address "http://0.0.0.0/" followed by enough characters to reach the 2048 character limit
      Then the MC does not probe it
      And the other configured addresses are probed as usual

    @backlog @mc
    Scenario: Each watching client gets suggestions for its own configured addresses
      Given one client names "http://localhost:3000/docs" and another names "http://localhost:3000/admin"
      And both addresses answer with an HTML page
      Then the first client is suggested "/docs" and not "/admin"
      And the second client is suggested "/admin" and not "/docs"

    @backlog @mc
    Scenario: A client with many configured addresses does not use up another client's allowance
      Given one client names 32 configured addresses
      And another client names one more address that serves a page
      Then the second client is still suggested its address

    @backlog @mc
    Scenario: A client that stops watching no longer has its configured addresses probed
      Given two clients watching with different configured addresses
      When the first client stops watching
      Then the MC keeps probing the second client's addresses
      And the MC no longer probes the first client's addresses

    @backlog @mc
    Scenario: No more than thirty-two configured addresses are probed
      Given a client names 40 configured local addresses when it watches for local servers
      Then the MC probes only the first 32

    @backlog @mc
    Scenario: A configured address does not hide the same server found by scanning
      Given a client names the configured address "http://localhost:3000" when it watches for local servers
      And a dev server listens on port 3000
      Then the server on port 3000 is suggested once, with the configured address

  Rule: The desktop shows the page beside the thread

    # The desktop embeds no browser: drawing the page needs QtWebEngine or
    # QtWebView, which on Linux is WebEngine underneath and has no input, zoom or
    # popup control. Until one is chosen the Previews tab lists
    # the thread's browser tabs, offers where a new one can go and opens them
    # in the user's browser, and the scenarios that draw the page wait
    # (@backlog-desktop).

    @desktop @backlog-desktop
    Scenario: The user opens a local dev server in a browser tab beside the thread
      Given the thread's dev server is listening locally
      When the user opens the preview
      Then the page opens in a browser tab beside the thread instead of a desktop-only notice

    @desktop
    Scenario: The user adds a browser tab from the side panel
      Given the side panel is open
      When the user opens the side panel's add menu
      Then it offers a browser tab next to diff, files, terminal and pull request

    @desktop
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

    @backlog @desktop
    Scenario: A load the page itself cancelled is not shown as a failure
      Given a browser tab whose page starts another load before the first finishes
      Then the tab does not say the page failed to load

    @backlog @desktop
    Scenario: A frame inside the page that fails does not fail the tab
      Given a browser tab showing a page that embeds a frame which cannot load
      Then the tab does not say the page failed to load

    @backlog @desktop
    Scenario: A failed load stays shown until a new load starts
      Given a browser tab whose page failed to load
      When the load is reported as having stopped
      Then the tab still says the page failed to load
      When the user reloads the page
      Then the failure is cleared while the new load runs

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

    @backlog @desktop
    Scenario: A zoom between the preset steps is brought to the nearest step
      Given a browser tab whose saved zoom is 137%
      When the tab is opened
      Then the tab is at the preset step nearest to 137%

    @backlog @desktop
    Scenario: Zooming the app does not zoom the page in a browser tab
      Given a browser tab at 100% zoom
      When the user zooms the whole app in
      Then the page in the tab stays at 100% zoom

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

    @backlog @desktop
    Scenario: A quiet tab can be muted ahead of time
      Given a browser tab that is not playing audio
      When the user mutes the tab from its menu
      Then the tab stays silent when its page starts playing sound

    @backlog @desktop
    Scenario: A browser tab cannot be muted before the desktop has opened its page
      Given the MC lists a browser tab the desktop has not opened yet
      When the user opens that tab's menu
      Then muting is listed but cannot be chosen

    @backlog @desktop
    Scenario: A tab stays muted when its page navigates
      Given a muted browser tab
      When the tab moves to another page
      Then the tab is still muted

    @backlog @desktop
    Scenario: A mute the page engine refuses is not shown as done
      Given a browser tab playing audio
      When the user mutes the tab and the engine refuses
      Then the tab is shown as not muted

    @backlog @desktop
    Scenario: Closing a browser tab the agent is using asks first
      Given the agent is controlling a browser tab
      When the user closes that tab
      Then the user is asked "Close browser while the agent is using it?"
      And the user is told that closing it may interrupt the current browser action
      And declining keeps the tab open

    @backlog @desktop
    Scenario: Closing several tabs the agent is using asks once
      Given the agent is controlling two browser tabs
      When the user closes every tab of the right panel
      Then the user is asked once "Close 2 browsers while the agent is using them?"
      And declining keeps every tab open

    @backlog @desktop
    Scenario: A new browser tab opens in the default profile unless the user picks another
      Given the user has the browser profiles "Personal" and "Work" and "Personal" is the default
      When the user adds a browser tab from the side panel
      Then the tab opens under "Personal"
      When the user adds a browser tab and picks "Work"
      Then that tab opens under "Work"

    @backlog @desktop
    Scenario: Choosing a profile is not offered when there is only one
      Given the user has one browser profile
      When the user looks at what can be added to the side panel
      Then a browser tab is offered without a choice of profile

    @backlog @desktop
    Scenario: A browser tab shows the icon the page itself gave
      Given a browser tab has loaded a page with its own icon
      Then the tab shows that icon
      When the tab moves to a page on another site
      Then the first site's icon is no longer shown for it

    @backlog @desktop
    Scenario: No outside service is asked for the icon of a private address
      Given a browser tab shows a page on "localhost:5173" that gave no icon
      Then no public icon service is asked about that address
      And the tab shows a plain browser icon

    @backlog @desktop
    Scenario: A page's icon stays when the tab moves within the same site
      Given a browser tab has loaded a page with its own icon
      When the tab moves to another page on the same site
      Then the tab keeps showing that icon

    @backlog @desktop
    Scenario Outline: An icon that cannot be used is left out
      Given a browser tab has loaded a page whose icon <problem>
      Then the tab shows a plain browser icon

      Examples:
        | problem                                  |
        | is larger than 100 kilobytes             |
        | redirects to another address             |
        | takes longer than five seconds to arrive |
        | cannot be read as a picture              |
        | is larger than a million pixels          |

    @backlog @desktop
    Scenario: A page's next icon is tried when the first cannot be used
      Given a browser tab has loaded a page that offers two icons and the first is refused
      Then the tab shows the second icon

    @backlog @desktop
    Scenario: Only the first few icons a page offers are tried
      Given a browser tab has loaded a page that offers twelve icons and only the ninth works
      Then the tab shows a plain browser icon

    @backlog @desktop
    Scenario: An icon from another site is fetched without the user's cookies for it
      Given a browser tab has loaded a page whose icon is served from another site
      When the desktop fetches that icon
      Then the other site is not sent the user's cookies

    @backlog @desktop
    Scenario: An icon given inline is used as it is
      Given a browser tab has loaded a page whose icon is given inline in the page
      Then the tab shows that icon

    @backlog @desktop
    Scenario: A page that is not a website has no icon
      Given a browser tab showing a page that is not a website
      Then the tab shows a plain browser icon

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

    @backlog @desktop
    Scenario Outline: A page may ask for some things and not others
      Given a page in a browser tab asks for <permission>
      Then the request is <outcome>

      Examples:
        | permission                         | outcome |
        | the clipboard's text               | allowed |
        | to put text on the clipboard       | allowed |
        | to show notifications              | allowed |
        | the user's location                | allowed |
        | the camera                         | refused |
        | the microphone                     | refused |
        | the list of installed fonts        | refused |
        | anything else a page can ask for   | refused |

    @backlog @desktop
    Scenario: A page is not told it is running in a different browser
      Given a page in a browser tab has an anti-abuse check that compares the browser's identity
      Then the check is not failed because the app changed how the browser calls itself

    @backlog @desktop
    Scenario: Each profile keeps its own sign-ins
      Given the user is signed in to a site in the default profile
      When a browser tab opens the same site in another profile
      Then the user is not signed in there

    @backlog @desktop
    Scenario: A private profile forgets everything when the app quits
      Given the user browsed in a private profile
      When the app is quit and started again
      Then none of that profile's cookies or site data are left

    @backlog @desktop
    Scenario: The user loads a page by typing its address
      Given a browser tab showing "http://localhost:5173"
      When the user types "localhost:3000" in the tab's address field and presses Enter
      Then the tab loads "http://localhost:3000"
      And the address field shows the page's address

    @backlog @desktop
    Scenario: Escape puts the page's address back in the address field
      Given a browser tab showing "http://localhost:5173"
      And the user has typed a different address in the field
      When the user presses Escape
      Then the field shows "http://localhost:5173" again
      And the field no longer has focus

    @backlog @desktop
    Scenario: Focusing the address field selects the whole address
      Given a browser tab showing "http://localhost:5173"
      When the user focuses the address field
      Then the whole address is selected, ready to be replaced

    @backlog @desktop
    Scenario Outline: Back and forward are offered only where the tab can go
      Given a browser tab whose page <history>
      Then going back is <back>
      And going forward is <forward>

      Examples:
        | history                                      | back        | forward     |
        | is the only one it has shown                 | unavailable | unavailable |
        | follows an earlier page                      | available   | unavailable |
        | is the first page, reached by going back     | unavailable | available   |

    @backlog @desktop
    Scenario: Reloading becomes stopping while the page loads
      Given a browser tab whose page is still loading
      Then the tab offers to stop loading instead of reloading
      When the user stops the load
      Then the tab keeps what had loaded
      And the tab offers to reload again

    @backlog @desktop
    Scenario Outline: Reload and editing shortcuts work inside the page
      Given a browser tab showing a page and the focus is in the page
      When the user presses <keys>
      Then <result>

      Examples:
        | keys                           | result                                              |
        | Ctrl or Command+R              | the page reloads                                    |
        | Ctrl or Command+Shift+R        | the page handles the key itself and is not reloaded |
        | Ctrl or Command+C, X, V or A   | the page's selection is copied, cut, pasted or selected |
        | Ctrl or Command+Z              | the page's last edit is undone                      |
        | Ctrl+Y on Windows              | the page's undone edit is redone                    |
        | Command+Option+Shift+V on macOS | the clipboard is pasted without its formatting     |
        | any other key                  | the page alone handles it and the app's menu does not |

    @backlog @desktop
    Scenario: The mouse's back and forward buttons move through the tab's history
      Given a browser tab showing a page that has a page before it
      When the user presses the mouse's back button over the page
      Then the tab goes back one page
      And a page the tab cannot go back from does nothing

    @backlog @desktop
    Scenario: The mouse's back button only moves the tab it is pressed over
      Given two browser tabs, each with a page before it
      When the user presses the mouse's back button over one of them
      Then only that tab goes back

    @backlog @desktop
    Scenario: The user opens a tab's page in the system browser
      Given a browser tab showing "http://localhost:5173"
      When the user opens the page in the system browser
      Then the system browser opens "http://localhost:5173"
      And the tab keeps showing the page

    @backlog @desktop
    Scenario: A tab's page can be reloaded without the cache
      Given a browser tab showing a page the browser has cached
      When the user chooses a hard reload
      Then the tab fetches the page and its files again instead of using the cache

    @backlog @desktop
    Scenario: The user opens the developer tools for a tab
      Given a browser tab showing a page
      When the user opens the developer tools
      Then the developer tools open for that tab's page

    @backlog @desktop
    Scenario Outline: A tab can follow the system or force a light or dark appearance
      Given a browser tab showing a page that adapts to the color scheme
      When the user sets the tab's appearance to "<appearance>"
      Then the page renders in <scheme>
      And the other tabs of the thread keep their own appearance

      Examples:
        | appearance | scheme                |
        | System     | the system's scheme   |
        | Light      | the light scheme      |
        | Dark       | the dark scheme       |

    @backlog @desktop
    Scenario: Clearing cookies only affects the tab's own profile
      Given the user has the browser profiles "Personal" and "Work"
      And a browser tab under "Work" and another under "Personal" are signed in
      When the user clears cookies from the "Work" tab's menu
      Then the "Work" profile is signed out
      And the "Personal" profile stays signed in

    @backlog @desktop
    Scenario: Clearing the cache only affects the tab's own profile
      Given a browser tab under the profile "Work" and another under "Personal"
      When the user clears the cache from the "Work" tab's menu
      Then the "Work" profile fetches its pages again
      And the "Personal" profile keeps its cache

    @backlog @desktop
    Scenario: A tab's menu names the profile its actions apply to
      Given a browser tab under the profile "Work"
      When the user opens the tab's menu
      Then the menu is headed "Profile: Work"
      And it offers clearing that profile's cookies and cache

    @backlog @desktop
    Scenario: A tab's page actions wait until its page has opened
      Given the MC lists a browser tab the desktop has not opened yet
      When the user opens the tab's menu
      Then hard reload, developer tools, appearance, zoom, cookies and cache are listed but cannot be chosen

    @backlog @desktop
    Scenario: The user captures a screenshot of the page
      Given a browser tab showing a page
      When the user captures a screenshot
      Then the user sees "Screenshot saved"
      And the toast offers to copy the image, copy its path and reveal it in the file manager

    @backlog @desktop
    Scenario: A copied screenshot path or image is confirmed in the toast
      Given the user just captured a screenshot
      When the user copies its path from the toast
      Then the toast says "Copied!" for about two seconds
      And the path is on the clipboard

    @backlog @desktop
    Scenario: A screenshot is named for the site it shows
      Given a browser tab showing "https://docs.example.com/guide"
      When the user captures a screenshot
      Then the saved file's name includes "docs-example-com"

    @backlog @desktop
    Scenario Outline: Only the app's own screenshots and recordings can be revealed or copied
      Given a path that is <path>
      When the user asks to reveal it or copy it from a toast
      Then it is refused and nothing is revealed or copied

      Examples:
        | path                                           |
        | a file outside the app's browser artifacts     |
        | a file that is not a picture, for a copied image |

    @backlog @desktop
    Scenario Outline: A screenshot that cannot be taken or copied says what failed
      Given a browser tab showing a page
      And <situation>
      When the user <action>
      Then the user sees "<title>"

      Examples:
        | situation                            | action                           | title                          |
        | the page cannot be captured          | captures a screenshot            | Unable to capture screenshot   |
        | the clipboard refuses the image      | copies the saved screenshot      | Unable to copy screenshot      |
        | the clipboard refuses the path       | copies the saved screenshot path | Unable to copy screenshot path |

    @backlog @desktop
    Scenario: A screenshot cannot be taken of a page that did not load
      Given a browser tab whose page failed to load
      Then capturing a screenshot is unavailable
      And annotating the page says "Page didn't load — pick unavailable until the page renders"

    @backlog @desktop
    Scenario: The user annotates the page from the tab's toolbar
      Given a browser tab showing a page
      When the user chooses to annotate the preview
      Then the toolbar shows that annotating is under way
      And the user can pick elements, regions and drawings on the page
      When the user finishes the annotation
      Then the annotation goes to the draft and the toolbar returns to normal

    @backlog @desktop
    Scenario: Annotating is cancelled from the toolbar or with Escape
      Given the user is annotating a page in a browser tab
      When the user chooses "Cancel annotation" or presses Escape
      Then nothing is added to the draft
      And the toolbar returns to normal

    @backlog @desktop
    Scenario: Annotating the page gives the user's typing position back
      Given the user's cursor is in the composer
      When the user annotates the page and finishes or cancels
      Then the cursor is back in the composer where it was

    @backlog @desktop
    Scenario: An annotation in progress ends when its tab goes away
      Given the user is annotating a page in a browser tab
      When that tab is closed or the user moves to another thread
      Then the annotation ends
      And the toolbar is not left showing that annotating is under way

    @backlog @desktop
    Scenario: A page that navigates away ends the annotation quietly
      Given the user is annotating a page in a browser tab
      When the page navigates before the user finishes
      Then the annotation ends without any message
      And nothing is added to the draft

    @backlog @desktop
    Scenario: Annotating a page does not click through to the page
      Given the user is annotating a page in a browser tab
      When the user clicks a button on the page
      Then the page does not react to the click
      And the pointer is a crosshair over the page

    @backlog @desktop
    Scenario Outline: A letter key switches the annotation tool
      Given the user is annotating a page in a browser tab
      When the user presses "<key>" outside the comment field
      Then the <tool> tool is in use

      Examples:
        | key | tool   |
        | v   | select |
        | r   | region |
        | d   | draw   |
        | e   | erase  |

    @backlog @desktop
    Scenario: Clicking an element picks it and picking another replaces it
      Given the user is annotating a page in a browser tab with the select tool
      And the user picked a heading
      When the user clicks a button
      Then only the button is picked
      When the user holds Shift and clicks the heading
      Then both are picked
      When the user clicks the heading again
      Then the heading is no longer picked

    @backlog @desktop
    Scenario: Dragging a region picks the small elements inside it
      Given the user is annotating a page in a browser tab with the region tool
      When the user drags over an area holding two buttons and a link
      Then the two buttons and the link are picked
      And no region is marked

    @backlog @desktop
    Scenario: A region with no small elements is kept as an area
      Given the user is annotating a page in a browser tab with the region tool
      When the user drags over an empty part of the page
      Then that area is marked as a region of the annotation

    @backlog @desktop
    Scenario: A region picks at most twenty elements
      Given a page with forty small elements in one area
      When the user drags over that area with the region tool
      Then twenty elements are picked, the smallest first

    @backlog @desktop
    Scenario: A tiny drag marks nothing
      Given the user is annotating a page in a browser tab with the region tool or the draw tool
      When the user drags less than three pixels or only clicks
      Then nothing is marked or drawn

    @backlog @desktop
    Scenario: The user draws freehand on the page
      Given the user is annotating a page in a browser tab with the draw tool
      When the user drags across the page
      Then the stroke is drawn in the app's primary colour
      And it becomes part of the annotation

    @backlog @desktop
    Scenario: The eraser removes what is under the pointer
      Given the user picked an element, marked a region and drew a stroke over the same spot
      When the user clicks that spot with the erase tool
      Then the most recently added thing there is removed
      And clicking again removes the next one

    @backlog @desktop
    Scenario: The comment box appears once something is marked
      Given the user is annotating a page in a browser tab
      Then no comment box is shown
      When the user picks an element
      Then a comment box asks the user to "Describe the change…" and is focused
      And attaching is unavailable until something is picked, marked or drawn

    @backlog @desktop
    Scenario Outline: Enter in the comment box attaches or sends
      Given the user marked something on the page and wrote a comment
      When the user presses <keys> in the comment box
      Then <outcome>

      Examples:
        | keys                                  | outcome                                              |
        | Enter                                 | the annotation is attached to the draft              |
        | Command or Ctrl+Enter                 | the annotation is sent at once                       |
        | Shift+Enter                           | the comment gets a new line and nothing is submitted |
        | Enter while composing with an IME     | nothing is submitted                                 |

    @backlog @desktop
    Scenario Outline: An annotation sent at once while the thread cannot take a message is attached instead
      Given the user marked something on the page and wrote a comment
      And <busy>
      When the user sends the annotation at once
      Then the annotation is attached to the draft and nothing is sent
      And the user sees an "info" toast "Annotation attached to draft" saying "Sending is unavailable right now. Finish the current action, then send."

      Examples:
        | busy                                   |
        | another message is still being sent    |
        | the thread is being rewound            |
        | the thread's messages are still loading |

    @backlog @desktop
    Scenario: The page cannot see what the user types in the comment box
      Given the user is annotating a page that listens to every key
      When the user types a comment
      Then the page's own key handlers do not see those keys

    @backlog @desktop
    Scenario: Submitting shows that the page is being captured
      Given the user marked an element and wrote a comment
      When the user attaches the annotation
      Then the button reads "Capturing…" and cannot be pressed again
      And the annotation carries the comment and marks as they were when attached, even if the user kept editing

    @backlog @desktop
    Scenario: A picked element is described even when its component cannot be read
      Given the user picked an element on a page whose component details do not respond within five seconds
      When the user attaches the annotation
      Then the annotation carries the element's tag, the start of its HTML and its area
      And the annotation is still attached

    @backlog @desktop
    Scenario: The annotation's picture covers what was marked with some margin
      Given the user marked an element near the edge of the page
      When the user attaches the annotation
      Then the picture covers the marked element with twenty pixels around it, kept inside the page

    @backlog @desktop
    Scenario: The comment box sits next to what was marked
      Given the user marked an element on a page
      Then the comment box is shown beside it, on the side with most room inside the page

    @backlog @desktop
    Scenario: Expanding the annotation editor shows the picked element's styles
      Given the user picked an element
      When the user expands the annotation editor
      Then its font, size, weight, line height, colours, opacity, radius, border, width, height, padding, margin and gap are shown with their current values
      And the editor can be dragged elsewhere on the page

    @backlog @desktop
    Scenario: The editor offers no styles for a marked region or a drawing
      Given the user marked only a region and drew a stroke
      When the user expands the annotation editor
      Then there are no styles to change

    @backlog @desktop
    Scenario: A style change shows on the page and is carried as before and after
      Given the user picked a button and expanded the annotation editor
      When the user changes its background colour
      Then the page shows the new colour at once
      And the annotation lists the change from the old colour to the new one for that element

    @backlog @desktop
    Scenario: Width and height follow each other while the aspect ratio is locked
      Given the user picked an image and expanded the annotation editor
      When the user changes the width
      Then the height changes to keep the picture's proportions
      When the user unlocks the aspect ratio and changes the width
      Then the height stays

    @backlog @desktop
    Scenario: The page is put back when the annotation ends
      Given the user changed the style of a picked element
      When the user cancels, attaches or sends the annotation
      Then the element looks as it did before

    @backlog @desktop
    Scenario: Unpicking an element undoes its style changes
      Given the user changed the style of a picked element
      When the user picks it again to unpick it
      Then the element looks as it did before
      And the annotation no longer lists its style changes

    @backlog @desktop
    Scenario: Starting a new annotation replaces one under way
      Given the user is annotating a page in a browser tab
      When the user starts annotating again
      Then the earlier marks and style changes are gone
      And only one annotation is under way

    @backlog @desktop
    Scenario: The annotation tools follow the app's theme
      Given the user is annotating a page in a browser tab
      When the user changes the app's colour theme
      Then the annotation tools take the new colours without ending the annotation

    @backlog @desktop
    Scenario: Holding Shift while choosing the camera records instead of taking a screenshot
      Given a browser tab showing a page
      When the user chooses the camera while holding Shift
      Then the tab starts recording
      And the camera now offers to stop the recording

    @backlog @desktop
    Scenario: The user records the page and saves the recording
      Given a browser tab showing a page
      When the user starts a recording of the tab
      Then the tab shows that it is recording
      When the user stops the recording
      Then the user sees "Recording saved"
      And the toast offers to reveal the file and copy its path

    @backlog @desktop
    Scenario Outline: A recording that cannot be stopped or copied says what failed
      Given the user is recording a browser tab
      And <situation>
      When the user <action>
      Then the user sees "<title>"

      Examples:
        | situation                             | action                          | title                         |
        | the desktop cannot finish the file    | stops the recording             | Unable to stop recording      |
        | the clipboard refuses the path        | copies the saved recording path | Unable to copy recording path |

    @backlog @desktop
    Scenario: A recording that cannot start says so, unless the user cancelled it
      Given a browser tab showing a page
      When the desktop cannot start the recording
      Then the user sees "Unable to start recording"
      When the user cancels the recording's choice of what to share
      Then the user is not told of any failure

    @backlog @desktop
    Scenario: Only one browser tab is recorded at a time
      Given tab "Docs" is being recorded
      When the user starts a recording of tab "App"
      Then the recording does not start
      And the user is told that "App" cannot be recorded while "Docs" is already being recorded

    @backlog @desktop
    Scenario: A recording shows the keys the user presses when asked to
      Given the user has chosen to show pressed keys in recordings
      And the user is recording a browser tab
      When the user presses Command and K in the page
      Then the recording shows a badge with that key chord near the bottom of the page
      And the badge goes away shortly after the keys are released

    @backlog @desktop
    Scenario: A recording marks where the mouse is pressed when asked to
      Given the user has chosen to show mouse presses in recordings
      And the user is recording a browser tab
      When the user presses and holds the mouse on the page
      Then the recording shows a ring at that spot for as long as the button is held
      When the user releases the button
      Then the ring fades out within a second

    @backlog @desktop
    Scenario: A recording shows nothing extra when both options are off
      Given the user has chosen to show neither pressed keys nor mouse presses
      When the user records a browser tab
      Then the recording is the page as it appears, with nothing drawn over it

    @backlog @desktop
    Scenario Outline: Keys typed into <place> are never shown in a recording
      Given the user is recording a browser tab with pressed keys shown
      When the user types into <place>
      Then the recording shows no key badges for those keys

      Examples:
        | place                           |
        | a password field                |
        | a field inside an embedded frame |
        | a field built as a custom element |

    @backlog @desktop
    Scenario: A touch screen contact is not drawn as the mouse pointer in a recording
      Given the user is recording a browser tab
      When the page receives a touch rather than a mouse
      Then the recording draws no pointer for it

    @backlog @desktop
    Scenario: A page cannot start a recording by itself
      Given a page in a browser tab runs a script that asks to capture the screen
      Then no recording starts
      And nothing about the user's screen is shared with the page

    @backlog @desktop
    Scenario: Closing the app window stops its recordings and closes popped-out previews
      Given a browser tab is being recorded and another is open in its own window
      When the user closes the app window
      Then the recording is stopped and kept
      And the separate window closes

    @backlog @desktop
    Scenario: A recording's decorations are never part of the page
      Given the user is recording a browser tab with pressed keys shown
      Then the page itself shows no recording controls or badges
      And only the saved video carries them

    @backlog @desktop
    Scenario: An agent's recording stops the only tab being recorded
      Given an agent is recording one tab of the thread, not the tab it is acting on
      When the agent stops the recording without naming a tab
      Then the recording of that tab is stopped

    @backlog @desktop
    Scenario: Stopping a recording of a tab that is not being recorded fails
      Given tab "Docs" is being recorded
      When an agent stops the recording of tab "App"
      Then the tool fails saying no recording is active for that tab
      And the recording of "Docs" keeps going

    @backlog @desktop
    Scenario: A popped-out preview that cannot be updated says so
      Given a browser tab is open in its own window
      When the desktop cannot update that window
      Then the user sees "Unable to update popped-out preview"

    @backlog @desktop
    Scenario: A tab's page can be moved to its own window and back
      Given a browser tab showing a page
      When the user opens the tab in a separate window
      Then the page shows in its own window and the tab's menu offers to close that window
      When the user closes the separate window
      Then the page is back beside the thread

    @backlog @desktop
    Scenario: A popped-out preview stays above other windows and is named for the page
      Given a browser tab showing a page titled "Checkout"
      When the user opens the tab in a separate window
      Then the window stays on top of other windows
      And its title is "Preview · Checkout"
      And a page without a title gives the window the title "Browser preview"

    @backlog @desktop
    Scenario: A popped-out preview keeps the page's proportions
      Given a browser tab open in its own window
      When the user resizes that window
      Then the window keeps the page's shape
      And it cannot be made smaller than a usable minimum

    @backlog @desktop
    Scenario: A popped-out preview follows the page when its shape changes
      Given a browser tab open in its own window
      When the page's size changes
      Then the window takes the page's new shape

    @backlog @desktop
    Scenario: A popped-out preview closes with its tab
      Given a browser tab open in its own window
      When the tab is closed
      Then the separate window closes

    @backlog @desktop
    Scenario: The user shows a device toolbar above a tab's page
      Given a browser tab that fills its space
      When the user shows the device toolbar from the tab's menu
      Then the toolbar offers "Responsive" and the named device sizes
      And the page keeps its current size until the user picks another
      When the user hides the device toolbar
      Then the page fills the tab again

    @backlog @desktop
    Scenario: Each tab keeps its own device size
      Given the thread has two browser tabs
      When the user picks the "iPhone SE" size in the first tab
      Then the second tab still fills its space

    @backlog @desktop
    Scenario: The user previews the page at a size of their own
      Given a browser tab with the device toolbar shown
      When the user types a width of 500 and a height of 800
      Then the page renders at 500 by 800

    @backlog @desktop
    Scenario Outline: A custom size outside what the preview can render is not applied
      Given a browser tab with the device toolbar shown
      When the user types a width of <width> and a height of <height>
      Then the page keeps its previous size

      Examples:
        | width | height |
        | 239   | 800    |
        | 800   | 239    |
        | 3841  | 800    |
        | 3840  | 2161   |

    @backlog @desktop
    Scenario: The aspect ratio can be locked while resizing
      Given a browser tab at 400 by 800 with the device toolbar shown
      When the user locks the aspect ratio and changes the width to 200
      Then the height becomes 400
      When the user unlocks the aspect ratio
      Then changing the width leaves the height alone

    @backlog @desktop
    Scenario: The aspect ratio cannot be locked on a size that cannot be used
      Given a browser tab with the device toolbar shown
      And the user has typed a width of 100
      Then locking the aspect ratio is unavailable

    @backlog @desktop
    Scenario: The user rotates the previewed device
      Given a browser tab at 390 by 844 with the device toolbar shown
      When the user rotates the viewport
      Then the page renders at 844 by 390

    @backlog @desktop
    Scenario: The toolbar waits while a new size is being applied
      Given the user has just picked a device size for a tab
      When the MC has not confirmed the size yet
      Then the toolbar's size controls cannot be used until it does

    @backlog @desktop
    Scenario: A size the desktop cannot apply says so and is undone
      Given a browser tab with the device toolbar shown
      When the desktop cannot resize the page to the size the user picked
      Then the user sees "Unable to resize browser viewport"
      And the tab returns to its previous size

    @backlog @desktop
    Scenario: The user drags the edge of a device-sized page to resize it
      Given a browser tab at 400 by 800 with the device toolbar shown
      When the user drags the page's right edge 100 pixels wider
      Then the page renders at 500 by 800 and the toolbar shows the new size

    @backlog @desktop
    Scenario Outline: The arrow keys resize a device-sized page from one of its edges
      Given a browser tab at 400 by 800 with the device toolbar shown
      And the keyboard focus is on the page's right edge
      When the user presses <keys>
      Then the page renders at <size> once the user pauses

      Examples:
        | keys                  | size       |
        | Right arrow           | 410 by 800 |
        | Shift and Right arrow | 450 by 800 |
        | Left arrow            | 390 by 800 |

    @backlog @desktop
    Scenario: A device-sized page that is bigger than the tab is shown scaled down
      Given a browser tab 600 pixels wide and 500 pixels tall with the device toolbar shown
      When the user previews the page at 1200 by 900
      Then the page is shown smaller, centred and in proportion, so all of it fits in the tab
      And the page still renders at 1200 by 900

    @backlog @desktop
    Scenario: A page that fills its space cannot be resized from its edges
      Given a browser tab that fills its space
      Then the page has no edges to drag or to move with the keyboard

    @backlog @desktop
    Scenario: Changing the size another way ends a drag in progress
      Given the user is dragging the edge of a device-sized page
      When the page's size is changed from the device toolbar
      Then the drag is dropped
      And the page keeps the size that was chosen

    @backlog @desktop
    Scenario: The device toolbar is closed from its own control
      Given a browser tab with the device toolbar shown
      When the user closes the device toolbar
      Then the page fills the tab again

    @backlog @desktop
    Scenario: A new browser tab with nothing to suggest says how to start
      Given the thread's project has no running dev server and no recent pages
      When the user opens a new browser tab
      Then the tab says "No preview yet"
      And it says to type a URL above or run a dev script and that localhost servers will show up automatically

    @backlog @desktop
    Scenario: A recent page can be taken off the new tab's list
      Given a new browser tab lists the recent page "http://localhost:5173"
      When the user removes "http://localhost:5173" from the recent pages
      Then it is no longer listed
      And it does not come back when the user opens another new tab

    # Dropped: contradicts the passing "A new browser tab offers local servers and recent pages"
    # (apps/desktop-qt/src/native/ThreadPreviews.h maxRecents = 10). The web's empty state showed
    # eight (apps/web/src/components/preview/PreviewEmptyState.tsx); revive this if eight is wanted.
    @dropped @desktop
    Scenario: A new browser tab shows at most eight recent pages
      Given the thread's project has ten recently visited pages
      When the user opens a new browser tab
      Then the eight most recent pages are listed

    @backlog @desktop
    Scenario Outline: A suggested local server shows what is serving it
      Given a dev server on port 5173 whose process is <process>
      When the user opens a new browser tab
      Then the server is listed as "<title>" with "localhost:5173" beneath it
      And its row shows the site's icon

      Examples:
        | process | title     |
        | vite    | vite      |
        | unknown | Listening |

    @backlog @desktop
    Scenario: A recent page shows its title, its address and when it was visited
      Given the user visited "http://localhost:5173/docs?page=2" titled "Docs" a few minutes ago
      When the user opens a new browser tab
      Then the page is listed as "Docs"
      And beneath it are "localhost:5173/docs?page=2" and how long ago it was visited
      And the row offers to remove it from history

    @backlog @desktop
    Scenario: A recent page without a title is listed by its address
      Given the user visited "http://localhost:5173/" which has no title
      When the user opens a new browser tab
      Then the page is listed as "localhost:5173"

    @backlog @desktop
    Scenario: Opening a suggested server visits it and shows it beside the thread
      Given a new browser tab suggests a dev server on port 5173
      When the user opens the suggestion
      Then the page opens in a browser tab beside the thread
      And the server is remembered among the recent pages

    @backlog @desktop
    Scenario: Two configured addresses that differ only by their anchor are one suggestion
      Given the project configures "http://localhost:3000/app#a" and "http://localhost:3000/app#b" as preview addresses
      When the user opens a new browser tab
      Then the page "http://localhost:3000/app" is suggested once, with the anchor of the first

    @backlog @desktop
    Scenario: An unreachable page's details suggest what to check
      Given a browser tab whose page failed to load
      When the user chooses "Details"
      Then the tab suggests checking the connection, confirming the dev server is running and checking the proxy and the firewall
      When the user chooses "Hide details"
      Then the suggestions are hidden

    @backlog @desktop
    Scenario: A page whose engine crashes is reloaded a few times
      Given a browser tab showing a page
      When the page's renderer crashes
      Then the tab reloads the page after a short wait
      When it crashes again three times in 30 seconds
      Then the tab stops reloading and shows the page as unreachable

    @backlog @desktop
    Scenario: A page that keeps crashing is retried again after a quiet half minute
      Given a browser tab that stopped reloading after repeated crashes
      When 30 seconds pass and the page crashes again
      Then the tab reloads it once more

    @backlog @desktop
    Scenario: Pages the user visits are remembered per project for new tabs
      Given the user visits "http://localhost:5173" in a browser tab of a project
      When the user opens a new browser tab in another thread of that project
      Then "http://localhost:5173" is among the recent pages

    @backlog @desktop
    Scenario: The history of one project does not appear in another
      Given the user visited "http://localhost:5173" in a project's browser tab
      When the user opens a new browser tab in a different project
      Then "http://localhost:5173" is not among the recent pages

    @backlog @desktop
    Scenario Outline: Recent pages are kept tidy
      Given the user visits <visit>
      Then the recent pages list <listed>

      Examples:
        | visit                                                          | listed                                           |
        | "http://localhost:5173" then "http://127.0.0.1:5173"           | one page for that local server                   |
        | "https://user:secret@example.com/docs"                         | "https://example.com/docs" without credentials   |
        | the same page twice                                            | the page once, as the most recent                |

    @backlog @desktop
    Scenario: A project remembers its last fifty pages
      Given the user has visited fifty one different pages in a project
      Then the recent pages remember the fifty most recent ones

    @backlog @desktop
    Scenario: The desktop remembers the history of the twenty most recently used projects
      Given the user has browsed in twenty one projects
      Then the history of the project used longest ago is forgotten

    @backlog @desktop
    Scenario: A page's icon is remembered after its tab closes
      Given a browser tab loaded a page that gave its own icon
      When the tab is closed and the page is later listed among recent pages
      Then it shows the icon it gave

    @backlog @desktop
    Scenario: A local page's icon is not shared with another project
      Given a browser tab on "localhost:5173" in one project loaded a page that gave its own icon
      When a browser tab in another project lists "localhost:5173"
      Then it does not show the first project's icon

    @backlog @desktop
    Scenario: The desktop remembers the icons of the forty most recent sites
      Given the user has browsed forty one sites that gave icons
      Then the icon of the site used longest ago is forgotten

    @backlog @desktop
    Scenario: The zoom level is shown briefly after it changes
      Given a browser tab at 100% zoom
      When the user zooms in
      Then the tab shows "110%" for about a second and a half
      And then the indicator goes away

    @backlog @desktop
    Scenario: A floating preview starts small and keeps the page's shape
      Given a browser tab showing a portrait page
      When the user floats the preview
      Then the player is about 320 pixels wide at the page's aspect ratio
      And it keeps a small gap from the edges of the conversation

    @backlog @desktop
    Scenario: The user moves and resizes the floating preview
      Given a floating preview
      When the user drags the player to another corner
      Then the player stays where it was dropped, inside the conversation
      When the user drags a corner outward
      Then the player grows keeping the page's aspect ratio
      But it never becomes smaller than a small minimum

    @backlog @desktop
    Scenario: A floating preview moves aside when the composer grows
      Given a floating preview in the lower part of the conversation
      When the composer grows with a long draft
      Then the player keeps clear of the composer

    @backlog @desktop
    Scenario: A floating preview keeps clear of the details card
      Given a floating preview and the thread's details are open
      Then the player does not cover the details card

    @backlog @desktop
    Scenario: A floating preview is closed from its own controls
      Given a floating preview
      When the user closes the floating preview
      Then the player disappears
      And the browser tab is still open in the right panel

    @backlog @desktop
    Scenario: A floating preview moves into the right panel
      Given a floating preview
      When the user opens it in the right panel
      Then the player disappears
      And the right panel shows that browser tab

    @backlog @desktop
    Scenario: A floating preview can be popped into a separate window
      Given a floating preview whose page has opened
      When the user pops the preview into a separate window
      Then the page plays in a window of its own
      And the player offers to close the popped-out preview

    @backlog @desktop
    Scenario: Popping a preview out is unavailable before its page has opened
      Given a floating preview whose page the desktop has not opened yet
      Then popping the preview out cannot be chosen

    @backlog @desktop
    Scenario: A floating preview whose page is not open yet says it is reconnecting
      Given a floating preview of a browser tab the desktop has not opened yet
      Then the player says "Reconnecting preview…"
      When the desktop opens the page
      Then the player shows the page

    @backlog @desktop
    Scenario: A floating preview shows that it is being recorded
      Given a floating preview
      When the page is being recorded
      Then the player shows a recording indicator
      When the recording stops
      Then the indicator goes away

    @backlog @desktop
    Scenario: Each thread has its own floating preview
      Given a floating preview in one thread
      When the user opens another thread
      Then the other thread has no floating preview unless it was floated there
      When the user returns to the first thread
      Then its floating preview is where it was left

    @backlog @desktop
    Scenario: Floating another tab keeps the player where the user put it
      Given a floating preview of one browser tab that the user moved and resized
      When the user floats another tab of the same thread
      Then the player shows the other tab
      And it keeps its position and width

    @backlog @desktop
    Scenario Outline: Closing the right panel on a live page or device floats it
      Given the right panel shows <surface>
      When the user closes the right panel
      Then <surface> floats over the conversation instead of being dropped

      Examples:
        | surface                     |
        | a browser tab               |
        | a device's screen           |

    @backlog @desktop
    Scenario: A floating device closes when its session ends
      Given a floating preview of a device
      When the device's session is closed
      Then the floating preview closes with it

    @backlog @desktop
    Scenario: A floating preview closes when its tab is closed
      Given a floating preview of a browser tab
      When that browser tab is closed
      Then the floating preview closes with it

    @backlog @desktop
    Scenario: A late drag does not move a player that now shows something else
      Given the user is dragging a floating preview of one tab
      When the player is switched to another tab before the drag ends
      Then the dropped position is not applied to the other tab's player

    @backlog @desktop
    Scenario Outline: A link opens where the user's default and the click say
      Given the user's links open in <default>
      When the user <click> a web link in the chat or the terminal
      Then the link opens in <target>

      Examples:
        | default             | click                       | target               |
        | HAL-C2's browser    | clicks                      | a tab beside the thread |
        | HAL-C2's browser    | clicks with Cmd or Ctrl on  | the system browser   |
        | the default browser | clicks                      | the system browser   |

    @backlog @desktop
    Scenario Outline: A link the in-app browser cannot load goes to the system
      Given the user's links open in HAL-C2's browser
      When the user clicks the link "<link>"
      Then the system opens it instead of a browser tab

      Examples:
        | link                      |
        | mailto:team@example.com  |
        | vscode://file/src/app.ts |

    @backlog @desktop
    Scenario: A link clicked where no thread is open goes to the system browser
      Given the user's links open in HAL-C2's browser
      And no thread is open
      When the user clicks a web link
      Then the link opens in the system browser

    @backlog @desktop
    Scenario: A link clicked just after launch follows the saved choice
      Given the user chose to open links in HAL-C2's browser in an earlier session
      When the user clicks a web link before the saved settings have loaded
      Then the link opens in a tab beside the thread once they have

    @backlog @desktop
    Scenario: A link is not opened when the saved choice cannot be read
      Given the saved settings cannot be read
      When the user clicks a web link
      Then the link is not opened in a browser the user did not choose

    @backlog @desktop
    Scenario: A page opened from the workspace loads the files next to it
      Given the project has "public/index.html" that uses "public/app.css" and "public/app.js"
      When the user opens "public/index.html" in the preview browser
      Then the page loads its stylesheet and script from the workspace

    @backlog @desktop
    Scenario: A file outside the workspace is shown on its own
      Given the user has the page "/tmp/report.html" outside the project
      When the user opens it in the preview browser
      Then the page is shown without the files next to it

    @backlog @desktop
    Scenario: A file opened in the preview uses the user's browser defaults
      Given the default browser viewport is 390 by 844 and the default profile is "Work"
      When the user opens "docs/manual.pdf" in the preview browser
      Then the tab opens at 390 by 844 under the profile "Work"

    @backlog @desktop
    Scenario: A file cannot be opened in the preview when saved browser settings cannot be read
      Given the saved browser settings cannot be loaded
      When the user opens "public/index.html" in the preview browser
      Then the user is told "Saved browser settings could not be loaded."

    @backlog @desktop
    Scenario: A page typed into a tab that cannot be opened says so
      Given the saved browser settings cannot be loaded
      And the thread has no open browser tab
      When the user types an address in the new browser tab's address bar and submits it
      Then the user sees "Unable to open browser" with the reason

    @backlog @desktop
    Scenario: A file cannot be opened in the preview where there is no integrated browser
      Given the desktop has no integrated browser
      When the user opens "public/index.html" in the preview browser
      Then the user is told "The integrated browser is unavailable in this runtime."

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
