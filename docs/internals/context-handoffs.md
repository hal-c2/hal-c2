# Context handoffs

Portable provider and fork handoffs are textual transcripts. They do not claim native provider
context parity. [`HalC2.Orchestration.Handoff`](../../apps/server-ex/lib/hal_c2/orchestration/handoff.ex)
builds them and documents what a transcript holds: what was said and each command the agent ran
with how it ended. Reasoning, other tool calls and attachments stay behind, and anything left out
of an over-long transcript is left out whole.

A provider thread gets either the full eligible history or only the runs it missed since it last
took part. Fork merge-back handoffs carry the child's eligible work, prepared when it was merged.
Neither path reconstructs provider-native session state, tool state, approvals, or omitted text.

A thread imported from the version 1 orchestrator uses a separate algorithm. It considers only
user and assistant messages, walks backward from the newest message, and builds a transcript
suffix within a 32,000-character budget. Do not describe that import budget as the limit for
portable handoffs.
