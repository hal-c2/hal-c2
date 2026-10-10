# Sources:
#   apps/mobile/src/connection/app-state-wakeups.ts (probe vs reconnect after 10 seconds)
#   apps/mobile/src/connection/background-activity.ts
#   apps/mobile/src/connection/background-activity-scopes.ts
#   apps/mobile/src/features/connection/EnvironmentConnectionNotice.tsx (cached data notices)
#   apps/mobile/src/features/threads/floating-working-status.ts (tap to reconnect)
#   apps/mobile/src/features/threads/ThreadRouteScreen.tsx (thread unavailable, reconnect or manage environments, restore draft failure)
#   apps/mobile/src/features/threads/ThreadDetailScreen.tsx (conversation could not be displayed)
#   apps/mobile/src/components/RenderErrorBoundary.tsx, apps/mobile/src/Stack.tsx (screen failed to draw, exits, pane failures)
#   apps/mobile/src/features/threads/ThreadCreationFailedCard.tsx (task that could not be started)
#   apps/mobile/src/features/threads/floating-working-control.tsx (agents and queue shortcuts, compacting)
#   apps/mobile/src/features/threads/threadContentPresentation.ts (loading, not cached, deleted)
#   apps/mobile/src/features/settings/SettingsClientStorageRouteScreen.tsx
#   apps/mobile/src/state/client-cache-state.ts
#   apps/mobile/src/persistence/mobile-database.ts
#   apps/mobile/src/connection/catalog-store.ts (the record of paired environments, earlier-format migration)
#   apps/mobile/src/Stack.tsx (outbox drain worker)
#   apps/mobile/src/state/thread-outbox.ts, thread-outbox-model.ts, thread-outbox-storage.ts (waiting messages kept on disk)
#   apps/mobile/src/state/use-thread-outbox-drain.ts (delivery order, retry delay, refused and oversized messages)
#   apps/mobile/src/state/pending-thread-creation.ts, recover-failed-thread-draft.ts (refused new tasks)
#   apps/mobile/src/state/edit-pending-thread-message.ts (pull a waiting message back)
#   apps/mobile/src/state/use-composer-drafts.ts, apps/mobile/src/features/cloud/cloud-drafts.ts (unsent work across sign-out)
# MC reconnection and replay are specified in features/connections/. This file covers
# what a phone does as the system suspends and resumes it, and what it keeps offline.

Feature: Staying useful through backgrounding and bad connections
  Phones suspend apps and lose the network often. The app keeps what it last saw, says
  plainly when it is stale, and catches up quickly when it can.

  Background:
    Given the phone is paired with "My MacBook"
    And the user has opened the thread "Fix checkout" before

  @backlog @mobile
  Scenario: Returning to the app after a moment checks the connection quickly
    Given the user switched away from the app for 5 seconds
    When the user returns to the app
    Then the phone checks the existing connection instead of reconnecting

  @backlog @mobile
  Scenario: Returning to the app after a longer break reconnects
    Given the user switched away from the app for a minute
    When the user returns to the app
    Then the phone reconnects to "My MacBook"
    And "Fix checkout" catches up on what happened while the app was away

  @backlog @mobile
  Scenario: Cached threads open without a connection
    Given "My MacBook" is unreachable
    When the user opens "Fix checkout"
    Then the last known conversation is shown
    And the user is told cached data remains available until the connection returns

  @backlog @mobile
  Scenario: A thread never opened before cannot be shown offline
    Given "My MacBook" is unreachable
    When the user opens a thread the phone has never loaded
    Then the user is told the thread will load when the connection returns

  @backlog @mobile
  Scenario: The app keeps retrying on its own
    Given "My MacBook" is unreachable
    Then the user is told the app will keep retrying automatically
    When "My MacBook" becomes reachable
    Then the thread list is current again without the user doing anything

  @backlog @mobile
  Scenario: A working agent's status offers to reconnect when the connection drops
    Given an agent is working in "Fix checkout"
    When the connection to "My MacBook" drops
    Then the working status shows the connection is lost
    When the user taps the working status
    Then the phone reconnects to "My MacBook"

  @backlog @mobile
  Scenario Outline: The thread's status says how the connection stands
    Given <situation>
    When the user is in "Fix checkout"
    Then the status reads "<label>"

    Examples:
      | situation                                        | label                                      |
      | the phone is connecting to "My MacBook"          | Reconnecting to My MacBook...              |
      | the phone retries after a failed attempt         | Failed to connect. Retrying My MacBook...  |
      | the phone has no network                         | You are offline                            |
      | "My MacBook" runs a version this app cannot use  | Client not supported                       |
      | "My MacBook" refused the connection              | Failed to connect to My MacBook            |

  @backlog @mobile
  Scenario Outline: The thread's status says what the phone is doing while the conversation loads
    Given the phone is connected to "My MacBook"
    And <situation>
    When the user opens "Fix checkout"
    Then the status reads "<label>"

    Examples:
      | situation                                              | label                |
      | the phone has no messages of "Fix checkout" yet        | Loading messages...  |
      | the phone shows cached messages while it catches up    | Syncing messages...  |

  @backlog @mobile
  Scenario: The thread's status says when the agent is compacting the conversation
    Given the agent is compacting the conversation of "Fix checkout"
    When the user is in "Fix checkout"
    Then the status reads "Compacting…"

  @backlog @mobile
  Scenario: A new task's status says it is being prepared before the thread exists
    Given the user started a new task in a new worktree and "My MacBook" has not created the thread yet
    Then the status reads "Setting up worktree…"
    When the task is not using a new worktree
    Then the status reads "Starting…"

  @backlog @mobile
  Scenario: The thread's status gives way to a pending question or approval
    Given an agent is working in "Fix checkout"
    When the agent asks the user to approve a command
    Then the working status is not shown while the approval waits

  @backlog @mobile
  Scenario: The thread's status leads to the subagents and the queue
    Given an agent is working in "Fix checkout" with two subagents and three queued messages
    Then the status offers to open the agents and says "3 queued"
    When the user chooses the queued messages
    Then the queue opens for reordering, steering or removal

  @backlog @mobile
  Scenario: A conversation that cannot be loaded says why
    Given "My MacBook" is connected and refuses to send "Fix checkout"
    When the user opens "Fix checkout"
    Then the user is told the conversation could not be loaded and the reason given

  @backlog @mobile
  Scenario: A conversation the phone cannot draw says so and leaves the rest of the thread usable
    Given "Fix checkout" holds a message the phone fails to draw
    When the user opens "Fix checkout"
    Then the user is told the conversation couldn't be displayed
    And the composer and the thread's header are still usable

  @backlog @mobile
  Scenario: A thread missing from a connected environment offers to reconnect it
    Given "My MacBook" is saved but "Fix checkout" is not in the snapshot the phone has of it
    And the phone has finished loading
    When the user opens a link to "Fix checkout"
    Then the user is told the thread is not available in the current snapshot
    And the user is offered to reconnect "My MacBook"

  @backlog @mobile
  Scenario: A thread of an environment the phone no longer has offers the environment settings
    Given the phone has no saved environment that holds "Fix checkout"
    When the user opens a link to "Fix checkout"
    Then the user is told the thread is not available in the current snapshot
    And the user is offered to manage environments

  @backlog @mobile
  Scenario: A thread link is not called unavailable while the phone is still loading
    Given the phone is still loading its environments
    When the user opens a link to "Fix checkout"
    Then the user sees that the thread is opening
    And the thread is not reported unavailable

  @backlog @mobile
  Scenario: A thread deleted elsewhere is reported when it is open
    Given "Fix checkout" is open on the phone
    When "Fix checkout" is deleted on another device
    Then the user is told the thread was deleted or is no longer available

  @backlog @mobile
  Scenario: Messages written offline are sent in order once the connection returns
    Given "My MacBook" is unreachable
    When the user sends "first" and then "second" in "Fix checkout"
    And "My MacBook" becomes reachable
    Then "first" is sent before "second"

  @backlog @mobile
  Scenario: A message the environment rejects after reconnecting is kept for the user
    Given the user sent "first" while offline
    And the environment rejects "first" when the connection returns
    Then "first" is no longer waiting to send
    And "first" is back in the draft of its thread, where the user can edit or delete it

  @backlog @mobile
  Scenario: The user sees how much each environment stores on the phone
    When the user opens client storage settings
    Then the storage used by "My MacBook" is shown

  @backlog @mobile
  Scenario: Clearing one environment's cache keeps the connection
    When the user clears the cache for "My MacBook" and confirms
    Then offline threads for "My MacBook" are removed from the phone
    And the phone stays paired with "My MacBook"

  @backlog @mobile
  Scenario: Clearing all client caches asks first
    When the user asks to clear all client caches
    Then the user is asked to confirm
    When the user cancels
    Then nothing is cleared

  @backlog @mobile
  Scenario: The splash screen waits for the user's appearance settings
    Given the user chose a dark theme
    When the app starts
    Then the first screen the user sees already uses the dark theme

  @backlog @mobile
  Scenario: Drafts are saved before the system suspends the app
    Given the user has typed "add a test" in "Fix checkout"
    When the system suspends and later terminates the app
    And the user opens the app again
    Then the draft in "Fix checkout" still reads "add a test"

  @backlog @mobile
  Scenario: Messages waiting to send survive the app being closed
    Given "My MacBook" is unreachable
    And the user sent "add a test" in "Fix checkout"
    When the system suspends and later terminates the app
    And the user opens the app again
    Then "add a test" is still waiting to send in "Fix checkout"
    When "My MacBook" becomes reachable
    Then "add a test" is sent

  @backlog @mobile
  Scenario: A dropped connection never discards a message waiting to send
    Given the user sent "add a test" in "Fix checkout"
    And the connection to "My MacBook" drops before it answers
    Then "add a test" stays waiting to send
    And the phone tries again with a delay that grows up to 16 seconds

  @backlog @mobile
  Scenario: A new task the environment already created is not created twice
    Given the user started the task "Add search" while "My MacBook" was unreachable
    And "My MacBook" had already created that thread before the phone heard back
    When the phone reconnects
    Then the task is not created a second time
    And the task is no longer listed as pending

  @backlog @mobile
  Scenario: A message for a thread that no longer exists is dropped
    Given the user sent "add a test" to "Fix checkout" while offline
    And "Fix checkout" was deleted from another device
    When the phone reconnects and has the current thread list
    Then "add a test" is not sent
    And "add a test" is no longer waiting to send

  @backlog @mobile
  Scenario: A message is not judged missing before the thread list has loaded
    Given the user sent "add a test" to "Fix checkout" while offline
    And "My MacBook" has reconnected but its thread list has not arrived
    Then "add a test" keeps waiting to send

  @backlog @mobile
  Scenario: A refused message joins what the user has typed in the draft since
    Given the user sent "add a test" in "Fix checkout" while offline
    And the user has typed "also check lint" in the draft of "Fix checkout" since
    When the environment refuses "add a test" when the connection returns
    Then the draft of "Fix checkout" holds "add a test" together with "also check lint"
    And the model and mode the message was sent with are restored with it
    And the user is told why it was refused

  @backlog @mobile
  Scenario: A refused message waits for room in the draft before it returns
    Given the draft of "Fix checkout" holds attachments
    And a refused message carries attachments that together exceed the limit for one message
    Then the message is not restored yet
    And the user is told to remove attachments from the draft first
    When the user removes enough attachments
    Then the refused message returns to the draft

  @backlog @mobile
  Scenario: A new task the environment refuses reopens in the new task editor
    Given the user started the task "Add search" while offline
    And the environment refuses the task when the connection returns
    Then the thread of the task says it could not be sent and why
    When the user reopens it
    Then the new task editor holds the prompt, attachments, project and workspace choices the user had
    And what the user was typing for that project is left alone

  @backlog @mobile
  Scenario: A refused task that cannot be put back in the editor says why and stays in the thread
    Given the environment refused the task "Add search"
    And the phone cannot restore the draft of the task
    When the user chooses to edit the task
    Then the user is told the draft could not be restored and why
    And the thread of the task still offers to edit it

  @backlog @mobile
  Scenario: Work typed into a task that failed to start comes back with it
    Given the user started the task "Add search" and typed more into its thread while it was being set up
    And the environment refuses the task
    When the user reopens the task
    Then the extra text and attachments are in the new task editor
    And the thread's own draft is empty

  @backlog @mobile
  Scenario: A reopened task with too many attachments keeps every file
    Given a refused task has more attachments than one message can carry
    When the user reopens the task
    Then every attachment is still in the editor
    And the user is asked to remove attachments before sending

  @backlog @mobile
  Scenario: A queued file larger than the environment accepts returns to the draft
    Given the user sent a message with a file attached while offline
    And the file is larger than "My MacBook" accepts
    When the phone reconnects
    Then the message is not sent
    And the message and its file are back in the draft
    And the user is told the file is too large

  @backlog @mobile
  Scenario: A queued file is returned when the environment takes no file attachments
    Given the user sent a message with a file attached while offline
    And "My MacBook" does not accept file attachments
    When the phone reconnects
    Then the message is not sent
    And the message and its file are back in the draft
    And the user is told the server does not support file attachments

  @backlog @mobile
  Scenario: Unreadable waiting messages are reported without blocking the others
    Given one waiting message cannot be read from the phone's storage
    When the app loads the waiting messages
    Then the user is told some queued messages could not be loaded
    And the unreadable message and its files are kept on the phone
    And the other waiting messages are still sent
    And the user can dismiss the notice or try loading again

  @backlog @mobile
  Scenario: A waiting message whose model is no longer available goes back to the draft
    Given the user sent "add a test" in "Fix checkout" with an Antigravity model while offline
    And "My MacBook" no longer has that model set up when the connection returns
    Then "add a test" is not sent
    And "add a test" is back in the draft of "Fix checkout"
    And the user is told to set Antigravity up on the desktop or choose another model

  @backlog @mobile
  Scenario: A waiting message keeps trying while the environment's settings have not arrived
    Given the user sent "add a test" in "Fix checkout" while offline
    And "My MacBook" has reconnected but has not yet sent its settings
    Then "add a test" keeps waiting to send
    And the phone tries again with a delay that grows up to 16 seconds
    When the settings arrive
    Then "add a test" is sent

  @backlog @mobile
  Scenario: A waiting message is sent with the permissions and mode it was written with
    Given the user switched "Fix checkout" to plan mode with full access and sent "add a test" while offline
    When "My MacBook" becomes reachable
    Then the thread's mode and permissions are changed first
    And "add a test" is sent after them

  @backlog @mobile
  Scenario: A thread whose mode could not be changed keeps its message waiting
    Given the user sent "add a test" in "Fix checkout" in a different mode than the thread has
    And the environment does not answer the request to change the mode
    Then "add a test" keeps waiting to send
    And "add a test" is not returned to the draft

  @backlog @mobile
  Scenario: A waiting attachment that fails for a reason other than the connection returns the message
    Given the user sent "add a test" with a photo in "Fix checkout" while offline
    And the environment refuses the photo when the connection returns
    Then "add a test" and the photo are back in the draft of "Fix checkout"
    And the user is told the reason the environment gave

  @backlog @mobile
  Scenario: A thread's stuck message does not hold up another thread
    Given "add a test" in "Fix checkout" cannot be sent yet
    And "update the readme" is waiting in "Docs pass" on the same environment
    When the environment is connected
    Then "update the readme" is sent

  @backlog @mobile
  Scenario: A new task whose project was removed is dropped
    Given the user started the task "Add search" in "shop" while offline
    And "shop" was removed from "My MacBook"
    When the phone reconnects and has the current project list
    Then the task is not sent
    And the task is no longer listed as pending

  @backlog @mobile
  Scenario: A new task is sent from the folder saved with it when its project has not loaded
    Given the user started the task "Add search" in "shop" while offline
    And "My MacBook" has reconnected but its project list has not arrived
    Then the task is sent to the project folder it was started with

  @backlog @mobile
  Scenario: A new task that is not complete waits for the user to finish it
    Given the user wrote the task "Add search" in "shop" in a new worktree but chose no base branch
    When "My MacBook" is reachable
    Then the task is not sent
    And the task stays listed with the pending tasks
    When the user chooses a base branch in the new task editor
    Then the task is sent

  @backlog @mobile
  Scenario: A waiting message is not sent while the user is editing it
    Given the user sent "add a test" in "Fix checkout" while offline
    And the user is editing the waiting message in the composer
    When "My MacBook" becomes reachable
    Then "add a test" is not sent
    And the photos already uploaded for it are kept for the editor

  @backlog @mobile
  Scenario: A message waiting to send can be pulled back into the composer
    Given the user sent "add a test" with a photo in "Fix checkout" while offline
    When the user edits the waiting message
    Then "add a test", the photo and the model choice are in the composer of "Fix checkout"
    And "add a test" is no longer waiting to send

  @backlog @mobile
  Scenario: A message that is being sent cannot be pulled back
    Given the phone is sending "add a test" to "My MacBook"
    When the user tries to edit it
    Then nothing changes
    And "add a test" is delivered once

  @backlog @mobile
  Scenario: Pulling a message back is refused when the composer would hold too many attachments
    Given the composer of "Fix checkout" already holds attachments
    And a waiting message has attachments that together exceed the limit for one message
    When the user edits the waiting message
    Then the user is told to remove attachments from the composer first
    And the message keeps waiting to send

  @backlog @mobile
  Scenario: A pull back that cannot be completed leaves the draft as it was
    Given the user typed "also check lint" in the composer of "Fix checkout"
    And "add a test" is waiting to send
    When the user edits the waiting message and the phone cannot take it out of the queue
    Then the composer still reads "also check lint"
    And "add a test" keeps waiting to send

  @backlog @mobile
  Scenario: Signing out keeps the unsent work of relayed environments
    Given the user has drafts and waiting messages for "Office Mac", reached through HAL-C2 Connect
    When the user signs out of HAL-C2 Connect
    Then the relayed environments are removed from the phone
    And the drafts and waiting messages for them are kept for that account

  @backlog @mobile
  Scenario: Signing back in restores that account's unsent work
    Given the user signed out with drafts and waiting messages for "Office Mac"
    When the user signs in to the same account again
    Then the drafts are back, merged with anything typed since
    And the waiting messages are sent once "Office Mac" connects

  @backlog @mobile
  Scenario: Another account does not receive the previous account's unsent work
    Given the user signed out with drafts and waiting messages for "Office Mac"
    When a different account signs in on the phone
    Then the previous account's drafts and waiting messages are not shown
    And they are kept until that previous account signs in again

  @backlog @mobile
  Scenario: Unsent work that could not be saved at sign-out is not lost
    Given the phone cannot save the waiting messages for relayed environments
    When the user signs out of HAL-C2 Connect
    Then the drafts and waiting messages stay on the phone
    And saving them is tried again the next time the app starts or an account signs in

  @backlog @mobile
  Scenario: Client storage with nothing kept says so
    Given the phone has used no environment yet
    When the user opens client storage
    Then the user is told there is no cached data
    And clearing caches is not offered

  @backlog @mobile
  Scenario: Client storage that cannot be read says so and keeps the connections
    Given the phone cannot read its storage
    When the user opens client storage
    Then the user is told storage is unavailable and to restart the app
    And clearing caches is not offered
    And the paired environments and their credentials are untouched

  # Likely already implemented: apps/mobile/src/connection/catalog-store.ts
  @backlog @mobile
  Scenario: Environments saved by an earlier version of the app are still paired after updating
    Given the phone holds environments paired with an earlier version of the app
    When the user opens the updated app
    Then the same environments are paired on the phone
    And they are kept in the phone's current format

  @backlog @mobile
  Scenario: A damaged record of paired environments is discarded
    Given the phone's record of paired environments is damaged
    When the app starts
    Then the phone starts with no paired environments
    And the user is offered to add an environment

  @backlog @mobile
  Scenario: The clear button says how much it will free
    Given the phone keeps 12 MB of cached data
    When the user opens client storage
    Then clearing caches offers to clear 12 MB

  @backlog @mobile
  Scenario: Each environment tells the phone whether it is in front
    Given the phone is paired with "My MacBook" and "Office Mac"
    When the user opens the app
    Then "My MacBook" and "Office Mac" are told the phone is in front
    When the user switches away from the app
    Then "My MacBook" and "Office Mac" are told the phone is in the background

  @backlog @mobile
  Scenario: The phone keeps telling its environments it is still there
    Given the phone is connected to "My MacBook"
    When about half a minute passes
    Then "My MacBook" is told again what the phone is showing
    And the report expires on "My MacBook" if the phone stops sending it

  @backlog @mobile
  Scenario: A burst of changes is reported once
    Given the phone is connected to "My MacBook"
    When the user switches between several threads within a moment
    Then "My MacBook" receives one report of what the phone is showing

  @backlog @mobile
  Scenario: The phone reports the status and checkout it is looking at
    Given the user is looking at "Fix checkout" and the checkout's source control status
    Then "My MacBook" is told the phone is following that checkout's status
    When the user leaves "Fix checkout"
    Then "My MacBook" is told the phone no longer follows it

  @backlog @mobile
  Scenario: An environment that cannot be reached does not stop the other reports
    Given the phone is paired with "My MacBook" and "Office Mac"
    And "Office Mac" is unreachable
    When the phone reports what it is showing
    Then "My MacBook" still receives the report

  @backlog @mobile
  Scenario Outline: A screen the phone fails to draw offers a way out that fits where it was opened
    Given <screen> fails to draw
    Then the user is told "This screen couldn't be displayed"
    And the user is offered to try again, to copy the details and to "<exit>"

    Examples:
      | screen                                 | exit          |
      | a screen opened from another screen    | Go back       |
      | the home screen                        | Open settings |
      | a screen with nothing to go back to    | Return home   |

  @backlog @mobile
  Scenario: A screen that failed to draw is drawn again when the user tries again
    Given a screen failed to draw and the user is told so
    When the user chooses to try again
    Then the screen is drawn again from the start

  @backlog @mobile
  Scenario: A screen that failed to draw is drawn again when it is opened for something else
    Given the screen for "Fix checkout" failed to draw
    When the user opens the same screen for another thread
    Then the screen is drawn instead of the failure

  @backlog @mobile
  Scenario: The details of a drawing failure can be copied for a bug report
    Given a screen failed to draw
    When the user copies the details
    Then the error and where it happened are on the clipboard
    And only the first line of the error is shown on the screen

  @backlog @mobile
  Scenario Outline: A failure in one pane of a tablet leaves the other panes working
    Given the tablet shows the thread list, a thread and its <pane>
    When the <pane> fails to draw
    Then the <pane> is replaced by "<title>" with a way to try again
    And the other panes keep working

    Examples:
      | pane      | title                              |
      | sidebar   | The sidebar couldn't be displayed  |
      | inspector | The inspector couldn't be displayed |
