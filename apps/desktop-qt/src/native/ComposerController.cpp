#include "ComposerController.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStringList>
#include <QUuid>

#include <algorithm>
#include <memory>

#include "DraftController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarModel.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {
const NativeControllerRegistrar<ComposerController> registrar(QStringLiteral("composer"), {QStringLiteral("turn")});

// apps/web/src/proposedPlan.ts PLAN_IMPLEMENTATION_PROMPT_PREFIX.
const QString kImplementPrefix = QStringLiteral("PLEASE IMPLEMENT THIS PLAN:\n");
// apps/web/src/components/chat/ComposerPendingApprovalPanel.tsx.
const QString kProviderGone = QStringLiteral("Provider process is gone — interrupt or restart the run to respond.");

QString str(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// apps/web/src/components/chat/ComposerPendingApprovalPanel.tsx fallbackLabel.
QString approvalTitle(const QString& kind) {
  if (kind == QLatin1String("mcp-elicitation")) return QStringLiteral("App access approval");
  if (kind == QLatin1String("command")) return QStringLiteral("Command approval");
  if (kind == QLatin1String("file-read")) return QStringLiteral("File read approval");
  if (kind == QLatin1String("permission")) return QStringLiteral("App permission approval");
  return QStringLiteral("File change approval");
}

// What the web offers when the provider names no options
// (ComposerPendingApprovalActions.tsx), the primary one first.
QVariantList defaultApprovalOptions() {
  const auto option = [](const QString& decision, const QString& label) {
    return QVariantMap{{QStringLiteral("decision"), decision}, {QStringLiteral("label"), label}};
  };
  return {option(QStringLiteral("accept"), QStringLiteral("Approve")),
          option(QStringLiteral("acceptForSession"), QStringLiteral("Always allow this session")),
          option(QStringLiteral("decline"), QStringLiteral("Decline")),
          option(QStringLiteral("cancel"), QStringLiteral("Cancel"))};
}

// apps/tui/src/proposedPlan.ts: the first heading, else "Proposed plan".
QString planTitle(const QString& markdown) {
  static const QRegularExpression heading(QStringLiteral("^\\s{0,3}#{1,6}\\s+(.+)$"),
                                          QRegularExpression::MultilineOption);
  const QString title = heading.match(markdown).captured(1).trimmed();
  return title.isEmpty() ? QStringLiteral("Proposed plan") : title;
}

// A respond failure that means the request is gone (the node's, and the
// providers' words apps/tui/src/staleRequest.ts lists): the request closes.
bool staleRequest(const QString& error) {
  const QString normalized = error.toLower();
  return normalized.contains(QLatin1String("no pending request")) ||
         normalized.contains(QLatin1String("stale pending")) || normalized.contains(QLatin1String("unknown pending"));
}

// The turn items of a kind, in timeline order.
QList<QJsonObject> itemsOf(const QHash<QString, QJsonObject>& items, const QString& type) {
  QList<QJsonObject> found;
  for (const QJsonObject& item : items) {
    if (str(item, QLatin1String("type")) == type) found.append(item);
  }
  std::sort(found.begin(), found.end(), [](const QJsonObject& a, const QJsonObject& b) {
    return a.value(QLatin1String("ordinal")).toDouble() < b.value(QLatin1String("ordinal")).toDouble();
  });
  return found;
}

// apps/web's new-thread title: the prompt, else the first image, cut to 50.
QString launchTitle(const QString& text, const QString& firstImage) {
  QString seed = text.trimmed();
  if (seed.isEmpty()) seed = firstImage.isEmpty() ? QStringLiteral("New thread") : QStringLiteral("Image: ") + firstImage;
  return seed.size() > 50 ? seed.left(50) + QStringLiteral("...") : seed;
}

QString newId() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}  // namespace

ComposerController::ComposerController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                       QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

void ComposerController::activate() {
  if (m_active) return;
  m_active = true;
  NativeShell* shell = NativeShell::of(this);
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, &ComposerController::follow);
  connect(shell->controller<ThreadStore>(), &ThreadStore::activeThreadChanged, this, &ComposerController::follow);
  // A draft the page opened becomes the shell's once DraftController adopts it.
  connect(shell->controller<DraftController>(), &DraftController::changed, this, &ComposerController::publish);
  // The row says whether a turn runs, which decides follow-ups and the plan.
  connect(m_store, &ShellStore::changed, this, &ComposerController::publish);
  follow();
}

bool ComposerController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  const QString target = this->target();
  const auto text = [&map] { return map.value(QStringLiteral("text")).toString(); };
  if (action == QLatin1String("composer.text.set")) {
    // A target the window has left: its last keystrokes are dropped.
    if (target.isEmpty() || map.value(QStringLiteral("target")).toString() != target) return true;
    setText(target, text(), map.value(QStringLiteral("cursor")).toInt(), map.value(QStringLiteral("edit")));
    return true;
  }
  if (action == QLatin1String("composer.suggest.select")) {
    if (!target.isEmpty()) selectSuggestion(target, map.value(QStringLiteral("id")).toString());
    return true;
  }
  if (action == QLatin1String("composer.suggest.dismiss")) {
    if (target.isEmpty()) return true;
    m_drafts[target].dismissed = true;
    publish();
    return true;
  }
  // Prompt history and terminal selections are not the shell's yet.
  if (action == QLatin1String("composer.history.step") || action == QLatin1String("composer.terminalContext.remove")) {
    return true;
  }
  if (action == QLatin1String("composer.model.select")) {
    if (!target.isEmpty()) {
      selectModel(target, map.value(QStringLiteral("instanceId")).toString(), map.value(QStringLiteral("model")).toString());
    }
    return true;
  }
  if (action == QLatin1String("composer.model.favorite.toggle")) {
    auto* settings = NativeShell::of(this)->controller<SettingsController>();
    if (!settings) return true;
    const QJsonArray favorites =
        composer::toggleFavorite(QJsonValue::fromVariant(settings->deviceValue(QStringLiteral("favorites"))),
                                 map.value(QStringLiteral("instanceId")).toString(), map.value(QStringLiteral("model")).toString());
    settings->writeDevice(QStringLiteral("favorites"), favorites.toVariantList());
    return true;
  }
  if (action == QLatin1String("composer.option.set")) {
    if (!target.isEmpty()) setOption(target, map.value(QStringLiteral("id")).toString(), map.value(QStringLiteral("value")));
    return true;
  }
  if (action == QLatin1String("composer.runtimeMode.set")) {
    if (target.isEmpty()) return true;
    const QString mode = map.value(QStringLiteral("mode")).toString();
    const QVariantList offered = composer::runtimeModes(instanceOf(selection(target)));
    const bool known = std::any_of(offered.cbegin(), offered.cend(), [&](const QVariant& entry) {
      return entry.toMap().value(QStringLiteral("value")).toString() == mode;
    });
    if (!known || mode == runtimeModeOf(target)) return true;
    m_drafts[target].runtimeMode = mode;
    save();
    publish();
    return true;
  }
  if (action == QLatin1String("composer.interactionMode.set")) {
    if (!target.isEmpty()) setInteractionMode(target, map.value(QStringLiteral("mode")).toString());
    return true;
  }

  if (action == QLatin1String("composer.interrupt")) return interrupt();
  if (action == QLatin1String("composer.submit")) return submit(map);
  if (action == QLatin1String("composer.attach")) return attach(map.value(QStringLiteral("files")).toList());
  if (action == QLatin1String("composer.attachment.remove")) {
    if (target.isEmpty()) return true;
    QList<Attachment>& attachments = m_drafts[target].attachments;
    const QString id = map.value(QStringLiteral("id")).toString();
    if (attachments.removeIf([&](const Attachment& attachment) { return attachment.id == id; }) > 0) publish();
    return true;
  }
  if (action == QLatin1String("composer.approval.respond")) {
    return respond(map.value(QStringLiteral("requestId")).toString(),
                   {{QStringLiteral("decision"), map.value(QStringLiteral("decision")).toString()}},
                   QStringLiteral("Failed to submit approval decision."));
  }
  if (action == QLatin1String("composer.question.answer")) {
    return respond(map.value(QStringLiteral("requestId")).toString(),
                   {{QStringLiteral("answers"), QJsonObject::fromVariantMap(map.value(QStringLiteral("answers")).toMap())}},
                   QStringLiteral("Failed to submit answers."));
  }
  if (action == QLatin1String("composer.question.dismiss")) {
    return respond(map.value(QStringLiteral("requestId")).toString(), {}, QStringLiteral("Failed to dismiss the question."));
  }
  if (action == QLatin1String("composer.plan.implement")) {
    if (!m_store->thread(target)) return true;
    return sendTurn(target, QString(), QStringLiteral("auto"), true, false);
  }
  if (action == QLatin1String("composer.queue.remove")) {
    return queueCommand(QStringLiteral("queued-run.cancel"), map.value(QStringLiteral("runId")).toString());
  }
  if (action == QLatin1String("composer.queue.steer")) {
    return queueCommand(QStringLiteral("queued-message.promote-to-steer"), map.value(QStringLiteral("runId")).toString());
  }
  return false;
}

// Stops the thread's active run, or the latest one while it still waits on
// the provider or background work, as client-runtime's interruptThreadTurn.
bool ComposerController::interrupt() {
  const auto thread = m_store->thread(openThread());
  if (!thread) return false;
  sidebar::Nullable runId = thread->activeRunId;
  if (!runId && (thread->activityRunStatus == QStringLiteral("waiting") || thread->pendingBackgroundTasks > 0)) {
    runId = thread->latestRunId;
  }
  if (!runId) return true;
  m_client->dispatchCommand(thread->environmentId,
                            {
                                {QStringLiteral("type"), QStringLiteral("run.interrupt")},
                                {QStringLiteral("threadId"), thread->id},
                                {QStringLiteral("runId"), *runId},
                            },
                            [this](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) {
                                toast(QStringLiteral("Failed to interrupt the current turn."), *error);
                              }
                            });
  return true;
}

// A send from the composer: the brick's text (else the draft's), with the
// draft's images, model and modes. A standalone "/plan" or "/default" only
// switches the mode. During a turn it follows the follow-up setting
// (`followUpBehavior`, steer by default), the alternate intent the other way;
// with the thread idle on a proposed plan it refines the plan (or implements
// it, with no text), as the web's resolvePlanFollowUpSubmission.
bool ComposerController::submit(const QVariantMap& payload) {
  const QString target = this->target();
  if (target.isEmpty()) return true;
  const QString text = payload.contains(QStringLiteral("text")) ? payload.value(QStringLiteral("text")).toString()
                                                                : draft(target);
  // The submit is the brick's newest edit, so it takes the cleared (or
  // restored) text as the answer to it.
  setText(target, text, int(text.size()), payload.value(QStringLiteral("edit")));
  if (slashMode(target, text)) return true;
  if (!m_draftId.isEmpty()) return submitDraft(target, payload);
  const bool hasImages = !m_drafts.value(target).attachments.isEmpty();
  const bool planFollowUp = !hasImages && turnState().value(QStringLiteral("plan")).isValid();
  if (text.trimmed().isEmpty() && !hasImages && !planFollowUp) return true;

  QString mode = QStringLiteral("auto");
  if (running(target)) {
    const bool queue = setting(QStringLiteral("followUpBehavior")).toString() == QLatin1String("queue");
    const bool alternate = payload.value(QStringLiteral("intent")).toString() == QLatin1String("alternate");
    mode = queue != alternate ? QStringLiteral("queue") : QStringLiteral("steer");
  }
  return sendTurn(target, text, mode, planFollowUp, true);
}

bool ComposerController::sendTurn(const QString& target, const QString& text, const QString& mode, bool planFollowUp,
                                  bool fromDraft) {
  const auto thread = m_store->thread(target);
  if (!thread) return false;
  // Nothing leaves while the node is out of reach: the draft stays as it is.
  if (!m_client->isReady() || !m_store->threadOnline(target)) {
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("Not connected: message not sent"),
        QStringLiteral("Reconnecting to the environment. Try again once it is connected."));
    return true;
  }
  const QString trimmed = text.trimmed();
  QJsonObject plan;
  if (planFollowUp) {
    plan = QJsonObject::fromVariantMap(turnState().value(QStringLiteral("plan")).toMap());
    if (plan.isEmpty()) return true;
  }
  const bool implement = planFollowUp && trimmed.isEmpty();

  const QString createdAt = sidebar::formatIso(m_now());
  const QString runtimeMode = runtimeModeOf(target);
  QString interactionMode = interactionModeOf(target);
  if (planFollowUp) interactionMode = implement ? QStringLiteral("default") : QStringLiteral("plan");
  QList<QJsonObject> commands;
  if (!runtimeMode.isEmpty() && runtimeMode != thread->runtimeMode) {
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.runtime-mode.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("runtimeMode"), runtimeMode},
        {QStringLiteral("createdAt"), createdAt},
    });
  }
  if (!interactionMode.isEmpty() && interactionMode != thread->interactionMode) {
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.interaction-mode.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("interactionMode"), interactionMode},
        {QStringLiteral("createdAt"), createdAt},
    });
  }
  QJsonObject message{
      {QStringLiteral("type"), QStringLiteral("message.dispatch")},
      {QStringLiteral("createdBy"), QStringLiteral("user")},
      {QStringLiteral("creationSource"), QStringLiteral("web")},
      {QStringLiteral("threadId"), thread->id},
      {QStringLiteral("messageId"), QUuid::createUuid().toString(QUuid::WithoutBraces)},
      {QStringLiteral("text"), implement ? kImplementPrefix + str(plan, QLatin1String("markdown")).trimmed() : trimmed},
      {QStringLiteral("attachments"), QJsonArray()},
      {QStringLiteral("titleSeed"), planFollowUp || trimmed.isEmpty() ? thread->title : trimmed},
  };
  const QJsonObject modelSelection = selection(target);
  if (!modelSelection.isEmpty()) message.insert(QStringLiteral("modelSelection"), modelSelection);
  if (implement) {
    message.insert(QStringLiteral("sourcePlanRef"),
                   QJsonObject{{QStringLiteral("threadId"), thread->id}, {QStringLiteral("planId"), str(plan, QLatin1String("id"))}});
  }
  // client-runtime startThreadTurn with a node that resolves the context.
  if (mode == QLatin1String("queue")) {
    message.insert(QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("queue_after_active")}});
  } else {
    message.insert(QStringLiteral("deliveryIntent"), mode);
    message.insert(QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("start_immediately")}});
  }
  commands.append(message);
  Draft& draft = m_drafts[target];
  if (planFollowUp) draft.interactionMode = interactionMode;

  // Implementing from the plan's own button leaves the draft alone.
  const QList<Attachment> attachments = fromDraft ? std::exchange(draft.attachments, {}) : QList<Attachment>();
  if (fromDraft) setText(target, QString(), 0);
  save();
  publish();

  // A send made while an earlier one is still in flight waits its turn.
  QList<Send>& queue = m_queues[target];
  queue.append({target, thread->environmentId, thread->id, commands, attachments, fromDraft ? text : QString()});
  if (queue.size() == 1) sendNext(target);
  return true;
}

// A new thread's first send, as the web's: its images are stored, then the
// thread is launched with the message in the draft's checkout. The draft (its
// text and images) stays until the node confirms; the window then shows the
// thread in its place. A background send (mod+alt+Enter) leaves the window on
// the draft, emptied for another prompt.
bool ComposerController::submitDraft(const QString& draftId, const QVariantMap& payload) {
  NativeShell* shell = NativeShell::of(this);
  auto* drafts = shell->controller<DraftController>();
  const auto kept = drafts->draft(draftId);
  if (!kept) return true;
  const bool background = payload.value(QStringLiteral("intent")).toString() == QLatin1String("background");
  const QString text = kept->text;
  QList<Attachment> attachments = m_drafts.value(draftId).attachments;
  if (text.trimmed().isEmpty() && attachments.isEmpty()) return true;
  if (m_launching.contains(draftId)) return true;

  const WorkspaceController::Launch where = shell->controller<WorkspaceController>()->launch(draftId);
  if (!where.problem.isEmpty()) {
    toast(QStringLiteral("Could not create thread"), where.problem);
    return true;
  }
  if (!m_client->isReady() || !m_store->environmentOnline(where.environmentId)) {
    shell->controller<ToastController>()->show(QStringLiteral("warning"), QStringLiteral("Not connected: message not sent"),
                                               QStringLiteral("Reconnecting to the environment. Try again once it is connected."));
    return true;
  }

  const QString trimmed = text.trimmed();
  const QJsonObject modelSelection = selection(draftId);
  QJsonObject input{
      {QStringLiteral("commandId"), newId()},
      {QStringLiteral("creationSource"), QStringLiteral("web")},
      {QStringLiteral("threadId"), kept->threadId},
      {QStringLiteral("projectId"), where.projectId},
      {QStringLiteral("title"), launchTitle(trimmed, attachments.isEmpty() ? QString() : attachments.constFirst().name)},
      {QStringLiteral("generateTitle"), true},
      {QStringLiteral("runtimeMode"), runtimeModeOf(draftId)},
      {QStringLiteral("interactionMode"), interactionModeOf(draftId)},
      {QStringLiteral("workspaceStrategy"), where.strategy},
      {QStringLiteral("initialMessage"), QJsonObject{{QStringLiteral("messageId"), newId()},
                                                     {QStringLiteral("text"), trimmed},
                                                     {QStringLiteral("attachments"), QJsonArray()}}},
  };
  if (!modelSelection.isEmpty()) input.insert(QStringLiteral("modelSelection"), modelSelection);

  if (background) {
    // The thread is on its way; the draft takes the next prompt under a new
    // thread id, so the launched thread's row does not end it.
    m_drafts[draftId].attachments.clear();
    drafts->renew(draftId);
    setText(draftId, QString(), 0);
  } else {
    m_launching.insert(draftId);
  }
  publish();
  const QString environmentId = where.environmentId;
  const auto start = [this, draftId, environmentId, background, text, attachments](const QJsonObject& input) {
    m_client->call(environmentId, QStringLiteral("orchestration.launchThread"), input,
                   [this, draftId, environmentId, input, background, text, attachments](
                       const QJsonValue& result, const std::optional<QString>& error) {
                     QString threadId = result.toObject().value(QLatin1String("threadId")).toString();
                     if (threadId.isEmpty()) threadId = str(input, QLatin1String("threadId"));
                     const QString threadKey = environmentId + QLatin1Char(':') + threadId;
                     if (background) {
                       launchedInBackground(draftId, text, attachments, threadKey, error);
                     } else {
                       launched(draftId, threadKey, error);
                     }
                   });
  };
  if (attachments.isEmpty()) {
    start(input);
    return true;
  }
  QJsonArray images;
  for (const Attachment& attachment : attachments) {
    images.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("image")},
                              {QStringLiteral("name"), attachment.name},
                              {QStringLiteral("mimeType"), attachment.mimeType},
                              {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                              {QStringLiteral("dataUrl"), attachment.dataUrl}});
  }
  QJsonObject message = input.value(QLatin1String("initialMessage")).toObject();
  m_client->call(environmentId, QStringLiteral("assets.persistChatAttachments"),
                 QJsonObject{{QStringLiteral("threadId"), kept->threadId},
                             {QStringLiteral("messageId"), message.value(QLatin1String("messageId"))},
                             {QStringLiteral("attachments"), images}},
                 [this, draftId, input, message, start, background, text, attachments](
                     const QJsonValue& result, const std::optional<QString>& error) mutable {
                   if (error) {
                     if (background) {
                       launchedInBackground(draftId, text, attachments, QString(), error);
                     } else {
                       launched(draftId, QString(), error);
                     }
                     return;
                   }
                   message.insert(QStringLiteral("attachments"), result.toObject().value(QLatin1String("attachments")));
                   input.insert(QStringLiteral("initialMessage"), message);
                   start(input);
                 });
  return true;
}

// The launch's answer: the draft becomes the thread, or stays with a toast.
void ComposerController::launched(const QString& draftId, const QString& threadKey, const std::optional<QString>& error) {
  m_launching.remove(draftId);
  if (error) {
    toast(QStringLiteral("Could not create thread"), *error);
    publish();
    return;
  }
  m_drafts.remove(draftId);
  save();
  NativeShell* shell = NativeShell::of(this);
  shell->controller<WorkspaceController>()->forgetDraft(draftId);
  shell->controller<DraftController>()->promote(draftId, threadKey);
  publish();
}

// A background launch's answer, as the web's: a toast that opens the new
// thread, or the prompt back in the draft (or, when the draft has a newer
// prompt, a toast that gives it back once the draft is empty).
void ComposerController::launchedInBackground(const QString& draftId, const QString& text,
                                              const QList<Attachment>& attachments, const QString& threadKey,
                                              const std::optional<QString>& error) {
  NativeShell* shell = NativeShell::of(this);
  auto* toasts = shell->controller<ToastController>();
  if (!error) {
    auto* navigation = shell->controller<NavigationController>();
    toasts->show(QStringLiteral("success"), QStringLiteral("Started 1 thread in background"), {},
                 ToastController::Action{QStringLiteral("Open"), [navigation, threadKey] {
                                           navigation->open(NavigationController::Route::thread(threadKey));
                                         }});
    return;
  }
  // Only into an empty draft: newer typing is the user's.
  const auto restore = [this, draftId, text, attachments] {
    if (!NativeShell::of(this)->controller<DraftController>()->draft(draftId) || !draft(draftId).isEmpty() ||
        !m_drafts.value(draftId).attachments.isEmpty()) {
      return false;
    }
    m_drafts[draftId].attachments = attachments;
    setText(draftId, text, int(text.size()));
    return true;
  };
  if (restore()) {
    toast(QStringLiteral("A background prompt could not be sent"), *error);
    return;
  }
  toasts->show(QStringLiteral("error"), QStringLiteral("A background prompt could not be sent"),
               QStringLiteral("Your newer draft is unchanged. Restore the failed prompt when this composer is empty."),
               ToastController::Action{QStringLiteral("Restore prompt"),
                                       [this, restore, draftId] {
                                         if (!restore()) return;
                                         NativeShell::of(this)->controller<NavigationController>()->open(
                                             NavigationController::Route::draft(draftId));
                                       }},
               0);
}

// Uploads the thread's oldest send's images, dispatches it command by
// command, then the next send.
void ComposerController::sendNext(const QString& target) {
  const Send send = m_queues.value(target).constFirst();
  const auto finish = [this, target](const std::optional<QString>& error) {
    if (error) {
      toast(QStringLiteral("Failed to send message"), *error);
      // The sends queued behind it would reach the node out of order, so they
      // stop too and come back with it.
      const QList<Send> unsent = m_queues.take(target);
      QStringList prompts;
      QList<Attachment> attachments;
      for (const Send& queued : unsent) {
        if (!queued.prompt.isEmpty()) prompts.append(queued.prompt);
        attachments.append(queued.attachments);
      }
      // Only into an untouched draft: newer typing is the user's.
      if (draft(target).isEmpty() && !prompts.isEmpty()) {
        const QString restored = prompts.join(QStringLiteral("\n\n"));
        setText(target, restored, int(restored.size()));
      }
      Draft& draft = m_drafts[target];
      draft.attachments = attachments + draft.attachments;
      save();
      publish();
      return;
    }
    // A draft's first turn makes it a thread (a no-op for a thread the node
    // already has).
    NativeShell::of(this)->controller<DraftController>()->promote(target);
    QList<Send>& queue = m_queues[target];
    queue.removeFirst();
    if (queue.isEmpty()) {
      m_queues.remove(target);
    } else {
      sendNext(target);
    }
  };
  if (send.attachments.isEmpty()) {
    dispatchAll(send, 0, finish);
    return;
  }
  QJsonArray images;
  for (const Attachment& attachment : send.attachments) {
    images.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("image")},
                              {QStringLiteral("name"), attachment.name},
                              {QStringLiteral("mimeType"), attachment.mimeType},
                              {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                              {QStringLiteral("dataUrl"), attachment.dataUrl}});
  }
  QJsonObject message = send.commands.constLast();
  m_client->call(send.environmentId, QStringLiteral("assets.persistChatAttachments"),
                 QJsonObject{{QStringLiteral("threadId"), send.threadId},
                             {QStringLiteral("messageId"), message.value(QLatin1String("messageId"))},
                             {QStringLiteral("attachments"), images}},
                 [this, send, message, finish](const QJsonValue& result, const std::optional<QString>& error) mutable {
                   if (error) {
                     finish(error);
                     return;
                   }
                   message.insert(QStringLiteral("attachments"), result.toObject().value(QLatin1String("attachments")));
                   Send stored = send;
                   stored.commands.last() = message;
                   dispatchAll(stored, 0, finish);
                 });
}

void ComposerController::dispatchAll(const Send& send, qsizetype index,
                                     std::function<void(const std::optional<QString>&)> done) {
  m_client->dispatchCommand(send.environmentId, send.commands.at(index),
                            [this, send, index, done](const QJsonValue&, const std::optional<QString>& error) {
                              if (!error && index + 1 < send.commands.size()) {
                                dispatchAll(send, index + 1, done);
                                return;
                              }
                              done(error);
                            });
}

// Images the brick read from disk ({name, mimeType, base64}) join the route
// thread's draft.
bool ComposerController::attach(const QVariantList& files) {
  const QString draftId = nativeDraft();
  const QString target = draftId.isEmpty() ? openThread() : draftId;
  if (draftId.isEmpty() && !m_store->thread(target)) return false;
  QList<Attachment>& attachments = m_drafts[target].attachments;
  for (const QVariant& value : files) {
    const QVariantMap file = value.toMap();
    const QString base64 = file.value(QStringLiteral("base64")).toString();
    const QString mimeType = file.value(QStringLiteral("mimeType")).toString();
    attachments.append({QStringLiteral("attachment-%1").arg(m_nextAttachment++), file.value(QStringLiteral("name")).toString(),
                        mimeType, QByteArray::fromBase64(base64.toLatin1()).size(),
                        QStringLiteral("data:%1;base64,%2").arg(mimeType, base64)});
  }
  publish();
  return true;
}

// Answers one of the route thread's requests: a decision, answers, or (with
// neither) dismissing the questions. A request the node says is gone closes;
// any other failure leaves it open to answer again.
bool ComposerController::respond(const QString& requestId, const QJsonObject& fields, const QString& failure) {
  const auto thread = m_store->thread(m_thread);
  if (!thread || requestId.isEmpty() || m_responding.contains(requestId)) return true;
  QJsonObject command{{QStringLiteral("type"), fields.isEmpty() ? QStringLiteral("thread.user-input.dismiss")
                                                                : QStringLiteral("runtime-request.respond")},
                      {QStringLiteral("threadId"), thread->id},
                      {QStringLiteral("requestId"), requestId}};
  for (auto it = fields.begin(); it != fields.end(); ++it) command.insert(it.key(), it.value());
  m_responding.insert(requestId);
  publish();
  m_client->dispatchCommand(thread->environmentId, command,
                            [this, requestId, failure](const QJsonValue&, const std::optional<QString>& error) {
                              m_responding.remove(requestId);
                              if (error && staleRequest(*error)) {
                                m_closed.insert(requestId);
                              } else if (error) {
                                toast(failure, *error);
                              }
                              publish();
                            });
  return true;
}

// Removes a queued message, or makes it steer the running turn.
bool ComposerController::queueCommand(const QString& type, const QString& runId) {
  const auto thread = m_store->thread(m_thread);
  if (!thread || runId.isEmpty()) return true;
  QJsonObject command{{QStringLiteral("type"), type}, {QStringLiteral("threadId"), thread->id}};
  if (type == QLatin1String("queued-run.cancel")) {
    command.insert(QStringLiteral("runId"), runId);
  } else {
    if (!thread->activeRunId) return true;
    command.insert(QStringLiteral("queuedRunId"), runId);
    command.insert(QStringLiteral("targetRunId"), *thread->activeRunId);
  }
  const QString failure = type == QLatin1String("queued-run.cancel") ? QStringLiteral("Failed to remove the queued message.")
                                                                      : QStringLiteral("Failed to steer with the queued message.");
  m_client->dispatchCommand(thread->environmentId, command,
                            [this, failure](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) toast(failure, *error);
                            });
  return true;
}

QString ComposerController::openThread() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

QString ComposerController::openDraft() const {
  const NavigationController::Route& route = NativeShell::of(this)->controller<NavigationController>()->route();
  return route.kind == QLatin1String("draft") ? route.draftId : QString();
}

QString ComposerController::nativeDraft() const {
  const QString id = openDraft();
  return !id.isEmpty() && NativeShell::of(this)->controller<DraftController>()->draft(id) ? id : QString();
}

// A thread's own model; for a draft the project's default, as the web's
// deriveComposerModelSelection: this device's project override, the
// project's, then the default for new threads. Empty lets the node choose.
QJsonObject ComposerController::baseSelection(const QString& key) const {
  if (const auto thread = m_store->thread(key)) return thread->modelSelection;
  NativeShell* shell = NativeShell::of(this);
  const auto kept = shell->controller<DraftController>()->draft(key);
  if (!kept) return {};
  const auto* settings = shell->controller<SettingsController>();
  const auto setting = [settings](const QString& path) {
    return settings ? QJsonValue::fromVariant(settings->value(path)).toObject() : QJsonObject();
  };
  QJsonObject selection = setting(QStringLiteral("projectSettingsOverrides.%1.defaultModelSelection").arg(kept->projectId));
  if (selection.isEmpty()) {
    selection = m_store->projectRow(kept->environmentId, kept->projectId).value(QLatin1String("defaultModelSelection")).toObject();
  }
  if (selection.isEmpty()) selection = setting(QStringLiteral("defaultModelSelection"));
  return selection;
}

bool ComposerController::running(const QString& target) const {
  const auto thread = m_store->thread(target);
  return thread && thread->activeRunId.has_value();
}

void ComposerController::toast(const QString& title, const QString& description) {
  NativeShell::of(this)->controller<ToastController>()->error(title, description);
}

// Follows the route's thread and its stream.
void ComposerController::follow() {
  const QString thread = openThread();
  const QString draftId = openDraft();
  const QString key = draftId.isEmpty() ? thread : draftId;
  if (key != m_thread || draftId != m_draftId) {
    m_thread = key;
    m_draftId = draftId;
    if (draftId.isEmpty()) {
      m_openedDraft = draft(thread);
    } else {
      const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(draftId);
      m_openedDraft = kept ? kept->text : QString();
    }
  }
  TimelineModel* timeline = thread.isEmpty() ? nullptr : NativeShell::of(this)->controller<ThreadStore>()->timeline(thread);
  if (timeline != m_timeline) {
    disconnect(m_timelineConnection);
    m_timeline = timeline;
    if (timeline) m_timelineConnection = connect(timeline, &TimelineModel::turnChanged, this, &ComposerController::publish);
  }
  publish();
}

void ComposerController::publish() {
  if (!m_active) return;
  QVariantMap state = turnState();
  if (state == m_published) return;
  m_published = state;
  m_bridge->publish(QStringLiteral("turn"), state);
}

QVariantMap ComposerController::turnState() const {
  const auto thread = m_store->thread(m_thread);
  QVariantList attachments;
  for (const Attachment& attachment : m_drafts.value(m_thread).attachments) {
    attachments.append(QVariantMap{{QStringLiteral("id"), attachment.id},
                                   {QStringLiteral("name"), attachment.name},
                                   {QStringLiteral("mimeType"), attachment.mimeType},
                                   {QStringLiteral("sizeBytes"), attachment.sizeBytes}});
  }
  const bool isRunning = thread && thread->activeRunId.has_value();
  // A new thread's draft; one only the page has is left to it.
  if (!m_draftId.isEmpty()) {
    const bool kept = NativeShell::of(this)->controller<DraftController>()->draft(m_draftId).has_value();
    return {{QStringLiteral("threadKey"), kept ? m_draftId : QString()},
            {QStringLiteral("kind"), QStringLiteral("draft")},
            {QStringLiteral("running"), false},
            {QStringLiteral("sending"), m_launching.contains(m_draftId)},
            {QStringLiteral("draft"), m_openedDraft},
            {QStringLiteral("attachments"), attachments},
            {QStringLiteral("approvals"), QVariantList()},
            {QStringLiteral("questions"), QVariantList()},
            {QStringLiteral("plan"), QVariant()},
            {QStringLiteral("queue"), QVariantList()}};
  }
  QVariantMap state{{QStringLiteral("threadKey"), thread ? m_thread : QString()},
                    {QStringLiteral("kind"), QStringLiteral("thread")},
                    {QStringLiteral("running"), isRunning},
                    {QStringLiteral("draft"), m_openedDraft},
                    {QStringLiteral("attachments"), attachments},
                    {QStringLiteral("approvals"), QVariantList()},
                    {QStringLiteral("questions"), QVariantList()},
                    {QStringLiteral("plan"), QVariant()},
                    {QStringLiteral("queue"), QVariantList()}};
  if (!thread || !m_timeline) return state;

  const QHash<QString, QJsonObject> items = m_timeline->entities(QStringLiteral("turn-item"));
  const QHash<QString, QJsonObject> requests = m_timeline->entities(QStringLiteral("runtime-request"));
  const QHash<QString, QJsonObject> runs = m_timeline->entities(QStringLiteral("run"));

  // A pending request, and whether it can still be answered.
  const auto pending = [&](const QJsonObject& item, QVariantMap& shown, bool approval) {
    const QString requestId = str(item, QLatin1String("requestId"));
    const QJsonObject request = requests.value(requestId);
    if (str(request, QLatin1String("status")) != QLatin1String("pending") || m_closed.contains(requestId)) return false;
    const QString capability = str(request.value(QLatin1String("responseCapability")).toObject(), QLatin1String("type"));
    const bool gone = capability == QLatin1String("not_resumable");
    shown.insert(QStringLiteral("requestId"), requestId);
    shown.insert(QStringLiteral("canRespond"), approval ? capability.isEmpty() || capability == QLatin1String("live") : !gone);
    shown.insert(QStringLiteral("problem"), gone ? kProviderGone : QString());
    shown.insert(QStringLiteral("responding"), m_responding.contains(requestId));
    return true;
  };

  QVariantList approvals;
  for (const QJsonObject& item : itemsOf(items, QStringLiteral("approval_request"))) {
    QVariantMap approval;
    if (!pending(item, approval, true)) continue;
    const QString title = approvalTitle(str(item, QLatin1String("requestKind")));
    QVariantList options;
    for (const QJsonValue& value : item.value(QLatin1String("options")).toArray()) {
      const QJsonObject option = value.toObject();
      options.append(QVariantMap{{QStringLiteral("decision"), str(option, QLatin1String("decision"))},
                                 {QStringLiteral("label"), str(option, QLatin1String("label"))},
                                 {QStringLiteral("warning"), str(option, QLatin1String("warning"))}});
    }
    approval.insert(QStringLiteral("title"), title);
    approval.insert(QStringLiteral("appName"), str(item, QLatin1String("appName")));
    const QString prompt = str(item, QLatin1String("prompt"));
    approval.insert(QStringLiteral("detail"), prompt.isEmpty() ? title : prompt);
    approval.insert(QStringLiteral("options"), options.isEmpty() ? defaultApprovalOptions() : options);
    approvals.append(approval);
  }
  state.insert(QStringLiteral("approvals"), approvals);

  QVariantList questions;
  for (const QJsonObject& item : itemsOf(items, QStringLiteral("user_input_request"))) {
    QVariantMap question;
    if (!pending(item, question, false)) continue;
    question.insert(QStringLiteral("questions"), item.value(QLatin1String("questions")).toArray().toVariantList());
    questions.append(question);
  }
  state.insert(QStringLiteral("questions"), questions);

  // The proposed plan still waiting on the user, from the latest run; offered
  // once the thread is idle.
  if (!isRunning) {
    QJsonObject latest;
    double latestOrdinal = -1;
    for (const QJsonObject& plan : m_timeline->entities(QStringLiteral("plan"))) {
      if (str(plan, QLatin1String("kind")) != QLatin1String("proposed_plan") ||
          str(plan, QLatin1String("status")) != QLatin1String("active")) {
        continue;
      }
      const double ordinal = runs.value(str(plan, QLatin1String("runId"))).value(QLatin1String("ordinal")).toDouble();
      if (ordinal >= latestOrdinal) {
        latestOrdinal = ordinal;
        latest = plan;
      }
    }
    if (!latest.isEmpty()) {
      const QString markdown = str(latest, QLatin1String("markdown"));
      state.insert(QStringLiteral("plan"), QVariantMap{{QStringLiteral("id"), str(latest, QLatin1String("id"))},
                                                       {QStringLiteral("title"), planTitle(markdown)},
                                                       {QStringLiteral("markdown"), markdown}});
    }
  }

  // Queued messages in the order they run.
  QList<QJsonObject> queued;
  for (const QJsonObject& run : runs) {
    if (str(run, QLatin1String("status")) == QLatin1String("queued")) queued.append(run);
  }
  std::sort(queued.begin(), queued.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const double left = a.value(QLatin1String("queuePosition")).toDouble(a.value(QLatin1String("ordinal")).toDouble());
    const double right = b.value(QLatin1String("queuePosition")).toDouble(b.value(QLatin1String("ordinal")).toDouble());
    return left < right;
  });
  const QHash<QString, QJsonObject> messages = m_timeline->entities(QStringLiteral("message"));
  QVariantList queue;
  for (const QJsonObject& run : queued) {
    queue.append(QVariantMap{{QStringLiteral("runId"), str(run, QLatin1String("id"))},
                             {QStringLiteral("text"), str(messages.value(str(run, QLatin1String("userMessageId"))), QLatin1String("text"))}});
  }
  state.insert(QStringLiteral("queue"), queue);
  return state;
}
