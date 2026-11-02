# Sources:
#   The maintainer's request: "We should be able to open spaces related files from projects",
#     live both ways, configurable with a scan that writes the config, from every entry point
#   apps/server-ex/lib/hal_c2/project_file.ex (hal-c2.json, read from the project's folder)
#   apps/server-ex/lib/hal_c2/space.ex, apps/server-ex/lib/hal_c2/space/markdown.ex
#   apps/server-ex/lib/hal_c2/space/files.ex (the sync)
#   apps/server-ex/lib/hal_c2/workspace.ex (projects.writeFile), apps/server-ex/lib/hal_c2/vcs/watch.ex
#     (the checkout-changed signal a turn, a git action and a rollback already send)
#   packages/contracts/src/space.ts (space.page.openFile, space.page.syncFile,
#     space.page.unlinkFile, space.files.list, space.files.scan)
#   packages/contracts/src/halC2ProjectFile.ts (the spaces section)
#   apps/server-ex/priv/mcp_tools.json (hal_c2_page_open_file, hal_c2_space_files_scan)
#   features/space/pages.feature (Markdown), features/space/page-history.feature,
#     features/files/file-viewer-and-editing.feature ("An open file follows the agent's changes")
#   ~/dev/pos-ecs docs/json-diff-spec.md and docs/python-async.md, copied in as test fixtures

Feature: Project files as Space pages
  A project's Markdown can be opened as a page of a Space, and that page is the file:
  an edit on the page is written to the file, and a change to the file, by an agent,
  git or the file viewer, shows on the page. Agents and git see one copy, the file.

  Which files count, and as what, is the `spaces` section of the project's `hal-c2.json`.
  A scan proposes that section from the files the project has and writes it. Pages and
  the files behind them live on the MC that has the project; clients only ever ask it.

  A page follows the file in the project's own folder, whatever is checked out there,
  never a thread's worktree. One file is behind at most one page. When the page and the
  file both change, the file wins, and what the page lost is a version in its history.
  What a file cannot hold stays on the page: comments, presence, the page's agent, its
  history, where it sits in the Space and its trash.

  Background:
    Given a connected environment with the project "shop"
    And the Space "Research"

  @mc
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

    Scenario: A file no entry covers is not opened in a Space
      Given "shop" has the files "README.md, src/app.ts"
      When the user opens "src/app.ts" of "shop" in "Research"
      Then the user is told "src/app.ts" is not one of the project's Space files

    Scenario: A file that does not exist is not opened
      When the user opens "docs/missing.md" of "shop" in "Research"
      Then the user is told there is no file "docs/missing.md"

    Scenario: Dropping a file from the section leaves its page linked
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the spaces section of "shop" is set to "notes/*.md page"
      Then the page "Guide" is still backed by "docs/guide.md"

  @mc
  Rule: Opening a file in a Space

    Scenario: A file opens as a page holding what it says
      Given "shop" has the file "docs/guide.md" reading:
        """
        # Guide

        ## Setup

        Install it.

        - [x] Clone
        - [ ] Build
        """
      When the user opens "docs/guide.md" of "shop" in "Research"
      Then the pages of "Research" are "Guide"
      And the page "Guide" is backed by "docs/guide.md" of "shop"
      And the page "Guide" has the blocks:
        | kind      | text       | checked |
        | heading   | Setup      |         |
        | paragraph | Install it. |        |
        | checklist | Clone      | yes     |
        | checklist | Build      | no      |

    Scenario: A file with no title heading is named after the file
      Given "shop" has the file "notes/todo.md" reading "Buy milk"
      When the user opens "notes/todo.md" of "shop" in "Research"
      Then the pages of "Research" are "todo"

    Scenario: Opening the file again goes to the same page
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user opens "docs/guide.md" of "shop" in "Research"
      Then the pages of "Research" are "Guide"
      And the user was taken to the page they opened before

    Scenario: Opening the file from another Space goes to its page where it is
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the Space "Lab"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user opens "docs/guide.md" of "shop" in "Lab"
      Then the user was taken to the page they opened before
      And the pages of "Lab" are ""

    Scenario: Opening a file whose page is in the trash brings the page back
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      And the user has moved the page "Guide" to the trash
      When the user opens "docs/guide.md" of "shop" in "Research"
      Then the pages of "Research" are "Guide"

    Scenario: A thread's worktree copy opens the page of the project folder's file
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user opens "docs/guide.md" from a worktree of "shop" in "Research"
      Then the user was taken to the page they opened before
      And the page "Guide" follows the project's own folder

    Scenario: A client watching the Space sees the page a file opened as
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And a second client watching the Space "Research"
      When the user opens "docs/guide.md" of "shop" in "Research"
      Then the second client sees the page "Guide" backed by "docs/guide.md"

    Scenario: A project this MC does not have opens nothing here
      When the user opens "docs/guide.md" of the project "elsewhere" in "Research"
      Then the user is told there is no project "elsewhere" on this MC

  @mc
  Rule: The page is the file

    Background:
      Given "shop" has the file "docs/guide.md" reading:
        """
        # Guide

        Install it.
        """
      And the user has opened "docs/guide.md" of "shop" in "Research"

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
      And the user has opened "notes/todo.md" of "shop" in "Research"
      When the user renames the page "todo" to "Todo"
      Then "notes/todo.md" of "shop" reads:
        """
        # Todo

        Buy milk
        """

    Scenario: An agent's change to the file shows on the page when its turn ends
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nInstall it with mise." and its turn ends
      Then the page "Guide" shows "Install it with mise."

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

  @mc
  Rule: Nothing in the file is lost

    # Real documents from the maintainer's corpus, copied in: what a page does not model
    # (tables, code, lists, front matter) is kept as its exact source
    # (features/space/markdown.feature), so writing the page back changes only the edit.
    Scenario Outline: A real document comes back byte for byte when one paragraph changes
      Given "shop" has the file "docs/<file>" copied from the fixture "<file>"
      And the user has opened "docs/<file>" of "shop" in "Research"
      When the user changes the paragraph starting "<start>" to "<after>"
      Then "docs/<file>" of "shop" is the fixture "<file>" with that paragraph changed to "<after>"

      Examples:
        | file              | start                                          | after                          |
        | json-diff-spec.md | Decode `~1` to `/`                             | Decode `~1`, then `~0`.        |
        | python-async.md   | The process entry point owns the event loop.   | The entry point owns the loop. |

    Scenario Outline: Opening a real document and writing nothing leaves it as it was
      Given "shop" has the file "docs/<file>" copied from the fixture "<file>"
      When the user opens "docs/<file>" of "shop" in "Research"
      Then "docs/<file>" of "shop" is the fixture "<file>"

      Examples:
        | file              |
        | json-diff-spec.md |
        | python-async.md   |

    Scenario: A file-backed page does not update itself
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user has "Guide" update itself with "Summarise the week" every 6 hours
      Then the user is told a page that is a file does not update itself

    Scenario: A chart is not drawn on a file-backed page
      Given "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user asks for a chart of "sales by month" on "Guide"
      Then the user is told a chart is not drawn on a page that is a file

  @mc
  Rule: When the page and the file both change

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop" in "Research"

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
      And the user has opened "docs/guide.md" of "shop" in "Research"

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

    Scenario: A branch without the file leaves the page saying the file is gone
      Given the branch "bare" of "shop" has no "docs/guide.md"
      When the user switches "shop" to the branch "bare"
      Then the page "Guide" says its file is gone

  @mc
  Rule: The way out

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop" in "Research"

    Scenario: Unlinking makes the page an ordinary page
      When the user unlinks the page "Guide" from its file
      Then the page "Guide" is not backed by a file
      And "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    Scenario: An unlinked page's edits stay off the file
      Given the user unlinked the page "Guide" from its file
      When the user changes the block "Install it." to "Only here."
      Then "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    Scenario: An unlinked page no longer follows the file
      Given the user unlinked the page "Guide" from its file
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nNew." and its turn ends
      Then the page "Guide" shows "Install it."

    Scenario: The file of an unlinked page opens as a new page
      Given the user unlinked the page "Guide" from its file
      When the user opens "docs/guide.md" of "shop" in "Research"
      Then the pages of "Research" are "Guide, Guide"

    Scenario: Unlinking an ordinary page is refused
      Given the page "Plain"
      When the user unlinks the page "Plain" from its file
      Then the page request is refused

    Scenario: Deleting the page for good leaves the file
      Given the user has moved the page "Guide" to the trash
      When the user deletes the page "Guide" for good
      Then "docs/guide.md" of "shop" reads "# Guide\n\nInstall it."

    Scenario: An unlinked page can update itself
      Given the user unlinked the page "Guide" from its file
      When the user has "Guide" update itself with "Summarise the week" every 6 hours
      Then the page request is accepted

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
      And the agent in "Work" opens "docs/guide.md" of "shop" in "Research"
      Then the spaces section of "shop" lists "*.md page, docs/**/*.md page"
      And the page "Guide" is backed by "docs/guide.md" of "shop"

    Scenario: An agent reading a file-backed page is told which file it is
      Given a thread "Work" in "shop"
      And "shop" has the file "docs/guide.md" reading "# Guide"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the agent in "Work" reads the page "Guide"
      Then the agent sees the page is backed by "docs/guide.md" of "shop"

  @mc
  Rule: Listing a project's Space files

    Scenario: The list says which files are open and where
      Given "shop" has the files "docs/guide.md, docs/api.md"
      And the user has opened "docs/guide.md" of "shop" in "Research"
      When the user lists the Space files of "shop"
      Then "docs/guide.md" is listed as the page "Guide" in "Research"
      And "docs/api.md" is listed as not open

  # The clients: every way in, the indicator and the way out. Each client asks the MC that
  # has the project; none reads or writes the file itself.
  @shared @backlog-mobile @backlog-tui
  Rule: Opening project files from the clients

    Background:
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."

    Scenario: The user opens a file in a Space from the file explorer
      Given the user is browsing the files of "shop"
      When the user opens "docs/guide.md" in a Space from its menu
      Then the Space shows the page "Guide"

    Scenario: The user opens the file they are reading in a Space
      Given the user is reading "docs/guide.md" in the file viewer
      When the user opens it in a Space
      Then the Space shows the page "Guide"

    Scenario: The user opens a file the agent mentioned in a Space
      Given the agent's message in a thread of "shop" links "docs/guide.md"
      When the user opens that link in a Space
      Then the Space shows the page "Guide"

    Scenario: The user adds a page from a project's files inside the Space
      Given the user is in the Space "Research"
      When the user adds a page from the files of "shop" and picks "docs/guide.md"
      Then the Space shows the page "Guide"

    Scenario: The user opens a project file in a Space from the command palette
      When the user asks the command palette to open "docs/guide.md" in a Space
      Then the Space shows the page "Guide"

    Scenario: The user runs the scan from the command palette
      When the user asks the command palette to scan "shop" for Space files
      Then the user is told the scan wrote the spaces section

    Scenario: A file that is not Space content is not offered
      Given "shop" has the file "src/app.ts" reading "export {}"
      When the user is browsing the files of "shop"
      Then "src/app.ts" offers no way to open it in a Space

    Scenario: A file outside a Space opens where the user last was
      Given the user last had the Space "Research" open
      When the user opens "docs/guide.md" in a Space from its menu
      Then the page "Guide" is in "Research"

    Scenario: A file-backed page shows its file
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      When the user shows the page "Guide"
      Then the page says it is the file "docs/guide.md" of "shop"

    Scenario: The user goes from a page to its file
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      When the user shows the file of the page "Guide"
      Then the file viewer shows "docs/guide.md" of "shop"

    Scenario: A page whose file is gone says so
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And an agent in "shop" deleted "docs/guide.md"
      When the user shows the page "Guide"
      Then the page says its file is gone

    Scenario: A page the file won over says where the user's edit went
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And the file won over the user's edit of "Guide"
      When the user shows the page "Guide"
      Then the page says the file changed under the user's edit and the edit is in its history

    Scenario: The user unlinks a page from its file
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      When the user unlinks the page "Guide" from its file
      Then the page no longer says it is a file

    # The desktop's Space view shows only its own MC's Spaces (#865).
    @backlog-desktop
    Scenario: A project on another machine opens its files in that machine's Space
      Given the project "shop" is on another connected environment
      When the user opens "docs/guide.md" in a Space from its menu
      Then the page "Guide" is in a Space of that environment

    Scenario: Showing a file-backed page reads its file again
      Given the user has opened "docs/guide.md" of "shop" in "Research"
      And "docs/guide.md" of "shop" was rewritten outside HAL-C2 to "# Guide\n\nFrom an editor."
      When the user shows the page "Guide"
      Then the page "Guide" shows "From an editor."

  # A deck from a file of slides, and an image that follows its file, are kinds the spaces
  # section will take once these pass (#853).
  @mc @shared @backlog
  Rule: Other kinds of Space file

    Scenario: A Markdown file of slides opens as a deck
      Given the spaces section of "shop" is set to "slides/*.md deck"
      And "shop" has the file "slides/launch.md" reading "# Launch\n\n---\n\n# Why"
      When the user opens "slides/launch.md" of "shop" in "Research"
      Then the deck "Launch" has the slides "Launch, Why"

    Scenario: An image file opens as an image of the Space that follows the file
      Given the spaces section of "shop" is set to "assets/*.png image"
      And "shop" has the image file "assets/logo.png"
      When the user opens "assets/logo.png" of "shop" in "Research"
      Then the images of "Research" are "logo.png"

    Scenario: A published file-backed page is a site that follows the file
      Given "shop" has the file "docs/guide.md" reading "# Guide\n\nInstall it."
      And the user has opened "docs/guide.md" of "shop" in "Research"
      And the user has published the page "Guide"
      When an agent in "shop" rewrites "docs/guide.md" to "# Guide\n\nNew." and its turn ends
      Then the site of "Guide" reads "New."
