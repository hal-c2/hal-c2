# Sources:
#   docs/user/source-control.md (providers, CLI and auth setup, clone via Add Project, Publish Repository)
#   packages/contracts/src/sourceControl.ts (SourceControlDiscoveryResult, SourceControlRepositoryLookupInput, SourceControlCloneRepositoryInput, SourceControlPublishRepositoryInput)
#   packages/contracts/src/rpc.ts (server.discoverSourceControl, sourceControl.lookupRepository, sourceControl.cloneRepository, sourceControl.publishRepository, projectClone.start, projectClone.retry, projectClone.cancel, subscribeProjectClones)
#   apps/server-ex/lib/hal_c2/source_control.ex
#   apps/server-ex/lib/hal_c2/source_control/forgejo.ex (fj preferred over tea)
#   apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (discovery probe, createRepository)
#   apps/server/src/sourceControl/ForgejoCli.ts (fj keys.json logins, subpath servers left to tea)
#   apps/server/src/sourceControl/SourceControlProviderDiscovery.ts, SourceControlProviderRegistry.ts,
#     gitHubAuthStatus.ts, gitLabAuthStatus.ts, GitHubSourceControlProvider.ts,
#     GitLabSourceControlProvider.ts, AzureDevOpsSourceControlProvider.ts (remote choice, probes, accounts)
#   apps/server/src/sourceControl/BitbucketApi.ts, BitbucketSourceControlProvider.ts (trusted origin, paging)
#   apps/server/src/sourceControl/GitLabCli.ts (createRepository namespaces), AzureDevOpsCli.ts (createRepository projects)
#   packages/shared/src/sourceControl.ts (the host of a remote read from its address)
#   apps/server-ex/lib/hal_c2/project_clones.ex
#   apps/web/src/components/GitActionsControl.tsx (publish repository)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (Publish repository)
#   apps/tui/src/features.backlog.test.ts (repository-setup-publishing)

Feature: Finding hosting tools, cloning and publishing repositories
  The MC finds which version control and hosting tools it can use and whether they are
  signed in. It clones repositories into new projects and publishes local ones to a host.

  Background:
    Given a connected environment

  @mc
  Scenario Outline: The MC reports each tool it finds
    Given <tool> is installed and signed in on the MC's machine
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

  @mc
  Scenario: A missing tool comes with how to install it
    Given the GitHub CLI is not installed
    When the user asks which source control tools are available
    Then GitHub is reported missing with how to install the GitHub CLI

  @mc
  Scenario: A tool that is not signed in says how to sign in
    Given the GitHub CLI is installed but not signed in
    When the user asks which source control tools are available
    Then GitHub is reported not authenticated and the user is told to run gh auth login

  @mc
  Scenario: Bitbucket is found through its environment variables
    Given the MC was started with a Bitbucket access token in its environment
    When the user asks which source control tools are available
    Then Bitbucket is reported available and signed in

  @mc
  Scenario Outline: The Forgejo CLI is preferred over tea
    Given both fj and tea are installed and fj holds a login for "<server>"
    When the user asks which source control tools are available
    Then Forgejo is reported through <cli>

    Examples:
      | server                  | cli |
      | codeberg.org            | fj  |
      | git.example.com/forgejo | tea |

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (matchForgejoLogin, resolveTarget)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex (match_login)
  @mc @backlog
  Scenario Outline: A Forgejo login is chosen by the address of the checkout's remote
    Given the Forgejo CLIs hold <logins>
    When the MC reads a Forgejo repository whose remote is <remote>
    Then <outcome>

    Examples:
      | logins                                                           | remote                                      | outcome                                         |
      | one login for "git.example.com"                                  | an https address on "git.example.com"       | that login is used                              |
      | one login for "git.example.com" with the SSH alias "ssh.example" | an SSH address on "ssh.example"             | that login is used                              |
      | two logins for "git.example.com", one of them the default        | an https address on "git.example.com"       | the default login is used                       |
      | two logins for "git.example.com", neither the default            | an https address on "git.example.com"       | the user is told to choose a default login      |
      | logins for two servers                                           | an https address on a third server          | the user is told no matching login was found    |
      | a login for "git.example.com/forgejo"                            | an address on "git.example.com/other"       | the user is told no matching login was found    |

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (listLogins, publicLogins)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex (logins_from_keys)
  @mc @backlog
  Scenario: The Forgejo CLI is read for its servers and tokens from its own storage
    Given the Forgejo CLI is signed in to "codeberg.org" and stores its tokens in its data folder
    When the MC reads a repository on "codeberg.org"
    Then the stored token of "codeberg.org" is used for the request
    And the server is reached over https unless the checkout's remote is an explicit http address of that server

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (readKeys, listLogins: missing-cli)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex (keys, fj_logins)
  @mc @backlog
  Scenario Outline: Credentials of a Forgejo CLI that is unusable are reported or ignored
    Given <state>
    When the MC reads a Forgejo repository
    Then <outcome>

    Examples:
      | state                                                          | outcome                                                                 |
      | the Forgejo CLI's stored credentials cannot be read            | the user is told "Could not read fj authentication storage."            |
      | the Forgejo CLI's stored credentials are damaged               | the user is told "fj authentication storage is invalid. Authenticate again with fj." |
      | stored credentials remain from an uninstalled Forgejo CLI and the Gitea CLI has a login | the Gitea CLI's login is used |
      | the Forgejo CLI has no credentials for the server after it renewed them | the user is told "fj has no credentials for this server. Authenticate again with fj." |

  # Legacy: apps/server/src/sourceControl/SourceControlDiscovery.test.ts (falls back to tea when fj is missing or has no account for this server)
  @mc @backlog
  Scenario Outline: A Forgejo read falls back to the Gitea CLI only when the Forgejo CLI has no account for the server
    Given <state>
    When the MC reads a Forgejo repository on "git.example.com"
    Then the read goes through <cli>

    Examples:
      | state                                                                                 | cli                |
      | the Forgejo CLI is not installed and the Gitea CLI has a login for the server         | the Gitea CLI      |
      | the Forgejo CLI has no login for the server and the Gitea CLI has one                 | the Gitea CLI      |
      | the Forgejo CLI has a login for the server and the Gitea CLI has one too              | the Forgejo CLI    |

  # Legacy: apps/server/src/sourceControl/SourceControlDiscovery.test.ts (a configured fj account owns its requests, including authentication errors)
  @mc @backlog
  Scenario: A refusal on a server the Forgejo CLI is signed in to is reported as it is
    Given the Forgejo CLI has a login for "git.example.com" and the Gitea CLI has one too
    And "git.example.com" refuses the Forgejo CLI's token
    When the MC reads a Forgejo repository on "git.example.com"
    Then the user is told the refusal
    And the Gitea CLI is not tried

  # Legacy: apps/server/src/sourceControl/SourceControlDiscovery.test.ts (handles fj mutation statuses without retrying failures)
  @mc @backlog
  Scenario: A failed change to a Forgejo server is not repeated through another account or tool
    Given the Forgejo CLI and the Gitea CLI both have a login for "git.example.com"
    When the MC posts a comment on "git.example.com" and the server answers with a failure
    Then the user is told the failure
    And the comment is not sent again

  # Legacy: apps/server/src/sourceControl/SourceControlDiscovery.test.ts (rejects HTTP failures even when tea exits successfully)
  @mc @backlog
  Scenario: A Forgejo server's failure counts even when the Gitea CLI itself ends well
    Given the Gitea CLI's request to the server is answered with an HTTP error but the CLI exits without an error
    When the MC reads a Forgejo repository
    Then the read fails with the server's error

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (authenticateFj)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex (whoami_ttl)
  @mc @backlog
  Scenario: An expired Forgejo token is renewed by the Forgejo CLI and not asked for again for half a minute
    Given the Forgejo CLI holds an expired token for "codeberg.org"
    When the MC reads two repositories there within half a minute
    Then the Forgejo CLI is asked to renew its token once
    And both reads use the renewed token

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (resolveTarget: owner of a bare repository name)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex
  @mc @backlog
  Scenario Outline: A Forgejo repository named without its owner belongs to the signed-in account
    Given the Forgejo CLI is signed in to "codeberg.org" as "ada"
    When the user looks up <repository> on Forgejo
    Then the repository read is "<read>"

    Examples:
      | repository      | read          |
      | "notes"         | ada/notes     |
      | "acme/notes"    | acme/notes    |
      | "a/b/c"         | nothing, the user is told to specify owner/repository or the full server URL |

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (requestFj, api: server mounted under a path)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex
  @mc @backlog
  Scenario: A Forgejo server under a path prefix is read through its own prefix
    Given the Forgejo CLI is signed in to "git.example.com/forgejo"
    When the MC reads the repository "acme/notes" there
    Then the request goes to the server's api below "git.example.com/forgejo"
    And the repository is named "acme/notes" without the prefix

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (requestFj: errors, limits)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex
  @mc @backlog
  Scenario Outline: A Forgejo server's refusal is reported in the user's words
    Given the repository is read through <cli>
    And the Forgejo server answers with <answer>
    When the MC reads a Forgejo repository
    Then the user is told "<message>"

    Examples:
      | cli      | answer                      | message                                                                             |
      | any tool | "not found"                 | Forgejo repository or pull request was not found.                                   |
      | tea      | "unauthorized" or "forbidden" | Forgejo denied access. Check this server's `tea login` credentials and permissions. |
      | tea      | "too many requests"         | Forgejo API rate limit exceeded.                                                    |

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (requestFj: manual redirects, 8 MiB cap, 30 s timeout)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex
  @mc @backlog
  Scenario Outline: A Forgejo server's odd answer is not trusted when the MC calls its API itself
    Given the repository is read through fj
    And the Forgejo server <answer>
    When the MC reads a Forgejo repository
    Then <outcome>

    Examples:
      | answer                             | outcome                                                                            |
      | answers with more than 8 MB        | the user is told "Forgejo returned an oversized or invalid response."              |
      | answers with text that is invalid  | the user is told "Forgejo returned an oversized or invalid response."              |
      | redirects to another server        | the redirect is not followed and the token is not sent there                       |
      | does not answer within 30 seconds  | the user is told "Forgejo API request failed or timed out."                        |

  # Legacy: apps/server/src/sourceControl/ForgejoCli.ts (execute: missing-cli)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control/forgejo.ex (@missing)
  @mc @backlog
  Scenario: Forgejo without either command line tool says what to install
    Given neither the Forgejo CLI nor the Gitea CLI is installed
    When the MC reads a Forgejo repository
    Then the user is told to install the Forgejo CLI 0.6 or later or the Gitea CLI 0.16 or later

  # Legacy: apps/server/src/sourceControl/SourceControlProviderDiscovery.ts (selectRemote)
  @mc @backlog
  Scenario Outline: The host of a checkout is read from the most telling remote
    Given the checkout's remotes are <remotes>
    When the user asks which host the checkout is on
    Then the host is the one of <chosen>

    Examples:
      | remotes                                                         | chosen                |
      | "origin" on GitLab and "backup" on GitHub                       | "origin"              |
      | "backup" on an unknown server and "mirror" on GitHub, no origin | "mirror"              |
      | "backup" on an unknown server and "mirror" on another unknown  | "backup", the first   |

  # Legacy: packages/shared/src/sourceControl.ts (detectSourceControlProviderFromRemoteUrl, isSshRemoteUrl)
  @mc @backlog
  Scenario Outline: A remote is told apart by its host name, however the address is written
    Given the checkout's only remote is "<remote>"
    When the user asks which host the checkout is on
    Then the host is reported as "<host>"

    Examples:
      | remote                                          | host                  |
      | https://github.com/acme/app.git                 | GitHub                |
      | git@github.com:acme/app.git                     | GitHub                |
      | git@github.mycorp.example:acme/app.git          | GitHub Self-Hosted    |
      | ssh://git@gitlab.mycorp.example/acme/app.git    | GitLab Self-Hosted    |
      | https://bitbucket.org/acme/app.git              | Bitbucket             |
      | https://bitbucket.mycorp.example/acme/app.git   | Bitbucket Self-Hosted |
      | git@ssh.dev.azure.com:v3/org/project/app        | Azure DevOps          |
      | https://org.visualstudio.com/project/_git/app   | Azure DevOps          |
      | https://codeberg.org/acme/app.git               | Forgejo               |
      | https://git.gitea.mycorp.example/acme/app.git   | Forgejo               |
      | https://git.example.test/acme/app.git          | git.example.test      |

  # Legacy: apps/server/src/sourceControl/SourceControlProviderDiscovery.ts (refineUnknownRemote), gitLabAuthStatus.ts
  @mc @backlog
  Scenario Outline: A self-hosted server is recognised only when the user is signed in to it
    Given the checkout's remote is on "<server>", which is not a well-known host
    And <login>
    When the user asks which host the checkout is on
    Then the host is reported as <host>

    Examples:
      | server           | login                                      | host                  |
      | git.example.com  | the GitLab CLI has a login for it          | "GitLab Self-Hosted"  |
      | git.example.com  | the Forgejo CLI has a login for it         | Forgejo               |
      | git.example.com  | no hosting tool has a login for it         | unknown               |

  # Legacy: apps/server/src/sourceControl/GitLabSourceControlProvider.test.ts (mixed-case provider hosts), gitLabAuthStatus.ts (ports, single-label names)
  @mc @backlog
  Scenario Outline: A self-hosted GitLab is recognised however its name is written
    Given the checkout's remote is on "<remote host>", which is not a well-known host
    And the GitLab CLI has a login for "<login host>"
    When the user asks which host the checkout is on
    Then the host is reported as "GitLab Self-Hosted"

    Examples:
      | remote host             | login host              |
      | Self-Hosted.Example.Test | self-hosted.example.test |
      | localhost:8080          | localhost:8080          |
      | selfhosted              | selfhosted              |

  # Legacy: apps/server/src/sourceControl/SourceControlProviderDiscovery.ts (probe timeouts, detection cache)
  @mc @backlog
  Scenario Outline: A hosting tool that does not answer in time is reported without holding up the rest
    Given <tool> takes longer than <limit> to answer when probed
    When the user asks which source control tools are available
    Then <tool> is reported unavailable without its version or account
    And the other tools are reported as usual

    Examples:
      | tool        | limit      |
      | the GitHub CLI | 5 seconds  |
      | the Azure CLI  | 20 seconds |

  # Legacy: apps/server/src/sourceControl/SourceControlProviderDiscovery.ts (cached results)
  @mc @backlog
  Scenario: Asking again within moments reuses the answer but a failure is asked again
    Given the user asked which source control tools are available a moment ago
    When the user asks again within a few seconds
    Then the earlier answer is returned without probing the tools again
    But a tool that failed to answer is probed again

  # Legacy: apps/server/src/sourceControl/gitHubAuthStatus.ts (minimum gh version, active account)
  @mc @backlog
  Scenario: A GitHub CLI too old to list its accounts says it needs updating
    Given the GitHub CLI on the MC's machine is older than version 2.81
    When the user asks which source control tools are available
    Then GitHub is reported with a note that the GitHub CLI must be updated to list its accounts

  # Legacy: apps/server/src/sourceControl/gitHubAuthStatus.ts, gitLabAuthStatus.ts
  @mc @backlog
  Scenario: The active account is the one shown when several are signed in
    Given the GitHub CLI is signed in to "work" and "home" on the same host and "home" is active
    When the user asks which source control tools are available
    Then GitHub is reported with the account "home"

  # Legacy: apps/server/src/sourceControl/gitHubAuthStatus.ts (token lines removed)
  @mc @backlog
  Scenario: A token printed by a hosting tool never reaches clients
    Given the GitHub CLI's status output includes a line with the token
    When the user asks which source control tools are available
    Then the account detail shown to the client has no token line

  # Legacy: apps/server/src/sourceControl/SourceControlProviderRegistry.ts (resolveLink), GitHubSourceControlProvider.ts, GitLabSourceControlProvider.ts
  @mc @backlog
  Scenario: A pasted link is resolved with the user's credentials only on github.com and gitlab.com
    When the user pastes a link to a pull request on a host that is not github.com or gitlab.com
    Then the link is not looked up with the signed-in tools' credentials

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts (trusted origin, redirects)
  @mc @backlog
  Scenario: A Bitbucket answer that points at another server is not followed
    Given a Bitbucket answer links to the next page or a redirect on a different host
    When the MC reads the list
    Then the link is not followed and no Bitbucket credential is sent there
    And the user is told "The response pointed at that host, outside the configured Bitbucket."

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts (MAX_REDIRECTS, manual redirects)
  @mc @backlog
  Scenario: Bitbucket redirects on the same server are followed a few times only
    Given Bitbucket redirects a request more times than the MC allows
    When the MC makes the request
    Then the request fails instead of following the redirects forever

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts (pagelen clamp, sort, bounded bodies)
  @mc @backlog
  Scenario: Bitbucket lists are limited and most recently updated first
    When the MC lists Bitbucket pull requests asking for 500 at a time
    Then at most 50 are asked for, the most recently updated first
    And a Bitbucket answer larger than the allowed size is refused

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts, BitbucketSourceControlProvider.ts (default branch, clone URL)
  @mc @backlog
  Scenario Outline: A Bitbucket repository's default branch and clone address follow its settings
    Given <model>
    And the checkout's origin uses <protocol>
    When the user looks up the repository
    Then the default branch is <branch>
    And the clone address uses <protocol>

    Examples:
      | model                                                           | protocol | branch                       |
      | its branching model names "develop" as the development branch   | ssh      | "develop"                    |
      | its branching model has no development branch                   | https    | the repository's main branch |

  @mc
  Scenario Outline: Looking up a repository on a host
    When the user looks up "<repository>" on <host>
    Then the repository's name, web address and clone addresses are returned

    Examples:
      | host   | repository |
      | GitHub | acme/shop  |
      | GitLab | acme/infra |

  @mc
  Scenario Outline: Looking up, cloning and publishing on other hosts
    When the user looks up "acme/shop" on <host>
    Then the repository's name, web address and clone addresses are returned

    Examples:
      | host         |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @mc
  Scenario Outline: Cloning over the protocol the user chose
    When the user clones "acme/shop" from GitHub over <protocol>
    Then the clone uses the repository's <protocol> address

    Examples:
      | protocol |
      | ssh      |
      | https    |

  @mc
  Scenario: Cloning needs something to clone
    When the user clones without naming a repository or address
    Then the user is told "A repository or remote URL is required."

  @mc
  Scenario: A cloned project is usable at once and shows its progress
    When the user adds a project by cloning "https://github.com/acme/shop"
    Then the project appears straight away
    And the clone's progress is streamed until the files are in place

  @mc
  Scenario: Cancelling a clone
    Given a clone of "acme/shop" is in progress
    When the user cancels it
    Then the clone stops and is reported as cancelled

  @mc
  Scenario: Retrying a failed clone
    Given the clone of "acme/shop" failed because the network dropped
    When the user retries it
    Then the clone starts again into the same project

  @mc
  Scenario: A failed clone waits for the user while a finished one goes away
    Given one clone finished and another failed
    When some time passes
    Then the finished clone is no longer reported
    But the failed clone is still reported until it is retried

  @mc
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

  @mc
  Scenario: Publishing a repository with nothing to push only adds the remote
    Given the project "notes" is a git repository with no commits
    When the user publishes "notes" to GitHub
    Then the repository is created and added as the remote
    And the result says the remote was added without pushing

  # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (publishRepository: selectRemoteUrl)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control.ex
  @mc @backlog
  Scenario Outline: A published repository is added as a remote over the protocol the user chose
    Given the project "notes" is a git repository with commits and no remote
    When the user publishes "notes" to GitHub choosing <protocol>
    Then the remote added to "notes" uses the <protocol> address of the new repository

    Examples:
      | protocol |
      | https    |
      | ssh      |

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (ensureRemote), SourceControlRepositoryService.ts (publishRepository)
  @mc @backlog
  Scenario Outline: A published repository is added under the remote name the user chose
    Given the project "notes" is a git repository with commits
    And <existing>
    When the user publishes "notes" to GitHub with the remote name "backup"
    Then <outcome>

    Examples:
      | existing                                                              | outcome                                                          |
      | it has no remote                                                      | the remote is added as "backup"                                  |
      | it already has a remote "backup" that points at another repository    | the remote is added as "backup-1" and "backup" is not changed    |
      | it already has the remote "mirror" that points at the new repository | "mirror" is used and no remote is added                          |

  # Legacy: apps/server/src/sourceControl/SourceControlRepositoryService.ts (publishRepository: createRepository fails first)
  @mc @backlog
  Scenario: A repository the host refuses to create leaves the checkout as it was
    Given the project "notes" is a git repository with commits and no remote
    And GitHub refuses the repository name
    When the user publishes "notes" to GitHub
    Then the user is told why GitHub refused it
    And "notes" still has no remote

  # Legacy: apps/server/src/sourceControl/GitLabCli.ts (createRepository, parseRepositoryPath)
  # Legacy: apps/server/src/sourceControl/AzureDevOpsCli.ts (createRepository, parseRepositorySpecifier)
  @mc @backlog
  Scenario Outline: A repository is published into the group or project named before its name
    Given the project "notes" is a git repository with commits and no remote
    When the user publishes "notes" to <host> as "<repository>"
    Then the repository is created <where>

    Examples:
      | host         | repository             | where                                         |
      | GitLab       | acme/tools/notes       | in the group "acme/tools"                     |
      | GitLab       | notes                  | under the signed-in user's own namespace      |
      | Azure DevOps | shop/notes             | in the Azure DevOps project "shop"            |
      | Azure DevOps | notes                  | in the project the checkout's tool defaults to |

  # Legacy: apps/server/src/sourceControl/GitLabCli.ts (createRepository: namespace lookup fails)
  @mc @backlog
  Scenario: Publishing into a group that cannot be found creates nothing
    Given the project "notes" is a git repository with commits and no remote
    And GitLab has no group "acme/tools"
    When the user publishes "notes" to GitLab as "acme/tools/notes"
    Then the user is told why GitLab refused it
    And "notes" still has no remote

  # Legacy: apps/server/src/sourceControl/AzureDevOpsCli.ts (createRepository: visibility not translated)
  @mc @backlog
  Scenario: Azure DevOps repositories take their visibility from their project
    Given the project "notes" is a git repository with commits and no remote
    When the user publishes "notes" to Azure DevOps as a public repository
    Then the repository is created and no visibility is asked of Azure DevOps
    And it is as visible as its Azure DevOps project is

  # Legacy: apps/server/src/sourceControl/ForgejoSourceControlProvider.ts (createRepository)
  @mc @backlog
  Scenario Outline: A Forgejo repository is created under the account or the organization named before its name
    Given the Forgejo CLI is signed in to "codeberg.org" as "ada"
    And the project "notes" is a git repository with commits and no remote
    When the user publishes "notes" to Forgejo as a <visibility> repository named "<repository>"
    Then the repository is created <where>
    And it is created empty and <visibility>

    Examples:
      | visibility | repository  | where                              |
      | private    | ada/notes   | under the signed-in account        |
      | public     | acme/notes  | in the organization "acme"         |

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts (createRepository, parseBitbucketRepositorySlug)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control.ex
  @mc @backlog
  Scenario Outline: A Bitbucket repository is published as workspace and repository
    Given the project "notes" is a git repository with commits and no remote
    When the user publishes "notes" to Bitbucket as a <visibility> repository named "<repository>"
    Then <outcome>

    Examples:
      | visibility | repository   | outcome                                                                                       |
      | private    | acme/notes   | the repository is created in the workspace "acme" as private                                  |
      | public     | acme/notes   | the repository is created in the workspace "acme" as public                                   |
      | private    | notes        | the user is told "Bitbucket repositories must be specified as workspace/repository." and nothing is created |

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts (authFromConfig, probeAuth)
  # Likely already implemented: apps/server-ex/lib/hal_c2/source_control.ex (bitbucket)
  @mc @backlog
  Scenario Outline: Bitbucket's sign-in state follows what the MC was started with
    Given the MC was started with <credentials>
    And Bitbucket <answer> when asked who the account is
    When the user asks which source control tools are available
    Then Bitbucket is reported <state>

    Examples:
      | credentials                                | answer                  | state                                                                              |
      | an access token                            | names the account       | signed in as that account                                                          |
      | an email address and an API token          | names the account       | signed in as that account                                                          |
      | an access token                            | cannot be reached       | configured, with "Bitbucket access token is configured." and no account            |
      | an email address and an API token          | cannot be reached       | configured as the email address, with "Bitbucket API token is configured."         |
      | an email address without an API token      | is not asked            | not authenticated and told which variables to set                                  |
      | nothing                                    | is not asked            | not authenticated and told which variables to set                                  |

  # Legacy: apps/server/src/sourceControl/BitbucketApi.ts (resolveRepository: BitbucketRepositoryRemoteNotFoundError)
  @mc @backlog
  Scenario: A checkout with no Bitbucket remote cannot be asked about Bitbucket
    Given the checkout "notes" has only a remote that is not on Bitbucket
    When the user looks up its Bitbucket pull requests
    Then the user is told that no Bitbucket repository remote was detected for the checkout

  # Legacy: apps/server/src/sourceControl/GitHubCli.ts (deriveRepositoryCloneUrlsFromCreateOutput)
  @mc @backlog
  Scenario: A repository created a moment ago is not looked up before it is used
    Given the project "notes" is a git repository with commits and no remote
    And GitHub has not yet made the new repository visible to lookups
    When the user publishes "notes" to GitHub
    Then the remote is the address GitHub printed when it created the repository
    And the branch is pushed to it

  @desktop @mobile @backlog-mobile
  Scenario: Publishing walks through provider, repository and summary
    Given the project "notes" has no remote
    When the user publishes the repository
    Then the user picks a host, names the repository, picks its visibility and confirms a summary

  @desktop @mobile @backlog-mobile
  Scenario: A host that is not ready is explained before publishing
    Given the GitHub CLI is not signed in
    When the user picks GitHub to publish to
    Then the user is told GitHub is not authenticated and how to fix it

  # Delivered natively (GitController, GitActions' publish dialog); source-control/git-actions.feature runs it in its own words, not these steps.
  @desktop
  Scenario: Starting to publish from the git actions
    Given the project "notes" has commits and no remote
    When the user chooses to publish the repository
    Then publishing begins for "notes"
