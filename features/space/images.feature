# Sources:
#   https://chatgpt.com/features/space/ (images kept in a Space)
#   spaces-feature-bdd-tests branch, features/space/slides-sites-and-images.feature
#     (the prototype: image cards, a creator dialog; read for ideas only)
#   packages/contracts/src/space.ts (space.image.*, the image block)
#   packages/contracts/src/assets.ts (assets.createUrl for a space-image)
#   apps/server-ex/lib/hal_c2/space/images.ex
#   apps/server-ex/lib/hal_c2/space/image_file.ex
#   apps/server-ex/lib/hal_c2/space/image_generation.ex

Feature: Images in a Space
  A Space keeps images: generated from a prompt by a provider the user already has, or
  added from a file. Each can be placed on any number of pages. The Space's stream holds
  only what is known about an image; clients fetch its bytes when they show it. An image
  goes to the trash and comes back like a page, and a page showing an image that left
  says so.

  Background:
    Given a connected environment
    And the Space "Research"

  @mc @desktop @mobile @tui
  Rule: Adding an image from a file

    Scenario: The user adds an image from a file
      When the user adds the image "cat.png" to "Research"
      Then the images of "Research" are "cat.png"

    Scenario: A file that is not really an image is refused
      When the user adds the file "notes.png" holding plain text to "Research"
      Then the image request is refused
      And the images of "Research" are ""

    Scenario: A client watching the Space sees a new image
      Given a second client watching the Space "Research"
      When the user adds the image "cat.png" to "Research"
      Then the second client sees the image "cat.png"

  @mc
  Rule: What the MC accepts

    Scenario Outline: The content of the file decides, not its name
      When the user adds a <content> file called "picture.png" to "Research"
      Then the images of "Research" are "picture.png"
      And the image "picture.png" is a <type>

      Examples:
        | content | type       |
        | PNG     | image/png  |
        | JPEG    | image/jpeg |
        | GIF     | image/gif  |
        | WebP    | image/webp |

    Scenario Outline: What is not a safe image is refused and not kept
      When the user adds <what> to "Research"
      Then the image request is refused
      And the images of "Research" are ""
      And no image file is left behind

      Examples:
        | what                                |
        | an SVG file                         |
        | a PNG with a broken header          |
        | a PNG claiming to be 20000 by 20000 |

    Scenario: A file over the limit cannot be uploaded
      When the user asks to upload an image of 11 MB
      Then the upload is refused

    Scenario: An upload is only taken once
      Given the image "cat.png" in "Research"
      When the user adds the same upload again
      Then the image request is refused
      And the images of "Research" are "cat.png"

    Scenario: Images survive a restart
      Given the image "cat.png" in "Research"
      When the MC restarts
      Then the images of "Research" are "cat.png"
      And the bytes of "cat.png" can be fetched

  @mc @desktop @mobile @tui
  Rule: Generating an image

    Scenario: The user generates an image from a prompt
      Given image generation is available
      When the user generates an image of "a red fox" in "Research"
      Then "Research" has a generated image of "a red fox"

    Scenario: No image is made without a provider that can generate one
      Given no image generation provider is available
      When the user generates an image of "a red fox" in "Research"
      Then the user is told image generation is unavailable
      And the images of "Research" are ""

    Scenario: A failed generation makes no image
      Given image generation fails
      When the user generates an image of "a red fox" in "Research"
      Then the user is told image generation failed
      And the images of "Research" are ""

  @mc @desktop @mobile @tui
  Rule: Choosing the provider

    Scenario: The user is offered only the providers that can generate an image
      Given image generation is available
      Then the image providers on offer say which can generate

  @mc
  Rule: Which providers generate images

    Scenario Outline: A provider that can generate one runs its own agent
      Given <provider> is installed and can generate images
      When the user generates an image of "a red fox" in "Research" with <provider>
      Then "Research" has a generated image of "a red fox"
      And the image remembers it was made by <provider>

      Examples:
        | provider |
        | codex    |
        | grok     |

    Scenario Outline: A provider that cannot generate one is not supported here
      When the user generates an image of "a red fox" in "Research" with <provider>
      Then the user is told <provider> does not generate images here
      And the images of "Research" are ""

      Examples:
        | provider    |
        | claudeAgent |
        | cursor      |
        | opencode    |
        | antigravity |
        | pi          |

    Scenario: With no choice the MC uses the first provider that can generate
      Given grok is installed and can generate images
      And no other provider is available
      When the user generates an image of "a red fox" in "Research"
      Then the image remembers it was made by grok

    Scenario: An agent that leaves no image makes no image
      Given grok is installed and leaves no file
      When the user generates an image of "a red fox" in "Research" with grok
      Then the user is told image generation failed
      And the images of "Research" are ""

    Scenario: What an agent leaves is checked like an upload
      Given grok is installed and leaves a file that is not an image
      When the user generates an image of "a red fox" in "Research" with grok
      Then the user is told image generation failed
      And the images of "Research" are ""

    Scenario: A prompt is required
      Given image generation is available
      When the user generates an image of "" in "Research"
      Then the image request is refused

  @mc @desktop @mobile @tui
  Rule: Images on a page

    Background:
      Given the page "Roadmap"
      And the image "cat.png" in "Research"

    Scenario: The user places an image on a page
      When the user places the image "cat.png" on "Roadmap"
      Then "Roadmap" shows the image "cat.png"

    Scenario: A page says when its image is in the trash, and shows it again on restore
      Given "Roadmap" shows the image "cat.png" already
      When the user moves the image "cat.png" to the trash
      Then "Roadmap" says the image "cat.png" is in the trash
      When the user restores the image "cat.png"
      Then "Roadmap" shows the image "cat.png"

    Scenario: A page says when its image was deleted for good
      Given "Roadmap" shows the image "cat.png" already
      And the image "cat.png" is in the image trash
      When the user deletes the image "cat.png" for good
      Then "Roadmap" says the image "cat.png" was deleted

    Scenario: An image in the trash cannot be placed
      Given the image "cat.png" is in the image trash
      When the user places the image "cat.png" on "Roadmap"
      Then the page request is refused

  @mc
  Rule: An image outlives what shows it

    Background:
      Given the page "Roadmap"
      And the image "cat.png" in "Research"
      And "Roadmap" shows the image "cat.png" already

    Scenario: Removing the block keeps the image
      When the user removes the image from "Roadmap"
      Then the images of "Research" are "cat.png"

    Scenario: Deleting the page keeps the image
      Given the page "Roadmap" is in the trash
      When the user deletes the page "Roadmap" for good
      Then the images of "Research" are "cat.png"
      And the bytes of "cat.png" can be fetched

    Scenario: Two pages share one image and one file
      Given the page "Ideas"
      When the user places the image "cat.png" on "Ideas"
      Then "Ideas" shows the image "cat.png"
      And "Roadmap" shows the image "cat.png"
      And the Space keeps one file for "cat.png"

    Scenario: Deleting an image used by two pages tells both
      Given the page "Ideas"
      And "Ideas" shows the image "cat.png" already
      And the image "cat.png" is in the image trash
      When the user deletes the image "cat.png" for good
      Then "Roadmap" says the image "cat.png" was deleted
      And "Ideas" says the image "cat.png" was deleted

    Scenario: A page's Markdown names the image, and comes back as the image
      When the user exports "Roadmap" as Markdown
      Then the Markdown holds the image "cat.png"
      When the user imports that Markdown into "Research" as "Copy"
      Then "Copy" shows the image "cat.png"

    Scenario: Markdown naming an image this Space does not have stays as text
      When the user imports this Markdown into "Research":
        """
        # Copy

        ![lost](space-image:nothing-here)
        """
      Then the blocks of "Copy" read "![lost](space-image:nothing-here)"

  @mc @desktop @mobile @tui
  Rule: Trash

    Background:
      Given the image "cat.png" in "Research"

    Scenario: A trashed image leaves the Space's images and waits in the trash
      When the user moves the image "cat.png" to the trash
      Then the images of "Research" are ""
      And the image trash of "Research" holds "cat.png"

    Scenario: The user restores an image from the trash
      Given the image "cat.png" is in the image trash
      When the user restores the image "cat.png"
      Then the images of "Research" are "cat.png"
      And the image trash of "Research" holds ""

    Scenario: The user deletes an image from the trash for good
      Given the image "cat.png" is in the image trash
      When the user deletes the image "cat.png" for good
      Then the image trash of "Research" holds ""

    Scenario: Only a trashed image can be deleted for good
      When the user deletes the image "cat.png" for good
      Then the image request is refused
      And the images of "Research" are "cat.png"

  @mc
  Rule: What happens to the bytes

    Background:
      Given the image "cat.png" in "Research"

    Scenario: A client fetches the bytes over a signed address
      Then the bytes of "cat.png" can be fetched

    Scenario: The trash can still show a trashed image
      Given the image "cat.png" is in the image trash
      Then the bytes of "cat.png" can be fetched

    Scenario: Deleting an image for good removes its file
      Given the image "cat.png" is in the image trash
      And a signed address for "cat.png"
      When the user deletes the image "cat.png" for good
      Then no image file is left behind
      And the signed address finds nothing
      And no new address can be signed for "cat.png"

    Scenario: The bytes never travel on the stream
      Given a second client watching the Space "Research"
      When the user adds the image "dog.png" to "Research"
      Then the second client sees the image "dog.png"
      And the Space's event log holds none of the bytes of "dog.png"

    Scenario: A Space that still keeps an image cannot be deleted
      When the user deletes the Space "Research"
      Then the Space request is refused
      And the Spaces are "Personal, Research"

    Scenario: A Space whose image is in the trash cannot be deleted either
      Given the image "cat.png" is in the image trash
      When the user deletes the Space "Research"
      Then the Space request is refused

  @desktop @mobile
  Rule: Showing images

    Background:
      Given the page "Roadmap"
      And the image "cat.png" in "Research"

    Scenario: The Space's images can be browsed
      When the user opens the images of "Research"
      Then the user sees the image "cat.png" with its name

    Scenario: A placed image is fetched only when the page is open
      Given "Roadmap" shows the image "cat.png" already
      Then no address has been signed for "cat.png"
      When the user opens the page "Roadmap"
      Then an address has been signed for "cat.png"

  @tui
  Rule: A terminal cannot draw an image

    Background:
      Given the page "Roadmap"

    Scenario: Images are listed by name and prompt
      Given image generation is available
      When the user generates an image of "a red fox" in "Research"
      Then the images list shows the prompt "a red fox"

    Scenario: A placed image shows as text on the page
      Given the image "cat.png" in "Research"
      And "Roadmap" shows the image "cat.png" already
      When the user opens the page "Roadmap"
      Then the page shows the text "[image: cat.png]"

  @backlog @mc @shared
  Rule: Still to come

    Scenario: The user generates an image from reference images
      When the user generates an image of "a red fox" in the style of "cat.png"
      Then the new image follows the reference

    Scenario: The user pins a style for the Space's images
      Given the Space's style is pinned to "watercolour"
      When the user generates an image of "a red fox" in "Research"
      Then the new image follows the style

    Scenario: The user edits an image
      Given the image "cat.png" in "Research"
      When the user asks for "a hat on the cat" on the image "cat.png"
      Then the Space keeps a new version of "cat.png"

    Scenario: The user renames an image
      Given the image "cat.png" in "Research"
      When the user renames the image "cat.png" to "kitten.png"
      Then the images of "Research" are "kitten.png"

    Scenario: An image goes on a slide
      When the user places the image "cat.png" on a slide
      Then the slide shows the image "cat.png"

    Scenario: An image goes on a published site
      When the user publishes a page showing the image "cat.png" as a site
      Then the site shows the image "cat.png"
