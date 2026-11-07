# Sources:
#   https://github.com/pingdotgg/t3code/pull/27197 (T3 Code's managed policy: loading, settings overlay, limits)
#   https://github.com/pingdotgg/t3code/pull/30973
#   https://github.com/pingdotgg/t3code/pull/29915
#   https://github.com/pingdotgg/t3code/pull/29911
#   https://github.com/pingdotgg/t3code/pull/29862
#   https://github.com/pingdotgg/t3code/pull/30319

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

    # Upstream #30973: a policy locking the telemetry export addresses was accepted and
    # listed as locked, but the server read them from the user's settings regardless.
    @backlog @mc @priority-low
    Scenario: A policy that sets where telemetry is exported stops the MC from starting
      Given the machine's managed policy locks the address traces are exported to
      When the MC starts
      Then it refuses to start, saying a policy cannot set telemetry export yet
      And checking the policy with the MC's command line gives the same reason

    @backlog @mc @priority-low
    Scenario: An administrator checks a policy before deploying it
      When the administrator checks a policy file with the MC's command line
      Then they are told whether this version can enforce it, and what is wrong if not
      And they can show the policy the machine enforces now

    # Upstream #29862: admins had to paste the whole policy as one line of JSON into the registry.
    @backlog @mc @priority-low
    Scenario: An administrator writes device management templates for the policy
      When the administrator asks the MC's command line for policy templates
      Then they get a Group Policy template for Windows and a configuration profile for macOS
      And a policy set through the Windows template is read the same as a policy file
      And a machine whose policy is set both ways refuses to start

    # Upstream #30319: the error window offered an update, an older version or the releases page,
    # though any version reads the same policy.
    @backlog @desktop @priority-low
    Scenario: A policy that stops the MC from starting sends the user to their administrator
      Given the machine's managed policy stops the MC from starting
      When the desktop app opens
      Then it says the organization's managed policy stopped HAL-C2 from starting
      And it asks the user to send the details, which name what to fix, to their IT administrator
      And it offers no older version and no releases page, only an update that is already available

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

    # Upstream #29915: one built-in provider (Kiro, which HAL-C2 does not ship) was missing from the
    # policy's providers, so its launch settings escaped the cap and admins could not allow it.
    @backlog @mc
    Scenario: The policy covers every provider the MC ships
      Given a policy that allows and pins every provider the MC ships
      When the MC starts
      Then the policy is accepted
      And every provider's binary and environment follow the policy's cap

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

    # Upstream #29911: only the desktop app followed the policy's mirror; the CLI and remote server
    # updates still found and downloaded the newest release from GitHub.
    @backlog @mc @priority-high
    Scenario: An MC under a policy mirror updates only to versions the mirror publishes
      Given the policy names the company's update mirror
      When the MC is updated from its command line or from a client
      Then the newest version comes from the mirror and is downloaded from it
      And a version the mirror does not publish is refused, naming the organization's mirror
