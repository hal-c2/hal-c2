# Sources:
#   apps/server-ex/lib/hal_c2/editors.ex (shell.openInEditor starts the editor on the MC's own machine)
#   apps/server-ex/lib/hal_c2/workspace.ex (what a project lets a client read and write)
#   apps/server-ex/lib/hal_c2/cluster/distribution.ex (the cluster link the share rides on)
#   apps/server-ex/lib/hal_c2/machine_files.ex (the folders, files.localPath), machine_files/share.ex (what a member answers), machine_files/helper.ex (the mount)
#   native/machine-files (the FUSE helper, a 9P2000.L client of the MC)
#   apps/desktop-qt/src/native/WorkspaceController.cpp, FileActionsController.cpp, TerminalController.cpp
#   apps/web/src/remoteOpen.ts (upstream opened a remote environment's files over SSH instead)
#   Cross-domain: connections/ owns clustering; file-viewer-and-editing.feature owns opening on this machine.

# The MC serves its projects' files to the cluster over 9P, as WSL does to Windows, and the
# MC on the user's machine shows each member's share as a folder of its own through FUSE.
# The user's own editor and file manager open a file of another machine from that folder.
# Linux only for now: on macOS (FUSE-T or macFUSE) and Windows (WinFsp) files.localPath
# answers that opening another machine's files is not supported yet.
Feature: Files on another machine
  A thread's files live on the machine its MC runs on. The user's own editor, file manager
  and terminal links open them all the same, from a folder this machine keeps for each
  other machine of the cluster.

  Background:
    Given the client is connected to the MC on its own machine
    And that MC is in a cluster with "devbox"
    And "devbox" has the project "shop" at "/home/me/shop"

  @mc
  Scenario: A file on another machine has a path on this one
    When the client asks its MC where "/home/me/shop/src/cart.ts" on "devbox" is on this machine
    Then the answer is a path inside the folder this machine keeps for "devbox"
    And reading that path gives the contents of "src/cart.ts" on "devbox"

  @mc
  Scenario: Saving through the folder writes the file on the other machine
    When the user saves "src/cart.ts" of "shop" through the folder kept for "devbox"
    Then "src/cart.ts" on "devbox" has the saved contents

  @mc
  Scenario: A change made on the other machine is read the next time
    Given the user's editor read "src/cart.ts" of "shop" through the folder kept for "devbox"
    When the agent on "devbox" changes "src/cart.ts"
    Then reading "src/cart.ts" through the folder again gives the agent's change

  @mc
  Scenario Outline: Only the other machine's projects are shared
    When the user reads "<path>" through the folder kept for "devbox"
    Then it is not found

    Examples:
      | path                       |
      | /home/me/.ssh/id_ed25519   |
      | /etc/passwd                |
      | /home/me/shop/../notes.txt |

  @mc
  Scenario: A thread's worktree is shared with its project
    Given a thread of "shop" works in the worktree "/home/me/.worktrees/shop-cart"
    When the user reads "/home/me/.worktrees/shop-cart/src/cart.ts" through the folder kept for "devbox"
    Then it gives the contents of "src/cart.ts" in that worktree

  @mc
  Scenario: Only the user the MC runs as can open the folder
    When another user of this machine reads the folder kept for "devbox"
    Then it is refused

  @mc
  Scenario: Reading from a machine that stops answering fails instead of hanging
    Given "devbox" has stopped answering
    When the user reads "/home/me/shop/src/cart.ts" through the folder kept for "devbox"
    Then the read fails saying "devbox" is unavailable

  @mc
  Scenario: The folder of a machine that leaves the cluster goes away
    When "devbox" is removed from the cluster
    Then this machine no longer keeps a folder for "devbox"

  @backlog @desktop @tui
  Scenario Outline: A file of a thread on another machine opens in this machine's apps
    Given a thread of "shop" runs on "devbox"
    When the user <action> "src/cart.ts"
    Then <app> on this machine opens it from the folder kept for "devbox"
    And nothing is started on "devbox"

    Examples:
      | action                       | app              |
      | opens in "VS Code"           | "VS Code"        |
      | reveals                      | the file manager |
      | follows a terminal's path to | the editor       |

  @backlog @desktop @tui
  Scenario: A machine that cannot show the folder says what it needs
    Given this machine has no way to show another machine's folder
    And a thread of "shop" runs on "devbox"
    When the user opens "src/cart.ts" in "VS Code"
    Then the user is told the file is on "devbox" and what to install to open it here
    And nothing is started on "devbox"
