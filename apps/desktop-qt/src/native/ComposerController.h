#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QVariant>

#include <functional>
#include <optional>
#include <utility>

#include "ComposerModel.h"

#include "NativeController.h"

class McClient;
class NativeShell;
class ShellBridge;
class ShellStore;
class TimelineModel;

// The composer on the thread, new-thread draft or Space page the window shows
// (the route), against the MC: the draft itself (text, caret, model, options,
// modes, images, terminal excerpts, quoted replies), what the picker offers, the @ $ / suggestions, sending,
// follow-ups while a turn runs, stop, the thread's pending approvals and
// questions, and its proposed plan.
//
// Each thread keeps its draft here, saved on this machine (setStorePath) and
// the same in every window (NativeShell::common); a new thread's text is
// DraftController's. The catalogue is the `providers` of
// the route environment's config (WorkspaceController::environmentConfig), so
// a thread elsewhere lists its own machine's models. A new thread's first send
// launches it (`orchestration.launchThread`) in the checkout WorkspaceController
// picked, or in another machine's checkout of the repository when the MC
// places it there (`hal-c2.placeThread`, load balancing), and the window moves
// to the thread in the draft's place; a background send launches it and
// leaves the draft ready for another prompt.
//
// A send is kept with the drafts until the MC answers it. One the app quit or
// crashed on comes back as its draft after the restart, once the thread's
// messages (a new thread's: whether it exists) show the MC never got it,
// unless a newer user message is in the thread; into a draft with newer
// typing it waits behind a toast's "Restore prompt" instead.
//
// Publishes `composer` (ShellComposerState in packages/contracts/src/shell.ts;
// null with no thread or draft open), `modelPicker` (ShellModelPickerState)
// and `turn`, the route thread's requests for the request bricks:
//   {threadKey, kind: "thread", running,
//    approvals: [{requestId, title, appName, detail, options: [{decision, label,
//      warning}], canRespond, responding, problem}],
//    questions: [{requestId, questions: [{id, header, question, options:
//      [{label, description}], multiSelect, allowCustomAnswer}], canRespond,
//      responding, problem}],
//    plan: {id, title, markdown} | null,  // offered while the thread is idle
//    queue: [{runId, messageId, text, pending}], waiting: [{runId, summary,
//      outcome}],
//    queueHeld, queueResuming,  // the MC keeps the queue until it is resumed
//    queueBusy,  // a remove or send-now the MC has not answered: one at a time
//    queueEditBlocked}  // why queued messages cannot be edited now, or ""
// A `pending` queue entry is a send the MC has not confirmed yet: listed, but
// with nothing to act on.
// `problem` says why a request cannot be answered, when it cannot. On a new
// thread's draft route the turn is {threadKey: draftId, kind: "draft",
// sending} with nothing pending; `sending` while its first send
// is on the way.
//
// `composer.edit` is the brick's last edit ({clientId, revision}) the shell
// applied: the brick adopts published text only when it answers its newest
// edit, so its own typing is never overwritten by an older echo, while the
// shell's changes (a suggestion, a cleared send, a restored failure) land.
//
// A Space page (SpaceController::promptPage) has a draft of its own too,
// keyed pageKey(pageId), which no thread key or draft id can be. Its prompt
// writes on the page: plain text goes to the page's bricks as
// `space.prompt.write` {pageId, text} (the page decides the kind of block and
// clears the prompt), and `@agent …` asks an agent to work on the page
// (SpaceController::askAgent) with the prompt's model, options, modes,
// attachments and the project picked for it (`composer.project.set
// {projectId}`, else the MC's `space.page.agentTarget`); a refused ask keeps
// everything. Stop stops the page's agent. A page's composer has no checkout,
// queue, follow-ups, several models or excerpts. `composer.ask` starts an ask
// in the page's prompt, ahead of what is there.
//
// The Space's images (SpaceController::imagesShown, with no thread, draft or
// page open) have a prompt of their own too, keyed imagesKey(spaceId), routeKind
// "images": its words are what the image should show, and a send generates one
// (`space.image.generate`) with the image model picked for it. The model picker
// offers only the image models of the providers that can make an image
// (`space.image.providers`, asked each time the images open); a send is busy
// while an image is being made. It has no options, modes, attachments,
// excerpts, checkout or queue.
//
// Actions: composer.text.set {target, text, cursor, edit},
// composer.suggest.select {id}, composer.suggest.dismiss,
// composer.model.select {instanceId, model},
// composer.model.favorite.toggle {instanceId, model},
// composer.model.multiple.toggle {instanceId, model} (a new thread's prompt
// goes to each model so chosen),
// composer.option.set {id, value}, composer.runtimeMode.set {mode},
// composer.interactionMode.set {mode}, composer.submit {text, intent, edit},
// composer.interrupt, composer.attach {files, folders} (a file is {name,
// mimeType, base64} for an image, {name, mimeType, path} for any other file,
// {name, text} for a pasted text), composer.attachment.remove {id},
// composer.attachment.retry {id}, composer.question.attach {requestId,
// questionId, files}, composer.question.attachment.remove {id},
// composer.terminalContext.add {terminalId, terminalLabel, lineStart, lineEnd,
// text}, composer.terminalContext.remove {id},
// composer.reviewComment.add {filePath, lineStart, lineEnd, text, diff,
// startIndex, endIndex, rangeLabel, sectionId, sectionTitle},
// composer.reviewComment.remove {id},
// composer.citation.add {messageId, text, start, end, prefix, suffix},
// composer.citation.comment {id, comment}, composer.citation.remove {id},
// composer.approval.respond {requestId, decision},
// composer.question.answer {requestId, answers}, composer.question.dismiss
// {requestId}, composer.plan.implement, composer.queue.remove {runId},
// composer.queue.steer {runId?} (the first queued without one; on a stopped
// thread it sends the message now, `queued-run.start`),
// composer.queue.edit {runId?} (the last queued without one),
// composer.queue.edit.cancel, composer.queue.resume (a held queue),
// composer.stash, composer.stash.restore {id},
// composer.stash.delete {id}, composer.stash.menu {open?} (toggles without),
// composer.history.step {direction: "backward" | "forward"}.
//
// The stash is this machine's, not a thread's:
// the prompts set aside with composer.stash, newest first, at most 20, kept
// with the drafts and the same in every window. Stashing an empty draft
// brings back the only entry, or opens the list. Publishes `composerStash`:
// {entries: [{id, snippet, createdAt}], open, shortcut}, `open` being this
// window's.
//
// A note on a diff's lines is a chip too (`composer.reviewComments`: {id,
// label "src/cart.ts L10-12", filePath, lineStart, lineEnd, text}); a send
// names it in the text and carries it as a `review-comment` context record
// (packages/contracts/src/composerContext.ts).
//
// A terminal excerpt is a chip on the draft (`composer.excerpts`); a send appends an inline context link for each
// to the text and carries the excerpts as the message's `context` records,
// which the MC hands the provider (HalC2.ComposerContext).
//
// A quoted reply is a chip too (`composer.citations`: {id, text, comment}),
// an assistant citation: a selection of one of the thread's replies,
// with the user's comment on it. A send appends its
// `[Assistant quote](hal-c2-citation://v1/...)` link to the text, which holds
// the whole citation (AssistantCitation in packages/contracts).
//
// Editing a queued message puts its text and attachments in the thread's
// composer (`composer.editingQueuedRunId`; the message's attachments are
// listed with `sent`) and sets the thread's own draft, attachments included,
// aside; a send saves the edit (`queued-run.edit`, its text and, when they
// changed, its attachments) and cancelling gives the draft back. Saves go
// one at a time: one made while another is unanswered waits for it, and only
// the newest waits. A run that leaves the queue mid-edit ends it: a changed edit
// stays in the composer when the set-aside draft was empty, and is dropped
// with a toast otherwise.
class ComposerController : public QObject, public NativeController {
  Q_OBJECT

public:
  ComposerController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  // The model the window's thread or draft will send with: {instanceId, model}, empty with none ready.
  QJsonObject currentSelection() const { return selection(target()); }
  void activate() override;
  void preview() override;
  bool isActive() const { return m_active; }
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // A message sent with no connection waits on this machine to be sent, in
  // order, once its environment is connected again, instead of staying in the
  // draft behind a "Not connected" toast; and one a dropped connection left
  // unanswered is sent again (the MC carries a message id out once) rather
  // than given back. The phone's outbox (MobileApp); off on the desktop.
  // A waiting message shows in its thread's `turn.outbox`
  // ({messageId, text, attachments, sending}), and `composer.outbox.edit
  // {messageId}` pulls one back into the composer.
  void setWaitsOffline(bool on);
  // How long the outbox waits after a send the connection dropped before it
  // tries that thread again: each delay in turn, then the last one over and
  // over (1, 2, 4, 8, then 16 s).
  void setOutboxRetryDelays(const QList<int>& delays) { m_outboxDelays = delays; }
  QList<int> outboxRetryDelays() const { return m_outboxDelays; }

  bool handle(const QString& action, const QVariant& payload) override;
  void adopt(const QString& draftId, const QString& threadKey, const QString& text);
  // The draft's first send is on its way: it becomes its thread once the MC answers.
  bool launching(const QString& draftId) const { return m_launching.contains(draftId); }

  // Where the threads' drafts are kept; loads them from there.
  void setStorePath(const QString& path);
  // The thread's (or new thread's) draft text, as the composer last left it.
  QString draft(const QString& target) const;
  // The draft's terminal excerpts, with their text: {id, terminalId,
  // terminalLabel, lineStart, lineEnd, text}.
  QVariantList terminalContexts(const QString& target) const;
  // What the sidebar shows for a draft with something in it: the text's first
  // line, else how many attachments it carries; nothing for an empty draft.
  std::optional<QString> draftPreview(const QString& target) const;
  // The threads (keys) whose composer holds something unsent, the rows the
  // sidebar marks "Unsent draft".
  QSet<QString> unsentThreads() const;
  // Empties the thread's composer of its text, attachments and excerpts, in
  // every window (the sidebar's `thread.draft.discard`); its model and modes stay.
  void discardDraft(const QString& target);
  // An image (a snapshot) joins `target`'s draft: a thread key or a draft id.
  // `source` rides with it to the MC when set (ChatImageAttachment.source).
  void attachImage(const QString& target, const QString& name, const QString& mimeType, const QByteArray& bytes,
                   const QJsonObject& source = {});
  // The draft's images: {id, name, mimeType, sizeBytes, source}.
  QVariantList attachments(const QString& target) const;
  // Whether `target`'s draft has files still on their way to the MC, or a
  // send in flight that carries the draft's attachments.
  bool attachmentsPending(const QString& target) const;
  // The draft key of a Space page; never a thread key (env:id) or a draft id (a uuid).
  static QString pageKey(const QString& pageId) { return QStringLiteral("page#") + pageId; }
  // The draft key of a Space's images prompt.
  static QString imagesKey(const QString& spaceId) { return QStringLiteral("images#") + spaceId; }
  // More than one model is chosen for the draft, each to get a thread of its own.
  bool choseSeveralModels(const QString& draftId) const { return m_drafts.value(draftId).multipleModels.has_value(); }
  // Adds `text` after the route's draft, a space apart from what is there
  // (the Files tab's Add to chat); false with no thread or draft open.
  bool insertAtEnd(const QString& text);
  // A draft's attachment as this machine holds it, for a viewer: {id, name,
  // mimeType, url (an image's bytes as a data URL), text (a file's as captured,
  // when it is text this machine can read), truncated}; empty when it is gone.
  QVariantMap attachmentPreview(const QString& id);

signals:
  // The outbox will try `target` again in `delayMs`.
  void outboxRetryScheduled(const QString& target, int delayMs);

private:
  struct Attachment {
    QString id;
    QString name;
    QString mimeType;
    qint64 sizeBytes = 0;
    QString dataUrl;
    QJsonObject source;
    // A file (not an image) goes to the MC when it is added and the message
    // names the upload (`attachments.createUploadUrl`); an image goes with
    // its message (`assets.persistChatAttachments`).
    bool file = false;
    // Where a file's bytes are: a path on this machine, or a pasted text.
    QString path;
    QByteArray content;
    // A picked file as it was when added, up to what a viewer shows: the file
    // on disk may have changed since.
    QByteArray captured;
    bool capturedWhole = false;
    bool pastedText = false;
    // A file's upload: "uploading", "failed" (why, in `error`), or empty once
    // the MC has it as `remoteId` on `environmentId`.
    QString upload;
    QString error;
    QString remoteId;
    QString environmentId;
    // How much of an uploading file has gone, 0 to 1; negative while unknown.
    double progress = -1;
  };
  // The attachment `id` of any draft, answer, waiting send or send in flight;
  // null when it is gone.
  Attachment* findAttachment(const QString& id);
  // Runs `change` on every held copy of the attachment `id` (a draft's, an
  // answer's, a waiting send's, a send in flight's); how many there were.
  int updateAttachmentCopies(const QString& id, const std::function<void(Attachment&)>& change);
  // Sends a file's bytes to the environment `target` runs on.
  void uploadFile(const QString& id, const QString& environmentId);
  // The environment a thread's or a new thread's files go to.
  QString environmentOf(const QString& target) const;
  // Why the files keep a send (or `what`) waiting, toasted; false when none do.
  bool filesBlock(const QList<Attachment>& attachments, const QString& what);
  static QJsonArray fileRecords(const QList<Attachment>& attachments);
  static QJsonObject attachmentJson(const Attachment& attachment);
  static std::optional<Attachment> attachmentOf(const QJsonObject& kept);
  // What the composer shows of attachments; `previews` adds each image's
  // thumbnail (thumbnail(), kept in m_previews).
  QVariantList shownAttachments(const QList<Attachment>& attachments, bool previews = false) const;
  // A dropped folder becomes a path the prompt names, where the MC shares
  // this machine's folders.
  bool attachFolders(const QString& target, const QVariantList& folders);
  // Files for the answer to one question of a pending request.
  bool attachToAnswer(const QString& requestId, QString questionId, const QVariantList& files);
  // A terminal selection on the draft,
  // or with `citation` a quoted reply (AssistantCitation in
  // packages/contracts/src/assistantCitations.ts) and nothing else.
  struct Excerpt {
    QString id;
    QString terminalId;
    QString terminalLabel;
    int lineStart = 1;
    int lineEnd = 1;
    QString text;
    QJsonObject citation;
    // Set for a note on lines of a diff instead (a `review-comment` record):
    // {filePath, sectionId, sectionTitle, startIndex, endIndex, rangeLabel,
    // diff}; `text` is then the note and the lines are the file's.
    QJsonObject review;
    // Set for another thread carried as context instead (a `thread`
    // record): {environmentId, threadId, title}; its link is in the text.
    QJsonObject thread;
  };
  struct Draft {
    QString text;  // a new thread's is DraftController's
    int cursor = 0;
    // The brick's last edit applied here: {clientId, revision}.
    QVariant edit;
    // The suggestions were dismissed; they return once the text changes.
    bool dismissed = false;
    // Chosen in the composer; the thread's own otherwise.
    std::optional<QJsonObject> modelSelection;
    QString runtimeMode;
    QString interactionMode;
    // The model and mode came with a new thread from the thread it was
    // started on, not from a pick here; the next new thread replaces them.
    bool carried = false;
    // A new thread's prompt goes to each of these instead: one thread per
    // model, each in its own worktree.
    std::optional<QList<QJsonObject>> multipleModels;
    // A Space page's: the project an ask runs in, as picked.
    QString projectId;
    QList<Attachment> attachments;
    QList<Excerpt> excerpts;
  };
  // A prompt set aside (composer.stash), with what it carried.
  struct StashEntry {
    QString id;
    QDateTime createdAt;
    QString text;
    QList<Attachment> attachments;
    QList<Excerpt> excerpts;
  };
  struct Send {
    QString target;
    QString environmentId;
    QString threadId;
    QList<QJsonObject> commands;
    // Uploaded first; the message carries what the MC stored.
    QList<Attachment> attachments;
    // Given back with the text if the send fails.
    QList<Excerpt> excerpts;
    // The text to give back if the send fails; empty for none.
    QString prompt;
    QString messageId;
    // Feedback on, or the implementing of, a proposed plan.
    bool planFollowUp = false;
  };
  // A prompt on its way to the MC, kept with the drafts until the MC answers
  // it: one a quit, crash or dropped connection cut off comes back to its
  // draft once the MC is heard from again (reconcileUnsent), unless the MC has
  // it or the user has said something newer there since.
  struct Unsent {
    // The thread, or the new thread's draft.
    QString target;
    // The thread it goes to, or a draft's launch makes.
    QString thread;
    QString messageId;
    // The thread's newest user message when it was sent, or when its
    // messages came in after (empty for none); nothing until they are known.
    std::optional<QString> after;
    QString prompt;
    QList<Attachment> attachments;
    QList<Excerpt> excerpts;
    // A send to several models: each model's launch is kept under its id,
    // and the prompt comes back once, only if none of them started.
    QString batch;
    // Read back from before a restart, or its answer lost with the
    // connection: waiting to be reconciled.
    bool kept = false;
    // The shell snapshots in when its answer was lost: it is reconciled
    // against a newer one, not rows from before the drop.
    quint64 seen = 0;
    // A launch whose answer a drop took, as it was sent: asked again under
    // its command id, which the MC carries out once, if the shell after the
    // drop has no thread for it. Not kept across a restart.
    QJsonObject launch;
    // The outbox's (setWaitsOffline): the commands as they were written, the
    // mode changes ahead of the message, sent once the thread's environment
    // is connected, less those the MC has answered; and the draft's model and
    // modes, which a refusal gives back with the prompt.
    QList<QJsonObject> commands;
    QJsonObject choices;
    // Waiting its turn to be sent rather than on its way, and whether it ever
    // waited, which is what shows it in the thread's outbox.
    bool waiting = false;
    bool waited = false;
  };

  bool interrupt();
  bool submit(const QVariantMap& payload);
  // A new thread's first send: its images, then the thread with its message.
  bool submitDraft(const QString& draftId, const QVariantMap& payload);
  // Where a new thread starts: the user's pick (`environmentId`, `projectId`),
  // or the checkout the MC chooses in its place. `then` is called once.
  void place(const QString& environmentId, const QString& projectId, bool tied, const QString& instanceId,
             std::function<void(const QString& environmentId, const QString& projectId)> then);
  void launched(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                const QList<Excerpt>& contexts, const QString& threadKey, const std::optional<QString>& error);
  bool restoreLaunch(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                     const QList<Excerpt>& contexts);
  // The prompt to every chosen model: `input` is the launch for one, less
  // its thread, model and checkout.
  bool submitToModels(const QString& draftId, const QList<QJsonObject>& models, const QJsonObject& input,
                      const QJsonObject& strategy, const QString& environmentId, const QString& text,
                      const QList<Attachment>& attachments, const QList<Excerpt>& contexts);
  bool toggleMultipleModel(const QString& target, const QString& instanceId, const QString& model);
  // A background send's answer: a toast that opens the thread, or one that
  // gives the prompt back.
  void launchedInBackground(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                            const QList<Excerpt>& contexts, const QString& threadKey,
                            const std::optional<QString>& error);
  // The model a thread (its own) or a draft (the project's default) starts from.
  QJsonObject baseSelection(const QString& key) const;
  // What a new thread in the project starts with.
  QJsonObject newThreadSelection(const QString& environmentId, const QString& projectId) const;
  // The project's own default model: this device's override, else the project's. Empty when it has none.
  QJsonObject projectSelection(const QString& environmentId, const QString& projectId) const;
  // A new thread started from `from` (a thread's key or a draft's id) keeps its model and mode.
  void carryInto(const QString& draftId, const QString& from);
  QString newThreadRuntimeMode(const QString& projectId) const;
  QString defaultRuntimeModeOf(const QString& target) const;
  // The Space page on show, when no thread or draft is.
  QString openPage() const;
  bool onPage() const { return !m_pageId.isEmpty(); }
  // The project the page's ask runs in: picked, else the MC's default.
  QString pageProject() const;
  // Asks the MC where the page's ask would run, once it is connected.
  void askPageProject();
  // A page's send: an ask, or words for the page to write.
  bool submitPage(const QString& target, const QString& text);
  // `@agent` ahead of the page's prompt, and the keyboard to it.
  void startAsk();
  // Whether the page's agent is at work, which makes the send button stop it.
  bool pageAgentRunning() const;
  void followPage();
  // The Space whose images are on show, when no thread, draft or page is.
  QString openImages() const;
  bool onImages() const { return !m_imagesSpace.isEmpty(); }
  // The images prompt: the image model picked, else the MC's default; empty when
  // no provider is on offer to make one.
  QJsonObject imageSelection(const QString& target) const;
  bool selectImageModel(const QString& target, const QString& instanceId, const QString& model);
  // The images prompt's send: an image of what it says.
  bool submitImages(const QString& target, const QString& text);
  QVariantMap imagesComposerState() const;
  QVariantList imagePickerInstances() const;
  // The message and the mode changes before it; empty `text` implements the plan.
  bool sendTurn(const QString& target, const QString& text, const QString& mode, bool planFollowUp, bool fromDraft);
  void sendNext(const QString& target);
  // A toast whose "Restore prompt" gives the prompt back once the target's
  // draft is empty, and opens it.
  void offerRestore(const QString& target, const QString& title, const QString& description, const QString& restored,
                    const QList<Attachment>& attachments = {}, const QList<Excerpt>& contexts = {});
  // The MC answered the send: it is no longer kept.
  void forgetUnsent(const QString& messageId);
  // The connection dropped before the MC answered: the send is kept as one a
  // restart cut off, as the MC may or may not have it.
  void keepUnanswered(const QString& messageId, const QJsonObject& launch = {});
  // A launch the drop left unanswered and the shell does not show, again.
  void retryLaunch(const QString& messageId);
  // The kept sends from before a restart whose fate can now be told: a
  // thread's once its stream is live, a launch's once the shell knows
  // whether its thread exists. Sends still on their way take the open
  // thread's newest message as their `after` once it is known.
  void reconcileUnsent();
  // Sends the outbox's waiting messages of each thread whose environment is
  // connected, in the order they were written; drops those of a thread the
  // environment no longer has. One window drains it.
  void drainOutbox();
  // A send the connection dropped, or the MC is still sending: it and the ones
  // behind it wait again, with what the MC has not answered of them, and the
  // thread is tried again after the next delay.
  void waitAgain(const QString& target, const QList<Send>& sends);
  void forgetAnswered(const QString& messageId, const QJsonObject& command);
  // The outbox's messages of the route thread, for `turn.outbox`.
  QVariantList outboxState(const QString& target) const;
  // Pulls a waiting message back into the composer.
  bool editWaiting(const QString& target, const QString& messageId);
  // Drops a waiting send and what it had already uploaded for it.
  bool deleteWaiting(const QString& target, const QString& messageId);
  // A refused outbox send: its prompt ahead of what was typed since, with the
  // model and modes it was written with.
  void restoreRefused(const QString& target, const QList<Send>& sends, const QString& error);
  std::optional<QString> newestBefore(const QString& thread) const;
  static QJsonObject excerptJson(const Excerpt& excerpt);
  static Excerpt excerptOf(const QJsonObject& kept);
  // The send's commands in order; `done` has the first error and its detail.
  using Dispatched = std::function<void(const std::optional<QString>& error, const QJsonValue& detail)>;
  void dispatchAll(const Send& send, qsizetype index, Dispatched done);
  bool attach(const QVariantList& files);
  static QString thumbnail(const QString& dataUrl);
  // A terminal selection joins the route's draft; blank ones are dropped.
  bool addTerminalContext(const QVariantMap& selection);
  // A note on lines of a diff joins the route's draft (ThreadDiff::comment).
  bool addReviewComment(const QVariantMap& comment);
  // A selection of one of the route thread's replies joins its draft.
  bool addCitation(const QVariantMap& selection);
  // Whether a draft of `text` holds nothing but terminal excerpts whose text is
  // gone. It is not sent, and the user is told.
  bool stopForExpiredExcerpts(const QString& text, const Draft& draft);
  // Tells the user how many of `contexts` a send left out, for lack of their text.
  void warnOfExpiredExcerpts(const QList<Excerpt>& contexts);
  // The message text with a link per excerpt, note and quote, and the
  // excerpts' and notes' records as its `context`.
  static void withExcerpts(QJsonObject& message, const QList<Excerpt>& contexts);
  // Up and Down on the editor's edge lines walk the thread's sent prompts,
  // text only: back from an empty draft,
  // forward past the newest to an empty one. An edited recall is a draft.
  void stepHistory(const QString& target, bool backward);
  // Why the prompt cannot be sent as it is, or nothing: its length.
  static QString promptProblem(const QString& text);
  // Why a draft carrying this much cannot be sent (the contracts' attachment
  // and context limits), or empty when it can.
  static QString carryProblem(const QList<Attachment>& attachments, const QList<Excerpt>& contexts);
  bool stash(const QString& target);
  void restoreStash(const QString& target, const QString& id);
  void setStashOpen(bool open);
  QVariantMap stashState() const;
  bool respond(const QString& requestId, const QJsonObject& fields, const QString& failure);
  bool queueCommand(const QString& type, const QString& runId);
  bool resumeQueue();
  bool editQueued(const QString& target, QString runId);
  bool saveQueuedEdit(const QString& target, const QString& text);
  // Gives the set-aside draft back; `keepEdit` leaves the edit's text instead.
  void endQueuedEdit(bool keepEdit = false);
  // Ends an edit whose run is no longer queued.
  void recoverQueuedEdit(const QVariantMap& turn);

  // The thread the window shows (the shell's route), or empty.
  QString openThread() const;
  // The new-thread draft the window shows (DraftController's), or empty.
  QString openDraft() const;
  // The route's composer target: its draft id, or its thread when the shell
  // has the thread's row; empty otherwise.
  QString target() const;
  void carryDrafts();

  // The draft's text and caret; `edit` is the brick's, kept when invalid.
  void setText(const QString& target, const QString& text, int cursor, const QVariant& edit = {});
  // A standalone "/plan" or "/default": the mode changes and the text goes.
  bool slashMode(const QString& target, const QString& text);
  // A standalone "/usage-limits" on a provider that offers it: the provider's
  // limits show above the composer (`composer.usageLimits`) from what the
  // environment last reported, and nothing is sent to the agent.
  bool slashUsageLimits(const QString& target, const QString& text);
  // The limits "/usage-limits" opened, by thread or draft, until the next
  // message or `composer.usageLimits.dismiss`.
  QHash<QString, QVariantMap> m_usageLimits;
  void setInteractionMode(const QString& target, const QString& mode);
  bool selectModel(const QString& target, const QString& instanceId, const QString& model);
  // A send used this model: new threads start from it.
  void rememberModel(const QJsonObject& selection);
  bool setOption(const QString& target, const QString& id, const QVariant& value);
  bool stepEffort(const QString& target, int direction);
  static bool effortLocked(const QJsonObject& descriptor, const QString& text);
  bool selectSuggestion(const QString& target, const QString& id);
  // The suggestions for the caret, with the trigger they answer.
  QList<composer::Suggestion> suggestions(const QString& target, const std::optional<composer::Trigger>& trigger) const;
  // Searches the workspace for an @ query the menu has no answer for yet.
  void searchPaths(const QString& target);
  bool canSearchPaths(const QString& target) const;
  std::pair<QString, QString> searchPlace(const QString& target) const;
  std::optional<composer::Trigger> triggerOf(const QString& target) const;
  void refreshPathSearch();

  // The catalogue of the route's environment.
  void refreshCatalogue();
  const composer::Instance* instanceOf(const QJsonObject& selection) const;
  // The draft's model: chosen, the thread's (or project default's), else the
  // first ready instance's default.
  QJsonObject selection(const QString& target) const;
  // Plan mode needs the setting and a provider that has it.
  bool planModeOn(const composer::Instance* instance) const;
  void setThreadRuntimeMode(const QString& target, const QString& mode);
  void settleRuntimeModes();
  QString runtimeModeOf(const QString& target) const;
  QString interactionModeOf(const QString& target) const;
  QVariant setting(const QString& key) const;
  // False when the drafts and stash could not be written.
  bool save() const;
  // The other windows' composers show what this one changed in the drafts.
  void spread() const;
  bool running(const QString& target) const;
  // Whether the shown thread's provider can take a message into its running
  // turn (its session's `turns.supportsActiveSteering`); a provider that
  // cannot is only offered the queue. No session known reads as able.
  bool canSteerActive() const;
  void toast(const QString& title, const QString& description);
  void follow();
  void publish();
  void previewTurn();
  // publish() in every window's composer: what one window changed in the
  // shared state (Kept) the others show too.
  static void publishEverywhere(NativeShell* shell);
  QVariantMap turnState() const;
  // A sent image's signed address, asked of the thread's timeline when it has none yet.
  QString sentAddress(const QString& id) const;
  // What the composer shows of an edited queued message's own attachments.
  QVariantList shownSent() const;
  bool queueHeld() const;
  QVariant composerState(const QVariantMap& turn) const;
  QVariantMap pickerState() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  bool m_previewing = false;
  // What every window's composer keeps.
  struct Kept {
    QHash<QString, Draft> drafts;
    // Newest first.
    QList<StashEntry> stash;
    // The model last sent with on each provider instance, and the instance
    // last sent with: a new thread starts from them.
    QHash<QString, QJsonObject> lastModels;
    QString lastInstance;
    // The options last given to each model (instanceId + '\n' + slug):
    // picking a model again offers them back.
    QHash<QString, QJsonArray> modelOptions;
    // In the order they were sent.
    QList<Unsent> unsent;
    // Each target's send the MC answered last, which its stream may not have
    // brought yet when the next is sent.
    QHash<QString, QString> delivered;
    QString path;
    // The images last written beside the drafts (imagesPath), so a keystroke
    // does not rewrite them.
    QString images;
    // The threads whose `queue.resume` the MC has not answered: one request
    // at a time per thread, whichever window asks.
    QSet<QString> resuming;
  };
  // Where the drafts' images are kept: shell-composer-images.json beside them.
  QString imagesPath() const;
  Kept& m_kept;
  // This window's "Not connected: queue not resumed" toast, while it may still show.
  QString m_notConnectedToast;
  QHash<QString, Draft>& m_drafts;
  // Each thread's sends, the one in flight first: a thread sends one at a
  // time, in the order the user sent them.
  QHash<QString, QList<Send>> m_queues;
  // The outbox (setWaitsOffline): on, its retry delays, how many sends in a
  // row the connection dropped for each thread, and the threads waiting out
  // their delay; and the shell frame it waits for after a drop, which says
  // which threads are still there.
  bool m_waitsOffline = false;
  quint64 m_outboxSince = 0;
  QList<int> m_outboxDelays{1000, 2000, 4000, 8000, 16000};
  QHash<QString, int> m_outboxFailures;
  QSet<QString> m_outboxHeld;
  // The route thread (or draft) and its stream.
  QString m_thread;
  QString m_draftId;
  // The Space page on show instead, and the project its asks run in unless
  // one is picked (`space.page.agentTarget`).
  QString m_pageId;
  QString m_pageProject;
  bool m_pageProjectAsked = false;
  bool m_pageRunning = false;
  // The Space whose images are on show instead.
  QString m_imagesSpace;
  QPointer<TimelineModel> m_timeline;
  // Sent attachments whose address was asked of the timeline (sentAddress),
  // until it signs one; one it would not sign is not asked for again.
  mutable QSet<QString> m_sentAsked;
  QMetaObject::Connection m_timelineConnection;
  QMetaObject::Connection m_timelineStatus;
  QMetaObject::Connection m_timelineSigned;
  // The files attached to each question's answer, by request id then
  // question id; they go with the answer and stay out of the thread's draft.
  QHash<QString, QHash<QString, QList<Attachment>>> m_answerFiles;
  // Requests answered and waiting for the MC, and ones it said are gone.
  QSet<QString> m_responding;
  QSet<QString> m_closed;
  // An access change sent to the MC, until the thread's row holds it: once the
  // MC took it, the version of its rows that does.
  struct SettingMode {
    QString mode;
    bool accepted = false;
    QString mc;
    QString epoch;  // none from an MC that names no version
    qint64 rev = 0;
  };
  // By draft target.
  QHash<QString, SettingMode> m_settingMode;
  // Drafts whose first send is on the way.
  QSet<QString> m_launching;
  // The thumbnails of the draft images the composer has shown, by attachment id.
  mutable QHash<QString, QString> m_previews;
  QVariantMap m_published;
  QVariant m_publishedComposer;
  QVariantMap m_publishedPicker;
  QVariantMap m_publishedStash;
  // This window's stash list is open.
  bool m_stashOpen = false;
  QList<composer::Instance> m_catalogue;
  // The @ search the menu shows: its target, query and checkout, and what came back.
  struct PathSearch {
    QString target;
    QString query;
    QString environmentId;
    QString cwd;
    bool done = false;
    bool failed = false;
    QList<std::pair<QString, bool>> entries;
    int request = 0;
  };
  PathSearch m_paths;
  // The queued message the route thread's composer is editing, and the
  // thread's draft set aside for it.
  struct QueuedEdit {
    QString thread;
    QString runId;
    QString messageId;
    QString original;
    // The message's attachments still on it, as the MC holds them, and
    // whether any were taken off.
    QJsonArray sent;
    bool sentChanged = false;
    QString saved;
    int savedCursor = 0;
    QList<Attachment> savedAttachments;
    // Added images the MC has stored for the message, by draft id: a save
    // the MC refused reuses them rather than storing them again.
    QHash<QString, QJsonObject> stored;
    bool saving = false;
    // A save made while one is on its way, sent once it is answered.
    std::optional<QString> next;
  };
  std::optional<QueuedEdit> m_queuedEdit;
  // Threads with a queue action (remove, send now) the MC has not answered.
  QSet<QString> m_queueBusy;
  // The sent prompt the composer is showing again: its message and text.
  struct Recall {
    QString target;
    QString entryId;
    QString recalled;
  };
  std::optional<Recall> m_recall;
};
