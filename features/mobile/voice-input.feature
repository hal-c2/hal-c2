# Sources:
#   https://github.com/pingdotgg/t3code/pull/17896
#   https://github.com/pingdotgg/t3code/pull/26096
#   https://github.com/pingdotgg/t3code/pull/31799
#   https://github.com/pingdotgg/t3code/pull/31800
#   https://github.com/pingdotgg/t3code/pull/31801
#   https://github.com/pingdotgg/t3code/pull/31769
#   https://github.com/pingdotgg/t3code/pull/31778 (dropped)
#   https://github.com/pingdotgg/t3code/pull/26734
#   https://github.com/pingdotgg/t3code/pull/31030
#   https://github.com/pingdotgg/t3code/pull/31300
#   apps/mobile/src/features/voice-input/ (on-device dictation states, errors, draft safety)
#   packages/client-runtime/src/voice-input/controller.ts, transcription.ts (where the transcript goes, spacing)
# Composer drafting is specified in features/composer/. Dictating on the phone itself or to a cloud
# provider is phone-only; dictating to an environment is in composer/environment-dictation.feature.
#   https://github.com/pingdotgg/t3code/pull/15502
#   https://github.com/pingdotgg/t3code/pull/28698

@priority-low
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
      | language    | draft          | result                     |
      | English     | "Please\|"     | "Please run the tests"     |
      | English     | "\|now"        | "run the tests now"        |
      | English     | "Please \|now" | "Please run the tests now" |
      | Japanese    | "Please\|"     | "Pleaserun the tests"      |

  # Upstream #31799: dictation spaced words only in English, so Korean and Hindi words ran
  # together; it now follows the recording's language and any script's letters and marks.
  @backlog @mobile
  Scenario Outline: A dictated word is spaced the way its language separates words
    Given the dictation language is <language>
    And the draft is <draft> with the cursor at "|"
    When the user dictates <words>
    Then the draft reads <result>

    Examples:
      | language    | draft        | words    | result            |
      | Korean      | "코드를\|"   | "검토"    | "코드를 검토"       |
      | Hindi       | "नमस्ते\|"    | "दोस्त"    | "नमस्ते दोस्त"        |
      | Japanese    | "コード\|"   | "確認"    | "コード確認"        |
      | Thai        | "สวัสดี\|"    | "ครับ"    | "สวัสดีครับ"         |
      | auto-detect | "Hello\|"    | "world"  | "Hello world"     |
      | auto-detect | "Hello\|"    | "世界"    | "Hello世界"        |

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

  # Upstream #28698: the microphone settings offered permission and input order on a phone where
  # dictation could not run, and the composer had no microphone.
  @backlog @mobile
  Scenario: The microphone settings say why dictation is unavailable
    Given the phone cannot transcribe on the device
    When the user opens the microphone settings
    Then they say dictation is unavailable on this device and why
    And they do not suggest that granting the microphone would turn it on

  # Upstream #31800: on-device dictation followed the app's language, so a phone set to Korean
  # or German first was still transcribed as English.
  @backlog @mobile
  Scenario: On-device dictation follows the phone's preferred languages in order
    Given the phone prefers Korean, then German, and the app is in English
    And the phone cannot transcribe Korean on the device
    When the user dictates
    Then the recording is transcribed as German
    But cancelling or failing the download of the first language's model ends the dictation without trying another language

  # Upstream #31801: the first on-device dictation in a language waited for the speech model
  # before recording, so "one, two, three" came out as "two, three".
  @backlog @mobile
  Scenario: Dictation records at once while the language's model is still being prepared
    Given the phone has not yet prepared its on-device model for the dictation language
    When the user starts dictating and at once says "one, two, three"
    And the user finishes dictating
    Then the transcript waits for the model and reads "one, two, three"
    And cancelling instead discards the recording, and the next dictation does not wait on it

  # Upstream #31769: Settings → Voice → Transcribe with offers OpenAI, Grok and OpenRouter beside
  # the phone; a saved key or a paired client never opts a device into sending audio.
  @backlog @mobile
  Scenario Outline: Cloud dictation is used only on a phone that chose it
    Given the environment has a saved <provider> key
    And this phone has not chosen where to transcribe
    When the user dictates
    Then the recording is transcribed on the phone
    When the user chooses <provider> under "Transcribe with" on this phone
    And the user dictates again
    Then only the finished recording is sent to <provider>
    And other phones keep transcribing where they chose

    Examples:
      | provider   |
      | OpenAI     |
      | Grok       |
      | OpenRouter |

  # Upstream #31769: an unavailable model or unreadable key stops transcription; there is no fallback.
  @backlog @mobile @priority-low
  Scenario: Cloud dictation that cannot reach its provider does not fall back
    Given this phone transcribes with OpenRouter
    And the environment's OpenRouter key cannot be read
    When the user dictates
    Then the user is told transcription could not run and why
    And the recording is not sent to another provider or model

  # Upstream #31778: microphone audio sent to an environment reached through the relay was refused
  # before it was sent. HAL-C2 has no relay; an environment the phone reaches directly can
  # transcribe (composer/environment-dictation.feature).
  @dropped @mobile
  Scenario: Dictation can be transcribed by an environment reached through the relay
    Given the user chose an environment reached through the relay under "Send microphone audio to"
    When the user dictates
    Then that environment transcribes the recording

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

  # Upstream #26734: Android had no dictation; it now uses Google's on-device speech recognition,
  # and every sentence spoken between pauses is kept.
  @backlog @mobile
  Scenario: An Android phone dictates on the device and keeps every sentence across pauses
    Given the user is on an Android phone with on-device speech recognition for their language
    When the user dictates two sentences with a pause between them
    And the user finishes dictating
    Then both sentences are added to the draft, separated as the recognizer separates them

  # Upstream #26734: support is checked again when the app returns, so a model downloaded meanwhile shows the microphone.
  @backlog @mobile
  Scenario: Dictation becomes available once the phone gains on-device recognition
    Given the composer offers no dictation because the phone has no on-device recognition for its language
    When the phone gains it while the app is in the background
    And the user returns to the app
    Then the composer offers dictation

  # Upstream #31030: a regional preference such as Celsius adds an extension to Android's locale
  # ("en-US-u-mu-celsius"), and on-device recognition then reported every language unavailable.
  @backlog @mobile
  Scenario: An Android phone with regional preferences set still dictates on the device
    Given the user is on an Android phone with on-device speech recognition for US English
    And the phone's regional preferences use Celsius and Monday as the first day of the week
    When the user opens the microphone settings
    Then dictation is available
    And the recording is transcribed as US English

  # Upstream #31300: Android fed the recording to the recognizer only after Stop, so a minute of
  # speech took another minute to come out.
  @backlog @mobile
  Scenario: An Android recording is transcribed while the user speaks
    Given the user is on an Android phone with on-device speech recognition for their language
    When the user dictates for a minute and finishes
    Then the transcript is added soon after, without another minute of transcribing
    And no speech from the end of the recording is lost

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

  # Upstream #15502: keep dictation running across navigation
  @backlog @mobile
  Scenario: Dictation keeps running when the user navigates away
    Given the user is dictating into a prompt
    When they leave that screen
    Then recording continues behind a small pill showing the time and its target
    And finishing returns the transcript to the prompt where it began

  # Upstream #17896: choose the microphone order for voice input
  @backlog @mobile
  Scenario: Dictation records from the first connected microphone in the user's order
    Given the user ordered the microphones as the built-in microphone, then Bluetooth
    And Bluetooth earbuds are connected
    When the user starts dictating
    Then the phone's own microphone records

  # Upstream #17896: choose the microphone order for voice input
  @backlog @mobile
  Scenario: A new microphone joins the order just above its kind
    Given the user's microphone order has a row for other Bluetooth microphones
    When dictation first sees the earbuds "Studio Buds"
    Then "Studio Buds" is listed by name just above the Bluetooth row
    And the user can move it anywhere in the order

  # Upstream #26096: a dragged row snapped back on release and its order never saved; the same
  # handle in the environment's route list had the same bug.
  @backlog @mobile
  Scenario: A microphone dragged to a new place keeps it
    When the user drags the Bluetooth row above the built-in microphone
    Then the order is saved with Bluetooth first

  # Upstream #26096: forgetting a device took an Edit mode; it is now a swipe.
  @backlog @mobile @priority-low
  Scenario Outline: The user forgets a microphone by swiping it away
    Given the earbuds "Studio Buds" are in the microphone order
    When the user <does>
    Then "Studio Buds" is no longer in the order
    And the rows for a kind of microphone cannot be forgotten

    Examples:
      | does                                         |
      | swipes "Studio Buds" left and chooses Forget |
      | uses the Forget accessibility action         |
