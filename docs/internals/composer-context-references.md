# Composer context references

> For maintainers. Using HAL-C2? See [docs/user](../user/).

Inline context references let a user message point at a typed payload from an exact position in
its prose: an image, a file, a terminal excerpt, a picked page element, a preview annotation, a
review comment, a file mention, or a skill. This document covers the wire contract and the codecs the MC and the clients share.

## Two linked concepts

- A **context record** is the payload. It lives in `message.context.records`, keyed by a
  `contextId`. Records never contain bytes: image and file records bind to an existing
  `ChatAttachment` by id.
- A **context reference** is one occurrence in the document. It is a Markdown link in
  `message.text` that carries only the kind and the `contextId`. Two references can point at one
  record. A reference's label is display text and never identity.

[`composerContext.ts`][contract] defines version 1 of the record union. Every record has
`version`, `contextId`, `kind`, and `label`, plus kind-specific fields with bounded lengths. The
union is open: a kind this build does not know decodes to `UnknownContextRecord` with its
`payload` preserved, and known kinds are excluded from that member so a malformed image record
fails its own schema rather than sliding through unchecked. `OrchestrationMessageContext` wraps
the records with `ForwardCompatibleArray`, so one undecodable record is dropped instead of failing
the whole message. The MC stores the field with the message and does not interpret it until it
projects the text for a provider.

## Identity namespaces

- `ComposerContextId`: durable payload identity. Branded. Values match `[a-z0-9_-]+` and do not
  require a `ctx_` prefix.
- `ComposerContextReferenceId` (`ref_…`): one document occurrence. Lives in a client's editor
  state, not on the wire, and is regenerated when canonical Markdown is reparsed.
- `ChatAttachmentId`: the existing server-owned attachment resource. A record's `attachmentId` is
  a binding, not the chip's identity, so upload normalization can rename the resource without
  rewriting references.

Clients mint context and reference ids; shared code does not.

## Canonical reference syntax

[`composerContextReferences.ts`][shared] owns the grammar:

```text
[label](hal-c2-context://v1/<kind>/<contextId>)
![label](hal-c2-context://v1/image/<contextId>)
```

The parser accepts exactly the `hal-c2-context:` scheme, the `v1` host, one kind segment matching
`[a-z][a-z0-9-]{0,39}`, and one id segment matching `[a-z0-9_-]{1,128}` case-insensitively. Query
strings, fragments, credentials, and extra segments are rejected. Labels are sanitized to survive
a Markdown link (no brackets or line breaks, at most 200 characters, never empty). Links that fail
to parse are ordinary text.

## Provider projection

[`HalC2.ComposerContext.for_provider/2`](../../apps/server-ex/lib/hal_c2/composer_context.ex) builds what the provider reads at turn start, so the persisted message stays readable:

1. Every reference becomes an in-place marker: `[Image: shot.png; ref=ctx_1]`.
2. A trailing `<hal_c2_context version="1">` envelope holds one `<context kind id>` entry per unique
   referenced id, in first-reference order. Records that are never referenced are not emitted.
   A referenced id with no record becomes `<context … unavailable="true"/>`. Mention and skill
   records produce a marker but no entry. Unknown kinds emit their payload as JSON.
3. Captured text is data: any `<` that would open or close `hal_c2_context` or `context` is escaped,
   so a terminal line or PR comment cannot forge a record.

Attachment bytes travel on the existing attachment channel; the envelope only carries metadata.
Text without references is returned unchanged.

[contract]: ../../packages/contracts/src/composerContext.ts
[shared]: ../../packages/shared/src/composerContextReferences.ts
