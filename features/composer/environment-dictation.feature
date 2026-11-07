# Sources:
#   https://github.com/pingdotgg/t3code/pull/30625
#   https://github.com/pingdotgg/t3code/pull/30623
#   https://github.com/pingdotgg/t3code/pull/30624
#   https://github.com/pingdotgg/t3code/pull/31059
#   https://github.com/pingdotgg/t3code/pull/32045
#   https://github.com/pingdotgg/t3code/pull/32197
#   https://github.com/pingdotgg/t3code/pull/32035
#   mobile/voice-input.feature (dictating on the phone itself, and to a cloud provider)
# #30625 builds on #14882 by UtkarshUsername (native inference and model discovery).

@priority-low
Feature: Dictating to an environment
  An environment can transcribe speech on its own machine. A device sends it audio only after the
  user chose that environment on that device; pairing, a microphone permission or a saved model
  never does.

  # Upstream #30625: an environment gets its own transcription engine, run by a bounded, cancellable
  # worker; only clients allowed to operate the environment may use it.
  @backlog @mc
  Scenario: An environment transcribes a recording for a client that may operate it
    Given the environment "Build box" has a transcription model installed
    When a client that may operate "Build box" sends it a finished recording
    Then "Build box" returns the transcript
    And a client that may only read "Build box" is refused

  # Upstream #30625: streaming audio is transcribed as it arrives.
  @backlog @mc
  Scenario: An environment transcribes audio while it is still being recorded
    Given the environment "Build box" has a streaming transcription model installed
    When a client streams a recording to "Build box"
    Then "Build box" returns the text as it is recognised
    And cancelling the stream stops the transcription and keeps nothing of it

  # Upstream #30625: models are pinned by digest; changing models needs settings-write access.
  @backlog @mc
  Scenario: Installing a transcription model checks it and needs settings access
    When a client that may change the settings of "Build box" installs a transcription model
    Then "Build box" downloads it and checks it against its pinned digest
    And a download that does not match is discarded
    And a client that may not change the settings of "Build box" cannot install or switch models

  # Upstream #30625: one speech operation runs at a time; a model download takes the slot.
  @backlog @mc
  Scenario: A recording sent while the environment is busy transcribing says so
    Given "Build box" is downloading a transcription model
    When a client sends "Build box" a recording
    Then the client is told "Build box" is busy

  # Upstream #30625: an automatic GPU choice that fails retries once on the same machine's CPU.
  @backlog @mc
  Scenario: A failed GPU transcription is retried once on the same machine
    Given "Build box" picked its GPU for transcription by itself
    When the GPU fails while transcribing a recording
    Then the recording is transcribed again on the CPU of "Build box"
    And the recording is never sent to another environment

  # Upstream #30625: cleaning up a transcript takes text, never audio.
  @backlog @mc
  Scenario: Cleaning up a transcript sends the environment only its text
    When a client asks "Build box" to clean up a transcript
    Then only the transcript's text is sent

  # Upstream #30623: Settings → Voice starts off on a new device; only naming an environment
  # authorises audio from it.
  @backlog @desktop @priority-high
  Scenario: The desktop sends no audio until the user picks an environment for it
    Given the desktop is paired with "Build box" and has not chosen where to transcribe
    When the user chooses "Build box" under Voice in the settings
    Then dictation in the composer sends its recording to "Build box"

  # Upstream #32197: on a fresh desktop the composer hid its microphone and the dictation shortcut
  # did nothing.
  @backlog @desktop @priority-high
  Scenario Outline: Dictating before choosing where to transcribe opens the choice
    Given the desktop has not chosen where to transcribe
    When the user <starts>
    Then the choice of where to transcribe opens
    And no recording is started and no audio is sent

    Examples:
      | starts                                 |
      | presses the composer's microphone      |
      | uses the dictation keyboard shortcut   |

  # Upstream #32197: choosing Off is an answer, and the editors never leave a draft to suggest setup.
  @backlog @desktop
  Scenario: A desktop that turned dictation off is not asked to set it up
    Given the user chose Off under Voice in the settings
    When the user presses the composer's microphone
    Then the user is not asked where to transcribe
    And dictating into a review comment never leaves the comment to suggest setup

  # Upstream #32035: first-run setup offered an English-only model to someone dictating in German.
  @backlog @desktop
  Scenario Outline: First-run setup recommends a model for the dictation language
    Given the desktop dictates to "Build box", which has no transcription model
    And the Voice language is <language>
    When the user sets up dictation
    Then <offer>

    Examples:
      | language                                     | offer                                                         |
      | German                                       | a model that transcribes German is recommended                |
      | Auto-detect, with the system set to German   | a model that transcribes German is recommended                |
      | a language no listed model transcribes       | the user is sent to Voice settings and nothing is downloaded  |

  # Upstream #32035: a model that names German "de-DE" refused "de".
  @backlog @mc
  Scenario: An environment transcribes in the language spelling its model expects
    Given "Build box" has a model that lists German as "de-DE"
    When a client dictates to "Build box" in German
    Then the recording is transcribed in German

  # Upstream #30623: going offline never picks another host.
  @backlog @desktop @mobile @priority-high
  Scenario: Dictation does not move to another environment when the chosen one is gone
    Given this device dictates to "Build box"
    And "Mac mini" can transcribe too
    When "Build box" disconnects
    Then dictation on this device is unavailable and says "Build box" cannot be reached
    And no recording is sent to "Mac mini"

  # Upstream #30623: revoking or changing the choice discards what is pending, even if the same
  # environment is chosen again.
  # Upstream #31059: the phone discards it the same way.
  @backlog @desktop @mobile
  Scenario Outline: <Change> the dictation environment drops what was waiting to go
    Given this device dictates to "Build box"
    And a recording is waiting to be retried
    When the user <changes> under Voice in the settings
    Then the waiting recording is discarded and never sent

    Examples:
      | Change      | changes                                               |
      | Turning off | turns dictation to an environment off                 |
      | Changing    | chooses "Mac mini"                                    |
      | Re-choosing | switches to the phone, then chooses "Build box" again |

  # Upstream #30623: cleanup is its own choice, off by default, and names where the text goes.
  @backlog @desktop @mobile
  Scenario: Cleaning up dictated text is a separate choice that names its recipient
    Given this device dictates to "Build box"
    Then cleaning up dictated text is off
    When the user turns cleanup on
    Then the settings say the transcript's text goes to "Build box"
    And a transcript the environment cannot clean up is kept as it was said

  # Upstream #30623: the inline comment and review editors use the same choice as the composer.
  @backlog @desktop
  Scenario Outline: Dictating into <editor> goes where the composer's dictation goes
    Given this device dictates to "Build box"
    When the user dictates into <editor>
    Then the recording is sent to "Build box"

    Examples:
      | editor               |
      | an inline comment    |
      | a review comment     |
      | a preview annotation |

  # Upstream #30624: the annotation editor lives inside someone else's page; the page itself
  # never gets the microphone or the connection to the environment.
  @backlog @desktop
  Scenario: A page being annotated never reaches the microphone
    Given the user is annotating a page in the preview
    Then the annotation editor offers dictation only when this device has chosen an environment
    And the page cannot start a recording or read what is transcribed

  # Upstream #31059: the phone keeps "This device" as the default; the confirmation names the host.
  @backlog @mobile @priority-high
  Scenario: The phone dictates to an environment only after the user confirms it
    Given the phone cannot transcribe on the device
    And the phone is paired with "Build box"
    When the user chooses "Build box" under Voice in the settings
    Then the user is asked to confirm that recordings go to "Build box"
    When the user confirms
    Then each finished recording is sent to "Build box" over its connection
    And another phone paired with "Build box" still transcribes where it chose

  # Upstream #31059: picking an environment did not check it had a model, so the first recording failed.
  @backlog @mobile
  Scenario: An environment with no transcription model says so before it is chosen
    Given "Build box" has no transcription model installed
    When the user opens Voice in the settings
    Then the row for "Build box" says it has no model installed

  # Upstream #31059: the chosen environment's model opens its full catalog.
  @backlog @mobile
  Scenario: The phone downloads or switches the chosen environment's model
    Given this phone dictates to "Build box"
    When the user opens the transcription model of "Build box"
    Then the user can search its models by accuracy, speed, languages and size
    And download one, following its progress or cancelling it
    And make an installed one the model "Build box" uses

  # Upstream #32045: finding the smallest, fastest or most accurate model meant reading the list.
  @backlog @desktop
  Scenario Outline: The desktop sorts an environment's transcription models by <order>
    Given this desktop dictates to "Build box"
    When the user sorts the models of "Build box" by <order>
    Then <first> is listed first
    And models with no benchmark are listed last
    And the model "Build box" uses does not change

    Examples:
      | order                         | first                                    |
      | download size                 | the smallest model                       |
      | speed                         | the fastest model                        |
      | accuracy in German            | the model with the lowest German errors  |

  # Upstream #32045: "Downloaded only" combines with search and the language filter, and keeps the
  # transcript of a model test.
  @backlog @desktop @priority-low
  Scenario: Showing only downloaded models keeps the model test's transcript
    Given the user tested a model and its transcript is shown
    When the user shows only downloaded models that match "nemo"
    Then only downloaded models whose name matches "nemo" are listed
    And the test's transcript is still shown

  # Upstream #31059
  @backlog @mobile
  Scenario: A phone that may not change an environment's settings sees its models read only
    Given this phone dictates to "Build box" but may not change its settings
    When the user opens the transcription model of "Build box"
    Then the models are listed without a way to download or switch them
