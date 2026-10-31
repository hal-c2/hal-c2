# Sources:
#   https://chatgpt.com/features/space/ (slides, sites, images, Slack, scheduled pages, applets)
#   spaces-feature-bdd-tests branch, features/space/ (the prototype; read for ideas only):
#     slides-sites-and-images.feature, self-updating-pages-and-schedules.feature,
#     living-pages-and-visualizations.feature, collaboration-agents-and-dots.feature

@backlog
Feature: Spaces beyond Pages
  Pages are the first part of Spaces. These are the parts still to come.

  @mc @shared
  Scenario: The user makes a slide deck in a Space
    When the user makes a slide deck from the page "Roadmap"
    Then the deck has a slide for each section of the page

  @mc @shared
  Scenario: The user publishes a page as a site
    When the user publishes the page "Roadmap" as a site
    Then the site shows the page as it is now

  @mc @shared
  Scenario: The user keeps images in a Space
    When the user generates an image for the page "Roadmap"
    Then the image is kept in the Space and shown on the page

  @mc @shared
  Scenario: A Space talks to a Slack channel
    Given the Space "Research" is connected to a Slack channel
    When someone asks about "Roadmap" in that channel
    Then the answer cites the page "Roadmap"

  @mc @shared
  Scenario: A page updates itself on a schedule
    Given the page "Status" has the instruction "Summarise yesterday's threads" every morning
    When the morning run finishes
    Then "Status" holds the new summary and says when it was written

  @mc @shared
  Scenario: The user visualises data on a page
    When the user asks for "/visualize weekly turns" on the page "Status"
    Then the page shows an applet drawing that data

  @mc @shared
  Scenario: The user asks an agent from inside a page
    When the user asks "@agent tidy this page" on the page "Roadmap"
    Then an agent edits "Roadmap" and its edits name its thread

  @mc @shared
  Scenario: The user sees who else is on a page
    Given a second client is reading the page "Roadmap"
    Then each client sees the other on the page

  @mc @shared
  Scenario: A Space is shared across the cluster
    Given a cluster of two MCs
    When the user opens the Space "Research" from the other MC
    Then its pages are the same on both

  @mc @shared
  Scenario: The user looks back through a page's history
    Given the page "Roadmap" was edited several times
    When the user opens its history
    Then each earlier version can be read and restored
