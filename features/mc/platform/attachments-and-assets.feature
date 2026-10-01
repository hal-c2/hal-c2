# Sources:
#   apps/server-ex/lib/hal_c2/attachments.ex (upload URLs, claims, persist, signed asset URLs)
#   apps/server-ex/lib/hal_c2/web/router.ex (POST /api/attachments/upload/:token, GET /api/assets/:token)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (project-favicon-assets, native-app-icon-assets,
#     github-media-assets)
#   packages/contracts/src/assets.ts (asset resources and errors)
#   packages/contracts/src/rpc.ts (attachments.createUploadUrl, attachments.delete, assets.createUrl,
#     assets.persistChatAttachments)
#   apps/server/src/assets/AssetAccess.ts (file identity checks)
#   docs/internals/environment-auth.md (The environment is the filesystem boundary)
#   docs/user/question-attachments.md
#   docs/internals/providers.md (Attachments and stored history: replay compatibility limit)
#   Shared domain: composer/attachments.feature owns attaching files while writing a turn.

Feature: Attachments and assets served by the MC
  Clients upload attachment bytes to the thread's MC over signed URLs, and read files
  back over signed asset URLs. Any MC of the cluster accepts a signed URL and forwards
  it to the MC that issued it.

  Background:
    Given a running MC with a project and a thread
    And a paired client

  @mc
  Scenario: A client uploads an image over a signed URL
    When the client asks for an upload URL for a 2 MB image
    And sends the image's bytes to that URL
    Then the MC accepts the upload

  @mc
  Scenario: An upload URL expires after ten minutes
    Given an upload URL issued eleven minutes ago
    When the client sends bytes to it
    Then the MC refuses the link as invalid or expired

  @mc
  Scenario Outline: Uploads over the size limit are refused
    When the client asks for an upload URL for <file>
    Then the MC refuses saying attachments may be at most <limit>

    Examples:
      | file              | limit |
      | an 11 MB image    | 10 MB |
      | a 51 MB document  | 50 MB |

  @mc
  Scenario: A body larger than the upload limit is refused
    When the client sends more than 50 MB to an upload URL
    Then the MC answers that the upload is too large

  @mc
  Scenario: A body of the wrong size is refused
    Given an upload URL for a 2 MB file
    When the client sends 1 MB to it
    Then the MC answers that the body is the wrong size

  @mc
  Scenario: A link that is not an upload URL is refused
    When the client sends bytes to an asset URL as if it were an upload URL
    Then the MC refuses it as not an upload URL

  @mc
  Scenario: Sending a message claims its uploads into the thread
    Given the client uploaded an image
    When the client sends a message naming that upload
    Then the image belongs to the thread
    And the provider can read it

  @mc
  Scenario: A thread whose messages carry file attachments replays after a restart
    Given the thread has a message with an attached image and an attached text file
    When the MC restarts
    Then the MC starts and the thread's history loads with both attachments

  @mc
  Scenario: A message naming an upload that never arrived fails
    When the client sends a message naming an upload it never sent
    Then the message fails saying the attachment was not uploaded

  @mc
  Scenario: A message naming an upload with different details fails
    Given the client uploaded an image
    When it sends a message naming that upload with another size
    Then the message fails saying the attachment does not match its upload

  @mc
  Scenario: Uploads never claimed are swept after a day
    Given an upload no message claimed for 25 hours
    Then the MC has removed it

  @mc
  Scenario: A client removes an upload it will not send
    Given the client uploaded an image
    When it deletes that upload
    Then the upload is gone

  @mc
  Scenario: Pasted images are stored with the thread
    When the client sends a message with pasted images inline
    Then the MC stores them as thread attachments

  @mc
  Scenario Outline: A signed asset URL serves a file for an hour
    When the client asks for an asset URL for <resource>
    Then the MC returns a URL that serves the file
    And the URL stops working after an hour

    Examples:
      | resource                               |
      | a thread attachment                    |
      | a file in the project                  |
      | a file for a draft in the project      |
      | a media file an agent wrote on the host |

  @mc
  Scenario: Asset responses are privately cacheable
    When the client reads a signed asset URL
    Then the response may be cached privately for an hour
    And it names the file for download

  @mc
  Scenario: Only media files are served as media
    When the client asks for a media URL for a text file
    Then the MC refuses saying only media files are served

  @mc
  Scenario Outline: Asset requests for missing things fail with their own error
    When the client asks for an asset URL for <missing>
    Then the MC fails with <error>

    Examples:
      | missing                         | error                             |
      | an attachment that is gone      | AssetAttachmentNotFoundError      |
      | a project file that is gone     | AssetWorkspaceAssetNotFoundError  |
      | a media file that is gone       | AssetWorkspaceAssetNotFoundError  |
      | a project the MC does not know | AssetWorkspaceContextNotFoundError |

  @mc
  Scenario: A file deleted after its URL was signed is gone
    Given a signed URL for a project file
    When the file is deleted
    And the client reads the URL
    Then the MC answers that the file is gone

  @mc
  Scenario: Upload and asset URLs work through any MC of the cluster
    Given an asset URL issued by another member
    When the client reads it through the MC it is connected to
    Then the MC forwards the request to the issuer
    And only the issuer checks the signature

  # The MC now serves favicons, app icons and GitHub media (below); only a kind
  # outside the contract is left.
  @mc
  Scenario Outline: Asset kinds the MC does not serve yet
    When the client asks for an asset URL for <resource>
    Then the MC fails saying files are not served by this MC yet

    Examples:
      | resource                            |
      | an asset kind this MC does not know |

  @mc
  Scenario: The MC serves a project's favicon
    Given a project with a favicon in its repository
    When a client asks for the project's favicon
    Then the MC serves that icon

  @mc
  Scenario: A project without a favicon falls back to the default icon
    Given a project with no favicon
    When a client asks for the project's favicon
    Then the MC answers not found
    And the client shows the default project icon

  @mc
  Scenario: The MC serves a native app's icon for a work log entry
    Given a work log entry that names an application on the host
    When a client asks for that application's icon
    Then the MC serves the icon

  @mc
  Scenario: A missing app icon keeps the entry's text
    Given a work log entry naming an application the host does not have
    When a client asks for its icon
    Then the MC answers not found
    And the entry keeps its text

  @mc
  Scenario: The MC proxies GitHub media with the user's GitHub credentials
    Given a pull request comment with an image in a private repository
    When a client asks for that image
    Then the MC fetches it with the host's GitHub credentials and serves it

  @mc
  Scenario: A private repository token never reaches the client
    When a client reads proxied GitHub media
    Then the response carries no GitHub token

  @mc
  Scenario: A replaced file needs a new asset URL
    Given a signed URL for a media file on the host
    When the file is replaced atomically by another file
    Then the old URL no longer serves it
    And editing the same file in place keeps the URL working

  @mc
  Scenario: Host videos seek without downloading the whole file
    Given a signed URL for a video on the host
    When a player seeks into the video
    Then the MC serves the requested range
