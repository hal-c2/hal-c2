# Sources:
#   features/space/beyond-pages.feature (the entry this file replaces)
#   https://chatgpt.com/features/space/ (sites)
#   spaces-feature-bdd-tests branch, features/space/slides-sites-and-images.feature
#     (the prototype; read for ideas only)
#   packages/contracts/src/space.ts (space.page.publish, space.page.unpublish)
#   apps/server-ex/lib/hal_c2/space/sites.ex
#   apps/server-ex/lib/hal_c2/web.ex (the address a link is made from, as for pairing links)

Feature: A page published as a site
  The user publishes a page and gets a link. Anyone who can reach the MC's address opens
  the link in an ordinary browser and reads the page as a plain HTML page, without pairing
  or signing in. The site is a snapshot taken at publish time and the MC serves it itself.
  The token in the link is the only access control and reaches that one page and nothing
  else on the MC.

  Background:
    Given a connected environment
    And the Space "Research"
    And the page "Roadmap" reads "Ship pages"

  Rule: Publishing, and the way back

    @mc @desktop @mobile @tui
    Scenario: The user publishes a page and sees that it is published
      When the user publishes the page "Roadmap" as a site
      Then the page "Roadmap" shows it is published with a link

    @desktop @mobile @tui
    Scenario: The user copies the link of a published page
      Given the page "Roadmap" is published as a site
      When the user copies the site link of the page "Roadmap"
      Then the site link of the page "Roadmap" is on the clipboard

    @mc
    Scenario: Anyone with the link reads the page without signing in
      Given the page "Roadmap" is published as a site
      When a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser reads "Roadmap" and "Ship pages"

    @mc @desktop @mobile @tui
    Scenario: The user unpublishes a page and the link stops working
      Given the page "Roadmap" is published as a site
      When the user unpublishes the page "Roadmap"
      Then the page "Roadmap" shows it is not published
      And the site link of the page "Roadmap" no longer opens

    @mc
    Scenario: Unpublishing a page that is not published changes nothing
      When the user unpublishes the page "Roadmap"
      Then the page "Roadmap" shows it is not published

    @mc
    Scenario: Publishing again after unpublishing makes a new link
      Given the page "Roadmap" is published as a site
      And the user unpublishes the page "Roadmap"
      When the user publishes the page "Roadmap" as a site
      Then the page "Roadmap" has a different site link
      And the earlier site link no longer opens

    @mc @desktop @mobile @tui
    Scenario: A page in the trash cannot be published
      Given the page "Roadmap" is in the trash
      When the user publishes the page "Roadmap" as a site
      Then the page request is refused

    @mc @desktop @mobile @tui
    Scenario: Every client watching the Space sees the page published
      Given a second client watching the Space "Research"
      When the user publishes the page "Roadmap" as a site
      Then the second client sees the page "Roadmap" published

  Rule: The site is a snapshot

    @mc
    Scenario: Later edits stay private until the user publishes again
      Given the page "Roadmap" is published as a site
      When the user writes "Secret plans" on the page "Roadmap"
      And a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser reads "Ship pages"
      And the browser does not read "Secret plans"

    @mc @desktop @mobile @tui
    Scenario: The page shows when its site is behind
      Given the page "Roadmap" is published as a site
      When the user writes "Secret plans" on the page "Roadmap"
      Then the page "Roadmap" shows its site is behind

    @mc @desktop @mobile @tui
    Scenario: Publishing again updates the site and keeps the link
      Given the page "Roadmap" is published as a site
      And the user writes "Secret plans" on the page "Roadmap"
      When the user publishes the page "Roadmap" as a site
      Then the page "Roadmap" shows its site is up to date
      And the page "Roadmap" has the same site link

    @mc
    Scenario: Published again, the link reads the new text
      Given the page "Roadmap" is published as a site
      And the user writes "Now public" on the page "Roadmap"
      When the user publishes the page "Roadmap" as a site
      And a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser reads "Now public"

    @mc
    Scenario: Renaming the page puts its site behind
      Given the page "Roadmap" is published as a site
      When the user renames the page "Roadmap" to "Plans"
      Then the page "Plans" shows its site is behind

    @mc
    Scenario: A comment does not put the site behind and is never published
      Given the page "Roadmap" is published as a site
      When the user comments "Private note" on the block "Ship pages"
      Then the page "Roadmap" shows its site is up to date
      When the user publishes the page "Roadmap" as a site
      And a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser does not read "Private note"

  Rule: The trash takes a site down

    @mc @desktop @mobile @tui
    Scenario: Trashing a page takes its site down
      Given the page "Roadmap" is published as a site
      When the user moves the page "Roadmap" to the trash
      Then the page "Roadmap" shows it is not published
      And the site link of the page "Roadmap" no longer opens

    @mc @desktop @mobile @tui
    Scenario: Restoring a page from the trash does not publish it again
      Given the page "Roadmap" is published as a site
      And the user moves the page "Roadmap" to the trash
      When the user restores the page "Roadmap"
      Then the page "Roadmap" shows it is not published
      And the site link of the page "Roadmap" no longer opens

    @mc
    Scenario: Trashing a page takes down the sites of the pages inside it
      Given the page "Milestones" inside "Roadmap"
      And the page "Milestones" is published as a site
      When the user moves the page "Roadmap" to the trash
      Then the page "Milestones" shows it is not published
      And the site link of the page "Milestones" no longer opens

    @mc
    Scenario: Deleting a page for good takes its site down
      Given the page "Roadmap" is published as a site
      And the user moves the page "Roadmap" to the trash
      When the user deletes the page "Roadmap" for good
      Then the site link of the page "Roadmap" no longer opens

  Rule: The link reaches one page and nothing else

    @mc
    Scenario: A site shows only its own page
      Given the page "Budget" reads "Quarterly numbers"
      And the page "Roadmap" is published as a site
      When a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser does not read "Quarterly numbers"

    @mc
    Scenario: A page that is not published looks like any other unknown address
      When a browser with no pairing opens a made-up site link in the Space
      Then the browser is answered as for an address the MC does not have

    @mc
    Scenario: A site token opens no authenticated route
      Given the page "Roadmap" is published as a site
      When the site token of the page "Roadmap" is used as a credential
      Then the MC refuses it on its HTTP routes and its socket

    @mc
    Scenario: A site link cannot be aimed at another Space
      Given the page "Roadmap" is published as a site
      And the Space "Elsewhere"
      When a browser with no pairing opens the site token of the page "Roadmap" under "Elsewhere"
      Then the browser is answered as for an address the MC does not have

    @mc
    Scenario: Publishing needs a session that may change the Space
      Given a session that may only read
      When that session publishes the page "Roadmap" as a site
      Then that session is refused for lack of access

    @mc
    Scenario: Publishing over Tailscale needs the right to open the MC to the tailnet
      Given a session that may change the Space but not access
      When that session publishes the page "Roadmap" over Tailscale
      Then that session is refused for lack of access

  Rule: The page is a plain, safe document

    @mc
    Scenario: All page text is escaped
      Given the page "<script>alert(1)</script>" reads "<img src=x onerror=alert(2)>"
      And the page "<script>alert(1)</script>" is published as a site
      When a browser with no pairing opens the site link of the page "<script>alert(1)</script>"
      Then the document has no tags from the page text
      And the browser reads "<img src=x onerror=alert(2)>" as text

    @mc
    Scenario: The response locks the document down
      Given the page "Roadmap" is published as a site
      When a browser with no pairing opens the site link of the page "Roadmap"
      Then the response has a policy that runs no scripts and loads nothing
      And the response is not cached, sends no referrer and allows no other origin

    @mc
    Scenario: Every kind of block reads as plain HTML
      Given the page "Roadmap" also has a heading "Next", a callout "Careful" and a ticked item "Done"
      And the page "Roadmap" is published as a site
      When a browser with no pairing opens the site link of the page "Roadmap"
      Then the document has a heading "Next", a note "Careful" and a ticked item "Done"

    @mc
    Scenario: Lists, alerts and dividers read as plain HTML
      Given the page "Plan" imported from:
        """
        # Plan

        1. Tag
           - [x] Notes
        2. Ship

        ---

        > [!WARNING]
        > Not on Friday.
        """
      And the page "Plan" is published as a site
      When a browser with no pairing opens the site link of the page "Plan"
      Then the document holds each line of:
        """
        <li>1. Tag</li>
        <li class="d1">☑ Notes</li>
        <li>2. Ship</li>
        <hr>
        <aside><strong>Warning</strong>
        """

    @mc
    Scenario: A link to another page renders as plain text
      Given the page "Milestones" inside "Roadmap"
      And the user links "Milestones" from "Roadmap"
      And the page "Roadmap" is published as a site
      When a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser reads "Milestones"
      And the document has no links

    @mc
    Scenario: A link to a page in the trash is left out of the site
      Given the page "Milestones" inside "Roadmap"
      And the user links "Milestones" from "Roadmap"
      And the page "Milestones" is in the trash
      And the page "Roadmap" is published as a site
      When a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser does not read "Milestones"

  Rule: The link names an address others can reach

    @mc
    Scenario: A client that reached the MC on the LAN gets a link on that address
      When a client that reached the MC at "http://192.168.1.20:3773" publishes the page "Roadmap"
      Then the site link of the page "Roadmap" starts with "http://192.168.1.20:3773/sites/"
      And the link is not marked as only for this machine

    @mc @desktop @mobile @tui
    Scenario: A link only this machine can open says so
      Given the MC listens only on this machine
      When the user publishes the page "Roadmap" as a site
      Then the page "Roadmap" says only this machine can open its site link

    @mc
    Scenario: An MC listening on every interface makes the link on a network address
      Given the MC listens on every network interface
      When the user publishes the page "Roadmap" as a site
      Then the link names one of the machine's non-loopback addresses

    @mc @desktop @mobile @tui
    Scenario: The user publishes over Tailscale
      Given Tailscale names the MC's machine "mc.tail1234.ts.net"
      When the user publishes the page "Roadmap" over Tailscale
      Then the site link of the page "Roadmap" starts with "https://mc.tail1234.ts.net"

    @mc
    Scenario: Tailscale cannot publish the site
      Given Tailscale is not running on the MC's machine
      When the user publishes the page "Roadmap" over Tailscale
      Then the page request is refused
      And the page "Roadmap" shows it is not published

    @mc
    Scenario: Publishing again from this machine keeps the address others can reach
      Given a client that reached the MC at "http://192.168.1.20:3773" publishes the page "Roadmap"
      When the user publishes the page "Roadmap" as a site
      Then the site link of the page "Roadmap" starts with "http://192.168.1.20:3773/sites/"

    @mc
    Scenario: Publishing again from the network keeps a link on the tailnet
      Given Tailscale names the MC's machine "mc.tail1234.ts.net"
      And the user publishes the page "Roadmap" over Tailscale
      When a client that reached the MC at "http://192.168.1.20:3773" publishes the page "Roadmap"
      Then the site link of the page "Roadmap" starts with "https://mc.tail1234.ts.net/sites/"

    @mc
    Scenario: Publishing over Tailscale moves a link others could already open
      Given Tailscale names the MC's machine "mc.tail1234.ts.net"
      And a client that reached the MC at "http://192.168.1.20:3773" publishes the page "Roadmap"
      When the user publishes the page "Roadmap" over Tailscale
      Then the site link of the page "Roadmap" starts with "https://mc.tail1234.ts.net/sites/"

    @mc
    Scenario: An image on a published page shows as its caption
      Given the image "cat.png" in "Research"
      And the user places the image "cat.png" on "Roadmap"
      When the user publishes the page "Roadmap" as a site
      And a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser reads "cat.png"

    @mc
    Scenario: A chart on a published page shows as its words
      Given the page "Roadmap" has a chart of "May" 3
      When the user publishes the page "Roadmap" as a site
      And a browser with no pairing opens the site link of the page "Roadmap"
      Then the browser reads "a chart"

  # Out of scope for the first version of sites.
  @backlog @mc @shared
  Scenario: A published page reads from a database
    Given the page "Roadmap" shows a database of tasks
    When the user publishes the page "Roadmap" as a site
    Then the site shows the database as it was at that moment

  @backlog @mc @shared
  Scenario: A site asks its readers to sign in
    Given the page "Roadmap" is published as a site for signed-in readers
    When a browser with no sign-in opens the site link of the page "Roadmap"
    Then the browser is asked to sign in

  @backlog @mc @shared
  Scenario: A site spans several pages
    When the user publishes the page "Roadmap" and the pages inside it as one site
    Then the site's links between those pages work

  @backlog @mc @shared
  Scenario: A site has its own domain
    When the user gives the site of the page "Roadmap" the domain "roadmap.example.com"
    Then the browser reaches the site at that domain

  @backlog @mc @shared
  Scenario: The user publishes a slide deck
    When the user publishes the deck "Kickoff" as a site
    Then the browser steps through the slides

  @backlog @mc @shared
  Scenario: A site shows the page's images
    Given the page "Roadmap" has an image
    When the user publishes the page "Roadmap" as a site
    Then the browser shows the image

  @backlog @mc @shared
  Scenario: A site is hosted outside the MC
    When the user publishes the page "Roadmap" to an outside host
    Then the site stays up while the MC is off

  @backlog @mc
  Scenario: An agent publishes a page through a tool
    When an agent publishes the page "Roadmap" with a tool
    Then the user sees the page published and can unpublish it
