# Sources:
#   apps/server-ex/lib/t3/projects.ex (projects.mutate: project.create, project.update,
#     project.delete; which project a folder belongs to)
#   packages/contracts/src/project.ts (ProjectMutation, ProjectMutationError, Project)
#   packages/contracts/src/orchestrationV2.ts (project.updated, project.removed)
#   apps/server/src/orchestration/decider.ts (project.create, project.meta-update,
#     project.delete with force), apps/server/src/project/ProjectMutation.ts
Feature: Projects on a node
  A project is a workspace folder on the node with its own settings. Threads live
  in projects.

  Background:
    Given a node

  @node
  Scenario: Creating a project for an existing folder
    Given the folder "~/code/app" exists
    When a client creates project "p1" for "~/code/app"
    Then project "p1" exists with title "app" and the folder expanded to a full path
    And it has no scripts and is not deleted

  @node
  Scenario: A project can be created with its own title, model and scripts
    When a client creates project "p1" titled "App" with a default model and a test script
    Then project "p1" has that title, default model and script

  @node
  Scenario: A missing folder can be created with the project
    Given the folder "~/code/new" does not exist
    When a client creates project "p1" for "~/code/new" asking to create the folder
    Then the folder exists and project "p1" points at it

  @node
  Scenario Outline: Projects that cannot be created
    When a client creates a project <input>
    Then it fails with "<message>"

    Examples:
      | input                                             | message                                     |
      | with no folder                                    | a workspace folder is required              |
      | for missing folder /missing without asking to create it | /missing does not exist on this machine     |

  @node
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

  @node
  Scenario: An update that changes nothing records nothing
    Given project "p1" is titled "App"
    When a client sets its title to "App"
    Then no change is recorded for "p1"

  @node
  Scenario: Deleting a project hides it
    Given project "p1" exists
    When a client deletes "p1"
    Then "p1" is marked deleted and no longer listed for clients

  @node
  Scenario Outline: Changing an unknown project fails
    When a client <action> project "nowhere"
    Then it fails with "unknown project nowhere"

    Examples:
      | action  |
      | updates |
      | deletes |

  @node
  Scenario: An unknown project change is refused
    When a client sends a project change of type "project.rename"
    Then it fails with "project.rename is not supported"

  @node
  Scenario: A folder inside a thread's worktree belongs to that thread's project
    Given thread "t1" of project "p1" works in a worktree outside the project folder
    Then a path inside that worktree belongs to project "p1"

  @node
  Scenario: The deepest project folder owns a path
    Given project "outer" has "~/code" and project "inner" has "~/code/app"
    Then "~/code/app/src" belongs to project "inner"
    And "~/code/other" belongs to project "outer"

  @node
  Scenario: Projects imported from the Node server read like native ones
    Given a project was imported from a Node server's history
    When a client reads it
    Then it has the same shape as a project created on the node

  @node
  Scenario: Two projects cannot share a folder
    Given project "p1" has the folder "~/code/app"
    When a client creates or moves another project to "~/code/app"
    Then it fails because the folder already belongs to a project

  @node
  Scenario: Deleting a project with threads needs force
    Given project "p1" has threads
    When a client deletes "p1" without force
    Then it fails because the project is not empty
    When a client deletes "p1" with force
    Then its threads are deleted and then the project
