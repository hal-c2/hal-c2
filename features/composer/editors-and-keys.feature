# Sources:
#   docs/user/composer.md (prompt recall, prompt stash)
#   docs/internals/composer-editors.md
#   apps/desktop-qt/qml/HalC2/Bricks/ComposerVimKeys.qml
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (editor actions, text insertion)
#   apps/desktop-qt/src/native/ComposerController.cpp (stash)
#   apps/desktop-qt/tests/tst_ComposerExtensions.qml
#   apps/desktop-qt/tests/tst_ComposerActions.qml
#   apps/tui/src/promptEditor.ts
#   apps/tui/src/components/ChatView.tsx (external editor, prompt height)
#   apps/web/src/composerPromptHistory.ts
#   apps/web/src/components/chat/ComposerStashMenu.tsx
#   apps/web/src/components/chat/ChatComposer.tsx (stash toasts)
#   packages/shared/src/keybindings.ts (composer.stash)
#   packages/contracts/src/settings.ts (composerRichTextEnabled, fontFamilyComposer)
#   apps/web/src/keybindings.ts, apps/web/src/hooks/useSidebarToggleKeybinding.ts (isRichTextBoldShortcut)
#   apps/web/src/components/chat/composerPromptHistory.ts (what is recalled, when Up and Down recall)
#   apps/web/src/promptStashStore.ts, apps/web/src/components/chat/ComposerStashBadge.tsx (what a stash keeps)
#   apps/web/src/components/ComposerPromptEditorTiptap.tsx (Enter, lists, wrapping a selection, keys around references)
#   apps/web/src/composer-list-continuation.ts, apps/web/src/composer-rich-text.ts, apps/web/src/composer-rich-text-doc.ts
#   apps/web/src/components/composerSelection.ts, apps/web/src/components/composerInlineChip.ts
#   apps/web/src/composerPlaceholder.ts, apps/web/src/components/chat/ChatComposer.tsx (what an empty composer asks for)

Feature: Editing the draft
  The user edits the draft with the keys they are used to, in an outside
  editor, or by recalling and stashing earlier prompts.

  Background:
    Given a project with an open thread

  @desktop
  Scenario: Escape enters normal mode when Vim keys are on
    Given Vim keys are on
    And the user has typed "hello world"
    When the user presses Escape
    Then typed letters move the cursor instead of inserting text

  @desktop
  Scenario Outline: Normal mode keys edit and move like Vim
    Given Vim keys are on and the editor is in normal mode
    And the draft reads "hello world" with the cursor at the start
    When the user presses <keys>
    Then <outcome>

    Examples:
      | keys | outcome                                  |
      | w    | the cursor moves to "world"              |
      | $    | the cursor moves to the end of the line  |
      | x    | the draft reads "ello world"             |
      | A    | the user inserts at the end of the line  |

  @desktop
  Scenario: Enter in normal mode does not send
    Given Vim keys are on and the editor is in normal mode
    When the user presses Enter
    Then nothing has been sent

  @desktop
  Scenario: Switching threads returns Vim keys to insert mode
    Given Vim keys are on and the editor is in normal mode
    When the user switches to another thread
    Then typed letters insert text

  @desktop
  Scenario: Vim keys can be turned on from settings
    When the user turns on Vim keys in settings
    Then the composer edits with Vim keys

  @desktop
  Scenario: Inserted text replaces the selection without sending
    Given the draft reads "hello world" with "world" selected
    When text "there" is inserted into the composer
    Then the draft reads "hello there"
    And nothing has been sent

  @desktop
  Scenario: Text meant for another thread is not inserted
    Given the user is writing in thread B
    When text meant for thread A arrives late
    Then thread B's draft is unchanged

  @tui
  Scenario: The draft can be written in the user's own editor
    Given the user's editor is set in VISUAL or EDITOR
    And the draft reads "start"
    When the user opens the draft in their editor and saves "start\nmore"
    Then the draft reads the saved text without trailing blank lines

  @tui
  Scenario: An image path written in the outside editor becomes an attachment
    When the user saves a line naming "./bug.png" from their editor
    Then "bug.png" is attached
    And that line is not part of the prompt text

  @desktop @mobile @backlog-mobile
  Scenario: Earlier prompts are recalled in an empty composer
    Given the user sent "first" and then "second" in this thread
    And the composer is empty
    When the user recalls the previous prompt twice
    Then the draft reads "first"
    When the user moves forward again
    Then the draft reads "second"

  @desktop
  Scenario: Stashing a prompt clears the composer and it can be restored
    Given the draft reads "half-finished idea"
    When the user stashes the prompt
    Then the composer is empty
    When the user restores the stashed prompt
    Then the draft reads "half-finished idea"

  @desktop
  Scenario: Stashing an empty draft brings back the only stashed prompt
    Given the draft reads "half-finished idea"
    When the user stashes the prompt
    And the user stashes the prompt again
    Then the draft reads "half-finished idea"
    And nothing is stashed

  @desktop
  Scenario: A restored prompt joins what the draft already holds
    Given the user stashed "first idea"
    And the user has typed "second thought"
    When the user restores the stashed prompt
    Then the draft reads "second thought" and then "first idea"

  @desktop
  Scenario: A stashed prompt can be deleted
    Given the user stashed "first idea"
    When the user deletes the stashed prompt
    Then nothing is stashed
    And the composer is empty

  @desktop
  Scenario: The stash keeps the 20 newest prompts
    Given the user stashed 20 prompts
    When the user stashes "one more"
    Then the user sees a "warning" toast "Oldest stashed prompt discarded" saying "The stash holds 20 prompts; the oldest was removed to make room."
    And 20 prompts are stashed, "one more" first

  @desktop
  Scenario: A prompt cannot be stashed while its files are uploading
    Given the draft carries a file that is still uploading
    When the user stashes the prompt
    Then the user is asked to wait for file uploads before stashing
    And the draft is unchanged

  @desktop
  Scenario: Turning rich text off keeps the draft as plain Markdown
    Given rich text editing is on and the draft shows "bold" in bold
    When the user turns rich text editing off
    Then the draft reads "**bold**"

  @backlog @desktop
  Scenario Outline: The bold shortcut formats the selection when rich text is on
    Given rich text editing is on
    And the user is on <platform>
    And the draft selects "word"
    When the user presses <chord>
    Then "word" is bold

    Examples:
      | platform | chord  |
      | macOS    | Cmd+B  |
      | Linux    | Ctrl+B |

  @backlog @desktop
  Scenario: The bold shortcut does not toggle the sidebar while rich text is on
    Given rich text editing is on
    And the composer has focus
    When the user presses the bold shortcut
    Then the sidebar stays as it was

  @backlog @desktop
  Scenario: The sidebar shortcut still works from a plain-text composer
    Given rich text editing is off
    And the composer has focus
    When the user presses the sidebar shortcut
    Then the sidebar toggles

  @backlog @desktop
  Scenario Outline: A composer that already holds something recalls nothing
    Given the user sent "first" in this thread
    And <state>
    When the user presses Up on the first line of the composer
    Then the draft is not replaced by "first"

    Examples:
      | state                                        |
      | the user has typed "new idea"                |
      | the draft carries an image and no text       |
      | the draft carries a file and no text         |
      | the draft carries a terminal excerpt         |
      | the draft carries a preview annotation       |
      | the draft carries a comment on a file        |
      | an approval is waiting for an answer         |
      | a question from the agent is waiting         |

  @backlog @desktop
  Scenario: Editing a recalled prompt makes it an ordinary draft
    Given the user sent "first" and then "second" in this thread
    And the user recalled "second"
    When the user changes the draft to "second, revised"
    And the user presses Up on the first line of the composer
    Then the draft reads "second, revised"

  @backlog @desktop
  Scenario: Moving forward past the newest prompt empties the composer
    Given the user sent "first" and then "second" in this thread
    And the user recalled "second"
    When the user moves forward again
    Then the composer is empty

  @backlog @desktop
  Scenario: Up at the oldest prompt moves the caret instead
    Given the user sent "first" in this thread
    And the user recalled "first"
    When the user presses Up again
    Then the draft reads "first"
    And the caret moves to the start of the draft

  @backlog @desktop
  Scenario: Down in a draft the user typed recalls nothing
    Given the user sent "first" in this thread
    And the user has typed "new idea"
    When the user presses Down on the last line of the composer
    Then the draft reads "new idea"

  @backlog @desktop
  Scenario: Up and Down only recall from the first and last line as shown
    Given the user recalled a prompt long enough to wrap onto three lines
    And the caret is on the last line
    When the user presses Up
    Then the caret moves up one line
    And the draft still reads that prompt

  @backlog @desktop
  Scenario Outline: A modifier held with Up or Down recalls nothing
    Given the user sent "first" in this thread
    And the composer is empty
    When the user presses <keys>
    Then the composer is empty

    Examples:
      | keys     |
      | Shift+Up |
      | Alt+Up   |
      | Ctrl+Up  |
      | Cmd+Up   |

  @backlog @desktop
  Scenario: Each thread recalls only its own prompts
    Given the user sent "about tax" in thread A and "about search" in thread B
    And the user recalled "about tax" in thread A
    When the user opens thread B and recalls the previous prompt
    Then the draft reads "about search"

  @backlog @desktop
  Scenario: The same prompt sent twice in a row is recalled once
    Given the user sent "first", then "again" and then "again" in this thread
    When the user recalls the previous prompt twice
    Then the draft reads "first"

  @backlog @desktop
  Scenario Outline: A recalled prompt is the words the user typed and nothing else
    Given the user sent "fix the build" with <extra>
    When the user recalls the previous prompt
    Then the draft reads "fix the build"

    Examples:
      | extra                                |
      | Ultrathink turned on                 |
      | a comment on a file                  |
      | a terminal excerpt added at the end  |
      | a preview annotation                 |

  @backlog @desktop
  Scenario Outline: Messages the user did not type are not recalled
    Given the user sent "first" and then <message>
    When the user recalls the previous prompt
    Then the draft reads "first"

    Examples:
      | message                                   |
      | an image with no text                     |
      | the request to implement a proposed plan  |

  @backlog @desktop
  Scenario Outline: Enter does not send while it is doing something else
    Given the draft reads "konnichiwa"
    When the user presses Enter <while>
    Then nothing has been sent

    Examples:
      | while                                              |
      | to accept a word from their input method           |
      | and holds it so the key repeats                    |
      | with the keyboard focus on a task's checkbox       |

  @backlog @desktop
  Scenario Outline: Enter in a list starts the next item
    Given the draft's last line reads "<line>" with the caret at its end
    When the user adds a new line
    Then the new line starts with "<next>"

    Examples:
      | line             | next   |
      | - milk           | -      |
      | * milk           | *      |
      | 1. milk          | 2.     |
      | 12. milk         | 13.    |
      | 3) milk          | 4)     |
      | - [x] milk       | - [ ]  |

  @backlog @desktop
  Scenario: A nested list item keeps its indentation on the next line
    Given the draft's last line is a bullet indented by two spaces
    When the user adds a new line
    Then the new line is a bullet indented by two spaces

  @backlog @desktop
  Scenario: Enter on an empty list item leaves the list
    Given the draft's last line is a bullet with nothing after it
    When the user adds a new line
    Then that line is no longer a bullet
    And no new bullet is started

  @backlog @desktop
  Scenario: Enter in the middle of a list item splits it in two
    Given the draft reads "- milk and eggs" with the caret before "and"
    When the user adds a new line
    Then the draft reads "- milk" and then "- and eggs" on the next line

  @backlog @desktop
  Scenario: A reference in a list item is never split
    Given a list item holds a file reference
    When the user adds a new line with the caret beside the reference
    Then the file reference is whole on one of the two lines

  @backlog @desktop
  Scenario: Tab indents the list item the caret is in
    Given the draft's last line reads "- milk"
    And no suggestion list is open
    When the user presses Tab
    Then that line is indented by two spaces

  @backlog @desktop
  Scenario Outline: Markdown typed with rich text on is shown styled
    Given rich text editing is on
    When the user types "<typed>"
    Then the draft shows <shown>
    And the message is sent as "<typed>"

    Examples:
      | typed         | shown                          |
      | **bold**      | "bold" in bold                 |
      | *lean*        | "lean" in italics              |
      | ~~gone~~      | "gone" struck through          |
      | `code`        | "code" as code                 |
      | - [ ] milk    | "milk" as an unchecked task    |
      | - [x] milk    | "milk" as a checked task       |

  @backlog @desktop
  Scenario Outline: Markers that do not make a style are left as typed
    Given rich text editing is on
    When the user types "<typed>"
    Then the draft reads "<typed>" with nothing styled

    Examples:
      | typed            |
      | 2 * 3 * 4        |
      | snake_case_name  |
      | \*not bold\*     |
      | **never closed   |

  @backlog @desktop
  Scenario: Markers inside code are part of the code
    Given rich text editing is on
    When the user types "`**kwargs`"
    Then the draft shows "**kwargs" as code, not in bold

  @backlog @desktop
  Scenario: The markers of styled text show while the caret is on it
    Given rich text editing is on and the draft shows "bold" in bold
    When the user moves the caret into "bold"
    Then the draft shows "**bold**"
    When the user moves the caret out of it
    Then the draft shows "bold" in bold

  @backlog @desktop
  Scenario: A task in the draft is ticked with the keyboard or the pointer
    Given rich text editing is on and the draft holds an unchecked task "milk"
    When the user ticks the task
    Then the message is sent as "- [x] milk"

  @backlog @desktop
  Scenario Outline: Typing an opening mark over a selection wraps it
    Given the draft reads "hello world" with "world" selected
    When the user types <mark>
    Then the draft reads "hello <wrapped>"
    And "world" is still selected

    Examples:
      | mark | wrapped   |
      | (    | (world)   |
      | [    | [world]   |
      | {    | {world}   |
      | "    | "world"   |
      | '    | 'world'   |
      | `    | `world`   |
      | <    | <world>   |
      | *    | *world*   |
      | _    | _world_   |

  @backlog @desktop
  Scenario Outline: Typing an opening mark over a reference or styled text replaces it
    Given the draft's selection covers <selection>
    When the user types (
    Then the selection is replaced by "("

    Examples:
      | selection          |
      | a file reference   |
      | text shown in bold |

  @backlog @desktop
  Scenario Outline: An arrow key steps over a reference in one press
    Given the caret is just <side> a file reference in the draft
    When the user presses <key>
    Then the caret is on the other side of the reference

    Examples:
      | side   | key   |
      | after  | Left  |
      | before | Right |

  @backlog @desktop
  Scenario Outline: Home and End on macOS go to the edges of the line as shown
    Given the user is on macOS
    And the draft holds one long paragraph wrapped onto three lines, with the caret in the second
    When the user presses <key>
    Then the caret is at the <edge> of the second line as shown

    Examples:
      | key  | edge  |
      | Home | start |
      | End  | end   |

  @backlog @desktop
  Scenario: A stashed prompt takes its images, files and references with it
    Given the draft reads "look at this" and carries an image, an uploaded file and a terminal excerpt
    When the user stashes the prompt
    Then the composer holds no text, image, file or excerpt
    When the user restores the stashed prompt
    Then the draft reads "look at this" and carries the image, the file and the terminal excerpt again

  @backlog @desktop
  Scenario: A prompt stashed in one thread is restored in another and keeps that thread's model
    Given the user stashed "half-finished idea" in a thread on Codex
    When the user opens a thread on Claude and restores the stashed prompt
    Then the draft reads "half-finished idea"
    And the thread still runs on Claude

  @backlog @desktop
  Scenario: Stashed prompts are still there after a restart
    Given the user stashed "half-finished idea" with an image
    When the app is restarted
    Then the stash lists "half-finished idea" with its image

  @backlog @desktop
  Scenario: A stashed prompt with files is restored only where its files were uploaded
    Given the user stashed a prompt with the file "trace.log" in a thread on the environment "laptop"
    When the user restores it in a thread on the environment "server"
    Then the user sees an "error" toast "Stashed files belong to another environment" saying "Restore this prompt in the environment that received its files."
    And the prompt is still stashed

  @backlog @desktop
  Scenario Outline: A restored prompt says which attachments did not come back
    Given the user stashed a prompt with "big.png" and <problem>
    When the user restores the stashed prompt
    Then the user sees a "warning" toast "Some attachments were not restored" saying "<reason>"
    And the prompt's text is restored

    Examples:
      | problem                                              | reason                                                                                     |
      | the image was too large for the stash to keep        | big.png exceeded the stash size limit when this prompt was saved.                          |
      | the image could not be read when it was stashed      | big.png could not be read when this prompt was saved.                                      |
      | the draft already carries 100 attachments            | big.png could not be restored: the composer is at its 100-attachment limit.                |

  @backlog @desktop
  Scenario: A stashed file kept longer than a day has to be attached again
    Given the user stashed a prompt with the file "trace.log" more than 24 hours ago
    When the user restores the stashed prompt
    Then "trace.log" comes back as a file that must be attached again
    And the user sees a "warning" toast "Some attachments were not restored" saying "trace.log: stashed files are kept for 24 hours and this upload expired. Attach the file again."

  @backlog @desktop
  Scenario: A prompt whose file must be attached again cannot be stashed
    Given the draft carries a file whose upload a restart interrupted
    When the user stashes the prompt
    Then the user sees an "error" toast "Attach dropped files again or remove them before stashing"
    And the draft is unchanged

  @backlog @desktop
  Scenario: A prompt is not stashed while a pasted reference is still arriving
    Given the user pasted a reference whose file is still being fetched
    When the user stashes the prompt
    Then the user sees an "info" toast "Still bringing a pasted attachment into this message." saying "Stash again once its chip resolves."
    And the draft is unchanged

  @backlog @desktop
  Scenario: Stashing an empty draft opens the stash when several prompts are stashed
    Given the user stashed "first idea" and "second idea"
    And the composer is empty
    When the user stashes the prompt
    Then the stash lists "second idea" and then "first idea"
    And the composer is still empty

  @backlog @desktop
  Scenario Outline: The stash is left alone while the composer is doing something else
    Given the draft reads "half-finished idea"
    And <state>
    When the user presses the stash shortcut
    Then <outcome>

    Examples:
      | state                                       | outcome                                              |
      | an approval is waiting for an answer        | nothing is stashed and the draft is unchanged        |
      | a new thread still needs its project chosen | nothing is stashed and the draft is unchanged        |
      | the command palette is open                 | nothing is stashed and the draft is unchanged        |
      | the thread is being rolled back             | nothing is stashed and the draft is unchanged        |
      | a question from the agent is waiting        | the stash opens or closes and the answer is not stashed |

  @backlog @desktop
  Scenario: Holding the stash shortcut stashes the prompt once
    Given the draft reads "half-finished idea" and nothing is stashed
    When the user holds the stash shortcut so the key repeats
    Then one prompt is stashed
    And it is not restored again by the repeats

  @backlog @desktop
  Scenario: The composer shows how many prompts are stashed
    Given the user stashed 3 prompts
    When the user looks at the composer
    Then the composer shows that 3 prompts are stashed
    And choosing that count opens the stash
    But no count is shown when nothing is stashed or while an approval is waiting

  @backlog @desktop
  Scenario Outline: A stashed prompt is listed by what it holds
    Given the user stashed <prompt>
    When the user opens the stash
    Then the prompt is listed as "<listed>"
    And the prompt says how long ago it was stashed

    Examples:
      | prompt                                    | listed                              |
      | "fix the build"                           | fix the build                       |
      | a prompt of 200 characters                | its first 90 characters and "…"     |
      | two images and no text                    | (2 images)                          |
      | one image and no text                     | (1 image)                           |
      | one file and no text                      | (1 file)                            |
      | one image, one file and no text           | (2 attachments)                     |

  @backlog @desktop
  Scenario: The stash is worked from the keyboard
    Given the user stashed "first idea" and "second idea" and the stash is open
    When the user presses Up on the first prompt
    Then the last prompt is highlighted
    When the user presses Enter
    Then that prompt is restored into the draft
    When the user opens the stash again and presses Escape
    Then the stash closes and nothing is restored

  @backlog @desktop
  Scenario: A stashed prompt is deleted from the keyboard
    Given the user stashed "first idea" and "second idea" and the stash is open
    When the user presses Ctrl+Backspace on "second idea"
    Then only "first idea" is stashed
    When the user deletes "first idea" as well
    Then the stash closes

  @backlog @desktop
  Scenario: An empty stash says how to fill it
    Given nothing is stashed
    When the user opens the stash
    Then the stash says "Nothing stashed yet. Press Ctrl+S with a prompt in the composer to stash it."

  @backlog @desktop
  Scenario: The stash closes when the user goes back to writing
    Given the stash is open
    When the user types in the composer
    Then the stash closes
    And the same happens when a suggestion list opens

  @backlog @desktop
  Scenario: A stashed prompt whose images are still being kept says so
    Given the user stashed a prompt with two large images a moment ago
    When the user opens the stash
    Then the prompt says it is saving 2 images
    And a prompt that lost an image says "1 image dropped"

  @backlog @desktop
  Scenario: Images still being kept are not lost when their prompt is restored at once
    Given the user stashed a prompt with two large images
    When the user restores it before the images are kept
    Then the user sees a "warning" toast "Stashed images did not attach"
    And the user is told to attach the 2 images again if they are still needed

  @backlog @desktop
  Scenario: A prompt that cannot be kept in the stash stays in the composer
    Given the draft reads "half-finished idea"
    When the user stashes the prompt and the stash cannot be written
    Then the user sees an "error" toast "Could not stash this prompt"
    And the draft still reads "half-finished idea"

  # Browser tab only: the stash lived in the page's storage, which a browser may block or fill.
  @dropped @desktop
  Scenario Outline: A stash the browser cannot keep warns that it may not last
    When <event> and the browser's storage refuses the change
    Then the user sees a "warning" toast "<title>"

    Examples:
      | event                                   | title                                     |
      | the user stashes a prompt               | Stashed prompt will not survive a reload  |
      | the user stashes a prompt with images   | Stashed images were not saved             |
      | the user restores a stashed prompt      | Restored prompt may reappear in the stash |
      | the user deletes a stashed prompt       | Stash entry may come back                 |

  # Browser tab only: the shortcut is taken from the browser so its own save dialog never opens.
  @dropped @desktop
  Scenario: The stash shortcut never opens the browser's save dialog
    Given the composer is empty and nothing is stashed
    When the user presses the stash shortcut
    Then the browser does not offer to save the page

  @backlog @desktop
  Scenario Outline: An empty composer says what it is waiting for
    Given the composer is empty
    And <state>
    Then the composer reads "<hint>"

    Examples:
      | state                                              | hint                                                                 |
      | nothing is waiting on the user                     | Ask anything, @tag files/folders, $use skills, or / for commands     |
      | an approval is waiting for an answer               | Resolve this approval request to continue                            |
      | a question with only fixed choices is waiting      | Choose an option above                                               |
      | a question that takes a typed answer is waiting    | Type your own answer, or leave this blank to use the selected option |
      | a proposed plan is waiting to be implemented       | Add feedback to refine the plan, or leave this blank to implement it |
      | a new thread still needs its project chosen        | Choose a project above to start a thread                             |
      | no provider can be used                            | Enable a provider in Settings to send a message                      |
      | the environment is disconnected                    | Ask for changes, send follow-ups, or attach images                   |

  @backlog @desktop
  Scenario: A draft that holds only a reference shows no hint
    Given the draft carries a terminal excerpt and no text
    Then the composer shows the excerpt and no hint about what to type

  @backlog @desktop
  Scenario Outline: The composer takes no typing while something else must be settled first
    Given <state>
    When the user types "hello"
    Then the draft does not change

    Examples:
      | state                                              |
      | the environment is still connecting                |
      | an approval is waiting for an answer               |
      | a new thread still needs its project chosen        |
      | a question with only fixed choices is waiting      |
      | the user's answer to a question is being submitted |

  @backlog @desktop
  Scenario: Turning rich text on or off keeps the draft
    Given the draft reads "fix **this** and - [ ] that" with a file reference
    When the user turns rich text editing on and then off again
    Then the draft reads the same text with the same file reference

  @backlog @desktop
  Scenario: A ticked task is written the same way however the user typed it
    Given rich text editing is on
    When the user types "- [X] milk"
    Then the message is sent as "- [x] milk"

  @backlog @desktop
  Scenario: Moving the caret from elsewhere in the app brings it into view
    Given the draft is long enough to scroll and is scrolled to its start
    When a reference is added at the end of the draft
    Then the draft scrolls so the caret and the new reference can be seen

  @backlog @desktop
  Scenario: Cancelling the comment on a quote just made takes the quote out again
    Given the user cited the assistant's paragraph about caching and has not yet saved a comment
    When the user cancels the comment
    Then the draft no longer quotes that paragraph
    But cancelling an edit of an older quote keeps the quote and its comment
