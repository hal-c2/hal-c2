# Sources:
#   docs/user/composer.md (slash commands, skills, context references, pull requests, threads, citing)
#   docs/internals/composer-context-references.md
#   apps/server-ex/lib/hal_c2/composer_context.ex (provider envelope, attachment remapping, quoted replies)
#   apps/desktop-qt/qml/HalC2/Bricks/Composer.qml (@file, $skill and /command suggestions)
#   apps/desktop-qt/src/native/ComposerController.cpp (terminal excerpts as context records on send, quoted replies)
#   apps/desktop-qt/qml/HalC2/Bricks/Markdown.qml (Cite on a selection of a reply)
#   packages/shared/src/assistantCitations.ts (citation links, the provider's view)
#   packages/shared/src/composerPullRequestMatches.ts (pull request suggestion order and scope)
#   packages/shared/src/composerInlineTokens.ts (scoped package names stay text)
#   apps/desktop-qt/tests/tst_ComposerKeyboard.qml (suggestion keys)
#   apps/web/src/composer-logic.ts (trigger kinds, built-in slash commands)
#   apps/web/src/components/chat/composerSlashCommandSearch.ts
#   apps/web/src/components/chat/ComposerCommandMenu.tsx
#   apps/web/src/components/chat/ChatComposer.tsx (menu empty states, reference paste failures)
#   apps/web/src/components/ChatView.tsx (/plan, /default, /feedback)
#   packages/contracts/src/settings.ts (showSkillsInSlashMenu)
#   apps/web/src/components/files/FilePreviewPanel.tsx, apps/web/src/reviewCommentContext.ts (file line comments)
#   apps/web/src/components/files/fileTreeDragMention.ts, apps/web/src/components/chat/composerMentionDrag.ts
#   apps/web/src/components/preview/PreviewView.tsx, packages/contracts/src/ipc.ts (preview annotations)
#   apps/web/src/components/contextPresentationRegistry.ts (element and annotation details)
#   apps/web/src/components/ChatView.tsx (/usage-limits panel lifetime, /feedback dispatch)
#   packages/client-runtime/src/state/threadFeedback.ts, apps/web/src/components/chat/ComposerFeedback.tsx
#   packages/client-runtime/src/composerThreadItems.ts (thread suggestions after @)
#   packages/client-runtime/src/providerSkills.ts (skill and slash command menus, per-folder skills, display names)
#   apps/web/src/providerSkillSearch.ts (which skills are offered, their order, where each comes from)
#   apps/web/src/components/chat/composerMenuHighlight.ts (the highlighted suggestion while results arrive)
#   apps/web/src/composer-editor-mentions.ts (text that only looks like a reference)
#   apps/web/src/components/composerInlineTokenPaste.ts, apps/web/src/components/chat/composerContextUndo.ts
#   apps/mobile/src/features/threads/ThreadFeed.tsx (Copy message carries the message's context references)
#   apps/web/src/components/composerContextPresentation.tsx, apps/web/src/components/contextChipParts.tsx,
#   apps/web/src/components/ThreadContextChip.tsx (what a reference shows and opens)
#   apps/web/src/composerDraftStore.ts (where context added from another panel lands in the draft)

Feature: Referencing files, skills, commands and context
  The user pulls things into a message by typing a trigger character or by
  bringing context from elsewhere in the app. References stay readable in the
  draft and arrive at the provider in a form it understands.

  Background:
    Given a project with an open thread

  @desktop @backlog-desktop
  Scenario Outline: A trigger character offers matching suggestions
    When the user types "<typed>"
    Then the user is offered <suggestions>

    Examples:
      | typed     | suggestions                           |
      | @src/co   | files and folders matching "src/co"   |
      | $rev      | skills matching "rev"                 |
      | /mo       | commands matching "mo"                |

  @desktop @backlog-desktop
  Scenario: Choosing a file suggestion puts the file into the draft
    Given the user has typed "@read"
    When the user chooses "README.md" from the suggestions
    Then the draft references "README.md"

  @desktop @backlog-desktop
  Scenario: Dismissing suggestions does not send the message
    Given the user is offered suggestions
    When the user dismisses them with Escape
    Then no suggestion is inserted
    And nothing has been sent

  @backlog @tui
  Scenario: The terminal client offers file, skill and command suggestions
    When the user types "@src" in the prompt
    Then the user is offered files and folders matching "src"

  @backlog @desktop
  Scenario Outline: Provider commands only apply at the start of a message
    When the user types "<typed>"
    Then <outcome>

    Examples:
      | typed                 | outcome                                    |
      | /compact              | the provider command "compact" is offered  |
      | please /compact       | no provider command is offered             |
      | please /model         | the built-in model command is offered      |

  @backlog @desktop
  Scenario Outline: Choosing a built-in command acts at once and leaves no text behind
    Given the Build and Plan toggle setting is on
    When the user chooses the built-in command "<command>"
    Then <outcome>
    And "<command>" is removed from the draft

    Examples:
      | command  | outcome                                  |
      | /plan    | the thread switches to planning          |
      | /default | the thread switches back to building     |
      | /model   | the user is asked to choose a model      |

  @backlog @desktop
  Scenario: Pull requests are found by number or by title
    Given the project's repository has pull request 42 "Fix login"
    When the user types "#login"
    Then pull request 42 "Fix login" is offered
    When the user chooses it
    Then the draft references pull request 42

  # Legacy: packages/shared/src/composerPullRequestMatches.ts (filterComposerPullRequestMatches)
  @backlog @desktop
  Scenario: A pull request typed in full is offered first even among many matches
    Given the project's repository has many pull requests whose numbers contain "12"
    And pull request 12 is not the most recently updated of them
    When the user types "#12"
    Then pull request 12 is the first suggestion
    And the other matches follow, most recently updated first

  # Legacy: packages/shared/src/composerPullRequestMatches.ts (filterComposerPullRequestMatches)
  @backlog @desktop
  Scenario: Pull requests of another project's repository are not suggested
    Given another project in the environment has a pull request 42 in a different repository
    When the user types "#42" in a thread of this project
    Then only this project's repository pull requests are offered

  # Legacy: packages/shared/src/composerInlineTokens.ts (SCOPED_PACKAGE_REFERENCE_REGEX)
  @backlog @desktop
  Scenario: An npm package name after an at sign stays text
    When the draft reads "install @acme/widgets first"
    Then "@acme/widgets" is not shown as a project file

  @backlog @desktop
  Scenario: Another thread on the same MC can be referenced
    Given the environment has a thread "Auth refactor"
    When the user references the thread "Auth refactor"
    Then the draft references "Auth refactor"
    And the agent can read that thread's history

  @backlog @desktop
  Scenario: A thread from another environment cannot be referenced
    Given a thread "Remote work" lives in a different environment
    When the user tries to reference it
    Then the user is told the agent can only read threads on its own server
    And the draft is unchanged

  @desktop
  Scenario: Part of an assistant response can be quoted with a comment
    Given the assistant replied with a paragraph about caching
    When the user cites that paragraph in the composer
    Then the draft carries the quoted paragraph
    And the user can add a comment to it

  @desktop
  Scenario: A quoted response is sent with its comment
    Given the draft quotes the assistant's paragraph about caching with the comment "Too slow?"
    When the user sends "Can we fix this?"
    Then the message starts with "Can we fix this?"
    And the message cites the paragraph with the comment "Too slow?"
    And the draft no longer quotes it

  @desktop
  Scenario: A stashed quote is listed by its text
    Given the draft quotes the assistant's paragraph about caching with the comment "Too slow?"
    When the user stashes the prompt
    Then the stash lists the prompt by the quoted paragraph and its comment

  @mc
  Scenario: The provider reads a quoted response as reference material
    Given a message quotes an earlier assistant response with the comment "Too slow?"
    When the message is sent to the provider
    Then the provider reads a numbered citation in place of the quote
    And the quoted text and the comment follow the message as citation data

  @desktop
  Scenario: A terminal excerpt is sent as a reference with its text
    Given the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user sends "Why does this fail?"
    Then the message references the excerpt "Terminal 1 lines 3-5"
    And the message starts with "Why does this fail?"
    And the message carries the excerpt's text
    And the draft no longer holds it

  @desktop
  Scenario: A terminal excerpt can be sent on its own
    Given the user adds line 7 of "Terminal 2" to the chat
    When the user sends ""
    Then the message references the excerpt "Terminal 2 line 7"

  @desktop
  Scenario: A removed terminal excerpt is not sent
    Given the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user removes that excerpt
    And the user sends "Never mind the output"
    Then the message starts with "Never mind the output"
    And the message carries no excerpt

  @desktop
  Scenario: A send the MC rejects gives its terminal excerpt back
    Given the MC refuses "message.dispatch" with "Provider unavailable"
    And the draft holds an excerpt from "Terminal 1" lines 3 to 5
    When the user sends "Why does this fail?"
    Then the user sees an "error" toast "Failed to send message" saying "Provider unavailable"
    And the composer shows that excerpt with its terminal and lines

  @backlog @desktop
  Scenario: Copied references survive being pasted into another draft
    Given a draft references the terminal excerpt "npm test output"
    When the user copies that text and pastes it into another thread's draft
    Then the other draft references "npm test output" as well

  @backlog @mobile
  Scenario: Copying a sent message brings its references along
    Given the user sent "look at this" with a reference to "src/cart.ts"
    When the user copies that message from the thread
    And pastes it into another draft
    Then the other draft holds "look at this" and the reference to "src/cart.ts"

  @backlog @mobile
  Scenario: Copying a sent message without references puts only its text on the clipboard
    Given the user sent "look at this" with no references
    When the user copies that message from the thread
    Then "look at this" is on the clipboard

  @backlog @desktop
  Scenario: A pasted reference whose source is unreachable is marked unresolved
    Given the user copied a reference from an environment that is now disconnected
    When the user pastes it into a draft
    Then the reference is marked unresolved
    And the user is told the environment it came from is not connected

  @mc
  Scenario: References reach the provider as labelled markers with their content appended
    Given a message "Look at README" references the file README.md
    When the message is sent to the provider
    Then the provider reads a marker naming the file README in place of the reference
    And the referenced content follows the message in a context envelope

  @mc
  Scenario: Referenced content cannot close the context envelope
    Given a terminal excerpt reference whose label contains "</hal_c2_context>"
    When the message is sent to the provider
    Then that text is escaped so the provider does not read it as the end of the context

  @backlog @desktop
  Scenario: A comment on lines of an open file goes into the draft
    Given the user is reading "src/cart.ts"
    When the user comments "Why is this rounded?" on lines 12 to 14
    Then the draft carries a file comment on "src/cart.ts" lines 12 to 14
    And sending the message gives the provider the comment with those lines of the file

  @backlog @desktop
  Scenario: A file comment follows its lines when the file is edited
    Given the draft carries a comment on line 12 of "src/cart.ts"
    When the user inserts two lines above line 12 in the file
    Then the draft's comment points at line 14 of "src/cart.ts"

  @backlog @desktop
  Scenario: Deleting a comment in the file removes it from the draft
    Given the draft carries a comment on line 12 of "src/cart.ts"
    When the user deletes that comment in the file
    Then the draft no longer carries the comment

  @backlog @desktop
  Scenario: Dragging a file from the file tree references it
    When the user drags "src/app.ts" from the file tree onto the composer
    Then the draft references the file "src/app.ts"
    And "src/app.ts" is not opened or left selected in the tree

  @backlog @desktop
  Scenario: Dragging a selection from the file tree references every selected entry
    Given "src/app.ts" and the folder "src/lib" are selected in the file tree
    When the user drags "src/app.ts" onto the composer
    Then the draft references "src/app.ts" and the folder "src/lib"

  @backlog @desktop
  Scenario Outline: A preview annotation is attached or sent
    Given the user annotated the page "Checkout" in the preview with "Make this button blue"
    When the user chooses to <submission> the annotation
    Then <result>

    Examples:
      | submission | result                                                                              |
      | attach     | the draft carries the annotation with the page, the comment and a picked-area image |
      | send       | a message carrying the annotation is sent right away                                |

  @backlog @desktop
  Scenario: An annotation whose screenshot fails is kept without it
    Given the user annotated a picked element in the preview
    When capturing the element's screenshot fails
    Then the draft carries the annotation without a screenshot
    And the user is told the element could not be captured

  @backlog @desktop
  Scenario: The user opens an annotation from the draft to read it in full
    Given the draft carries an annotation of the page "Checkout"
    When the user opens the annotation
    Then the user sees the page, the comment, the picked elements and the requested style changes

  @backlog @desktop
  Scenario: /usage-limits closes once the agent spends quota again
    Given the user opened "/usage-limits" in a Codex thread
    When the agent resumes after the user answers its approval request
    Then the limits shown above the composer close

  @backlog @desktop
  Scenario: /usage-limits closes when the user switches model
    Given the user opened "/usage-limits" in a Codex thread
    When the user switches the thread to Claude
    Then the limits shown above the composer close

  @backlog @desktop
  Scenario: /usage-limits is left to providers without limits in HAL-C2
    Given a thread on a provider whose limits HAL-C2 does not know
    When the user sends "/usage-limits"
    Then "/usage-limits" is sent to the provider as a message

  @backlog @desktop
  Scenario: /usage-limits with nothing to show says so and keeps the draft
    Given a Codex thread whose limits HAL-C2 has not been able to read
    When the user sends "/usage-limits"
    Then the user sees an "info" toast "Usage limits are unavailable for this provider"
    And nothing is sent to the provider and the draft still reads "/usage-limits"

  @backlog @desktop @tui
  Scenario: /feedback in a Codex thread sends feedback to OpenAI
    Given a Codex thread that has run a turn
    When the user sends "/feedback The agent stopped early"
    Then the draft is cleared and the user sees that feedback is being sent to OpenAI
    And once it is sent the user sees the feedback thread id and can copy it

  @backlog @desktop @tui
  Scenario: /feedback before the first Codex turn is refused
    Given a Codex thread with no messages yet
    When the user sends "/feedback"
    Then the user is told to send a message before submitting feedback

  @backlog @desktop @tui
  Scenario: Feedback that fails to upload says why
    Given a Codex thread that has run a turn
    When the user sends "/feedback" and the upload fails
    Then the user is told the feedback could not be sent to OpenAI and why
    And the user can dismiss the notice

  @backlog @desktop @tui
  Scenario Outline: /feedback is an ordinary message outside a plain Codex draft
    Given <situation>
    When the user sends "/feedback slow"
    Then "/feedback slow" is sent to the agent as a message

    Examples:
      | situation                                  |
      | a Claude thread                            |
      | a Codex draft that carries an image        |

  @backlog @desktop
  Scenario Outline: A suggestion list with nothing to offer says why
    When the user types "<typed>" and <situation>
    Then the suggestion list says "<message>"

    Examples:
      | typed | situation                                    | message                                             |
      | $zzz  | no skill matches                             | No skills found. Try / to browse provider commands. |
      | @zzz  | no file or folder matches                    | No matching files or folders.                       |
      | /zzz  | no command matches                           | No matching command.                                |
      | #zzz  | no pull request matches                      | No pull request matches zzz.                        |
      | #     | the repository has no pull requests          | No pull requests found in this repository.          |
      | #     | the project has no repository on a code host | Pull requests are not available for this project.   |
      | #     | the code host cannot be read                 | Pull requests could not be read for this project.   |

  @backlog @desktop
  Scenario Outline: A suggestion list that is still looking says what it is looking for
    When the user types "<typed>" and the <items> have not come back yet
    Then the suggestion list says "<message>"

    Examples:
      | typed  | items         | message                       |
      | $rev   | skills        | Searching workspace skills... |
      | @cart  | files         | Searching workspace files...  |
      | #login | pull requests | Finding pull request...       |

  @backlog @desktop
  Scenario: The suggestion list is walked with the arrow keys and wraps at its ends
    Given the user typed "@" and three files are offered
    When the user presses Up on the first suggestion
    Then the last suggestion is highlighted
    When the user presses Down
    Then the first suggestion is highlighted

  @backlog @desktop
  Scenario Outline: Enter or Tab takes the highlighted suggestion
    Given the user typed "@read" and "README.md" is highlighted
    When the user presses <key>
    Then the draft references "README.md"
    And nothing is sent

    Examples:
      | key   |
      | Enter |
      | Tab   |

  @backlog @desktop
  Scenario: The highlighted suggestion stays put while more results arrive
    Given the user typed "@cart" and moved the highlight to the second file
    When more files matching "cart" arrive
    Then the same file is still highlighted
    When the user types one more letter
    Then the first suggestion is highlighted

  @backlog @desktop
  Scenario: Suggestions are ordered by how closely their name matches
    Given the provider offers the commands "review", "review-pr" and "code-review" and the skill "pre-review"
    When the user types "/review"
    Then "review" is offered first, then "review-pr", then "code-review" and "pre-review"

  @backlog @desktop
  Scenario: Equally good matches list built-in commands, then provider commands, then skills
    Given the provider offers a command and a skill that both match "/mo" as well as "/model" does
    When the user types "/mo"
    Then "/model" is offered before the provider command, and the skill last

  @backlog @desktop
  Scenario: A skill offered among the slash commands is named as a skill
    Given skills are shown in the slash menu
    And the provider offers the skill "review"
    When the user types "/skill"
    Then "/skill:review" is offered
    When the user chooses it
    Then the draft references the skill "review"

  @backlog @desktop
  Scenario: Each skill is offered once, and only if the user may run it
    Given the provider reports the skill "review" from two places and a skill "internal" the user may not run
    When the user types "$"
    Then "review" is offered once
    And "internal" is not offered

  # Legacy: packages/client-runtime/src/providerSkills.ts (getProviderSlashCommandsForSlashMenu)
  @backlog @desktop
  Scenario: A provider command named like a skill that is offered is not listed twice
    Given skills are shown in the slash menu
    And the provider offers the skill "review" and also a command "review"
    When the user types "/review"
    Then "review" is offered once, as the skill

  # Legacy: packages/client-runtime/src/providerSkills.ts (resolveProviderSkillsForCwd, resolveProviderSlashCommandsForCwd)
  @backlog @desktop
  Scenario: A thread offers the skills and commands of the folder it works in
    Given the provider reports different skills for "/work/shop" and for "/work/blog"
    When the user types "$" in a thread working in "/work/blog"
    Then only the skills reported for "/work/blog" are offered

  # Legacy: packages/client-runtime/src/providerSkills.ts (formatProviderSkillDisplayName)
  @backlog @desktop
  Scenario Outline: A skill without a display name is named from its id
    Given the provider offers the skill "<id>" with no display name
    When the user types "$"
    Then the skill is shown as "<shown>"

    Examples:
      | id            | shown         |
      | lint-fix      | Lint Fix      |
      | pdf_reader    | Pdf Reader    |
      | plugin:review | Plugin Review |

  @backlog @desktop
  Scenario Outline: A skill says where it comes from
    Given the provider offers a skill from <place>
    When the user types "$"
    Then the skill is marked "<mark>"

    Examples:
      | place                 | mark     |
      | an app                | App      |
      | the repository        | Repo     |
      | the project           | Project  |
      | the user's own skills | Personal |
      | the system            | System   |
      | anywhere else         | Provider |

  @backlog @desktop
  Scenario: A skill is found by its description as well as its name
    Given the provider offers the skill "lint-fix" described as "Tidy the changed files"
    When the user types "$tidy"
    Then "lint-fix" is offered

  @backlog @desktop
  Scenario Outline: Any currency sign opens the skills
    Given the provider offers the skill "review"
    When the user types "<typed>"
    Then the skill "review" is offered

    Examples:
      | typed |
      | $rev  |
      | €rev  |
      | £rev  |

  @backlog @desktop
  Scenario: Threads on this environment are offered ahead of files
    Given the environment has another thread "Auth refactor" and the project has the file "auth.ts"
    When the user types "@auth"
    Then the thread "Auth refactor" is offered before "auth.ts"
    And the thread the user is writing in is not offered

  # Legacy: packages/client-runtime/src/composerThreadItems.ts (matchComposerThreadItems)
  @backlog @desktop
  Scenario: Thread suggestions need something typed, skip archived threads and stay few
    Given the environment has seven threads whose titles contain "auth", one of them archived
    When the user types "@" alone
    Then only files and folders are offered
    When the user types "@AUTH"
    Then at most five threads are offered, the most recently updated first
    And the archived thread is not offered

  @backlog @desktop
  Scenario: A pull request suggestion says whether it is open, merged or closed
    Given the project's repository has the merged pull request 41 "Add login"
    When the user types "#41"
    Then pull request 41 is offered as merged

  @backlog @desktop
  Scenario Outline: Text that only looks like a reference stays text
    When the draft reads "<text>"
    Then <outcome>

    Examples:
      | text                             | outcome                                 |
      | it costs $50 a month             | "$50" is not shown as a skill           |
      | about $5k per seat               | "$5k" is not shown as a skill           |
      | # Release notes                  | no pull requests are offered            |
      | see issue#12                     | no pull requests are offered            |
      | [docs](https://example.com/a.md) | the link is not shown as a project file |

  @backlog @desktop
  Scenario: A Markdown link to a project file becomes a file reference
    When the user pastes "[cart](src/cart.ts)" into the draft
    Then the draft references "src/cart.ts"

  @backlog @desktop
  Scenario: Closing the suggestions leaves the caret where the user was typing
    Given the user typed "fix @rea" and suggestions are offered
    When the user dismisses the suggestions
    Then the next letter the user types follows "@rea"

  @backlog @desktop
  Scenario: A provider command is put into the draft ready for its arguments
    Given the provider offers the command "review"
    When the user types "/rev" and chooses "review"
    Then the draft reads "/review " with the caret after the space
    And nothing is sent

  @backlog @desktop
  Scenario Outline: A pasted reference that cannot be brought along says why
    Given the user copied a message part that carries the file "trace.log"
    When the user pastes it into another draft and <problem>
    Then the user sees an "error" toast "Couldn't bring trace.log into this message" saying "<reason> Remove the chip or attach the file again."
    And the reference is marked unresolved

    Examples:
      | problem                                   | reason                                                                      |
      | the file is no longer kept by its MC      | The original attachment is no longer available.                             |
      | fetching the file from its MC fails       | Downloading it from the source failed.                                      |
      | the draft already carries 100 attachments | The draft rejected this attachment (duplicate or attachment limit reached). |

  @backlog @desktop
  Scenario: A message is not sent while a pasted reference is still arriving
    Given the user pasted a reference whose file is still being fetched
    When the user sends the message
    Then nothing is sent
    And the user sees an "info" toast "Still bringing a pasted attachment into this message." saying "Send again once its chip resolves."

  @backlog @desktop
  Scenario: A pasted file that arrives after the user moved on is not added to another draft
    Given the user pasted a reference whose file is still being fetched
    And the user opened another thread meanwhile
    When the file arrives
    Then the other thread's draft carries no new attachment

  @backlog @desktop
  Scenario: A copied preview annotation brings its screenshot along
    Given the draft carries a preview annotation with a screenshot
    When the user copies the annotation and pastes it into another thread's draft
    Then that draft carries the annotation with its screenshot

  @backlog @desktop
  Scenario: A thread reference pasted from another environment is left out
    Given the user copied text that references a thread in a different environment
    When the user pastes it into a draft
    Then the text is pasted without the thread reference

  @backlog @desktop
  Scenario: Pasting right after a reference keeps them apart
    Given the draft ends with a reference to "README.md"
    When the user pastes "and the tests"
    Then the draft reads the reference, a space, then "and the tests"

  @backlog @desktop
  Scenario: Undoing the removal of a reference brings back what it carried
    Given the draft carries a preview annotation with a screenshot
    When the user deletes the annotation from the draft and then undoes
    Then the draft carries the annotation with its screenshot again

  @backlog @desktop
  Scenario: A file reference opens the file it names
    Given the draft references "src/cart.ts"
    When the user clicks the reference
    Then "src/cart.ts" opens in the file viewer
    And resting on the reference shows the file's full path

  @backlog @desktop
  Scenario Outline: A skill reference says what the skill does
    Given the draft references the skill "review" which has <description>
    When the user rests on the reference
    Then the user reads "<shown>"
    And the user can open the skill's instructions

    Examples:
      | description                         | shown                                          |
      | the description "Review the change" | Review the change                              |
      | no description                      | No description is available for this skill.    |

  @backlog @desktop
  Scenario: A pull request reference shows its state and opens the pull request
    Given the draft references the merged pull request 41 "Add login"
    Then the reference is shown as merged
    When the user clicks the reference
    Then pull request 41 opens

  @backlog @desktop
  Scenario: A thread reference follows the thread's title and opens it
    Given the draft references the thread "Auth refactor"
    When that thread is renamed "Auth rewrite"
    Then the reference reads "Auth rewrite"
    When the user clicks the reference
    Then the thread "Auth rewrite" opens

  @backlog @desktop
  Scenario: A reference to a thread that was deleted says so
    Given the draft references the thread "Auth refactor"
    When that thread is deleted
    Then the reference says "Thread no longer available"
    And clicking it opens nothing

  @backlog @desktop
  Scenario: A reference whose content is gone says how to recover
    Given the draft holds a reference whose content was not kept
    When the user rests on the reference
    Then the user reads "This context is no longer available. Remove it or attach it again."

  @backlog @desktop
  Scenario: Copying the thread id from the feedback notice can fail
    Given the feedback notice shows the thread id
    When the user copies the id and the clipboard refuses
    Then the user sees an "error" toast "Could not copy thread ID"

  @backlog @desktop
  Scenario: Context added from another panel lands where the user was typing
    Given the draft reads "Look at  before merging" with the caret after "at "
    When the user adds a terminal excerpt from the terminal panel
    Then the excerpt's reference sits after "at " in the draft

  @backlog @desktop
  Scenario: Context added to a thread the user is not writing in goes at the end of its draft
    Given another thread's draft reads "Check this"
    When context is added to that thread while its composer is not open
    Then that thread's draft ends with the new reference after "Check this"
