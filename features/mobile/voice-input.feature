# Sources:
#   apps/mobile/src/features/voice-input/ (on-device dictation states, errors, draft safety)
# Composer drafting is specified in features/composer/. Dictation is phone-only.

Feature: Dictating a message
  The user can speak a message into the composer. Dictation only ever edits the draft; the
  user always reviews and sends it themselves.

  Background:
    Given the user is in a thread on a phone that supports on-device transcription

  @backlog @mobile
  Scenario: Dictation records and then transcribes into the draft
    When the user starts dictating
    Then the user sees that the phone is recording and for how long
    When the user finishes dictating
    Then the user sees that the recording is being transcribed
    And the transcript is added to the draft

  @backlog @mobile
  Scenario: The recording shows how loudly the user is speaking
    Given the user is dictating
    When the user speaks
    Then the recording level rises and falls with the user's voice

  @backlog @mobile
  Scenario: Dictation never sends the message
    When the user dictates "run the tests"
    Then the draft reads "run the tests"
    And nothing is sent to the agent

  @backlog @mobile
  Scenario: Dictation is inserted where the cursor is
    Given the user has typed "Please now" with the cursor after "Please"
    When the user dictates "run the tests"
    Then the draft reads "Please run the tests now"

  @backlog @mobile
  Scenario: The user cancels dictation
    Given the user is dictating
    When the user cancels dictation
    Then the draft is unchanged

  @backlog @mobile
  Scenario: A transcript that arrives after the user edited the draft does not overwrite it
    Given the user finished dictating and the transcript is still being prepared
    When the user edits the draft
    Then the late transcript does not replace the user's edit

  @backlog @mobile
  Scenario: Leaving the app while dictation is starting cancels it
    Given dictation is still preparing
    When the user switches to another app
    Then dictation is cancelled
    And the draft is unchanged

  @backlog @mobile
  Scenario: Denied microphone access explains how to recover
    Given the user has denied microphone access
    When the user starts dictating
    Then the user is told the microphone is unavailable
    And the user is offered to open the microphone settings

  @backlog @mobile
  Scenario Outline: Dictation explains why it cannot run
    Given <situation>
    When the user starts dictating
    Then the user is told <reason>

    Examples:
      | situation                                              | reason                                   |
      | the phone's language has no on-device transcription    | the language is not supported            |
      | the phone cannot transcribe on the device              | this device does not support dictation   |

  @backlog @mobile
  Scenario: A failed transcription can be retried
    Given transcription failed
    When the user retries
    Then the recording is transcribed again
