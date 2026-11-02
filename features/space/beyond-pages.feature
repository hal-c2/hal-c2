# Sources:
#   https://chatgpt.com/features/space/ (Slack)
#   spaces-feature-bdd-tests branch, features/space/ (the prototype; read for ideas only):
#     slides-sites-and-images.feature (sites and images),
#     living-pages-and-visualizations.feature, collaboration-agents-and-dots.feature

@backlog
Feature: Spaces beyond Pages
  Pages are the first part of Spaces. These are the parts still to come. Sites and
  slides have their own files, `sites.feature` and `slides.feature`.

  @mc @shared
  Scenario: A Space talks to a Slack channel
    Given the Space "Research" is connected to a Slack channel
    When someone asks about "Roadmap" in that channel
    Then the answer cites the page "Roadmap"

  @mc @shared
  Scenario: The user asks an agent from inside a page
    When the user asks "@agent tidy this page" on the page "Roadmap"
    Then an agent edits "Roadmap" and its edits name its thread

  @mc @shared
  Scenario: A Space is shared across the cluster
    Given a cluster of two MCs
    When the user opens the Space "Research" from the other MC
    Then its pages are the same on both
