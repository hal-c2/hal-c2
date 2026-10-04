#include "ComposerController.h"

#include <QBuffer>
#include <QFile>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStringList>
#include <QUrl>
#include <QUuid>

#include <algorithm>
#include <cmath>
#include <memory>

#include "DraftController.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"
#include "WorkspaceController.h"
#include "WorkspaceFiles.h"

namespace {
const NativeControllerRegistrar<ComposerController> registrar(QStringLiteral("composer"),
                                                               {QStringLiteral("turn"), QStringLiteral("composer"),
                                                                QStringLiteral("modelPicker"), QStringLiteral("composerStash")});

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

// A respond failure that means the request is gone (the MC's, and the
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

// What stands for the kept images: an image never changes in place, so its
// target and id do.
QString imagesSignature(const QJsonObject& targets) {
  QStringList signature;
  for (auto it = targets.begin(); it != targets.end(); ++it) {
    for (const QJsonValue& image : it.value().toArray()) {
      signature.append(it.key() + u'/' + image.toObject().value(QLatin1String("id")).toString());
    }
  }
  return signature.join(u'\n');
}

QString newId() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

// apps/web/src/promptStashStore.ts MAX_STASH_ENTRIES.
constexpr qsizetype kMaxStashEntries = 20;

// packages/contracts/src/assistantCitations.ts: the longest quote or comment,
// and how much of the reply on either side a citation keeps.
constexpr qsizetype kMaxCitationLength = 8000;
constexpr qsizetype kCitationContextLength = 32;

// `[Assistant quote](hal-c2-citation://v1/<environment>/<thread>/<message>?text=...)`:
// serializeAssistantCitation in packages/shared/src/assistantCitations.ts.
QString citationLink(const QJsonObject& citation) {
  const auto encoded = [](const QString& value) { return QString::fromLatin1(QUrl::toPercentEncoding(value)); };
  QStringList path;
  for (const auto key : {QLatin1String("environmentId"), QLatin1String("threadId"), QLatin1String("messageId")}) {
    path.append(encoded(citation.value(key).toString()));
  }
  QStringList query;
  for (const auto key : {QLatin1String("text"), QLatin1String("start"), QLatin1String("end"), QLatin1String("prefix"),
                         QLatin1String("suffix"), QLatin1String("comment")}) {
    const QJsonValue value = citation.value(key);
    if (value.isUndefined()) continue;
    const QString text = value.isString() ? value.toString() : QString::number(qint64(value.toDouble()));
    query.append(key + u'=' + encoded(text).replace(QLatin1String("%20"), QLatin1String("+")));
  }
  return QStringLiteral("[Assistant quote](hal-c2-citation://v1/%1?%2)").arg(path.join(u'/'), query.join(u'&'));
}

}  // namespace

ComposerController::ComposerController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                       QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_kept(NativeShell::of(this)->shell()->common<Kept>()),
      m_drafts(m_kept.drafts) {}

void ComposerController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, &ComposerController::follow);
  connect(shell->controller<ThreadStore>(), &ThreadStore::activeThreadChanged, this, &ComposerController::follow);
  // A draft opened, renewed or promoted in any window.
  connect(shell->controller<DraftController>(), &DraftController::changed, this, &ComposerController::publish);
  // The row says whether a turn runs, which decides follow-ups and the plan.
  connect(m_store, &ShellStore::changed, this, &ComposerController::publish);
  // The route environment's providers are the picker's catalogue.
  connect(shell->controller<WorkspaceController>(), &WorkspaceController::configChanged, this, [this] {
    refreshCatalogue();
    publish();
  });
  if (auto* settings = shell->controller<SettingsController>()) {
    connect(settings, &SettingsController::settingsChanged, this, &ComposerController::publish);
    connect(settings, &SettingsController::deviceChanged, this, &ComposerController::publish);
  }
  connect(shell->controller<KeybindingController>(), &KeybindingController::bindingsChanged, this,
          &ComposerController::publish);
  refreshCatalogue();
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
  // Prompt history is not the shell's yet.
  if (action == QLatin1String("composer.history.step")) return true;
  if (action == QLatin1String("composer.terminalContext.add")) return addTerminalContext(map);
  if (action == QLatin1String("composer.citation.add")) return addCitation(map);
  if (action == QLatin1String("composer.citation.comment")) {
    if (target.isEmpty()) return true;
    const QString id = map.value(QStringLiteral("id")).toString();
    for (Excerpt& excerpt : m_drafts[target].excerpts) {
      if (excerpt.id != id || excerpt.citation.isEmpty()) continue;
      // withAssistantCitationComment: a blank comment is no comment.
      const QString comment = map.value(QStringLiteral("comment")).toString().trimmed().left(kMaxCitationLength);
      if (comment.isEmpty()) {
        excerpt.citation.remove(QLatin1String("comment"));
      } else {
        excerpt.citation.insert(QStringLiteral("comment"), comment);
      }
      publish();
    }
    return true;
  }
  if (action == QLatin1String("composer.terminalContext.remove") || action == QLatin1String("composer.citation.remove")) {
    if (target.isEmpty()) return true;
    const QString id = map.value(QStringLiteral("id")).toString();
    if (m_drafts[target].excerpts.removeIf([&](const Excerpt& context) { return context.id == id; }) > 0) {
      publish();
    }
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

  if (action == QLatin1String("composer.stash")) return stash(target);
  if (action == QLatin1String("composer.stash.restore")) {
    if (!target.isEmpty()) restoreStash(target, map.value(QStringLiteral("id")).toString());
    return true;
  }
  if (action == QLatin1String("composer.stash.delete")) {
    const QString id = map.value(QStringLiteral("id")).toString();
    if (m_kept.stash.removeIf([&](const StashEntry& entry) { return entry.id == id; }) == 0) return true;
    if (m_kept.stash.isEmpty()) m_stashOpen = false;
    save();
    publish();
    return true;
  }
  if (action == QLatin1String("composer.stash.menu")) {
    setStashOpen(map.contains(QStringLiteral("open")) ? map.value(QStringLiteral("open")).toBool() : !m_stashOpen);
    return true;
  }

  if (action == QLatin1String("composer.interrupt")) return interrupt();
  if (action == QLatin1String("composer.submit")) return submit(map);
  if (action == QLatin1String("composer.attach")) return attach(map.value(QStringLiteral("files")).toList());
  if (action == QLatin1String("composer.attachment.remove")) {
    if (target.isEmpty()) return true;
    QList<Attachment>& attachments = m_drafts[target].attachments;
    const QString id = map.value(QStringLiteral("id")).toString();
    if (attachments.removeIf([&](const Attachment& attachment) { return attachment.id == id; }) > 0) {
      save();
      publish();
    }
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
  if (action == QLatin1String("composer.queue.edit")) {
    return editQueued(target, map.value(QStringLiteral("runId")).toString());
  }
  if (action == QLatin1String("composer.queue.edit.cancel")) {
    if (m_queuedEdit && m_queuedEdit->thread == target) endQueuedEdit();
    return true;
  }
  if (action == QLatin1String("composer.queue.steer")) {
    // Without a run, the first queued one (the steer key).
    QString runId = map.value(QStringLiteral("runId")).toString();
    const QVariantList queue = turnState().value(QStringLiteral("queue")).toList();
    if (runId.isEmpty() && !queue.isEmpty()) runId = queue.constFirst().toMap().value(QStringLiteral("runId")).toString();
    return queueCommand(QStringLiteral("queued-message.promote-to-steer"), runId);
  }
  return false;
}

// The web's stashCurrentPrompt: the draft goes to the stash and the composer
// empties; an empty draft brings back the only entry, or opens the list.
// Nothing while an approval waits; a question waiting opens the list instead.
bool ComposerController::stash(const QString& target) {
  if (target.isEmpty()) return true;
  const QVariantMap turn = turnState();
  if (!turn.value(QStringLiteral("approvals")).toList().isEmpty()) return true;
  if (!turn.value(QStringLiteral("questions")).toList().isEmpty()) {
    setStashOpen(!m_stashOpen);
    return true;
  }
  Draft& kept = m_drafts[target];
  const QString text = draft(target).trimmed();
  if (text.isEmpty() && kept.attachments.isEmpty() && kept.excerpts.isEmpty()) {
    if (m_kept.stash.size() == 1) {
      restoreStash(target, m_kept.stash.constFirst().id);
    } else {
      setStashOpen(!m_stashOpen);
    }
    return true;
  }
  m_kept.stash.prepend({newId(), m_now(), text, kept.attachments, kept.excerpts});
  if (m_kept.stash.size() > kMaxStashEntries) {
    m_kept.stash.removeLast();
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("Oldest stashed prompt discarded"),
        QStringLiteral("The stash holds %1 prompts; the oldest was removed to make room.").arg(kMaxStashEntries));
  }
  kept.attachments.clear();
  kept.excerpts.clear();
  // Clearing saves and publishes.
  setText(target, QString(), 0);
  save();
  return true;
}

// The entry joins what the draft already holds, after a blank line, and
// leaves the stash (the web's restoreStashEntry).
void ComposerController::restoreStash(const QString& target, const QString& id) {
  const auto found = std::find_if(m_kept.stash.cbegin(), m_kept.stash.cend(),
                                  [&](const StashEntry& entry) { return entry.id == id; });
  if (found == m_kept.stash.cend()) return;
  const StashEntry entry = *found;
  m_kept.stash.removeAt(found - m_kept.stash.cbegin());
  m_stashOpen = false;
  Draft& kept = m_drafts[target];
  kept.attachments.append(entry.attachments);
  kept.excerpts.append(entry.excerpts);
  const QString current = draft(target);
  const QString text = current.trimmed().isEmpty() ? entry.text : current.trimmed() + QStringLiteral("\n\n") + entry.text;
  setText(target, text, int(text.size()));
  save();
}

void ComposerController::setStashOpen(bool open) {
  if (open == m_stashOpen) return;
  m_stashOpen = open;
  publish();
}

// apps/web/src/components/chat/ComposerStashMenu.tsx stashEntrySnippet.
QVariantMap ComposerController::stashState() const {
  static const QRegularExpression space(QStringLiteral("\\s+"));
  QVariantList entries;
  for (const StashEntry& entry : m_kept.stash) {
    QString snippet = entry.text;
    // A quote reads as its text and comment (assistantCitationsToPlainText).
    for (const Excerpt& excerpt : entry.excerpts) {
      if (excerpt.citation.isEmpty()) continue;
      snippet += QLatin1Char(' ') + excerpt.citation.value(QStringLiteral("text")).toString();
      if (const QString comment = excerpt.citation.value(QStringLiteral("comment")).toString(); !comment.isEmpty()) {
        snippet += QStringLiteral(" Comment: ") + comment;
      }
    }
    snippet = snippet.trimmed().replace(space, QStringLiteral(" "));
    if (snippet.size() > 90) {
      snippet = snippet.left(90) + QStringLiteral("…");
    } else if (snippet.isEmpty()) {
      const qsizetype images = entry.attachments.size();
      snippet = images == 0 ? QStringLiteral("(empty)")
                            : QStringLiteral("(%1 image%2)").arg(images).arg(images == 1 ? "" : "s");
    }
    entries.append(QVariantMap{{QStringLiteral("id"), entry.id},
                               {QStringLiteral("snippet"), snippet},
                               {QStringLiteral("createdAt"), entry.createdAt.toString(Qt::ISODateWithMs)}});
  }
  return {{QStringLiteral("entries"), entries},
          {QStringLiteral("open"), m_stashOpen},
          {QStringLiteral("shortcut"),
           NativeShell::of(this)->controller<KeybindingController>()->shortcutLabel(QStringLiteral("composer.stash"))}};
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
  m_client->dispatchCommand(this, thread->environmentId,
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
  if (m_queuedEdit && m_queuedEdit->thread == target) return saveQueuedEdit(target, text);
  if (slashMode(target, text)) return true;
  if (!m_draftId.isEmpty()) return submitDraft(target, payload);
  const Draft& kept = m_drafts.value(target);
  const bool hasExtras = !kept.attachments.isEmpty() || !kept.excerpts.isEmpty();
  const bool planFollowUp = !hasExtras && turnState().value(QStringLiteral("plan")).isValid();
  if (text.trimmed().isEmpty() && !hasExtras && !planFollowUp) return true;

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
  // Nothing leaves while the MC is out of reach: the draft stays as it is.
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
  // Only a mode the user changed is set; a thread the MC has no mode for
  // keeps the MC's default.
  const QString runtimeMode = m_drafts.value(target).runtimeMode;
  QString interactionMode = interactionModeOf(target);
  if (planFollowUp) interactionMode = implement ? QStringLiteral("default") : QStringLiteral("plan");
  if (thread->interactionMode.isEmpty() && interactionMode == QLatin1String("default")) interactionMode.clear();
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
  // client-runtime startThreadTurn with an MC that resolves the context.
  if (mode == QLatin1String("queue")) {
    message.insert(QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("queue_after_active")}});
  } else {
    message.insert(QStringLiteral("deliveryIntent"), mode);
    message.insert(QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("start_immediately")}});
  }
  Draft& draft = m_drafts[target];
  if (planFollowUp) draft.interactionMode = interactionMode;

  // Implementing from the plan's own button leaves the draft alone.
  const QList<Attachment> attachments = fromDraft ? std::exchange(draft.attachments, {}) : QList<Attachment>();
  const QList<Excerpt> contexts =
      fromDraft ? std::exchange(draft.excerpts, {}) : QList<Excerpt>();
  withExcerpts(message, contexts);
  commands.append(message);
  if (fromDraft) setText(target, QString(), 0);
  save();
  publish();

  // A send made while an earlier one is still in flight waits its turn.
  QList<Send>& queue = m_queues[target];
  queue.append({target, thread->environmentId, thread->id, commands, attachments, contexts, fromDraft ? text : QString()});
  if (queue.size() == 1) sendNext(target);
  return true;
}

// A new thread's first send, as the web's: its images are stored, then the
// thread is launched with the message in the draft's checkout. The draft (its
// text and images) stays until the MC confirms; the window then shows the
// thread in its place. A background send (mod+alt+Enter) leaves the window on
// the draft, emptied for another prompt.
bool ComposerController::submitDraft(const QString& draftId, const QVariantMap& payload) {
  auto* shell = NativeShell::of(this);
  auto* drafts = shell->controller<DraftController>();
  const auto kept = drafts->draft(draftId);
  if (!kept) return true;
  const bool background = payload.value(QStringLiteral("intent")).toString() == QLatin1String("background");
  const QString text = kept->text;
  QList<Attachment> attachments = m_drafts.value(draftId).attachments;
  const QList<Excerpt> contexts = m_drafts.value(draftId).excerpts;
  if (text.trimmed().isEmpty() && attachments.isEmpty() && contexts.isEmpty()) return true;
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
  if (!contexts.isEmpty()) {
    QJsonObject initial = input.value(QLatin1String("initialMessage")).toObject();
    withExcerpts(initial, contexts);
    input.insert(QStringLiteral("initialMessage"), initial);
  }

  if (background) {
    // The thread is on its way; the draft takes the next prompt under a new
    // thread id, so the launched thread's row does not end it.
    m_drafts[draftId].attachments.clear();
    m_drafts[draftId].excerpts.clear();
    drafts->renew(draftId);
    setText(draftId, QString(), 0);
  } else {
    m_launching.insert(draftId);
  }
  publish();
  const QString environmentId = where.environmentId;
  const auto start = [this, draftId, environmentId, background, text, attachments, contexts](const QJsonObject& input) {
    m_client->call(this, environmentId, QStringLiteral("orchestration.launchThread"), input,
                   [this, draftId, environmentId, input, background, text, attachments, contexts](
                       const QJsonValue& result, const std::optional<QString>& error) {
                     QString threadId = result.toObject().value(QLatin1String("threadId")).toString();
                     if (threadId.isEmpty()) threadId = str(input, QLatin1String("threadId"));
                     const QString threadKey = environmentId + QLatin1Char(':') + threadId;
                     if (background) {
                       launchedInBackground(draftId, text, attachments, contexts, threadKey, error);
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
    QJsonObject image{{QStringLiteral("type"), QStringLiteral("image")},
                      {QStringLiteral("name"), attachment.name},
                      {QStringLiteral("mimeType"), attachment.mimeType},
                      {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                      {QStringLiteral("dataUrl"), attachment.dataUrl}};
    if (!attachment.source.isEmpty()) image.insert(QStringLiteral("source"), attachment.source);
    images.append(image);
  }
  QJsonObject message = input.value(QLatin1String("initialMessage")).toObject();
  m_client->call(this, environmentId, QStringLiteral("assets.persistChatAttachments"),
                 QJsonObject{{QStringLiteral("threadId"), kept->threadId},
                             {QStringLiteral("messageId"), message.value(QLatin1String("messageId"))},
                             {QStringLiteral("attachments"), images}},
                 [this, draftId, input, message, start, background, text, attachments, contexts](
                     const QJsonValue& result, const std::optional<QString>& error) mutable {
                   if (error) {
                     if (background) {
                       launchedInBackground(draftId, text, attachments, contexts, QString(), error);
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
  auto* shell = NativeShell::of(this);
  shell->controller<WorkspaceController>()->forgetDraft(draftId);
  shell->controller<DraftController>()->promote(draftId, threadKey);
  publish();
}

// A background launch's answer, as the web's: a toast that opens the new
// thread, or the prompt back in the draft (or, when the draft has a newer
// prompt, a toast that gives it back once the draft is empty).
void ComposerController::launchedInBackground(const QString& draftId, const QString& text,
                                              const QList<Attachment>& attachments,
                                              const QList<Excerpt>& contexts, const QString& threadKey,
                                              const std::optional<QString>& error) {
  auto* shell = NativeShell::of(this);
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
  const auto restore = [this, draftId, text, attachments, contexts] {
    if (!NativeShell::of(this)->controller<DraftController>()->draft(draftId) || !draft(draftId).isEmpty() ||
        !m_drafts.value(draftId).attachments.isEmpty() || !m_drafts.value(draftId).excerpts.isEmpty()) {
      return false;
    }
    m_drafts[draftId].attachments = attachments;
    m_drafts[draftId].excerpts = contexts;
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
      // The sends queued behind it would reach the MC out of order, so they
      // stop too and come back with it.
      const QList<Send> unsent = m_queues.take(target);
      QStringList prompts;
      QList<Attachment> attachments;
      QList<Excerpt> contexts;
      for (const Send& queued : unsent) {
        if (!queued.prompt.isEmpty()) prompts.append(queued.prompt);
        attachments.append(queued.attachments);
        contexts.append(queued.excerpts);
      }
      // Only into an untouched draft: newer typing is the user's.
      if (draft(target).isEmpty() && !prompts.isEmpty()) {
        const QString restored = prompts.join(QStringLiteral("\n\n"));
        setText(target, restored, int(restored.size()));
      }
      Draft& draft = m_drafts[target];
      draft.attachments = attachments + draft.attachments;
      draft.excerpts = contexts + draft.excerpts;
      save();
      publish();
      return;
    }
    // A draft's first turn makes it a thread (a no-op for a thread the MC
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
    QJsonObject image{{QStringLiteral("type"), QStringLiteral("image")},
                      {QStringLiteral("name"), attachment.name},
                      {QStringLiteral("mimeType"), attachment.mimeType},
                      {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                      {QStringLiteral("dataUrl"), attachment.dataUrl}};
    if (!attachment.source.isEmpty()) image.insert(QStringLiteral("source"), attachment.source);
    images.append(image);
  }
  QJsonObject message = send.commands.constLast();
  m_client->call(this, send.environmentId, QStringLiteral("assets.persistChatAttachments"),
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
  m_client->dispatchCommand(this, send.environmentId, send.commands.at(index),
                            [this, send, index, done](const QJsonValue&, const std::optional<QString>& error) {
                              if (!error && index + 1 < send.commands.size()) {
                                dispatchAll(send, index + 1, done);
                                return;
                              }
                              done(error);
                            });
}

// What the composer shows of a draft image, its middle square scaled down, as
// a PNG data URL: the full image would be compared and handed to QML on every
// keystroke. Empty when Qt cannot read the image.
QString ComposerController::thumbnail(const QString& dataUrl) {
  constexpr int kSide = 128;
  QByteArray bytes = QByteArray::fromBase64(QStringView(dataUrl).mid(dataUrl.indexOf(QLatin1Char(',')) + 1).toLatin1());
  QBuffer source(&bytes);
  QImageReader reader(&source);
  reader.setAutoTransform(true);
  const QSize size = reader.size();
  const int side = std::min(size.width(), size.height());
  if (side > 0) {
    reader.setClipRect(QRect((size.width() - side) / 2, (size.height() - side) / 2, side, side));
    if (side > kSide) reader.setScaledSize(QSize(kSide, kSide));
  }
  const QImage image = reader.read();
  QByteArray png;
  QBuffer target(&png);
  if (image.isNull() || !target.open(QIODevice::WriteOnly) || !image.save(&target, "PNG")) return {};
  return QStringLiteral("data:image/png;base64,") + QString::fromLatin1(png.toBase64());
}

// Images the brick read from disk ({name, mimeType, base64}) join the route
// thread's draft.
bool ComposerController::attach(const QVariantList& files) {
  const QString target = this->target();
  if (target.isEmpty()) return true;
  QList<Attachment>& attachments = m_drafts[target].attachments;
  for (const QVariant& value : files) {
    const QVariantMap file = value.toMap();
    const QString base64 = file.value(QStringLiteral("base64")).toString();
    const QString mimeType = file.value(QStringLiteral("mimeType")).toString();
    attachments.append({newId(), file.value(QStringLiteral("name")).toString(),
                        mimeType, QByteArray::fromBase64(base64.toLatin1()).size(),
                        QStringLiteral("data:%1;base64,%2").arg(mimeType, base64)});
  }
  save();
  publish();
  return true;
}

void ComposerController::attachImage(const QString& target, const QString& name, const QString& mimeType,
                                     const QByteArray& bytes, const QJsonObject& source) {
  if (target.isEmpty()) return;
  m_drafts[target].attachments.append({newId(), name, mimeType, bytes.size(),
                                       QStringLiteral("data:%1;base64,%2").arg(mimeType, QString::fromLatin1(bytes.toBase64())),
                                       source});
  save();
  publish();
}

QVariantList ComposerController::attachments(const QString& target) const {
  QVariantList list;
  for (const Attachment& attachment : m_drafts.value(target).attachments) {
    list.append(QVariantMap{{QStringLiteral("id"), attachment.id},
                            {QStringLiteral("name"), attachment.name},
                            {QStringLiteral("mimeType"), attachment.mimeType},
                            {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                            {QStringLiteral("source"), attachment.source.toVariantMap()}});
  }
  return list;
}

// apps/web/src/lib/terminalContext.ts normalizeTerminalContextSelection: the
// text without CRs or blank edges, and a valid line range; a selection with
// no text, terminal or label adds nothing.
bool ComposerController::addTerminalContext(const QVariantMap& selection) {
  const QString target = this->target();
  if (target.isEmpty()) return true;
  static const QRegularExpression edges(QStringLiteral("^\\n+|\\n+$"));
  QString text = selection.value(QStringLiteral("text")).toString();
  text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
  text.remove(edges);
  const QString terminalId = selection.value(QStringLiteral("terminalId")).toString().trimmed();
  const QString terminalLabel = selection.value(QStringLiteral("terminalLabel")).toString().trimmed();
  if (text.isEmpty() || terminalId.isEmpty() || terminalLabel.isEmpty()) return true;
  const int lineStart = std::max(1, int(std::floor(selection.value(QStringLiteral("lineStart")).toDouble())));
  const int lineEnd = std::max(lineStart, int(std::floor(selection.value(QStringLiteral("lineEnd")).toDouble())));
  m_drafts[target].excerpts.append({newId(), terminalId, terminalLabel, lineStart, lineEnd, text});
  publish();
  return true;
}

// A quote the composer holds: one selection of one reply of the thread it
// is on, within the citation's limits (AssistantCitation); anything else
// adds nothing.
bool ComposerController::addCitation(const QVariantMap& selection) {
  const QString target = this->target();
  const auto thread = m_store->thread(target);
  if (!thread) return true;
  const QString messageId = selection.value(QStringLiteral("messageId")).toString();
  const QString text = selection.value(QStringLiteral("text")).toString();
  const qint64 start = qint64(selection.value(QStringLiteral("start")).toDouble());
  const qint64 end = qint64(selection.value(QStringLiteral("end")).toDouble());
  if (messageId.isEmpty() || text.trimmed().isEmpty() || text.size() > kMaxCitationLength || start < 0 || end <= start) {
    return true;
  }
  m_drafts[target].excerpts.append(
      {newId(), {}, {}, 1, 1, {},
       QJsonObject{{QStringLiteral("version"), 1},
                   {QStringLiteral("environmentId"), thread->environmentId},
                   {QStringLiteral("threadId"), thread->id},
                   {QStringLiteral("messageId"), messageId},
                   {QStringLiteral("text"), text},
                   {QStringLiteral("start"), start},
                   {QStringLiteral("end"), end},
                   {QStringLiteral("prefix"), selection.value(QStringLiteral("prefix")).toString().right(kCitationContextLength)},
                   {QStringLiteral("suffix"), selection.value(QStringLiteral("suffix")).toString().left(kCitationContextLength)}}});
  publish();
  return true;
}

QVariantList ComposerController::terminalContexts(const QString& target) const {
  QVariantList contexts;
  for (const Excerpt& context : m_drafts.value(target).excerpts) {
    if (!context.citation.isEmpty()) continue;
    contexts.append(QVariantMap{{QStringLiteral("id"), context.id},
                                {QStringLiteral("terminalId"), context.terminalId},
                                {QStringLiteral("terminalLabel"), context.terminalLabel},
                                {QStringLiteral("lineStart"), context.lineStart},
                                {QStringLiteral("lineEnd"), context.lineEnd},
                                {QStringLiteral("text"), context.text}});
  }
  return contexts;
}

std::optional<QString> ComposerController::draftPreview(const QString& target) const {
  const QString text = draft(target).trimmed();
  if (!text.isEmpty()) return text.section(QLatin1Char('\n'), 0, 0);
  const auto kept = m_drafts.constFind(target);
  const qsizetype count = kept == m_drafts.cend() ? 0 : kept->attachments.size() + kept->excerpts.size();
  if (count == 0) return std::nullopt;
  return count == 1 ? tr("1 attachment") : tr("%1 attachments").arg(count);
}

// As the web's composer: each excerpt is an inline link in the text
// (formatTerminalContextReference) and a record in `context`
// (terminalContextRecord); the MC swaps the links for the excerpts when it
// hands the message to the provider. A quoted reply is only a link, which
// holds all of it.
void ComposerController::withExcerpts(QJsonObject& message, const QList<Excerpt>& contexts) {
  if (contexts.isEmpty()) return;
  static const QRegularExpression unsafe(QStringLiteral("[\\[\\]\\\\\\r\\n]"));
  static const QRegularExpression spaces(QStringLiteral("\\s+"));
  QStringList links;
  QJsonArray records;
  for (const Excerpt& context : contexts) {
    if (!context.citation.isEmpty()) {
      links.append(citationLink(context.citation));
      continue;
    }
    const QString range = context.lineStart == context.lineEnd
                              ? QStringLiteral("line %1").arg(context.lineStart)
                              : QStringLiteral("lines %1-%2").arg(context.lineStart).arg(context.lineEnd);
    QString label = (context.terminalLabel + QLatin1Char(' ') + range).replace(unsafe, QStringLiteral(" "));
    label = label.replace(spaces, QStringLiteral(" ")).trimmed().left(200);
    const QString contextId = QStringLiteral("terminal_") + context.id;
    links.append(QStringLiteral("[%1](hal-c2-context://v1/terminal/%2)").arg(label, contextId));
    records.append(QJsonObject{
        {QStringLiteral("version"), 1},
        {QStringLiteral("contextId"), contextId},
        {QStringLiteral("kind"), QStringLiteral("terminal")},
        {QStringLiteral("label"), label},
        {QStringLiteral("terminalId"), context.terminalId},
        {QStringLiteral("terminalLabel"), context.terminalLabel},
        {QStringLiteral("lineStart"), context.lineStart},
        {QStringLiteral("lineEnd"), context.lineEnd},
        {QStringLiteral("text"), context.text},
    });
  }
  const QString text = message.value(QLatin1String("text")).toString();
  const QString joined = links.join(QLatin1Char(' '));
  message.insert(QStringLiteral("text"), text.isEmpty() ? joined : text + QStringLiteral("\n\n") + joined);
  if (records.isEmpty()) return;
  QJsonObject context = message.value(QLatin1String("context")).toObject();
  QJsonArray existing = context.value(QLatin1String("records")).toArray();
  for (const QJsonValue& record : records) existing.append(record);
  context.insert(QStringLiteral("version"), 1);
  context.insert(QStringLiteral("records"), existing);
  message.insert(QStringLiteral("context"), context);
}

// Answers one of the route thread's requests: a decision, answers, or (with
// neither) dismissing the questions. A request the MC says is gone closes;
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
  m_client->dispatchCommand(this, thread->environmentId, command,
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
  m_client->dispatchCommand(this, thread->environmentId, command,
                            [this, failure](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) toast(failure, *error);
                            });
  return true;
}

bool ComposerController::editQueued(const QString& target, QString runId) {
  if (target.isEmpty() || !m_draftId.isEmpty() || (m_queuedEdit && m_queuedEdit->saving)) return true;
  const QVariantList queue = turnState().value(QStringLiteral("queue")).toList();
  if (queue.isEmpty()) return true;
  if (runId.isEmpty()) runId = queue.constLast().toMap().value(QStringLiteral("runId")).toString();
  const auto entry = std::find_if(queue.cbegin(), queue.cend(), [&](const QVariant& item) {
    return item.toMap().value(QStringLiteral("runId")) == runId;
  });
  if (entry == queue.cend()) return true;
  const QString text = entry->toMap().value(QStringLiteral("text")).toString();
  // Moving to another queued message keeps the draft set aside for the first.
  if (!m_queuedEdit || m_queuedEdit->thread != target) {
    m_queuedEdit = QueuedEdit{target, {}, {}, draft(target), m_drafts.value(target).cursor};
  }
  m_queuedEdit->runId = runId;
  m_queuedEdit->original = text;
  setText(target, text, int(text.size()));
  return true;
}

bool ComposerController::saveQueuedEdit(const QString& target, const QString& text) {
  const auto thread = m_store->thread(target);
  if (!thread || m_queuedEdit->saving || text.trimmed().isEmpty()) return true;
  m_queuedEdit->saving = true;
  const QString runId = m_queuedEdit->runId;
  const QJsonObject command{{QStringLiteral("type"), QStringLiteral("queued-run.edit")},
                            {QStringLiteral("threadId"), thread->id},
                            {QStringLiteral("runId"), runId},
                            {QStringLiteral("text"), text.trimmed()}};
  m_client->dispatchCommand(this, thread->environmentId, command,
                            [this, runId](const QJsonValue&, const std::optional<QString>& error) {
                              if (!m_queuedEdit || m_queuedEdit->runId != runId) return;
                              m_queuedEdit->saving = false;
                              if (error) {
                                toast(QStringLiteral("Could not save the edited queued message."), *error);
                                publish();
                                return;
                              }
                              endQueuedEdit();
                            });
  publish();
  return true;
}

void ComposerController::endQueuedEdit(bool keepEdit) {
  if (!m_queuedEdit) return;
  const QueuedEdit edit = *std::exchange(m_queuedEdit, std::nullopt);
  if (keepEdit) {
    save();
    publish();
    return;
  }
  setText(edit.thread, edit.saved, edit.savedCursor);
}

void ComposerController::recoverQueuedEdit(const QVariantMap& turn) {
  if (!m_queuedEdit || m_queuedEdit->saving || m_queuedEdit->thread != m_thread || !m_timeline) return;
  const QVariantList queue = turn.value(QStringLiteral("queue")).toList();
  const bool queued = std::any_of(queue.cbegin(), queue.cend(), [this](const QVariant& item) {
    return item.toMap().value(QStringLiteral("runId")) == m_queuedEdit->runId;
  });
  if (queued) return;
  const bool dirty = draft(m_queuedEdit->thread) != m_queuedEdit->original;
  const bool keep = dirty && m_queuedEdit->saved.trimmed().isEmpty();
  endQueuedEdit(keep);
  if (!dirty) return;
  NativeShell::of(this)->controller<ToastController>()->show(
      keep ? QStringLiteral("info") : QStringLiteral("warning"), QStringLiteral("Queued message is no longer queued"),
      keep ? QStringLiteral("Your unsaved edit was kept in the composer.") : QStringLiteral("Your unsaved edit was discarded."));
}

QString ComposerController::openThread() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

QString ComposerController::openDraft() const {
  const NavigationController::Route& route = NativeShell::of(this)->controller<NavigationController>()->route();
  return route.kind == QLatin1String("draft") ? route.draftId : QString();
}

// A thread's own model; for a draft the project's default, as the web's
// deriveComposerModelSelection: this device's project override, the
// project's, then the default for new threads. Empty lets the MC choose.
QJsonObject ComposerController::baseSelection(const QString& key) const {
  if (const auto thread = m_store->thread(key)) return thread->modelSelection;
  auto* shell = NativeShell::of(this);
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
  m_thread = draftId.isEmpty() ? thread : draftId;
  m_draftId = draftId;
  // Leaving the thread leaves its edit, as cancelling would.
  if (m_queuedEdit && m_queuedEdit->thread != m_thread) endQueuedEdit();
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
  const QVariantMap state = turnState();
  if (m_queuedEdit) {
    recoverQueuedEdit(state);
    // Ending the edit published everything already.
    if (!m_queuedEdit) return;
  }
  if (state != m_published) {
    m_published = state;
    m_bridge->publish(QStringLiteral("turn"), state);
  }
  const QVariant composerState = this->composerState(state);
  if (composerState != m_publishedComposer) {
    m_publishedComposer = composerState;
    m_bridge->publish(QStringLiteral("composer"), composerState);
  }
  const QVariantMap picker = pickerState();
  if (picker != m_publishedPicker) {
    m_publishedPicker = picker;
    m_bridge->publish(QStringLiteral("modelPicker"), picker);
  }
  const QVariantMap stash = stashState();
  if (stash != m_publishedStash) {
    m_publishedStash = stash;
    m_bridge->publish(QStringLiteral("composerStash"), stash);
  }
  // Other windows list the draft by what it holds.
  if (!m_draftId.isEmpty()) {
    for (const auto& window : NativeShell::of(this)->shell()->windows()) window->sidebar()->draftEdited(m_draftId);
  }
}

QVariantMap ComposerController::turnState() const {
  const auto thread = m_store->thread(m_thread);
  const bool isRunning = thread && thread->activeRunId.has_value();
  // A new thread's draft.
  if (!m_draftId.isEmpty()) {
    const bool kept = NativeShell::of(this)->controller<DraftController>()->draft(m_draftId).has_value();
    return {{QStringLiteral("threadKey"), kept ? m_draftId : QString()},
            {QStringLiteral("kind"), QStringLiteral("draft")},
            {QStringLiteral("running"), false},
            {QStringLiteral("sending"), m_launching.contains(m_draftId)},
            {QStringLiteral("approvals"), QVariantList()},
            {QStringLiteral("questions"), QVariantList()},
            {QStringLiteral("plan"), QVariant()},
            {QStringLiteral("queue"), QVariantList()}};
  }
  QVariantMap state{{QStringLiteral("threadKey"), thread ? m_thread : QString()},
                    {QStringLiteral("kind"), QStringLiteral("thread")},
                    {QStringLiteral("running"), isRunning},
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

// --- The draft and what the composer shows -------------------------------------

QString ComposerController::target() const {
  if (!m_draftId.isEmpty()) {
    return NativeShell::of(this)->controller<DraftController>()->draft(m_draftId) ? m_draftId : QString();
  }
  return m_store->thread(m_thread) ? m_thread : QString();
}

QString ComposerController::draft(const QString& target) const {
  if (const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(target)) return kept->text;
  return m_drafts.value(target).text;
}

QVariant ComposerController::setting(const QString& key) const {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return settings ? settings->setting(key) : QVariant();
}

void ComposerController::setText(const QString& target, const QString& text, int cursor, const QVariant& edit) {
  Draft& kept = m_drafts[target];
  if (edit.isValid() && !edit.isNull()) kept.edit = edit;
  const bool changed = text != draft(target);
  cursor = std::clamp(cursor, 0, int(text.size()));
  if (changed || cursor != kept.cursor) kept.dismissed = false;
  kept.cursor = cursor;
  if (changed) {
    if (NativeShell::of(this)->controller<DraftController>()->draft(target)) {
      // A new thread's text is kept with its draft.
      NativeShell::of(this)->controller<DraftController>()->setText(target, text);
      spread();
    } else {
      kept.text = text;
      save();
    }
  }
  searchPaths(target);
  publish();
}

bool ComposerController::slashMode(const QString& target, const QString& text) {
  static const QRegularExpression command(QStringLiteral("^/(plan|default)\\s*$"), QRegularExpression::CaseInsensitiveOption);
  const QRegularExpressionMatch match = command.match(text.trimmed());
  if (!match.hasMatch() || !m_drafts.value(target).attachments.isEmpty() ||
      !m_drafts.value(target).excerpts.isEmpty() || !planModeOn(instanceOf(selection(target)))) {
    return false;
  }
  setInteractionMode(target, match.captured(1).toLower());
  setText(target, QString(), 0);
  return true;
}

void ComposerController::setInteractionMode(const QString& target, const QString& mode) {
  if (mode != QLatin1String("plan") && mode != QLatin1String("default")) return;
  if (mode == QLatin1String("plan") && !planModeOn(instanceOf(selection(target)))) return;
  if (mode == interactionModeOf(target)) return;
  m_drafts[target].interactionMode = mode;
  save();
  publish();
}

// As the web's handleModelSelect: a started thread keeps its provider, and a
// model its session cannot switch to says why instead.
bool ComposerController::selectModel(const QString& target, const QString& instanceId, const QString& model) {
  if (instanceId.isEmpty() || model.isEmpty()) return false;
  // Only what the picker offers: a ready provider's own models.
  const composer::Instance* next = composer::find(m_catalogue, instanceId);
  if (!next || !next->ready() || composer::findModel(*next, model).isEmpty()) return false;
  const std::optional<composer::Lock> lock = lockOf(target);
  if (lock && next->driver != lock->driver) return false;
  const auto thread = m_store->thread(target);
  if (thread && thread->runtime) {
    const QJsonObject current = thread->modelSelection;
    if (const auto block = composer::blockReason(m_catalogue, current.value(QLatin1String("instanceId")).toString(),
                                                 current.value(QLatin1String("model")).toString(), instanceId, model)) {
      NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("warning"), block->title, block->description);
      return false;
    }
  }
  Draft& kept = m_drafts[target];
  const QJsonObject current = selection(target);
  QJsonObject chosen{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}};
  // Options belong to the provider they were set on.
  if (current.value(QLatin1String("instanceId")).toString() == instanceId && current.contains(QLatin1String("options"))) {
    chosen.insert(QStringLiteral("options"), current.value(QLatin1String("options")));
  }
  kept.modelSelection = chosen;
  save();
  publish();
  return true;
}

bool ComposerController::setOption(const QString& target, const QString& id, const QVariant& value) {
  QJsonObject chosen = selection(target);
  const composer::Instance* instance = instanceOf(chosen);
  if (!instance || !instance->ready()) return false;
  const QJsonArray descriptors =
      composer::descriptors(composer::findModel(*instance, chosen.value(QLatin1String("model")).toString()),
                            chosen.value(QLatin1String("options")).toArray(), planModeOn(instance));
  const std::optional<QJsonArray> options = composer::applyOption(descriptors, id, value);
  if (!options) return false;
  chosen.insert(QStringLiteral("options"), *options);
  m_drafts[target].modelSelection = chosen;
  save();
  publish();
  return true;
}

// Puts the suggestion in the trigger's place, as the web's
// applyPromptReplacement; the composer's own commands act instead.
bool ComposerController::selectSuggestion(const QString& target, const QString& id) {
  const QString text = draft(target);
  const std::optional<composer::Trigger> trigger = composer::trigger(text, m_drafts.value(target).cursor);
  if (!trigger || m_drafts.value(target).dismissed) return false;
  const QList<composer::Suggestion> offered = suggestions(target, trigger);
  const auto chosen = std::find_if(offered.cbegin(), offered.cend(), [&](const composer::Suggestion& item) { return item.id == id; });
  if (chosen == offered.cend()) return false;
  const QString replacement = chosen->replacement;
  int end = trigger->end;
  if (replacement.endsWith(u' ') && end < text.size() && text.at(end) == u' ') ++end;
  const QString next = text.left(trigger->start) + replacement + text.mid(end);
  setText(target, next, trigger->start + int(replacement.size()));
  if (id == QLatin1String("slash:model")) {
    m_bridge->sendToBricks(QStringLiteral("composer.modelPicker.toggle"));
  } else if (id == QLatin1String("slash:plan") || id == QLatin1String("slash:default")) {
    setInteractionMode(target, id.mid(6));
  }
  return true;
}

QList<composer::Suggestion> ComposerController::suggestions(const QString& target,
                                                            const std::optional<composer::Trigger>& trigger) const {
  if (!trigger) return {};
  const composer::Instance* instance = instanceOf(selection(target));
  if (trigger->kind == QLatin1String("slash-command")) {
    return composer::slashItems(instance, *trigger, planModeOn(instance), setting(QStringLiteral("showSkillsInSlashMenu")).toBool(),
                                draft(target).trimmed() == u'/' + trigger->query);
  }
  if (trigger->kind == QLatin1String("skill")) return composer::skillItems(instance, *trigger);
  if (trigger->kind == QLatin1String("path") && m_paths.target == target && m_paths.query == trigger->query) {
    return composer::pathItems(m_paths.entries);
  }
  return {};
}

// The @ menu asks the MC's workspace search (the Files tab's) for the
// route's checkout; the answer counts only while it is still the question.
void ComposerController::searchPaths(const QString& target) {
  const std::optional<composer::Trigger> trigger = composer::trigger(draft(target), m_drafts.value(target).cursor);
  if (!trigger || trigger->kind != QLatin1String("path") || trigger->query.isEmpty()) return;
  if (m_paths.target == target && m_paths.query == trigger->query) return;
  const auto& place = NativeShell::of(this)->controller<WorkspaceController>()->place();
  if (!place || place->cwd().isEmpty() || !m_store->environmentOnline(place->environmentId)) return;
  m_paths = {target, trigger->query, false, {}, m_paths.request + 1};
  const int request = m_paths.request;
  WorkspaceFiles::searchEntries(m_client, this, place->environmentId, place->cwd(), trigger->query, 80,
                                [this, request](const QList<FileTreeModel::Entry>& entries, bool,
                                                const std::optional<QString>&) {
                                  if (request != m_paths.request) return;
                                  m_paths.done = true;
                                  for (const FileTreeModel::Entry& entry : entries) {
                                    m_paths.entries.append({entry.path, entry.directory});
                                  }
                                  publish();
                                });
}

void ComposerController::refreshCatalogue() {
  const QJsonObject config = NativeShell::of(this)->controller<WorkspaceController>()->environmentConfig();
  m_catalogue = composer::instances(config.value(QLatin1String("providers")).toArray());
}

const composer::Instance* ComposerController::instanceOf(const QJsonObject& selection) const {
  return composer::find(m_catalogue, selection.value(QLatin1String("instanceId")).toString());
}

QJsonObject ComposerController::selection(const QString& target) const {
  QJsonObject chosen = m_drafts.value(target).modelSelection.value_or(baseSelection(target));
  if (chosen.value(QLatin1String("instanceId")).toString().isEmpty()) {
    const auto ready = std::find_if(m_catalogue.cbegin(), m_catalogue.cend(), [](const composer::Instance& instance) {
      return instance.ready();
    });
    if (ready == m_catalogue.cend()) return {};
    return {{QStringLiteral("instanceId"), ready->instanceId}, {QStringLiteral("model"), composer::defaultModel(*ready)}};
  }
  if (chosen.value(QLatin1String("model")).toString().isEmpty()) {
    if (const composer::Instance* instance = instanceOf(chosen)) {
      chosen.insert(QStringLiteral("model"), composer::defaultModel(*instance));
    }
  }
  return chosen;
}

bool ComposerController::started(const QString& target) const {
  const auto thread = m_store->thread(target);
  return thread && (thread->latestRunId || thread->latestUserMessageAt || thread->runtime);
}

std::optional<composer::Lock> ComposerController::lockOf(const QString& target) const {
  if (!started(target)) return std::nullopt;
  const composer::Instance* instance = instanceOf(m_store->thread(target)->modelSelection);
  if (!instance) return std::nullopt;
  return composer::Lock{instance->driver, instance->groupKey};
}

bool ComposerController::planModeOn(const composer::Instance* instance) const {
  return instance && instance->showInteractionModeToggle && setting(QStringLiteral("planModeEnabled")).toBool();
}

QString ComposerController::runtimeModeOf(const QString& target) const {
  if (const QString mode = m_drafts.value(target).runtimeMode; !mode.isEmpty()) return mode;
  if (const auto thread = m_store->thread(target); thread && !thread->runtimeMode.isEmpty()) return thread->runtimeMode;
  return QStringLiteral("full-access");
}

// The mode a send uses: plan only while plan mode is on, as the web's.
QString ComposerController::interactionModeOf(const QString& target) const {
  if (!planModeOn(instanceOf(selection(target)))) return QStringLiteral("default");
  if (const QString mode = m_drafts.value(target).interactionMode; !mode.isEmpty()) return mode;
  if (const auto thread = m_store->thread(target); thread && !thread->interactionMode.isEmpty()) {
    return thread->interactionMode;
  }
  return QStringLiteral("default");
}

// ShellComposerState, as the web's buildShellComposerState worked it out.
QVariant ComposerController::composerState(const QVariantMap& turn) const {
  const QString target = this->target();
  if (target.isEmpty()) return QVariant::fromValue(nullptr);
  const bool isDraft = !m_draftId.isEmpty();
  const auto thread = m_store->thread(target);
  const Draft kept = m_drafts.value(target);
  const QString text = draft(target);
  const int cursor = std::clamp(kept.cursor, 0, int(text.size()));
  const QJsonObject chosen = selection(target);
  const composer::Instance* instance = instanceOf(chosen);
  const bool planOn = planModeOn(instance);

  const std::optional<composer::Trigger> trigger = kept.dismissed ? std::nullopt : composer::trigger(text, cursor);
  QVariantList suggestionList;
  for (const composer::Suggestion& item : suggestions(target, trigger)) {
    suggestionList.append(QVariantMap{{QStringLiteral("id"), item.id},
                                      {QStringLiteral("kind"), item.kind},
                                      {QStringLiteral("label"), item.label},
                                      {QStringLiteral("description"), item.description}});
  }
  QVariant emptyText = QVariant::fromValue(nullptr);
  if (trigger && suggestionList.isEmpty()) {
    // A path search says nothing until it has answered.
    const bool waiting = trigger->kind == QLatin1String("path") &&
                         (trigger->query.isEmpty() || m_paths.target != target || m_paths.query != trigger->query ||
                          !m_paths.done);
    if (!waiting && !composer::emptyText(trigger->kind).isEmpty()) emptyText = composer::emptyText(trigger->kind);
  }

  QVariantList attachments;
  for (const Attachment& attachment : kept.attachments) {
    auto preview = m_previews.constFind(attachment.id);
    if (preview == m_previews.cend()) {
      // A new image is when the ones that left the drafts and the stash are forgotten.
      QSet<QString> held;
      for (const Draft& draft : std::as_const(m_drafts)) {
        for (const Attachment& image : draft.attachments) held.insert(image.id);
      }
      for (const StashEntry& entry : std::as_const(m_kept.stash)) {
        for (const Attachment& image : entry.attachments) held.insert(image.id);
      }
      m_previews.removeIf([&](const auto& known) { return !held.contains(known.key()); });
      preview = m_previews.insert(attachment.id, thumbnail(attachment.dataUrl));
    }
    attachments.append(QVariantMap{{QStringLiteral("id"), attachment.id},
                                   {QStringLiteral("name"), attachment.name},
                                   {QStringLiteral("preview"), *preview}});
  }
  QVariantList terminalContexts;
  QVariantList citations;
  for (const Excerpt& context : kept.excerpts) {
    if (!context.citation.isEmpty()) {
      const QJsonValue comment = context.citation.value(QLatin1String("comment"));
      citations.append(QVariantMap{{QStringLiteral("id"), context.id},
                                   {QStringLiteral("text"), context.citation.value(QLatin1String("text")).toString()},
                                   {QStringLiteral("comment"), comment.isString() ? QVariant(comment.toString())
                                                                                  : QVariant::fromValue(nullptr)}});
      continue;
    }
    terminalContexts.append(QVariantMap{{QStringLiteral("id"), context.id},
                                        {QStringLiteral("label"), context.terminalLabel},
                                        {QStringLiteral("lineStart"), context.lineStart},
                                        {QStringLiteral("lineEnd"), context.lineEnd}});
  }
  const QVariantList approvals = turn.value(QStringLiteral("approvals")).toList();
  const QVariantList questions = turn.value(QStringLiteral("questions")).toList();
  const QVariantMap firstQuestion =
      questions.isEmpty() ? QVariantMap()
                          : questions.constFirst().toMap().value(QStringLiteral("questions")).toList().value(0).toMap();
  const bool choiceOnly = !firstQuestion.isEmpty() && !firstQuestion.value(QStringLiteral("allowCustomAnswer")).toBool();
  const bool planOffered = !turn.value(QStringLiteral("plan")).isNull() && turn.value(QStringLiteral("plan")).isValid();
  const bool showPlanFollowUp = planOffered && kept.attachments.isEmpty() && kept.excerpts.isEmpty();
  QString environmentId = thread ? thread->environmentId : QString();
  if (isDraft) {
    if (const auto draft = NativeShell::of(this)->controller<DraftController>()->draft(target)) {
      environmentId = draft->environmentId;
    }
  }
  const bool offline = !m_store->environmentOnline(environmentId);
  const bool noProvider =
      std::none_of(m_catalogue.cbegin(), m_catalogue.cend(), [](const composer::Instance& entry) { return entry.ready(); });
  const bool busy = isDraft && m_launching.contains(target);
  const bool hasContent = !text.trimmed().isEmpty() || !kept.attachments.isEmpty() || !kept.excerpts.isEmpty();
  const bool isRunning = thread && thread->activeRunId.has_value();

  QString placeholder = QStringLiteral("Ask anything, @tag files/folders, $use skills, or / for commands");
  if (!approvals.isEmpty()) {
    placeholder = QStringLiteral("Resolve this approval request to continue");
  } else if (showPlanFollowUp) {
    placeholder = QStringLiteral("Add feedback to refine the plan, or leave this blank to implement it");
  } else if (noProvider) {
    placeholder = QStringLiteral("Enable a provider in Settings to send a message");
  } else if (offline) {
    placeholder = QStringLiteral("Ask for changes, send follow-ups, or attach images");
  }
  QVariant disabledReason = QVariant::fromValue(nullptr);
  if (offline) {
    disabledReason = QStringLiteral("Not connected");
  } else if (noProvider) {
    disabledReason = QStringLiteral("No provider available");
  }

  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  const QString selectedInstance = chosen.value(QLatin1String("instanceId")).toString();
  const QString selectedModel = chosen.value(QLatin1String("model")).toString();
  const QVariantList options =
      instance ? composer::shellOptions(composer::descriptors(composer::findModel(*instance, selectedModel),
                                                              chosen.value(QLatin1String("options")).toArray(), planOn))
               : QVariantList();
  const auto orNull = [](const QString& value) { return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value); };
  return QVariantMap{
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), isDraft ? QStringLiteral("draft") : QStringLiteral("server")},
      {QStringLiteral("edit"), kept.edit.isValid() ? kept.edit : QVariant::fromValue(nullptr)},
      {QStringLiteral("text"), text},
      {QStringLiteral("cursor"), cursor},
      {QStringLiteral("triggerKind"), trigger ? QVariant(trigger->kind) : QVariant::fromValue(nullptr)},
      {QStringLiteral("suggestions"), suggestionList},
      {QStringLiteral("suggestionsEmptyText"), emptyText},
      {QStringLiteral("attachments"), attachments},
      {QStringLiteral("terminalContexts"), terminalContexts},
      {QStringLiteral("citations"), citations},
      {QStringLiteral("placeholder"), placeholder},
      {QStringLiteral("editorDisabled"), !approvals.isEmpty() || choiceOnly},
      {QStringLiteral("canSend"), !(busy || offline || noProvider) && (hasContent || showPlanFollowUp)},
      {QStringLiteral("sendDisabledReason"), disabledReason},
      {QStringLiteral("isRunning"), isRunning},
      {QStringLiteral("followUpBehavior"), setting(QStringLiteral("followUpBehavior")).toString() == QLatin1String("queue")
                                               ? QStringLiteral("queue")
                                               : QStringLiteral("steer")},
      {QStringLiteral("enterIntents"), composer::enterIntents(keys->resolved(), keys->mac(),
                                                              setting(QStringLiteral("sendShortcut")).toString(), isDraft,
                                                              isRunning)},
      {QStringLiteral("isSendBusy"), busy},
      {QStringLiteral("isConnecting"), false},
      {QStringLiteral("pendingApprovalCount"), approvals.size()},
      {QStringLiteral("pendingUserInputCount"), questions.size()},
      {QStringLiteral("showPlanFollowUpPrompt"), showPlanFollowUp},
      {QStringLiteral("selectedInstanceId"), orNull(selectedInstance)},
      {QStringLiteral("selectedModel"), orNull(selectedModel)},
      {QStringLiteral("options"), options},
      {QStringLiteral("runtimeMode"), runtimeModeOf(target)},
      {QStringLiteral("runtimeModes"), composer::runtimeModes(instance)},
      {QStringLiteral("interactionMode"), interactionModeOf(target)},
      {QStringLiteral("showInteractionModeToggle"), planOn},
      {QStringLiteral("editingQueuedRunId"), m_queuedEdit && m_queuedEdit->thread == target
                                                 ? QVariant(m_queuedEdit->runId)
                                                 : QVariant::fromValue(nullptr)},
  };
}

// ShellModelPickerState: the rail for the route's thread or draft.
QVariantMap ComposerController::pickerState() const {
  const QString target = this->target();
  const auto thread = m_store->thread(target);
  const QJsonObject chosen = selection(target);
  const QJsonObject current = thread ? thread->modelSelection : QJsonObject();
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  const composer::ModelPrefs prefs =
      settings ? composer::modelPrefs(QJsonValue::fromVariant(settings->deviceValue(QStringLiteral("favorites"))),
                                      QJsonValue::fromVariant(settings->deviceValue(QStringLiteral("providerModelPreferences"))))
               : composer::ModelPrefs();
  const std::optional<composer::Lock> lock = lockOf(target);
  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  const auto key = [keys](const QString& command) { return composer::pickerKey(keys->resolved(), keys->mac(), command); };
  QVariantList jump;
  for (int n = 1; n <= 9; ++n) jump.append(key(QStringLiteral("modelPicker.jump.%1").arg(n)));
  const QVariant toggle = key(QStringLiteral("modelPicker.toggle"));
  return {
      {QStringLiteral("instances"),
       composer::pickerInstances(m_catalogue, prefs, chosen.value(QLatin1String("instanceId")).toString(),
                                 chosen.value(QLatin1String("model")).toString(), lock, thread && thread->runtime,
                                 current.value(QLatin1String("instanceId")).toString(),
                                 current.value(QLatin1String("model")).toString())},
      {QStringLiteral("locked"), lock.has_value()},
      {QStringLiteral("shortcut"),
       toggle.isNull() ? QVariant::fromValue(nullptr) : toggle.toMap().value(QStringLiteral("label"))},
      {QStringLiteral("previousProvider"), key(QStringLiteral("modelPicker.previousProvider"))},
      {QStringLiteral("nextProvider"), key(QStringLiteral("modelPicker.nextProvider"))},
      {QStringLiteral("jump"), jump},
  };
}

// --- Keeping drafts ---------------------------------------------------------------

// Each target's text and choices, as {targets: {<target>: {text, modelSelection,
// runtimeMode, interactionMode}}, stash: [{id, createdAt, text, attachments,
// terminalContexts}]} (a quoted reply among them carries its `citation`), and the drafts' images beside them (imagesPath).
void ComposerController::setStorePath(const QString& path) {
  m_kept.path = path;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return;
  const QJsonObject stored = QJsonDocument::fromJson(file.readAll()).object();
  m_kept.stash.clear();
  for (const QJsonValue& value : stored.value(QLatin1String("stash")).toArray()) {
    const QJsonObject entry = value.toObject();
    StashEntry kept{str(entry, QLatin1String("id")),
                    QDateTime::fromString(str(entry, QLatin1String("createdAt")), Qt::ISODateWithMs),
                    str(entry, QLatin1String("text")),
                    {},
                    {}};
    for (const QJsonValue& image : entry.value(QLatin1String("attachments")).toArray()) {
      const QJsonObject a = image.toObject();
      kept.attachments.append({str(a, QLatin1String("id")), str(a, QLatin1String("name")), str(a, QLatin1String("mimeType")),
                               qint64(a.value(QLatin1String("sizeBytes")).toDouble()), str(a, QLatin1String("dataUrl")),
                               a.value(QLatin1String("source")).toObject()});
    }
    for (const QJsonValue& context : entry.value(QLatin1String("terminalContexts")).toArray()) {
      const QJsonObject t = context.toObject();
      kept.excerpts.append({str(t, QLatin1String("id")), str(t, QLatin1String("terminalId")),
                                    str(t, QLatin1String("terminalLabel")), t.value(QLatin1String("lineStart")).toInt(1),
                                    t.value(QLatin1String("lineEnd")).toInt(1), str(t, QLatin1String("text")),
                                    t.value(QLatin1String("citation")).toObject()});
    }
    if (!kept.id.isEmpty()) m_kept.stash.append(kept);
  }
  const QJsonObject targets = stored.value(QLatin1String("targets")).toObject();
  for (auto it = targets.begin(); it != targets.end(); ++it) {
    const QJsonObject entry = it.value().toObject();
    Draft& kept = m_drafts[it.key()];
    kept.text = entry.value(QLatin1String("text")).toString();
    kept.cursor = int(kept.text.size());
    if (entry.value(QLatin1String("modelSelection")).isObject()) {
      kept.modelSelection = entry.value(QLatin1String("modelSelection")).toObject();
    }
    kept.runtimeMode = entry.value(QLatin1String("runtimeMode")).toString();
    kept.interactionMode = entry.value(QLatin1String("interactionMode")).toString();
  }
  QFile images(imagesPath());
  if (images.open(QIODevice::ReadOnly)) {
    const QByteArray data = images.readAll();
    const QJsonObject kept = QJsonDocument::fromJson(data).object().value(QLatin1String("targets")).toObject();
    for (auto it = kept.begin(); it != kept.end(); ++it) {
      QList<Attachment>& attachments = m_drafts[it.key()].attachments;
      for (const QJsonValue& value : it.value().toArray()) {
        const QJsonObject image = value.toObject();
        const QString dataUrl = image.value(QLatin1String("dataUrl")).toString();
        if (!dataUrl.startsWith(QLatin1String("data:image/"))) continue;
        attachments.append({image.value(QLatin1String("id")).toString(), image.value(QLatin1String("name")).toString(),
                            image.value(QLatin1String("mimeType")).toString(),
                            qint64(image.value(QLatin1String("sizeBytes")).toDouble()), dataUrl,
                            image.value(QLatin1String("source")).toObject()});
      }
    }
    m_kept.images = imagesSignature(kept);
  }
  publish();
}

QString ComposerController::imagesPath() const {
  if (m_kept.path.isEmpty()) return {};
  QString path = m_kept.path;
  if (path.endsWith(QLatin1String(".json"))) path.chop(5);
  return path + QStringLiteral("-images.json");
}

void ComposerController::spread() const {
  for (const auto& window : NativeShell::of(this)->shell()->windows()) {
    auto* composer = window->controller<ComposerController>();
    if (composer && composer != this) QMetaObject::invokeMethod(composer, &ComposerController::publish, Qt::QueuedConnection);
  }
}

void ComposerController::save() const {
  spread();
  if (m_kept.path.isEmpty()) return;
  QJsonObject targets;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    const Draft& kept = it.value();
    // An edited queued message is not the thread's draft.
    const QString text = m_queuedEdit && m_queuedEdit->thread == it.key() ? m_queuedEdit->saved : kept.text;
    QJsonObject entry;
    if (!text.isEmpty()) entry.insert(QStringLiteral("text"), text);
    if (kept.modelSelection) entry.insert(QStringLiteral("modelSelection"), *kept.modelSelection);
    if (!kept.runtimeMode.isEmpty()) entry.insert(QStringLiteral("runtimeMode"), kept.runtimeMode);
    if (!kept.interactionMode.isEmpty()) entry.insert(QStringLiteral("interactionMode"), kept.interactionMode);
    if (!entry.isEmpty()) targets.insert(it.key(), entry);
  }
  QJsonArray stash;
  for (const StashEntry& entry : m_kept.stash) {
    QJsonArray images;
    for (const Attachment& a : entry.attachments) {
      QJsonObject image{{QStringLiteral("id"), a.id}, {QStringLiteral("name"), a.name},
                        {QStringLiteral("mimeType"), a.mimeType}, {QStringLiteral("sizeBytes"), double(a.sizeBytes)},
                        {QStringLiteral("dataUrl"), a.dataUrl}};
      if (!a.source.isEmpty()) image.insert(QStringLiteral("source"), a.source);
      images.append(image);
    }
    QJsonArray contexts;
    for (const Excerpt& t : entry.excerpts) {
      QJsonObject context{{QStringLiteral("id"), t.id}, {QStringLiteral("terminalId"), t.terminalId},
                          {QStringLiteral("terminalLabel"), t.terminalLabel}, {QStringLiteral("lineStart"), t.lineStart},
                          {QStringLiteral("lineEnd"), t.lineEnd}, {QStringLiteral("text"), t.text}};
      if (!t.citation.isEmpty()) context.insert(QStringLiteral("citation"), t.citation);
      contexts.append(context);
    }
    stash.append(QJsonObject{{QStringLiteral("id"), entry.id},
                             {QStringLiteral("createdAt"), entry.createdAt.toString(Qt::ISODateWithMs)},
                             {QStringLiteral("text"), entry.text},
                             {QStringLiteral("attachments"), images},
                             {QStringLiteral("terminalContexts"), contexts}});
  }
  QFile file(m_kept.path);
  if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
    QJsonObject stored{{QStringLiteral("targets"), targets}};
    if (!stash.isEmpty()) stored.insert(QStringLiteral("stash"), stash);
    file.write(QJsonDocument(stored).toJson(QJsonDocument::Compact));
  }
  // The drafts' images, apart: rewritten only when they change.
  QJsonObject images;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    QJsonArray list;
    for (const Attachment& attachment : it.value().attachments) {
      QJsonObject image{{QStringLiteral("id"), attachment.id},
                        {QStringLiteral("name"), attachment.name},
                        {QStringLiteral("mimeType"), attachment.mimeType},
                        {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                        {QStringLiteral("dataUrl"), attachment.dataUrl}};
      if (!attachment.source.isEmpty()) image.insert(QStringLiteral("source"), attachment.source);
      list.append(image);
    }
    if (!list.isEmpty()) images.insert(it.key(), list);
  }
  const QString joined = imagesSignature(images);
  if (joined == m_kept.images) return;
  m_kept.images = joined;
  QFile imagesFile(imagesPath());
  if (images.isEmpty()) {
    imagesFile.remove();
    return;
  }
  if (!imagesFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
  imagesFile.write(QJsonDocument(QJsonObject{{QStringLiteral("targets"), images}}).toJson(QJsonDocument::Compact));
}
