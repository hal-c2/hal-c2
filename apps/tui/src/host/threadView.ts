import type { OrchestrationThread, ProviderApprovalDecision } from "@hal-c2/contracts";
import type { PropertyMap } from "opentui-qml";

import {
  approvalKey,
  approvalTitle,
  derivePendingApprovals,
  PROVIDER_GONE,
  type PendingApproval,
} from "../approvals.ts";
import type { TuiClient } from "../connection.ts";
import { splitUnifiedDiff } from "../diffSplit.ts";
import { latestActionableProposedPlan } from "../proposedPlan.ts";
import type { Store, StoreState } from "../store.ts";
import { clip } from "../format.ts";
import { relativeTime, THEME, type Palette } from "../theme.ts";
import { revertableCheckpoints } from "../timeline.ts";
import {
  buildUserInputAnswers,
  derivePendingUserInputs,
  type PendingUserInput,
} from "../userInput.ts";
import { createAttachmentPreviews } from "./attachmentPreviews.ts";
import { buildImageViewerState, type TuiImageViewerState } from "./imageViewer.ts";
import type { TuiMode, TuiSize } from "./layoutState.ts";
import { memoryMutedThreads, type MutedThreadsStore } from "./mutedThreads.ts";
import type { PaletteCommand } from "./paletteState.ts";
import { chunk, styled } from "./styledText.ts";
import {
  nextThreadAlerts,
  OPEN_THREAD_ACTION,
  threadTransitions,
  type ThreadAlert,
} from "./notificationsState.ts";
import {
  buildTimelineState,
  checkpointDirPaths,
  EMPTY_TIMELINE_VIEW,
  TIMELINE_WINDOW_SIZE,
  type CellPixels,
  type TimelineState,
  type TimelineView,
} from "./timelineState.ts";

// The open thread's view state (port of the timeline, approval, question,
// plan, revert and diff parts of ChatView). Publishes `timeline`,
// `timelineScroll`, `approvals`, `userInput`, `threadHints`, `revert`, `diff`,
// `imageViewer` and `notifications`, and handles their actions.

/** Options a question panel shows at once, scrolled around the highlight. */
export const USER_INPUT_OPTION_WINDOW = 8;
/** How long a copied code block or table shows that it was copied. */
const COPIED_MARK_MS = 2000;

export interface ThreadViewOptions {
  readonly store: Store;
  readonly client: TuiClient;
  readonly state: PropertyMap;
  readonly mode: () => TuiMode;
  /** The host's mode switch; "compose" resolves through `composeMode`. */
  readonly setMode: (mode: TuiMode) => void;
  readonly nowMs: () => number;
  readonly palette?: Palette;
  /** The terminal draws inline images: load previews for image attachments. */
  readonly inlineImages?: boolean;
  /** Pixel size of a terminal cell, when known (sizes previews and the viewer). */
  readonly cellPixels?: () => CellPixels | null;
  /** The terminal size (the image viewer fills it). */
  readonly size: () => TuiSize;
  /** The composer's width (the question panel inside it clips to it). */
  readonly composerWidth?: () => number;
  /** The open question appeared, moved, or was set aside or answered. */
  readonly onQuestionChange?: () => void;
  /** The diff or image view opened or closed over the conversation pane. */
  readonly paneReplacedChanged?: () => void;
  /** This device's muted threads (default: kept for this run only). */
  readonly mutedThreads?: MutedThreadsStore | undefined;
  /** Put text on the terminal's clipboard; false when the terminal refuses. */
  readonly copyToClipboard?: ((text: string) => boolean) | undefined;
}

export interface ThreadView {
  /** Republish what changed between two store states. */
  readonly sync: (next: StoreState, prev: StoreState | null) => void;
  /** The conversation pane's width changed (layout). */
  readonly setPaneWidth: (width: number) => void;
  /** Handle a thread action; false when the action is not ours. */
  readonly dispatch: (action: string, payload: unknown) => boolean;
  /** "userInput" while a question waits for an answer, otherwise "compose". */
  readonly composeMode: () => TuiMode;
  /** The conversation pane was resized (the image viewer refits). */
  readonly resize: () => void;
  /** The diff or image view has the conversation pane. */
  readonly paneReplaced: () => boolean;
  /** Open the diff viewer on a diff that is not a checkpoint's (a base ref compare). */
  readonly showReview: (review: DiffReview) => void;
  /** The user stopped this turn from this client. */
  readonly turnInterrupted: (turnId: string) => void;
  /** Stop the timers the view started. */
  readonly dispose: () => void;
  /** The open thread's palette entries (copy the reply, …). */
  readonly paletteCommands: () => PaletteCommand[];
  /** Resolves once attachment links and previews asked for so far have landed. */
  readonly settled: () => Promise<void>;
  /** The question the composer shows (open, not set aside): how many options it lists. */
  readonly question: () => { readonly visibleOptions: number } | null;
}

interface QuestionState {
  readonly requestId: string | null;
  readonly deferred: boolean;
  readonly questionIndex: number;
  readonly optionIndex: number;
  readonly selections: Readonly<Record<string, ReadonlyArray<string>>>;
  readonly customAnswer: string;
}

const NO_QUESTION: QuestionState = {
  requestId: null,
  deferred: false,
  questionIndex: 0,
  optionIndex: 0,
  selections: {},
  customAnswer: "",
};

type DiffStatus = "loading" | "ready" | "empty" | "error";

interface DiffState {
  readonly open: boolean;
  /** 0 = all changes, 1..N = the revertable checkpoints (newest first). */
  readonly index: number;
  readonly focusPath: string | null;
  readonly view: "unified" | "split";
  readonly status: DiffStatus;
  readonly text: string;
  /** A diff another area asked for (a base ref compare) instead of a checkpoint's. */
  readonly review?: DiffReview | null;
}

/** A diff shown in the viewer that is not one of the thread's checkpoints. */
export interface DiffReview {
  /** The scope as the title names it: "main…feature/tax · no whitespace". */
  readonly label: string;
  readonly load: () => Promise<string>;
}

const CLOSED_DIFF: DiffState = {
  open: false,
  index: 0,
  focusPath: null,
  view: "unified",
  status: "loading",
  text: "",
};

const field = (payload: unknown, name: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[name]
    : undefined;

const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

const toggled = (set: ReadonlySet<string>, id: string): Set<string> => {
  const next = new Set(set);
  if (!next.delete(id)) next.add(id);
  return next;
};

export function createThreadView(options: ThreadViewOptions): ThreadView {
  const { store, client, state } = options;
  const palette = options.palette ?? THEME;

  let detail: OrchestrationThread | null = null;
  let page: StoreState["threadPage"] = null;
  let paneWidth = 1;
  let composerWidth = 0;
  /** The selected project's title while a project row (not a thread) is selected. */
  let projectHint: string | null = null;
  let view: TimelineView = EMPTY_TIMELINE_VIEW;
  let timeline: TimelineState | null = null;
  let pendingOlder: { readonly detailId: string; readonly rowCount: number } | null = null;
  let scrollSeq = 0;

  let approvals: PendingApproval[] = [];
  let approvalIndex = 0;
  /** The unanswerable request the user was last told about. */
  let toldGone: string | null = null;
  let questions: PendingUserInput[] = [];
  let question: QuestionState = NO_QUESTION;
  /** The request an answer is on its way for (blocks a second submit). */
  let answering: string | null = null;
  let revertIndex = 0;
  let revertConfirming = false;
  let diff: DiffState = CLOSED_DIFF;
  let diffRequest = 0;
  let alerts: ReadonlyArray<ThreadAlert> = [];
  let alertSeq = 0;
  let viewedThreadId: string | null = null;
  const mutedStore = options.mutedThreads ?? memoryMutedThreads();
  /** Threads that raise no alert on this device. */
  const muted = new Set(mutedStore.load());
  /** Turns the user stopped in this session: their work stays open once they settle. */
  const interruptedTurns = new Set<string>();
  /** The code block or table just copied, and the timer that clears the mark. */
  let copied: string | null = null;
  let copiedTimer: ReturnType<typeof setTimeout> | null = null;
  let imageViewer: TuiImageViewerState | null = null;
  const cellPixels = () => options.cellPixels?.() ?? null;
  const attachments = createAttachmentPreviews({
    client,
    inlineImages: options.inlineImages === true,
    onChange: () => publishTimeline(),
  });

  const activeQuestion = (): PendingUserInput | null => questions[0] ?? null;
  const questionOpen = () => activeQuestion() !== null && !question.deferred;
  const composeMode = (): TuiMode => (questionOpen() ? "userInput" : "compose");
  /** Enter or leave the question panel when the prompt has the keys. */
  const reconcileMode = () => {
    const mode = options.mode();
    if (mode === "compose" || mode === "userInput") options.setMode("compose");
  };
  const checkpoints = () => (detail ? revertableCheckpoints(detail.checkpoints) : []);

  // --- timeline -----------------------------------------------------------

  const shellThread = (threadId: string) =>
    store.getState().shell?.threads.find((thread) => thread.id === threadId) ?? null;
  const threadTitle = (threadId: string) => shellThread(threadId)?.title ?? null;
  /** The thread the open one is a subagent of, from the thread list's lineage. */
  const parentThread = () => {
    const lineage = detail ? shellThread(detail.id)?.lineage : null;
    if (lineage?.relationshipToParent !== "subagent" || !lineage.parentThreadId) return null;
    return {
      threadId: lineage.parentThreadId,
      title: threadTitle(lineage.parentThreadId) ?? "its parent thread",
    };
  };

  const publishTimeline = () => {
    timeline = buildTimelineState({
      detail,
      hasOlderTurns: page?.hasMore ?? false,
      loadingOlderTurns: page?.loadingOlder ?? false,
      approvalCount: approvals.length,
      view,
      openTurns: interruptedTurns,
      copied,
      threadTitle,
      parent: parentThread(),
      paneWidth,
      nowMs: options.nowMs(),
      palette,
      emptyHint: projectHint
        ? `${projectHint} — Enter to expand, then Alt+↑/↓ to pick a thread.`
        : "Select a thread to view its conversation.",
      attachments: attachments.get,
      cellPixels: cellPixels(),
    });
    state.set("timeline", timeline);
  };

  // --- image viewer --------------------------------------------------------

  const imageAttachment = (id: string) => {
    for (const message of detail?.messages ?? []) {
      const found = message.attachments?.find(
        (attachment) => attachment.type === "image" && attachment.id === id,
      );
      if (found) return found;
    }
    return null;
  };

  const viewImage = (id: string | null) => {
    const attachment = id === null ? null : imageAttachment(id);
    const image = attachment ? attachments.get(attachment.id).image : null;
    const wasOpen = imageViewer !== null;
    imageViewer =
      attachment && image
        ? buildImageViewerState({
            attachment,
            image,
            size: options.size(),
            cellPixels: cellPixels(),
          })
        : null;
    state.set("imageViewer", imageViewer);
    if (wasOpen !== (imageViewer !== null)) options.paneReplacedChanged?.();
  };

  const openImage = (id: unknown) => {
    if (typeof id !== "string") return;
    viewImage(id);
    if (imageViewer) options.setMode("imagePreview");
  };

  /** Close the viewer; the timeline under it never moved. */
  const closeImage = () => {
    if (!imageViewer) return;
    viewImage(null);
    if (options.mode() === "imagePreview") options.setMode("compose");
  };

  // --- clipboard -------------------------------------------------------------

  const copy = (text: string, label: string) => {
    const copied = options.copyToClipboard?.(text) ?? false;
    store.setStatus(
      copied ? `${label} copied.` : "Clipboard not supported by this terminal.",
      copied ? "success" : "error",
    );
    return copied;
  };

  /** Mark a code block or table as just copied; the mark clears itself. */
  const showCopied = (key: string) => {
    if (copiedTimer) clearTimeout(copiedTimer);
    copied = key;
    publishTimeline();
    copiedTimer = setTimeout(() => {
      copiedTimer = null;
      copied = null;
      publishTimeline();
    }, COPIED_MARK_MS);
    copiedTimer.unref?.();
  };

  /** The agent's latest finished reply, as it was written (its markdown). */
  const latestReply = () =>
    detail?.messages.findLast(
      (message) =>
        message.role === "assistant" && !message.streaming && message.text.trim().length > 0,
    ) ?? null;

  const paletteCommands = (): PaletteCommand[] => [
    ...(viewedThreadId !== null
      ? [
          {
            id: "mute-alerts",
            title: muted.has(viewedThreadId)
              ? "Unmute alerts for this thread"
              : "Mute alerts for this thread",
            keywords: "mute unmute alerts notifications",
            action: "thread.alerts.toggleMute",
          },
        ]
      : []),
    ...(latestReply()
      ? [
          {
            id: "copy-reply",
            title: "Copy reply",
            keywords: "clipboard markdown answer",
            action: "timeline.reply.copy",
          },
        ]
      : []),
  ];

  const requestScroll = (to: "top" | "bottom" | null, by = 0) => {
    scrollSeq += 1;
    state.set("timelineScroll", { seq: scrollSeq, to, by });
  };

  const setView = (next: Partial<TimelineView>) => {
    view = { ...view, ...next };
    publishTimeline();
  };

  const showOlder = () => {
    if (!detail || !timeline) return;
    if (timeline.windowStart > 0) {
      setView({ windowEnd: timeline.windowStart });
    } else if (page?.hasMore && !page.loadingOlder) {
      pendingOlder = { detailId: detail.id, rowCount: timeline.rowCount };
      client.loadOlderThreadTurns(detail.id as never);
    }
    requestScroll("top");
  };

  const showNewer = () => {
    if (!timeline) return;
    const end = Math.min(timeline.rowCount, timeline.windowEnd + TIMELINE_WINDOW_SIZE);
    setView({ windowEnd: end === timeline.rowCount ? null : end });
    requestScroll("top");
  };

  /** Once an older page lands, keep the window on the rows that arrived. */
  const settleOlderPage = () => {
    if (!pendingOlder || !timeline) return;
    if (pendingOlder.detailId !== detail?.id) {
      pendingOlder = null;
    } else if (timeline.rowCount > pendingOlder.rowCount) {
      const end = timeline.rowCount - pendingOlder.rowCount;
      pendingOlder = null;
      setView({ windowEnd: end });
      requestScroll("top");
    } else if (!page?.loadingOlder) {
      pendingOlder = null;
    }
  };

  const toggleDir = (turnCount: number, path: string) => {
    const collapsedDirs = new Map(view.collapsedDirs);
    collapsedDirs.set(turnCount, toggled(collapsedDirs.get(turnCount) ?? new Set(), path));
    setView({ collapsedDirs });
  };

  const toggleAllDirs = (turnCount: number) => {
    const all = checkpointDirPaths(detail, turnCount);
    const collapsed = view.collapsedDirs.get(turnCount) ?? new Set<string>();
    const allCollapsed = all.length > 0 && all.every((path) => collapsed.has(path));
    const collapsedDirs = new Map(view.collapsedDirs);
    collapsedDirs.set(turnCount, allCollapsed ? new Set() : new Set(all));
    setView({ collapsedDirs });
  };

  // --- approvals, questions, plan -----------------------------------------

  const publishApprovals = () => {
    const count = approvals.length;
    const index = Math.min(approvalIndex, Math.max(0, count - 1));
    const active = approvals[index] ?? null;
    const options = (active?.options ?? []).map((option) => ({
      decision: option.decision,
      label: option.label,
      key: approvalKey(option.decision),
      warning: option.warning ?? "",
    }));
    const canRespond = active !== null && !active.notResumable;
    state.set("approvals", {
      count,
      index,
      countText: count > 1 ? `${index + 1}/${count}` : "",
      // What kind of permission the selected request wants.
      title: active ? approvalTitle(active.requestKind) : "",
      items: approvals.map((approval, i) => ({
        requestId: approval.requestId,
        label: `${approval.requestKind}${approval.detail ? `: ${approval.detail}` : ""}`,
        active: i === index,
      })),
      options,
      // A provider's caution sits on the line of the option it is about.
      warnings: options
        .filter((option) => option.warning !== "")
        .map((option) => ({
          decision: option.decision,
          text: `⚠ ${option.key} ${option.label}: ${option.warning}`,
        })),
      canRespond,
      problem: active?.notResumable ? PROVIDER_GONE : "",
      hint: canRespond
        ? [
            ...(count > 1 ? ["↑/↓ select"] : []),
            ...options.map((option) => `${option.key} ${option.label}`),
          ].join(" · ")
        : "",
    });
    // Say once why a request cannot be answered.
    if (active?.notResumable && toldGone !== active.requestId) {
      toldGone = active.requestId;
      store.setStatus(PROVIDER_GONE, "error");
    }
  };

  const publishUserInput = () => {
    publishQuestion();
    options.onQuestionChange?.();
  };
  const publishQuestion = () => {
    const pending = activeQuestion();
    const current = pending?.questions[question.questionIndex] ?? null;
    if (!pending || !current) {
      state.set("userInput", { pending: false, active: false, deferred: false, options: [] });
      return;
    }
    const selected = question.selections[current.id] ?? [];
    const count = current.options.length;
    const start = Math.min(
      Math.max(0, question.optionIndex - USER_INPUT_OPTION_WINDOW + 1),
      Math.max(0, count - USER_INPUT_OPTION_WINDOW),
    );
    const total = pending.questions.length;
    // ComposerPendingUserInputPanel: labels clip to the composer, less its frame and marker.
    const labelRoom = Math.max(8, (options.composerWidth?.() ?? 64) - 8);
    state.set("userInput", {
      pending: true,
      active: !question.deferred,
      deferred: question.deferred,
      requestId: pending.requestId,
      header: current.header,
      question: current.question,
      questionIndex: question.questionIndex,
      count: total,
      countText: total > 1 ? `(${question.questionIndex + 1} of ${total})` : "",
      multiSelect: current.multiSelect,
      windowStart: start,
      options: current.options
        .slice(start, start + USER_INPUT_OPTION_WINDOW)
        .map((option, offset) => {
          const index = start + offset;
          const isSelected = selected.includes(option.label);
          const highlighted = index === question.optionIndex;
          const box = current.multiSelect
            ? isSelected
              ? "[x]"
              : "[ ]"
            : isSelected
              ? "(•)"
              : "( )";
          return {
            index,
            label: option.label,
            description: option.description,
            highlighted,
            selected: isSelected,
            text: `${highlighted ? "▸" : " "} ${box} ${option.label}`,
            line: styled(
              chunk(highlighted ? "▸ " : "  ", { fg: highlighted ? palette.accent : palette.dim }),
              chunk(`${box} `, { fg: isSelected ? palette.accent : palette.dim }),
              chunk(clip(option.label, labelRoom), {
                fg: highlighted ? palette.text : palette.dim,
              }),
            ),
          };
        }),
      customAnswer: question.customAnswer,
      headerLine: styled(
        chunk(`${current.header}  `, { fg: palette.accent }),
        total > 1
          ? chunk(`(${question.questionIndex + 1} of ${total})`, { fg: palette.dim })
          : null,
      ),
      questionLine: clip(current.question, labelRoom),
      hint: current.multiSelect
        ? "↑/↓ move · Space toggle · Enter submit · Esc defer"
        : "↑/↓ select · Enter submit · Esc defer",
      primaryActionLabel: "Submit answer",
    });
  };

  /** Key hints the thread adds to the prompt's own (^Y, ^A/^R, a set-aside question). */
  const publishHints = () => {
    const plan = detail ? latestActionableProposedPlan(detail) : null;
    const items = [
      ...(plan ? ["^Y implement"] : []),
      ...(approvals.length > 0
        ? [approvals.length > 1 ? "^A/^R approve (↑/↓)" : "^A/^R approve"]
        : []),
    ];
    const banner =
      activeQuestion() && question.deferred ? "⚠ question pending — ^U to answer" : null;
    state.set("threadHints", { items, text: items.join(" · "), banner });
  };

  const publishInteraction = () => {
    publishApprovals();
    publishUserInput();
    publishHints();
  };

  const setQuestion = (next: Partial<QuestionState>) => {
    question = { ...question, ...next };
    publishUserInput();
    publishHints();
    reconcileMode();
  };

  const activeApproval = () => approvals[Math.min(approvalIndex, approvals.length - 1)] ?? null;

  const APPROVAL_STATUS: Record<ProviderApprovalDecision, [string, string, string]> = {
    accept: ["Approving…", "Approved.", "Approval failed"],
    acceptForSession: ["Approving…", "Approved for this session.", "Approval failed"],
    acceptAlways: ["Approving…", "Always approved.", "Approval failed"],
    decline: ["Declining…", "Declined.", "Decline failed"],
    cancel: ["Cancelling…", "Request cancelled.", "Cancel failed"],
  };

  const answerApproval = (decision: ProviderApprovalDecision) => {
    const approval = activeApproval();
    if (!detail || !approval) return;
    if (approval.notResumable) {
      store.setStatus(PROVIDER_GONE, "error");
      return;
    }
    const [busy, done, failed] = APPROVAL_STATUS[decision];
    store.setStatus(busy, "busy");
    client.approve(detail.id as never, approval.requestId as never, decision).then(
      () => store.setStatus(done, "success"),
      (error) => store.setStatus(`${failed}: ${errorText(error)}`, "error"),
    );
  };

  const moveOption = (delta: number) => {
    const current = activeQuestion()?.questions[question.questionIndex];
    const count = current?.options.length ?? 0;
    if (count === 0) return;
    setQuestion({ optionIndex: (question.optionIndex + delta + count) % count });
  };

  const toggleOption = () => {
    const current = activeQuestion()?.questions[question.questionIndex];
    const option = current?.options[question.optionIndex];
    if (!current || !option) return;
    const selected = question.selections[current.id] ?? [];
    const next = current.multiSelect
      ? selected.includes(option.label)
        ? selected.filter((label) => label !== option.label)
        : [...selected, option.label]
      : [option.label];
    setQuestion({ selections: { ...question.selections, [current.id]: next } });
  };

  const submitAnswer = () => {
    const pending = activeQuestion();
    const current = pending?.questions[question.questionIndex];
    if (!detail || !pending || !current) return;
    // A typed answer wins; otherwise single choice takes the highlighted option.
    const custom = question.customAnswer.trim();
    let selections = question.selections;
    if (!current.multiSelect) {
      const answer = custom.length > 0 ? custom : current.options[question.optionIndex]?.label;
      if (answer !== undefined) selections = { ...selections, [current.id]: [answer] };
    }
    if ((selections[current.id]?.length ?? 0) === 0) {
      store.setStatus("Pick an option or type an answer first.", "info");
      return;
    }
    if (question.questionIndex < pending.questions.length - 1) {
      setQuestion({
        selections,
        questionIndex: question.questionIndex + 1,
        optionIndex: 0,
        customAnswer: "",
      });
      return;
    }
    if (answering === pending.requestId) return;
    const requestId = pending.requestId;
    answering = requestId;
    question = { ...question, selections };
    store.setStatus("Sending answer…", "busy");
    client
      .respondUserInput(
        detail.id as never,
        requestId as never,
        buildUserInputAnswers(pending.questions, selections),
      )
      .then(
        () => {
          if (question.requestId !== requestId) return;
          // Keep the answer until the stream resolves the request; set the
          // panel aside so it cannot be sent twice meanwhile.
          setQuestion({ deferred: true });
          store.setStatus("Answer sent.", "success");
        },
        (error) => {
          if (answering === requestId) answering = null;
          if (question.requestId === requestId) {
            store.setStatus(`answer failed: ${errorText(error)}`, "error");
          }
        },
      );
  };

  const implementPlan = () => {
    const plan = detail ? latestActionableProposedPlan(detail) : null;
    if (!detail || !plan) return;
    store.setStatus("Implementing plan…", "busy");
    client.implementPlan(detail, plan.id).catch((error: unknown) => {
      store.setStatus(`implement failed: ${errorText(error)}`, "error");
    });
  };

  // --- revert picker -------------------------------------------------------

  /** The revert picker as RevertMenu draws it: eight turns at most, the window ending at the selection. */
  const publishRevert = () => {
    const list = checkpoints();
    const open = options.mode() === "revert";
    const index = Math.min(revertIndex, Math.max(0, list.length - 1));
    const windowSize = 8;
    const windowStart = Math.min(
      Math.max(0, index - windowSize + 1),
      Math.max(0, list.length - windowSize),
    );
    const confirming = open && revertConfirming ? (list[index] ?? null) : null;
    state.set("revert", {
      open,
      index,
      // Set once a checkpoint is picked: the rollback waits for a second Enter.
      confirming: confirming?.checkpointTurnCount ?? null,
      title: confirming
        ? styled(
            chunk("revert ▸ ", { fg: palette.error }),
            chunk(`roll back to turn ${confirming.checkpointTurnCount}? This cannot be undone.`, {
              fg: palette.text,
            }),
          )
        : styled(
            chunk("revert ▸ ", { fg: palette.error }),
            chunk("pick a checkpoint — discards changes made after it", { fg: palette.dim }),
          ),
      hint: confirming ? "Enter roll back · Esc cancel" : "↑/↓ select · Enter revert · Esc cancel",
      emptyText: "No checkpoints to revert to yet.",
      rows: list.slice(windowStart, windowStart + windowSize).map((checkpoint, offset) => {
        const active = windowStart + offset === index;
        const fileCount = checkpoint.files.length;
        return {
          turnCount: checkpoint.checkpointTurnCount,
          active,
          text: styled(
            chunk(active ? "▸ " : "  ", { fg: active ? palette.accent : palette.dim }),
            chunk(
              `turn ${checkpoint.checkpointTurnCount} · ${fileCount} file${fileCount === 1 ? "" : "s"} · ${relativeTime(checkpoint.completedAt)}`,
              { fg: active ? palette.text : palette.dim },
            ),
          ),
        };
      }),
    });
  };

  const openRevert = () => {
    if (!detail) return;
    revertIndex = 0;
    revertConfirming = false;
    options.setMode("revert");
    publishRevert();
  };

  const closeRevert = () => {
    revertConfirming = false;
    options.setMode("compose");
    publishRevert();
  };

  /** Enter picks a checkpoint, then asks: a rollback cannot be undone. A second Enter does it. */
  const confirmRevert = () => {
    const checkpoint = checkpoints()[revertIndex];
    if (checkpoint && !revertConfirming) {
      revertConfirming = true;
      publishRevert();
      return;
    }
    closeRevert();
    if (!detail || !checkpoint) return;
    const turnCount = checkpoint.checkpointTurnCount;
    store.setStatus(`Reverting to turn ${turnCount}…`, "busy");
    client.revertCheckpoint(detail.id as never, turnCount).then(
      () => store.setStatus(`Reverted to turn ${turnCount}.`, "success"),
      (error) => store.setStatus(`revert failed: ${errorText(error)}`, "error"),
    );
  };

  // --- diff viewer -------------------------------------------------------

  const publishDiff = () => {
    const list = checkpoints();
    const checkpoint = diff.index > 0 ? list[Math.min(diff.index - 1, list.length - 1)] : null;
    const scopeLabel = diff.review
      ? diff.review.label
      : diff.index === 0
        ? "all changes"
        : `turn ${checkpoint?.checkpointTurnCount ?? "?"}`;
    const allFiles = diff.status === "ready" ? splitUnifiedDiff(diff.text) : [];
    const focused = diff.focusPath ? allFiles.filter((file) => file.path === diff.focusPath) : [];
    const files = focused.length > 0 ? focused : allFiles;
    const status: DiffStatus =
      diff.status === "ready" && files.length === 0 ? "empty" : diff.status;
    state.set("diff", {
      open: diff.open,
      scopeLabel,
      status,
      view: diff.view,
      focusPath: focused.length > 0 ? diff.focusPath : null,
      title: `diff · ${scopeLabel}`,
      header: `  ${files.length} file${files.length === 1 ? "" : "s"} · ${diff.view} · ↑/↓ view · s ${
        diff.view === "unified" ? "split" : "stacked"
      } · PgUp/PgDn scroll · Esc close`,
      message:
        status === "loading"
          ? "loading…"
          : status === "error"
            ? "failed to load diff"
            : status === "empty"
              ? "no changes in this turn"
              : "",
      files: files.map((file) => ({
        path: file.path,
        filetype: file.filetype ?? "",
        label: file.filetype ? `  · ${file.filetype}` : "",
        body: file.body,
      })),
    });
  };

  /**
   * Fetch the open scope's diff. `keep` leaves what is shown in place until
   * the new text arrives (a refresh), so the viewer keeps its scroll position.
   */
  const loadDiff = (keep = false) => {
    if (!detail || !diff.open) return;
    const list = checkpoints();
    const latestTurnCount = list.reduce((max, c) => Math.max(max, c.checkpointTurnCount), 0);
    const checkpoint = diff.index > 0 ? list[Math.min(diff.index - 1, list.length - 1)] : null;
    const request = diff.review
      ? diff.review.load()
      : diff.index === 0
        ? client.getFullThreadDiff(detail.id as never, latestTurnCount)
        : checkpoint
          ? client.getTurnDiff(detail.id as never, checkpoint.checkpointTurnCount)
          : null;
    if (!(keep && request && diff.status === "ready")) {
      diff = { ...diff, status: request ? "loading" : "empty", text: "" };
      publishDiff();
    }
    if (!request) return;
    const id = ++diffRequest;
    request.then(
      (text) => {
        if (id !== diffRequest || !diff.open) return;
        diff = { ...diff, text, status: text.trim().length > 0 ? "ready" : "empty" };
        publishDiff();
      },
      () => {
        if (id !== diffRequest || !diff.open) return;
        diff = { ...diff, status: "error" };
        publishDiff();
      },
    );
  };

  const openDiff = (turnCount: number | null, path: string | null) => {
    if (!detail) return;
    const index =
      turnCount === null
        ? -1
        : checkpoints().findIndex((checkpoint) => checkpoint.checkpointTurnCount === turnCount);
    const wasOpen = diff.open;
    diff = {
      ...diff,
      open: true,
      index: index >= 0 ? index + 1 : 0,
      focusPath: path,
      review: null,
    };
    if (!wasOpen) options.paneReplacedChanged?.();
    options.setMode("diff");
    loadDiff();
  };

  /** Open the viewer on a diff from elsewhere (a compare against a base ref). */
  const showReview = (review: DiffReview) => {
    if (!detail) return;
    const wasOpen = diff.open;
    diff = { ...diff, open: true, index: 0, focusPath: null, review };
    if (!wasOpen) options.paneReplacedChanged?.();
    options.setMode("diff");
    loadDiff();
  };

  const moveDiff = (delta: number) => {
    const count = checkpoints().length + 1;
    diff = {
      ...diff,
      index: (diff.index + delta + count) % count,
      focusPath: null,
      review: null,
    };
    loadDiff();
  };

  const closeDiff = () => {
    diffRequest += 1;
    const wasOpen = diff.open;
    diff = { ...CLOSED_DIFF, view: diff.view };
    if (wasOpen) options.paneReplacedChanged?.();
    options.setMode("compose");
    publishDiff();
  };

  // --- notifications -------------------------------------------------------

  const publishNotifications = () => {
    state.set("notifications", {
      items: alerts.map(({ threadId: _threadId, ...notification }) => notification),
    });
  };

  const dismissAlert = (id: unknown) => {
    const next = alerts.filter((alert) => alert.id !== id);
    if (next.length === alerts.length) return;
    alerts = next;
    publishNotifications();
  };

  // --- sync ------------------------------------------------------------------

  const sync = (next: StoreState, prev: StoreState | null) => {
    const selectedThreadId = next.selection?.kind === "thread" ? next.selection.id : null;
    const selectedProject =
      next.selection?.kind === "project"
        ? (next.shell?.projects.find((project) => project.id === next.selection?.id)?.title ?? null)
        : null;
    if (next.shell && prev?.shell !== next.shell) {
      alerts = nextThreadAlerts(
        alerts,
        threadTransitions(prev?.shell?.threads ?? null, next.shell.threads).filter(
          (transition) => !muted.has(transition.thread.id),
        ),
        selectedThreadId,
        () => `thread-alert:${++alertSeq}`,
      );
    }
    if (selectedThreadId !== viewedThreadId) {
      viewedThreadId = selectedThreadId;
      alerts = alerts.filter((alert) => alert.threadId !== selectedThreadId);
    }
    if (!prev || prev.shell !== next.shell || prev.selection !== next.selection) {
      publishNotifications();
    }

    if (selectedProject !== projectHint) {
      projectHint = selectedProject;
      if (!next.detail) publishTimeline();
    }

    if (prev && prev.detail === next.detail && prev.threadPage === next.threadPage) return;
    const threadChanged = (detail?.id ?? null) !== (next.detail?.id ?? null);
    detail = next.detail;
    page = next.threadPage;
    if (threadChanged) {
      view = EMPTY_TIMELINE_VIEW;
      pendingOlder = null;
      approvalIndex = 0;
      if (diff.open) closeDiff();
      if (options.mode() === "revert") closeRevert();
      closeImage();
      attachments.forgetFailures();
    }
    approvals = detail ? derivePendingApprovals(detail.activities) : [];
    approvalIndex = Math.min(approvalIndex, Math.max(0, approvals.length - 1));
    questions = detail ? derivePendingUserInputs(detail.activities) : [];
    const requestId = activeQuestion()?.requestId ?? null;
    if (requestId !== question.requestId) {
      question = { ...NO_QUESTION, requestId };
      answering = null;
    }
    publishTimeline();
    settleOlderPage();
    publishInteraction();
    if (options.mode() === "revert") publishRevert();
    reconcileMode();
  };

  const dispatch = (action: string, payload: unknown): boolean => {
    switch (action) {
      // Chords the prompt shares (^A, ^R, ↑/↓, ^U, ^Y, Space) decline when
      // there is nothing to act on, so the key reaches the focused field.
      case "approval.approve":
        if (approvals.length === 0) return false;
        answerApproval("accept");
        return true;
      case "approval.decline":
        if (approvals.length === 0) return false;
        answerApproval("decline");
        return true;
      // Offered only when the provider (or the default set) has the choice.
      case "approval.approveSession":
      case "approval.cancel": {
        const wanted: ReadonlyArray<string> =
          action === "approval.cancel" ? ["cancel"] : ["acceptForSession", "acceptAlways"];
        const option = activeApproval()?.options.find((entry) => wanted.includes(entry.decision));
        if (!option) return false;
        answerApproval(option.decision);
        return true;
      }
      case "approval.next":
      case "approval.previous": {
        if (approvals.length < 2) return false;
        const delta = action === "approval.next" ? 1 : -1;
        approvalIndex = (approvalIndex + delta + approvals.length) % approvals.length;
        publishApprovals();
        return true;
      }
      case "userInput.move": {
        const delta = Number(field(payload, "delta") ?? 1);
        moveOption(delta < 0 ? -1 : 1);
        return true;
      }
      case "userInput.toggle":
        if (!activeQuestion()?.questions[question.questionIndex]?.multiSelect) return false;
        toggleOption();
        return true;
      case "userInput.answer.set": {
        const text = field(payload, "text");
        question = { ...question, customAnswer: typeof text === "string" ? text : "" };
        publishUserInput();
        return true;
      }
      case "userInput.submit":
        submitAnswer();
        return true;
      case "userInput.defer":
        if (activeQuestion()) setQuestion({ deferred: true });
        return true;
      case "userInput.reopen":
        if (!activeQuestion() || !question.deferred || answering === question.requestId) {
          return false;
        }
        setQuestion({ deferred: false });
        return true;
      case "plan.implement":
        if (!detail || !latestActionableProposedPlan(detail)) return false;
        implementPlan();
        return true;
      case "timeline.showOlder":
        showOlder();
        return true;
      case "timeline.showNewer":
        showNewer();
        return true;
      case "timeline.scroll": {
        const to = field(payload, "to");
        requestScroll(
          to === "top" || to === "bottom" ? to : null,
          Number(field(payload, "by") ?? 0),
        );
        return true;
      }
      case "timeline.workGroup.toggle":
        setView({ expandedGroups: toggled(view.expandedGroups, String(field(payload, "id"))) });
        return true;
      case "timeline.fold.toggle":
        setView({ expandedFolds: toggled(view.expandedFolds, String(field(payload, "id"))) });
        return true;
      case "timeline.message.toggle":
        setView({ expandedMessages: toggled(view.expandedMessages, String(field(payload, "id"))) });
        return true;
      case "timeline.files.toggleDir":
        toggleDir(Number(field(payload, "turnCount")), String(field(payload, "path")));
        return true;
      case "timeline.files.toggleAll":
        toggleAllDirs(Number(field(payload, "turnCount")));
        return true;
      case "timeline.copy": {
        const text = field(payload, "text");
        const key = field(payload, "key");
        if (typeof text !== "string" || typeof key !== "string") return true;
        if (copy(text, String(field(payload, "label") ?? "Text"))) showCopied(key);
        return true;
      }
      case "timeline.table.toggle":
        setView({ collapsedTables: toggled(view.collapsedTables, String(field(payload, "key"))) });
        return true;
      case "timeline.reply.copy": {
        const reply = latestReply();
        if (reply) copy(reply.text, "Reply");
        return true;
      }
      case "image.open":
        openImage(field(payload, "id"));
        return true;
      case "image.close":
        closeImage();
        return true;
      case "link.open": {
        const url = field(payload, "url");
        if (typeof url === "string") store.setStatus(url, "info");
        return true;
      }
      case "diff.open": {
        const turnCount = field(payload, "turnCount");
        const path = field(payload, "path");
        openDiff(
          typeof turnCount === "number" ? turnCount : null,
          typeof path === "string" ? path : null,
        );
        return true;
      }
      case "diff.all":
        openDiff(null, null);
        return true;
      case "diff.toggleView":
        diff = { ...diff, view: diff.view === "unified" ? "split" : "unified" };
        publishDiff();
        return true;
      case "diff.next":
        moveDiff(1);
        return true;
      case "diff.previous":
        moveDiff(-1);
        return true;
      case "diff.close":
        closeDiff();
        return true;
      case "diff.refresh":
        // The same scope again, kept on screen while it loads.
        if (!diff.open) return false;
        loadDiff(true);
        return true;
      case "checkpoint.revert.open":
        openRevert();
        return true;
      case "checkpoint.revert.move": {
        const count = checkpoints().length;
        if (count > 0) {
          const delta = Number(field(payload, "delta") ?? 1) < 0 ? -1 : 1;
          revertIndex = (revertIndex + delta + count) % count;
          // Moving on to another checkpoint takes the question back.
          revertConfirming = false;
        }
        publishRevert();
        return true;
      }
      case "checkpoint.revert.confirm":
        confirmRevert();
        return true;
      case "checkpoint.revert.cancel":
        closeRevert();
        return true;
      case "thread.alerts.toggleMute": {
        if (viewedThreadId === null) return true;
        const title = detail?.id === viewedThreadId ? detail.title : "this thread";
        if (muted.delete(viewedThreadId)) {
          store.setStatus(`Alerts unmuted for ${title}.`, "success");
        } else {
          muted.add(viewedThreadId);
          // An alert already up for it goes with the mute.
          alerts = alerts.filter((alert) => alert.threadId !== viewedThreadId);
          publishNotifications();
          store.setStatus(`Alerts muted for ${title}.`, "success");
        }
        mutedStore.save([...muted]);
        return true;
      }
      case "notification.dismiss":
        dismissAlert(field(payload, "id"));
        return true;
      case "notification.action": {
        const alert = alerts.find((entry) => entry.id === field(payload, "id"));
        if (!alert) return true;
        dismissAlert(alert.id);
        if (field(payload, "actionId") === OPEN_THREAD_ACTION) {
          store.select({ kind: "thread", id: alert.threadId });
        }
        return true;
      }
      default:
        return false;
    }
  };

  publishDiff();
  publishRevert();
  state.set("imageViewer", imageViewer);

  return {
    sync,
    setPaneWidth: (width) => {
      const nextComposerWidth = options.composerWidth?.() ?? 0;
      if (nextComposerWidth !== composerWidth) {
        composerWidth = nextComposerWidth;
        publishQuestion();
      }
      if (width === paneWidth) return;
      paneWidth = width;
      publishTimeline();
    },
    dispatch,
    composeMode,
    resize: () => {
      if (imageViewer) viewImage(imageViewer.id);
    },
    paneReplaced: () => diff.open || imageViewer !== null,
    showReview,
    turnInterrupted: (turnId) => {
      interruptedTurns.add(turnId);
    },
    paletteCommands,
    dispose: () => {
      if (copiedTimer) clearTimeout(copiedTimer);
    },
    settled: attachments.settled,
    question: () => {
      const current = activeQuestion()?.questions[question.questionIndex];
      return current && !question.deferred
        ? { visibleOptions: Math.min(current.options.length, USER_INPUT_OPTION_WINDOW) }
        : null;
    },
  };
}
