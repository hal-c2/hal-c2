# Sources:
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2Command tags, version 2 event types)
#   packages/contracts/src/orchestration.ts (OrchestrationEventType: the version 1 log)
#   apps/server-ex/test/t3/node_parity_test.exs (@commands: status and dispatch path of every command)
#   apps/server-ex/lib/t3/orchestration.ex (dispatch clauses, @thread_updates)
#   apps/server-ex/lib/t3/import/v2.ex (how each Node event becomes an entity patch)
#   apps/server/src/orchestration/decider.ts, apps/server/src/orchestration/projector.ts
#   Counts: 47 commands (37 aligned, 0 backlog, 10 dropped);
#   41 version 2 events (all aligned); 32 version 1 events (all aligned).
#   The node stores whole-entity changes as patches keyed by entity kind, so an event
#   is aligned when the node records the same entity change and streams it to clients.
#   Shared domain: node/orchestration/ holds what each command does to a thread.

Feature: Command and event parity with the TypeScript server
  Every orchestration command a client can dispatch is handled by the node or is internal
  to the TypeScript server. Every event the TypeScript server logs has a matching entity
  change on the node, so an imported log and a live node agree.

  Background:
    Given a node
    And a paired protocol 3 client with a project and a thread

  @node
  Scenario Outline: The node handles the <command> command
    When the client dispatches <command>
    Then the node accepts it through its <kind> path
    And clients following the thread see the resulting change

    Examples: 37 aligned commands
      | command                         | kind          |
      | thread.create                   | dispatch      |
      | thread.archive                  | thread update |
      | thread.unarchive                | thread update |
      | thread.delete                   | thread update |
      | thread.settle                   | thread update |
      | thread.auto-settle              | dispatch      |
      | thread.unsettle                 | thread update |
      | thread.snooze                   | thread update |
      | thread.unsnooze                 | thread update |
      | thread.pin                      | thread update |
      | thread.unpin                    | thread update |
      | thread.pin.reorder              | thread update |
      | thread.active.reorder           | thread update |
      | thread.visit                    | thread update |
      | thread.mark-unread              | thread update |
      | thread.metadata.update          | thread update |
      | thread.pull-request.link        | thread update |
      | thread.pull-request.unlink      | thread update |
      | thread.pull-request-link.sync   | dispatch      |
      | thread.pull-request.sync        | dispatch      |
      | thread.runtime-mode.set         | thread update |
      | thread.interaction-mode.set     | thread update |
      | thread.model-selection.set      | thread update |
      | provider-session.detach         | dispatch      |
      | message.dispatch                | dispatch      |
      | run.interrupt                   | dispatch      |
      | queued-message.promote-to-steer | dispatch      |
      | queue.resume                    | dispatch      |
      | queued-run.reorder              | dispatch      |
      | queued-run.cancel               | dispatch      |
      | queued-run.edit                 | dispatch      |
      | runtime-request.respond         | dispatch      |
      | thread.user-input.dismiss       | dispatch      |
      | checkpoint.rollback             | dispatch      |
      | thread.fork                     | dispatch      |
      | thread.merge_back               | dispatch      |
      | provider.switch                 | thread update |

  # These commands are sent by the TypeScript server's own workers, never by a client. The
  # node does the same work in-process or over MCP, so it answers that the command is not supported.
  @dropped @node
  Scenario Outline: The node refuses the internal <command> command
    When the client dispatches <command>
    Then the node answers "<command> is not supported by this node yet"

    Examples: 10 dropped commands
      | command                                        | reason                                                                             |
      | thread.title.regeneration.complete             | Node's title worker reports back; here thread.metadata.update regenerates in place |
      | prepared-run.release                           | Node's launch worker; runs start in-process here                                   |
      | notification.delivery.accept                   | Node's notification worker                                                         |
      | prepared-run.progress                          | Node's launch worker; runs start in-process here                                   |
      | prepared-run.fail                              | Node's launch worker; runs start in-process here                                   |
      | delegated_task.request                         | agents delegate over MCP (T3.Orchestration.Delegation)                             |
      | delegated_task.wake-policy                     | agents delegate over MCP (T3.Orchestration.Delegation)                             |
      | delegated_task.completion-delivery.acknowledge | agents delegate over MCP (T3.Orchestration.Delegation)                             |
      | delegated_task.completion-delivery.dispose     | agents delegate over MCP (T3.Orchestration.Delegation)                             |
      | thread.created.record                          | Node's thread-creation receipt; thread.create records here                         |

  @node
  Scenario Outline: The node records the change a <event> event carries
    Given the TypeScript server logged <event> for an entity
    When the node records the same change
    Then it stores <recorded as>
    And streams it to clients following the <entity>

    Examples: 41 version 2 events
      | event                           | entity           | recorded as                                            |
      | checkpoint.captured             | checkpoint       | a patch on the checkpoint entity                       |
      | checkpoint.rollback-requested   | checkpoint       | a patch on the checkpoint entity                       |
      | checkpoint-scope.created        | checkpoint-scope | a patch on the checkpoint-scope entity                 |
      | context-handoff.updated         | context-handoff  | a patch on the context-handoff entity                  |
      | context-transfer.created        | context-transfer | a patch on the context-transfer entity                 |
      | context-transfer.updated        | context-transfer | a patch on the context-transfer entity                 |
      | message.updated                 | message          | a patch on the message entity                          |
      | node.updated                    | node             | a patch on the node entity                             |
      | plan.updated                    | plan             | a patch on the plan entity                             |
      | provider-session.attached       | provider-session | a patch that binds the session to the thread           |
      | provider-session.detached       | provider-session | a patch that unbinds the session from the thread       |
      | provider-session.updated        | provider-session | a patch on the session while the thread is bound to it |
      | provider-thread.updated         | provider-thread  | a patch that makes it the active provider thread       |
      | provider-turn.updated           | provider-turn    | a patch on the provider-turn entity                    |
      | run-attempt.created             | run-attempt      | a patch on the run-attempt entity                      |
      | run-attempt.updated             | run-attempt      | a patch on the run-attempt entity                      |
      | run.created                     | run              | a patch on the run entity                              |
      | runtime-request.updated         | runtime-request  | a patch on the runtime-request entity                  |
      | run.updated                     | run              | a patch on the run entity                              |
      | subagent.updated                | subagent         | a patch on the subagent entity                         |
      | thread.active-reordered         | thread           | a patch on the thread entity                           |
      | thread.archived                 | thread           | a patch on the thread entity                           |
      | thread.created                  | thread           | a patch on the thread entity                           |
      | thread.deleted                  | thread           | a patch on the thread entity                           |
      | thread.interaction-mode-updated | thread           | a patch on the thread entity                           |
      | thread.marked-unread            | thread           | a quiet patch on the thread                            |
      | thread.metadata-updated         | thread           | a patch on the thread entity                           |
      | thread.model-selection-updated  | thread           | a patch on the thread entity                           |
      | thread.pinned                   | thread           | a patch on the thread entity                           |
      | thread.pin-reordered            | thread           | a patch on the thread entity                           |
      | thread.provider-switched        | thread           | a patch on the thread entity                           |
      | thread.pull-request-synced      | thread           | a patch on the thread entity                           |
      | thread.runtime-mode-updated     | thread           | a patch on the thread entity                           |
      | thread.settled                  | thread           | a patch on the thread entity                           |
      | thread.snoozed                  | thread           | a patch on the thread entity                           |
      | thread.unarchived               | thread           | a patch on the thread entity                           |
      | thread.unpinned                 | thread           | a patch on the thread entity                           |
      | thread.unsettled                | thread           | a patch on the thread entity                           |
      | thread.unsnoozed                | thread           | a patch on the thread entity                           |
      | thread.visited                  | thread           | a quiet patch on the thread                            |
      | turn-item.updated               | turn-item        | a patch on the turn-item entity                        |

  @node
  Scenario: A re-emitted entity with no change is dropped
    Given the TypeScript server logged the same message twice with identical content
    When the node imports the log
    Then it stores one patch

  @node
  Scenario Outline: Version 1 project events become project entities
    Given the TypeScript server logged <event> for a project
    When the node imports the log
    Then it stores the change on <recorded as>

    Examples: 3 version 1 project events
      | event                | entity  | recorded as        |
      | project.created      | project | the project entity |
      | project.meta-updated | project | the project entity |
      | project.deleted      | project | the project entity |

  @node
  Scenario Outline: Version 1 thread events are imported
    Given the TypeScript server logged <event> as a version 1 thread event
    When the node imports the log
    Then the thread's history includes the change

    Examples: 25 version 1 thread events
      | event                                | entity |
      | thread.created                       | thread |
      | thread.deleted                       | thread |
      | thread.archived                      | thread |
      | thread.unarchived                    | thread |
      | thread.settled                       | thread |
      | thread.unsettled                     | thread |
      | thread.snoozed                       | thread |
      | thread.unsnoozed                     | thread |
      | thread.pinned                        | thread |
      | thread.unpinned                      | thread |
      | thread.pin-reordered                 | thread |
      | thread.meta-updated                  | thread |
      | thread.pull-request-linked           | thread |
      | thread.pull-request-unlinked         | thread |
      | thread.pull-request-synced           | thread |
      | thread.runtime-mode-set              | thread |
      | thread.interaction-mode-set          | thread |
      | thread.message-sent                  | thread |
      | thread.approval-response-requested   | thread |
      | thread.user-input-response-requested | thread |
      | thread.reverted                      | thread |
      | thread.session-set                   | thread |
      | thread.proposed-plan-upserted        | thread |
      | thread.turn-diff-completed           | thread |
      | thread.activity-appended             | thread |

  # Neither server changes a thread for these: they feed only v1 turn rows the v2 migration drops, and their results are later events.
  @node
  Scenario Outline: Version 1 request events are imported through their results
    Given the TypeScript server logged <event> as a version 1 thread event
    When the node imports the log
    Then the imported thread is the same as without it

    Examples: 4 version 1 request events
      | event                              | entity |
      | thread.turn-start-requested        | thread |
      | thread.turn-interrupt-requested    | thread |
      | thread.checkpoint-revert-requested | thread |
      | thread.session-stop-requested      | thread |
