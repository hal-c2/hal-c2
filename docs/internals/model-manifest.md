# Model manifest

The MC owns the [manifest](../../apps/server-ex/priv/model-manifest.json) and
[`HalC2.ModelManifest`](../../apps/server-ex/lib/hal_c2/model_manifest.ex) reads it. Every release
bundles the file, which allows offline startup, and the MC fetches the copy on `main` at boot and
when the user refreshes providers, so model metadata can change between releases. A failed fetch
or invalid data preserves the last usable manifest.

A newer bundle outranks the cached remote manifest by `updatedAt`, so a release can
correct model data before the next successful fetch. Bump `updatedAt` whenever the
file changes. Fetch time cannot establish which copy contains the newer edit.

Generic catalog data describes presentation and capabilities. Each provider owns
its dispatch mappings. Claude and Antigravity use the manifest for their built-in
catalogs. Adding a model with an existing capability profile is a JSON
edit; a new profile is needed only for a new capability combination. Codex still
gets its model list from its app server.

`currentModels` names the current model ids per provider. `providers.<kind>.models[].status`
classifies the models of a catalog the manifest carries.

Model data is schema-validated configuration. Tests should cover resolver, cache,
and provider semantics with synthetic model names, so adding a model never requires
tests that repeat the configuration.
