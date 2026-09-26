# Sources:
#   apps/server-ex/lib/hal_c2/web/protocol.ex (@version 3, client and server frames, shapes, decode)
#   apps/server-ex/lib/hal_c2/web/socket.ex (hello, snapshot, events, live, resync, end, shell.*, config.*, rpc.*)
#   apps/server-ex/lib/hal_c2/web/router.ex (GET /ws)
#   apps/server-ex/lib/hal_c2/web/wire.ex (snapshot rows and event patches on the wire)
#   packages/client-runtime/src/v3/clusterSocket.ts (the 19 shape types, hello, resync, end)
#   packages/client-runtime/src/v3/session.ts (methods a protocol 3 environment does not serve yet)
#   packages/client-runtime/src/connection/compatibility.ts (SHAPE_PROTOCOL_VERSION, negotiation)
#   packages/contracts/src/rpc.ts (the subscription methods each shape replaces)
#   Counts: 4 client frames, 19 shape types (20 rows: config has a node and an environment form),
#   37 server frame types, 8 refusal reasons; all aligned, 1 dropped.
#   Behaviour of a single subscription (resume, merge, resync timing) lives in
#   node/platform/websocket-protocol.feature. This file is the frame-by-frame ledger.

Feature: Protocol 3 wire parity
  A protocol 3 client talks to a node over one WebSocket of JSON text frames. It subscribes to
  shapes, keeps each in sync from an offset, and calls methods with rpc frames. Every stream
  the TypeScript server offered as a subscription method is a shape here.

  Background:
    Given a node
    And a protocol 3 client connected to it

  @node
  Scenario: The node greets every socket with its protocol version and name
    When the client opens its socket
    Then the first frame is a hello carrying protocol 3 and the node's name

  @node
  Scenario Outline: The node answers a <frame> frame
    When the client sends a <frame> frame with <fields>
    Then the node answers with <answer>

    Examples: 4 client frames
      | frame | fields                                   | answer                                                             |
      | sub   | id, shape, offset (a number or null)     | the shape's first frames under that id                             |
      | unsub | id                                       | nothing further under that id                                      |
      | ping  | none                                     | a pong                                                             |
      | rpc   | id, environment, method, optional payload | an rpc.result or an rpc.error under that id                       |

  @node
  Scenario Outline: A <shape> subscription opens with <first frame>
    When the client subscribes to a <shape> shape with <fields>
    Then the first frame under that id is <first frame>
    And later changes arrive as <later frames>
    And the shape stands in for <replaces>

    # previewAutomation: the node's broker and the TypeScript PreviewAutomationBroker both
    # send the host a connected event as it subscribes, before any agent request.
    Examples: 20 shape forms
      | shape                | fields             | first frame                                           | later frames                                                                              | replaces                                            |
      | shell                | none               | a shell frame with every node and every row           | shell.rows, shell.environment and shell.node frames                                       | orchestration.subscribeShell                        |
      | stream               | node, stream       | snapshot parts, the first with part 0                 | events frames after a live frame, or a resync                                             | orchestration.subscribeThread                       |
      | config               | node               | a config frame, then config.themes and config.usageLimitSources | config.settings, config.providers, config.keybindings, config.themes, config.usageLimitSources and config.ready frames | server.getConfig, subscribeServerConfig, subscribeServerLifecycle |
      | config               | environment        | the same frames as the node form for the environment's node | the same frames as the node form                                                     | server.getConfig, subscribeServerConfig, subscribeServerLifecycle |
      | terminal             | node, input        | a terminal frame with the terminal's snapshot         | terminal frames                                                                           | terminal.attach                                     |
      | terminals            | node               | a terminals frame                                     | terminals frames                                                                          | subscribeTerminalMetadata                           |
      | vcs                  | node, cwd          | a vcs frame with the checkout's status                | vcs frames                                                                                | subscribeVcsStatus                                  |
      | providerAuth         | node, instanceId   | a providerAuth frame with the sign-in state           | providerAuth frames                                                                       | provider.auth.subscribe                             |
      | worktreeSetup        | node, threadId     | a worktreeSetup frame, null or a snapshot             | worktreeSetup frames                                                                      | subscribeWorktreeSetup                              |
      | scheduledTasks       | node               | a scheduledTasks frame with every task                | scheduledTasks frames with the whole list                                                 | scheduledTasks.subscribe                            |
      | authAccess           | none               | an authAccess frame with links and paired clients     | authAccess frames                                                                         | subscribeAuthAccess                                 |
      | projectClones        | node               | a projectClones frame with every clone in progress    | projectClones frames with the whole list                                                  | subscribeProjectClones                              |
      | preview              | node               | nothing until a preview tab changes                   | preview frames                                                                            | subscribePreviewEvents                              |
      | resourceTelemetry    | node               | a resourceTelemetry frame                             | a resourceTelemetry frame every few seconds while subscribed                              | subscribeResourceTelemetry                          |
      | localServers         | node               | a localServers frame with the current list            | localServers frames whenever the list changes                                             | subscribeDiscoveredLocalServers                     |
      | devices              | node               | a devices frame with the whole device state           | devices frames with the whole state                                                       | subscribeDeviceState                                |
      | previewAutomation    | node, host         | a previewAutomation frame saying it is connected      | previewAutomation frames                                                                  | previewAutomation.connect                           |
      | pullRequestRefreshes | node               | a pullRequestRefreshes frame with the revision        | pullRequestRefreshes frames with each new revision                                        | pullRequests.subscribeRefreshes                     |
      | gitAction            | node, input        | a gitAction frame as the action starts                | gitAction progress frames                                                                 | git.runStackedAction                                |
      | serverUpdate         | node, input        | a serverUpdate frame as the update starts             | serverUpdate progress frames                                                              | server.updateServerWithProgress                     |

  @node
  Scenario Outline: A <shape> subscription ends on its own
    Given the client is subscribed to a <shape> shape
    When <ending>
    Then the node sends <last frames>
    And the node forgets the subscription

    Examples: shapes with an end
      | shape             | ending                                    | last frames                                                  |
      | gitAction         | the action finishes or fails              | a gitAction frame with action_finished or action_failed      |
      | serverUpdate      | the update completes                      | a serverUpdate frame with complete, then an end frame        |
      | serverUpdate      | the update fails                          | an error frame with the reason and its detail                |
      | previewAutomation | the node drops the client as its host     | an end frame                                                 |

  @node
  Scenario Outline: The node sends <frame> frames
    Given the client is subscribed to a shape that uses <frame> frames
    When <when>
    Then the client receives a <frame> frame carrying <fields>

    Examples: 30 socket, stream, config and node frames
      | frame                      | when                                                   | fields                                                    |
      | hello                      | the socket opens                                       | protocol, node                                            |
      | pong                       | the client pings                                       | nothing else                                              |
      | error                      | a frame or subscription is refused                     | reason, and the id when there is one                      |
      | rpc.result                 | a method succeeds                                      | id, result                                                |
      | rpc.error                  | a method fails                                         | id, error, and the contract error as detail when there is one |
      | shell                      | the shell subscription opens                           | id, nodes with online and environment, rows               |
      | shell.rows                 | projects or threads on one node change                 | id, node, rows                                            |
      | shell.environment          | a node's environment descriptor changes                | id, node, environment                                     |
      | shell.node                 | a node joins or leaves the cluster                     | id, node, online                                          |
      | snapshot                   | a stream subscription starts or falls too far behind   | id, offset, at, part, rows in creation order, done        |
      | events                     | stream entities change                                 | id, offset, events as seq, kind, id, patch and unix ms at |
      | live                       | a stream has caught up                                 | id, offset                                                |
      | resync                     | a client falls behind                                  | id, the offset to resubscribe from                        |
      | end                        | a shape is over                                        | id                                                        |
      | config                     | a config subscription opens                            | id, node, the node's server config                        |
      | config.ready               | the node moves to another version in place             | id, new environment descriptor, update outcome            |
      | config.settings            | the node's settings change                             | id, settings                                              |
      | config.themes              | the node's published themes change                     | id, themes                                                |
      | config.usageLimitSources   | the node's usage limit sources change                  | id, sources                                               |
      | config.keybindings         | the node's keybinding rules change                     | id, the whole rule list                                   |
      | config.providers           | the node's providers change                            | id, providers                                             |
      | terminal                   | an attached terminal emits                             | id, event                                                 |
      | terminals                  | terminal summaries change                              | id, event                                                 |
      | vcs                        | a checkout's status changes                            | id, event                                                 |
      | providerAuth               | a provider's sign-in state changes                     | id, state                                                 |
      | worktreeSetup              | a thread's worktree setup progresses                   | id, event                                                 |
      | scheduledTasks             | a scheduled task changes                               | id, tasks                                                 |
      | authAccess                 | a pairing link or paired client changes                | id, event                                                 |
      | projectClones              | a project clone progresses                             | id, clones                                                |
      | pullRequestRefreshes       | pull requests are refreshed                            | id, revision                                              |

  @node
  Scenario Outline: The node sends <frame> frames for its host
    Given the client is subscribed to a <shape> shape
    When <when>
    Then the client receives a <frame> frame carrying <fields>

    Examples: host frames
      | frame             | shape             | when                                        | fields         |
      | preview           | preview           | a preview tab changes                       | id, event      |
      | previewAutomation | previewAutomation | an agent drives the client's browser        | id, event      |
      | resourceTelemetry | resourceTelemetry | the resource monitor takes a sample         | id, snapshot   |
      | localServers      | localServers      | a web server starts or stops on the host    | id, list       |
      | devices           | devices           | a simulator, emulator or device session changes | id, state  |
      | gitAction         | gitAction         | a git action progresses                     | id, event      |
      | serverUpdate      | serverUpdate      | a version move progresses                   | id, event      |

  @node
  Scenario Outline: The node refuses <case> with "<reason>"
    When the client sends <case>
    Then the node answers with a <frame> frame whose reason is "<reason>"
    And the socket stays open

    Examples: 8 refusal reasons
      | case                                                     | frame     | reason                  |
      | text that is not JSON                                    | error     | invalid json            |
      | a frame with an unknown or missing type                  | error     | unknown message         |
      | a subscription to a shape type the node does not know    | error     | unknown shape           |
      | a subscription naming a node outside the cluster         | error     | unknown node            |
      | a config subscription for an unknown environment         | error     | unknown environment     |
      | an authAccess subscription from a session without access:read | error | access:read is required |
      | an rpc for an unknown environment                        | rpc.error | unknown environment     |
      | an rpc whose node has gone away                          | rpc.error | node unavailable        |

  @node
  Scenario: Activity reports go to the node's background policy without a reply payload
    When the client calls server.reportClientActivity in an rpc frame
    Then the node records the activity lease for the client's session and socket
    And the rpc.result carries no result

  @node
  Scenario: Methods a protocol 3 environment does not serve fail in the client
    When a client calls a method the protocol 3 adapter does not carry
    Then the call fails in the client saying the method is not served by protocol-3 environments yet
    And no frame is sent to the node

  # The node speaks only protocol 3. Clients negotiate from the environment descriptor
  # (compatibility.ts) and use the protocol 3 adapter, so the node does not also serve the
  # TypeScript server's Effect RPC wire protocol on /ws.
  @dropped @node
  Scenario: A client speaking the TypeScript RPC wire protocol is served by the node
    Given a client that speaks only the TypeScript server's orchestration protocol
    When it connects to the node's socket
    Then the node serves its requests
