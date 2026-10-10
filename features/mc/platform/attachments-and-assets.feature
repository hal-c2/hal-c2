# Sources:
#   apps/server-ex/lib/hal_c2/attachments.ex (upload URLs, claims, persist, signed asset URLs)
#   apps/server-ex/lib/hal_c2/web/router.ex (POST /api/attachments/upload/:token, GET /api/assets/:token)
#   apps/server-ex/test/hal_c2/features_backlog_test.exs (project-favicon-assets, native-app-icon-assets,
#     github-media-assets)
#   packages/contracts/src/assets.ts (asset resources and errors)
#   packages/contracts/src/rpc.ts (attachments.createUploadUrl, attachments.delete, assets.createUrl,
#     assets.persistChatAttachments)
#   apps/server/src/assets/AssetAccess.ts (file identity checks, image size from the header)
#   packages/shared/src/imageDimensions.ts (PNG, GIF, WebP and JPEG header sizes, EXIF rotation)
#   apps/server/src/http.ts (asset response headers, byte ranges, download names, no-store after expiry)
#   apps/server/src/assets/GitHubMediaFetch.ts (credential host list, redirects, SVG policy)
#   apps/server/src/assets/AssetAccess.test.ts, MediaFile.ts (signed URL claims, favicon buckets,
#     sibling files, symlink and swap checks, inline attachment rules, GitHub media addresses)
#   apps/server/src/attachmentStore.ts, attachmentPaths.ts, imageMime.ts (ids, partial uploads, binary fallback,
#     path containment, pasted-image validation), apps/server/src/ws.ts (persistChatAttachments)
#   apps/server/src/orchestration-v2/AttachmentClaims.ts (duplicate ids, provider limits before
#     claiming, undoing a claim that fails part-way)
#   apps/server/src/orchestration-v2/ThreadMessageIntake.ts (uploads given back after a refusal, kept
#     when the outcome is unknown, answers sent twice, the limit across an answer's questions)
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

  @backlog @mc
  Scenario: A message naming the same upload twice is refused
    Given the client uploaded an image
    When the client sends a message naming that upload twice
    Then the message fails with "Duplicate attachment ids are not allowed."

  @backlog @mc
  Scenario: A message over the provider's attachment limits claims nothing
    Given the client uploaded more images than the thread's provider accepts in one message
    When the client sends a message naming all of them
    Then the message fails before any upload is claimed into the thread

  @backlog @mc
  Scenario: A message whose attachments cannot all be claimed claims none of them
    Given the client uploaded two images
    When the client sends a message naming both and the second cannot be claimed
    Then the message fails naming the second image
    And the first image does not belong to the thread
    And both uploads can still be sent again

  @backlog @mc
  Scenario: A message the MC refuses after claiming its uploads gives them back
    Given the client uploaded an image
    When the client sends a message naming that upload and the MC refuses the message
    Then the image does not belong to the thread
    And the upload can still be sent again

  @backlog @mc
  Scenario: Claimed copies are kept when the MC cannot tell whether the message was accepted
    Given the client uploaded an image
    When the client sends a message naming that upload and the send fails without a clear refusal
    Then the image stays with the thread
    And sending the same message again does not store the image a second time

  @backlog @mc
  Scenario: An answer sent again after it was accepted stores its files once
    Given the user answered a question attaching "error.png" and the answer was accepted
    When the client sends the same answer again
    Then the thread holds one copy of "error.png"
    And the answer still names the copy saved the first time

  @backlog @mc
  Scenario: Files attached to an answer are counted across all its questions
    Given the agent asked two questions and the provider accepts 50 MiB of images per message
    When the user answers both, attaching five 10 MiB images to each
    Then the answer is refused naming the 80 MiB the images add up to
    And none of the images is claimed into the thread

  @backlog @mc
  Scenario: Editing a queued message claims the uploads it adds
    Given the thread has a queued message and the client uploaded an image
    When the client edits the queued message to attach that upload
    Then the image belongs to the thread
    And the queued message carries it

  @backlog @mc
  Scenario: A launch that carries uploads must name its thread
    Given the client uploaded an image
    When a client launches a thread attaching that upload without giving the thread an id
    Then the launch fails with "Uploaded attachments need a thread id at launch."
    And the upload can still be sent again

  @mc
  Scenario: Uploads never claimed are swept after a day
    Given an upload no message claimed for 25 hours
    Then the MC has removed it

  @mc
  Scenario: A client removes an upload it will not send
    Given the client uploaded an image
    When it deletes that upload
    Then the upload is gone

  # Legacy: apps/server/src/assets/AttachmentUpload.ts (deletePendingAttachment),
  #   apps/server/src/assets/AttachmentUpload.test.ts (deletes pending uploads without deleting
  #   thread-owned copies)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (delete)
  @backlog @mc
  Scenario: Removing an upload never removes a thread's copy
    Given an upload that is still pending and the same image already stored with a thread
    When a client deletes the pending upload twice and then deletes the thread's attachment id
    Then the pending upload is gone and both requests succeeded
    And the thread's copy is still there

  # Legacy: apps/server/src/assets/AttachmentUpload.ts (storeAttachmentUpload: ".part" file,
  #   takeWhile over the signed size), apps/server/src/assets/AttachmentUpload.test.ts (stores the
  #   expected bytes without leaving temporary files; removes partial streamed uploads ...)
  @backlog @mc
  Scenario Outline: An upload that fails part-way leaves nothing behind
    Given an upload URL for a 6 byte image
    When <arrival>
    Then the upload is refused or abandoned
    And no file for it, finished or partial, is in the attachment store

    Examples:
      | arrival                                              |
      | the client sends 7 bytes in a streamed body          |
      | the client sends 3 bytes in a streamed body and stops |
      | the client sends 3 bytes and the connection drops    |

  # Legacy: apps/server/src/assets/AttachmentUpload.ts (validateAttachmentUploadToken: a third
  #   segment, a changed payload, a body that is not a token)
  @backlog @mc
  Scenario Outline: An upload URL that was altered is refused
    Given an upload URL for a 2 MB file
    When the client sends the bytes to the URL with <change>
    Then the MC refuses the link as invalid or expired
    And nothing is stored

    Examples:
      | change                         |
      | one character added to the payload |
      | a third dot-separated segment  |
      | a word that is not a token     |

  # Legacy: packages/contracts AttachmentUploadSigningKeyError, apps/server/src/assets/AssetAccess.ts
  #   (AssetSigningKeyLoadError; resolveAsset answers null when the key cannot be read)
  @backlog @mc
  Scenario: No URL is signed when the MC cannot read its signing key
    Given the MC's signing key cannot be read or created
    When a client asks for an upload URL or an asset URL
    Then the request fails with AttachmentUploadSigningKeyError or AssetSigningKeyLoadError
    And a URL signed earlier is not served until the key can be read

  @mc
  Scenario: Pasted images are stored with the thread
    When the client sends a message with pasted images inline
    Then the MC stores them as thread attachments

  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (persist)
  @backlog @mc
  Scenario Outline: A pasted image that is not what it claims to be is refused
    When the client sends a message with a pasted image <problem>
    Then the message fails naming the image
    And the MC stores none of the message's pasted images

    Examples:
      | problem                                                     |
      | whose data is not a base64 image                            |
      | whose data is a different image type than its declared type |
      | whose data is not valid base64                              |
      | whose decoded size differs from its declared size           |

  @backlog @mc
  Scenario: A message sent again does not store its pasted images twice
    Given the client sent a message with a pasted image
    When the client sends the same message again after a lost reply
    Then the thread has the image once
    And the second send finds the stored image under the same attachment id

  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (id_suffix)
  @backlog @mc
  Scenario Outline: A file the MC cannot name safely is stored as a binary file
    Given the client uploads a file named <name>
    When the client sends a message naming that upload
    Then the MC stores the file without an extension it cannot trust
    And the provider and the user can still open it

    Examples:
      | name                                  |
      | "archive.part"                        |
      | "notes.averyveryverylongextension"    |
      | "report.t@r"                          |

  @backlog @mc
  Scenario: An upload still arriving is swept after an hour
    Given an upload that began arriving more than an hour ago and never finished
    Then the MC has removed the unfinished bytes
    But a completed upload from the same hour is kept until it is a day old

  @backlog @mc
  Scenario: An attachment that already belongs to a thread cannot be claimed again
    Given an image that belongs to one thread
    When a client sends a message to another thread naming that image as an upload
    Then the message fails saying the attachment must be a pending upload
    And the image still belongs to its first thread

  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (safe_id?)
  @backlog @mc
  Scenario Outline: An attachment id that points outside the attachment store finds nothing
    When a client asks for the attachment <id>
    Then the MC answers that no such attachment exists
    And nothing outside the attachment store is read

    Examples:
      | id                          |
      | "../../settings.json"       |
      | "a/b"                       |
      | "pending-123.png"           |

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

  # Legacy: apps/server/src/assets/AssetAccess.test.ts (rejects non-previewable files, disguised
  #   targets, and directories)
  @backlog @mc
  Scenario Outline: A media URL is not issued for a file that only has a media name
    Given the host has <file>
    When the client asks for a media URL for it
    Then the MC refuses saying only media files are served

    Examples:
      | file                                              |
      | "disguised.png", a link to the text file "secret.txt" |
      | "secret.%70ng", a text file                        |
      | "secret.png#private.txt", a text file              |

  # Legacy: packages/shared/src/imageDimensions.ts, apps/server/src/assets/AssetAccess.ts (readImageDimensionsFromHeader)
  @backlog @mc
  Scenario Outline: A client is told an image's size before it fetches the image
    Given the project holds a <format> image
    When the client asks for an asset URL for it
    Then the answer carries the image's width and height in pixels

    Examples:
      | format                                  |
      | PNG                                     |
      | GIF                                     |
      | WebP                                    |
      | JPEG whose metadata is large            |

  # Legacy: packages/shared/src/imageDimensions.ts (readJpeg, exifOrientationSwapsAxes)
  @backlog @mc
  Scenario: A photo stored on its side is given the size it is shown at
    Given the project holds a JPEG photo whose metadata says it is rotated a quarter turn
    When the client asks for an asset URL for it
    Then the width and height are swapped from those stored in the file

  # Legacy: packages/shared/src/imageDimensions.ts (null on unknown or malformed headers)
  @backlog @mc
  Scenario Outline: An image whose size cannot be read is served without one
    Given the project holds <file>
    When the client asks for an asset URL for it
    Then the MC returns a URL that serves the file
    And the answer carries no width and height

    Examples:
      | file                              |
      | an SVG image                      |
      | a PNG whose header is cut short   |
      | a file named like an image that is not one |

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

  # Legacy: apps/server/src/assets/AssetAccess.ts (resolveAsset: signature, expiry),
  #   apps/server/src/assets/AssetAccess.test.ts (tampered tokens)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (verify)
  @backlog @mc
  Scenario Outline: A signed URL that was altered is not served
    Given a signed URL for a media file on the host
    When the client reads the URL with <change>
    Then the MC does not serve the file

    Examples:
      | change                                   |
      | extra characters after the signature     |
      | the signature removed                    |
      | its payload swapped for another URL's    |

  # Legacy: apps/server/src/assets/AssetAccess.ts (SIGNING_SECRET_NAME, getOrCreateRandom)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (secret)
  @backlog @mc
  Scenario: A signed URL still works after the MC restarts
    Given a signed URL for a project file
    When the MC restarts
    And the client reads the URL within its hour
    Then the MC serves the file
    And a URL signed by a different MC's key is still refused

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

  # Legacy: apps/server/src/assets/AssetAccess.ts (PROJECT_FAVICON_TOKEN_BUCKET_MS, content-hash file
  #   name), apps/server/src/assets/AssetAccess.test.ts (issues project favicon capabilities ...;
  #   buckets project favicon expiry after content hashing)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (favicon_expiry, "v<sha256>-")
  @backlog @mc
  Scenario: A favicon's URL stays the same until the icon changes
    Given a signed URL for a project's favicon
    When a client asks for the project's favicon URL again within half an hour
    Then it receives the same URL
    When the icon file's contents change
    Then the next URL ends in a different name
    And the URL's expiry falls on a half-hour boundary, between one and two half-hours away

  # Legacy: apps/server/src/assets/AssetAccess.ts (project-favicon-external),
  #   apps/server/src/assets/AssetAccess.test.ts (issues an exact capability for a saved favicon
  #   outside the workspace; ignores a client favicon path hint; keeps automatic favicon resolution
  #   separate from a saved override)
  @backlog @mc
  Scenario Outline: The icon the user saved decides which favicon is served
    Given the project has the automatic icon "favicon.svg"
    And <saved>
    When a client asks for the project's favicon URL<hint>
    Then the MC serves <served>
    And the URL answers only for that file, whatever name is asked for

    Examples:
      | saved                                                  | hint                          | served                                |
      | the user saved "brand/custom.svg" as the icon           |                               | "brand/custom.svg"                    |
      | the user saved "/pictures/custom.png", outside the project |                            | "/pictures/custom.png"                |
      | the user saved "brand/saved.svg" as the icon            | , suggesting "brand/hint.svg" | "brand/saved.svg"                     |
      | the user saved nothing                                  |                               | "favicon.svg"                         |

  # Legacy: apps/server/src/assets/AssetAccess.test.ts (rejects a resolved project favicon with a
  #   non-image extension)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (@image_extensions)
  @backlog @mc
  Scenario: A saved icon that is not an image is refused
    Given the user saved "secret.txt" as the project's icon
    When a client asks for the project's favicon URL
    Then the MC refuses it saying only images are served as icons

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

  # Legacy: apps/server/src/assets/NativeAppIconResolver.ts (resolveApplicationPath,
  #   resolveNativeAppIconUncached; macOS only)
  # Likely already implemented on Linux: apps/server-ex/lib/hal_c2/attachments/app_icon.ex (desktop
  #   entries); the macOS lookup below is not
  @backlog @mc
  Scenario Outline: On macOS the MC finds an application's icon in its bundle
    Given the MC runs on macOS and Spotlight knows <apps>
    When a client asks for the icon of the application <reference>
    Then the MC serves the icon of <chosen>

    Examples:
      | apps                                                              | reference                       | chosen                          |
      | "Editor.app" with the bundle id "com.example.Editor"              | with the bundle id "com.example.Editor" | "Editor.app"            |
      | "Review.app" and "Review Beta.app", the second used more recently | named "Review"                  | "Review.app"                    |
      | "Review 2.app" and "Review 3.app", the second used more recently  | named "Review"                  | "Review 3.app"                  |

  # Legacy: apps/server/src/assets/NativeAppIconResolver.ts (iconName checks, relativeSource,
  #   ICON_SIZE, cacheKey)
  @backlog @mc
  Scenario Outline: A macOS application icon is turned into a small picture the client can use
    Given the application bundle <bundle>
    When a client asks for its icon
    Then <result>

    Examples:
      | bundle                                                             | result                                           |
      | names its icon in Info.plist and holds it in Resources             | the MC serves it as a 64 by 64 PNG               |
      | has no icon name but holds "AppIcon.icns"                          | the MC serves "AppIcon.icns" as a PNG            |
      | has no icon name and no "AppIcon.icns" but holds one other ".icns" | the MC serves that icon as a PNG                 |
      | names an icon with a folder in its name                            | the MC answers not found                         |
      | holds an icon that is a link to a file outside Resources           | the MC answers not found                         |
      | holds no icon at all                                               | the MC answers not found                         |

  # Legacy: apps/server/src/assets/NativeAppIconResolver.ts (Cache: one hour, 256 entries, misses
  #   cached, rebuilt when the file is gone; Semaphore of two; containsControlCharacter;
  #   escapeSpotlightString), apps/server/src/assets/NativeAppIconResolver.test.ts
  @backlog @mc
  Scenario: Asking again for an application's icon does not search again
    Given a client asked for the icon of an application the host does not have
    When a client asks for that icon again within the hour
    Then the MC answers not found without searching the host again
    And an icon that was found is rebuilt if its converted picture was deleted

  # Legacy: apps/server/src/assets/NativeAppIconResolver.ts (containsControlCharacter,
  #   escapeSpotlightString)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments/app_icon.ex (resolve)
  @backlog @mc
  Scenario Outline: An application name that cannot be searched safely finds no icon
    When a client asks for the icon of the application named <name>
    Then the MC does not search the host with it as part of a query
    And <result>

    Examples:
      | name                              | result                                       |
      | "Review * App"                    | the star only matches a star, not any name   |
      | a name with a line break          | the MC answers not found                     |
      | a name with a NUL character       | the MC answers not found                     |

  @mc
  Scenario: The MC proxies GitHub media with the user's GitHub credentials
    Given a pull request comment with an image in a private repository
    When a client asks for that image
    Then the MC fetches it with the host's GitHub credentials and serves it

  @mc
  Scenario: A private repository token never reaches the client
    When a client reads proxied GitHub media
    Then the response carries no GitHub token

  # Legacy: apps/server/src/assets/AssetAccess.ts (github-media case), packages/shared/src/githubMedia.ts,
  #   apps/server/src/assets/AssetAccess.test.ts (serves GitHub-hosted pull request media ...)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments/github_media.ex (fetch_url)
  @backlog @mc
  Scenario Outline: A GitHub media address is checked when its URL is issued
    When the client asks for an asset URL for the GitHub media address <address>
    Then <result>

    Examples:
      | address                                                                  | result                                                          |
      | https://github.com/user-attachments/assets/1a1842fb-6383-492f-873c-57aa0033fa6c | the URL ends in the attachment's id                       |
      | https://github.com/owner/repo/blob/main/docs/shot.png                    | the MC will fetch it from raw.githubusercontent.com instead     |
      | https://github.com/owner/repo/assets/45952064/1a1842fb                   | the MC will fetch the older attachment address as it is         |
      | https://media.githubusercontent.com/media/owner/repo/main/a.mp4          | the MC will fetch the Git LFS address as it is                  |
      | https://raw.githubusercontent.com/o/r/main/100%.png                       | the URL ends in "100%25.png"                                    |
      | https://example.com/shot.png                                             | the MC fails with AssetGitHubMediaUrlValidationError            |
      | https://example.com/shot.png?token=private-media-token                   | the MC fails with AssetGitHubMediaUrlValidationError            |
      | http://github.com/user-attachments/assets/1a1842fb                       | the MC fails with AssetGitHubMediaUrlValidationError            |
      | https://github.com/owner/repo/pull/1                                     | the MC fails with AssetGitHubMediaUrlValidationError            |
      | https://github.com/owner/repo/blob/main/                                 | the MC fails with AssetGitHubMediaUrlValidationError            |

  # Legacy: apps/server/src/assets/AssetAccess.test.ts (the error never carries the rejected URL)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments.ex (asset_claims github-media)
  @backlog @mc
  Scenario: A refused GitHub media address is not repeated in the error
    When the client asks for an asset URL for "https://example.com/shot.png?token=private-media-token"
    Then the failure does not contain the address or its token

  # Legacy: apps/server/src/assets/GitHubMediaFetch.ts (githubToken: no credential is not cached),
  #   apps/server/src/assets/AssetAccess.test.ts (loads private media immediately after login)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments/github_media.ex (token)
  @backlog @mc
  Scenario: Signing in to GitHub takes effect on the next media request
    Given the host's GitHub CLI is not signed in
    And a private repository image is signed for a client
    When the client reads it
    Then GitHub answers 404 and the client receives 404
    When the host signs in to GitHub
    And the client reads it again
    Then the MC sends the credential and serves the image
    And the next requests reuse the credential without asking the CLI again

  # Legacy: apps/server/src/assets/GitHubMediaFetch.ts (githubMediaResponse)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments/github_media.ex (serve, fetch)
  @backlog @mc
  Scenario Outline: GitHub's answer to a media request is passed on or refused
    Given GitHub answers a media request with <upstream>
    When a client reads the media URL
    Then the MC answers <answer>

    Examples:
      | upstream                                                | answer                                              |
      | 404, or any other status below 500                      | that same status, with no body                      |
      | a 5xx status                                            | 502                                                 |
      | four redirects in a row                                 | 502                                                 |
      | a redirect to an address that is not https              | 502                                                 |
      | an HTML page with status 200                            | 415                                                 |
      | "application/octet-stream" for a file named "clip.mp4"  | 200 with the type "video/mp4"                       |

  # Legacy: apps/server/src/assets/GitHubMediaFetch.ts (FORWARDED_REQUEST_HEADERS,
  #   FORWARDED_RESPONSE_HEADERS, cache-control from the URL's remaining life)
  # Likely already implemented: apps/server-ex/lib/hal_c2/attachments/github_media.ex (serve)
  @backlog @mc
  Scenario: A seek in GitHub-hosted video costs one range request upstream
    Given a signed URL for a video hosted on GitHub
    When a player asks for "bytes=100-199"
    Then the MC forwards that range to GitHub
    And answers with GitHub's range, length and validators
    And the response may be cached privately for as long as the signed URL has left, and not at all once it has expired

  @backlog @mc
  Scenario: A GitHub SVG is served in a sandbox that cannot run scripts
    Given a pull request comment with an SVG image in a repository
    When a client asks for that image
    Then the response is an SVG that runs no scripts and loads nothing from outside

  @backlog @mc
  Scenario: GitHub's credential is not sent to a redirect host outside GitHub
    Given GitHub answers a media request with a redirect to a signed object address
    When the MC follows the redirect
    Then the GitHub credential is not sent to the redirected address

  @mc
  Scenario: A replaced file needs a new asset URL
    Given a signed URL for a media file on the host
    When the file is replaced atomically by another file
    Then the old URL no longer serves it
    And editing the same file in place keeps the URL working

  # Legacy: apps/server/src/assets/AssetAccess.test.ts (binds media URLs to the canonical target
  #   and rejects symlink substitution)
  @backlog @mc
  Scenario: A URL signed through a link stays with the file the link pointed at
    Given "alias.png" is a link to "actual.svg" and a signed URL was issued for "alias.png"
    When "alias.png" is made to point at "other.svg"
    Then the URL still serves "actual.svg" as an SVG image
    When "actual.svg" is replaced by a link to "other.svg"
    Then the URL no longer serves anything

  # Legacy: apps/server/src/assets/AssetAccess.test.ts (keeps full and partial responses bound to
  #   the file opened during resolution; rejects a symlink swapped in after canonical validation
  #   but before open; closes a descriptor rejected when its path changes during open; rejects an
  #   ancestor symlink race)
  @backlog @mc
  Scenario Outline: A file swapped for a link while it is being served never reveals the target
    Given a signed URL for the video "recording.mp4", beside a private "secret.txt"
    When <swap> and the client reads the URL<range>
    Then the MC serves <served>

    Examples:
      | swap                                                     | range                  | served                       |
      | "recording.mp4" is replaced by a link to "secret.txt" after the MC opened it | | the video's own bytes        |
      | "recording.mp4" is replaced by a link to "secret.txt" after the MC opened it | asking for bytes 2-5 | bytes 2-5 of the video |
      | "recording.mp4" is replaced by a link to "secret.txt" before the MC opens it  | | nothing                      |
      | the folder holding "recording.mp4" is swapped for a link to another folder    | | nothing                      |

  # Legacy: apps/server/src/assets/AssetAccess.ts (media-file-exact and workspace-file-exact:
  #   the file name in the URL must be the signed file's name)
  @backlog @mc
  Scenario: A media or image URL answers only to the name it was signed with
    Given a signed URL for "icon.png" in a folder that also holds "other.png"
    When the client asks the same URL for "other.png" or for "../icon.png"
    Then the MC serves neither

  # Legacy: apps/server/src/assets/AssetAccess.ts (resolveAsset workspace-file: decodeRelativePath,
  #   PREVIEW_ASSET_EXTENSIONS)
  @backlog @mc
  Scenario: A page's neighbouring files are served by name under its URL
    Given a signed URL for "report.html" in the project, beside "report.css" and ".env"
    When the client reads "report.css" under that URL
    Then the MC serves "report.css"
    And "report.html" itself is served under the same URL

  # Legacy: apps/server/src/assets/AssetAccess.ts (resolveAsset: dot segments, NUL, extension
  #   whitelist, canonical workspace containment)
  @backlog @mc
  Scenario Outline: A page's neighbours are limited to what a page needs
    Given a signed URL for "report.html" in the project
    When the client reads <name> under that URL
    Then the MC does not serve it

    Examples:
      | name                                             |
      | ".env"                                           |
      | "../secret.txt"                                  |
      | "sub/../../secret.txt"                           |
      | "notes.md", which is not a page, style, script, font or image |
      | a name containing a NUL character                |
      | "link.css", a link to a file outside the project |

  # Legacy: apps/server/src/assets/AssetAccess.ts (draft-workspace-file; issueAssetUrl)
  @backlog @mc
  Scenario: A draft page is served from the folder it was written for
    Given a draft in the project "/work/app" refers to "report.html"
    When the client asks for an asset URL for it with no thread
    Then the MC serves "report.html" and the files next to it
    And an absolute media path outside the project is served as that one file only

  @mc
  Scenario: Host videos seek without downloading the whole file
    Given a signed URL for a video on the host
    When a player seeks into the video
    Then the MC serves the requested range

  @backlog @mc
  Scenario Outline: A byte range that the file cannot satisfy is refused
    Given a signed URL for a video that is ten bytes long
    When a player asks for <range>
    Then the MC answers that the range cannot be satisfied
    And it says the file's real length

    Examples:
      | range                                    |
      | bytes starting at the end of the file    |
      | the last zero bytes of the file          |
      | bytes starting beyond any real file size |

  @backlog @mc
  Scenario: A player can ask for the last bytes of a file
    Given a signed URL for a video on the host
    When a player asks for only the last bytes of the file
    Then the MC serves exactly those bytes

  @backlog @mc
  Scenario: A thread attachment's media is not cached past its signed URL
    Given a signed URL for an audio attachment of a thread
    When a player reads it
    Then the response may not be stored by caches
    And it still accepts byte ranges

  @backlog @mc
  Scenario: Uploaded documents are downloaded rather than opened
    Given a signed download URL for an uploaded document
    When the client reads it
    Then the MC serves it as an attachment that cannot run scripts
    And the file keeps its real name and type when those were claimed at upload

  @backlog @mc
  Scenario Outline: A file type that a browser could render is downloaded as plain bytes
    Given a signed download URL for an uploaded file claimed as <type>
    When the client reads it
    Then the MC serves it as an opaque download

    Examples:
      | type                  |
      | HTML                  |
      | XML                   |
      | SVG                   |
      | XHTML                 |
      | a malformed type      |

  @backlog @mc
  Scenario: Office documents keep their own type
    Given a signed download URL for an uploaded Word, Excel or PowerPoint file
    When the client reads it
    Then the MC serves it with its official document type

  # Legacy: apps/server/src/assets/AssetAccess.ts (INLINE_PREVIEW_MIME_TYPES, audioMimeTypeFromExtension),
  #   apps/server/src/assets/AssetAccess.test.ts (serves video attachments inline; serves document
  #   attachments inline when a viewer requests it; serves audio previews ...)
  @backlog @mc
  Scenario Outline: A viewer can ask for a document or recording to be shown rather than saved
    Given a thread attachment stored as <stored>
    When the client asks for its URL with the name "<name>", the claimed type "<claimed>" and <disposition>
    Then the MC serves it as <served>

    Examples:
      | stored | name          | claimed                   | disposition        | served                          |
      | .pdf   | report.pdf    | application/pdf           | "inline"           | "application/pdf", shown inline |
      | .html  | page.html     | text/html                 | "inline"           | "text/html", shown inline       |
      | .wav   | recording.wav | application/octet-stream  | "inline"           | "audio/wav", shown inline       |
      | .wav   | recording.wav | application/octet-stream  | "attachment"       | a download of its own type      |
      | .mp4   | demo.mp4      | video/mp4; codecs="avc1"  | no disposition     | "video/mp4", shown inline       |

  # Legacy: apps/server/src/assets/AssetAccess.test.ts (keeps inline requests for other attachment
  #   types as downloads)
  @backlog @mc
  Scenario: A file type that cannot be shown stays a download whatever the client claims
    Given a thread attachment stored as ".zip"
    When the client asks for its URL claiming "text/html" and asks for it inline
    Then the MC serves it as a download
    And the type comes from the stored file, not from the claim

  @backlog @mc
  Scenario: HTML and SVG files served from a project are sandboxed
    Given a signed URL for an HTML file and one for an SVG file in the project
    When the client reads them
    Then the HTML is served as UTF-8 in a sandbox
    And the SVG is served in a sandbox with no network or scripts

  @backlog @mc
  Scenario: A file name with unusual characters downloads safely
    Given an uploaded document whose name has quotes, line breaks or non-ASCII letters
    When the client reads its download URL
    Then the name is cleaned for the plain header
    And the full name is carried in the encoded one
