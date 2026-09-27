# Sources:
#   docs/user/source-control.md (providers, CLI and auth setup, clone via Add Project, Publish Repository)
#   packages/contracts/src/sourceControl.ts (SourceControlDiscoveryResult, SourceControlRepositoryLookupInput, SourceControlCloneRepositoryInput, SourceControlPublishRepositoryInput)
#   packages/contracts/src/rpc.ts (server.discoverSourceControl, sourceControl.lookupRepository, sourceControl.cloneRepository, sourceControl.publishRepository, projectClone.start, projectClone.retry, projectClone.cancel, subscribeProjectClones)
#   apps/server-ex/lib/hal_c2/source_control.ex
#   apps/server-ex/lib/hal_c2/source_control/forgejo.ex (fj preferred over tea)
#   apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (discovery probe)
#   apps/server/src/sourceControl/ForgejoCli.ts (fj keys.json logins, subpath servers left to tea)
#   apps/server-ex/lib/hal_c2/project_clones.ex
#   apps/web/src/components/GitActionsControl.tsx (publish repository)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (Publish repository)
#   apps/tui/src/features.backlog.test.ts (repository-setup-publishing)

Feature: Finding hosting tools, cloning and publishing repositories
  The node finds which version control and hosting tools it can use and whether they are
  signed in. It clones repositories into new projects and publishes local ones to a host.

  Background:
    Given a connected environment

  @node
  Scenario Outline: The node reports each tool it finds
    Given <tool> is installed and signed in on the node's machine
    When the user asks which source control tools are available
    Then <name> is reported available with its version and signed-in account

    Examples:
      | tool  | name            |
      | git   | Git             |
      | jj    | Jujutsu         |
      | gh    | GitHub          |
      | glab  | GitLab          |
      | tea   | Forgejo / Gitea |
      | az    | Azure DevOps    |

  @node
  Scenario: A missing tool comes with how to install it
    Given the GitHub CLI is not installed
    When the user asks which source control tools are available
    Then GitHub is reported missing with how to install the GitHub CLI

  @node
  Scenario: A tool that is not signed in says how to sign in
    Given the GitHub CLI is installed but not signed in
    When the user asks which source control tools are available
    Then GitHub is reported not authenticated and the user is told to run gh auth login

  @node
  Scenario: Bitbucket is found through its environment variables
    Given the node was started with a Bitbucket access token in its environment
    When the user asks which source control tools are available
    Then Bitbucket is reported available and signed in

  @node
  Scenario Outline: The Forgejo CLI is preferred over tea
    Given both fj and tea are installed and fj holds a login for "<server>"
    When the user asks which source control tools are available
    Then Forgejo is reported through <cli>

    Examples:
      | server                  | cli |
      | codeberg.org            | fj  |
      | git.example.com/forgejo | tea |

  @node
  Scenario Outline: Looking up a repository on a host
    When the user looks up "<repository>" on <host>
    Then the repository's name, web address and clone addresses are returned

    Examples:
      | host   | repository |
      | GitHub | acme/shop  |
      | GitLab | acme/infra |

  @node
  Scenario Outline: Looking up, cloning and publishing on other hosts
    When the user looks up "acme/shop" on <host>
    Then the repository's name, web address and clone addresses are returned

    Examples:
      | host         |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @node
  Scenario Outline: Cloning over the protocol the user chose
    When the user clones "acme/shop" from GitHub over <protocol>
    Then the clone uses the repository's <protocol> address

    Examples:
      | protocol |
      | ssh      |
      | https    |

  @node
  Scenario: Cloning needs something to clone
    When the user clones without naming a repository or address
    Then the user is told "A repository or remote URL is required."

  @node
  Scenario: A cloned project is usable at once and shows its progress
    When the user adds a project by cloning "https://github.com/acme/shop"
    Then the project appears straight away
    And the clone's progress is streamed until the files are in place

  @node
  Scenario: Cancelling a clone
    Given a clone of "acme/shop" is in progress
    When the user cancels it
    Then the clone stops and is reported as cancelled

  @node
  Scenario: Retrying a failed clone
    Given the clone of "acme/shop" failed because the network dropped
    When the user retries it
    Then the clone starts again into the same project

  @node
  Scenario: A failed clone waits for the user while a finished one goes away
    Given one clone finished and another failed
    When some time passes
    Then the finished clone is no longer reported
    But the failed clone is still reported until it is retried

  @node
  Scenario Outline: Publishing a local repository
    Given the project "notes" is a git repository with commits and no remote
    When the user publishes "notes" to <host> as a <visibility> repository
    Then the repository is created on <host> as <visibility>
    And it is added as the remote and the current branch is pushed and tracked

    Examples:
      | host   | visibility |
      | GitHub | private    |
      | GitHub | public     |
      | GitLab | private    |

  @node
  Scenario: Publishing a repository with nothing to push only adds the remote
    Given the project "notes" is a git repository with no commits
    When the user publishes "notes" to GitHub
    Then the repository is created and added as the remote
    And the result says the remote was added without pushing

  @backlog @desktop @mobile
  Scenario: Publishing walks through provider, repository and summary
    Given the project "notes" has no remote
    When the user publishes the repository
    Then the user picks a host, names the repository, picks its visibility and confirms a summary

  @backlog @desktop @mobile
  Scenario: A host that is not ready is explained before publishing
    Given the GitHub CLI is not signed in
    When the user picks GitHub to publish to
    Then the user is told GitHub is not authenticated and how to fix it

  @desktop
  Scenario: Starting to publish from the git actions
    Given the project "notes" has commits and no remote
    When the user chooses to publish the repository
    Then publishing begins for "notes"
