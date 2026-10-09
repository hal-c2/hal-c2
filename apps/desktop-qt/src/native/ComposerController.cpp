#include "ComposerController.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStringList>
#include <QTimer>
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
// How long a new thread waits to be placed before it starts where the user
// picked: the MC itself waits a second for the picked machine and a second for
// the others.
constexpr int kPlacementWaitMs = 3000;
// apps/web/src/components/chat/ComposerPendingApprovalPanel.tsx.
const QString kProviderGone = QStringLiteral("Provider process is gone — interrupt or restart the run to respond.");

QString str(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// McClient's answer to a call the connection dropped under: the MC may or
// may not have carried it out ("not connected" is one that never left).
bool unanswered(const std::optional<QString>& error) {
  return error && *error == QLatin1String("disconnected");
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
    return QVariantMap{{QStringLiteral("decision"), decision},
                       {QStringLiteral("label"), label},
                       {QStringLiteral("warning"), QString()}};
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
      signature.append(it.key() + u'/' + image.toObject().value(QLatin1String("id")).toString() + u'/' +
                       image.toObject().value(QLatin1String("remoteId")).toString() + image.toObject().value(QLatin1String("upload")).toString());
    }
  }
  return signature.join(u'\n');
}

QString newId() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

// The id of the newest of a thread's `message` entities the user sent (not an
// agent or automation), leaving out `except`; empty for none.
QString newestUserMessage(const QHash<QString, QJsonObject>& messages, const QSet<QString>& except) {
  QString newest;
  QString newestAt;
  for (auto it = messages.cbegin(); it != messages.cend(); ++it) {
    const QString by = str(*it, QLatin1String("createdBy"));
    if (except.contains(it.key()) || str(*it, QLatin1String("role")) != QLatin1String("user") ||
        (!by.isEmpty() && by != QLatin1String("user"))) {
      continue;
    }
    // The MC's ISO times, to the millisecond, read in order as text.
    const QString at = str(*it, QLatin1String("createdAt"));
    if (newest.isEmpty() || at > newestAt || (at == newestAt && it.key() > newest)) {
      newest = it.key();
      newestAt = at;
    }
  }
  return newest;
}

// apps/web/src/promptStashStore.ts MAX_STASH_ENTRIES.
constexpr qsizetype kMaxStashEntries = 20;
// packages/contracts/src/chatAttachment.ts PROVIDER_SEND_TURN_MAX_INPUT_CHARS.
constexpr qsizetype kMaxPromptChars = 120000;
// apps/web/src/components/chat/composerPromptHistory.ts CLAUDE_ULTRATHINK_PREFIX.
const QString kUltrathinkPrefix = QStringLiteral("Ultrathink:\n");

// What the user typed of a sent message (the web's recallableComposerPrompt):
// without the Ultrathink prefix and the context links a send appends; a plan
// the app asked to implement is not a prompt.
QString recallable(QString prompt) {
  static const QRegularExpression contextLink(QStringLiteral(" ?\\[[^\\]]*\\]\\(hal-c2-context://[^)]*\\)"));
  prompt = prompt.trimmed();
  if (prompt.startsWith(kUltrathinkPrefix)) prompt = prompt.mid(kUltrathinkPrefix.size());
  prompt.remove(contextLink);
  prompt = prompt.trimmed();
  return prompt.startsWith(kImplementPrefix.trimmed()) ? QString() : prompt;
}

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
  connect(m_store, &ShellStore::changed, this, [this] {
    carryDrafts();
    reconcileUnsent();
    publish();
  });
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
  if (action == QLatin1String("composer.history.step")) {
    if (!target.isEmpty()) stepHistory(target, map.value(QStringLiteral("direction")).toString() != QLatin1String("forward"));
    return true;
  }
  if (action == QLatin1String("composer.terminalContext.add")) return addTerminalContext(map);
  if (action == QLatin1String("composer.reviewComment.add")) return addReviewComment(map);
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
  if (action == QLatin1String("composer.terminalContext.remove") || action == QLatin1String("composer.citation.remove") ||
      action == QLatin1String("composer.reviewComment.remove")) {
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
  if (action == QLatin1String("composer.model.multiple.toggle")) {
    if (!target.isEmpty()) toggleMultipleModel(target, map.value(QStringLiteral("instanceId")).toString(), map.value(QStringLiteral("model")).toString());
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
  if (action == QLatin1String("composer.usageLimits.dismiss")) {
    if (m_usageLimits.remove(target) > 0) publish();
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
  if (action == QLatin1String("composer.attach")) {
    if (target.isEmpty()) return true;
    const QVariantList folders = map.value(QStringLiteral("folders")).toList();
    if (!folders.isEmpty()) attachFolders(target, folders);
    const QVariantList files = map.value(QStringLiteral("files")).toList();
    if (files.isEmpty()) return true;
    // While the agent waits on an answer, files are the answer's.
    const QVariantList questions = turnState().value(QStringLiteral("questions")).toList();
    if (!questions.isEmpty()) return attachToAnswer(questions.constFirst().toMap().value(QStringLiteral("requestId")).toString(), {}, files);
    return attach(files);
  }
  if (action == QLatin1String("composer.question.attach")) {
    return attachToAnswer(map.value(QStringLiteral("requestId")).toString(), map.value(QStringLiteral("questionId")).toString(),
                          map.value(QStringLiteral("files")).toList());
  }
  if (action == QLatin1String("composer.attachment.remove") || action == QLatin1String("composer.question.attachment.remove")) {
    const QString id = map.value(QStringLiteral("id")).toString();
    const Attachment* found = findAttachment(id);
    if (!found) return true;
    // An upload no message took is the MC's to drop.
    if (!found->remoteId.isEmpty()) {
      m_client->call(this, found->environmentId, QStringLiteral("attachments.delete"),
                     QJsonObject{{QStringLiteral("attachmentId"), found->remoteId}}, [](const QJsonValue&, const std::optional<QString>&) {});
    }
    const auto matches = [&](const Attachment& attachment) { return attachment.id == id; };
    for (Draft& draft : m_drafts) draft.attachments.removeIf(matches);
    for (auto& questions : m_answerFiles) {
      for (QList<Attachment>& files : questions) files.removeIf(matches);
    }
    save();
    publish();
    return true;
  }
  if (action == QLatin1String("composer.attachment.retry")) {
    const QString id = map.value(QStringLiteral("id")).toString();
    if (const Attachment* found = findAttachment(id); found && found->file && found->upload == QLatin1String("failed")) {
      uploadFile(id, found->environmentId.isEmpty() ? environmentOf(m_thread) : found->environmentId);
    }
    return true;
  }
  if (action == QLatin1String("composer.approval.respond")) {
    return respond(map.value(QStringLiteral("requestId")).toString(),
                   {{QStringLiteral("decision"), map.value(QStringLiteral("decision")).toString()}},
                   QStringLiteral("Failed to submit approval decision."));
  }
  if (action == QLatin1String("composer.question.answer")) {
    const QString requestId = map.value(QStringLiteral("requestId")).toString();
    QJsonObject fields{{QStringLiteral("answers"), QJsonObject::fromVariantMap(map.value(QStringLiteral("answers")).toMap())}};
    QJsonObject files;
    const QHash<QString, QList<Attachment>> attached = m_answerFiles.value(requestId);
    for (auto it = attached.cbegin(); it != attached.cend(); ++it) {
      if (it->isEmpty()) continue;
      if (filesBlock(*it, QStringLiteral("answering"))) return true;
      files.insert(it.key(), fileRecords(*it));
    }
    if (!files.isEmpty()) fields.insert(QStringLiteral("attachmentsByQuestionId"), files);
    return respond(requestId, fields, QStringLiteral("Failed to submit answers."));
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

void ComposerController::stepHistory(const QString& target, bool backward) {
  if (!m_timeline || target != m_thread) return;
  const Draft kept = m_drafts.value(target);
  const QString current = draft(target);
  // Oldest first; a prompt sent twice in a row is one entry, its newest.
  QList<std::pair<QString, QString>> entries;
  for (const QJsonObject& item : itemsOf(m_timeline->entities(QStringLiteral("turn-item")), QStringLiteral("user_message"))) {
    const QString prompt = recallable(str(item, QLatin1String("text")));
    if (prompt.isEmpty()) continue;
    if (!entries.isEmpty() && entries.constLast().second == prompt) entries.removeLast();
    entries.append({str(item, QLatin1String("id")), prompt});
  }
  qsizetype active = -1;
  if (m_recall && m_recall->target == target && m_recall->recalled == current) {
    for (qsizetype i = 0; i < entries.size(); ++i) {
      if (entries.at(i).first == m_recall->entryId) active = i;
    }
    for (qsizetype i = entries.size() - 1; active < 0 && i >= 0; --i) {
      if (entries.at(i).second == current) active = i;
    }
  }
  qsizetype next = -1;
  if (backward) {
    // Only an empty composer starts a recall: attachments count as content.
    if (active < 0 && (!current.isEmpty() || !kept.attachments.isEmpty() || !kept.excerpts.isEmpty())) return;
    next = active < 0 ? entries.size() - 1 : active - 1;
    if (next < 0) return;
  } else {
    if (active < 0) return;
    next = active + 1;
  }
  if (next >= entries.size()) {
    m_recall.reset();
    setText(target, QString(), 0);
    return;
  }
  m_recall = Recall{target, entries.at(next).first, entries.at(next).second};
  setText(target, entries.at(next).second, int(entries.at(next).second.size()));
}

// apps/web/src/components/chat/composerSubmission.ts
// getComposerPromptLengthValidationMessage.
QString ComposerController::promptProblem(const QString& text) {
  const qsizetype excess = text.trimmed().size() - kMaxPromptChars;
  if (excess <= 0) return {};
  const QLocale english(QLocale::English, QLocale::UnitedStates);
  return QStringLiteral("Prompt is %1 %2 over the %3-character limit. Shorten or split it before sending.")
      .arg(english.toString(excess), excess == 1 ? QStringLiteral("character") : QStringLiteral("characters"), english.toString(kMaxPromptChars));
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
  if (std::any_of(kept.attachments.cbegin(), kept.attachments.cend(), [](const Attachment& a) { return a.upload == QLatin1String("uploading"); })) {
    NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("warning"), QStringLiteral("Wait for file uploads before stashing this prompt"), {});
    return true;
  }
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
  // The turn the user stops here stays open once it settles.
  if (m_timeline) m_timeline->keepOpen(*runId);
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
  if (const QString problem = promptProblem(text); !problem.isEmpty()) {
    toast(QStringLiteral("Message not sent"), problem);
    return true;
  }
  if (m_queuedEdit && m_queuedEdit->thread == target) return saveQueuedEdit(target, text);
  if (slashMode(target, text)) return true;
  if (slashUsageLimits(target, text)) return true;
  // The next message closes the limits "/usage-limits" opened.
  if (!text.trimmed().isEmpty()) m_usageLimits.remove(target);
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
  if (fromDraft && filesBlock(m_drafts.value(target).attachments, QStringLiteral("sending"))) return true;
  // Nor while the thread is on its way to another machine, which would refuse it.
  if (thread->movingTo) {
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("%1 is moving to %2").arg(thread->title, *thread->movingTo),
        QStringLiteral("Send the message once it has arrived."));
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
  rememberModel(modelSelection);
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
  // A send made while an earlier one is still in flight waits its turn.
  QList<Send>& queue = m_queues[target];
  const QString messageId = str(message, QLatin1String("messageId"));
  queue.append({target, thread->environmentId, thread->id, commands, attachments, contexts, fromDraft ? text : QString(), messageId});
  const bool first = queue.size() == 1;
  // Kept until the MC answers. Sending again is newer than what a restart
  // left of the thread's sends.
  m_kept.unsent.removeIf([&](const Unsent& unsent) { return unsent.kept && unsent.target == target; });
  if (fromDraft && (!text.isEmpty() || !attachments.isEmpty() || !contexts.isEmpty())) {
    m_kept.unsent.append({target, target, messageId, newestBefore(target), text, attachments, contexts});
  }
  if (fromDraft) setText(target, QString(), 0);
  save();
  publish();
  if (first) sendNext(target);
  return true;
}

// Where a new thread starts. With more than one machine in the cluster the MC
// this shell is connected to chooses (`hal-c2.placeThread`, HalC2.LoadBalancing):
// it answers the user's own pick while balancing is off or no machine has more
// room, else another machine and its checkout of the repository. The pick
// stands for a draft the user tied to its machine, and whenever the MC cannot
// be followed: it refuses, takes longer than kPlacementWaitMs, or names a
// project or machine this shell cannot reach. Balancing never holds a first
// message back.
void ComposerController::place(const QString& environmentId, const QString& projectId, bool tied, const QString& instanceId,
                               std::function<void(const QString&, const QString&)> then) {
  QStringList machines = m_store->environments();
  machines.removeDuplicates();
  if (tied || machines.size() < 2) {
    then(environmentId, projectId);
    return;
  }
  QJsonObject input{{QStringLiteral("environmentId"), environmentId}, {QStringLiteral("projectId"), projectId}};
  if (!instanceId.isEmpty()) input.insert(QStringLiteral("instanceId"), instanceId);
  // The MC's answer or the wait running out, whichever is first.
  const auto answered = std::make_shared<bool>(false);
  const auto answer = [this, environmentId, projectId, then, answered](const QJsonValue& result, const std::optional<QString>& error) {
    if (std::exchange(*answered, true)) return;
    const QString placedOn = str(result.toObject(), QLatin1String("environmentId"));
    const QString placedIn = str(result.toObject(), QLatin1String("projectId"));
    const bool reachable = !error && m_store->environmentOnline(placedOn) && !m_store->projectRow(placedOn, placedIn).isEmpty();
    if (reachable) {
      then(placedOn, placedIn);
    } else {
      then(environmentId, projectId);
    }
  };
  m_client->call(this, m_client->environment(), QStringLiteral("hal-c2.placeThread"), input, answer);
  QTimer::singleShot(kPlacementWaitMs, this, [answer] { answer(QJsonValue(), QStringLiteral("no answer")); });
}

// A new thread's first send, as the web's: the thread is placed, its images
// are stored, then it is launched with the message in the draft's checkout
// (or the one it was placed in). The draft empties as it is sent, as a
// follow-up's composer does, and gets its text and images back if the launch
// fails; once the MC confirms, the window shows the thread in its place. A
// background send (mod+alt+Enter) leaves the window on the draft, emptied for
// another prompt.
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

  // A file sent to another machine before the draft moved goes up again.
  bool moved = false;
  for (const Attachment& attachment : std::as_const(attachments)) {
    if (!attachment.file || attachment.upload != QString() || attachment.environmentId == where.environmentId) continue;
    moved = true;
    uploadFile(attachment.id, where.environmentId);
  }
  if (moved) attachments = m_drafts.value(draftId).attachments;
  if (filesBlock(attachments, QStringLiteral("sending"))) return true;
  const QString trimmed = text.trimmed();
  const QJsonObject modelSelection = selection(draftId);
  const QString messageId = newId();
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
      {QStringLiteral("initialMessage"), QJsonObject{{QStringLiteral("messageId"), messageId},
                                                     {QStringLiteral("text"), trimmed},
                                                     {QStringLiteral("attachments"), QJsonArray()}}},
  };
  if (!modelSelection.isEmpty()) input.insert(QStringLiteral("modelSelection"), modelSelection);
  rememberModel(modelSelection);
  if (!contexts.isEmpty()) {
    QJsonObject initial = input.value(QLatin1String("initialMessage")).toObject();
    withExcerpts(initial, contexts);
    input.insert(QStringLiteral("initialMessage"), initial);
  }

  if (const auto models = m_drafts.value(draftId).multipleModels) {
    return submitToModels(draftId, *models, input, where.strategy, where.environmentId, text, attachments, contexts);
  }
  // The prompt leaves the composer as a follow-up's does, and comes back if
  // the launch fails.
  m_drafts[draftId].attachments.clear();
  m_drafts[draftId].excerpts.clear();
  const QString threadId = kept->threadId;
  // Kept, before the draft lets go of it, until the MC answers the launch.
  m_kept.unsent.append({draftId, where.environmentId + QLatin1Char(':') + threadId, messageId, std::nullopt, text,
                        attachments, contexts});
  save();
  if (background) {
    // The thread is on its way; the draft takes the next prompt under a new
    // thread id, so the launched thread's row does not end it.
    drafts->renew(draftId);
  } else {
    m_launching.insert(draftId);
  }
  setText(draftId, QString(), 0);
  publish();
  // The images go to the machine the thread starts on, then the thread does.
  const auto begin = [this, draftId, threadId, messageId, background, text, attachments, contexts](
                         const QString& environmentId, QJsonObject input) {
    for (Unsent& unsent : m_kept.unsent) {
      if (unsent.messageId == messageId) unsent.thread = environmentId + QLatin1Char(':') + threadId;
    }
    save();
    const auto start = [this, draftId, environmentId, messageId, background, text, attachments, contexts](const QJsonObject& input) {
      m_client->call(this, environmentId, QStringLiteral("orchestration.launchThread"), input,
                     [this, draftId, environmentId, input, messageId, background, text, attachments, contexts](
                         const QJsonValue& result, const std::optional<QString>& error) {
                       if (unanswered(error)) {
                         // The thread may be there: the draft becomes it if so
                         // (DraftController::reconcile), else it is asked for again.
                         keepUnanswered(messageId, input);
                         m_launching.remove(draftId);
                         publish();
                         return;
                       }
                       forgetUnsent(messageId);
                       QString threadId = result.toObject().value(QLatin1String("threadId")).toString();
                       if (threadId.isEmpty()) threadId = str(input, QLatin1String("threadId"));
                       const QString threadKey = environmentId + QLatin1Char(':') + threadId;
                       if (background) {
                         launchedInBackground(draftId, text, attachments, contexts, threadKey, error);
                       } else {
                         launched(draftId, text, attachments, contexts, threadKey, error);
                       }
                     });
    };
    const QJsonArray files = fileRecords(attachments);
    if (std::all_of(attachments.cbegin(), attachments.cend(), [](const Attachment& a) { return a.file; })) {
      if (!files.isEmpty()) {
        QJsonObject initial = input.value(QLatin1String("initialMessage")).toObject();
        initial.insert(QStringLiteral("attachments"), files);
        input.insert(QStringLiteral("initialMessage"), initial);
      }
      start(input);
      return;
    }
    QJsonArray images;
    for (const Attachment& attachment : attachments) {
      if (attachment.file) continue;
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
                   QJsonObject{{QStringLiteral("threadId"), threadId},
                               {QStringLiteral("messageId"), message.value(QLatin1String("messageId"))},
                               {QStringLiteral("attachments"), images}},
                   [this, draftId, input, message, messageId, start, background, text, attachments, contexts, files](
                       const QJsonValue& result, const std::optional<QString>& error) mutable {
                     if (error) {
                       forgetUnsent(messageId);
                       if (background) {
                         launchedInBackground(draftId, text, attachments, contexts, QString(), error);
                       } else {
                         launched(draftId, text, attachments, contexts, QString(), error);
                       }
                       return;
                     }
                     QJsonArray stored = result.toObject().value(QLatin1String("attachments")).toArray();
                     for (const QJsonValue& file : files) stored.append(file);
                     message.insert(QStringLiteral("attachments"), stored);
                     input.insert(QStringLiteral("initialMessage"), message);
                     start(input);
                   });
  };
  // Files already went to the machine the user picked, so the thread starts there.
  const bool hasFiles = std::any_of(attachments.cbegin(), attachments.cend(), [](const Attachment& a) { return a.file; });
  place(where.environmentId, where.projectId, where.tied || hasFiles, str(modelSelection, QLatin1String("instanceId")),
        [where, input, begin](const QString& environmentId, const QString& projectId) mutable {
          if (environmentId != where.environmentId || projectId != where.projectId) {
            input.insert(QStringLiteral("projectId"), projectId);
            // The branch this machine's checkout is on says nothing of
            // another's; a new worktree's base is the repository's on either.
            QJsonObject strategy = where.strategy;
            if (str(strategy, QLatin1String("type")) == QLatin1String("root")) strategy.remove(QLatin1String("branch"));
            input.insert(QStringLiteral("workspaceStrategy"), strategy);
          }
          begin(environmentId, input);
        });
  return true;
}

// A started thread, or a model with one sibling, is one model's; a new
// thread's draft may name several.
bool ComposerController::toggleMultipleModel(const QString& target, const QString& instanceId, const QString& model) {
  if (m_draftId.isEmpty() || target != m_draftId) return false;
  const composer::Instance* instance = composer::find(m_catalogue, instanceId);
  if (!instance || !instance->ready() || composer::findModel(*instance, model).isEmpty()) return false;
  // Each model needs a worktree of its own: a folder that is not a Git
  // repository runs one model, the one just chosen.
  const auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (workspace && workspace->git() && !workspace->git()->local.value(QLatin1String("isRepo")).toBool(true)) {
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("Only one model can be chosen"),
        QStringLiteral("Multiple models need a new thread in a Git project. Each gets its own worktree."));
    m_drafts[target].multipleModels.reset();
    return selectModel(target, instanceId, model);
  }
  Draft& kept = m_drafts[target];
  QList<QJsonObject> models = kept.multipleModels.value_or(QList<QJsonObject>{selection(target)});
  const auto same = [&](const QJsonObject& chosen) {
    return chosen.value(QLatin1String("instanceId")) == instanceId && chosen.value(QLatin1String("model")) == model;
  };
  if (models.removeIf(same) == 0) models.append({{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}});
  if (models.size() <= 1) {
    // One model left is the draft's model again.
    if (!models.isEmpty()) kept.modelSelection = models.constFirst();
    kept.multipleModels.reset();
  } else {
    // Each model's thread starts in a worktree of its own.
    if (!kept.multipleModels) m_bridge->dispatch(QStringLiteral("workspace.envMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("worktree")}});
    m_drafts[target].multipleModels = models;
  }
  save();
  publish();
  return true;
}

// As the web's send to multiple models: each gets a thread of its own, in a
// new worktree off the draft's branch, and the draft is ready for the next
// prompt. A thread that fails to start says so; if none starts the prompt
// comes back, then or, for launches a quit or drop left unanswered, once the
// shell shows none of their threads.
bool ComposerController::submitToModels(const QString& draftId, const QList<QJsonObject>& models, const QJsonObject& input,
                                        const QJsonObject& strategy, const QString& environmentId, const QString& text,
                                        const QList<Attachment>& attachments, const QList<Excerpt>& contexts) {
  auto* shell = NativeShell::of(this);
  const QString type = str(strategy, QLatin1String("type"));
  const QString base = type == QLatin1String("worktree") ? str(strategy, QLatin1String("baseRef"))
                       : type == QLatin1String("root")   ? str(strategy, QLatin1String("branch"))
                                                         : QString();
  if (base.isEmpty()) {
    shell->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("Choose models and a base branch"),
        QStringLiteral("Multiple models need a new thread in a Git project. Each gets its own worktree."));
    return true;
  }
  QJsonObject worktree{{QStringLiteral("type"), QStringLiteral("worktree")}, {QStringLiteral("baseRef"), base}};
  if (strategy.value(QLatin1String("startFromOrigin")).toBool()) worktree.insert(QStringLiteral("startFromOrigin"), true);

  m_drafts[draftId].attachments.clear();
  m_drafts[draftId].excerpts.clear();
  shell->controller<DraftController>()->renew(draftId);
  setText(draftId, QString(), 0);

  struct Progress {
    qsizetype pending = 0;
    qsizetype started = 0;
    qsizetype unanswered = 0;
    QString first;
  };
  const auto progress = std::make_shared<Progress>();
  progress->pending = models.size();
  const QString batch = newId();
  const auto settled = [this, progress, batch, draftId, text, attachments, contexts](
                           const QString& model, const QString& threadKey, const QString& messageId,
                           const std::optional<QString>& error, bool lost, const QJsonObject& launch) {
    auto* shell = NativeShell::of(this);
    if (lost) {
      keepUnanswered(messageId, launch);
      ++progress->unanswered;
    } else if (error) {
      forgetUnsent(messageId);
      toast(tr("Could not start a thread on %1").arg(model), *error);
    } else {
      // A thread has the prompt: none of the launches brings it back.
      if (m_kept.unsent.removeIf([&](const Unsent& unsent) { return unsent.batch == batch; }) > 0) save();
      if (progress->started++ == 0) progress->first = threadKey;
    }
    if (--progress->pending > 0) return;
    if (progress->started > 0) {
      auto* navigation = shell->controller<NavigationController>();
      const QString first = progress->first;
      shell->controller<ToastController>()->show(
          QStringLiteral("success"), tr("Started %n thread(s) in background", nullptr, int(progress->started)), {},
          ToastController::Action{QStringLiteral("Open"), [navigation, first] { navigation->open(NavigationController::Route::thread(first)); }});
      return;
    }
    // Nothing started: the prompt goes back into an untouched draft, unless
    // a launch may have (reconcileUnsent).
    if (progress->unanswered > 0) return;
    if (!shell->controller<DraftController>()->draft(draftId) || !draft(draftId).isEmpty()) return;
    m_drafts[draftId].attachments = attachments;
    m_drafts[draftId].excerpts = contexts;
    setText(draftId, text, int(text.size()));
  };

  QJsonArray images;
  for (const Attachment& attachment : attachments) {
    if (attachment.file) continue;
    QJsonObject image{{QStringLiteral("type"), QStringLiteral("image")}, {QStringLiteral("name"), attachment.name},
                      {QStringLiteral("mimeType"), attachment.mimeType}, {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                      {QStringLiteral("dataUrl"), attachment.dataUrl}};
    if (!attachment.source.isEmpty()) image.insert(QStringLiteral("source"), attachment.source);
    images.append(image);
  }
  const QJsonArray files = fileRecords(attachments);
  for (const QJsonObject& model : models) {
    QJsonObject launch = input;
    QJsonObject message = launch.value(QLatin1String("initialMessage")).toObject();
    const QString threadId = newId();
    const QString messageId = newId();
    message.insert(QStringLiteral("messageId"), messageId);
    message.insert(QStringLiteral("attachments"), files);
    launch.insert(QStringLiteral("commandId"), newId());
    launch.insert(QStringLiteral("threadId"), threadId);
    launch.insert(QStringLiteral("modelSelection"), model);
    launch.insert(QStringLiteral("workspaceStrategy"), worktree);
    launch.insert(QStringLiteral("initialMessage"), message);
    const QString name = str(model, QLatin1String("model"));
    const QString threadKey = environmentId + QLatin1Char(':') + threadId;
    // Kept until the MC answers this model's launch.
    m_kept.unsent.append({draftId, threadKey, messageId, std::nullopt, text, attachments, contexts, batch});
    const auto start = [this, environmentId, name, threadKey, messageId, settled](const QJsonObject& launch) {
      m_client->call(this, environmentId, QStringLiteral("orchestration.launchThread"), launch,
                     [name, threadKey, messageId, settled, launch](const QJsonValue&, const std::optional<QString>& error) {
                       settled(name, threadKey, messageId, error, unanswered(error), launch);
                     });
    };
    if (images.isEmpty()) {
      start(launch);
      continue;
    }
    m_client->call(this, environmentId, QStringLiteral("assets.persistChatAttachments"),
                   QJsonObject{{QStringLiteral("threadId"), threadId}, {QStringLiteral("messageId"), message.value(QLatin1String("messageId"))},
                               {QStringLiteral("attachments"), images}},
                   [launch, message, files, start, name, threadKey, messageId, settled](
                       const QJsonValue& result, const std::optional<QString>& error) mutable {
                     if (error) {
                       // No thread was launched, whatever became of the images.
                       settled(name, threadKey, messageId, error, false, {});
                       return;
                     }
                     QJsonArray stored = result.toObject().value(QLatin1String("attachments")).toArray();
                     for (const QJsonValue& file : files) stored.append(file);
                     message.insert(QStringLiteral("attachments"), stored);
                     launch.insert(QStringLiteral("initialMessage"), message);
                     start(launch);
                   });
  }
  save();
  publish();
  return true;
}

// The launch's answer: the draft becomes the thread, or gets its prompt back
// with a toast.
void ComposerController::launched(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                                  const QList<Excerpt>& contexts, const QString& threadKey,
                                  const std::optional<QString>& error) {
  m_launching.remove(draftId);
  if (error) {
    restoreLaunch(draftId, text, attachments, contexts);
    toast(QStringLiteral("Could not create thread"), *error);
    publish();
    return;
  }
  auto* shell = NativeShell::of(this);
  shell->controller<WorkspaceController>()->forgetDraft(draftId);
  shell->controller<DraftController>()->promote(draftId, threadKey);
  m_drafts.remove(draftId);
  save();
  publish();
}

// A failed launch's prompt back in its draft. Only into an empty one: newer
// typing is the user's.
bool ComposerController::restoreLaunch(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                                       const QList<Excerpt>& contexts) {
  if (!NativeShell::of(this)->controller<DraftController>()->draft(draftId) || !draft(draftId).isEmpty() ||
      !m_drafts.value(draftId).attachments.isEmpty() || !m_drafts.value(draftId).excerpts.isEmpty()) {
    return false;
  }
  m_drafts[draftId].attachments = attachments;
  m_drafts[draftId].excerpts = contexts;
  // The draft keeps its text; the images and excerpts are the composer's.
  save();
  setText(draftId, text, int(text.size()));
  return true;
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
  const auto restore = [this, draftId, text, attachments, contexts] {
    return restoreLaunch(draftId, text, attachments, contexts);
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
      // The sends queued behind it would reach the MC out of order, so they
      // stop too and come back with it.
      const QList<Send> unsent = m_queues.take(target);
      if (unanswered(error)) {
        // The MC may have the first: the thread's messages tell once it is
        // back, and the ones behind it come back with it or without it.
        for (const Send& queued : unsent) keepUnanswered(queued.messageId);
        publish();
        return;
      }
      QStringList prompts;
      QList<Attachment> attachments;
      QList<Excerpt> contexts;
      for (const Send& queued : unsent) {
        if (!queued.prompt.isEmpty()) prompts.append(queued.prompt);
        attachments.append(queued.attachments);
        contexts.append(queued.excerpts);
        forgetUnsent(queued.messageId);
      }
      const QString restored = prompts.join(QStringLiteral("\n\n"));
      // Only into an untouched draft: newer typing is the user's, and the
      // toast gives the prompt back once the draft is empty.
      if (restored.isEmpty() || draft(target).isEmpty()) {
        toast(QStringLiteral("Failed to send message"), *error);
        if (!restored.isEmpty()) setText(target, restored, int(restored.size()));
      } else {
        offerRestore(target, QStringLiteral("Failed to send message"),
                     QStringLiteral("Your newer draft is unchanged. Restore the failed prompt when this composer is empty."),
                     restored);
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
    const QString delivered = queue.takeFirst().messageId;
    // The sends behind it come after it in the thread.
    for (Unsent& unsent : m_kept.unsent) {
      if (unsent.target == target && !unsent.kept && unsent.after) unsent.after = delivered;
    }
    m_kept.delivered.insert(target, delivered);
    forgetUnsent(delivered);
    if (queue.isEmpty()) {
      m_queues.remove(target);
      publish();
    } else {
      sendNext(target);
    }
  };
  const QJsonArray files = fileRecords(send.attachments);
  if (std::all_of(send.attachments.cbegin(), send.attachments.cend(), [](const Attachment& a) { return a.file; })) {
    Send ready = send;
    if (!files.isEmpty()) {
      QJsonObject message = ready.commands.constLast();
      message.insert(QStringLiteral("attachments"), files);
      ready.commands.last() = message;
    }
    dispatchAll(ready, 0, finish);
    return;
  }
  QJsonArray images;
  for (const Attachment& attachment : send.attachments) {
    if (attachment.file) continue;
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
                 [this, send, message, finish, files](const QJsonValue& result, const std::optional<QString>& error) mutable {
                   if (error) {
                     finish(error);
                     return;
                   }
                   QJsonArray carried = result.toObject().value(QLatin1String("attachments")).toArray();
                   for (const QJsonValue& file : files) carried.append(file);
                   message.insert(QStringLiteral("attachments"), carried);
                   Send stored = send;
                   stored.commands.last() = message;
                   dispatchAll(stored, 0, finish);
                 });
}

void ComposerController::offerRestore(const QString& target, const QString& title, const QString& description,
                                      const QString& restored, const QList<Attachment>& attachments,
                                      const QList<Excerpt>& contexts) {
  NativeShell::of(this)->controller<ToastController>()->show(
      QStringLiteral("error"), title, description,
      ToastController::Action{QStringLiteral("Restore prompt"),
                              [this, target, restored, attachments, contexts] {
                                if (!draft(target).isEmpty()) return;
                                Draft& kept = m_drafts[target];
                                kept.attachments = attachments + kept.attachments;
                                kept.excerpts = contexts + kept.excerpts;
                                setText(target, restored, int(restored.size()));
                                save();
                                auto* shell = NativeShell::of(this);
                                shell->controller<NavigationController>()->open(
                                    shell->controller<DraftController>()->draft(target)
                                        ? NavigationController::Route::draft(target)
                                        : NavigationController::Route::thread(target));
                              }},
      0);
}

void ComposerController::forgetUnsent(const QString& messageId) {
  if (m_kept.unsent.removeIf([&](const Unsent& unsent) { return unsent.messageId == messageId; }) > 0) save();
}

void ComposerController::keepUnanswered(const QString& messageId, const QJsonObject& launch) {
  for (Unsent& unsent : m_kept.unsent) {
    if (unsent.messageId != messageId) continue;
    unsent.kept = true;
    unsent.seen = m_store->snapshots();
    unsent.launch = launch;
    save();
  }
}

// The MC may have taken the launch and not made its thread yet: asked again
// under its command id, it answers once, and only a refusal brings the
// prompt back (reconcileUnsent).
void ComposerController::retryLaunch(const QString& messageId) {
  const auto found = std::find_if(m_kept.unsent.begin(), m_kept.unsent.end(), [&](const Unsent& unsent) { return unsent.messageId == messageId; });
  if (found == m_kept.unsent.end()) return;
  const QJsonObject launch = std::exchange(found->launch, {});
  found->kept = false;
  const QString environmentId = found->thread.section(QLatin1Char(':'), 0, 0);
  m_client->call(this, environmentId, QStringLiteral("orchestration.launchThread"), launch,
                 [this, messageId, launch](const QJsonValue&, const std::optional<QString>& error) {
                   if (unanswered(error)) {
                     keepUnanswered(messageId, launch);
                     return;
                   }
                   const auto it = std::find_if(m_kept.unsent.begin(), m_kept.unsent.end(),
                                                [&](const Unsent& unsent) { return unsent.messageId == messageId; });
                   if (it == m_kept.unsent.end()) return;
                   if (error) {
                     it->kept = true;
                   } else {
                     // A thread has the prompt, the draft becomes it (DraftController::reconcile).
                     const QString batch = it->batch;
                     m_kept.unsent.removeIf([&](const Unsent& unsent) {
                       return unsent.messageId == messageId || (!batch.isEmpty() && unsent.batch == batch);
                     });
                   }
                   save();
                   reconcileUnsent();
                 });
}

// The thread's newest user message ahead of the sends still on their way to
// it, once its messages are known.
std::optional<QString> ComposerController::newestBefore(const QString& thread) const {
  if (!m_timeline || m_timeline->threadKey() != thread || m_timeline->status() != QLatin1String("live")) return std::nullopt;
  QSet<QString> pending;
  for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
    if (unsent.target == thread) pending.insert(unsent.messageId);
  }
  const QHash<QString, QJsonObject> messages = m_timeline->entities(QStringLiteral("message"));
  const QString delivered = m_kept.delivered.value(thread);
  if (!delivered.isEmpty() && !messages.contains(delivered)) return delivered;
  return newestUserMessage(messages, pending);
}

// A kept send's fate shows once the thread's messages do: one the MC got is
// there and is dropped; one behind a newer user message (another device's, or
// this one's after the restart) is dropped too, as the user moved on. The
// rest come back to the draft: into it when it is empty, else behind a toast
// that restores them once it is. A new thread's first send waits for the
// shell to know whether the thread exists.
void ComposerController::reconcileUnsent() {
  // A send made before its thread's messages were known measures from when
  // they are, so a newer message from elsewhere still drops it.
  const auto unmeasured = [this](const Unsent& unsent) {
    return !unsent.kept && !unsent.after && unsent.target == m_timeline->threadKey();
  };
  if (m_timeline && std::any_of(m_kept.unsent.cbegin(), m_kept.unsent.cend(), unmeasured)) {
    if (const std::optional<QString> newest = newestBefore(m_timeline->threadKey())) {
      for (Unsent& unsent : m_kept.unsent) {
        if (unmeasured(unsent)) unsent.after = newest;
      }
      save();
    }
  }
  if (!m_active || std::none_of(m_kept.unsent.cbegin(), m_kept.unsent.cend(), [](const Unsent& u) { return u.kept; })) return;
  auto* drafts = NativeShell::of(this)->controller<DraftController>();
  const auto online = [this](const QString& key) {
    return m_store->synchronized() && m_store->environmentOnline(key.section(QLatin1Char(':'), 0, 0));
  };
  const bool live = m_timeline && m_timeline->status() == QLatin1String("live");
  const QHash<QString, QJsonObject> messages = live ? m_timeline->entities(QStringLiteral("message")) : QHash<QString, QJsonObject>();
  // What each target gets back, in the order the targets were sent to.
  QStringList targets;
  QHash<QString, QList<Unsent>> back;
  QSet<QString> settled;
  QSet<QString> mine;
  for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
    if (unsent.kept) mine.insert(unsent.messageId);
  }
  const QString newest = live ? newestUserMessage(messages, mine) : QString();
  // The sends to several models that started a thread, or have come back;
  // and those with a launch still to be answered, which may yet start one.
  QSet<QString> started;
  QSet<QString> waiting;
  for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
    if (unsent.batch.isEmpty()) continue;
    const bool exists = m_store->thread(m_store->located(unsent.thread)).has_value();
    if (unsent.kept && exists) started.insert(unsent.batch);
    if (!unsent.kept || (!unsent.launch.isEmpty() && !exists)) waiting.insert(unsent.batch);
  }
  QStringList retries;
  for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
    // One whose answer a drop took waits for the shell as it is after the drop.
    if (!unsent.kept || m_store->snapshots() <= unsent.seen) continue;
    const QString key = m_store->located(unsent.thread);
    QString into;
    if (unsent.target != unsent.thread) {
      // A launch: the thread it made, or the draft it came from.
      if (!online(key)) continue;
      if (!m_store->thread(key) && !unsent.launch.isEmpty()) {
        retries.append(unsent.messageId);
        continue;
      }
      if (!m_store->thread(key) && waiting.contains(unsent.batch) && !started.contains(unsent.batch)) continue;
      if (!m_store->thread(key) && drafts->draft(unsent.target) && !started.contains(unsent.batch)) into = unsent.target;
      if (!unsent.batch.isEmpty()) started.insert(unsent.batch);
    } else if (online(key) && !m_store->thread(key)) {
      // The thread is gone.
    } else if (!live || m_timeline->threadKey() != key) {
      continue;
    } else if (!messages.contains(unsent.messageId) && (!unsent.after || *unsent.after == newest)) {
      into = key;
    }
    settled.insert(unsent.messageId);
    if (into.isEmpty()) continue;
    if (!back.contains(into)) targets.append(into);
    back[into].append(unsent);
  }
  for (const QString& messageId : std::as_const(retries)) retryLaunch(messageId);
  if (settled.isEmpty()) return;
  m_kept.unsent.removeIf([&](const Unsent& unsent) { return settled.contains(unsent.messageId); });
  for (const QString& target : std::as_const(targets)) {
    QStringList prompts;
    QList<Attachment> attachments;
    QList<Excerpt> contexts;
    for (const Unsent& unsent : back.value(target)) {
      if (!unsent.prompt.isEmpty()) prompts.append(unsent.prompt);
      attachments.append(unsent.attachments);
      contexts.append(unsent.excerpts);
    }
    const QString restored = prompts.join(QStringLiteral("\n\n"));
    const Draft& there = m_drafts.value(target);
    if (draft(target).isEmpty() && there.attachments.isEmpty() && there.excerpts.isEmpty()) {
      Draft& kept = m_drafts[target];
      kept.attachments = attachments;
      kept.excerpts = contexts;
      setText(target, restored, int(restored.size()));
    } else {
      offerRestore(target, QStringLiteral("A prompt was not sent"),
                   QStringLiteral("HAL-C2 closed before it was sent. Your newer draft is unchanged. Restore the prompt when this composer is empty."),
                   restored, attachments, contexts);
    }
  }
  save();
  publish();
}

QJsonObject ComposerController::excerptJson(const Excerpt& excerpt) {
  QJsonObject kept{{QStringLiteral("id"), excerpt.id}, {QStringLiteral("terminalId"), excerpt.terminalId},
                   {QStringLiteral("terminalLabel"), excerpt.terminalLabel}, {QStringLiteral("lineStart"), excerpt.lineStart},
                   {QStringLiteral("lineEnd"), excerpt.lineEnd}, {QStringLiteral("text"), excerpt.text}};
  if (!excerpt.citation.isEmpty()) kept.insert(QStringLiteral("citation"), excerpt.citation);
  if (!excerpt.review.isEmpty()) kept.insert(QStringLiteral("review"), excerpt.review);
  return kept;
}

ComposerController::Excerpt ComposerController::excerptOf(const QJsonObject& kept) {
  return {str(kept, QLatin1String("id")), str(kept, QLatin1String("terminalId")), str(kept, QLatin1String("terminalLabel")),
          kept.value(QLatin1String("lineStart")).toInt(1), kept.value(QLatin1String("lineEnd")).toInt(1),
          str(kept, QLatin1String("text")), kept.value(QLatin1String("citation")).toObject(),
          kept.value(QLatin1String("review")).toObject()};
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

// What the brick read from disk or the clipboard joins the route's draft: an
// image as its bytes, any other file by its path, a pasted text as itself.
// Files go to the MC at once.
bool ComposerController::attach(const QVariantList& files) {
  const QString target = this->target();
  if (target.isEmpty()) return true;
  const QString environmentId = environmentOf(target);
  QStringList added;
  for (const QVariant& value : files) {
    const QVariantMap file = value.toMap();
    const QString name = file.value(QStringLiteral("name")).toString();
    const QString mimeType = file.value(QStringLiteral("mimeType")).toString();
    QList<Attachment>& attachments = m_drafts[target].attachments;
    if (file.contains(QStringLiteral("base64"))) {
      const QString base64 = file.value(QStringLiteral("base64")).toString();
      attachments.append({newId(), name, mimeType, QByteArray::fromBase64(base64.toLatin1()).size(),
                          QStringLiteral("data:%1;base64,%2").arg(mimeType, base64)});
      continue;
    }
    Attachment attachment{newId(), name, mimeType.isEmpty() ? QStringLiteral("application/octet-stream") : mimeType};
    attachment.file = true;
    if (file.contains(QStringLiteral("text"))) {
      attachment.content = file.value(QStringLiteral("text")).toString().toUtf8();
      attachment.pastedText = true;
      attachment.mimeType = QStringLiteral("text/plain");
      attachment.sizeBytes = attachment.content.size();
      // nextPastedTextFileName: pasted-text.txt, then pasted-text-2.txt, ...
      const auto taken = [&](const QString& candidate) {
        return std::any_of(attachments.cbegin(), attachments.cend(), [&](const Attachment& other) { return other.name.compare(candidate, Qt::CaseInsensitive) == 0; });
      };
      attachment.name = QStringLiteral("pasted-text.txt");
      for (int n = 2; taken(attachment.name); ++n) attachment.name = QStringLiteral("pasted-text-%1.txt").arg(n);
      NativeShell::of(this)->controller<ToastController>()->show(
          QStringLiteral("info"), tr("Large paste attached as %1").arg(attachment.name),
          tr("%1 · Use %2 to keep a large paste inline.")
              .arg(QLocale(QLocale::English, QLocale::UnitedStates).formattedDataSize(attachment.sizeBytes, 1, QLocale::DataSizeIecFormat),
                   NativeShell::of(this)->controller<KeybindingController>()->mac() ? QStringLiteral("⌘⇧V") : QStringLiteral("Ctrl+Shift+V")));
    } else {
      attachment.path = file.value(QStringLiteral("path")).toString();
      attachment.sizeBytes = QFileInfo(attachment.path).size();
    }
    attachments.append(attachment);
    added.append(attachment.id);
  }
  save();
  publish();
  for (const QString& id : std::as_const(added)) uploadFile(id, environmentId);
  return true;
}

// The same for the answer to a question: `questionId`, else the first of the
// request that takes a typed answer. A question of fixed choices takes none.
bool ComposerController::attachToAnswer(const QString& requestId, QString questionId, const QVariantList& files) {
  const QVariantList pending = turnState().value(QStringLiteral("questions")).toList();
  const auto request = std::find_if(pending.cbegin(), pending.cend(), [&](const QVariant& entry) {
    return entry.toMap().value(QStringLiteral("requestId")) == requestId;
  });
  if (request == pending.cend()) return true;
  bool accepts = false;
  for (const QVariant& entry : request->toMap().value(QStringLiteral("questions")).toList()) {
    const QVariantMap question = entry.toMap();
    if (!question.value(QStringLiteral("allowCustomAnswer")).toBool()) continue;
    if (questionId.isEmpty()) questionId = question.value(QStringLiteral("id")).toString();
    if (questionId == question.value(QStringLiteral("id")).toString()) accepts = true;
  }
  if (!accepts) {
    toast(QStringLiteral("This question cannot accept attachments."), {});
    return true;
  }
  const QString environmentId = environmentOf(m_thread);
  QStringList added;
  for (const QVariant& value : files) {
    const QVariantMap file = value.toMap();
    Attachment attachment{newId(), file.value(QStringLiteral("name")).toString(), file.value(QStringLiteral("mimeType")).toString()};
    if (attachment.mimeType.isEmpty()) attachment.mimeType = QStringLiteral("application/octet-stream");
    attachment.file = true;
    if (file.contains(QStringLiteral("base64"))) {
      attachment.content = QByteArray::fromBase64(file.value(QStringLiteral("base64")).toString().toLatin1());
      attachment.sizeBytes = attachment.content.size();
    } else if (file.contains(QStringLiteral("text"))) {
      attachment.content = file.value(QStringLiteral("text")).toString().toUtf8();
      attachment.sizeBytes = attachment.content.size();
    } else {
      attachment.path = file.value(QStringLiteral("path")).toString();
      attachment.sizeBytes = QFileInfo(attachment.path).size();
    }
    m_answerFiles[requestId][questionId].append(attachment);
    added.append(attachment.id);
  }
  publish();
  for (const QString& id : std::as_const(added)) uploadFile(id, environmentId);
  return true;
}

// apps/web ChatComposer addDroppedFolders: a folder is named by its path,
// which only means something where the MC shares this machine's disk.
bool ComposerController::attachFolders(const QString& target, const QVariantList& folders) {
  if (!m_bridge->localFolders() || environmentOf(target) != m_client->environment()) {
    toast(QStringLiteral("Folders can't be dropped into remote environments"), QStringLiteral("Type the folder path with @ instead."));
    return true;
  }
  QString text = draft(target);
  for (const QVariant& folder : folders) {
    if (!text.isEmpty() && !text.back().isSpace()) text += u' ';
    text += composer::pathLink(folder.toString());
  }
  setText(target, text, int(text.size()));
  return true;
}

ComposerController::Attachment* ComposerController::findAttachment(const QString& id) {
  for (Draft& draft : m_drafts) {
    for (Attachment& attachment : draft.attachments) {
      if (attachment.id == id) return &attachment;
    }
  }
  for (auto& questions : m_answerFiles) {
    for (QList<Attachment>& files : questions) {
      for (Attachment& attachment : files) {
        if (attachment.id == id) return &attachment;
      }
    }
  }
  return nullptr;
}

QString ComposerController::environmentOf(const QString& target) const {
  if (const auto thread = m_store->thread(target)) return thread->environmentId;
  auto* shell = NativeShell::of(this);
  if (!shell->controller<DraftController>()->draft(target)) return {};
  return shell->controller<WorkspaceController>()->launch(target).environmentId;
}

// `attachments.createUploadUrl`, then the bytes to the URL it answers with;
// the message later names the upload, and the MC moves it into the thread.
void ComposerController::uploadFile(const QString& id, const QString& environmentId) {
  Attachment* attachment = findAttachment(id);
  if (!attachment) return;
  const auto failed = [this, id](const QString& why) {
    if (Attachment* found = findAttachment(id)) {
      found->upload = QStringLiteral("failed");
      found->error = why;
    }
    save();
    publish();
  };
  attachment->upload = QStringLiteral("uploading");
  attachment->error.clear();
  attachment->remoteId.clear();
  attachment->environmentId = environmentId;
  QByteArray bytes = attachment->content;
  if (!attachment->path.isEmpty()) {
    QFile file(attachment->path);
    if (!file.open(QIODevice::ReadOnly)) {
      failed(tr("%1 could not be read.").arg(attachment->name));
      return;
    }
    bytes = file.readAll();
  }
  const QString mimeType = attachment->mimeType;
  publish();
  m_client->call(this, environmentId, QStringLiteral("attachments.createUploadUrl"),
                 QJsonObject{{QStringLiteral("type"), QStringLiteral("file")},
                             {QStringLiteral("name"), attachment->name},
                             {QStringLiteral("mimeType"), mimeType},
                             {QStringLiteral("sizeBytes"), bytes.size()}},
                 [this, id, bytes, mimeType, failed](const QJsonValue& result, const std::optional<QString>& error) {
                   const QString url = result.toObject().value(QLatin1String("relativeUrl")).toString();
                   const QString remoteId = result.toObject().value(QLatin1String("attachmentId")).toString();
                   if (error || url.isEmpty() || remoteId.isEmpty()) {
                     failed(error.value_or(tr("The environment did not take the upload.")));
                     return;
                   }
                   m_client->upload(this, url, bytes, mimeType, [this, id, remoteId, failed](const QJsonValue&, const std::optional<QString>& error) {
                     if (error) {
                       failed(*error);
                       return;
                     }
                     if (Attachment* found = findAttachment(id)) {
                       found->upload.clear();
                       found->remoteId = remoteId;
                     }
                     save();
                     publish();
                   });
                 });
}

// The web's send guards (ChatView): nothing leaves while a file is still on
// its way, or after one failed.
bool ComposerController::filesBlock(const QList<Attachment>& attachments, const QString& what) {
  bool uploading = false, failed = false;
  for (const Attachment& attachment : attachments) {
    uploading = uploading || attachment.upload == QLatin1String("uploading");
    failed = failed || attachment.upload == QLatin1String("failed");
  }
  if (failed) {
    toast(tr("Retry or remove failed uploads before %1.").arg(what), {});
  } else if (uploading) {
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), tr("Wait for attachments to finish uploading, or remove failed uploads."), {});
  }
  return failed || uploading;
}

// ChatFileAttachment for each uploaded file.
QJsonArray ComposerController::fileRecords(const QList<Attachment>& attachments) {
  QJsonArray files;
  for (const Attachment& attachment : attachments) {
    if (!attachment.file) continue;
    QJsonObject file{{QStringLiteral("type"), QStringLiteral("file")},
                     {QStringLiteral("id"), attachment.remoteId},
                     {QStringLiteral("name"), attachment.name},
                     {QStringLiteral("mimeType"), attachment.mimeType},
                     {QStringLiteral("sizeBytes"), attachment.sizeBytes}};
    if (attachment.pastedText) file.insert(QStringLiteral("source"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("pasted-text")}});
    files.append(file);
  }
  return files;
}

// What the composer shows of each: {id, name, kind, status, error, source};
// `source` is a Snap Shot's {appName, windowTitle, accessibility}, the
// last being what its window said of itself, in the web's words
// (SnapShotAttachmentDetails.tsx).
QVariantList ComposerController::shownAttachments(const QList<Attachment>& attachments, bool previews) const {
  QVariantList shown;
  for (const Attachment& attachment : attachments) {
    QVariant source = QVariant::fromValue(nullptr);
    if (str(attachment.source, QLatin1String("kind")) == QLatin1String("snap-shot")) {
      // SnapShotAttachmentDetails.tsx: the text the window said of itself,
      // else its element tree when any element has a name or value.
      const QJsonObject accessibility = attachment.source.value(QLatin1String("accessibility")).toObject();
      QString said = str(accessibility, QLatin1String("format")) == QLatin1String("flat-text") ? str(accessibility, QLatin1String("text")).trimmed()
                                                                                             : str(attachment.source, QLatin1String("accessibleText")).trimmed();
      const std::function<bool(const QJsonObject&)> readable = [&readable](const QJsonObject& node) {
        if (!str(node, QLatin1String("name")).isEmpty() || !str(node, QLatin1String("value")).isEmpty()) return true;
        const QJsonArray children = node.value(QLatin1String("children")).toArray();
        return std::any_of(children.begin(), children.end(), [&](const QJsonValue& child) { return readable(child.toObject()); });
      };
      if (said.isEmpty() && readable(accessibility.value(QLatin1String("root")).toObject())) {
        said = QString::fromUtf8(QJsonDocument(accessibility).toJson(QJsonDocument::Indented));
      }
      if (said.isEmpty()) {
        said = accessibility.isEmpty() ? QStringLiteral("The app or capture backend did not provide verified accessibility data.")
                                       : QStringLiteral("Structured accessibility elements were included, but they have no readable names or values.");
      }
      source = QVariantMap{{QStringLiteral("appName"), str(attachment.source, QLatin1String("appName"))},
                           {QStringLiteral("windowTitle"), str(attachment.source, QLatin1String("windowTitle"))},
                           {QStringLiteral("accessibility"), said}};
    }
    QVariantMap entry{{QStringLiteral("id"), attachment.id},
                      {QStringLiteral("name"), attachment.name},
                      {QStringLiteral("kind"), attachment.file ? QStringLiteral("file") : QStringLiteral("image")},
                      {QStringLiteral("status"), attachment.upload},
                      {QStringLiteral("error"), attachment.error},
                      {QStringLiteral("source"), source}};
    if (previews && !attachment.file) {
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
      entry.insert(QStringLiteral("preview"), *preview);
    }
    shown.append(entry);
  }
  return shown;
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

// The chip's and the record's name for a note: "src/cart.ts L10-12".
static QString reviewLabel(const QString& filePath, int first, int last) {
  return first == last ? QStringLiteral("%1 L%2").arg(filePath).arg(first) : QStringLiteral("%1 L%2-%3").arg(filePath).arg(first).arg(last);
}

bool ComposerController::addReviewComment(const QVariantMap& comment) {
  const QString target = this->target();
  if (target.isEmpty()) return true;
  const QString filePath = comment.value(QStringLiteral("filePath")).toString().trimmed();
  // COMPOSER_CONTEXT_REVIEW_TEXT_MAX_CHARS and _DIFF_MAX_CHARS.
  const QString note = comment.value(QStringLiteral("text")).toString().trimmed().left(16000);
  if (filePath.isEmpty() || note.isEmpty()) return true;
  const int first = std::max(1, comment.value(QStringLiteral("lineStart")).toInt());
  const int last = std::max(first, comment.value(QStringLiteral("lineEnd")).toInt());
  Excerpt context{newId(), {}, {}, first, last, note, {}, {}};
  context.review = QJsonObject{{QStringLiteral("filePath"), filePath},
                               {QStringLiteral("sectionId"), comment.value(QStringLiteral("sectionId"), QStringLiteral("diff")).toString()},
                               {QStringLiteral("sectionTitle"), comment.value(QStringLiteral("sectionTitle"), QStringLiteral("Diff")).toString()},
                               {QStringLiteral("startIndex"), comment.value(QStringLiteral("startIndex")).toInt()},
                               {QStringLiteral("endIndex"), comment.value(QStringLiteral("endIndex")).toInt()},
                               {QStringLiteral("rangeLabel"), comment.value(QStringLiteral("rangeLabel")).toString()},
                               {QStringLiteral("diff"), comment.value(QStringLiteral("diff")).toString().left(32000)}};
  m_drafts[target].excerpts.append(context);
  publish();
  NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("success"), QStringLiteral("Comment added to the prompt"),
                                                             reviewLabel(filePath, first, last));
  return true;
}

bool ComposerController::attachmentsPending(const QString& target) const {
  for (const Attachment& attachment : m_drafts.value(target).attachments) {
    if (attachment.upload == QLatin1String("uploading")) return true;
  }
  for (const Send& send : m_queues.value(target)) {
    if (!send.attachments.isEmpty()) return true;
  }
  return false;
}

QVariantList ComposerController::terminalContexts(const QString& target) const {
  QVariantList contexts;
  for (const Excerpt& context : m_drafts.value(target).excerpts) {
    if (!context.citation.isEmpty() || !context.review.isEmpty()) continue;
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
    if (!context.review.isEmpty()) {
      // reviewCommentRecord: the note with the file, the lines and their text.
      const QString filePath = context.review.value(QLatin1String("filePath")).toString();
      QString label = reviewLabel(filePath, context.lineStart, context.lineEnd).replace(unsafe, QStringLiteral(" "));
      label = label.replace(spaces, QStringLiteral(" ")).trimmed().left(200);
      const QString contextId = QStringLiteral("review_") + context.id;
      links.append(QStringLiteral("[%1](hal-c2-context://v1/review-comment/%2)").arg(label, contextId));
      QJsonObject record = context.review;
      record.insert(QStringLiteral("version"), 1);
      record.insert(QStringLiteral("contextId"), contextId);
      record.insert(QStringLiteral("kind"), QStringLiteral("review-comment"));
      record.insert(QStringLiteral("label"), label);
      record.insert(QStringLiteral("text"), context.text);
      records.append(record);
      continue;
    }
    // An excerpt whose text is gone (the web's expired context) has nothing to send.
    if (context.text.trimmed().isEmpty()) continue;
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
  // A quote is a link with no record, so the links decide whether anything is added.
  if (links.isEmpty()) return;
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
                              if (!error) m_answerFiles.remove(requestId);
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
  // Then the model last sent with, while its provider can still run it.
  if (selection.isEmpty()) {
    const QJsonObject last = m_kept.lastModels.value(m_kept.lastInstance);
    const composer::Instance* instance = instanceOf(last);
    if (instance && instance->ready() && !composer::findModel(*instance, last.value(QLatin1String("model")).toString()).isEmpty()) {
      selection = last;
    }
  }
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
    disconnect(m_timelineStatus);
    m_timeline = timeline;
    if (timeline) {
      m_timelineConnection = connect(timeline, &TimelineModel::turnChanged, this, &ComposerController::publish);
      // A thread's messages are known once its stream is live.
      m_timelineStatus = connect(timeline, &TimelineModel::statusChanged, this, &ComposerController::reconcileUnsent);
    }
  }
  reconcileUnsent();
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
    // Each question with the files attached to its answer.
    const QHash<QString, QList<Attachment>> files = m_answerFiles.value(question.value(QStringLiteral("requestId")).toString());
    QVariantList asked;
    for (const QJsonValue& value : item.value(QLatin1String("questions")).toArray()) {
      QVariantMap one = value.toObject().toVariantMap();
      one.insert(QStringLiteral("attachments"), shownAttachments(files.value(one.value(QStringLiteral("id")).toString())));
      asked.append(one);
    }
    question.insert(QStringLiteral("questions"), asked);
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

// A draft that became a thread: what the user typed after sending its first
// message goes on in the thread's composer.
void ComposerController::adopt(const QString& draftId, const QString& threadKey, const QString& text) {
  Draft carried = m_drafts.take(draftId);
  if (text.isEmpty() && carried.attachments.isEmpty() && carried.excerpts.isEmpty()) return;
  const Draft there = m_drafts.value(threadKey);
  if (!there.text.isEmpty() || !there.attachments.isEmpty() || !there.excerpts.isEmpty()) return;
  carried.edit = QVariant();
  carried.text = text;
  carried.cursor = std::clamp(carried.cursor, 0, int(text.size()));
  m_drafts.insert(threadKey, carried);
  save();
}

// A thread that moved to another machine has a new key: what was written for
// it, and the model and modes chosen, follow it there.
void ComposerController::carryDrafts() {
  QList<std::pair<QString, QString>> moved;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    const QString located = m_store->located(it.key());
    if (located != it.key()) moved.append({it.key(), located});
  }
  if (moved.isEmpty()) return;
  for (const auto& [from, to] : moved) {
    Draft carried = m_drafts.take(from);
    // The brick showing the thread there has made no edit yet.
    carried.edit = QVariant();
    const Draft there = m_drafts.value(to);
    if (there.text.isEmpty() && there.attachments.isEmpty() && there.excerpts.isEmpty()) m_drafts.insert(to, carried);
  }
  save();
}

QString ComposerController::draft(const QString& target) const {
  if (const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(target)) return kept->text;
  return m_drafts.value(target).text;
}

QVariant ComposerController::setting(const QString& key) const {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return settings ? settings->setting(key) : QVariant();
}

QVariantMap ComposerController::attachmentPreview(const QString& id) {
  const Attachment* found = findAttachment(id);
  if (!found) return {};
  QVariantMap preview{{QStringLiteral("id"), found->id}, {QStringLiteral("name"), found->name}, {QStringLiteral("mimeType"), found->mimeType}};
  if (!found->file) {
    preview.insert(QStringLiteral("url"), found->dataUrl);
    return preview;
  }
  // What was pasted, or the file where it was picked from, up to the megabyte the viewer shows.
  QByteArray bytes = found->content;
  if (bytes.isEmpty() && !found->path.isEmpty()) {
    QFile file(found->path);
    if (file.open(QIODevice::ReadOnly)) bytes = file.read(1024 * 1024);
  }
  if (!bytes.contains('\0')) preview.insert(QStringLiteral("text"), QString::fromUtf8(bytes));
  return preview;
}

bool ComposerController::insertAtEnd(const QString& text) {
  const QString where = target();
  if (where.isEmpty()) return false;
  QString next = draft(where);
  if (!next.isEmpty() && !next.back().isSpace()) next += u' ';
  next += text;
  setText(where, next, int(next.size()));
  return true;
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

bool ComposerController::slashUsageLimits(const QString& target, const QString& text) {
  static const QRegularExpression command(QStringLiteral("^/usage-limits\\s*$"), QRegularExpression::CaseInsensitiveOption);
  if (!command.match(text.trimmed()).hasMatch()) return false;
  const composer::Instance* instance = instanceOf(selection(target));
  // Offered by the environment only where there are limits to show.
  const bool offered = instance && std::any_of(instance->slashCommands.begin(), instance->slashCommands.end(), [](const QJsonValue& value) {
    return value.toObject().value(QLatin1String("name")) == QLatin1String("usage-limits");
  });
  if (!offered) return false;
  QVariantList windows;
  for (const QJsonValue& value : instance->usageLimits.value(QLatin1String("windows")).toArray()) {
    const QJsonObject window = value.toObject();
    const double used = window.value(QLatin1String("usedPercent")).toDouble();
    windows.append(QVariantMap{{QStringLiteral("label"), window.value(QLatin1String("label")).toString()},
                               {QStringLiteral("usedPercent"), used},
                               {QStringLiteral("remainingPercent"), std::clamp(100.0 - used, 0.0, 100.0)},
                               {QStringLiteral("resetsAt"), window.value(QLatin1String("resetsAt")).toString()}});
  }
  m_usageLimits.insert(target, QVariantMap{{QStringLiteral("provider"), instance->displayName},
                                           {QStringLiteral("checkedAt"), instance->usageLimits.value(QLatin1String("checkedAt")).toString()},
                                           {QStringLiteral("windows"), windows},
                                           {QStringLiteral("message"), windows.isEmpty() ? tr("%1 has not reported its limits yet.").arg(instance->displayName)
                                                                                          : QString()}});
  setText(target, QString(), 0);
  publish();
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

void ComposerController::rememberModel(const QJsonObject& selection) {
  const QString instanceId = selection.value(QLatin1String("instanceId")).toString();
  if (instanceId.isEmpty() || (m_kept.lastInstance == instanceId && m_kept.lastModels.value(instanceId) == selection)) return;
  m_kept.lastInstance = instanceId;
  m_kept.lastModels.insert(instanceId, selection);
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
  kept.multipleModels.reset();
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
  // A choice the provider takes from the prompt (Claude's ultrathink) is put
  // there instead (the web's TraitsPicker); any other choice takes it out.
  static const QRegularExpression prefix(QStringLiteral("^Ultrathink:\\s*"), QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression slashCommand(QStringLiteral("^/[^\\s/]+(?:\\s|$)"));
  for (const QJsonValue& entry : descriptors) {
    const QJsonObject descriptor = entry.toObject();
    const QJsonArray injected = descriptor.value(QLatin1String("promptInjectedValues")).toArray();
    if (str(descriptor, QLatin1String("id")) != id || injected.isEmpty()) continue;
    const QString text = draft(target).trimmed();
    if (injected.contains(QJsonValue::fromVariant(value))) {
      if (!text.startsWith(kUltrathinkPrefix.trimmed()) && !slashCommand.match(text).hasMatch()) {
        const QString next = kUltrathinkPrefix + text;
        setText(target, next, int(next.size()));
      }
      return true;
    }
    if (prefix.match(text).hasMatch()) {
      const QString next = QString(text).remove(prefix);
      setText(target, next, int(next.size()));
    }
  }
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
  // A new thread: its project's default permissions, else the default for
  // new threads (Settings → Project defaults).
  auto* shell = NativeShell::of(this);
  const auto* settings = shell->controller<SettingsController>();
  if (const auto kept = shell->controller<DraftController>()->draft(target); kept && settings) {
    for (const QString& path : {QStringLiteral("projectSettingsOverrides.%1.defaultRuntimeMode").arg(kept->projectId),
                                QStringLiteral("defaultRuntimeMode")}) {
      if (const QString mode = settings->value(path).toString(); !mode.isEmpty()) return mode;
    }
  }
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

  const QVariantList attachments = shownAttachments(kept.attachments, true);
  QVariantList terminalContexts;
  QVariantList reviewComments;
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
    if (!context.review.isEmpty()) {
      const QString filePath = context.review.value(QLatin1String("filePath")).toString();
      reviewComments.append(QVariantMap{{QStringLiteral("id"), context.id},
                                        {QStringLiteral("label"), reviewLabel(filePath, context.lineStart, context.lineEnd)},
                                        {QStringLiteral("filePath"), filePath},
                                        {QStringLiteral("lineStart"), context.lineStart},
                                        {QStringLiteral("lineEnd"), context.lineEnd},
                                        {QStringLiteral("text"), context.text}});
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
  // An effort the prompt asks for (Ultrathink) is the one shown.
  QVariantList shownOptions = options;
  if (instance && text.trimmed().startsWith(kUltrathinkPrefix.trimmed())) {
    const QJsonArray described = composer::descriptors(composer::findModel(*instance, selectedModel), chosen.value(QLatin1String("options")).toArray(), planOn);
    for (qsizetype i = 0; i < described.size() && i < shownOptions.size(); ++i) {
      const QJsonArray injected = described.at(i).toObject().value(QLatin1String("promptInjectedValues")).toArray();
      if (injected.isEmpty()) continue;
      QVariantMap option = shownOptions.at(i).toMap();
      option.insert(QStringLiteral("value"), injected.first().toVariant());
      shownOptions[i] = option;
    }
  }
  const auto orNull = [](const QString& value) { return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value); };
  return QVariantMap{
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), isDraft ? QStringLiteral("draft") : QStringLiteral("server")},
      // The branch and worktree controls under the composer: a new thread's,
      // and kept once it has started only when the user asks (Composer context).
      {QStringLiteral("showContextStrip"), isDraft || setting(QStringLiteral("persistComposerContextStrip")).toBool()},
      {QStringLiteral("edit"), kept.edit.isValid() ? kept.edit : QVariant::fromValue(nullptr)},
      {QStringLiteral("text"), text},
      {QStringLiteral("cursor"), cursor},
      {QStringLiteral("triggerKind"), trigger ? QVariant(trigger->kind) : QVariant::fromValue(nullptr)},
      {QStringLiteral("suggestions"), suggestionList},
      {QStringLiteral("suggestionsEmptyText"), emptyText},
      {QStringLiteral("attachments"), attachments},
      {QStringLiteral("terminalContexts"), terminalContexts},
      {QStringLiteral("reviewComments"), reviewComments},
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
      // A first message launching, or a message on its way to the MC.
      {QStringLiteral("isSendBusy"), busy || m_queues.contains(target)},
      {QStringLiteral("isConnecting"), false},
      {QStringLiteral("pendingApprovalCount"), approvals.size()},
      {QStringLiteral("pendingUserInputCount"), questions.size()},
      {QStringLiteral("showPlanFollowUpPrompt"), showPlanFollowUp},
      {QStringLiteral("selectedInstanceId"), orNull(selectedInstance)},
      {QStringLiteral("selectedModel"), orNull(selectedModel)},
      {QStringLiteral("options"), shownOptions},
      {QStringLiteral("runtimeMode"), runtimeModeOf(target)},
      {QStringLiteral("runtimeModes"), composer::runtimeModes(instance)},
      {QStringLiteral("interactionMode"), interactionModeOf(target)},
      {QStringLiteral("showInteractionModeToggle"), planOn},
      {QStringLiteral("usageLimits"), m_usageLimits.contains(target) ? QVariant(m_usageLimits.value(target)) : QVariant::fromValue(nullptr)},
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
      // A new thread may go to several models: [{instanceId, model}] once
      // more than one is chosen.
      {QStringLiteral("supportsMultiple"), !m_draftId.isEmpty() && target == m_draftId},
      {QStringLiteral("multiple"), [&]() -> QVariant {
         const auto models = m_drafts.value(target).multipleModels;
         if (!models) return QVariant::fromValue(nullptr);
         QVariantList list;
         for (const QJsonObject& model : *models) list.append(model.toVariantMap());
         return list;
       }()},
      {QStringLiteral("shortcut"),
       toggle.isNull() ? QVariant::fromValue(nullptr) : toggle.toMap().value(QStringLiteral("label"))},
      {QStringLiteral("previousProvider"), key(QStringLiteral("modelPicker.previousProvider"))},
      {QStringLiteral("nextProvider"), key(QStringLiteral("modelPicker.nextProvider"))},
      {QStringLiteral("jump"), jump},
  };
}

// --- Keeping drafts ---------------------------------------------------------------

// An attachment as the drafts' file keeps it: an image with its bytes
// (`dataUrl`), a file with its path or pasted text and what the MC knows it as.
QJsonObject ComposerController::attachmentJson(const Attachment& attachment) {
  QJsonObject kept{{QStringLiteral("id"), attachment.id},
                   {QStringLiteral("name"), attachment.name},
                   {QStringLiteral("mimeType"), attachment.mimeType},
                   {QStringLiteral("sizeBytes"), double(attachment.sizeBytes)},
                   {QStringLiteral("dataUrl"), attachment.dataUrl}};
  if (!attachment.source.isEmpty()) kept.insert(QStringLiteral("source"), attachment.source);
  if (attachment.file) {
    kept.insert(QStringLiteral("file"), true);
    kept.insert(QStringLiteral("path"), attachment.path);
    kept.insert(QStringLiteral("dataUrl"), QStringLiteral("data:;base64,") + QString::fromLatin1(attachment.content.toBase64()));
    kept.insert(QStringLiteral("pastedText"), attachment.pastedText);
    kept.insert(QStringLiteral("remoteId"), attachment.remoteId);
    kept.insert(QStringLiteral("environmentId"), attachment.environmentId);
    kept.insert(QStringLiteral("upload"), attachment.upload);
  }
  return kept;
}

std::optional<ComposerController::Attachment> ComposerController::attachmentOf(const QJsonObject& kept) {
  const QString dataUrl = kept.value(QLatin1String("dataUrl")).toString();
  const bool file = kept.value(QLatin1String("file")).toBool();
  if (!file && !dataUrl.startsWith(QLatin1String("data:image/"))) return std::nullopt;
  Attachment attachment{kept.value(QLatin1String("id")).toString(), kept.value(QLatin1String("name")).toString(),
                        kept.value(QLatin1String("mimeType")).toString(), qint64(kept.value(QLatin1String("sizeBytes")).toDouble()),
                        file ? QString() : dataUrl, kept.value(QLatin1String("source")).toObject()};
  if (!file) return attachment;
  attachment.file = true;
  attachment.path = kept.value(QLatin1String("path")).toString();
  attachment.content = QByteArray::fromBase64(dataUrl.section(u',', 1).toLatin1());
  attachment.pastedText = kept.value(QLatin1String("pastedText")).toBool();
  attachment.remoteId = kept.value(QLatin1String("remoteId")).toString();
  attachment.environmentId = kept.value(QLatin1String("environmentId")).toString();
  // An upload this shell did not see end has to go again.
  if (attachment.remoteId.isEmpty()) {
    attachment.upload = QStringLiteral("failed");
    attachment.error = tr("The upload was interrupted.");
  }
  return attachment;
}

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
      if (const auto attachment = attachmentOf(image.toObject())) kept.attachments.append(*attachment);
    }
    for (const QJsonValue& context : entry.value(QLatin1String("terminalContexts")).toArray()) {
      kept.excerpts.append(excerptOf(context.toObject()));
    }
    if (!kept.id.isEmpty()) m_kept.stash.append(kept);
  }
  m_kept.lastInstance = str(stored, QLatin1String("lastInstance"));
  const QJsonObject lastModels = stored.value(QLatin1String("lastModels")).toObject();
  for (auto it = lastModels.begin(); it != lastModels.end(); ++it) m_kept.lastModels.insert(it.key(), it.value().toObject());
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
  QJsonObject unsentImages;
  if (images.open(QIODevice::ReadOnly)) {
    const QJsonObject data = QJsonDocument::fromJson(images.readAll()).object();
    const QJsonObject kept = data.value(QLatin1String("targets")).toObject();
    for (auto it = kept.begin(); it != kept.end(); ++it) {
      QList<Attachment>& attachments = m_drafts[it.key()].attachments;
      for (const QJsonValue& value : it.value().toArray()) {
        if (const auto attachment = attachmentOf(value.toObject())) attachments.append(*attachment);
      }
    }
    unsentImages = data.value(QLatin1String("unsent")).toObject();
    m_kept.images = imagesSignature(kept) + u'\n' + imagesSignature(unsentImages);
  }
  // The sends the app quit or crashed on, waiting to be reconciled.
  m_kept.unsent.clear();
  for (const QJsonValue& value : stored.value(QLatin1String("unsent")).toArray()) {
    const QJsonObject entry = value.toObject();
    Unsent kept{str(entry, QLatin1String("target")), str(entry, QLatin1String("thread")), str(entry, QLatin1String("messageId")),
                std::nullopt, str(entry, QLatin1String("text")), {}, {}, str(entry, QLatin1String("batch")), true};
    if (entry.value(QLatin1String("after")).isString()) kept.after = str(entry, QLatin1String("after"));
    for (const QJsonValue& image : unsentImages.value(kept.messageId).toArray()) {
      if (const auto attachment = attachmentOf(image.toObject())) kept.attachments.append(*attachment);
    }
    for (const QJsonValue& context : entry.value(QLatin1String("terminalContexts")).toArray()) {
      kept.excerpts.append(excerptOf(context.toObject()));
    }
    if (!kept.target.isEmpty() && !kept.messageId.isEmpty()) m_kept.unsent.append(kept);
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
    for (const Attachment& a : entry.attachments) images.append(attachmentJson(a));
    QJsonArray contexts;
    for (const Excerpt& t : entry.excerpts) contexts.append(excerptJson(t));
    stash.append(QJsonObject{{QStringLiteral("id"), entry.id},
                             {QStringLiteral("createdAt"), entry.createdAt.toString(Qt::ISODateWithMs)},
                             {QStringLiteral("text"), entry.text},
                             {QStringLiteral("attachments"), images},
                             {QStringLiteral("terminalContexts"), contexts}});
  }
  QJsonArray unsent;
  QJsonObject unsentImages;
  for (const Unsent& entry : m_kept.unsent) {
    QJsonObject kept{{QStringLiteral("target"), entry.target}, {QStringLiteral("thread"), entry.thread},
                     {QStringLiteral("messageId"), entry.messageId}, {QStringLiteral("text"), entry.prompt}};
    if (entry.after) kept.insert(QStringLiteral("after"), *entry.after);
    if (!entry.batch.isEmpty()) kept.insert(QStringLiteral("batch"), entry.batch);
    QJsonArray contexts;
    for (const Excerpt& t : entry.excerpts) contexts.append(excerptJson(t));
    if (!contexts.isEmpty()) kept.insert(QStringLiteral("terminalContexts"), contexts);
    unsent.append(kept);
    QJsonArray list;
    for (const Attachment& attachment : entry.attachments) list.append(attachmentJson(attachment));
    if (!list.isEmpty()) unsentImages.insert(entry.messageId, list);
  }
  // Whole or not at all: a write cut short would lose every thread's draft.
  QDir().mkpath(QFileInfo(m_kept.path).absolutePath());
  QSaveFile file(m_kept.path);
  if (file.open(QIODevice::WriteOnly)) {
    QJsonObject stored{{QStringLiteral("targets"), targets}};
    if (!stash.isEmpty()) stored.insert(QStringLiteral("stash"), stash);
    if (!unsent.isEmpty()) stored.insert(QStringLiteral("unsent"), unsent);
    if (!m_kept.lastInstance.isEmpty()) {
      QJsonObject lastModels;
      for (auto it = m_kept.lastModels.cbegin(); it != m_kept.lastModels.cend(); ++it) lastModels.insert(it.key(), it.value());
      stored.insert(QStringLiteral("lastInstance"), m_kept.lastInstance);
      stored.insert(QStringLiteral("lastModels"), lastModels);
    }
    file.write(QJsonDocument(stored).toJson(QJsonDocument::Compact));
    file.commit();
  }
  // The drafts' images, apart: rewritten only when they change.
  QJsonObject images;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    QJsonArray list;
    for (const Attachment& attachment : it.value().attachments) list.append(attachmentJson(attachment));
    if (!list.isEmpty()) images.insert(it.key(), list);
  }
  const QString joined = imagesSignature(images) + u'\n' + imagesSignature(unsentImages);
  if (joined == m_kept.images) return;
  if (images.isEmpty() && unsentImages.isEmpty()) {
    if (QFile::remove(imagesPath()) || !QFile::exists(imagesPath())) m_kept.images = joined;
    return;
  }
  QSaveFile imagesFile(imagesPath());
  if (!imagesFile.open(QIODevice::WriteOnly)) return;
  QJsonObject kept{{QStringLiteral("targets"), images}};
  if (!unsentImages.isEmpty()) kept.insert(QStringLiteral("unsent"), unsentImages);
  imagesFile.write(QJsonDocument(kept).toJson(QJsonDocument::Compact));
  // Remembered once written, so a failed write is tried again on the next save.
  if (imagesFile.commit()) m_kept.images = joined;
}
