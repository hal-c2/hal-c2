# Sources:
#   apps/mobile/src/features/voice-input/ (on-device dictation states, errors, draft safety)
#   packages/client-runtime/src/voice-input/controller.ts, transcription.ts (where the transcript goes, spacing)
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

  # Legacy: packages/client-runtime/src/voice-input/controller.ts (resolveTranscriptCommit)
  @backlog @mobile
  Scenario: Dictation replaces the text that was selected
    Given the user has typed "Please fix it" with "fix" selected
    When the user dictates "run the tests"
    Then the draft reads "Please run the tests it"

  # Legacy: packages/client-runtime/src/voice-input/controller.ts (resolveTranscriptCommit)
  @backlog @mobile
  Scenario: The cursor ends after the dictated text
    Given the user has typed "Please" with the cursor at the end
    When the user dictates "run the tests"
    Then the cursor is after "tests" in the draft

  # Legacy: packages/client-runtime/src/voice-input/controller.ts (usesEnglishSpacing)
  @backlog @mobile
  Scenario Outline: Spaces are added around a dictated English phrase only where words would run together
    Given the phone's language is <language>
    And the draft is <draft> with the cursor at "|"
    When the user dictates "run the tests"
    Then the draft reads <result>

    Examples:
      | language   | draft            | result                |
      | English    | "Please|"        | "Please run the tests" |
      | English    | "|now"           | "run the tests now"   |
      | English    | "Please |now"    | "Please run the tests now" |
      | another one | "Please|"       | "Pleaserun the tests" |

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

  @backlog @mobile
  Scenario: Finishing is not offered until recording has begun
    Given dictation is still preparing
    Then the user sees that dictation is preparing
    And finishing dictation is not available yet
    But cancelling dictation is

  @backlog @mobile
  Scenario: The draft cannot be edited or sent while dictation is in progress
    Given the user is dictating
    Then the draft cannot be edited
    And the message cannot be sent
    When the user cancels dictation
    Then the draft can be edited and sent again

  @backlog @mobile
  Scenario: A recording stops by itself after five minutes
    Given the user has been dictating for five minutes
    Then the recording stops
    And what was said is transcribed into the draft

  @backlog @mobile
  Scenario: Leaving the app while recording discards the recording
    Given the user is dictating
    When the user switches to another app
    Then the recording is discarded
    And the user is told the recording was interrupted
    And the draft is unchanged

  @backlog @mobile
  Scenario: A phone call during a recording discards it
    Given the user is dictating
    When the phone takes a call
    Then the recording is discarded
    And the user is told the recording was interrupted
    And the draft is unchanged

  @backlog @mobile
  Scenario: Opening another thread cancels dictation
    Given the user is dictating in "Fix checkout"
    When the user opens another thread
    Then dictation is cancelled
    And the draft of "Fix checkout" is unchanged

  @backlog @mobile
  Scenario: Leaving the screen stops dictation
    Given the user is dictating
    When the user leaves the thread screen
    Then the recording is discarded and the microphone is released

  @backlog @mobile
  Scenario: A recording with no speech says so
    Given the user dictated without saying anything
    Then the user is told no speech was detected
    And the draft is unchanged
    And the user can try again

  @backlog @mobile
  Scenario: A transcript for a draft that changed is not added and says so
    Given the draft changed while the recording was being transcribed
    Then the user is told the draft changed and the transcript was not added
    And the user can try again

  @backlog @mobile
  Scenario: Dictation can be cancelled while it is being transcribed
    Given the recording is being transcribed
    When the user cancels dictation
    Then the transcript is not added to the draft

  @backlog @mobile
  Scenario: Starting again while the last transcription is finishing asks to wait
    Given the previous recording is still being transcribed in the background
    When the user starts dictating
    Then the user is told transcription is still finishing and to try again shortly

  @backlog @mobile
  Scenario: Only one recording runs at a time
    Given a recording is already active in another composer
    When the user starts dictating
    Then the user is told another voice recording is already active

  @backlog @mobile
  Scenario: Dictation cannot start while the composer is unavailable
    Given the composer is unavailable
    When the user tries to start dictating
    Then nothing is recorded

  @backlog @mobile
  Scenario: A dictation error can be dismissed
    Given dictation failed and shows its error
    When the user dismisses the error
    Then the error is gone
    And dictation can be started again

  @backlog @mobile
  Scenario: A phone known up front to have no on-device transcription offers no dictation
    Given the phone already reports no on-device transcription for its language before the composer opens
    Then the composer offers no way to start dictating

  @backlog @mobile
  Scenario: The screen stays awake while recording
    Given the user is dictating
    When the phone would otherwise lock after a while
    Then the screen stays on until dictation ends

  @backlog @mobile
  Scenario: Audio the phone was playing resumes after dictation
    Given music was playing before the user started dictating
    When dictation ends
    Then the music plays again
