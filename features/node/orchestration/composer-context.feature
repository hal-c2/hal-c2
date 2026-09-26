# Sources:
#   apps/server-ex/lib/hal_c2/composer_context.ex (context links, markers, hal_c2_context envelope,
#     attachment remapping)
#   packages/shared/src/composerContextReferences.ts (the shared format)
#   packages/contracts/src/orchestrationV2.ts (message.dispatch context records)
#   V2 commands: message.dispatch with context; events: message.updated
Feature: Inline context in messages
  A message can reference context inline: a file, a terminal selection, a page
  element, a review comment, another thread. The provider reads each reference
  as a readable marker in place, and every referenced payload once at the end.

  Background:
    Given a node with a project "demo"
    And thread "t1" exists in "demo"

  @node
  Scenario: A message without context links reaches the provider unchanged
    When "Please fix the tests" is sent to "t1"
    Then the provider receives exactly "Please fix the tests"

  @node
  Scenario: A context link becomes a marker and its payload is appended
    When a message referencing mention "src/app.ts" with id "m1" is sent to "t1"
    Then the provider reads the marker "[Mention: src/app.ts; ref=m1]" where the link was
    And the message ends with a hal_c2_context envelope holding the mention's path

  @node
  Scenario: A payload referenced twice is appended once
    When a message links the same context id twice
    Then two markers appear and the envelope holds one entry for that id

  @node
  Scenario: A reference with no payload is marked unavailable
    When a message links context id "gone" and carries no record for it
    Then the envelope marks "gone" as unavailable

  @node
  Scenario: Two records with the same id are ambiguous
    When a message carries two records with id "dup" and links "dup"
    Then neither record is used and "dup" is marked unavailable

  @node
  Scenario Outline: Marker labels are cleaned
    When a message links context with label <label>
    Then the marker label is <cleaned>

    Examples:
      | label                               | cleaned                          |
      | spanning two lines                  | the label on one line            |
      | containing brackets and backslashes | the label with those as spaces   |
      | 300 characters long                 | the first 200 characters         |
      | empty                               | the kind of the context          |

  @node
  Scenario: Malformed links are left as text
    When a message holds a context link with an unknown version or an invalid id
    Then the link is passed through unchanged and nothing is appended

  @node
  Scenario: Captured text cannot close the envelope
    When a terminal selection containing a closing hal_c2_context tag is referenced
    Then the tag is escaped in the payload

  @node
  Scenario Outline: Each kind of context has a readable payload
    When a message references <kind> context
    Then its payload shows <content>

    Examples:
      | kind               | content                                                       |
      | image              | name, type, size and attachment id                            |
      | file               | name, type, size and attachment id                            |
      | terminal           | the terminal label and numbered lines of the selection        |
      | element            | the page element's description                                |
      | preview-annotation | the page, url, comment, requested visual changes and elements |
      | review-comment     | the file, range, section, comment and diff                    |
      | mention            | the path                                                      |
      | skill              | the skill name                                                |
      | thread             | the thread title and id, and how to read it as reference only |

  @node
  Scenario: A context of an unknown kind is passed as data
    When a message references context of a kind the node does not know
    Then its payload is the record's fields as JSON

  @node
  Scenario: Attached files keep pointing at their uploads once claimed
    Given a message references an uploaded image as context
    When the upload is claimed into "t1" under a new id
    Then the context record points at the claimed attachment
