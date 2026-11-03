# Sources:
#   The maintainer's request: "We should be able to open spaces related files from projects",
#     live both ways, configurable with a scan that writes the config, from every entry point
#   The maintainer, 2026-11-02: "We should just show the project in the sidebar you are taking
#     the approch of looking like we are importing the project files while we are looking at
#     the them and editing them. You can create some seperation if you want like collapsing
#     accordion moving between projects and spaces"
#   apps/server-ex/lib/hal_c2/project_file.ex (hal-c2.json, read from the project's folder)
#   apps/server-ex/lib/hal_c2/space.ex (the project's Space), apps/server-ex/lib/hal_c2/space/markdown.ex
#   apps/server-ex/lib/hal_c2/space/files.ex (the sync)
#   apps/server-ex/lib/hal_c2/workspace.ex (projects.writeFile), apps/server-ex/lib/hal_c2/vcs/watch.ex
#     (the checkout-changed signal a turn, a git action and a rollback already send)
#   packages/contracts/src/space.ts (space.page.openFile, space.page.syncFile, space.files.list,
#     space.files.scan, the index's projectSpace)
#   packages/contracts/src/halC2ProjectFile.ts (the spaces section)
#   apps/server-ex/priv/mcp_tools.json (hal_c2_page_open_file, hal_c2_space_files_scan)
#   features/space/pages.feature (Markdown), features/space/page-history.feature,
#     features/files/file-viewer-and-editing.feature ("An open file follows the agent's changes")
#   ~/dev/pos-ecs docs/json-diff-spec.md and docs/python-async.md, copied in as test fixtures

Feature: Project files edited as pages
  A project's Markdown files show in the Space sidebar under their project, and each opens
  in the page editor as a page that is the file: an edit on the page is written to the
  file, and a change to the file, by an agent, git or the file viewer, shows on the page.
  Agents and git see one copy, the file. Nothing is imported: the user is looking at and
  editing the project's files.

  Which files count, and as what, is the `spaces` section of the project's `hal-c2.json`.
  A scan proposes that section from the files the project has and writes it. The pages
  and the files behind them live on the MC that has the project; clients only ever ask it.

  A file's page is the project's, not a Space's: it is a page of the project's own Space,
  which the MC makes the first time a file is opened and no client shows as a Space. A
  page follows the file in the project's own folder, whatever is checked out there, never
  a thread's worktree. One file is behind at most one page. When the page and the file
  both change, the file wins, and what the page lost is a version in its history. What a
  file cannot hold stays on the page: comments, presence, the page's agent, its history
  and its trash.

  Background:
    Given a connected environment with the project "shop"
    And the Space "Research"

  Rule: Which files are Space content

    Scenario: Without a spaces section every Markdown file is a page
      Given "shop" has the files "README.md, docs/guide.md, src/app.ts"
      When the user lists the Space files of "shop"
      Then the Space files are "README.md page, docs/guide.md page"

    Scenario Outline: The spaces section says which files count
      Given "shop" has the files "README.md, docs/guide.md, notes/todo.md"
      And the spaces section of "shop" is set to "<entries>"
      When the user lists the Space files of "shop"
      Then the Space files are "<files>"

      Examples:
        | entries                          | files                                |
        | docs/**/*.md page                | docs/guide.md page                   |
        | *.md page                        | README.md page                       |
        | docs/*.md page, notes/*.md page  | docs/guide.md page, notes/todo.md page |
        | notes/todo.md page               | notes/todo.md page                   |

    Scenario: A spaces section that does not match the format counts no files
      Given "shop" has the files "README.md"
      And the spaces section of "shop" is "{\"files\": [{\"path\": \"*.md\", \"kind\": \"poster\"}]}"
      When the user lists the Space files of "shop"
      Then the Space files are ""
      And the user is told the spaces section does not match the format

    Scenario: A spaces section that does not match the format leaves the scripts alone
      Given the spaces section of "shop" is "[]"
      And "shop" declares the script "Test"
      Then the scripts of "shop" are "Test"

    Scenario: A file no entry covers is not opened
      Given "shop" has the files "README.md, src/app.ts"
      When the user opens "src/app.ts" of "shop"
      Then the user is told "src/app.ts" is not one of the project's Space files

    Scenario: A file that does not exist is not opened
      When the user opens "docs/missing.md" of "shop"
      Then the user is told there is no file "docs/missing.md"

    Scenario: Dropping a file from the section leaves its page linked
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the spaces section of "shop" is set to "notes/*.md page"
      Then the page "Guide" is still backed by "docs/guide.md"

  @mc
  Rule: Opening a file

    Scenario: A file opens as a page holding what it says
      Given "shop" has the file "docs/guide.md" reading:
        """
        # Guide

        ## Setup

        Install it.

        - [x] Clone
        - [ ] Build
        """
      When the user opens "docs/guide.md" of "shop"
      Then the pages of the Space of "shop" are "Guide"
      And the page "Guide" is backed by "docs/guide.md" of "shop"
      And the page "Guide" has the blocks:
        | kind      | text       | checked |
        | heading   | Setup      |         |
        | paragraph | Install it. |        |
        | checklist | Clone      | yes     |
        | checklist | Build      | no      |

    Scenario: A file with no title heading is named after the file
      Given "shop" has the file "notes/todo.md" reading "Buy milk"
      When the user opens "notes/todo.md" of "shop"
      Then the pages of the Space of "shop" are "todo"

    Scenario: Opening the file again goes to the same page
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the user opens "docs/guide.md" of "shop"
      Then the pages of the Space of "shop" are "Guide"
      And the user was taken to the page they opened before

    # A file's page is in its project's Space; there is no other Space to open it from.
    @dropped
    Scenario: Opening the file from another Space goes to its page where it is
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the Space "Lab"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user opens "docs/guide.md" of "shop" in "Lab"
      Then the user was taken to the page they opened before
      And the pages of "Lab" are ""

    Scenario: Opening a file whose page is in the trash brings the page back
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      And the user has moved the page "Guide" to the trash
      When the user opens "docs/guide.md" of "shop"
      Then the pages of the Space of "shop" are "Guide"

    Scenario: A thread's worktree copy opens the page of the project folder's file
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the user opens "docs/guide.md" from a worktree of "shop"
      Then the user was taken to the page they opened before
      And the page "Guide" follows the project's own folder

    Scenario: A client watching the project's Space sees the page a file opened as
      Given "shop" has the files "docs/guide.md, docs/api.md"
      And the user has opened "docs/api.md" of "shop"
      And a second client watching the Space of "shop"
      When the user opens "docs/guide.md" of "shop"
      Then the second client sees the page "Guide" backed by "docs/guide.md"

    Scenario: A project this MC does not have opens nothing here
      When the user opens "docs/guide.md" of the project "elsewhere"
      Then the user is told there is no project "elsewhere" on this MC

  # A file is the project's, not a Space's (the maintainer, 2026-11-02): its page is in the
  # project's own Space, which is no Space of the user's. It is not listed, so it does not
  # count when the MC makes Personal for a user who has no Space.
  @mc
  Rule: The project's Space

    Scenario: A file's page is in none of the user's Spaces
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      When the user opens "docs/guide.md" of "shop"
      Then the pages of "Research" are ""
      And the Spaces are "Personal, Research"

    Scenario: Every file of a project is a page of the same Space
      Given "shop" has the files "docs/guide.md, notes/todo.md"
      And the user has opened "docs/guide.md" of "shop"
      When the user opens "notes/todo.md" of "shop"
      Then the pages of the Space of "shop" are "Guide, Todo"

    Scenario: With every Space of the user's deleted, the first look still finds Personal
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the user deletes every Space they have
      Then the Spaces are "Personal"
      And the pages of the Space of "shop" are "Guide"

    Scenario: The project's Space can't be deleted as a Space of the user's
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the user deletes the Space of "shop"
      Then the Space request is refused
      And the pages of the Space of "shop" are "Guide"

  # Before the project's Space, a file opened as a page of whichever of the user's Spaces
  # the user picked (#855). The MC makes each such page an ordinary page where it is, once,
  # when it starts: the user's Space keeps what it had, and the file opens afresh in the
  # project's Space.
  @mc
  Rule: Pages a file had in a user's Space

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And "docs/guide.md" of "shop" was opened as a page of "Research" before

    Scenario: A file's page in a user's Space becomes an ordinary page there
      When the MC starts after the update
      Then the pages of "Research" are "Guide"
      And the page "Guide" is not backed by a file
      And "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    Scenario: The file then opens in the project's Space
      Given the MC started after the update
      When the user opens "docs/guide.md" of "shop"
      Then the pages of the Space of "shop" are "Guide"
      And the page "Guide" is backed by "docs/guide.md" of "shop"
      And the pages of "Research" are "Guide"

    Scenario: The page left in the user's Space no longer follows the file
      Given the MC started after the update
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nNew." and its turn ends
      Then the pages of "Research" are "Guide"
      And the page "Guide" shows "Install it."

  @mc
  Rule: The page is the file

    Background:
      Given "shop" has the file "docs/guide.md" reading:
        """
        # Guide

        Install it.
        """
      And the user has opened "docs/guide.md" of "shop"

    Scenario: An edit on the page is written to the file
      When the user changes the block "Install it." to "Install it twice."
      Then "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it twice.
        """

    Scenario: A block added on the page is written to the file
      When the user writes "Then run it." on the page "Guide"
      Then "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it.

        Then run it.
        """

    Scenario: Renaming the page writes the file's title heading
      When the user renames the page "Guide" to "Handbook"
      Then "docs/guide.md" of "shop" starts with "# Handbook"

    Scenario: Renaming a page whose file has no title heading gives it one
      Given "shop" has the file "notes/todo.md" reading "Buy milk"
      And the user has opened "notes/todo.md" of "shop"
      When the user renames the page "todo" to "Todo"
      Then "notes/todo.md" of "shop" reads:
        """
        # Todo

        Buy milk
        """

    Scenario: An agent's change to the file shows on the page when its turn ends
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it with mise." and its turn ends
      Then the page "Guide" shows "Install it with mise."

    Scenario: A table's cell and a code block's language the file changes stay in the file
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it.\n\n| Step | Owner |\n| ---- | ----- |\n| MC   | Ada   |\n\n```js\nrun()\n```" and its turn ends
      And an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it.\n\n| Step | Owner |\n| ---- | ----- |\n| MC   | Bob   |\n\n```ts\nrun()\n```" and its turn ends
      And the user changes the block "Install it." to "Install it twice."
      Then "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it twice.

        | Step | Owner |
        | ---- | ----- |
        | MC   | Bob   |

        ```ts
        run()
        ```
        """

    Scenario: A list's nesting, an alert's kind and a rule's spelling the file changes stay in the file
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it.\n\n- one\n- two\n\n> [!NOTE]\n> Mind it.\n\n***\n\n* item" and its turn ends
      And an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it.\n\n- one\n  - two\n\n> [!TIP]\n> Mind it.\n\n___\n\n> item" and its turn ends
      And the user changes the block "Install it." to "Install it twice."
      Then "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it twice.

        - one
          - two

        > [!TIP]
        > Mind it.

        ___

        > item
        """

    Scenario: A comment stays on a block the file keeps
      Given the user commented "Which version?" on the block "Install it."
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it.\n\nThen run it." and its turn ends
      Then the block "Install it." has the open comment "Which version?"

    Scenario: A comment on a block the file no longer has stays on the page
      Given the user commented "Which version?" on the block "Install it."
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nUse the installer." and its turn ends
      Then the page "Guide" still has the comment "Which version?"

    Scenario: A file saved from the file viewer shows on the page
      When the user saves "docs/guide.md" of "shop" in the file viewer as "# Guide\n\nSaved here."
      Then the page "Guide" shows "Saved here."

    Scenario: A branch switched in the project folder shows on the page
      Given "docs/guide.md" reads "# Guide\n\nOn a branch." on the branch "draft" of "shop"
      When the user switches "shop" to the branch "draft"
      Then the page "Guide" shows "On a branch."

    Scenario: A change made while the MC was stopped shows once it is back
      When the MC restarts after "docs/guide.md" of "shop" was rewritten to "# Guide\n\nChanged offline."
      Then the page "Guide" shows "Changed offline."

    Scenario: Opening the page reads its file again
      Given "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nFrom an editor."
      When the user opens the page "Guide" again
      Then the page "Guide" shows "From an editor."

    Scenario: An agent's edit of the page is written to the file and names its thread
      Given a thread "Work" in "shop"
      When the agent in "Work" changes the block "Install it." to "Install it now."
      Then "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it now.
        """
      And the newest version of "Guide" is by the thread "Work"

    Scenario: A change to the file is a version of the page by the file
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it with mise." and its turn ends
      Then the newest version of "Guide" is by the project file

    Scenario: Restoring a version of the page writes it to the file
      Given the user changed the block "Install it." to "Install it twice."
      When the user restores the version of "Guide" that read "Install it."
      Then "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it.
        """

    Scenario: A page restored from the trash shows its file as it is now
      Given the user has moved the page "Guide" to the trash
      And "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nWhile it was in the trash."
      When the user restores the page "Guide"
      Then the page "Guide" shows "While it was in the trash."

    Scenario: An edit to a file that can't be written is refused and changes neither
      Given "docs/guide.md" of "shop" is read-only
      When the user changes the block "Install it." to "My way."
      Then the user is told "docs/guide.md" could not be written
      And the page "Guide" shows "Install it."
      And "docs/guide.md" of "shop" reads:
        """
        # Guide

        Install it.
        """

  @mc
  Rule: Links in the project

    Background:
      Given "shop" has the file "AGENTS.md" reading "# Agents\n\nBe kind."
      And "CLAUDE.md" of "shop" links to "AGENTS.md"

    Scenario: A page of a link edits the file it links to and keeps the link
      Given the user has opened "CLAUDE.md" of "shop"
      When the user changes the block "Be kind." to "Be brief."
      Then "AGENTS.md" of "shop" reads "# Agents\n\nBe brief."
      And "CLAUDE.md" of "shop" still links to "AGENTS.md"

    Scenario: A link and the file it links to, each a page, take each other's edits
      Given the user has opened "CLAUDE.md" of "shop"
      And the user has opened "AGENTS.md" of "shop"
      When the user changes "Be kind." on the page of "CLAUDE.md" to "Be brief."
      And the user changes "Be brief." on the page of "AGENTS.md" to "Be terse."
      Then "AGENTS.md" of "shop" reads "# Agents\n\nBe terse."
      And the page of "CLAUDE.md" shows "Be terse." and says nothing changed under an edit
      And the page of "AGENTS.md" shows "Be terse." and says nothing changed under an edit

    Scenario: A link out of the project is not opened
      Given "NOTES.md" of "shop" links to a file outside the project
      When the user opens "NOTES.md" of "shop"
      Then the user is told "NOTES.md" is not in the project

    Scenario: A link that comes to lead out of the project leaves its page saying the file is gone
      Given the user has opened "CLAUDE.md" of "shop"
      And "CLAUDE.md" of "shop" links to a file outside the project
      When the user opens the page "Agents" again
      Then the page "Agents" says its file is gone
      And the page "Agents" shows "Be kind."

  @mc
  Rule: Nothing in the file is lost

    # Real documents from the maintainer's corpus, copied in: what a page does not model
    # (tables, code, lists, front matter) is kept as its exact source
    # (features/space/markdown.feature), so writing the page back changes only the edit.
    Scenario Outline: A real document comes back byte for byte when one paragraph changes
      Given "shop" has the file "docs/<file>" copied from the fixture "<file>"
      And the user has opened "docs/<file>" of "shop"
      When the user changes the paragraph starting "<start>" to "<after>"
      Then "docs/<file>" of "shop" is the fixture "<file>" with that paragraph changed to "<after>"

      Examples:
        | file              | start                                          | after                          |
        | json-diff-spec.md | Decode `~1` to `/`                             | Decode `~1`, then `~0`.        |
        | python-async.md   | The process entry point owns the event loop.   | The entry point owns the loop. |

    Scenario Outline: Opening a real document and writing nothing leaves it as it was
      Given "shop" has the file "docs/<file>" copied from the fixture "<file>"
      When the user opens "docs/<file>" of "shop"
      Then "docs/<file>" of "shop" is the fixture "<file>"

      Examples:
        | file              |
        | json-diff-spec.md |
        | python-async.md   |

    Scenario: A file-backed page does not update itself
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the user has "Guide" update itself with "Summarise the week" every 6 hours
      Then the user is told a page that is a file does not update itself

    Scenario: A chart is not drawn on a file-backed page
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the user asks for a chart of "sales by month" on "Guide"
      Then the user is told a chart is not drawn on a page that is a file

  @mc
  Rule: When the page and the file both change

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop"

    Scenario: The file wins over an edit made after it changed
      Given "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nThe agent's way."
      When the user changes the block "Install it." to "My way."
      Then the page "Guide" shows "The agent's way."
      And "docs/guide.md" of "shop" reads "# Guide\n\nThe agent's way."
      And the page "Guide" says the file changed under the user's edit

    Scenario: The edit the file won over is a version the user can restore
      Given "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nThe agent's way."
      And the user changed the block "Install it." to "My way."
      When the user restores the version of "Guide" that read "My way."
      Then the page "Guide" shows "My way."
      And "docs/guide.md" of "shop" reads "# Guide\n\nMy way."

    Scenario: The next edit that reaches the file clears the notice
      Given "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nThe agent's way."
      And the user changed the block "Install it." to "My way."
      When the user changes the block "The agent's way." to "Agreed."
      Then the page "Guide" no longer says the file changed under the user's edit

  @mc
  Rule: Renamed, moved and deleted files

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop"

    Scenario: A file moved as it is takes its page with it
      When an agent in "shop" moves "docs/guide.md" to "docs/handbook.md" and its turn ends
      Then the page "Guide" is backed by "docs/handbook.md" of "shop"

    Scenario: A deleted file leaves its page saying the file is gone
      When an agent in "shop" deletes "docs/guide.md" and its turn ends
      Then the page "Guide" says its file is gone
      And the page "Guide" shows "Install it."

    Scenario: An edit to a page whose file is gone is kept on the page only
      Given an agent in "shop" deleted "docs/guide.md"
      When the user changes the block "Install it." to "Still here."
      Then the page "Guide" shows "Still here."
      And "docs/guide.md" of "shop" does not exist

    Scenario: A file that comes back is followed again
      Given an agent in "shop" deleted "docs/guide.md"
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nBack again." and its turn ends
      Then the page "Guide" shows "Back again."
      And the page "Guide" no longer says its file is gone

    Scenario: A file that comes back wins over edits made while it was gone, and says so
      Given an agent in "shop" deleted "docs/guide.md"
      And the user changed the block "Install it." to "Still here."
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nBack again." and its turn ends
      Then the page "Guide" shows "Back again."
      And the page "Guide" says the file changed under the user's edit

    Scenario: A deleted file with more than one copy left is not followed to either
      Given "shop" has the file "notes/one.md" reading "# Guide\n\nInstall it."
      And "shop" has the file "notes/two.md" reading "# Guide\n\nInstall it."
      When an agent in "shop" deletes "docs/guide.md" and its turn ends
      Then the page "Guide" says its file is gone
      And the page "Guide" is still backed by "docs/guide.md"

    Scenario: A folder where the file was leaves its page saying the file is gone
      Given "docs/guide.md" of "shop" was replaced by a folder outside HAL-C2
      When the user opens the page "Guide" again
      Then the page "Guide" says its file is gone
      And the page "Guide" shows "Install it."

    Scenario: A branch without the file leaves the page saying the file is gone
      Given the branch "bare" of "shop" has no "docs/guide.md"
      When the user switches "shop" to the branch "bare"
      Then the page "Guide" says its file is gone

  # The way in is showing the project in the Space sidebar, and the way out is collapsing
  # its section (Rule: Project files in the Space sidebar). The page is the file's for as
  # long as the file is, so the MC has nothing to unlink.
  @mc
  Rule: The way out

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop"

    # No unlink: the way out is collapsing the project's section, and a copy is #899.
    @dropped
    Scenario: Unlinking makes the page an ordinary page
      When the user unlinks the page "Guide" from its file
      Then the page "Guide" is not backed by a file
      And "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    # No unlink: a page of a project's Space is always its file.
    @dropped
    Scenario: An unlinked page's edits stay off the file
      Given the user unlinked the page "Guide" from its file
      When the user changes the block "Install it." to "Only here."
      Then "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    # No unlink: a page of a project's Space is always its file.
    @dropped
    Scenario: An unlinked page no longer follows the file
      Given the user unlinked the page "Guide" from its file
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nNew." and its turn ends
      Then the page "Guide" shows "Install it."

    # No unlink: a file deleted for good opens afresh instead (below).
    @dropped
    Scenario: The file of an unlinked page opens as a new page
      Given the user unlinked the page "Guide" from its file
      When the user opens "docs/guide.md" of "shop" in "Research"
      Then the pages of "Research" are "Guide, Guide"

    # No unlink, so nothing to refuse.
    @dropped
    Scenario: Unlinking an ordinary page is refused
      Given the page "Plain"
      When the user unlinks the page "Plain" from its file
      Then the page request is refused

    Scenario: Deleting the page for good leaves the file
      Given the user has moved the page "Guide" to the trash
      When the user deletes the page "Guide" for good
      Then "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    # No unlink: a page that updates itself is an ordinary page of a user's Space.
    @dropped
    Scenario: An unlinked page can update itself
      Given the user unlinked the page "Guide" from its file
      When the user has "Guide" update itself with "Summarise the week" every 6 hours
      Then the page request is accepted

    Scenario: A file whose page was deleted for good opens as a new page
      Given the user has moved the page "Guide" to the trash
      And the user deleted the page "Guide" for good
      When the user opens "docs/guide.md" of "shop"
      Then the pages of the Space of "shop" are "Guide"
      And the page "Guide" is backed by "docs/guide.md" of "shop"

    # The MC has no page copy between Spaces yet (#899).
    @shared @backlog
    Scenario: The user makes an ordinary page of a file in a Space
      When the user makes an ordinary page of "Guide" in "Research"
      Then the pages of "Research" are "Guide"
      And the page "Guide" of "Research" is not backed by a file
      And "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

  @mc
  Rule: The scan

    Scenario: The scan writes a spaces section for the Markdown the project has
      Given "shop" has the files "README.md, CONTRIBUTING.md, docs/guide.md, docs/api/rest.md, notes/todo.md, src/app.ts"
      When the user scans "shop" for Space files
      Then the spaces section of "shop" lists "*.md page, docs/**/*.md page, notes/**/*.md page"
      And the user is told the scan wrote the spaces section

    Scenario: The scan leaves out hidden folders
      Given "shop" has the files "README.md, .github/pull_request_template.md"
      When the user scans "shop" for Space files
      Then the spaces section of "shop" lists "*.md page"

    Scenario: The scan keeps the rest of hal-c2.json as it was
      Given the hal-c2.json of "shop" reads:
        """
        {
          // Shared with the team.
          "scripts": [{ "name": "Test", "command": "mix test" }]
        }
        """
      And "shop" has the files "docs/guide.md"
      When the user scans "shop" for Space files
      Then the hal-c2.json of "shop" still has the comment "// Shared with the team."
      And the scripts of "shop" are "Test"
      And the spaces section of "shop" lists "docs/**/*.md page"

    Scenario: The scan does not overwrite a spaces section someone wrote
      Given "shop" has the files "docs/guide.md, notes/todo.md"
      And the spaces section of "shop" is set to "docs/guide.md page"
      When the user scans "shop" for Space files
      Then the spaces section of "shop" lists "docs/guide.md page"
      And the user is told the spaces section was already written and is shown "docs/**/*.md page, notes/**/*.md page"

    Scenario: The user replaces a spaces section with what the scan found
      Given "shop" has the files "docs/guide.md, notes/todo.md"
      And the spaces section of "shop" is set to "docs/guide.md page"
      When the user scans "shop" for Space files and replaces the spaces section
      Then the spaces section of "shop" lists "docs/**/*.md page, notes/**/*.md page"

    Scenario: Running the scan again with nothing new changes nothing
      Given "shop" has the files "docs/guide.md"
      And the user has scanned "shop" for Space files
      When the user scans "shop" for Space files
      Then the user is told the spaces section is already what the scan finds

    Scenario: The scan writes nothing for a project with no Markdown
      Given "shop" has the files "src/app.ts"
      When the user scans "shop" for Space files
      Then the user is told the scan found no Space files
      And "shop" has no spaces section

    Scenario: An agent scans the project and opens a file as a page
      Given a thread "Work" in "shop"
      And "shop" has the file "docs/guide.md" reading "# Guide"
      When the agent in "Work" scans "shop" for Space files
      And the agent in "Work" opens "docs/guide.md" of "shop"
      Then the spaces section of "shop" lists "*.md page, docs/**/*.md page"
      And the page "Guide" is backed by "docs/guide.md" of "shop"

    Scenario: An agent reading a file-backed page is told which file it is
      Given a thread "Work" in "shop"
      And "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop"
      When the agent in "Work" reads the page "Guide"
      Then the agent sees the page is backed by "docs/guide.md" of "shop"

  @mc
  Rule: Listing a project's Space files

    Scenario: The list says which files are open and the project's Space
      Given "shop" has the files "docs/guide.md, docs/api.md"
      And the user has opened "docs/guide.md" of "shop"
      When the user lists the Space files of "shop"
      Then "docs/guide.md" is listed as the page "Guide" in the Space of "shop"
      And "docs/api.md" is listed as not open
      And the list names the Space of "shop"

    Scenario: Before a file is opened the list names no Space
      Given "shop" has the files "docs/guide.md"
      When the user lists the Space files of "shop"
      Then "docs/guide.md" is listed as not open
      And the list names no Space yet

  # The clients before the sidebar: each opened a file as a page *in a Space*, which read as
  # an import (the maintainer, 2026-11-02). The sidebar rule below replaces what is dropped.
  @shared
  Rule: Opening project files from the clients

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."

    # Not "in a Space": the file explorer edits the file as a page in its project's section.
    @dropped
    Scenario: The user opens a file in a Space from the file explorer
      Given the user is browsing the files of "shop"
      When the user opens "docs/guide.md" in a Space from its menu
      Then the Space shows the page "Guide"

    # Not "in a Space": the file viewer edits the file as a page in its project's section.
    @dropped
    Scenario: The user opens the file they are reading in a Space
      Given the user is reading "docs/guide.md" in the file viewer
      When the user opens it in a Space
      Then the Space shows the page "Guide"

    # Not "in a Space": a chat link edits the file as a page in its project's section.
    @dropped
    Scenario: The user opens a file the agent mentioned in a Space
      Given the agent's message in a thread of "shop" links "docs/guide.md"
      When the user opens that link in a Space
      Then the Space shows the page "Guide"

    # Nothing is added to a Space: the project's section in the sidebar holds its files.
    @dropped
    Scenario: The user adds a page from a project's files inside the Space
      Given the user is in the Space "Research"
      When the user adds a page from the files of "shop" and picks "docs/guide.md"
      Then the Space shows the page "Guide"

    # Not "in a Space": the command palette edits the file as a page.
    @dropped
    Scenario: The user opens a project file in a Space from the command palette
      When the user asks the command palette to open "docs/guide.md" in a Space
      Then the Space shows the page "Guide"

    # Replaced by the sidebar rule's scan, which shows the project's section.
    @dropped
    Scenario: The user runs the scan from the command palette
      When the user asks the command palette to scan "shop" for Space files
      Then the user is told the scan wrote the spaces section

    # Reworded for "Edit as a page" in the sidebar rule.
    @dropped
    Scenario: A file that is not Space content is not offered
      Given "shop" has the file "src/app.ts" reading "export {}"
      When the user is browsing the files of "shop"
      Then "src/app.ts" offers no way to open it in a Space

    # Moot: a file's page is in its project's Space, wherever the user was.
    @dropped
    Scenario: A file outside a Space opens where the user last was
      Given the user last had the Space "Research" open
      When the user opens "docs/guide.md" in a Space from its menu
      Then the page "Guide" is in "Research"

    # The MC makes the Space "Personal" when it lists none, as it does for the Spaces pane.
    # Moot: the project's Space is made for the file, and Personal does not count it.
    @dropped
    Scenario: Opening a file with no Space opens it in the Space the MC makes
      Given every Space was deleted
      When the user asks the command palette to open "docs/guide.md" in a Space
      Then the page "Guide" is in "Personal"

    # A page follows the file in the project's own folder, never a thread's worktree.
    # Reworded for "Edit as a page" in the sidebar rule.
    @dropped
    Scenario: A file only in a thread's worktree has no page to open
      Given a thread of "shop" works in a worktree where "docs/draft.md" reads "# Draft"
      When the user is browsing the files of "shop"
      Then "docs/draft.md" offers no way to open it in a Space

    # Reworded for "Edit the project's copy as a page" in the sidebar rule.
    @dropped
    Scenario: Opening a file from a worktree thread opens the project's copy
      Given a thread of "shop" works in a worktree where "docs/guide.md" reads "# Guide\n\nDraft."
      When the user opens the project's copy of "docs/guide.md" in a Space from its menu
      Then the Space shows the page "Guide"
      And the page "Guide" shows "Install it."

    # Reworded in the sidebar rule: the page is opened from its project, not in "Research".
    @dropped
    Scenario: A file-backed page shows its file
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      When the user shows the page "Guide"
      Then the page says it is the file "docs/guide.md" of "shop"

    # Reworded in the sidebar rule: the page is opened from its project, not in "Research".
    @dropped
    Scenario: The user goes from a page to its file
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      When the user shows the file of the page "Guide"
      Then the file viewer shows "docs/guide.md" of "shop"

    # A running turn updates its thread's row often; the files change only with the project.
    # Still so with the sidebar: it asks for the files as the file explorer does.
    @backlog-tui
    Scenario: A client asks for a project's files once while its thread runs
      Given the user is browsing the files of "shop"
      When the thread's row changes 5 times
      Then the MC is not asked for the files of "shop" again

    # The Files tab of a worktree thread shows the worktree's copy, not the file the page follows.
    # Reworded in the sidebar rule: the page is opened from its project, not in "Research".
    @dropped @backlog-tui
    Scenario: Going to a page's file passes over a thread in a worktree
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And a newer thread of "shop" works in a worktree
      When the user shows the file of the page "Guide"
      Then the file viewer shows the project's own "docs/guide.md" of "shop"

    # Reworded in the sidebar rule: the page is opened from its project, not in "Research".
    @dropped
    Scenario: A page whose file is gone says so
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And an agent in "shop" deleted "docs/guide.md"
      When the user shows the page "Guide"
      Then the page says its file is gone

    # Reworded in the sidebar rule: the page is opened from its project, not in "Research".
    @dropped
    Scenario: A page the file won over says where the user's edit went
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And the file won over the user's edit of "Guide"
      When the user shows the page "Guide"
      Then the page says the file changed under the user's edit and the edit is in its history

    # No unlink: the way out is collapsing the project's section.
    @dropped
    Scenario: The user unlinks a page from its file
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      When the user unlinks the page "Guide" from its file
      Then the page no longer says it is a file

    # The TUI's Space pane follows only its own MC's Spaces (#860).
    # The desktop's Space view shows only its own MC's Spaces (#865).
    # The phone's Space screen follows only its own MC's Spaces (#860).
    # Reworded in the sidebar rule: that machine's project shows as a section.
    @dropped @backlog-tui @backlog-desktop @backlog-mobile
    Scenario: A project on another machine opens its files in that machine's Space
      Given the project "shop" is on another connected environment
      When the user opens "docs/guide.md" in a Space from its menu
      Then the page "Guide" is in a Space of that environment

    # Reworded in the sidebar rule: the page is opened from its project, not in "Research".
    @dropped
    Scenario: Showing a file-backed page reads its file again
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nFrom an editor."
      When the user shows the page "Guide"
      Then the page "Guide" shows "From an editor."

  # The Space sidebar has the Space's own pages, then a section for each project on the
  # Space's MC whose Space files list is not empty: every such project, with nothing to
  # pin or set up, since a project with Markdown is what the user would look for, and one
  # without has nothing to show. A project on another MC is not shown yet (#860). Sections
  # start collapsed, so a Space with many projects still opens on its own pages, and each
  # client remembers which the user expanded. Collapsing a section is the way out, and
  # expanding it the way back. Every other way in says "Edit as a page".
  @shared
  Rule: Project files in the Space sidebar

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."

    Scenario: The sidebar has a section for each project with Space files
      Given the project "tools" has no Space files
      When the user is in the Space "Research"
      Then the sidebar's project sections are "shop"

    Scenario: A project's section starts collapsed
      When the user is in the Space "Research"
      Then the section of "shop" is collapsed

    Scenario: Expanding a project's section shows its files by folder
      Given the user is in the Space "Research"
      When the user expands the section of "shop"
      Then the section of "shop" shows "guide.md" in the folder "docs"

    Scenario: Collapsing a project's section hides its files
      Given the user is in the Space "Research"
      And the user expanded the section of "shop"
      When the user collapses the section of "shop"
      Then the section of "shop" is collapsed

    Scenario: The client remembers which sections are expanded
      Given the user is in the Space "Research"
      And the user expanded the section of "shop"
      When the client starts again
      Then the section of "shop" is expanded

    Scenario: The user edits a file from its project's section
      Given the user is in the Space "Research"
      And the user expanded the section of "shop"
      When the user picks "docs/guide.md" in the section of "shop"
      Then the page editor shows the page "Guide"
      And the page "Guide" is not among the pages of "Research"

    Scenario: The user goes back to the Space's pages in one step
      Given the Space "Research" with the page "Plan"
      And the user is editing "docs/guide.md" of "shop" from its section
      When the user picks the page "Plan" in the sidebar
      Then the page editor shows the page "Plan"

    Scenario: The user edits a file as a page from the file explorer
      Given the user is browsing the files of "shop"
      When the user picks "Edit as a page" on "docs/guide.md"
      Then the page editor shows the page "Guide" in the section of "shop"

    Scenario: The user edits the file they are reading as a page
      Given the user is reading "docs/guide.md" in the file viewer
      When the user picks "Edit as a page" in the file viewer
      Then the page editor shows the page "Guide" in the section of "shop"

    Scenario: The user edits a file the agent mentioned as a page
      Given the agent's message in a thread of "shop" links "docs/guide.md"
      When the user picks "Edit as a page" on that link
      Then the page editor shows the page "Guide" in the section of "shop"

    Scenario: The user edits a project file as a page from the command palette
      When the user asks the command palette to edit "docs/guide.md" of "shop" as a page
      Then the page editor shows the page "Guide" in the section of "shop"

    Scenario: The user runs the scan from the command palette
      Given the project "tools" has the file "README.md" reading "# Tools"
      When the user asks the command palette to scan "tools" for Space files
      Then the user is told the scan wrote the spaces section
      And the sidebar's project sections are "shop, tools"

    Scenario: A file that is not Space content is not offered
      Given "shop" has the file "src/app.ts" reading "export {}"
      When the user is browsing the files of "shop"
      Then "src/app.ts" offers no "Edit as a page"

    # A page follows the file in the project's own folder, never a thread's worktree.
    Scenario: A file only in a thread's worktree has no page to edit
      Given a thread of "shop" works in a worktree where "docs/draft.md" reads "# Draft"
      When the user is browsing the files of "shop"
      Then "docs/draft.md" offers no "Edit as a page"

    Scenario: From a worktree thread the user edits the project's copy
      Given a thread of "shop" works in a worktree where "docs/guide.md" reads "# Guide\n\nDraft."
      When the user picks "Edit the project's copy as a page" on "docs/guide.md"
      Then the page editor shows the page "Guide" in the section of "shop"
      And the page "Guide" shows "Install it."

    Scenario: A file-backed page shows its file
      Given the user has opened "docs/guide.md" of "shop"
      When the user shows the page "Guide"
      Then the page says it is the file "docs/guide.md" of "shop"

    Scenario: The user goes from a page to its file
      Given the user has opened "docs/guide.md" of "shop"
      When the user shows the file of the page "Guide"
      Then the file viewer shows "docs/guide.md" of "shop"

    # The Files tab of a worktree thread shows the worktree's copy, not the file the page follows.
    Scenario: Going to a page's file passes over a thread in a worktree
      Given the user has opened "docs/guide.md" of "shop"
      And a newer thread of "shop" works in a worktree
      When the user shows the file of the page "Guide"
      Then the file viewer shows the project's own "docs/guide.md" of "shop"

    # space.files.list lists only files that exist, so the section has no row for it (#929).
    @backlog-tui
    Scenario: A page whose file is gone says so
      Given the user has opened "docs/guide.md" of "shop"
      And an agent in "shop" deleted "docs/guide.md"
      When the user shows the page "Guide"
      Then the page says its file is gone

    Scenario: A page the file won over says where the user's edit went
      Given the user has opened "docs/guide.md" of "shop"
      And the file won over the user's edit of "Guide"
      When the user shows the page "Guide"
      Then the page says the file changed under the user's edit and the edit is in its history

    Scenario: Showing a file-backed page reads its file again
      Given the user has opened "docs/guide.md" of "shop"
      And "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nFrom an editor."
      When the user shows the page "Guide"
      Then the page "Guide" shows "From an editor."

    # Each client follows only its own MC's projects and Spaces (#860).
    # The desktop's Space view shows only its own MC's Spaces (#865).
    # The phone's Space screen shows only its own MC's Spaces too (#860).
    # The TUI's Space pane lists only its own MC's projects as sections (#860).
    @backlog-desktop @backlog-mobile @backlog-tui
    Scenario: A project on another machine shows as a section from that machine
      Given the project "shop" is on another connected environment
      When the user is in the Space "Research"
      Then the sidebar's project sections are "shop"
      And picking "docs/guide.md" in the section of "shop" edits it on that environment

  # A deck from a file of slides, and an image that follows its file, are kinds the spaces
  # section will take once these pass (#853).
  @mc @shared @backlog
  Rule: Other kinds of Space file

    Scenario: A Markdown file of slides opens as a deck
      Given the spaces section of "shop" is set to "slides/*.md deck"
      And "shop" has the file "slides/launch.md" reading "# Launch\n\n---\n\n# Why"
      When the user opens "slides/launch.md" of "shop"
      Then the deck "Launch" has the slides "Launch, Why"

    Scenario: An image file opens as an image that follows the file
      Given the spaces section of "shop" is set to "assets/*.png image"
      And "shop" has the image file "assets/logo.png"
      When the user opens "assets/logo.png" of "shop"
      Then the images of the Space of "shop" are "logo.png"

    Scenario: A published file-backed page is a site that follows the file
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop"
      And the user has published the page "Guide"
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nNew." and its turn ends
      Then the site of "Guide" reads "New."
