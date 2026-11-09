# Context handoffs

Portable provider and fork handoffs are textual transcripts. They do not claim native provider
context parity. [`HalC2.Orchestration.Handoff`](../../apps/server-ex/lib/hal_c2/orchestration/handoff.ex)
builds them and documents what a transcript holds: run by run, what was said, each command the
agent ran with how it ended, the user's answers to its questions and the files the run changed.
Reasoning, other tool calls and attachments stay behind.

Who said a thing is part of it. Most messages with the user's role are not the user's: the MC's
wakes and delegated results carry a `notification` and are handed over as notices, and a message
another thread's agent sent (`createdBy: "agent"`) is said as that agent's. Labelling them `User:`
made the next agent take a worker's report for an instruction.

An over-long transcript gives way in a fixed order, because the user's words are the one thing
the next agent cannot recover by reading the repository: first what the agent did (older runs
condensed to their command outcomes, files and final answer, then to their requests), then what
other agents sent, then the runs with none of the user's words, and only then what the user said
(cut in the middle, marked) and the remaining runs. The first run, which holds the task (a
worker's brief counts as the user's words), and the newest stay. The newest run's own work is the
exception to the order: it is what the next agent picks up, so room for its last step, cut short,
is held back before anything older is shown or the user's words are cut. A note ahead of the runs says
what was condensed, cut or left out. Measured on real threads, this keeps every user request whole
where the old newest-first fill kept a fifth of them; `prop/hal_c2/handoff_history_prop_test.exs`
holds the order on large threads, and
[`proof/models/handoff_history.maude`](../../apps/server-ex/proof/models/handoff_history.maude)
at every budget over small ones, where a law can break in a window a few characters wide.

A provider thread gets either the full eligible history or only the runs it missed since it last
took part. Fork merge-back handoffs carry the child's eligible work, prepared when it was merged.
Neither path reconstructs provider-native session state, tool state, approvals, or text a condensed
transcript left out.

"Took part" means the provider was seen to take the prompt, not that a prompt was sent. A run
that hands history over marks its provider thread until the provider confirms that same run:
it says it started the turn (Codex answering `turn/start`, Claude starting the prompt's
command, Muse's `turn/started`), or, for a provider that never says so (Pi, ACP), it sends
its first output or completes the turn. A confirmation that arrives after a newer run set
its own mark leaves that mark. While a mark stands, the next run starts a new conversation
with the whole thread, because a prompt can be lost after the MC moved on. Even a
confirmation comes before the provider has stored the prompt, so a provider that crashes
right after confirming can still lose it. A runtime that finds its conversation gone and
opens a new one with the whole thread (`Handoff.fresh_start/2`) marks it the same way.

A new conversation is a new session: the MC lets go of the runtime first. That includes a
provider thread with no conversation id, because its last run may have opened one and failed
before the id was recorded, leaving that conversation holding a prompt the MC cannot account
for.

A run also starts a new conversation when its handoff would not fit the resumed one. The fit is
checked against the newest usage report from that conversation, plus a reserve for each turn
sent since. The window is the newest one any report from the provider thread named, because
some reports (Claude's count after compacting) name none. So every adapter must record usage on
the run's `provider-turn`: a report kept only on the provider thread cannot say which run it
counts.

A message is refused only when its text alone, with the reserve, exceeds a window the provider
reported. The window assumed for a provider that never reported one is a guess, and what
attachments take is an estimate: an image a fixed share, a file (sent as its path) its size up
to a cap. Both still shape how much history fits.

A conversation is never replaced while its background work runs. An unconfirmed handoff goes
into it again: the runs after the one through which it was known to hold the thread
(`unconfirmedSince`). A handoff with no room is refused as busy. A run refused before it
reached a provider is in no later handoff.

A wake, and `/compact` or `/logout`, hands nothing over and leaves the provider thread's place
and mark alone. Text in front of a command would hide it from the provider, and a wake sends no
words. What the provider missed goes with the next run that sends it words. A command that is
its provider's first run in the thread hands nothing over either: its new provider thread has
seen no run (`lastRunOrdinal` 0), so the next run that sends words hands over the whole
thread. A bare `/compact` there has no conversation to compact and is refused before it reaches
the provider, unless a fork carries one over (`compact_refusal/5` in `orchestration.ex`). A
command on a provider thread whose conversation is gone, or that another instance held, is not
quiet: like any message, it is handed the thread. Which other slash commands are commands depends on where the
provider reads one (#1342). An ACP agent reads one only at the start of its prompt, and Pi a
prompt template, so there every slash command is quiet the same way. A command that starts
work needs the history, though: Claude runs one from the last block of a message, so its history
goes in a block of its own ahead of it. Pi runs `/skill:` commands from the start, so its
history follows them as their words. The turn keeps what it hands over apart from the user's
text (`Handoff.ahead/2`), and only the user's text is read for `$skill` mentions. These rules
are model-checked in
[`proof/models/provider_handoff.maude`](../../apps/server-ex/proof/models/provider_handoff.maude).

A thread imported from the version 1 orchestrator uses a separate algorithm. It considers only
user and assistant messages, walks backward from the newest message, and builds a transcript
suffix within a 32,000-character budget. Do not describe that import budget as the limit for
portable handoffs.
