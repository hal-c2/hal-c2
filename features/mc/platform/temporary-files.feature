# Sources:
#   https://github.com/hal-c2/hal-c2/issues/483 (agents' processes are uncontained)
#   https://github.com/hal-c2/hal-c2/issues/485 (scratch paths collide between VMs)
#   apps/server-ex/lib/hal_c2/scratch.ex (the MC's and each thread's temporary files)
#   apps/server-ex/lib/hal_c2/project_environment.ex (for_turn: the launch environment)
#   apps/server-ex/lib/hal_c2/storage_cleanup.ex (the hourly sweep)

Feature: Temporary files
  An agent's temporary files can outgrow the machine's temp folder, which is often held
  in memory and shared by everything on the machine. The MC gives them a place of their
  own, on a disk the user can choose, and removes them when nothing needs them.

  Background:
    Given an MC with a project "api"

  Rule: Each thread's agent sessions have their own temp folder

    @mc
    Scenario: An agent session starts with its thread's temp folder
      Given a thread "work"
      When an agent session of "work" is launched
      Then its temporary file variables all name the folder of "work"
      And that folder exists and only the user can read it

    @mc
    Scenario: A temp folder the provider instance names wins
      Given a thread "work"
      When an agent session of "work" is launched with TMPDIR set by its provider instance
      Then its TMPDIR is the one the provider instance set

    # Stops a mistyped or unmounted location from taking agents down with it.
    @mc
    Scenario: A session starts without one when the folder cannot be made
      Given a thread "work"
      And the MC cannot write to its temporary files location
      When an agent session of "work" is launched
      Then its launch sets no temporary file variables

  Rule: The user chooses where temporary files go

    @mc
    Scenario: By default temporary files are in the cache directory
      When the MC makes a temporary folder of its own
      Then the folder is inside the MC's cache directory

    @mc
    Scenario: HAL_C2_TMPDIR moves temporary files
      Given HAL_C2_TMPDIR names a folder on another disk
      When the MC makes a temporary folder of its own
      Then the folder is inside the one HAL_C2_TMPDIR names

    # Each MC's boot removes its own leftovers, so they cannot share a folder.
    @mc
    Scenario: Two MCs given the same HAL_C2_TMPDIR do not share a folder
      Given HAL_C2_TMPDIR names a folder on another disk
      Then two MCs with different homes keep their temporary files apart

    @mc
    Scenario: An HAL_C2_TMPDIR that is not an absolute path is ignored
      Given HAL_C2_TMPDIR is "relative/path"
      When the MC makes a temporary folder of its own
      Then the folder is inside the MC's cache directory

  Rule: Temporary files go when nothing needs them

    @mc
    Scenario Outline: The sweep removes a thread's temp folder
      Given a thread "work" with a temp folder holding a file
      And "work" <condition>
      When the MC sweeps storage
      Then the temp folder of "work" is gone

      Examples:
        | condition                  |
        | is deleted                 |
        | has been idle for 8 days   |

    @mc
    Scenario Outline: The sweep leaves a thread's temp folder
      Given a thread "work" with a temp folder holding a file
      And "work" <condition>
      When the MC sweeps storage
      Then the temp folder of "work" still holds its file

      Examples:
        | condition                                |
        | was active yesterday                     |
        | has been idle for 8 days but has a run   |

    @mc
    Scenario: A folder the MC did not name is left alone
      Given a thread "work" with a temp folder holding a file
      And a folder the MC did not name sits beside it
      When the MC sweeps storage
      Then that folder is still there

    @mc
    Scenario: The next start removes what a crash left behind
      Given a temporary file of the MC's is still there
      When the MC prepares its files at the next start
      Then that file is gone
      And the temp folder of a thread is kept

  # NVIDIA OpenShell does not fit: it copies the project in, and its live mounts bypass its
  # own policy. A private mount namespace per session needs only bubblewrap (Linux).
  Rule: Scratch files an agent writes to a literal /tmp are contained too

    @mc @backlog
    Scenario: On Linux an agent's /tmp is its thread's temp folder
      Given a thread "work" on Linux with bubblewrap installed
      When the agent of "work" writes "/tmp/build"
      Then the file is in the temp folder of "work"
      And the machine's own /tmp is unchanged
