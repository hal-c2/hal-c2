# Sources:
#   https://github.com/pingdotgg/t3code/pull/17749
#   https://github.com/pingdotgg/t3code/pull/17662
#   https://github.com/pingdotgg/t3code/pull/11922
#   https://github.com/pingdotgg/t3code/pull/19078
#   https://github.com/pingdotgg/t3code/pull/16246
#   https://github.com/pingdotgg/t3code/pull/7079
#   https://github.com/pingdotgg/t3code/pull/13669
#   apps/server-ex/lib/hal_c2/editors.ex (availableEditors, shell.openInEditor)
#   apps/server-ex/lib/hal_c2/codex/provider.ex (the version read a server config waits on)
#   apps/server-ex/lib/hal_c2/local_servers.ex (subscribeDiscoveredLocalServers)
#   apps/server-ex/lib/hal_c2/projects.ex (filesystem.browse)
#   apps/server-ex/lib/hal_c2/paths.ex (symlink resolution)
#   apps/server-ex/lib/hal_c2/subprocess.ex (line framing, pipe backpressure)
#   apps/server-ex/lib/hal_c2/git.ex (use_gh_for_github: GitHub over the GitHub CLI's sign-in)
#   packages/contracts/src/editor.ts (EDITORS, launch styles, ExternalLauncher errors)
#   apps/server/src/processRunner.ts (timeout, output limit, truncation, exit status, spawn errors)
#   apps/server/src/process/externalLauncher.ts (Windows and WSL reveal, Linux folder-handler probe,
#     editor discovery cache, default browser launch)
#   packages/contracts/src/shell.ts
#   packages/contracts/src/rpc.ts (shell.openInEditor, filesystem.browse, subscribeDiscoveredLocalServers)
#   docs/internals/composer-editors.md
#   Shared domain: files/ owns opening files from the explorer; preview/ owns server suggestions.

Feature: The MC working with its host machine
  An MC opens editors on its own machine, lists folders for adding projects, finds
  web servers running on the host for previews, and reaches GitHub as its user does.

  Background:
    Given a running MC

  @mc
  Scenario: The server config lists editors installed on the host
    Given Cursor and Zed are installed on the host
    When a client reads the MC's server config
    Then the available editors include Cursor and Zed
    And the file manager is listed last

  # Upstream #7079: the agy command is Google's Antigravity CLI, not the Antigravity IDE.
  @backlog @mc @plugin-antigravity @priority-low
  Scenario: The agy command is not taken for the Antigravity IDE
    Given the Antigravity CLI "agy" is installed on the host and the Antigravity IDE is not
    When a client reads the MC's server config
    Then the available editors do not include Antigravity

  @backlog @mc @plugin-antigravity @priority-low
  Scenario: The Antigravity IDE opens a location at its line
    Given the Antigravity IDE is installed on the host
    When a client opens "src/app.ts" at line 12 column 4 in Antigravity IDE
    Then the MC launches the Antigravity IDE at that line

  # Upstream #13669: a long PATH does not empty the editor list.
  @backlog @mc
  Scenario: Editors installed on a long PATH are still listed
    Given the host's PATH has more than seventy folders and Cursor is installed in the last one
    When a client reads the MC's server config
    Then the available editors include Cursor

  @backlog @mc @priority-low
  Scenario: On a Mac Zed is found by its app before a "zed" on the PATH
    Given a Mac host with the Zed app installed and another program named "zed" earlier on its PATH
    When a client opens "src/app.ts" in Zed
    Then the Zed app opens it

  @mc
  Scenario Outline: Opening a location in an editor uses that editor's style
    When a client opens "src/app.ts" at line 12 column 4 in <editor>
    Then the MC launches <editor> the way it takes a line and column
    And it does not wait for the editor to exit

    Examples:
      | editor   |
      | VS Code  |
      | Cursor   |
      | Zed      |
      | IntelliJ |

  @mc
  Scenario: The user's default text editor is offered first
    Given the host's default text editor is Neovim
    When a client reads the MC's server config
    Then the default editor is listed first

  @mc
  Scenario: Opening a location in the default editor opens the file
    Given the host's default text editor is Neovim
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then the MC launches Neovim's desktop entry on "src/app.ts"

  @mc
  Scenario: On a Mac the default editor is the one macOS opens text in
    Given the MC runs on macOS
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then macOS opens "src/app.ts" in its default text editor

  @mc
  Scenario: On Windows the default editor is the one Windows opens text files in
    Given the MC runs on Windows and opens text files in Notepad
    When a client reads the MC's server config
    Then the default editor is listed first
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad

  @mc
  Scenario: On Windows a program the user picked in the Open With dialog is the default editor
    Given the MC runs on Windows and the user's chosen program is the application notepad.exe
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad

  @mc
  Scenario: On Windows the MC holds nothing open for the editor it started
    Given the MC runs on Windows and opens text files in Notepad
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad and the MC holds no port for it

  # Upstream #17749: a command shim re-reads its arguments through cmd.exe, which mangles
  # a line break or a double quote. Neither can be in a Windows file name.
  @backlog @mc @priority-low
  Scenario Outline: On Windows an editor started through a command shim is not given a path it would mangle
    Given the MC runs on Windows and the chosen editor is the command shim "code.cmd"
    When a client opens <path> in that editor
    Then <outcome>

    Examples:
      | path                                       | outcome                                            |
      | a path holding a line break                | the editor is not started and the client is told it could not be opened |
      | a path holding a double quote              | the editor is not started and the client is told it could not be opened |
      | "C:\work\naïve & (draft) 100%.ts" at 12:4  | the editor opens that file at line 12 column 4     |

  @mc
  Scenario: On Windows a text association without a chosen program still names the editor
    Given the MC runs on Windows and the class registered for .txt opens text files in Notepad
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad

  @mc
  Scenario: On Windows a chosen program without a command line falls back to the class registered for .txt
    Given the MC runs on Windows and the chosen program names no command line but the class registered for .txt opens text files in Notepad
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad

  @mc
  Scenario: On Windows the file goes where the registered command line puts it
    Given the MC runs on Windows and Notepad is registered with the command line '"NOTEPAD" --visit "%1" --funcall whitespace-mode --file=%1 --user-data-dir="C:\Editor Data" --name=a\"b "C:\Dir\\"'
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad with the file where the command line puts it

  @mc
  Scenario: On Windows the other shell parameters of the registered command line get what the shell gives
    Given the MC runs on Windows and Notepad is registered with the command line '"NOTEPAD" "%1" %S %2 --dir=%W %H %I'
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad with the other parameters filled in

  @mc
  Scenario: On Windows the file is appended when the registered command line names no file placeholder
    Given the MC runs on Windows and Notepad is registered with the command line '"NOTEPAD" %S'
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad with the file appended after the other parameters

  @mc
  Scenario: On Windows a quoted bare placeholder is dropped like the shell's unquoted one
    Given the MC runs on Windows and Notepad is registered with the command line '"NOTEPAD" "%1" "%2"'
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad with the quoted empty parameter dropped

  @mc
  Scenario: On Windows a doubled quote inside quoted text is one quote
    Given the MC runs on Windows and Notepad is registered with the command line '"NOTEPAD" "%1" "say ""hi"" there"'
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad with the doubled quotes read as quotes

  @mc
  Scenario: On Windows a path with backslashes reaches the editor as it is
    Given the MC runs on Windows and opens text files in Notepad
    When a client opens the path "C:\Projects\2024\app.ts" in the default editor
    Then Windows opens "C:\Projects\2024\app.ts" in Notepad

  @mc
  Scenario: On Windows the registered command line may name its program with a variable and take the file as %L
    Given the MC runs on Windows and Notepad is registered through the variable in '"%HAL_C2_TEST_EDITORS%/notepad.exe" %L'
    When a client opens "src/app.ts" at line 12 column 4 in the default editor
    Then Windows opens "src/app.ts" in Notepad

  @mc
  Scenario: On Windows a REG_SZ command line keeps its variables unexpanded
    Given the MC runs on Windows and Notepad is registered with the REG_SZ command line '"%HAL_C2_TEST_EDITORS%/notepad.exe" %1'
    When a client reads the MC's server config
    Then the default editor is not offered

  @mc
  Scenario Outline: On Windows an unquoted program path with spaces offers no default editor
    Given the MC runs on Windows and Notepad is registered with the unquoted command line '<line>'
    When a client reads the MC's server config
    Then the default editor is not offered

    Examples:
      | line                                  |
      | C:\Program Files\Editor\editor.exe %1   |
      | C:Program Files\Editor\editor.exe %1    |
      | \Program Files\Editor\editor.exe %1     |
      | /Program Files/Editor/editor.exe %1     |

  @mc
  Scenario: A Windows host's text association is looked up once for the server configs read within a minute
    Given the MC runs on Windows and keeps the registry's answer for a minute
    When a client reads the MC's server config
    And a client reads the MC's server config a second time
    Then the registry was not queried again
    And the default editor is listed first

  @mc
  Scenario: A hung registry lookup does not hold up the server config on Windows
    Given the MC runs on Windows and reg never answers
    When a client reads the MC's server config
    Then the default editor is not offered

  @mc
  Scenario Outline: A registered program path the MC cannot read does not offer a default editor on Windows
    Given the MC runs on Windows and reg prints the program path "<path>"
    When a client reads the MC's server config
    Then the default editor is not offered

    Examples:
      | path       |
      | \377\376   |
      | a\000b    |

  @mc
  Scenario: On Windows a Store app's text association does not offer a default editor
    Given the MC runs on Windows and the text association names no command line
    When a client reads the MC's server config
    Then the default editor is not offered

  @mc
  Scenario: A Windows host without a text association does not offer a default editor
    Given the MC runs on Windows with no program for text files
    When a client reads the MC's server config
    Then the default editor is not offered

  @mc
  Scenario: A default editor installed in a vendor folder is found by its id
    Given the host's default text editor is "acme-editor.desktop", installed as "acme/editor.desktop"
    When a client reads the MC's server config
    Then the default editor is listed first

  @mc
  Scenario: An empty DISPLAY is no display
    Given the host's default text editor is Neovim
    And DISPLAY is set but empty and there is no Wayland display
    When a client reads the available editors
    Then the default editor is not offered
    And the file manager is not offered

  @mc
  Scenario: A hung default editor lookup does not hold up the server config
    Given the host's xdg-mime never answers
    When a client reads the MC's server config
    Then the default editor is not offered

  @mc
  Scenario: A hung Codex CLI does not hold up the server config
    Given the host's codex never answers
    When a client reads the MC's server config
    Then Codex is listed with an unknown version
    When the host's codex answers with version "1.2.3"
    And a client reads the MC's server config again
    Then Codex is listed with version "1.2.3"

  @mc
  Scenario: A Codex CLI that stays hung is asked again only after a minute
    Given the host's codex never answers, and a minute has not passed since it was asked
    When a client reads the MC's server config
    And a client reads the MC's server config again
    Then Codex is listed with an unknown version
    And codex was asked for its version once

  @mc
  Scenario: A host without a default text editor does not offer one
    Given a Linux host with no display
    When a client reads the available editors
    Then the default editor is not offered

  @mc
  Scenario: Revealing a folder in the file manager
    When a client opens a project folder in the file manager
    Then the host's file manager shows that folder

  @mc
  Scenario: On Linux revealing a file shows the folder that holds it
    Given a Linux host with a display and xdg-open installed
    When a client reveals a file in the file manager
    Then the host's file manager shows the folder that holds the file

  # The file manager only ever shows folders. A workspace path is something an agent or a
  # cloned repository controls, and handing a file to the host's opener runs whatever its
  # type maps to: a shortcut, a script, an app.
  @mc
  Scenario Outline: On Linux opening a file in the file manager shows the folder that holds it
    Given a Linux host with a display and xdg-open installed
    When a client opens "<file>" in the file manager
    Then the host's file manager shows the folder that holds the file

    Examples:
      | file           |
      | README.md      |
      | tool.desktop   |

  # A trailing slash on a file's path must not make the opener treat the file as a folder.
  @mc
  Scenario: On Linux a file addressed with a trailing slash still shows the folder that holds it
    Given a Linux host with a display and xdg-open installed
    When a client opens the file "tool.desktop" addressed with a trailing slash in the file manager
    Then the host's file manager shows the folder that holds the file

  @mc
  Scenario Outline: On a Mac opening a file in the file manager reveals it instead of opening it
    Given the MC runs on macOS
    When a client opens "<item>" in the file manager
    Then Finder shows the file selected in its folder

    Examples:
      | item           |
      | README.md      |
      | setup.command  |
      | Tool.app/      |

  @mc
  Scenario: On a Mac opening a plain folder in the file manager opens it in Finder
    Given the MC runs on macOS
    When a client opens a project folder in the file manager
    Then Finder opens that folder

  @mc
  Scenario Outline: On Windows opening a file in the file manager selects it in Explorer
    Given the MC runs on Windows
    When a client opens "<item>" in the file manager
    Then Explorer shows the file selected in its folder

    Examples:
      | item              |
      | README.md         |
      | notes.lnk         |
      | Tools.{0000}/     |

  @mc
  Scenario: On Windows opening a plain folder in the file manager opens it in Explorer
    Given the MC runs on Windows
    When a client opens a project folder in the file manager
    Then Explorer opens that folder

  @mc
  Scenario: A program the MC starts for a client does not stay attached to the MC
    Given a Linux host with a display and xdg-open installed
    When a client opens a file in the file manager
    Then the program runs in a session of its own with no input or output shared with the MC
    And the MC holds no process or port for it

  @mc
  Scenario: A host without setsid still starts the program in a session of its own
    Given a Linux host with a display and xdg-open installed
    And the host has no setsid program
    When a client opens a file in the file manager
    Then the program runs in a session of its own with no input or output shared with the MC
    And the MC holds no process or port for it

  @mc
  Scenario: Opening the file manager on a host without one fails
    Given a Linux host with no display
    When a client opens a folder in the file manager
    Then the MC fails saying the file manager is unsupported

  @mc
  Scenario: On a Mac the file manager reveals the item
    Given the MC runs on macOS
    When a client reveals a file in the file manager
    Then Finder shows the file selected in its folder

  @mc
  Scenario: An unknown editor is refused
    When a client opens a folder in an editor id the MC does not know
    Then the MC fails saying the editor is unknown

  @mc
  Scenario: An editor that is not installed is refused
    Given Zed is not installed on the host
    When a client opens a folder in Zed
    Then the MC fails naming the command it could not find

  @mc
  Scenario: A headless Linux host offers no file manager
    Given a Linux host with no display
    When a client reads the available editors
    Then the file manager is not offered

  @backlog @mc
  Scenario Outline: A Linux host offers the file manager only when something can open folders
    Given a Linux host with a display and xdg-open installed
    And <handler state>
    When a client reads the available editors
    Then the file manager is not offered

    Examples:
      | handler state                                       |
      | no application is registered to open folders        |
      | xdg-mime is not installed                           |
      | the query for the folder handler fails              |

  @backlog @mc @priority-low
  Scenario: A folder handler lookup that stalls drops only the file manager
    Given a Linux host with a display whose folder handler lookup never answers
    When a client reads the MC's server config
    Then the server config arrives with the editors that were found
    And the file manager is not offered

  @mc
  Scenario: On Windows the file manager selects the file in Explorer
    Given the MC runs on Windows
    When a client reveals a file in the file manager
    Then Explorer shows the file selected in its folder

  # The MC selects a file with `explorer /select,`, which needs no PowerShell.
  @dropped @mc
  Scenario: On Windows without PowerShell revealing a file is not offered
    Given the MC runs on Windows without PowerShell
    When a client reads the available editors
    Then the file manager is still offered for folders
    But revealing a file in it is not offered

  @backlog @mc @priority-low
  Scenario: On WSL a file is revealed in Windows Explorer through its Windows path
    Given the MC runs inside WSL with Explorer and PowerShell reachable from it
    When a client reveals a file in the file manager
    Then Windows Explorer shows that file selected under the distro's network path

  @backlog @mc @priority-low
  Scenario Outline: On WSL a reveal that Windows cannot do falls back to the Linux file manager
    Given the MC runs inside WSL and <situation>
    When a client reveals a file in the file manager
    Then the Linux file manager opens the folder that holds the file

    Examples:
      | situation                                                    |
      | PowerShell is not reachable from the distro                  |
      | the Explorer bridge is not installed                         |
      | Explorer cannot select the path the file lives under         |

  @backlog @mc
  Scenario: Editors found outside the PATH are launched from where they are installed
    Given Cursor is installed in an application folder that is not on the PATH
    When a client opens a folder in Cursor
    Then the MC launches Cursor from its installed location

  @backlog @mc
  Scenario: An application folder that holds no launcher does not hide an editor on the PATH
    Given an editor application folder exists but contains no usable launcher
    And the editor's command is on the PATH
    When a client reads the available editors
    Then the editor is offered launched through the PATH command

  @backlog @mc @priority-low
  Scenario: Installing an editor shows up in the server config within a minute
    Given a client read the server config a moment ago
    When an editor is installed on the host
    Then the next read within a minute may still omit it
    But a read after a minute offers the new editor

  @backlog @mc @priority-low
  Scenario: A client that disconnects during an editor scan does not break the next one
    Given a client disconnects while the MC is scanning for editors
    When another client reads the server config
    Then the MC scans again and the server config lists the available editors

  @backlog @mc
  Scenario: The host's default browser opens a link for the MC
    Given the MC needs the user to sign in through a browser
    When the MC opens the link on its host
    Then the host's default browser opens that link
    And the MC does not wait for the browser to close

  @backlog @mc @priority-low
  Scenario: A host with no way to open a browser says which command it could not run
    Given the host has no command that opens a browser
    When the MC opens a link on its host
    Then the MC fails naming the link and the command it tried

  @mc
  Scenario: Browsing folders to add a project
    Given the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt
    When a client browses "~/dev/t"
    Then the MC lists folders in "~/dev" whose names start with "t"
    And hidden folders are left out

  @mc
  Scenario: Browsing a folder lists everything in it
    Given the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt
    When a client browses "~/dev/"
    Then the MC lists every folder in "~/dev", hidden ones included

  @mc
  Scenario: Browsing a folder that does not exist
    When a client browses a path whose parent does not exist
    Then the MC fails without listing anything

  @mc
  Scenario: The MC finds web servers running on the host
    Given a development server is serving HTML on port 5173
    When a client follows the host's local servers
    Then port 5173 is listed

  @mc
  Scenario: Ports that do not serve HTML are not listed
    Given a database is listening on port 5432
    When a client follows the host's local servers
    Then port 5432 is not listed

  @mc
  Scenario: A server that stops is removed from the list
    Given a client follows the host's local servers with port 5173 listed
    When that server stops
    Then port 5173 is removed from the list

  @mc
  Scenario: The MC only scans for servers while someone watches
    Given nobody follows the host's local servers
    Then the MC does not scan the host's ports

  @mc
  Scenario: A symlink loop is reported rather than followed forever
    Given a project path that loops through symlinks
    When the MC resolves it
    Then it fails as a symlink loop

  @mc
  Scenario: A chatty subprocess is slowed down rather than buffered without end
    Given a provider process writing output faster than the MC reads it
    Then the MC applies backpressure through the process's pipe
    And its memory stays bounded

  @backlog @mc
  Scenario: A command the MC runs for a client that never finishes is stopped
    Given a client asks the MC to run a command that never exits
    When the command has run for a minute
    Then the MC stops it
    And the client is told the command timed out after the time it was given

  @backlog @mc
  Scenario: A command that writes more than the MC will hold is stopped
    Given a client asks the MC to run a command that prints more than 8 MiB
    When the output passes the limit
    Then the MC stops the command without waiting for it to finish
    And the client is told which stream went over the limit and what the limit is

  @backlog @mc
  Scenario: A command whose output may be long is cut at the limit instead of failing
    Given the MC runs a command for a view that can show a partial result
    When the command prints more than the view's limit
    Then the view receives the output up to the limit followed by a marker that it was cut
    And the command is reported as having succeeded or failed by its own exit code

  @backlog @mc
  Scenario: A command that exits with an error is a result and not a failure of the MC
    Given a client asks the MC to run a command that exits with status 1 and prints a message
    When the command finishes
    Then the client receives the exit status, the output and the error output

  @backlog @mc
  Scenario: A command that cannot start says which command and where
    Given a client asks the MC to run a command that is not installed
    Then the client is told the command could not be started and in which folder it was tried

  @backlog @mc @priority-low
  Scenario: Output that is not valid text is passed on and marked
    Given a command prints bytes that are not valid UTF-8
    When the command finishes
    Then the output is returned with the bad bytes replaced
    And the result says the output was not valid UTF-8

  @mc
  Scenario: Git the MC starts reaches GitHub with the GitHub CLI's sign-in
    Given the GitHub CLI on the host is signed in to github.com
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over HTTPS
    And the GitHub CLI answers git's request for a GitHub credential

  @mc
  Scenario: Without the GitHub CLI's sign-in git reaches GitHub as configured
    Given the GitHub CLI on the host is not signed in
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over SSH

  @mc
  Scenario Outline: Git stays on SSH where GitHub answers it, and goes to the GitHub CLI's sign-in where it refuses it
    Given the GitHub CLI on the host is signed in to github.com
    And an SSH agent runs on the host and SSH to GitHub <ssh>
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over <transport>
    And the GitHub CLI answers git's request for a GitHub credential

    Examples:
      | ssh         | transport |
      | is answered | SSH       |
      | is refused  | HTTPS     |

  # Asking SSH is a network round trip, at boot and after every release upgrade.
  @mc
  Scenario: The MC does not wait for SSH to answer for GitHub
    Given the GitHub CLI on the host is signed in to github.com
    And an SSH agent runs on the host and SSH to GitHub hangs
    When the MC begins setting up the git it starts
    Then the MC is still asking whether SSH answers for GitHub
    And git fetches "git@github.com:acme/shop.git" over HTTPS

  @mc
  Scenario: An SSH that runs past its time is stopped and leaves git on its route
    Given the GitHub CLI on the host is signed in to github.com
    And an SSH agent runs on the host and SSH to GitHub hangs
    And SSH is given 1000 ms to answer
    When the MC sets up the git it starts
    Then the ssh the MC started has stopped
    And git fetches "git@github.com:acme/shop.git" over HTTPS

  # A network that is down for one boot does not move git off a route that works.
  @mc
  Scenario Outline: An SSH that cannot reach GitHub keeps the route git had
    Given the GitHub CLI on the host is signed in to github.com
    And an SSH agent runs on the host and SSH to GitHub <before>
    And the MC sets up the git it starts
    And an SSH agent runs on the host and SSH to GitHub cannot reach it
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over <transport>

    Examples:
      | before      | transport |
      | is answered | SSH       |
      | is refused  | HTTPS     |

  # Git as configured while signed out was never an answer from SSH.
  @mc
  Scenario: A sign-in made while SSH cannot reach GitHub goes over HTTPS
    Given the GitHub CLI on the host is not signed in
    And the MC sets up the git it starts
    And the GitHub CLI signs in to github.com
    And an SSH agent runs on the host and SSH to GitHub cannot reach it
    When the MC sets up the git it starts
    Then git fetches "git@github.com:acme/shop.git" over HTTPS

  # Git matches its rules' prefixes by case, so each first character of an owner counts.
  @mc
  Scenario Outline: A user's own rule sending HTTPS to SSH does not send git back to SSH
    Given the GitHub CLI on the host is signed in to github.com
    And the user's own git config sends "https://github.com/" to SSH
    When the MC sets up the git it starts
    Then git fetches "https://github.com/<owner>/shop.git" over HTTPS
    And git pushes to "https://github.com/<owner>/shop.git" over HTTPS

    Examples:
      | owner  |
      | acme   |
      | Acme   |
      | 9lives |

  # Git takes the longest matching prefix, and a pushInsteadOf over any insteadOf for a push.
  @mc
  Scenario Outline: A user's own rule for one owner still applies where git would take it
    Given the GitHub CLI on the host is signed in to github.com
    And the user's own git config has <rule> rule sending "https://github.com/acme/" to "git@github.com:acme/"
    When the MC sets up the git it starts
    Then git fetches "https://github.com/acme/shop.git" from "<fetch>"
    And git pushes "https://github.com/acme/shop.git" to "<push>"

    Examples:
      | rule            | fetch                            | push                             |
      | an insteadOf    | git@github.com:acme/shop.git     | https://github.com/acme/shop.git |
      | a pushInsteadOf | https://github.com/acme/shop.git | git@github.com:acme/shop.git     |

  @mc
  Scenario Outline: A sign-in or sign-out reaches git already running at the next upgrade in place
    Given the GitHub CLI on the host is <before>
    And the MC sets up the git it starts
    And an agent's git is already running
    When the GitHub CLI <change> and the MC upgrades in place
    Then the agent's git fetches "git@github.com:acme/shop.git" over <transport>

    Examples:
      | before                  | change                  | transport |
      | not signed in           | signs in to github.com  | HTTPS     |
      | signed in to github.com | signs out               | SSH       |

  @backlog @mc @priority-low
  Scenario: A JetBrains editor whose application bundle carries a version is found
    Given the editor "IntelliJ IDEA 2026.1.4.app" is installed in Applications on macOS
    When the MC looks for installed editors
    Then IntelliJ IDEA is available
    And "Visual Studio Code - Insiders.app" is not taken for "Visual Studio Code"

  # Upstream #17662: systemd-oomd kills a whole cgroup, so one greedy agent took the server and
  # every other agent with it. Each agent and terminal now gets its own scope in an agents slice
  # held below the machine's memory, and the kernel picks agents before the MC.
  @backlog @mc
  Scenario: An agent that runs out of memory on Linux is killed without the MC
    Given the MC runs on Linux under a systemd user manager
    And two threads each run an agent
    When one agent uses more memory than the machine can give
    Then that agent is killed and its turn fails with "Killed: out of memory."
    And the MC and the other agent keep running

  @backlog @mc @priority-low
  Scenario: Where there is no systemd user manager agents start as before
    Given the MC runs on macOS or in a container without a systemd user manager
    When a thread starts an agent
    Then the agent starts directly, with no scope around it

  @backlog @mc
  Scenario: An out-of-memory kill marks only the session it ended
    Given a thread's agent was killed for using too much memory
    When the thread starts a new agent session and that turn fails for another reason
    Then the failure does not say "Killed: out of memory."

  # Upstream #11922: on macOS a terminal's ssh to a LAN host failed with "No route to host"
  # until the app declared why it uses the local network.
  @backlog @desktop @priority-low
  Scenario: On macOS terminals and agents reach hosts on the local network
    Given the packaged desktop app runs on macOS with its MC
    When the user runs "ssh build-box.local hostname" in a HAL-C2 terminal
    Then macOS asks once whether HAL-C2 may use the local network, saying it is for remote environments, terminals and agents
    And once allowed, the command reaches "build-box.local"
