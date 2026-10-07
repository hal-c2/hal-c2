# Sources:
#   packages/contracts/src/plugin.ts (PluginManifest, PluginEntry, PLUGIN_METHODS, the plugins and plugin shapes)
#   apps/server-ex/lib/hal_c2/plugins.ex (packages, manifest, permissions, plugins.call, plugins.file)
#   apps/server-ex/lib/hal_c2/plugins/kinds.ex (HalC2.Plugins.Extension)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (the host API a plugin calls, gated by its granted permissions)
#   docs/user/plugins.md (plugin packages)
#   plugins/code-review/plugin.json (the first package)

Feature: Plugin packages
  A plugin package is a directory that can live anywhere: a manifest that says what the
  plugin is, what it asks for and what it adds, an optional MC part, optional UI parts,
  and its assets. The MC it is installed on runs the MC part and serves the UI parts to
  every client of that environment, so the two halves always come from the same version.

  Background:
    Given an MC with a plugins directory

  @mc
  Scenario: A package directory is listed with what its manifest says about it
    Given the plugins directory contains the package "code-review" with a name, description, author, icon and two screenshots
    When the MC starts
    Then "code-review" is listed with its name, description, author and version
    And its icon and screenshots can be fetched from the MC

  @mc
  Scenario: A package whose manifest does not parse is listed with the reason
    Given the plugins directory contains the package "broken" whose manifest is not valid JSON
    When the MC starts
    Then "broken" is listed with an error naming its manifest
    And the MC is ready

  @mc
  Scenario: A package whose manifest names another id is refused
    Given the plugins directory contains the directory "reviews" whose manifest says its id is "code-review"
    When the MC starts
    Then "reviews" is listed with an error saying the directory and the id differ

  @mc
  Scenario: A package whose choice setting has options HAL-C2 cannot read is listed with the reason
    Given the plugins directory contains the package "broken" whose choice setting lists bare strings as options
    When the MC starts
    Then "broken" is listed with an error naming its setting

  @mc
  Scenario Outline: A package whose setting has a default it cannot take is listed with the reason
    Given the plugins directory contains the package "broken" whose setting is <setting>
    When the MC starts
    Then "broken" is listed with an error naming its setting

    Examples:
      | setting                                        |
      | on or off, with the default "yes"              |
      | a choice whose default is turned off           |
      | a choice whose default is not one of its options |

  @mc
  Scenario Outline: A package whose manifest has a part of the wrong shape is listed with the reason
    Given the plugins directory contains the package "broken" whose manifest has "<part>"
    When the MC starts
    Then "broken" is listed with an error naming "<where>"
    And the MC is ready

    Examples:
      | part                             | where                      |
      | screenshots that are an object   | screenshots                |
      | a page without a title           | contributes.pages[0].title |
      | an author that is only a name    | author                     |
      | a setting that is not an object  | settings[0]                |
      | a permission without a reason    | permissions[0].reason      |

  @mc
  Scenario: A package that needs a newer plugin API asks for an MC update
    Given the plugins directory contains the package "future" built for a newer plugin API
    When the user tries to enable "future"
    Then the user is told to update the MC first

  @mc
  Scenario: A package with only UI parts runs without MC code
    Given the plugins directory contains the package "clock" with a UI part and no MC part
    When the user enables "clock"
    Then "clock" is running
    And its UI part is offered to clients

  @mc
  Scenario: The MC serves the UI parts of the plugins that are running
    Given the package "code-review" is enabled
    When a client asks for the UI parts of "code-review"
    Then it gets each QML file of the package with the package's version
    And files outside the package's directory cannot be asked for

  @mc
  Scenario: Changing any file of a package, hidden ones too, gives it a new revision
    Given the package "code-review" is enabled
    When a hidden file of "code-review" changes and the MC rescans
    Then "code-review" has a new revision

  @mc
  Scenario Outline: A new version that fails to load part way keeps all of the old version running
    Given the package "code-review" is enabled
    When a new version of "code-review" <which> is placed in the plugins directory
    Then "code-review" answers as its old version
    And the reload is reported as failed because of "<reason>"

    Examples:
      | which                                  | reason                       |
      | whose second MC file does not compile  | undefined function           |
      | whose MC files hold two plugin modules | more than one plugin module  |

  @mc
  Scenario: A disabled package does not serve its UI parts
    Given the package "code-review" is disabled
    When a client asks for the UI parts of "code-review"
    Then the request is refused because the plugin is not running

  @mc
  Scenario: Clients see the plugin list change as it happens
    Given a client watches the plugin list
    When the user enables "code-review" accepting its permissions
    Then the client is told that "code-review" is running

  @mc
  Scenario: The settings a package declares have types and defaults
    Given the package "code-review" declares a choice, a list, a switch, a long text and a secret
    When the user opens its settings without having saved any
    Then each field shows its declared default
    And the secret shows only whether it is set

  @mc
  Scenario: A settings value of the wrong type is refused
    Given the package "code-review" declares the switch "skipDrafts"
    When the user saves the text "sometimes" for "skipDrafts"
    Then the save is refused naming "skipDrafts"
    And the previous settings are kept

  Rule: A package says what it needs, and gets nothing more

    @mc
    Scenario: The permissions a package asks for are listed before it is enabled
      Given the package "code-review" asks to read pull requests, write pull request reviews and start threads
      When the user lists the plugins
      Then "code-review" shows each permission with the reason it gives
      And none of them is granted

    @mc
    Scenario: Enabling a package grants the permissions the user accepted
      When the user enables "code-review" accepting its permissions
      Then "code-review" is running with those permissions granted

    @mc
    Scenario: Enabling a package without accepting its permissions is refused
      When the user enables "code-review" without accepting its permissions
      Then the MC refuses saying which permissions need approval
      And "code-review" stays disabled

    @mc
    Scenario: A plugin cannot use an MC capability it was not granted
      Given the package "quiet" was granted only to read pull requests
      When "quiet" tries to start a thread
      Then the MC refuses the call naming the missing permission
      And the refusal is recorded on "quiet"

    @mc
    Scenario: An update that asks for more permissions waits for the user
      Given "code-review" is running with read access to pull requests
      When a version that also asks to write pull request reviews replaces it
      Then "code-review" is stopped and listed as waiting for approval of the new permission
      And it runs again once the user accepts it

    @mc
    Scenario: An update that drops a permission gives it up
      Given "code-review" is running with read and write access to pull requests
      When a version that only asks to read pull requests replaces it
      Then "code-review" can no longer write pull request reviews
      And a later version that asks to write them again waits for the user

    @mc
    Scenario: The consent says that an MC part is trusted code
      Given the package "code-review" has an MC part
      When the user lists the plugins
      Then "code-review" is marked as running code with the MC's own access

  Rule: A running plugin talks to its own UI

    @mc
    Scenario: A plugin answers requests from its UI
      Given the package "code-review" is running
      When its UI asks it for "reviews.list"
      Then the plugin's answer reaches the UI

    @mc
    Scenario: A request to a plugin that is not running is refused
      Given the package "code-review" is disabled
      When its UI asks it for "reviews.list"
      Then the request is refused because the plugin is not running

    @mc
    Scenario: A plugin that raises while answering does not take the MC down
      Given the package "code-review" raises while answering "reviews.list"
      When its UI asks it for "reviews.list"
      Then the UI gets the plugin's error
      And the MC keeps serving other requests

    @mc
    Scenario: A plugin pushes its state to every client watching it
      Given two clients watch the "reviews" topic of "code-review"
      When "code-review" publishes a new list of reviews
      Then both clients get the new list

    @mc
    Scenario: A client that starts watching gets the last state at once
      Given "code-review" published a list of reviews
      When a client starts watching the "reviews" topic of "code-review"
      Then it gets that list without waiting for the next change

    @mc
    Scenario: A plugin keeps its own data across MC restarts
      Given "code-review" saved a record in its data directory
      When the MC restarts
      Then "code-review" reads the same record back

  Rule: Threads a plugin starts are its threads

    @mc
    Scenario: A thread started by a plugin carries the plugin and the kind of thread
      Given "code-review" is running with permission to start threads
      When "code-review" starts a "review" thread in a project
      Then the thread is marked as a "review" thread of "code-review"
      And it was created by the system on behalf of a plugin

    @mc
    Scenario: A plugin is told when one of its threads finishes a turn
      Given "code-review" started a "review" thread
      When the turn in that thread finishes
      Then "code-review" is told the thread and how the turn ended

    @mc
    Scenario: A plugin's threads stay ordinary threads when the plugin is gone
      Given "code-review" started a "review" thread
      When "code-review" is removed
      Then the thread can still be opened, read and continued

    @mc
    Scenario: A plugin can keep its threads out of the thread list
      When "code-review" starts a "review" thread that is not listed
      Then the thread is marked as not listed
      And it can still be opened by its id

  @backlog @mc
  Scenario: A package can be installed from an archive URL
    When the user installs a package from the URL of a ".tar.gz" archive and confirms
    Then the archive is unpacked into the plugins directory
    And the package is listed as disabled with that URL as its source

  @backlog @mc
  Scenario: Removing a package keeps its data until the user asks to delete it
    Given "code-review" has saved data
    When the user removes "code-review"
    Then its directory is gone
    And its data is kept unless the user chose to delete it too
