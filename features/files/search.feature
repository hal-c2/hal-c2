# Sources:
#   apps/server-ex/lib/hal_c2/workspace.ex (search_entries, rank, search_contents)
#   apps/web/src/components/search/ProjectContentSearchDialog.tsx
#   apps/web/src/components/files/ProjectFilePicker.tsx
#   apps/web/src/components/CommandPalette.tsx (Go to file, Search project contents)
#   apps/tui/src/features.backlog.test.ts (file mentions)
#   packages/contracts/src/filesystem.ts (ProjectSearchEntriesInput, ProjectSearchContentsInput)
#   packages/contracts/src/rpc.ts (projects.searchEntries, projects.searchContents)
#   packages/contracts/src/keybindings.ts (filePicker.toggle, projectSearch.toggle)
#   apps/desktop-qt/src/native/CommandPaletteController.cpp (files and content modes)

Feature: Searching project files
  The user finds files by name and finds text across a project's files.

  Background:
    Given a connected environment with the project "shop"
    And "shop" holds "src/cart.ts", "src/lib/cart-total.ts", "docs/shopping-cart.md" and "assets/logo.png"

  Rule: Finding files by name

    @mc
    Scenario: Name matches rank above path matches and shorter paths win ties
      When a client searches "shop" for files named "cart"
      Then "src/cart.ts" is ranked first
      And "src/lib/cart-total.ts" is ranked before "docs/shopping-cart.md"

    @mc
    Scenario: Letters typed in order find a file even when they are not adjacent
      When a client searches "shop" for files named "sct"
      Then "src/cart.ts" is returned

    @mc
    Scenario Outline: A leading mention or relative prefix is ignored
      When a client searches "shop" for files named "<query>"
      Then "src/cart.ts" is returned

      Examples:
        | query      |
        | @cart      |
        | ./src/cart |

    @mc
    Scenario Outline: A search can be narrowed to one kind of entry
      When a client searches "shop" for <kind> named "<query>"
      Then only <returned> is returned

      Examples:
        | kind        | query | returned           |
        | folders     | src   | "src"              |
        | image files | logo  | "assets/logo.png"  |

    @mc
    Scenario: A search returns a limited number of matches and says there are more
      Given "shop" holds 300 files named like "cart"
      When a client searches "shop" for files named "cart" with a limit of 50
      Then 50 entries are returned
      And the result is marked as truncated

    # Neither server records which files were opened; both rank an empty search by
    # how recently files changed (the TS index's modification frecency).
    @mc
    Scenario: An empty file search lists the files that changed most recently first
      Given "docs/shopping-cart.md" changed most recently
      When a client searches "shop" for files with an empty query
      Then "docs/shopping-cart.md" is listed first

    @desktop @mobile @backlog-mobile
    Scenario: The file picker opens the chosen file
      When the user goes to a file and types "cart"
      And the user picks "src/cart.ts"
      Then "src/cart.ts" opens in the viewer

    @desktop @mobile @backlog-mobile
    Scenario: The file picker says when nothing matches
      When the user goes to a file and types "zzz"
      Then the user is told no files match

  Rule: Finding text across files

    Background:
      Given "src/cart.ts" contains the line "const Total = cartTotal(items)"

    @mc
    Scenario: Content search is case-insensitive by default
      When a client searches the contents of "shop" for "total"
      Then the line "const Total = cartTotal(items)" in "src/cart.ts" is returned
      And each match carries its line number and the character range of the match

    @mc
    Scenario Outline: Content search options narrow the matches
      When a client searches the contents of "shop" for "<query>" with <option>
      Then "src/cart.ts" <result>

      Examples:
        | query | option                  | result             |
        | total | matching case           | is not returned    |
        | Total | matching case           | is returned        |
        | cart  | matching whole words    | is not returned    |
        | T.tal | a regular expression    | is returned        |

    @mc
    Scenario: An invalid regular expression falls back to a plain text search and says why
      When a client searches the contents of "shop" for "cart(" as a regular expression
      Then matches for the text "cart(" are returned
      And the result explains why the regular expression was not used

    @mc
    Scenario: Content search works without ripgrep installed
      Given ripgrep is not installed on the environment
      When a client searches the contents of "shop" for "total"
      Then "src/cart.ts" is returned

    @mc
    Scenario: Content search skips files larger than one megabyte
      Given "logs/huge.log" in "shop" is 5 MB and contains "total"
      When a client searches the contents of "shop" for "total"
      Then "logs/huge.log" is not returned

    @desktop
    Scenario: Content search groups matches by file and opens a match at its line
      When the user searches the project contents for "total"
      Then the matches are grouped under "src/cart.ts"
      When the user opens the match
      Then "src/cart.ts" opens at the matching line

    @desktop
    Scenario: The result count summarises matches and files
      When the user searches the project contents for "cart"
      Then the user sees how many results were found in how many files

    @desktop
    Scenario Outline: Content search explains empty and invalid states
      Given <situation>
      When the user searches the project contents
      Then the user is told "<message>"

      Examples:
        | situation                                  | message                                 |
        | the query is empty                         | Type to search across your project.     |
        | nothing matches "zzz"                      | No results found.                       |
        | the query is the regular expression "cart(" | Invalid regular expression              |
        | no project is open                         | Open a project to search its files.     |

    @desktop
    Scenario: The search is cleared when the user switches project
      Given the user searched the project contents of "shop" for "total"
      When the user switches to the project "docs"
      Then the content search is empty

    @tui
    Scenario: The terminal client searches project contents
      When the user searches the project contents for "total"
      Then "src/cart.ts" is listed with its matching line
