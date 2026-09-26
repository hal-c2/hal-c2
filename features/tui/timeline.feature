# Sources:
#   apps/tui/src/components/MessagesTimeline.tsx, MessagesTimeline.test.tsx
#   apps/tui/src/timeline.ts, timeline.test.ts (interleaving, turn folds, durations, changed files)
#   apps/tui/src/worklog.ts, worklog.test.ts
#   apps/tui/src/timelineLinks.ts, timelineLinks.test.ts
#   apps/tui/src/contextWindow.ts, contextWindow.test.ts
#   apps/tui/src/components/WorkingIndicator.tsx, WorkingIndicator.test.tsx
#   apps/tui/src/components/DiffViewer.tsx, DiffViewer.test.tsx
#   apps/tui/src/diffSplit.ts, diffSplit.test.ts
#   apps/tui/src/components/ChatView.tsx (the diff viewer takes the conversation pane's place)
#   apps/tui/src/components/ThreadOverlays.tsx (revert picker)
#   apps/tui/src/fileTree.ts, fileTree.test.ts (changed-files tree)
#   apps/tui/src/theme.ts (createTuiSyntaxStyle for Markdown)
#   apps/tui/src/features.backlog.test.ts (review-workspace)
#   Shared domain: timeline/ owns reading a thread on every surface.

Feature: Reading a thread in the terminal
  The timeline interleaves messages and tool work as they stream, folds finished turns,
  and opens any turn's changes as a diff the user can read split or stacked.

  Background:
    Given the terminal client is open on a thread

  @tui
  Scenario: Messages and tool calls interleave in the order they happened
    Given the agent wrote a message, ran two commands, then wrote another message
    Then the timeline shows the message, one group of two tool calls, then the second message

  @tui
  Scenario: A message and a tool call at the same instant show the message first
    Given a message and a tool call share a timestamp
    Then the message is shown before the tool call

  @tui
  Scenario Outline: Tool calls carry an icon for their kind
    Given the agent made a <kind> tool call
    Then its row starts with "<icon>"

    Examples:
      | kind          | icon |
      | command       | $    |
      | file read     | ◎    |
      | file change   | ✎    |
      | image view    | ▣    |
      | web search    | ⌕    |
      | MCP           | ⚙    |
      | dynamic       | ⚒    |
      | user input    | ✦    |
      | thinking      | ✱    |
      | failed        | ✗    |

  @tui
  Scenario: A tool call's updates collapse into one row
    Given a tool call reported started, progress and completed
    Then the timeline shows one row for that tool call with its final state

  @tui
  Scenario: A file change row previews the first file and a count
    Given the agent changed "src/a.ts" and two other files in one tool call
    Then the row shows "src/a.ts" and that two more files changed

  @tui
  Scenario: A running turn shows a static working indicator
    Given the agent is working
    Then the timeline shows that the agent is working with the elapsed seconds
    And the indicator does not repaint on a timer

  @tui
  Scenario: Streaming text appears as it arrives
    Given the agent is writing a reply
    And the timeline is scrolled to the latest entry
    When more of the reply arrives
    Then the timeline shows the new text without the user scrolling

  @tui
  Scenario: The active turn shows only its latest tool calls
    Given the running turn has made twelve tool calls
    Then only the most recent tool calls are shown
    And a row offers the previous tool calls behind "+N previous tool calls"

  @tui
  Scenario: Expanding previous tool calls reveals them
    Given the running turn hides earlier tool calls
    When the user expands the previous tool calls
    Then every tool call in the turn is shown
    And the user can show fewer again

  @tui
  Scenario: A finished turn folds its work behind a "Worked for" row
    Given a turn has finished after two minutes of tool work
    Then its tool calls and commentary fold behind a "Worked for" row with the duration
    And the final message stays visible

  @tui
  Scenario: A turn with nothing to hide does not fold
    Given a finished turn that is only a final message
    Then no "Worked for" row is shown

  @tui
  Scenario: The header shows plan or build and the context window
    Given the thread is in plan mode and has used part of its context window
    Then the header shows "plan"
    And it shows a meter with the tokens used and the percentage

  @tui
  Scenario: A context window with no known maximum still shows usage
    Given the provider reports tokens used but no maximum
    Then the meter shows the tokens used without a percentage

  @tui
  Scenario: Long threads mount only the latest page
    Given a thread with hundreds of turns
    Then only the latest page of the timeline is drawn
    And the user can reveal earlier entries a page at a time

  @tui
  Scenario: Markdown keeps its structure
    Given the agent replied with headings, emphasis, lists and a code block
    Then headings, bold text, lists and the code block are styled distinctly

  @tui
  Scenario: Bare URLs become clickable terminal links
    Given the agent wrote "See https://example.com/docs."
    Then "https://example.com/docs" is a terminal hyperlink without the trailing full stop

  @tui
  Scenario: URLs inside code stay plain text
    Given the agent wrote a URL inside inline code
    Then that URL is not turned into a link

  @tui
  Scenario: User messages sit on the right and long ones collapse
    Given the user sent a long message
    Then the message is aligned to the right and collapsed
    And expanding it shows the full message

  @tui
  Scenario: The conversation sits in a rounded pane
    Then the conversation is framed by a rounded border in the faint colour
    And the thread's title is inside the frame

  @tui
  Scenario: Entries are spaced like the OpenTUI client
    Given the user asked "Fix the build", the agent ran "bun run build" and replied "Fixed."
    Then the timeline reads:
      """
                                                   ╭───────────────╮
                                                   │ Fix the build │
                                                   ╰───────────────╯

      $ Ran command ✓  bun run build


      Fixed.
      """

  @tui
  Scenario: The user's message is boxed in the accent colour
    Given the user asked "Fix the build", the agent ran "bun run build" and replied "Fixed."
    Then the border around "Fix the build" is drawn in the accent colour

  @tui
  Scenario: A collapsed message keeps its bubble as narrow as its text
    Given the user sent twelve lines from "Requirement 1" to "Requirement 12"
    Then the timeline reads:
      """
      ╭────────────────╮
      │ Requirement 1  │
      │ Requirement 2  │
      │ Requirement 3  │
      │ Requirement 4  │
      │ Requirement 5  │
      │ Requirement 6  │
      │ Requirement 7  │
      │ Requirement 8  │
      │ ⌄ Show full    │
      │ message        │
      ╰────────────────╯
      """

  @tui
  Scenario: Lists and code blocks read like the OpenTUI client
    Given the agent replied with a list and a code block
    Then the timeline reads:
      """
      Steps:

      - first item
      - second item

      const answer = 42;

      Done.
      """
    And the list markers are bold in the accent colour

  @tui
  Scenario: A turn that changed files shows a changed-files tree
    Given the last turn changed files in nested folders
    Then the timeline shows a tree of the changed files with additions and deletions
    And single-child folders are compacted into one row

  @tui
  Scenario: Collapse all hides the files under their folders
    Given a changed-files tree is shown
    When the user collapses all
    Then only the top folders are shown

  @tui
  Scenario: Clicking a changed file opens its diff
    When the user clicks "src/a.ts" in the changed-files tree
    Then the diff viewer opens scoped to "src/a.ts" for that turn

  @tui
  Scenario: The user views all changes in the thread
    When the user views all changes from the command palette
    Then the diff viewer opens with the header "all changes"
    And each file has its own section with its language

  @tui
  Scenario: A focused file missing from the diff falls back to all files
    When the user opens the diff for a file that is not in that turn
    Then the diff viewer shows every file in the turn

  @tui
  Scenario: The user switches the diff between split and stacked
    Given the diff viewer shows a stacked diff
    When the user presses "s"
    Then the diff is shown side by side
    And pressing "s" again returns to stacked

  @tui
  Scenario Outline: The diff viewer explains every state it can be in
    Given the diff is <state>
    Then the diff viewer shows <message>

    Examples:
      | state             | message                   |
      | still loading     | a loading hint            |
      | for an empty turn | that there are no changes |
      | failed to load    | the error                 |

  @tui
  Scenario: File names with spaces and accents show as written
    Given a turn changed "docs/Read Me é.md"
    Then the diff viewer names the file "docs/Read Me é.md"

  @tui
  Scenario: Closing the diff viewer returns to the conversation
    Given the diff viewer is open
    When the user presses "Esc"
    Then the conversation is shown again

  @backlog @tui
  Scenario: The diff viewer takes the conversation pane's place in the chat column
    Given the terminal is 200 columns wide
    When the user views all changes from the command palette
    Then the diff viewer covers the conversation pane inside a rounded border in the accent colour
    And the prompt is still shown under it

  @backlog @tui
  Scenario: A diff that fails to load says so in one line
    Given the diff is failed to load
    Then the diff viewer reads "failed to load diff" in the error colour

  @tui
  Scenario: The user reverts the thread to a checkpoint
    When the user opens "Revert to checkpoint…"
    Then checkpoints are listed newest first with their changed file counts
    And confirming one restores the workspace to that checkpoint

  @tui
  Scenario: Backing out of the revert picker changes nothing
    Given the revert picker is open
    When the user presses "Esc"
    Then the workspace is unchanged

  @backlog @tui
  Scenario: The user compares against a base ref and hides whitespace
    When the user reviews the thread's changes against "main" ignoring whitespace
    Then the diff shows only non-whitespace changes since "main"

  @backlog @tui
  Scenario: The diff keeps the user's place in a large change
    Given the user scrolled halfway through a large diff
    When the diff refreshes
    Then the user is at the same file and line

  @backlog @tui
  Scenario: The user annotates diff lines as context for the next prompt
    When the user adds a note on a diff line
    Then the note and the line are attached to the prompt as context
