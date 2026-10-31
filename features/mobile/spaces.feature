# Sources:
#   apps/mobile-qt/qml/HalC2/Mobile/MobileShell.qml (the page written from a thread, awaited by the phone's Space screen)
#   apps/mobile-qt/qml/HalC2/Mobile/SpaceScreen.qml (the Space screen's steps, opening the awaited page)
# Pages themselves are specified in features/space/pages.feature. This file covers
# how the phone's one-step-at-a-time Space screen keeps up with a page on its way.

@mobile
Feature: Spaces on a phone
  Writing a page from a thread takes a while, and the user can look around meanwhile.
  The phone opens the written page when it lands, and nothing else in its place.

  Background:
    Given a connected environment with the thread "Work" in the project "shop"
    And the thread "Work" talked about a release plan
    And the Space "Ideas" with the page "Draft"
    And the Space "Research"
    And text generation is available
    And writing a page from a thread takes a while

  Scenario: Browsing Spaces while a page is written opens the written page
    When the user makes a page in "Research" from the thread "Work"
    And the user opens the Space "Ideas"
    Then the Space screen shows the pages of "Ideas"
    When the page from the thread is written
    Then the new page holds the generated summary

  Scenario: A phone unfolded and folded again is back on the page it showed
    When the user opens the page "Draft" of "Ideas"
    And the user unfolds the phone
    And the window narrows to a phone's width
    Then the Space screen shows the page "Draft"

  Scenario: A page that opened in the wide layout is not awaited on the phone
    When the user makes a page in "Research" from the thread "Work"
    And the user unfolds the phone
    And the page from the thread is written
    And the window narrows to a phone's width
    And the user opens the Space "Ideas"
    Then the Space screen shows the pages of "Ideas"
