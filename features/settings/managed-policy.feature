# Sources:
#   https://github.com/pingdotgg/t3code/pull/27197 (T3 Code's managed policy: loading, settings overlay, limits)

# Upstream #27197: an organization's administrator deploys a policy with their device management
# tool, and the machine's server enforces it for every client, agent, scheduled task and the CLI.
Feature: Managed policy
  An administrator rolling HAL-C2 out to a team deploys a managed policy to each machine.
  The policy sets defaults and locks for settings and limits what the environment may do,
  and the MC enforces it whichever client or agent asks.

  Rule: The policy is read when the MC starts

    @backlog @mc
    Scenario Outline: A policy the MC cannot enforce stops it from starting
      Given the machine's managed policy <problem>
      When the MC starts
      Then it refuses to start and says what is wrong with the policy

      Examples:
        | problem                                         |
        | is not valid JSON                               |
        | has a key this version does not know            |
        | has a value of the wrong type                   |
        | is deployed both natively and as a file         |

    @backlog @mc @priority-low
    Scenario: An administrator checks a policy before deploying it
      When the administrator checks a policy file with the MC's command line
      Then they are told whether this version can enforce it, and what is wrong if not
      And they can show the policy the machine enforces now

  Rule: The policy sets defaults and locks for settings

    @backlog @mc
    Scenario: A policy default holds until the user chooses otherwise
      Given the policy makes "Auto-open the preview" off by default
      When the user has not chosen
      Then "Auto-open the preview" is off
      When the user turns it on
      Then it is on

    @backlog @mc
    Scenario Outline: A locked setting cannot be changed
      Given the policy locks the approval mode to "Ask"
      When <who> sets it to something else
      Then the change is refused
      And the setting stays "Ask"

      Examples:
        | who                                  |
        | the user, for all projects           |
        | the user, in a project's overrides   |
        | an agent through MCP                 |

    @backlog @mc
    Scenario: Removing the policy gives back what the user had chosen
      Given the user chose a setting before the policy locked it
      When the policy is removed and the MC starts again
      Then the setting is what the user had chosen

    @backlog @desktop @mobile
    Scenario: A locked setting says who manages it
      Given the policy of "Acme" locks a setting
      When the user opens that setting
      Then it cannot be changed and reads "Managed by Acme"

  Rule: The policy limits what the environment may do

    @backlog @mc
    Scenario Outline: Nothing starts with more permission than the policy allows
      Given the policy allows at most asking for approval
      When <what> asks for full access
      Then it is refused

      Examples:
        | what                       |
        | a turn the user starts     |
        | an agent through MCP       |
        | a scheduled task's run     |
        | an ACP session's mode      |

    @backlog @mc
    Scenario: A thread above the permission the policy allows is not lowered behind the user's back
      Given a thread in full access
      And the policy now allows at most asking for approval
      When the user sends a message there
      Then the turn is refused
      And the thread is still in full access until the user switches it down

    @backlog @desktop @mobile
    Scenario: A thread above the allowed permission offers to switch down
      Given a thread in full access and a policy that allows at most asking for approval
      When the user opens the thread
      Then the modes above the policy cannot be picked
      And one click switches the thread to the broadest mode allowed

    @backlog @mc
    Scenario: Under a permission cap providers are launched only as the policy says
      Given the policy caps the permission mode
      Then a provider's binary, launch arguments and environment come from the policy alone
      And the user's own launch settings for providers are not used

    @backlog @mc
    Scenario: Only the providers the policy allows can be used
      Given the policy allows Claude and Codex
      When the user adds a Cursor instance
      Then it is refused

    @backlog @mc
    Scenario: A provider is routed the way the policy says
      Given the policy sets the base URL of every Claude instance to the company gateway and locks it
      When any Claude instance runs a turn
      Then it uses the company gateway
      And the user cannot change that instance's base URL

    @backlog @mc
    Scenario: Clients the policy does not allow cannot connect
      Given the policy allows only clients on this machine
      Then the MC does not listen beyond this machine
      And it gives out no pairing links
      And devices paired earlier are unpaired when it starts

    @backlog @mc
    Scenario Outline: The policy turns off <what>
      Given the policy turns off <what>
      Then <result>

      Examples:
        | what                   | result                                             |
        | webhook tasks          | no scheduled task can be started by a webhook      |
        | browser cookie import  | the preview cannot import cookies from a browser   |
        | telemetry              | no product events or traces are sent               |

    @backlog @mc @desktop
    Scenario Outline: The policy controls updates
      Given the policy <limit>
      Then <result>

      Examples:
        | limit                          | result                                           |
        | turns updates off              | the app neither checks for nor offers updates     |
        | does not allow nightly builds  | the nightly channel cannot be chosen              |
        | names the company's mirror     | the desktop looks for updates at that mirror      |
