# Sources:
#   apps/server-ex/lib/hal_c2/projects.ex (projects.mutate: project.create, project.update,
#     project.delete; which project a folder belongs to; repository identity)
#   apps/server/src/project/RepositoryIdentityResolver.ts,
#     packages/client-runtime/src/state/projectGrouping.ts (grouping by canonicalKey)
#   packages/contracts/src/project.ts (ProjectMutation, ProjectMutationError, Project)
#   packages/contracts/src/orchestrationV2.ts (project.updated, project.removed)
#   apps/server/src/orchestration/decider.ts (project.create, project.meta-update,
#     project.delete with force), apps/server/src/project/ProjectMutation.ts
Feature: Projects on an MC
  A project is a workspace folder on the MC with its own settings. Threads live
  in projects.

  Background:
    Given an MC

  @mc
  Scenario: Creating a project for an existing folder
    Given the folder "~/code/app" exists
    When a client creates project "p1" for "~/code/app"
    Then project "p1" exists with title "app" and the folder expanded to a full path
    And it has no scripts and is not deleted

  @mc
  Scenario: A project can be created with its own title, model and scripts
    When a client creates project "p1" titled "App" with a default model and a test script
    Then project "p1" has that title, default model and script

  @mc
  Scenario: A missing folder can be created with the project
    Given the folder "~/code/new" does not exist
    When a client creates project "p1" for "~/code/new" asking to create the folder
    Then the folder exists and project "p1" points at it

  @mc
  Scenario Outline: Projects that cannot be created
    When a client creates a project <input>
    Then it fails with "<message>"

    Examples:
      | input                                             | message                                     |
      | with no folder                                    | a workspace folder is required              |
      | for missing folder /missing without asking to create it | /missing does not exist on this machine     |

  @mc
  Scenario Outline: Updating a project's settings
    Given project "p1" exists
    When a client updates the <field> of "p1"
    Then "p1" has the new <field> and a later update time

    Examples:
      | field                          |
      | title                          |
      | folder                         |
      | default model                  |
      | scripts                        |
      | automatic pull choice          |
      | icon                           |
      | favicon path                   |
      | default thread workspace mode  |

  @mc
  Scenario: An update that changes nothing records nothing
    Given project "p1" is titled "App"
    When a client sets its title to "App"
    Then no change is recorded for "p1"

  @mc
  Scenario: Deleting a project hides it
    Given project "p1" exists
    When a client deletes "p1"
    Then "p1" is marked deleted and no longer listed for clients

  @mc
  Scenario Outline: Changing an unknown project fails
    When a client <action> project "nowhere"
    Then it fails with "unknown project nowhere"

    Examples:
      | action  |
      | updates |
      | deletes |

  @mc
  Scenario: An unknown project change is refused
    When a client sends a project change of type "project.rename"
    Then it fails with "project.rename is not supported"

  @mc
  Scenario: A folder inside a thread's worktree belongs to that thread's project
    Given thread "t1" of project "p1" works in a worktree outside the project folder
    Then a path inside that worktree belongs to project "p1"

  @mc
  Scenario: The deepest project folder owns a path
    Given project "outer" has "~/code" and project "inner" has "~/code/app"
    Then "~/code/app/src" belongs to project "inner"
    And "~/code/other" belongs to project "outer"

  Rule: A project knows the repository its folder is a checkout of, so clients can
    group checkouts of one repository on different machines

    @mc
    Scenario: A project in a checkout carries its repository
      Given the folder "~/code/app" is a checkout whose origin is "git@github.com:Acme/Shop.git"
      When a client creates project "p1" for "~/code/app"
      Then project "p1" is a checkout of "github.com/acme/shop" named "shop" owned by "acme"

    @mc
    Scenario: A project outside a repository has none
      Given the folder "~/code/app" exists
      When a client creates project "p1" for "~/code/app"
      Then project "p1" is not a checkout of any repository

    @mc
    Scenario: Credentials in an origin stay on the machine
      Given the folder "~/code/app" is a checkout whose origin is "https://bot:secret@github.com/acme/shop.git"
      When a client creates project "p1" for "~/code/app"
      Then project "p1" is a checkout of "github.com/acme/shop" named "shop" owned by "acme"
      And its remote is "https://github.com/acme/shop.git"

    @mc
    Scenario: A project moved to another checkout takes on its repository
      Given project "p1" is a checkout of "https://github.com/acme/shop"
      When a client moves "p1" to a checkout of "git@github.com:acme/other.git"
      Then project "p1" is a checkout of "github.com/acme/other" named "other" owned by "acme"

    @mc
    Scenario: A project learns its repository when the MC loads new code in place
      Given project "p1" was added before its checkout had the origin "git@github.com:acme/shop.git"
      When the MC loads new code in place
      Then project "p1" is a checkout of "github.com/acme/shop" named "shop" owned by "acme"

    @mc
    Scenario: A project learns its repository when the MC starts
      Given project "p1" was added before its checkout had the origin "git@github.com:acme/shop.git"
      When the MC restarts
      Then project "p1" is a checkout of "github.com/acme/shop" named "shop" owned by "acme"

  @mc
  Scenario: Projects imported from the Node server read like native ones
    Given a project was imported from a Node server's history
    When a client reads it
    Then it has the same shape as a project created on the MC

  @mc
  Scenario: Two projects cannot share a folder
    Given project "p1" has the folder "~/code/app"
    When a client creates or moves another project to "~/code/app"
    Then it fails because the folder already belongs to a project

  @mc
  Scenario: Deleting a project with threads needs force
    Given project "p1" has threads
    When a client deletes "p1" without force
    Then it fails because the project is not empty
    When a client deletes "p1" with force
    Then its threads are deleted and then the project
