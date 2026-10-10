# Assistant citations

Citations carry the selected excerpt and source identity in ordinary message text.
Drafts, clipboard copies, stashes, and sent messages keep that representation
without a separate citation store. The saved quote remains usable when its source
disappears or changes. The [shared format](../../packages/shared/src/assistantCitations.ts) uses
stable environment IDs without a connection origin, so moving between local, remote,
and tunnel connections does not change a citation's identity.

Source navigation is best effort. A text selector refers to rendered text after whitespace
normalization, measured in UTF-16 units. It cannot be applied to raw Markdown. The original
excerpt keeps its whitespace; normalization is only for locating it. Repeated text needs an
unambiguous context match, even if one occurrence still sits at the saved offsets. Guessing could
highlight the wrong claim.

Expand citations before dispatch to a provider: the MC does it in
[`HalC2.ComposerContext`](../../apps/server-ex/lib/hal_c2/composer_context.ex). Send the saved
excerpt without looking up the source, distinguish quoted reference material from the user's
comment, and leave persisted messages in their original form. Input limits apply after
expansion as well as before it. A draft that fits as encoded links can exceed the
provider limit once expanded.
