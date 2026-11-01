# Sources:
#   features/space/beyond-pages.feature ("The user looks back through a page's history")
#   spaces-feature-bdd-tests branch, features/space/living-pages-and-visualizations.feature and
#     apps/desktop-qt/examples/space/VersionHistoryDrawer.qml (the prototype; read for ideas only)
#   packages/contracts/src/space.ts (space.page.history, space.page.version, space.page.restoreVersion)
#   apps/server-ex/lib/hal_c2/space/history.ex
#   features/space/images.feature (a block on an image that left stays and says so)
#   features/space/sites.feature (a site is behind when publishing again would change it)

Feature: A page's history
  A page's history is read from the Space's event log, on demand and a stretch at a
  time; it is never kept as a second copy nor sent down the live stream. A version is
  one author's run of edits with no more than five minutes between any two of them,
  and it holds the page's title and blocks. Restoring a version is itself a new edit:
  nothing in the history is rewritten or lost. Comments are not versioned.

  Background:
    Given a connected environment with the thread "Work" in the project "shop"
    And the Space "Research" with the page "Roadmap"
    And "Roadmap" has the blocks "Draft"
    And a while passes
    And the user changes the block "Draft" to "Final"

  @mc @desktop @mobile @tui
  Rule: Looking back and restoring

    Scenario: The history lists a page's versions, newest first
      When the user opens the history of "Roadmap"
      Then the history has 2 versions
      And each version says when it was written and by the user
      And the newest version is the page as it is now

    Scenario: A version an agent wrote names its thread
      Given a while passes
      And the agent in "Work" adds the block "Agent note" to "Roadmap"
      When the user opens the history of "Roadmap"
      Then the newest version was written by the thread "Work"

    Scenario: Reading a version changes nothing
      When the user reads the version 1 back on "Roadmap"
      Then the version reads "Draft"
      And the blocks of "Roadmap" read "Final"

    Scenario: The user closes a version they were reading
      Given the user reads the version 1 back on "Roadmap"
      When the user goes back to the list of versions
      Then the history has 2 versions
      And no version is being read

    Scenario: Restoring a version makes the page look like it again
      When the user restores the version 1 back on "Roadmap"
      Then the blocks of "Roadmap" read "Draft"
      And the history has 3 versions
      And the newest version says it restored an earlier one

    Scenario: A restore can be undone by restoring the version before it
      Given the user restores the version 1 back on "Roadmap"
      When the user restores the version 1 back on "Roadmap"
      Then the blocks of "Roadmap" read "Final"
      And the history has 4 versions

    Scenario: A version shows its image as the image is now
      Given the image "cat.png" in "Research"
      And "Roadmap" shows the image "cat.png" already
      When the user reads the version 0 back on "Roadmap"
      Then the version shows the image "cat.png"
      When the image "cat.png" is in the image trash
      Then the version says the image "cat.png" is in the trash

    Scenario: A client watching the Space sees a restore land
      Given a second client watching the Space "Research"
      When the user restores the version 1 back on "Roadmap"
      Then the second client sees the block "Draft"

    Scenario: The history of a page in the trash can be read but not restored
      Given the page "Roadmap" is in the trash
      When the user opens the history of "Roadmap"
      Then the history has 2 versions
      And the user cannot restore a version of "Roadmap"

  @mc
  Rule: What makes a version

    Scenario: A run of edits is one version
      Given the user changes the block "Final" to "Finaler"
      And the user changes the block "Finaler" to "Finalest"
      When the user opens the history of "Roadmap"
      Then the history has 2 versions
      And the version 1 back reads "Draft"

    Scenario: Another author starts another version
      Given the agent in "Work" changes the block "Final" to "Agent's"
      And the user changes the block "Agent's" to "Mine"
      When the user opens the history of "Roadmap"
      Then the history has 4 versions
      And the version 1 back was written by the thread "Work"

    Scenario: An agent's delete names its thread
      Given the agent in "Work" deletes the block "Final"
      When the user opens the history of "Roadmap"
      Then the newest version was written by the thread "Work"

    Scenario: Renaming a page is an edit, and a restore brings the old title back
      Given a while passes
      And the user renames the page "Roadmap" to "Plan"
      When the user restores the version 1 back on "Plan"
      Then the pages of "Research" are "Roadmap"

    Scenario: A restored version stands alone from the edits after it
      Given the user restores the version 1 back on "Roadmap"
      And the user changes the block "Draft" to "Redraft"
      When the user opens the history of "Roadmap"
      Then the history has 4 versions

    Scenario: Restoring the version the page already is changes nothing
      When the user restores the version 0 back on "Roadmap"
      Then the blocks of "Roadmap" read "Final"
      And the history has 2 versions

    Scenario: The versions come a stretch at a time
      Given a while passes
      And the user changes the block "Final" to "Third"
      And a while passes
      And the user changes the block "Third" to "Fourth"
      When the user asks for 3 versions of "Roadmap"
      Then 3 versions come, and there are more
      When the user asks for the versions after those
      Then 1 version comes, and there are no more

  @desktop
  Rule: Beside a deck

    Scenario: Opening a deck closes the history
      Given the user reads the version 1 back on "Roadmap"
      When the user makes the deck "Pitch"
      Then the history is closed
      And no version is being read

  @mc
  Rule: What happens to a page's history

    Scenario: A page imported from Markdown starts its history at the import
      When the user imports this Markdown into "Research":
        """
        # Imported

        Ship pages
        """
      And the user opens the history of "Imported"
      Then the history has 1 version
      And the version 0 back reads "Ship pages"

    Scenario: A page from a thread starts its history with the thread's name
      Given text generation is available
      And the thread "Work" talked about a release plan
      When the user makes a page in "Research" from the thread "Work"
      And the user opens the history of "Release plan"
      Then the history has 1 version
      And the newest version was written by the thread "Work"

    Scenario: Moving a page or trashing and restoring it adds no version
      Given the page "Ideas"
      When the user moves the page "Roadmap" into "Ideas"
      And the user moves the page "Roadmap" to the trash
      And the user restores the page "Roadmap"
      And the user opens the history of "Roadmap"
      Then the history has 2 versions

    Scenario: A restore leaves the page where it is
      Given the page "Ideas"
      And the user moves the page "Roadmap" into "Ideas"
      When the user restores the version 1 back on "Roadmap"
      Then "Roadmap" is a subpage of "Ideas"

    Scenario: A restore moves a published page's site as any edit does
      Given the page "Roadmap" is published as a site
      When the user restores the version 1 back on "Roadmap"
      Then the page "Roadmap" shows its site is behind
      When the user restores the version 1 back on "Roadmap"
      Then the page "Roadmap" shows its site is up to date
      And the history has 4 versions

    Scenario: A restore brings an image's block back, whatever became of the image
      Given the image "cat.png" in "Research"
      And "Roadmap" shows the image "cat.png" already
      And a while passes
      And the user removes the image from "Roadmap"
      And the image "cat.png" is in the image trash
      When the user restores the version 1 back on "Roadmap"
      Then "Roadmap" says the image "cat.png" is in the trash
      When the user restores the image "cat.png"
      Then "Roadmap" shows the image "cat.png"

    Scenario: A deleted block comes back without its comments
      Given a while passes
      And the comment "Which week?" on the block "Final"
      And the user deletes the block "Final"
      When the user restores the version 1 back on "Roadmap"
      Then the blocks of "Roadmap" read "Final"
      And the block "Final" has no comments

    Scenario: A comment outlives a restore that takes its block away
      Given a while passes
      And the user adds a paragraph block "Later" to "Roadmap"
      And the comment "Why?" on the block "Later"
      When the user restores the version 1 back on "Roadmap"
      Then the blocks of "Roadmap" read "Final"
      And the page "Roadmap" still has the comment "Why?"
      When the user restores the version 1 back on "Roadmap"
      Then the block "Later" has the open comment "Why?"

    Scenario: Deleting a page for good is the user's edit of a page that linked to it
      Given the page "Ideas"
      And the agent in "Work" links "Ideas" from "Roadmap"
      And the page "Ideas" is in the trash
      And the user deletes the page "Ideas" for good
      When the user opens the history of "Roadmap"
      Then the history has 4 versions
      And the newest version was written by the user
      And the version 1 back was written by the thread "Work"

    Scenario: The history outlives a restart
      Given the MC restarts
      When the user opens the history of "Roadmap"
      Then the history has 2 versions

    Scenario: A page deleted for good has no history to read
      Given the page "Roadmap" is in the trash
      And the user keeps the id of "Roadmap"
      And the user deletes the page "Roadmap" for good
      When the user opens the history of the kept page
      Then the page request is refused
