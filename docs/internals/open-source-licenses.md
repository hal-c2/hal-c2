# Open source license notices

License notices are generated independently for each Qt client that ships them:

- The Qt desktop stages `licenses/third-party-licenses.json` beside its runtime
  (`apps/desktop-qt/scripts/stage-runtime.mjs`, or `vp run --filter @hal-c2/desktop-qt licenses` for
  a dev build). It holds the packages of the Cursor sidecar the MC release ships
  (`packages/cursor-acp`) plus the `desktop-qt` custom notices: Qt, the Erlang/OTP and Elixir runtime
  of the MC, the Node.js it ships, and the icons the bricks draw. `LicensesController` reads it when
  the Open source licenses section opens.
- The Qt mobile client compiles its manifest into the binary when an APK is built
  (`apps/mobile-qt/cmake/Licenses.cmake`), since an APK has no directory beside the binary. It holds
  the `mobile-qt` custom notices and no packages: what an APK ships is native code (Qt, OpenSSL, the
  NDK's C++ library, the libraries Qt's Android activity is built with) and the icons, so writing it
  needs no installed npm packages.

No path depends on the connected environment or an RPC.

## What the build collects

The generator follows installed production and optional dependencies, including dependencies of
workspace packages, and omits first-party `@hal-c2/*` packages. The desktop manifest starts from the
`packages/cursor-acp` package manifest; the mobile manifest starts from none.

The build fails when a collected package has no distributable license identifier or contains no
license or notice text. Generated notices use license templates from the pinned SPDX License List.
Strict builds download a missing template into the gitignored `.generated/` cache; `pnpm
licenses:sync` can warm that cache explicitly. The dev build (`licenses --offline`) makes no network
request and omits generated rows until the cache exists. This keeps dev startup optional while
preventing incomplete release artifacts.

## Custom notices and package overrides

The repository-level `third-party-licenses.config.json` holds manually maintained exceptions for
all clients. Add an entry to `customNotices` for adapted icons, fonts, media, native modules, or
another asset that did not come from an npm package. The clients are `desktop-qt` and `mobile-qt`:

```json
{
  "name": "asset-name",
  "license": "CC-BY-4.0",
  "generatedNotices": [
    {
      "licenseId": "CC-BY-4.0",
      "preamble": ["Asset by Example Author. Changes: converted to MP3."]
    }
  ],
  "sourceUrl": "https://example.com/source",
  "bundles": ["assets", "desktop-qt"]
}
```

Each `generatedNotices` item names an SPDX license template and can add `copyrights` or a short
`preamble` for attribution and provenance. Multiple items are joined into one row for software
that vendors separately licensed code. Keep `noticeFile` or `noticeFiles` only when a vendored
source tree already carries an intrinsic license file that should remain beside it. Paths are
relative to the config file. `bundles` controls which generated manifests include the entry and
supplies the label shown to users. Use `includeInBundles` when those differ, such as an optional
device tool the MC installs on demand: it appears in the desktop manifest but is not bundled into it.

Use `packageOverrides` only when an installed npm archive omits its notice or has incorrect
metadata:

```json
{
  "name": "package-name",
  "version": "1.2.3",
  "generatedNotice": {
    "licenseId": "MIT",
    "copyrights": ["Copyright (c) 2026 Example Author"]
  },
  "license": "MIT",
  "sourceUrl": "https://example.com/package-name"
}
```

For packages containing separately licensed code, use `generatedNotices` with an array of templates instead of `generatedNotice`. The generator includes every notice in the package row.

`version`, `license`, and `sourceUrl` are optional. Omitting `version` applies the override to every
installed version of that package. An override can use `repositoryUrl` instead of `name` when
several packages from one monorepo share the same notice:

```json
{
  "repositoryUrl": "https://github.com/example/project",
  "generatedNotice": {
    "licenseId": "Apache-2.0"
  }
}
```

The generator also reuses an installed sibling package's notice when both packages declare the
same normalized repository and license. A name-and-version override always wins over these
repository fallbacks.

Fetched SPDX templates live under the repository `.generated/` directory, which is ignored. Do not commit or edit it;
updating dependencies or configuration is enough for the next strict build to refresh the output.
