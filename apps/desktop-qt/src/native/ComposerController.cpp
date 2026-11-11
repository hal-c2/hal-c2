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
#include "PlanController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "SpaceController.h"
#include "ThisMachine.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "TimelineSummary.h"
#include "ToastController.h"
#include "WorkspaceController.h"
#include "WorkspaceFiles.h"

namespace {
const NativeControllerRegistrar<ComposerController> registrar(QStringLiteral("composer"),
                                                               {QStringLiteral("turn"), QStringLiteral("composer"),
                                                                QStringLiteral("modelPicker"), QStringLiteral("composerStash")});

// The prompt that has the provider implement a proposed plan.
const QString kImplementPrefix = QStringLiteral("PLEASE IMPLEMENT THIS PLAN:\n");
// How long a new thread waits to be placed before it starts where the user
// picked: the MC itself waits a second for the picked machine and a second for
// the others.
constexpr int kPlacementWaitMs = 3000;
// Why a request cannot be answered when its provider process has ended.
const QString kProviderGone = QStringLiteral("Provider process is gone — interrupt or restart the run to respond.");

QString str(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// McClient's answer to a call the connection dropped under: the MC may or
// may not have carried it out ("not connected" is one that never left).
bool unanswered(const std::optional<QString>& error) {
  return error && *error == QLatin1String("disconnected");
}

// An answer that says nothing of the message: the connection dropped under
// it, or it never left. The outbox sends it again.
bool undelivered(const std::optional<QString>& error) {
  return unanswered(error) || (error && *error == QLatin1String("not connected"));
}

// The MC has the message and its provider has not taken it yet (a steer):
// asked again, the MC answers once it has (orchestration.ex `decide_message`).
bool stillSending(const QJsonValue& detail) {
  return detail.toObject().value(QLatin1String("code")) == QLatin1String("message_still_sending");
}

// The thread's model, runtime or interaction mode changed after the choice
// the send carries was made: the MC took none of it.
bool selectionStale(const QJsonValue& detail) {
  return detail.toObject().value(QLatin1String("code")) == QLatin1String("selection-stale");
}

// The base a choice sent to the thread goes with: the revision of its
// selection it was made against. None from an MC that counts none.
void withBase(QJsonObject& command, const std::optional<qint64>& base) {
  if (base) command.insert(QStringLiteral("selectionBase"), double(*base));
}

// The title of an approval whose request names none.
QString approvalTitle(const QString& kind) {
  if (kind == QLatin1String("mcp-elicitation")) return QStringLiteral("App access approval");
  if (kind == QLatin1String("command")) return QStringLiteral("Command approval");
  if (kind == QLatin1String("file-read")) return QStringLiteral("File read approval");
  if (kind == QLatin1String("permission")) return QStringLiteral("App permission approval");
  return QStringLiteral("File change approval");
}

// What is offered when the provider names no options, the primary one first.
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

// A new thread's title: the prompt, else the first image, cut to 50.
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

// How many prompts the stash keeps.
constexpr qsizetype kMaxStashEntries = 20;
// What one message can carry (packages/contracts: a provider turn's
// attachments, and COMPOSER_CONTEXT_MAX_RECORDS / its serialized size).
constexpr qsizetype kMaxAttachments = 100;
constexpr qsizetype kMaxContextRecords = 200;
constexpr qsizetype kMaxContextChars = 16000000;
// How a prompt the user typed asks Claude to ultrathink.
const QString kUltrathinkPrefix = QStringLiteral("Ultrathink:\n");

// What the user typed of a sent message:
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

// `[Assistant quote](hal-c2-citation://v1/<environment>/<thread>/<message>?text=...)`.
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

// A message as the queue lists it: each quoted reply as its words, and the
// comment after them, not its link (upstream #18999).
QString quotedPlainly(const QString& text) {
  static const QRegularExpression link(QStringLiteral("\\[Assistant quote\\]\\((?:hal-c2|t3)-citation://v1/[^\\s)?]+\\?([^\\s)]+)\\)"));
  if (!text.contains(QLatin1String("-citation://v1/"))) return text;
  QString shown;
  qsizetype from = 0;
  for (auto it = link.globalMatch(text); it.hasNext();) {
    const QRegularExpressionMatch match = it.next();
    QString quote;
    QString comment;
    for (const QString& pair : match.captured(1).split(u'&')) {
      const qsizetype eq = pair.indexOf(u'=');
      const QString value = QUrl::fromPercentEncoding(pair.mid(eq + 1).replace(u'+', u' ').toLatin1());
      if (pair.startsWith(QLatin1String("text="))) quote = value;
      if (pair.startsWith(QLatin1String("comment="))) comment = value;
    }
    shown += text.mid(from, match.capturedStart() - from);
    shown += quote.isEmpty() ? match.captured(0) : comment.isEmpty() ? quote : quote + QStringLiteral(" Comment: ") + comment;
    from = match.capturedEnd();
  }
  return (shown + text.mid(from)).trimmed();
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
  connect(shell->controller<DraftController>(), &DraftController::started, this, &ComposerController::carryInto);
  // The row says whether a turn runs, which decides follow-ups and the plan.
  connect(m_store, &ShellStore::changed, this, [this] {
    // A moved thread's edit ends first, so the draft it set aside is carried.
    recoverQueuedEdits();
    carryDrafts();
    forgetTakenPicks();
    reconcileUnsent();
    settleModes();
    refreshPathSearch();
    drainOutbox();
    publish();
  });
  // A dropped connection fails its calls while the store still says online.
  connect(m_client, &McClient::readyChanged, this, [this] {
    // The thread list the outbox goes by is the one sent after this drop.
    if (!m_client->isReady()) m_outboxSince = m_store->snapshots() + 1;
    if (onPage() && !m_pageProjectAsked) askPageProject();
    refreshPathSearch();
    drainOutbox();
    publish();
  });
  // The route's checkout arrived or moved, so an @ word can now be searched.
  connect(shell->controller<WorkspaceController>(), &WorkspaceController::placeChanged, this, [this] {
    refreshPathSearch();
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
  // A Space page on show takes the prompt when no thread or draft has it.
  if (auto* spaces = shell->controller<SpaceController>()) {
    connect(spaces, &SpacePages::changed, this, &ComposerController::followPage);
    connect(spaces, &SpacePages::promptPageChanged, this, &ComposerController::followPage);
    connect(spaces, &SpacePages::agentAskRequested, this, &ComposerController::startAsk);
    // The images' prompt: what it offers, and whether an image is being made.
    connect(spaces, &SpacePages::imageOfferChanged, this, [this] {
      if (onImages()) publish();
    });
  }
  refreshCatalogue();
  follow();
  // What a restart kept goes once the MC has said what it holds.
  drainOutbox();
}

// The cached sidebar before the MC answers (a phone opened offline): the
// route thread's composer takes its draft, and its outbox shows what still
// waits to be sent. Nothing reaches the MC and nothing is decided on the
// cached rows: a send waits in the outbox (or is refused, off the phone), and
// the outbox goes once activate() has the MC's own thread list.
void ComposerController::preview() {
  if (m_active) return;
  if (!std::exchange(m_previewing, true)) {
    connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this,
            &ComposerController::previewTurn);
  }
  previewTurn();
}

void ComposerController::previewTurn() {
  if (m_active) return;
  m_thread = openThread();
  publish();
}

bool ComposerController::handle(const QString& action, const QVariant& payload) {
  if (!m_active && !m_previewing) return false;
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
  // The images' prompt makes an image of its words: nothing a turn carries.
  if (onImages()) {
    static const QSet<QString> turnOnly{
        QStringLiteral("composer.terminalContext.add"), QStringLiteral("composer.reviewComment.add"),
        QStringLiteral("composer.citation.add"),        QStringLiteral("composer.ask"),
        QStringLiteral("composer.project.set"),         QStringLiteral("composer.model.multiple.toggle"),
        QStringLiteral("composer.option.set"),          QStringLiteral("composer.runtimeMode.set"),
        QStringLiteral("composer.interactionMode.set"), QStringLiteral("composer.stash"),
        QStringLiteral("composer.stash.restore"),       QStringLiteral("composer.interrupt"),
        QStringLiteral("composer.attach"),              QStringLiteral("composer.plan.implement"),
        QStringLiteral("composer.model.favorite.toggle")};
    if (turnOnly.contains(action)) return true;
    if (action == QLatin1String("composer.model.select")) {
      selectImageModel(target, map.value(QStringLiteral("instanceId")).toString(), map.value(QStringLiteral("model")).toString());
      return true;
    }
  }
  if (action == QLatin1String("composer.history.step")) {
    if (!target.isEmpty()) stepHistory(target, map.value(QStringLiteral("direction")).toString() != QLatin1String("forward"));
    return true;
  }
  // A page has no terminal, diff or replies of its own to quote.
  if (action == QLatin1String("composer.terminalContext.add")) return onPage() || addTerminalContext(map);
  if (action == QLatin1String("composer.reviewComment.add")) return onPage() || addReviewComment(map);
  if (action == QLatin1String("composer.citation.add")) return onPage() || addCitation(map);
  if (action == QLatin1String("composer.ask")) {
    startAsk();
    return true;
  }
  if (action == QLatin1String("composer.project.set")) {
    const QString projectId = map.value(QStringLiteral("projectId")).toString();
    if (!onPage() || target.isEmpty() || m_store->projectRow(m_client->environment(), projectId).isEmpty()) return true;
    m_drafts[target].projectId = projectId;
    save();
    refreshPathSearch();
    publish();
    return true;
  }
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
    Draft& kept = m_drafts[target];
    // A carried thread's link is in the text where it was chosen: taking
    // its chip off takes the link out too, or the send carries a link with
    // no record behind it.
    const bool threadLink = std::any_of(kept.excerpts.cbegin(), kept.excerpts.cend(),
                                        [&](const Excerpt& context) { return context.id == id && !context.thread.isEmpty(); });
    if (kept.excerpts.removeIf([&](const Excerpt& context) { return context.id == id; }) > 0) {
      bool published = false;
      if (threadLink) {
        const QString text = draft(target);
        const QRegularExpression link(QStringLiteral(" ?\\[@[^\\]]*\\]\\(hal-c2-context://v1/thread/thread_%1\\)")
                                          .arg(QRegularExpression::escape(id)));
        // The caret keeps its place among the words that stay: a link
        // stripped before it moves it back by the link's length, and one
        // stripped around it leaves it where the link started.
        const int cursor = std::clamp(kept.cursor, 0, int(text.size()));
        QString stripped;
        stripped.reserve(text.size());
        qsizetype at = 0;
        qsizetype removed = 0;
        std::optional<int> spanned;
        for (auto matches = link.globalMatch(text); matches.hasNext();) {
          const QRegularExpressionMatch match = matches.next();
          stripped += text.sliced(at, match.capturedStart() - at);
          if (!spanned) {
            if (match.capturedEnd() <= cursor) {
              removed += match.capturedLength();
            } else if (match.capturedStart() < cursor) {
              spanned = int(match.capturedStart() - removed);
            }
          }
          at = match.capturedEnd();
        }
        stripped += text.sliced(at);
        if (stripped != text) {
          setText(target, stripped, spanned.value_or(int(cursor - removed)));
          published = true;
        }
      }
      if (!published) publish();
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
  if (action == QLatin1String("composer.effort.step")) {
    if (!target.isEmpty()) stepEffort(target, map.value(QStringLiteral("direction")).toInt());
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
    setThreadMode(target, ModeKind::Runtime, mode);
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

  if (action == QLatin1String("composer.interrupt")) return interrupt(map.value(QStringLiteral("runId")).toString());
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
    // One of the edited queued message's own: off the edit, the MC keeps it until saved.
    if (QueuedEdit* edit = queuedEdit(target)) {
      const qsizetype before = edit->sent.size();
      for (qsizetype i = edit->sent.size() - 1; i >= 0; --i) {
        if (edit->sent.at(i).toObject().value(QLatin1String("id")).toString() == id) edit->sent.removeAt(i);
      }
      if (edit->sent.size() != before) {
        edit->sentChanged = true;
        publish();
        return true;
      }
    }
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
      uploadFile(id, found->environmentId.isEmpty() ? environmentOf(target) : found->environmentId);
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
  if (action == QLatin1String("composer.outbox.edit")) {
    if (!target.isEmpty()) editWaiting(target, map.value(QStringLiteral("messageId")).toString());
    return true;
  }
  if (action == QLatin1String("composer.outbox.delete")) {
    if (!target.isEmpty()) deleteWaiting(target, map.value(QStringLiteral("messageId")).toString());
    return true;
  }
  if (action == QLatin1String("composer.queue.edit.cancel")) {
    endQueuedEdit(target);
    return true;
  }
  if (action == QLatin1String("composer.queue.resume")) {
    return resumeQueue();
  }
  if (action == QLatin1String("composer.queue.steer")) {
    // Without a run, the first queued one (the steer key).
    QString runId = map.value(QStringLiteral("runId")).toString();
    if (runId.isEmpty()) {
      for (const QVariant& entry : turnState().value(QStringLiteral("queue")).toList()) {
        runId = entry.toMap().value(QStringLiteral("runId")).toString();
        if (!runId.isEmpty()) break;
      }
    }
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
    // Only what the user typed: not a scheduled task's, another agent's or the app's message.
    const QString by = str(item, QLatin1String("createdBy"));
    if ((!by.isEmpty() && by != QLatin1String("user")) || TimelineModel::sentByScheduledTask(item) ||
        !str(item, QLatin1String("senderThreadId")).isEmpty()) {
      continue;
    }
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

// Why a draft cannot be sent for what it carries, else empty.
QString ComposerController::carryProblem(const QList<Attachment>& attachments, const QList<Excerpt>& contexts) {
  if (attachments.size() > kMaxAttachments) {
    return QStringLiteral("Remove attachments until there are at most %1.").arg(kMaxAttachments);
  }
  // Each excerpt rides as one context record (withExcerpts); a quote rides
  // as a link with none.
  qsizetype records = 0;
  qsizetype chars = 0;
  for (const Excerpt& context : contexts) {
    if (!context.citation.isEmpty()) continue;
    if (!context.thread.isEmpty()) {
      ++records;
      chars += context.thread.value(QLatin1String("title")).toString().size();
      continue;
    }
    if (context.text.trimmed().isEmpty()) continue;
    ++records;
    chars += context.text.size() + context.terminalLabel.size();
  }
  if (records > kMaxContextRecords) {
    return QStringLiteral("Remove context items until there are at most %1.").arg(kMaxContextRecords);
  }
  if (chars > kMaxContextChars) {
    return QStringLiteral("This draft has too much context to send. Remove some context items and try again.");
  }
  return {};
}

// The draft goes to the stash and the composer
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
  std::optional<StashEntry> oldest;
  if (m_kept.stash.size() > kMaxStashEntries) oldest = m_kept.stash.takeLast();
  // A stash that cannot be written keeps nothing: the prompt stays in the composer.
  if (!save()) {
    m_kept.stash.removeFirst();
    if (oldest) m_kept.stash.append(*oldest);
    NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("error"), QStringLiteral("Could not stash this prompt"),
                                                               QStringLiteral("The stash could not be saved on this machine."));
    publish();
    return true;
  }
  if (oldest) {
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
// leaves the stash.
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

// What the stash menu shows: each entry with a snippet of its text.
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
      // What it holds instead: images, files, or both as attachments.
      const qsizetype files = std::count_if(entry.attachments.cbegin(), entry.attachments.cend(), [](const Attachment& a) { return a.file; });
      const qsizetype all = entry.attachments.size();
      const QString kind = files == 0 ? QStringLiteral("image") : files == all ? QStringLiteral("file") : QStringLiteral("attachment");
      snippet = all == 0 ? QStringLiteral("(empty)") : QStringLiteral("(%1 %2%3)").arg(all).arg(kind, all == 1 ? QString() : QStringLiteral("s"));
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
// the provider or background work. A Stop naming its run (`only`, a plugin
// notice's) stops nothing once another run is the one to stop.
bool ComposerController::interrupt(const QString& only) {
  if (onPage()) {
    if (auto* spaces = NativeShell::of(this)->controller<SpaceController>()) {
      spaces->handle(QStringLiteral("space.agent.stop"), QVariantMap());
    }
    return true;
  }
  const auto thread = m_store->thread(openThread());
  if (!thread) return false;
  sidebar::Nullable runId = thread->activeRunId;
  if (!runId && (thread->activityRunStatus == QStringLiteral("waiting") || thread->pendingBackgroundTasks > 0)) {
    runId = thread->latestRunId;
  }
  if (!runId || (!only.isEmpty() && *runId != only)) return true;
  // The turn the user stops here stays open once it settles.
  if (m_timeline) m_timeline->keepOpen(*runId);
  m_client->dispatchCommand(this, thread->environmentId,
                            {
                                {QStringLiteral("type"), QStringLiteral("run.interrupt")},
                                {QStringLiteral("threadId"), thread->id},
                                {QStringLiteral("runId"), *runId},
                                // The user's Stop also stops what the thread delegated.
                                {QStringLiteral("stopDelegated"), true},
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
// it, with no text).
bool ComposerController::submit(const QVariantMap& payload) {
  const QString target = this->target();
  if (target.isEmpty()) return true;
  const QString text = payload.contains(QStringLiteral("text")) ? payload.value(QStringLiteral("text")).toString()
                                                                : draft(target);
  // The submit is the brick's newest edit, so it takes the cleared (or
  // restored) text as the answer to it.
  setText(target, text, int(text.size()), payload.value(QStringLiteral("edit")));
  if (onPage()) return submitPage(target, text);
  if (onImages()) return submitImages(target, text);
  if (queuedEdit(target)) return saveQueuedEdit(target, text);
  if (slashMode(target, text)) return true;
  if (slashUsageLimits(target, text)) return true;
  // The next message closes the limits "/usage-limits" opened.
  if (!text.trimmed().isEmpty()) m_usageLimits.remove(target);
  if (!m_draftId.isEmpty()) return submitDraft(target, payload);
  const Draft& kept = m_drafts.value(target);
  if (const QString problem = carryProblem(kept.attachments, kept.excerpts); !problem.isEmpty()) {
    toast(QStringLiteral("Message not sent"), problem);
    return true;
  }
  const bool hasExtras = !kept.attachments.isEmpty() || !kept.excerpts.isEmpty();
  const bool planFollowUp = !hasExtras && turnState().value(QStringLiteral("plan")).isValid();
  if (text.trimmed().isEmpty() && !hasExtras && !planFollowUp) return true;
  if (stopForExpiredExcerpts(text, kept)) return true;

  QString mode = QStringLiteral("auto");
  if (running(target)) {
    const QString intent = payload.value(QStringLiteral("intent")).toString();
    if (intent == QLatin1String("restart") && canSteerActive()) {
      mode = QStringLiteral("restart");
    } else if (intent == QLatin1String("queue") || intent == QLatin1String("steer")) {
      mode = intent == QLatin1String("steer") && !canSteerActive() ? QStringLiteral("queue") : intent;
    } else {
      const bool queue = setting(QStringLiteral("followUpBehavior")).toString() == QLatin1String("queue");
      const bool alternate = intent == QLatin1String("alternate");
      mode = queue != alternate ? QStringLiteral("queue") : QStringLiteral("steer");
      if (mode == QLatin1String("steer") && !canSteerActive()) mode = QStringLiteral("queue");
    }
  }
  return sendTurn(target, text, mode, planFollowUp, true);
}

bool ComposerController::sendTurn(const QString& target, const QString& text, const QString& mode, bool planFollowUp,
                                  bool fromDraft) {
  const auto thread = m_store->thread(target);
  if (!thread) return false;
  // An Antigravity model its environment has not set up cannot be sent to:
  // its setup lives on the desktop, so say so instead of dispatching.
  const QJsonObject chosen = selection(target);
  if (const composer::Instance* instance = instanceOf(chosen);
      instance && instance->driver == QLatin1String("antigravity") &&
      (!instance->ready() ||
       (!str(chosen, QLatin1String("model")).isEmpty() && composer::findModel(*instance, str(chosen, QLatin1String("model"))).isEmpty()))) {
    toast(QStringLiteral("Antigravity model unavailable"),
          QStringLiteral("Set up Antigravity on the desktop, or choose another model."));
    return true;
  }
  // The outbox takes a message the MC cannot be reached for, one whose files
  // are still going up, and one written behind a message still waiting there,
  // which must go first.
  const bool connected = m_client->isReady() && m_store->threadOnline(target);
  const QList<Attachment> carrying = m_drafts.value(target).attachments;
  const bool uploading = fromDraft && std::any_of(carrying.cbegin(), carrying.cend(), [](const Attachment& a) {
                           return a.upload == QLatin1String("uploading");
                         });
  const bool waits =
      m_waitsOffline && fromDraft &&
      (!connected || uploading || m_outboxHeld.contains(target) ||
       std::any_of(m_kept.unsent.cbegin(), m_kept.unsent.cend(), [&](const Unsent& u) { return u.waiting && u.target == target; }));
  // Else nothing leaves while the MC is out of reach: the draft stays as it is.
  if (!connected && !waits) {
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("Not connected: message not sent"),
        QStringLiteral("Reconnecting to the environment. Try again once it is connected."));
    return true;
  }
  // A failed upload stops the send; one still going up holds it in the
  // outbox where the shell waits offline, and stops it where it does not.
  if (fromDraft) {
    const bool failed = std::any_of(carrying.cbegin(), carrying.cend(), [](const Attachment& a) { return a.upload == QLatin1String("failed"); });
    if ((failed || (uploading && !waits)) && filesBlock(carrying, QStringLiteral("sending"))) return true;
  }
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
  // Only what the user picked goes: with no pick the thread runs on what it
  // holds when the turn starts, so a change made elsewhere since stands. A
  // thread whose own provider is known not to run here needs a pick
  // (composerState); one the catalogue cannot judge yet is the MC's to run.
  const Draft& picks = m_drafts.value(target);
  const bool modelPicked = picks.modelSelection.has_value();
  if (!modelPicked && !thread->modelSelection.isEmpty() && !m_catalogue.isEmpty()) {
    const composer::Instance* own = instanceOf(thread->modelSelection);
    if (!own || !own->ready()) {
      toast(QStringLiteral("Choose a model to send"),
            QStringLiteral("This thread's provider is unavailable here. Pick a model, then send again."));
      return true;
    }
  }
  const QJsonObject shownSelection = selection(target);
  const QJsonObject modelSelection = modelPicked ? shownSelection : QJsonObject();
  // The modes are set as the user picks them (setThreadMode). The send sets
  // one only where the composer shows another than the thread will have: a
  // saved mode the provider no longer offers, or the mode a plan's follow-up
  // chooses. Like the user's, these name no revision, and are this client's
  // own changes, which the model pick stands past.
  const composer::Instance* shownInstance = instanceOf(shownSelection);
  const auto heading = [&](ModeKind kind, const QString& rowMode) {
    const auto setting = settingModes(kind).constFind(target);
    return setting != settingModes(kind).cend() ? setting->mode : rowMode;
  };
  QString runtimeMode;
  if (const QString headed = heading(ModeKind::Runtime, thread->runtimeMode); !headed.isEmpty()) {
    if (const QString shown = composer::shownRuntimeMode(shownInstance, headed); shown != headed) runtimeMode = shown;
  }
  const QString headedInteraction = heading(ModeKind::Interaction, thread->interactionMode);
  QString interactionMode = planFollowUp ? (implement ? QStringLiteral("default") : QStringLiteral("plan")) : interactionModeOf(target);
  // A thread the MC has no mode for keeps the MC's default.
  if (interactionMode == headedInteraction || (headedInteraction.isEmpty() && interactionMode == QLatin1String("default"))) {
    interactionMode.clear();
  }
  // The pick names the revision it was made against; dispatchAll moves it on
  // past this client's own changes.
  const std::optional<qint64> base =
      modelPicked && thread->selectionRevision ? std::optional<qint64>(picks.pickBase.value_or(*thread->selectionRevision)) : std::nullopt;
  QList<QJsonObject> commands;
  if (!runtimeMode.isEmpty()) {
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.runtime-mode.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("runtimeMode"), runtimeMode},
        {QStringLiteral("createdAt"), createdAt},
    });
  }
  if (!interactionMode.isEmpty()) {
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.interaction-mode.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("interactionMode"), interactionMode},
        {QStringLiteral("createdAt"), createdAt},
    });
  }
  // Another provider takes the thread over, handed its conversation by the MC.
  // A thread that names no provider is not leaving one: the message's model
  // selection is what the MC runs it on.
  const QString instanceId = str(modelSelection, QLatin1String("instanceId"));
  const QString current = str(thread->modelSelection, QLatin1String("instanceId"));
  if (!instanceId.isEmpty() && !current.isEmpty() && instanceId != current) {
    QJsonObject command{
        {QStringLiteral("type"), QStringLiteral("provider.switch")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("modelSelection"), modelSelection},
        {QStringLiteral("createdAt"), createdAt},
    };
    withBase(command, base);
    commands.append(command);
  } else if (modelPicked && !thread->selectionRevision && !composer::pickMatchesThread(modelSelection, thread->modelSelection)) {
    // An MC that counts no revisions runs a plain send on the message's model
    // but keeps the thread's own: the pick is saved to the thread first, so
    // it is what the thread runs and every client shows.
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.model-selection.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("modelSelection"), modelSelection},
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
  if (!modelSelection.isEmpty()) {
    message.insert(QStringLiteral("modelSelection"), modelSelection);
    withBase(message, base);
  }
  // This device's memory of the model and its options, picked or not.
  rememberModel(shownSelection);
  if (implement) {
    message.insert(QStringLiteral("sourcePlanRef"),
                   QJsonObject{{QStringLiteral("threadId"), thread->id}, {QStringLiteral("planId"), str(plan, QLatin1String("id"))}});
  }
  // The MC resolves the context.
  if (mode == QLatin1String("queue")) {
    message.insert(QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("queue_after_active")}});
  } else {
    message.insert(QStringLiteral("deliveryIntent"), mode);
    message.insert(QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("start_immediately")}});
  }
  Draft& draft = m_drafts[target];

  // Implementing from the plan's own button leaves the draft alone.
  const QList<Attachment> attachments = fromDraft ? std::exchange(draft.attachments, {}) : QList<Attachment>();
  const QList<Excerpt> contexts =
      fromDraft ? std::exchange(draft.excerpts, {}) : QList<Excerpt>();
  warnOfExpiredExcerpts(contexts);
  withExcerpts(message, contexts);
  commands.append(message);
  const QString messageId = str(message, QLatin1String("messageId"));
  // What the outbox gives back with a refusal or an edit: the model pick,
  // with the revision it was made against.
  QJsonObject choices;
  if (modelPicked) choices.insert(QStringLiteral("modelSelection"), modelSelection);
  if (base) choices.insert(QStringLiteral("selectionBase"), double(*base));
  if (waits) {
    m_kept.unsent.removeIf([&](const Unsent& unsent) { return unsent.kept && unsent.target == target; });
    Unsent waiting{target, target, messageId, std::nullopt, fromDraft ? text : QString(), attachments, contexts};
    waiting.commands = commands;
    waiting.choices = choices;
    waiting.waiting = true;
    waiting.waited = true;
    m_kept.unsent.append(waiting);
    setText(target, QString(), 0);
    save();
    drainOutbox();
    publish();
    return true;
  }
  // A send made while an earlier one is still in flight waits its turn.
  QList<Send>& queue = m_queues[target];
  queue.append({target, thread->environmentId, thread->id, commands, attachments, contexts, fromDraft ? text : QString(), messageId, planFollowUp});
  const bool first = queue.size() == 1;
  // Kept until the MC answers. Sending again is newer than what a restart
  // left of the thread's sends.
  m_kept.unsent.removeIf([&](const Unsent& unsent) { return unsent.kept && unsent.target == target; });
  if (fromDraft && (!text.isEmpty() || !attachments.isEmpty() || !contexts.isEmpty())) {
    m_kept.unsent.append({target, target, messageId, newestBefore(target), text, attachments, contexts});
    if (m_waitsOffline) {
      m_kept.unsent.last().commands = commands;
      m_kept.unsent.last().choices = choices;
    }
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

// A new thread's first send: the thread is placed, its images
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
  if (const QString problem = carryProblem(attachments, contexts); !problem.isEmpty()) {
    toast(QStringLiteral("Message not sent"), problem);
    return true;
  }
  if (stopForExpiredExcerpts(text, m_drafts.value(draftId))) return true;
  if (m_launching.contains(draftId)) return true;

  const WorkspaceController::Launch where = shell->controller<WorkspaceController>()->launch(draftId);
  // A draft whose project is gone (its machine left, or the project went
  // before the draft heard) keeps its prompt for another project.
  if (where.problem.isEmpty() && !m_store->project(where.environmentId + QLatin1Char(':') + where.projectId)) {
    shell->controller<ToastController>()->show(QStringLiteral("warning"), QStringLiteral("Choose a project first"),
                                               QStringLiteral("This draft no longer points to an available project."));
    return true;
  }
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
      {QStringLiteral("runtimeMode"), composer::shownRuntimeMode(instanceOf(modelSelection), runtimeModeOf(draftId))},
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
    warnOfExpiredExcerpts(contexts);
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
    NativeShell::of(this)->controller<WorkspaceController>()->publish();
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
    kept.carried = false;
  } else {
    // Each model's thread starts in a worktree of its own.
    if (!kept.multipleModels) m_bridge->dispatch(QStringLiteral("workspace.envMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("worktree")}});
    m_drafts[target].multipleModels = models;
  }
  NativeShell::of(this)->controller<WorkspaceController>()->publish();
  save();
  publish();
  return true;
}

// Send to multiple models: each gets a thread of its own, in a
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
      // No translation is loaded, so "thread(s)" would show as written: each count spells itself out.
      const int started = int(progress->started);
      const QString message = started == 1 ? tr("Started %n thread in background", nullptr, 1) : tr("Started %n threads in background", nullptr, started);
      shell->controller<ToastController>()->show(
          QStringLiteral("success"), message, {},
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
    // Each model's own provider decides which of the saved permissions stand.
    launch.insert(QStringLiteral("runtimeMode"), composer::shownRuntimeMode(instanceOf(model), runtimeModeOf(draftId)));
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

// A background launch's answer: a toast that opens the new
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
  const auto finish = [this, target](const std::optional<QString>& error, const QJsonValue& detail) {
    if (error) {
      // The sends queued behind it would reach the MC out of order, so they
      // stop too and come back with it.
      const QList<Send> unsent = m_queues.take(target);
      if (m_waitsOffline && (undelivered(error) || stillSending(detail))) {
        waitAgain(target, unsent);
        return;
      }
      if (m_waitsOffline || selectionStale(detail)) {
        restoreRefused(target, unsent, *error, detail);
        return;
      }
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
        // A plan's feedback says so, with a reason even when the MC gave none.
        if (unsent.constFirst().planFollowUp) {
          toast(QStringLiteral("Plan follow-up not sent"), error->isEmpty() ? QStringLiteral("Failed to send plan follow-up.") : *error);
        } else {
          toast(QStringLiteral("Failed to send message"), *error);
        }
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
    m_outboxFailures.remove(target);
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
                     finish(error, QJsonValue());
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

void ComposerController::setWaitsOffline(bool on) {
  m_waitsOffline = on;
  drainOutbox();
  publish();
}

void ComposerController::drainOutbox() {
  if (!m_waitsOffline || !m_active || !m_client->isReady() || !m_store->synchronized() || m_store->snapshots() < m_outboxSince) return;
  // One window sends the outbox, which every window shares.
  for (const auto& window : NativeShell::of(this)->shell()->windows()) {
    auto* composer = window->controller<ComposerController>();
    if (composer && composer->isActive()) {
      if (composer != this) return;
      break;
    }
  }
  QStringList targets;
  QSet<QString> gone;
  QSet<QString> blocked;
  for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
    if (!unsent.waiting || targets.contains(unsent.target) || gone.contains(unsent.target) || blocked.contains(unsent.target)) continue;
    if (m_queues.contains(unsent.target) || m_outboxHeld.contains(unsent.target)) continue;
    // A send whose files have not all arrived waits for them, in its order.
    const bool filesReady = std::all_of(unsent.attachments.cbegin(), unsent.attachments.cend(), [](const Attachment& a) {
      return a.upload != QLatin1String("uploading") && a.upload != QLatin1String("failed");
    });
    if (!filesReady) {
      blocked.insert(unsent.target);
      continue;
    }
    if (!m_store->environmentOnline(unsent.target.section(QLatin1Char(':'), 0, 0))) continue;
    // The environment has said what it holds, and the thread is not there.
    if (!m_store->thread(unsent.target)) {
      gone.insert(unsent.target);
      continue;
    }
    targets.append(unsent.target);
  }
  if (targets.isEmpty() && gone.isEmpty()) return;
  m_kept.unsent.removeIf([&](const Unsent& unsent) { return unsent.waiting && gone.contains(unsent.target); });
  for (const QString& target : std::as_const(targets)) {
    const auto thread = m_store->thread(target);
    QList<Send>& queue = m_queues[target];
    for (Unsent& unsent : m_kept.unsent) {
      if (!unsent.waiting || unsent.target != target) continue;
      unsent.waiting = false;
      queue.append({target, thread->environmentId, thread->id, unsent.commands, unsent.attachments, unsent.excerpts,
                    unsent.prompt, unsent.messageId, false});
    }
  }
  save();
  for (const QString& target : std::as_const(targets)) sendNext(target);
  publish();
}

void ComposerController::waitAgain(const QString& target, const QList<Send>& sends) {
  for (const Send& send : sends) {
    const auto kept = std::find_if(m_kept.unsent.begin(), m_kept.unsent.end(),
                                   [&](const Unsent& unsent) { return unsent.messageId == send.messageId; });
    if (kept == m_kept.unsent.end() || kept->commands.isEmpty()) {
      keepUnanswered(send.messageId);
      continue;
    }
    kept->waiting = true;
    kept->waited = true;
  }
  const int failures = m_outboxFailures.value(target);
  m_outboxFailures.insert(target, failures + 1);
  const int delay = m_outboxDelays.isEmpty() ? 0 : m_outboxDelays.at(std::min<qsizetype>(failures, m_outboxDelays.size() - 1));
  m_outboxHeld.insert(target);
  emit outboxRetryScheduled(target, delay);
  QTimer::singleShot(delay, this, [this, target] {
    m_outboxHeld.remove(target);
    drainOutbox();
  });
  save();
  publish();
}

void ComposerController::restoreRefused(const QString& target, const QList<Send>& sends, const QString& error,
                                        const QJsonValue& detail) {
  const bool stale = selectionStale(detail);
  QStringList prompts;
  QList<Attachment> attachments;
  QList<Excerpt> contexts;
  QJsonObject choices;
  for (const Send& send : sends) {
    if (!send.prompt.isEmpty()) prompts.append(send.prompt);
    attachments.append(send.attachments);
    contexts.append(send.excerpts);
    for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
      if (unsent.messageId == send.messageId && choices.isEmpty()) choices = unsent.choices;
    }
    forgetUnsent(send.messageId);
  }
  if (stale) {
    toastStale(detail);
  } else if (!sends.isEmpty() && sends.constFirst().planFollowUp) {
    toast(QStringLiteral("Plan follow-up not sent"), error.isEmpty() ? QStringLiteral("Failed to send plan follow-up.") : error);
  } else {
    toast(QStringLiteral("Failed to send message"), error);
  }
  // Ahead of what was typed since, which stays.
  const QString typed = draft(target);
  if (!typed.isEmpty()) prompts.append(typed);
  const QString restored = prompts.join(QStringLiteral("\n\n"));
  Draft& kept = m_drafts[target];
  kept.attachments = attachments + kept.attachments;
  kept.excerpts = contexts + kept.excerpts;
  // A stale send's picks were made against what the thread has left: the
  // composer shows the thread's own, for the user to check.
  if (stale) {
    dropPicks(kept);
  } else {
    restoreChoices(kept, choices);
  }
  if (restored != typed) setText(target, restored, int(restored.size()));
  save();
  publish();
}

QVariantList ComposerController::outboxState(const QString& target) const {
  QVariantList outbox;
  for (const Unsent& unsent : std::as_const(m_kept.unsent)) {
    if (!unsent.waited || unsent.target != target) continue;
    outbox.append(QVariantMap{{QStringLiteral("messageId"), unsent.messageId},
                              {QStringLiteral("text"), unsent.prompt},
                              {QStringLiteral("attachments"), shownAttachments(unsent.attachments)},
                              {QStringLiteral("sending"), !unsent.waiting}});
  }
  return outbox;
}

// What is pulled back joins the composer ahead of anything typed there, with
// the model and modes it was written with. One on its way is not pulled back:
// the MC may already have it.
bool ComposerController::editWaiting(const QString& target, const QString& messageId) {
  const auto found = std::find_if(m_kept.unsent.cbegin(), m_kept.unsent.cend(), [&](const Unsent& unsent) {
    return unsent.messageId == messageId && unsent.target == target && unsent.waiting;
  });
  if (found == m_kept.unsent.cend()) return true;
  const Unsent unsent = *found;
  m_kept.unsent.erase(found);
  Draft& kept = m_drafts[target];
  kept.attachments = unsent.attachments + kept.attachments;
  kept.excerpts = unsent.excerpts + kept.excerpts;
  restoreChoices(kept, unsent.choices);
  forgetTakenPicks();
  const QString typed = draft(target);
  const QString text = typed.isEmpty() ? unsent.prompt : unsent.prompt.isEmpty() ? typed : unsent.prompt + QStringLiteral("\n\n") + typed;
  setText(target, text, int(text.size()));
  save();
  publish();
  return true;
}

bool ComposerController::deleteWaiting(const QString& target, const QString& messageId) {
  const auto found = std::find_if(m_kept.unsent.cbegin(), m_kept.unsent.cend(), [&](const Unsent& unsent) {
    return unsent.messageId == messageId && unsent.target == target && unsent.waiting;
  });
  if (found == m_kept.unsent.cend()) return true;
  const Unsent unsent = *found;
  m_kept.unsent.erase(found);
  // What had already arrived for it is the MC's to drop; an upload still in
  // flight finds nothing holding it when it lands and is dropped then
  // (uploadFile), and its copies going here stops the send being drained.
  for (const Attachment& attachment : unsent.attachments) {
    if (attachment.remoteId.isEmpty()) continue;
    m_client->call(this, attachment.environmentId, QStringLiteral("attachments.delete"),
                   QJsonObject{{QStringLiteral("attachmentId"), attachment.remoteId}},
                   [](const QJsonValue&, const std::optional<QString>&) {});
  }
  save();
  publish();
  return true;
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
// A started thread's model pick gives way once the thread moves past it, its
// own send being taken included, so a change made on another client shows
// here and no pick made before it undoes it. This client's own mode changes
// are not such a change: the pick stands past them (`nextPick`). From an MC
// that counts no revisions, a model the thread now runs is the thread's again
// and a pick it has not taken stays (upstream #20886).
void ComposerController::forgetTakenPicks() {
  bool forgot = false;
  for (auto it = m_own.begin(); it != m_own.end();) {
    const auto thread = m_store->thread(it.key());
    const std::optional<qint64> revision = thread ? thread->selectionRevision : std::nullopt;
    it->removeIf([&](const std::shared_ptr<OwnChange>& change) {
      return change->answered && (!revision || !ownAhead(*change, *revision));
    });
    it = it->isEmpty() ? m_own.erase(it) : std::next(it);
  }
  for (auto it = m_drafts.begin(); it != m_drafts.end(); ++it) {
    if (!it->modelSelection || it->multipleModels) continue;
    const auto thread = m_store->thread(it.key());
    if (!thread) continue;
    const std::optional<qint64> base = it->pickBase;
    if (nextPick(*it, *thread)) {
      forgot = forgot || it->pickBase != base;
      continue;
    }
    dropPicks(*it);
    forgot = true;
  }
  if (forgot) save();
}

bool ComposerController::ownAhead(const OwnChange& change, qint64 revision) {
  if (change.answered) return change.revision && *change.revision > revision;
  // One sent before `revision` may already be in it: the row can beat the
  // answer, and counting it again would take another client's change for it.
  return change.sentAt && *change.sentAt >= revision;
}

// The pick moves its base only across revisions this client's own answers
// name. While one of its own changes is unanswered, that change may be what
// moved the thread, so the pick waits, unmoved, for the answer to say.
bool ComposerController::nextPick(Draft& draft, const sidebar::Thread& thread) const {
  const std::optional<qint64> revision = thread.selectionRevision;
  if (!revision || !draft.pickBase) return !composer::pickMatchesThread(*draft.modelSelection, thread.modelSelection);
  const qint64 base = *draft.pickBase;
  if (*revision < base) return false;
  if (*revision == base) return true;
  QSet<qint64> named;
  qsizetype pending = 0;
  for (const auto& change : std::as_const(draft.pickOwn)) {
    if (!change->answered) ++pending;
    if (change->revision) named.insert(*change->revision);
  }
  qint64 unaccounted = 0;
  for (qint64 at = base + 1; at <= *revision; ++at) unaccounted += named.contains(at) ? 0 : 1;
  // Each unanswered change may yet name one revision; any more are another client's.
  if (unaccounted > pending) return false;
  if (unaccounted > 0) return true;
  draft.pickBase = *revision;
  draft.pickOwn.removeIf([&](const std::shared_ptr<OwnChange>& change) { return change->answered && !ownAhead(*change, *revision); });
  return true;
}

// Each pick is made fresh against what the thread holds now, with the own
// changes that may still move it on.
void ComposerController::notePick(const QString& target) {
  Draft& draft = m_drafts[target];
  draft.pickOwn.clear();
  const auto thread = m_store->thread(target);
  if (!thread || !thread->selectionRevision) {
    draft.pickBase.reset();
    return;
  }
  draft.pickBase = *thread->selectionRevision;
  for (const auto& change : m_own.value(target)) {
    if (ownAhead(*change, *draft.pickBase)) draft.pickOwn.append(change);
  }
}

std::shared_ptr<ComposerController::OwnChange> ComposerController::ownSent(const QString& target) {
  const auto thread = m_store->thread(target);
  auto change = std::make_shared<OwnChange>();
  change->sentAt = thread ? thread->selectionRevision : std::nullopt;
  m_own[target].append(change);
  if (auto draft = m_drafts.find(target); draft != m_drafts.end() && draft->modelSelection) draft->pickOwn.append(change);
  return change;
}

bool ComposerController::ownPending(const QString& target) const {
  const OwnChanges changes = m_own.value(target);
  return std::any_of(changes.cbegin(), changes.cend(), [](const auto& change) { return !change->answered; });
}

// The MC answers with the revision a change moved the thread to. An MC that
// counts revisions names one in every answer that moved the thread, and one
// that counts none never counts the change, so each thread's own MC decides.
void ComposerController::ownAnswered(const QString& target, const std::shared_ptr<OwnChange>& change, const QJsonValue& reply,
                                     bool took) {
  change->answered = true;
  if (const QJsonValue moved = reply.toObject().value(QLatin1String("selectionRevision")); took && moved.isDouble()) {
    change->revision = qint64(moved.toDouble());
  }
  // Sends that waited for the answers go now, made past this client's own changes.
  if (!ownPending(target)) {
    const QList<std::function<void()>> waiting = m_afterOwn.take(target);
    for (const auto& resume : waiting) resume();
  }
  forgetTakenPicks();
  publish();
}

void ComposerController::dropPicks(Draft& draft) {
  draft.modelSelection.reset();
  draft.pickBase.reset();
  draft.pickOwn.clear();
}

void ComposerController::restoreChoices(Draft& draft, const QJsonObject& choices) {
  const QJsonObject model = choices.value(QLatin1String("modelSelection")).toObject();
  if (model.isEmpty()) return;
  draft.modelSelection = model;
  draft.pickOwn.clear();
  draft.pickBase.reset();
  if (const QJsonValue base = choices.value(QLatin1String("selectionBase")); base.isDouble()) draft.pickBase = qint64(base.toDouble());
}

void ComposerController::toastStale(const QJsonValue& detail) {
  const QJsonObject refusal = detail.toObject();
  QJsonObject now = refusal.value(QLatin1String("modelSelection")).toObject();
  if (now.isEmpty()) now = refusal.value(QLatin1String("selection")).toObject().value(QLatin1String("modelSelection")).toObject();
  const QString instanceId = str(now, QLatin1String("instanceId"));
  const QString model = str(now, QLatin1String("model"));
  QString modelName = model;
  QString provider = instanceId;
  if (const composer::Instance* instance = composer::find(m_catalogue, instanceId)) {
    if (!instance->displayName.isEmpty()) provider = instance->displayName;
    if (const QString name = str(composer::findModel(*instance, model), QLatin1String("name")); !name.isEmpty()) modelName = name;
  }
  const QString where = modelName.isEmpty() || provider.isEmpty() ? QStringLiteral("This thread changed elsewhere.")
                                                                  : QStringLiteral("This thread moved to %1 on %2 elsewhere.").arg(modelName, provider);
  NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("warning"), QStringLiteral("Message not sent"),
                                                             where + QStringLiteral(" Check it and send again."));
}

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
  if (!excerpt.thread.isEmpty()) kept.insert(QStringLiteral("thread"), excerpt.thread);
  return kept;
}

ComposerController::Excerpt ComposerController::excerptOf(const QJsonObject& kept) {
  return {str(kept, QLatin1String("id")), str(kept, QLatin1String("terminalId")), str(kept, QLatin1String("terminalLabel")),
          kept.value(QLatin1String("lineStart")).toInt(1), kept.value(QLatin1String("lineEnd")).toInt(1),
          str(kept, QLatin1String("text")), kept.value(QLatin1String("citation")).toObject(),
          kept.value(QLatin1String("review")).toObject(), kept.value(QLatin1String("thread")).toObject()};
}

// A send's model pick names the revision it was made against. It is made past
// this client's own changes before it goes: the pick in the draft moved on
// across them (`nextPick`), and so does the next command once one before it
// in the send answers the revision right after its base. Nothing else moves
// it, so a change made elsewhere meanwhile refuses it (`selection-stale`).
void ComposerController::dispatchAll(const Send& send, qsizetype index, Dispatched done) {
  const QJsonObject& command = send.commands.at(index);
  const QString type = str(command, QLatin1String("type"));
  if (command.contains(QLatin1String("selectionBase"))) {
    // The MC takes calls side by side, so a pick sent while one of this
    // client's own changes is on its way could reach it before or after
    // that change: it waits for the answer, then is made past it.
    if (ownPending(send.target)) {
      m_afterOwn[send.target].append([this, send, index, done] { dispatchAll(send, index, done); });
      return;
    }
    qint64 base = qint64(command.value(QLatin1String("selectionBase")).toDouble());
    const Draft picks = m_drafts.value(send.target);
    if (picks.modelSelection && picks.pickBase && *picks.pickBase > base &&
        *picks.modelSelection == command.value(QLatin1String("modelSelection")).toObject()) {
      base = *picks.pickBase;
    }
    QSet<qint64> named;
    for (const auto& change : m_own.value(send.target)) {
      if (change->revision) named.insert(*change->revision);
    }
    while (named.contains(base + 1)) ++base;
    if (base != qint64(command.value(QLatin1String("selectionBase")).toDouble())) {
      Send rest = send;
      rebase(rest, index, base);
      return dispatchAll(rest, index, done);
    }
  }
  // The send's own mode change moves the revision on like the user's.
  std::shared_ptr<OwnChange> own;
  if (type == QLatin1String("thread.runtime-mode.set") || type == QLatin1String("thread.interaction-mode.set")) {
    own = ownSent(send.target);
  }
  m_client->dispatchCommand(this, send.environmentId, command,
                            [this, send, index, done, own](const QJsonValue& detail, const std::optional<QString>& error) {
                              if (own) ownAnswered(send.target, own, detail, !error);
                              if (!error && index + 1 < send.commands.size()) {
                                const QJsonObject answered = send.commands.at(index);
                                Send rest = send;
                                const QJsonObject next = rest.commands.at(index + 1);
                                const QJsonValue moved = detail.toObject().value(QLatin1String("selectionRevision"));
                                if (moved.isDouble() && next.contains(QLatin1String("selectionBase")) &&
                                    qint64(moved.toDouble()) == qint64(next.value(QLatin1String("selectionBase")).toDouble()) + 1) {
                                  rebase(rest, index + 1, qint64(moved.toDouble()));
                                }
                                if (m_waitsOffline) forgetAnswered(send.messageId, answered);
                                dispatchAll(rest, index + 1, done);
                                return;
                              }
                              done(error, error ? detail : QJsonValue());
                            });
}

// The send's choice at `index` made against `base`, in the outbox too, where a
// refusal gives the picks back from.
void ComposerController::rebase(Send& send, qsizetype index, qint64 base) {
  QJsonObject& next = send.commands[index];
  const QJsonObject before = next;
  next.insert(QStringLiteral("selectionBase"), double(base));
  for (Unsent& unsent : m_kept.unsent) {
    if (unsent.messageId != send.messageId) continue;
    for (QJsonObject& kept : unsent.commands) {
      if (kept == before) kept = next;
    }
    if (unsent.choices.contains(QLatin1String("selectionBase"))) unsent.choices.insert(QStringLiteral("selectionBase"), double(base));
  }
}

// A mode change the MC answered leaves the outbox's record of its send: sent
// again under a fresh command id, it could undo one made since on another
// device. One it did not answer stays, and goes again with the message (the
// MC takes the message once, by its id), as the mode it sets is absolute.
void ComposerController::forgetAnswered(const QString& messageId, const QJsonObject& command) {
  for (Unsent& unsent : m_kept.unsent) {
    if (unsent.messageId != messageId || unsent.commands.size() < 2) continue;
    if (unsent.commands.removeOne(command)) save();
  }
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
  const bool acceptsFiles = m_store->acceptsFileAttachments(environmentId);
  bool refusedFile = false;
  QStringList added;
  for (const QVariant& value : files) {
    const QVariantMap file = value.toMap();
    // An environment that takes no file attachments refuses files as they
    // are chosen; images, which ride with the message, still attach. A
    // large paste turned into a text file is no file to refuse: its words
    // go into the draft where they were pasted instead.
    if (!acceptsFiles && !file.contains(QStringLiteral("base64"))) {
      if (file.contains(QStringLiteral("text"))) {
        const QString pasted = file.value(QStringLiteral("text")).toString();
        const QString text = draft(target);
        const int cursor = std::clamp(m_drafts[target].cursor, 0, int(text.size()));
        setText(target, text.left(cursor) + pasted + text.mid(cursor), cursor + int(pasted.size()));
        continue;
      }
      refusedFile = true;
      continue;
    }
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
  if (refusedFile) {
    NativeShell::of(this)->controller<ToastController>()->show(
        QStringLiteral("warning"), QStringLiteral("File not attached"),
        QStringLiteral("The server does not support file attachments."));
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

// A folder is named by its path,
// which only means something where the MC shares this machine's disk.
bool ComposerController::attachFolders(const QString& target, const QVariantList& folders) {
  if (!m_bridge->localFolderImportEnabled() || !thisMachine::hosts(*m_store, *m_client, environmentOf(target))) {
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
  for (Unsent& unsent : m_kept.unsent) {
    for (Attachment& attachment : unsent.attachments) {
      if (attachment.id == id) return &attachment;
    }
  }
  for (QList<Send>& queue : m_queues) {
    for (Send& send : queue) {
      for (Attachment& attachment : send.attachments) {
        if (attachment.id == id) return &attachment;
      }
    }
  }
  return nullptr;
}

int ComposerController::updateAttachmentCopies(const QString& id, const std::function<void(Attachment&)>& change) {
  int copies = 0;
  const auto apply = [&](QList<Attachment>& held) {
    for (Attachment& attachment : held) {
      if (attachment.id != id) continue;
      change(attachment);
      ++copies;
    }
  };
  for (Draft& draft : m_drafts) apply(draft.attachments);
  for (auto& questions : m_answerFiles) {
    for (QList<Attachment>& files : questions) apply(files);
  }
  for (Unsent& unsent : m_kept.unsent) apply(unsent.attachments);
  for (QList<Send>& queue : m_queues) {
    for (Send& send : queue) apply(send.attachments);
  }
  return copies;
}

QString ComposerController::environmentOf(const QString& target) const {
  if (const auto thread = m_store->thread(target)) return thread->environmentId;
  // A page's ask runs on the MC its Space is on.
  if (target.startsWith(pageKey({})) || target.startsWith(imagesKey({}))) return m_client->environment();
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
    updateAttachmentCopies(id, [&](Attachment& held) {
      held.upload = QStringLiteral("failed");
      held.error = why;
      held.progress = -1;
    });
    save();
    publish();
  };
  attachment->upload = QStringLiteral("uploading");
  attachment->error.clear();
  attachment->remoteId.clear();
  attachment->environmentId = environmentId;
  attachment->progress = -1;
  QByteArray bytes = attachment->content;
  if (!attachment->path.isEmpty()) {
    QFile file(attachment->path);
    if (!file.open(QIODevice::ReadOnly)) {
      failed(tr("%1 could not be read.").arg(attachment->name));
      return;
    }
    bytes = file.readAll();
    attachment->captured = bytes.left(1024 * 1024);
    attachment->capturedWhole = bytes.size() <= 1024 * 1024;
  }
  const QString mimeType = attachment->mimeType;
  publish();
  m_client->call(this, environmentId, QStringLiteral("attachments.createUploadUrl"),
                 QJsonObject{{QStringLiteral("type"), QStringLiteral("file")},
                             {QStringLiteral("name"), attachment->name},
                             {QStringLiteral("mimeType"), mimeType},
                             {QStringLiteral("sizeBytes"), bytes.size()}},
                 [this, id, bytes, mimeType, environmentId, failed](const QJsonValue& result, const std::optional<QString>& error) {
                   const QString url = result.toObject().value(QLatin1String("relativeUrl")).toString();
                   const QString remoteId = result.toObject().value(QLatin1String("attachmentId")).toString();
                   if (error || url.isEmpty() || remoteId.isEmpty()) {
                     failed(error.value_or(tr("The environment did not take the upload.")));
                     return;
                   }
                   m_client->upload(
                       this, url, bytes, mimeType,
                       [this, id, remoteId, environmentId, failed](const QJsonValue&, const std::optional<QString>& error) {
                         if (error) {
                           failed(*error);
                           return;
                         }
                         const int copies = updateAttachmentCopies(id, [&](Attachment& held) {
                           held.upload.clear();
                           held.remoteId = remoteId;
                           held.progress = -1;
                         });
                         if (copies == 0) {
                           // What it was uploading for went while it went up:
                           // the upload is the MC's to drop again.
                           m_client->call(this, environmentId, QStringLiteral("attachments.delete"),
                                          QJsonObject{{QStringLiteral("attachmentId"), remoteId}},
                                          [](const QJsonValue&, const std::optional<QString>&) {});
                         }
                         save();
                         publish();
                         // A send waiting on this upload can go now.
                         drainOutbox();
                       },
                       [this, id](qint64 sent, qint64 total) {
                         if (total <= 0) return;
                         const double gone = double(sent) / double(total);
                         bool steps = false;
                         updateAttachmentCopies(id, [&](Attachment& held) {
                           if (int(held.progress * 100) == int(gone * 100)) return;
                           held.progress = gone;
                           steps = true;
                         });
                         if (steps) publish();
                       });
                 });
}

// Send guards: nothing leaves while a file is still on
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
// last being what its window said of itself.
QVariantList ComposerController::shownAttachments(const QList<Attachment>& attachments, bool previews) const {
  QVariantList shown;
  for (const Attachment& attachment : attachments) {
    QVariant source = QVariant::fromValue(nullptr);
    if (str(attachment.source, QLatin1String("kind")) == QLatin1String("snap-shot")) {
      // The text the window said of itself,
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
                      {QStringLiteral("progress"), attachment.progress},
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

// The selection's text without CRs or blank edges, and a valid line range; a selection with
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

// The quoted lines' language, by the file's extension ("src/cart.ts" -> "ts"),
// as reviewCommentContext's inferReviewCommentFenceLanguage has it.
static QString fenceLanguage(const QString& filePath) {
  const QString path = QString(filePath).replace(QLatin1Char('\\'), QLatin1Char('/'));
  const QString name = path.mid(path.lastIndexOf(QLatin1Char('/')) + 1).toLower();
  const qsizetype dot = name.lastIndexOf(QLatin1Char('.'));
  if (dot > 0 && dot < name.size() - 1) return name.mid(dot + 1);
  if (name.startsWith(QLatin1Char('.')) && name.size() > 1) return name.mid(1);
  return QStringLiteral("text");
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
                               {QStringLiteral("diff"), comment.value(QStringLiteral("diff")).toString().left(32000)},
                               {QStringLiteral("fenceLanguage"), comment.value(QStringLiteral("fenceLanguage"), fenceLanguage(filePath)).toString()}};
  m_drafts[target].excerpts.append(context);
  publish();
  NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("success"), QStringLiteral("Comment added to the prompt"),
                                                             reviewLabel(filePath, first, last));
  return true;
}

bool ComposerController::holdsFiles(const QString& target) const {
  const QList<Attachment> attachments = m_drafts.value(target).attachments;
  return std::any_of(attachments.cbegin(), attachments.cend(), [](const Attachment& a) { return a.file; });
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

QSet<QString> ComposerController::unsentThreads() const {
  QSet<QString> threads;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    if (m_store->thread(it.key()) && draftPreview(it.key())) threads.insert(it.key());
  }
  return threads;
}

void ComposerController::discardDraft(const QString& target) {
  const auto kept = m_drafts.find(target);
  if (kept == m_drafts.end() || !m_store->thread(target)) return;
  kept->attachments.clear();
  kept->excerpts.clear();
  setText(target, QString(), 0);
  // The attachments went too, which the text alone does not save; other
  // windows' composers and every sidebar see the empty draft.
  save();
  for (const auto& window : NativeShell::of(this)->shell()->windows()) window->sidebar()->draftEdited(target);
}

namespace {

template <typename Excerpts>
qsizetype countExpired(const Excerpts& excerpts) {
  return std::count_if(excerpts.cbegin(), excerpts.cend(), [](const auto& context) {
    return context.citation.isEmpty() && context.review.isEmpty() && context.text.trimmed().isEmpty();
  });
}

}  // namespace

bool ComposerController::stopForExpiredExcerpts(const QString& text, const Draft& draft) {
  const qsizetype expired = countExpired(draft.excerpts);
  if (expired == 0 || expired != draft.excerpts.size() || !text.trimmed().isEmpty() || !draft.attachments.isEmpty()) return false;
  NativeShell::of(this)->controller<ToastController>()->show(
      QStringLiteral("warning"),
      expired == 1 ? QStringLiteral("Expired terminal context won't be sent") : QStringLiteral("Expired terminal contexts won't be sent"),
      QStringLiteral("Remove it or re-add it to include terminal output."));
  return true;
}

void ComposerController::warnOfExpiredExcerpts(const QList<Excerpt>& contexts) {
  const qsizetype expired = countExpired(contexts);
  if (expired == 0) return;
  NativeShell::of(this)->controller<ToastController>()->show(
      QStringLiteral("warning"),
      expired == 1 ? QStringLiteral("Expired terminal context omitted from message") : QStringLiteral("Expired terminal contexts omitted from message"),
      QStringLiteral("Re-add it if you want that terminal output included."));
}

// Each excerpt is an inline link in the text
// and a record in `context`; the MC swaps the links for the excerpts when it
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
    if (!context.thread.isEmpty()) {
      // A thread carried as context: its link is already in the text where
      // it was chosen; the record says which thread it names.
      records.append(QJsonObject{{QStringLiteral("version"), 1},
                                 {QStringLiteral("contextId"), QStringLiteral("thread_") + context.id},
                                 {QStringLiteral("kind"), QStringLiteral("thread")},
                                 {QStringLiteral("environmentId"), context.thread.value(QLatin1String("environmentId"))},
                                 {QStringLiteral("threadId"), context.thread.value(QLatin1String("threadId"))},
                                 {QStringLiteral("title"), context.thread.value(QLatin1String("title"))}});
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
    // An excerpt whose text is gone has nothing to send.
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
  // A quote is a link with no record, and a thread's record has its link
  // already in the text: either alone adds its half.
  if (links.isEmpty() && records.isEmpty()) return;
  if (!links.isEmpty()) {
    const QString text = message.value(QLatin1String("text")).toString();
    const QString joined = links.join(QLatin1Char(' '));
    message.insert(QStringLiteral("text"), text.isEmpty() ? joined : text + QStringLiteral("\n\n") + joined);
  }
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

// Removes a queued message, or sends it now: a steer of the running turn, or
// on a stopped thread its own turn, ahead of the rest (`queued-run.start`).
// One queue action at a time per thread: the queue's buttons wait for the
// MC's answer (`turn.queueBusy`), as an edit does.
bool ComposerController::queueCommand(const QString& type, const QString& runId) {
  const auto thread = m_store->thread(m_thread);
  if (!thread || runId.isEmpty() || m_queueBusy.contains(m_thread)) return true;
  QJsonObject command{{QStringLiteral("type"), type}, {QStringLiteral("threadId"), thread->id}};
  QString failure = QStringLiteral("Failed to remove the queued message.");
  if (type == QLatin1String("queued-run.cancel")) {
    command.insert(QStringLiteral("runId"), runId);
  } else if (thread->activeRunId) {
    command.insert(QStringLiteral("queuedRunId"), runId);
    command.insert(QStringLiteral("targetRunId"), *thread->activeRunId);
    failure = QStringLiteral("Failed to steer with the queued message.");
  } else {
    command.insert(QStringLiteral("type"), QStringLiteral("queued-run.start"));
    command.insert(QStringLiteral("runId"), runId);
    failure = QStringLiteral("Failed to send the queued message.");
  }
  const QString key = m_thread;
  m_queueBusy.insert(key);
  m_client->dispatchCommand(this, thread->environmentId, command,
                            [this, key, failure](const QJsonValue&, const std::optional<QString>& error) {
                              m_queueBusy.remove(key);
                              if (error) toast(failure, *error);
                              publish();
                            });
  publish();
  return true;
}

// Lets the MC start a queue it holds (after a restart or a usage limit). One
// request at a time per thread across every window, and only for a queue still
// held: a click on a stale card, after another device resumed it, asks nothing.
// The thread's stream has to be caught up too: the held flag a reconnected
// window still shows may be one the MC has since cleared. The answer is
// handled apart from this window, which may close before it comes: a refusal
// is told in the window that asked, else in the one the user is in.
bool ComposerController::resumeQueue() {
  const auto thread = m_store->thread(m_thread);
  if (!thread || m_kept.resuming.contains(m_thread) || !queueHeld()) return true;
  if (!m_client->isReady() || !m_store->synchronized() || !m_store->threadOnline(m_thread) || !m_timeline ||
      m_timeline->threadKey() != m_thread || m_timeline->status() != QLatin1String("live")) {
    // One warning however often the button is pressed while reconnecting: a toast
    // still showing is renewed rather than stacked.
    auto* toasts = NativeShell::of(this)->controller<ToastController>();
    const QString title = QStringLiteral("Not connected: queue not resumed");
    const QString description = QStringLiteral("Reconnecting to the environment. Try again once it is connected.");
    if (m_notConnectedToast.isEmpty() || !toasts->replace(m_notConnectedToast, QStringLiteral("warning"), title, description, {}, 5000)) {
      m_notConnectedToast = toasts->show(QStringLiteral("warning"), title, description);
    }
    return true;
  }
  const QString key = m_thread;
  NativeShell* shell = NativeShell::of(this)->shell();
  const QString windowId = NativeShell::of(this)->id();
  m_kept.resuming.insert(key);
  // The client is the reply's context, not this controller: the answer has to
  // clear `resuming` even when this window has closed (a client drop fails the call).
  m_client->dispatchCommand(m_client, thread->environmentId,
                            QJsonObject{{QStringLiteral("type"), QStringLiteral("queue.resume")}, {QStringLiteral("threadId"), thread->id}},
                            [shell = QPointer<NativeShell>(shell), key, windowId](const QJsonValue&, const std::optional<QString>& error) {
                              if (!shell) return;
                              // Cleared by the answer alone, not by the held flag clearing on the
                              // stream: the answer may come first, and until the event follows, the
                              // button is enabled for a queue still shown as held. A click then
                              // asks again, which is harmless: `queue.resume` only clears the
                              // flag and starts the next run if none is active, so a second one
                              // is a no-op. Holding `resuming` until the flag clears would
                              // instead leave "Resuming…" stuck whenever the queue is held again
                              // at once (the next run hitting the same usage limit).
                              shell->common<Kept>().resuming.remove(key);
                              if (error) {
                                NativeWindow* window = shell->window(windowId);
                                if (!window) window = shell->activeWindow();
                                if (window) window->controller<ToastController>()->error(QStringLiteral("Failed to resume the queue."), *error);
                              }
                              publishEverywhere(shell);
                            });
  // This window greys the button now, so a second click cannot ask again; the
  // others follow on the next turn of the loop, as a draft change does.
  publish();
  spread();
  return true;
}

// The reply comes from the event loop, not from a command being handled, so
// every window, this one gone or not, can republish at once.
void ComposerController::publishEverywhere(NativeShell* shell) {
  for (const auto& window : shell->windows()) {
    if (auto* composer = window->controller<ComposerController>()) composer->publish();
  }
}

bool ComposerController::editQueued(const QString& target, QString runId) {
  const QueuedEdit* open = queuedEdit(target);
  if (target.isEmpty() || !m_draftId.isEmpty() || (open && open->saving) || m_queueBusy.contains(target)) return true;
  const QVariantMap turn = turnState();
  // The question takes the composer: the queue cannot have it too.
  if (!turn.value(QStringLiteral("queueEditBlocked")).toString().isEmpty()) return true;
  const QVariantList queue = turn.value(QStringLiteral("queue")).toList();
  // The newest the MC has: one still being saved has no run to edit.
  if (runId.isEmpty()) {
    for (auto it = queue.crbegin(); it != queue.crend() && runId.isEmpty(); ++it) runId = it->toMap().value(QStringLiteral("runId")).toString();
  }
  if (runId.isEmpty()) return true;
  const auto entry = std::find_if(queue.cbegin(), queue.cend(), [&](const QVariant& item) {
    return item.toMap().value(QStringLiteral("runId")) == runId;
  });
  if (entry == queue.cend()) return true;
  const QString text = entry->toMap().value(QStringLiteral("text")).toString();
  const QString messageId = entry->toMap().value(QStringLiteral("messageId")).toString();
  // Moving to another queued message keeps the draft set aside for the first.
  if (!open) {
    QueuedEdit edit;
    edit.thread = target;
    edit.saved = draft(target);
    edit.savedCursor = m_drafts.value(target).cursor;
    edit.savedAttachments = std::exchange(m_drafts[target].attachments, {});
    if (m_timeline) edit.watch = connect(m_timeline, &TimelineModel::turnChanged, this, &ComposerController::recoverQueuedEdits);
    m_queuedEdits.insert(target, edit);
    save();
  } else if (open->runId != runId) {
    // What was added for the message left goes aside with the draft.
    QueuedEdit& edit = m_queuedEdits[target];
    edit.savedAttachments += std::exchange(m_drafts[target].attachments, {});
    edit.stored.clear();
    save();
  }
  QueuedEdit& edit = m_queuedEdits[target];
  edit.runId = runId;
  edit.messageId = messageId;
  edit.original = text;
  edit.sent = m_timeline ? m_timeline->entities(QStringLiteral("message")).value(messageId).value(QLatin1String("attachments")).toArray()
                         : QJsonArray();
  edit.sentChanged = false;
  setText(target, text, int(text.size()));
  return true;
}

bool ComposerController::saveQueuedEdit(const QString& target, const QString& text) {
  const auto thread = m_store->thread(target);
  if (!thread) return true;
  // The MC applies saves in the order they come: a second waits for the
  // first's answer rather than racing it, and the newest one is what goes.
  QueuedEdit* edit = queuedEdit(target);
  if (edit->saving) {
    edit->next = text;
    return true;
  }
  const QList<Attachment> added = m_drafts.value(target).attachments;
  // The MC refuses a message left with nothing in it.
  if (text.trimmed().isEmpty() && edit->sent.isEmpty() && added.isEmpty()) {
    toast(tr("A queued message cannot be left empty."), {});
    return true;
  }
  if (filesBlock(added, QStringLiteral("saving"))) return true;
  edit->saving = true;
  const QString runId = edit->runId;
  QJsonObject command{{QStringLiteral("type"), QStringLiteral("queued-run.edit")},
                      {QStringLiteral("threadId"), thread->id},
                      {QStringLiteral("runId"), runId},
                      {QStringLiteral("text"), text.trimmed()}};
  QStringList addedIds;
  for (const Attachment& attachment : added) addedIds.append(attachment.id);
  const auto dispatch = [this, target, runId, addedIds, environmentId = thread->environmentId](const QJsonObject& command) {
    m_client->dispatchCommand(this, environmentId, command,
                              [this, target, runId, addedIds, command](const QJsonValue&, const std::optional<QString>& error) {
                                QueuedEdit* edit = queuedEdit(target);
                                if (!edit || edit->runId != runId) return;
                                edit->saving = false;
                                const std::optional<QString> next = std::exchange(edit->next, std::nullopt);
                                if (error) {
                                  toast(QStringLiteral("Could not save the edited queued message."), *error);
                                } else {
                                  // What went with the message is the message's now.
                                  m_drafts[target].attachments.removeIf([&](const Attachment& a) { return addedIds.contains(a.id); });
                                  const QString saved = str(command, QLatin1String("text"));
                                  // Words typed since are a newer edit, left open over what was saved.
                                  if (!next && draft(target).trimmed() == saved) {
                                    endQueuedEdit(target);
                                    return;
                                  }
                                  // The next save starts from what this one saved.
                                  edit->original = saved;
                                  if (command.contains(QLatin1String("attachments"))) {
                                    edit->sent = command.value(QLatin1String("attachments")).toArray();
                                    edit->sentChanged = false;
                                  }
                                }
                                if (next) {
                                  saveQueuedEdit(target, *next);
                                  return;
                                }
                                publish();
                              });
  };
  // Text alone keeps the attachments the message has.
  if (!edit->sentChanged && added.isEmpty()) {
    dispatch(command);
    publish();
    return true;
  }
  // New images are stored for the message first, as a send's are; one a
  // refused save already stored is not stored again.
  QJsonArray images;
  QStringList imageIds;
  for (const Attachment& attachment : added) {
    if (attachment.file || edit->stored.contains(attachment.id)) continue;
    QJsonObject image{{QStringLiteral("type"), QStringLiteral("image")},
                      {QStringLiteral("name"), attachment.name},
                      {QStringLiteral("mimeType"), attachment.mimeType},
                      {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                      {QStringLiteral("dataUrl"), attachment.dataUrl}};
    if (!attachment.source.isEmpty()) image.insert(QStringLiteral("source"), attachment.source);
    images.append(image);
    imageIds.append(attachment.id);
  }
  // The message keeps its attachments, then the added ones in the order added.
  const auto withAttachments = [this, target, added](QJsonObject command) {
    const QueuedEdit& edit = m_queuedEdits[target];
    QJsonArray attachments = edit.sent;
    for (const Attachment& attachment : added) {
      if (attachment.file) {
        for (const QJsonValue& file : fileRecords({attachment})) attachments.append(file);
      } else if (const auto stored = edit.stored.constFind(attachment.id); stored != edit.stored.cend()) {
        attachments.append(*stored);
      }
    }
    command.insert(QStringLiteral("attachments"), attachments);
    return command;
  };
  if (images.isEmpty()) {
    dispatch(withAttachments(command));
    publish();
    return true;
  }
  m_client->call(this, thread->environmentId, QStringLiteral("assets.persistChatAttachments"),
                 QJsonObject{{QStringLiteral("threadId"), thread->id},
                             {QStringLiteral("messageId"), edit->messageId},
                             {QStringLiteral("attachments"), images}},
                 [this, target, runId, command, imageIds, withAttachments, dispatch](const QJsonValue& result, const std::optional<QString>& error) {
                   QueuedEdit* edit = queuedEdit(target);
                   if (!edit || edit->runId != runId) return;
                   if (error) {
                     edit->saving = false;
                     toast(QStringLiteral("Could not save the edited queued message."), *error);
                     if (const std::optional<QString> next = std::exchange(edit->next, std::nullopt)) {
                       saveQueuedEdit(target, *next);
                       return;
                     }
                     publish();
                     return;
                   }
                   const QJsonArray stored = result.toObject().value(QLatin1String("attachments")).toArray();
                   for (qsizetype i = 0; i < stored.size() && i < imageIds.size(); ++i) edit->stored.insert(imageIds.at(i), stored.at(i).toObject());
                   dispatch(withAttachments(command));
                 });
  publish();
  return true;
}

void ComposerController::endQueuedEdit(const QString& thread, bool keepEdit) {
  const auto it = m_queuedEdits.find(thread);
  if (it == m_queuedEdits.end()) return;
  const QueuedEdit edit = *it;
  m_queuedEdits.erase(it);
  disconnect(edit.watch);
  // The set-aside attachments come back ahead of any added since.
  Draft& kept = m_drafts[edit.thread];
  kept.attachments = edit.savedAttachments + kept.attachments;
  save();
  if (keepEdit) {
    save();
    publish();
    return;
  }
  setText(edit.thread, edit.saved, edit.savedCursor);
}

void ComposerController::recoverQueuedEdits() {
  // Rows read from the cache or held for an MC are not the MC's word: a
  // missing row there says nothing about the thread.
  if (!m_store->synchronized()) return;
  ThreadStore* threads = NativeShell::of(this)->controller<ThreadStore>();
  for (const QString& thread : m_queuedEdits.keys()) {
    const QueuedEdit* edit = queuedEdit(thread);
    if (!edit || edit->saving) continue;
    const std::optional<sidebar::Thread> row = m_store->thread(thread);
    // A deleted thread takes its edit with it; a moved one ends it, so the
    // draft set aside for it comes back and carryDrafts() takes it along.
    if (!row) {
      endQueuedEdit(thread);
      continue;
    }
    // The thread's queue is known while its stream is live.
    const TimelineModel* timeline = threads->timeline(thread);
    if (!timeline || timeline->status() != QLatin1String("live")) continue;
    // Still queued: its run waits and its message is there to edit.
    const QJsonObject run = timeline->entities(QStringLiteral("run")).value(edit->runId);
    if (run.value(QLatin1String("status")).toString() == QLatin1String("queued") &&
        timeline->entities(QStringLiteral("message")).contains(run.value(QLatin1String("userMessageId")).toString()))
      continue;
    const bool dirty = draft(thread) != edit->original || edit->sentChanged || !m_drafts.value(thread).attachments.isEmpty();
    const bool keep = dirty && edit->saved.trimmed().isEmpty();
    endQueuedEdit(thread, keep);
    if (!dirty) continue;
    const QString detail =
        thread == m_thread ? (keep ? tr("Your unsaved edit was kept in the composer.") : tr("Your unsaved edit was discarded."))
                           : (keep ? tr("Your unsaved edit in \u201c%1\u201d was kept in its composer.") : tr("Your unsaved edit in \u201c%1\u201d was discarded."))
                                 .arg(row->title);
    NativeShell::of(this)->controller<ToastController>()->show(keep ? QStringLiteral("info") : QStringLiteral("warning"),
                                                               QStringLiteral("Queued message is no longer queued"), detail);
  }
}

QString ComposerController::openThread() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

QString ComposerController::openDraft() const {
  const NavigationController::Route& route = NativeShell::of(this)->controller<NavigationController>()->route();
  return route.kind == QLatin1String("draft") ? route.draftId : QString();
}

// A thread's own model; for a draft the project's default: this device's project override, the
// project's, then the default for new threads. Empty lets the MC choose.
QJsonObject ComposerController::baseSelection(const QString& key) const {
  if (const auto thread = m_store->thread(key)) return thread->modelSelection;
  // A page's ask starts as a new thread in its project would.
  if (onPage() && key == pageKey(m_pageId)) return newThreadSelection(m_client->environment(), pageProject());
  const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(key);
  if (!kept) return {};
  return newThreadSelection(kept->environmentId, kept->projectId);
}

QJsonObject ComposerController::newThreadSelection(const QString& environmentId, const QString& projectId) const {
  // The project's MC names the model a new thread there starts on, resolved
  // from its own settings and providers; the rest is for an MC that does not.
  if (!projectId.isEmpty()) {
    const QJsonObject named = m_store->projectRow(environmentId, projectId).value(QLatin1String("newThreadModelSelection")).toObject();
    if (!named.isEmpty()) return named;
  }
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  const auto setting = [settings](const QString& path) {
    return settings ? QJsonValue::fromVariant(settings->value(path)).toObject() : QJsonObject();
  };
  QJsonObject selection = projectSelection(environmentId, projectId);
  if (selection.isEmpty()) selection = setting(QStringLiteral("defaultModelSelection"));
  // A page's ask then takes the model of the user's latest thread in its project,
  // from the threads the MC counts (page_agent.ex): not those a plugin or an agent
  // started, and deleted ones have left the store. Where the MC would give way to
  // the first provider that runs, this takes an older thread whose provider can.
  if (selection.isEmpty() && onPage() && !projectId.isEmpty() && projectId == pageProject()) {
    QString latest;
    for (const sidebar::Thread& thread : m_store->threads()) {
      if (thread.environmentId != environmentId || thread.projectId != projectId || thread.updatedAt < latest) continue;
      if (!thread.createdBy.isEmpty() && thread.createdBy != QLatin1String("user")) continue;
      const composer::Instance* instance = instanceOf(thread.modelSelection);
      if (!instance || !instance->ready()) continue;
      latest = thread.updatedAt;
      selection = thread.modelSelection;
    }
  }
  // Then the model last sent with from this device, while its provider can still
  // run it. The MC has no such fallback; a page's ask lands here only when the
  // project has no thread of the user's to take a model from.
  if (selection.isEmpty()) {
    const QJsonObject last = m_kept.lastModels.value(m_kept.lastInstance);
    const composer::Instance* instance = instanceOf(last);
    if (instance && instance->ready() && !composer::findModel(*instance, last.value(QLatin1String("model")).toString()).isEmpty()) {
      selection = last;
    }
  }
  return selection;
}

QJsonObject ComposerController::projectSelection(const QString& environmentId, const QString& projectId) const {
  if (projectId.isEmpty()) return {};
  if (const auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    const QJsonObject own =
        QJsonValue::fromVariant(settings->value(QStringLiteral("projectSettingsOverrides.%1.defaultModelSelection").arg(projectId))).toObject();
    if (!own.isEmpty()) return own;
  }
  return m_store->projectRow(environmentId, projectId).value(QLatin1String("defaultModelSelection")).toObject();
}

// A new thread (DraftController::started names `from` only then) opened on a
// draft with nothing of its own (just created, or never written or picked in,
// or holding only what an earlier new thread carried) takes the mode as
// picked there or as the thread has it, and the model the same way unless
// the project has a default model of its own. A draft the user has started
// on keeps what it has.
void ComposerController::carryInto(const QString& draftId, const QString& from) {
  if (from.isEmpty() || from == draftId) return;
  const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(draftId);
  if (!kept) return;
  const Draft before = m_drafts.value(draftId);
  const bool picked = !before.carried && (before.modelSelection || !before.interactionMode.isEmpty());
  if (!kept->text.isEmpty() || picked || before.multipleModels || !before.attachments.isEmpty() || !before.excerpts.isEmpty()) {
    return;
  }
  const auto thread = m_store->thread(from);
  const Draft source = m_drafts.value(from);
  Draft draft = before;
  // The mode the composer showed there.
  draft.interactionMode = interactionModeOf(from);
  draft.modelSelection.reset();
  if (projectSelection(kept->environmentId, kept->projectId).isEmpty()) {
    const QJsonObject model = source.modelSelection.value_or(thread ? thread->modelSelection : QJsonObject());
    if (!model.isEmpty()) draft.modelSelection = model;
  }
  draft.carried = true;
  if (draft.interactionMode == before.interactionMode && draft.modelSelection == before.modelSelection &&
      before.carried) {
    return;
  }
  m_drafts.insert(draftId, draft);
  save();
  publish();
}

QString ComposerController::openPage() const {
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  return spaces ? spaces->promptPage() : QString();
}

QString ComposerController::pageProject() const {
  const QString picked = m_drafts.value(pageKey(m_pageId)).projectId;
  if (!picked.isEmpty() && !m_store->projectRow(m_client->environment(), picked).isEmpty()) return picked;
  return m_pageProject;
}

void ComposerController::askPageProject() {
  auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  if (!spaces || !m_client->isReady()) return;
  m_pageProjectAsked = true;
  spaces->agentTarget([self = QPointer(this)](const QString& projectId) {
    if (!self || self->m_pageProject == projectId) return;
    self->m_pageProject = projectId;
    self->refreshPathSearch();
    self->publish();
  });
}

bool ComposerController::pageAgentRunning() const {
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  if (!onPage() || !spaces || spaces->pageId() != m_pageId) return false;
  const QString status = spaces->agent().value(QStringLiteral("status")).toString();
  return status == QLatin1String("running") || status == QLatin1String("stopping");
}

void ComposerController::followPage() {
  if (openThread().isEmpty() && openDraft().isEmpty() && (openPage() != m_pageId || openImages() != m_imagesSpace)) {
    follow();
  } else if (std::exchange(m_pageRunning, pageAgentRunning()) != m_pageRunning) {
    publish();
  }
}

QString ComposerController::openImages() const {
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  return spaces ? spaces->promptImages() : QString();
}

QJsonObject ComposerController::imageSelection(const QString& target) const {
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  if (!spaces) return {};
  const QVariantMap offer = spaces->imageProviders();
  if (const auto picked = m_drafts.value(target).modelSelection;
      picked && composer::offersImageModel(offer, picked->value(QLatin1String("instanceId")).toString(),
                                           picked->value(QLatin1String("model")).toString())) {
    return *picked;
  }
  return QJsonObject::fromVariantMap(offer.value(QStringLiteral("selection")).toMap());
}

bool ComposerController::selectImageModel(const QString& target, const QString& instanceId, const QString& model) {
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  if (!spaces || !composer::offersImageModel(spaces->imageProviders(), instanceId, model)) return false;
  Draft& kept = m_drafts[target];
  kept.modelSelection = QJsonObject{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}};
  kept.carried = false;
  save();
  publish();
  return true;
}

bool ComposerController::submitImages(const QString& target, const QString& text) {
  auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  const QString prompt = text.trimmed();
  if (!spaces || prompt.isEmpty() || spaces->generatingImage()) return true;
  if (!m_client->isReady() || !m_store->environmentOnline(m_client->environment())) {
    NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("warning"), QStringLiteral("Not connected: no image made"),
                                                               QStringLiteral("Reconnecting to the environment. Try again once it is connected."));
    return true;
  }
  // The prompt keeps its words until the image is made: a refusal or a failed
  // generation leaves them there to try again.
  spaces->generateImage(prompt, imageSelection(target), [self = QPointer(this), target, text](bool made) {
    if (!self) return;
    if (made && self->draft(target) == text) self->setText(target, QString(), 0);
    self->publish();
  });
  return true;
}

namespace {
// The words of an ask: they start with `@agent`.
bool isAsk(const QString& text) {
  static const QRegularExpression ask(QStringLiteral("^@agent(\\s|$)"), QRegularExpression::CaseInsensitiveOption);
  return ask.match(text.trimmed()).hasMatch();
}
}  // namespace

bool ComposerController::submitPage(const QString& target, const QString& text) {
  const QString trimmed = text.trimmed();
  const Draft kept = m_drafts.value(target);
  if (!isAsk(trimmed)) {
    if (!kept.attachments.isEmpty() || !kept.excerpts.isEmpty()) {
      toast(QStringLiteral("Not written"), QStringLiteral("Attachments go to an agent: start the prompt with @agent."));
    } else if (!trimmed.isEmpty()) {
      // The page writes the block, or picks a kind or a chart (SpacePage).
      m_bridge->sendToBricks(QStringLiteral("space.prompt.write"),
                             QVariantMap{{QStringLiteral("pageId"), m_pageId}, {QStringLiteral("text"), trimmed}});
    }
    return true;
  }
  auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  if (!spaces || m_launching.contains(target)) return true;
  if (!m_client->isReady() || !m_store->environmentOnline(m_client->environment())) {
    NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("warning"), QStringLiteral("Not connected: message not sent"),
                                                               QStringLiteral("Reconnecting to the environment. Try again once it is connected."));
    return true;
  }
  if (filesBlock(kept.attachments, QStringLiteral("sending"))) return true;
  // What a turn's message would carry; the MC takes `@agent` off the request.
  QJsonObject message{{QStringLiteral("text"), trimmed}};
  withExcerpts(message, kept.excerpts);
  QJsonArray attachments;
  for (const Attachment& attachment : kept.attachments) {
    if (attachment.file) continue;
    QJsonObject image{{QStringLiteral("type"), QStringLiteral("image")},
                      {QStringLiteral("name"), attachment.name},
                      {QStringLiteral("mimeType"), attachment.mimeType},
                      {QStringLiteral("sizeBytes"), attachment.sizeBytes},
                      {QStringLiteral("dataUrl"), attachment.dataUrl}};
    if (!attachment.source.isEmpty()) image.insert(QStringLiteral("source"), attachment.source);
    attachments.append(image);
  }
  for (const QJsonValue& file : fileRecords(kept.attachments)) attachments.append(file);
  const QJsonObject modelSelection = selection(target);
  QJsonObject ask{{QStringLiteral("request"), message.value(QLatin1String("text")).toString()},
                  {QStringLiteral("runtimeMode"),
                   composer::shownRuntimeMode(instanceOf(modelSelection), runtimeModeOf(target))},
                  {QStringLiteral("interactionMode"), interactionModeOf(target)}};
  if (const QString projectId = pageProject(); !projectId.isEmpty()) ask.insert(QStringLiteral("projectId"), projectId);
  if (!modelSelection.isEmpty()) ask.insert(QStringLiteral("modelSelection"), modelSelection);
  if (!attachments.isEmpty()) ask.insert(QStringLiteral("attachments"), attachments);
  if (message.contains(QLatin1String("context"))) ask.insert(QStringLiteral("context"), message.value(QLatin1String("context")));
  rememberModel(modelSelection);
  m_launching.insert(target);
  publish();
  QStringList sent;
  for (const Attachment& attachment : kept.attachments) sent.append(attachment.id);
  for (const Excerpt& excerpt : kept.excerpts) sent.append(excerpt.id);
  // The prompt keeps what it asked until the MC takes it: a refusal leaves
  // every word and attachment there to try again.
  spaces->askAgent(m_pageId, ask, [self = QPointer(this), target, text, sent](bool taken) {
    if (!self) return;
    self->m_launching.remove(target);
    if (taken) {
      Draft& draft = self->m_drafts[target];
      draft.attachments.removeIf([&sent](const Attachment& a) { return sent.contains(a.id); });
      draft.excerpts.removeIf([&sent](const Excerpt& e) { return sent.contains(e.id); });
      if (self->draft(target) == text) {
        self->setText(target, QString(), 0);
      } else {
        self->save();
      }
    }
    self->publish();
  });
  return true;
}

void ComposerController::startAsk() {
  const QString target = this->target();
  if (!onPage() || target.isEmpty()) return;
  const QString text = draft(target);
  if (!isAsk(text)) {
    const QString next = QStringLiteral("@agent ") + text;
    setText(target, next, int(next.size()));
  }
  m_bridge->sendToBricks(QStringLiteral("composer.focus"), QVariantMap());
}

bool ComposerController::running(const QString& target) const {
  const auto thread = m_store->thread(target);
  return thread && thread->activeRunId.has_value();
}

bool ComposerController::canSteerActive() const {
  if (!m_timeline) return true;
  // Sessions are keyed per instance and a provider switch keeps the old
  // one, so only the session that would take the steer counts: the active
  // run's instance, else the thread's current one. Neither known, every
  // session counts, as before.
  QString instance;
  if (const auto thread = m_store->thread(m_thread)) {
    if (thread->activeRunId) {
      const QJsonObject run = m_timeline->entities(QStringLiteral("run")).value(*thread->activeRunId);
      instance = run.value(QLatin1String("providerInstanceId")).toString();
      if (instance.isEmpty()) {
        instance = run.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")).toString();
      }
    }
    if (instance.isEmpty()) instance = thread->modelSelection.value(QLatin1String("instanceId")).toString();
  }
  for (const QJsonObject& session : m_timeline->entities(QStringLiteral("provider-session"))) {
    if (!instance.isEmpty() && session.value(QLatin1String("providerInstanceId")).toString() != instance) continue;
    const QJsonValue steers = session.value(QLatin1String("capabilities"))
                                  .toObject()
                                  .value(QLatin1String("turns"))
                                  .toObject()
                                  .value(QLatin1String("supportsActiveSteering"));
    if (steers.isBool() && !steers.toBool()) return false;
  }
  return true;
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
  const QString page = thread.isEmpty() && draftId.isEmpty() ? openPage() : QString();
  if (std::exchange(m_pageId, page) != page && !page.isEmpty()) askPageProject();
  // The images' prompt asks what can make an image each time they open.
  const QString images = thread.isEmpty() && draftId.isEmpty() && page.isEmpty() ? openImages() : QString();
  if (std::exchange(m_imagesSpace, images) != images && !images.isEmpty()) {
    NativeShell::of(this)->controller<SpaceController>()->handle(QStringLiteral("space.image.providers"), QVariantMap());
  }
  m_pageRunning = pageAgentRunning();
  TimelineModel* timeline = thread.isEmpty() ? nullptr : NativeShell::of(this)->controller<ThreadStore>()->timeline(thread);
  if (timeline != m_timeline) {
    disconnect(m_timelineConnection);
    disconnect(m_timelineStatus);
    disconnect(m_timelineSigned);
    m_timeline = timeline;
    m_sentAsked.clear();
    if (timeline) {
      // A queued message's image the queue or an edit shows has its address.
      m_timelineSigned = connect(timeline, &TimelineModel::attachmentSigned, this, [this](const QString& id, const QUrl& url) {
        if (!m_sentAsked.contains(id)) return;
        if (!url.isEmpty()) m_sentAsked.remove(id);
        publish();
      });
      m_timelineConnection = connect(timeline, &TimelineModel::turnChanged, this, &ComposerController::publish);
      // A thread's messages are known once its stream is live.
      m_timelineStatus = connect(timeline, &TimelineModel::statusChanged, this, &ComposerController::reconcileUnsent);
    }
  }
  reconcileUnsent();
  refreshPathSearch();
  publish();
}

void ComposerController::publish() {
  if (!m_active && !m_previewing) return;
  recoverQueuedEdits();
  const QVariantMap state = turnState();
  if (state != m_published) {
    m_published = state;
    m_bridge->publish(QStringLiteral("turn"), state);
  }
  const QVariant composerState = this->composerState(state);
  if (composerState != m_publishedComposer) {
    m_publishedComposer = composerState;
    m_bridge->publish(QStringLiteral("composer"), composerState);
    // A file ties the draft to its machine, so the machine picker stops
    // reading "Auto balance" (WorkspaceController::autoBalanced).
    const bool files = holdsFiles(target());
    if (files != m_heldFiles) {
      m_heldFiles = files;
      if (auto* workspace = NativeShell::of(this)->controller<WorkspaceController>()) workspace->publish();
    }
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
  // Other windows list the draft by what it holds, and mark a thread's row
  // while its composer holds something unsent.
  const QString edited = m_draftId.isEmpty() ? m_thread : m_draftId;
  if (!edited.isEmpty()) {
    for (const auto& window : NativeShell::of(this)->shell()->windows()) window->sidebar()->draftEdited(edited);
  }
}

// Whether the MC holds this thread's queue, with something listed to resume:
// the one fact resumeQueue needs, without rebuilding the whole turn state.
bool ComposerController::queueHeld() const {
  if (!m_draftId.isEmpty() || !m_store->thread(m_thread) || !m_timeline) return false;
  const composer::Queued queued =
      composer::queued(m_timeline->entities(QStringLiteral("run")).values(), m_timeline->entities(QStringLiteral("message")));
  return queued.shownHeld();
}

QVariantMap ComposerController::turnState() const {
  const auto thread = m_store->thread(m_thread);
  const bool isRunning = thread && thread->activeRunId.has_value();
  // The Space's images: an image being made is the only work.
  if (onImages()) {
    const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
    return {{QStringLiteral("threadKey"), QString()},
            {QStringLiteral("kind"), QStringLiteral("images")},
            {QStringLiteral("running"), false},
            {QStringLiteral("sending"), spaces && spaces->generatingImage()},
            {QStringLiteral("approvals"), QVariantList()},
            {QStringLiteral("questions"), QVariantList()},
            {QStringLiteral("plan"), QVariant()},
            {QStringLiteral("queue"), QVariantList()},
            {QStringLiteral("waiting"), QVariantList()},
            {QStringLiteral("queueHeld"), false},
            {QStringLiteral("queueResuming"), false}};
  }
  // A Space page: its agent's requests are asked in the agent's thread.
  if (onPage()) {
    return {{QStringLiteral("threadKey"), QString()},
            {QStringLiteral("kind"), QStringLiteral("page")},
            {QStringLiteral("running"), false},
            {QStringLiteral("sending"), m_launching.contains(pageKey(m_pageId))},
            {QStringLiteral("approvals"), QVariantList()},
            {QStringLiteral("questions"), QVariantList()},
            {QStringLiteral("plan"), QVariant()},
            {QStringLiteral("queue"), QVariantList()},
            {QStringLiteral("waiting"), QVariantList()},
            {QStringLiteral("queueHeld"), false},
            {QStringLiteral("queueResuming"), false}};
  }
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
            {QStringLiteral("queue"), QVariantList()},
            {QStringLiteral("waiting"), QVariantList()},
            {QStringLiteral("queueHeld"), false},
            {QStringLiteral("queueResuming"), false}};
  }
  QVariantMap state{{QStringLiteral("threadKey"), thread ? m_thread : QString()},
                    {QStringLiteral("kind"), QStringLiteral("thread")},
                    {QStringLiteral("running"), isRunning},
                    {QStringLiteral("approvals"), QVariantList()},
                    {QStringLiteral("questions"), QVariantList()},
                    {QStringLiteral("plan"), QVariant()},
                    {QStringLiteral("queue"), QVariantList()},
                    {QStringLiteral("waiting"), QVariantList()},
                    {QStringLiteral("queueHeld"), false},
                    {QStringLiteral("queueResuming"), m_kept.resuming.contains(m_thread)},
                    {QStringLiteral("outbox"), outboxState(m_thread)}};
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
    const QString title = approvalTitle(timeline::approvalKind(item));
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
      // A question with nothing the user could answer is not shown (the
      // removed client-runtime's parseQuestions).
      const QJsonObject raw = value.toObject();
      if (raw.value(QLatin1String("options")).toArray().isEmpty() && raw.value(QLatin1String("allowCustomAnswer")).toBool(true) == false) continue;
      QVariantMap one = raw.toVariantMap();
      one.insert(QStringLiteral("attachments"), shownAttachments(files.value(one.value(QStringLiteral("id")).toString())));
      asked.append(one);
    }
    if (asked.isEmpty()) continue;
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
      // `heading` is empty for a plan with none; `fileName` and
      // `workspaceRoot` start the dialog that saves it to the workspace.
      const QString title = planTitle(markdown);
      static const QRegularExpression headed(QStringLiteral("^\\s{0,3}#{1,6}\\s+\\S"), QRegularExpression::MultilineOption);
      state.insert(QStringLiteral("plan"), QVariantMap{{QStringLiteral("id"), str(latest, QLatin1String("id"))},
                                                       {QStringLiteral("title"), title},
                                                       {QStringLiteral("heading"), headed.match(markdown).hasMatch() ? title : QString()},
                                                       {QStringLiteral("markdown"), markdown},
                                                       {QStringLiteral("fileName"), PlanController::fileName(markdown)},
                                                       {QStringLiteral("workspaceRoot"), PlanController::workspaceRoot(m_store, m_thread)}});
    }
  }

  // The running turn's task list (ChatView's activeComposerTasksProgress):
  // the step in progress, else the next pending one, else the last; how many
  // are done; and each step with its status and how long it took. Not shown
  // while an approval or a question waits above the composer.
  state.insert(QStringLiteral("tasks"), QVariant());
  if (isRunning && approvals.isEmpty() && questions.isEmpty()) {
    const QString runId = *thread->activeRunId;
    QJsonObject list;
    for (const QJsonObject& plan : m_timeline->entities(QStringLiteral("plan"))) {
      if (str(plan, QLatin1String("kind")) == QLatin1String("todo_list") && str(plan, QLatin1String("runId")) == runId &&
          str(plan, QLatin1String("status")) != QLatin1String("superseded")) {
        list = plan;
      }
    }
    const QJsonArray steps = list.value(QLatin1String("steps")).toArray();
    if (!steps.isEmpty()) {
      QVariantList shown;
      QString current;
      QString next;
      int completed = 0;
      for (const QJsonValue& value : steps) {
        const QJsonObject step = value.toObject();
        const QString text = str(step, QLatin1String("text"));
        const QString status = str(step, QLatin1String("status"));
        if (status == QLatin1String("completed")) ++completed;
        if (status == QLatin1String("running") && current.isEmpty()) current = text;
        if (status == QLatin1String("pending") && next.isEmpty()) next = text;
        const QJsonValue duration = step.value(QLatin1String("durationMs"));
        shown.append(QVariantMap{
            {QStringLiteral("text"), text},
            {QStringLiteral("status"), status},
            {QStringLiteral("duration"), duration.isDouble() ? TimelineModel::durationText(qint64(duration.toDouble()))
                                         : status == QLatin1String("running") ? QStringLiteral("now")
                                                                              : QString()}});
      }
      if (current.isEmpty()) current = next;
      if (current.isEmpty()) current = str(steps.last().toObject(), QLatin1String("text"));
      state.insert(QStringLiteral("tasks"), QVariantMap{{QStringLiteral("current"), current},
                                                        {QStringLiteral("completed"), completed},
                                                        {QStringLiteral("total"), int(steps.size())},
                                                        {QStringLiteral("steps"), shown}});
    }
  }

  const composer::Queued queued = composer::queued(runs.values(), m_timeline->entities(QStringLiteral("message")));
  QVariantList queue;
  for (const QVariant& value : queued.queue) {
    QVariantMap entry = value.toMap();
    QVariantList attachments;
    for (const QVariant& attachment : entry.value(QStringLiteral("attachments")).toList()) {
      QVariantMap shown = attachment.toMap();
      if (shown.value(QStringLiteral("kind")) == QLatin1String("image"))
        shown.insert(QStringLiteral("url"), sentAddress(shown.value(QStringLiteral("id")).toString()));
      attachments.append(shown);
    }
    entry.insert(QStringLiteral("attachments"), attachments);
    entry.insert(QStringLiteral("shown"), quotedPlainly(entry.value(QStringLiteral("text")).toString()));
    entry.insert(QStringLiteral("pending"), false);
    queue.append(entry);
  }
  // A follow-up on its way to the MC is listed at the end as being saved,
  // with nothing to do to it until the MC has it.
  const QHash<QString, QJsonObject> messages = m_timeline->entities(QStringLiteral("message"));
  for (const Send& send : m_queues.value(m_thread)) {
    for (const QJsonObject& command : send.commands) {
      if (str(command, QLatin1String("type")) != QLatin1String("message.dispatch") ||
          str(command.value(QLatin1String("dispatchMode")).toObject(), QLatin1String("type")) != QLatin1String("queue_after_active") ||
          messages.contains(str(command, QLatin1String("messageId")))) {
        continue;
      }
      QVariantList attachments;
      for (const Attachment& attachment : send.attachments) {
        attachments.append(QVariantMap{{QStringLiteral("id"), attachment.id},
                                       {QStringLiteral("name"), attachment.name},
                                       {QStringLiteral("mimeType"), attachment.mimeType},
                                       {QStringLiteral("kind"), attachment.file ? QStringLiteral("file") : QStringLiteral("image")}});
      }
      queue.append(QVariantMap{{QStringLiteral("runId"), QString()},
                               {QStringLiteral("messageId"), str(command, QLatin1String("messageId"))},
                               {QStringLiteral("text"), str(command, QLatin1String("text"))},
                               {QStringLiteral("shown"), quotedPlainly(str(command, QLatin1String("text")))},
                               {QStringLiteral("attachments"), attachments},
                               {QStringLiteral("pending"), true}});
    }
  }
  state.insert(QStringLiteral("queue"), queue);
  // A queue action waits for the MC's answer before another can be taken.
  state.insert(QStringLiteral("queueBusy"), m_queueBusy.contains(m_thread));
  // Why the queued messages cannot be edited now, empty when they can.
  state.insert(QStringLiteral("queueEditBlocked"), questions.isEmpty() ? QString() : QStringLiteral("Answer the question to edit queued messages"));
  state.insert(QStringLiteral("waiting"), queued.waiting);
  // Held with nothing listed shows no card, so it offers no resume either. A queued run
  // comes with its message in the one transaction that queues it (the MC's `queue_run`),
  // so a run without its message on a live stream is the moment before the two events
  // are read, not a state that lasts; an empty card in that moment would only flash.
  state.insert(QStringLiteral("queueHeld"), queued.shownHeld());
  return state;
}

QString ComposerController::sentAddress(const QString& id) const {
  if (!m_timeline || id.isEmpty()) return {};
  if (const QUrl url = m_timeline->attachmentAddress(id); !url.isEmpty()) return url.toString();
  if (!m_sentAsked.contains(id)) {
    m_sentAsked.insert(id);
    // Not from inside building the state: the answer publishes again.
    QMetaObject::invokeMethod(
        m_timeline, [timeline = m_timeline, id] { if (timeline) timeline->loadAttachment(id); }, Qt::QueuedConnection);
  }
  return {};
}

QVariantList ComposerController::shownSent() const {
  QVariantList shown;
  const auto edit = m_queuedEdits.constFind(target());
  if (edit == m_queuedEdits.cend()) return shown;
  for (const QJsonValue& value : edit->sent) {
    const QJsonObject attachment = value.toObject();
    const bool image = str(attachment, QLatin1String("type")) == QLatin1String("image");
    const QString id = str(attachment, QLatin1String("id"));
    QVariantMap entry{{QStringLiteral("id"), id},
                      {QStringLiteral("name"), str(attachment, QLatin1String("name"))},
                      {QStringLiteral("mimeType"), str(attachment, QLatin1String("mimeType"))},
                      {QStringLiteral("kind"), image ? QStringLiteral("image") : QStringLiteral("file")},
                      {QStringLiteral("status"), QString()},
                      {QStringLiteral("error"), QString()},
                      {QStringLiteral("source"), QVariant::fromValue(nullptr)},
                      {QStringLiteral("sent"), true}};
    if (image) entry.insert(QStringLiteral("preview"), sentAddress(id));
    shown.append(entry);
  }
  return shown;
}

// --- The draft and what the composer shows -------------------------------------

QString ComposerController::target() const {
  if (onPage()) return pageKey(m_pageId);
  if (onImages()) return imagesKey(m_imagesSpace);
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
  // What was pasted or captured; a draft restored from disk has only the file where it was picked from.
  QByteArray bytes = found->content.isEmpty() ? found->captured : found->content;
  bool whole = found->content.isEmpty() ? found->capturedWhole : true;
  if (bytes.isEmpty() && !found->path.isEmpty()) {
    QFile file(found->path);
    if (file.open(QIODevice::ReadOnly)) {
      bytes = file.read(1024 * 1024);
      whole = file.atEnd();
    }
  }
  // A player or document view reads the whole file, not this preview's first part.
  if (!found->path.isEmpty()) preview.insert(QStringLiteral("path"), found->path);
  if (whole) preview.insert(QStringLiteral("bytes"), bytes);
  bytes.truncate(1024 * 1024);
  if (!bytes.contains('\0')) {
    preview.insert(QStringLiteral("text"), QString::fromUtf8(bytes));
    preview.insert(QStringLiteral("truncated"), !whole);
  }
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
  const QJsonObject config = NativeShell::of(this)->controller<WorkspaceController>()->environmentConfig();
  m_usageLimits.insert(target, composer::usageLimitsReport(instance->instanceId, config.value(QLatin1String("providers")).toArray(),
                                                           config.value(QLatin1String("usageLimitSources")).toArray()));
  setText(target, QString(), 0);
  publish();
  return true;
}

// An existing thread takes a new access mode at once, as the TUI's does: a turn
// waiting on approvals blocks the composer, so the next send may never come, and
// the provider can apply it to the running turn. The draft shows it meanwhile, and
// goes once the MC holds it; a refused change goes too, so the picker shows the
// mode the thread really has. A pick back to the thread's mode still goes while
// another is on its way, which would otherwise land after it.
// The user's own change, made now: it names no revision, so none made
// elsewhere refuses it, and the model pick stands past it.
void ComposerController::setThreadMode(const QString& target, ModeKind kind, const QString& mode) {
  const auto thread = m_store->thread(target);
  const bool runtime = kind == ModeKind::Runtime;
  QHash<QString, SettingMode>& settings = settingModes(kind);
  // A pick back to the thread's mode still goes while another is on its way.
  if (!thread || ((runtime ? thread->runtimeMode : thread->interactionMode) == mode && !settings.contains(target))) return;
  settings.insert(target, SettingMode{mode});
  const QJsonObject command{
      {QStringLiteral("type"), runtime ? QStringLiteral("thread.runtime-mode.set") : QStringLiteral("thread.interaction-mode.set")},
      {QStringLiteral("threadId"), thread->id},
      {runtime ? QStringLiteral("runtimeMode") : QStringLiteral("interactionMode"), mode},
  };
  const auto own = ownSent(target);
  m_client->dispatchCommand(this, thread->environmentId, command,
                            [this, target, kind, mode, own](const QJsonValue& result, const std::optional<QString>& error) {
                              ownAnswered(target, own, result, !error);
                              QHash<QString, SettingMode>& settings = settingModes(kind);
                              if (settings.value(target).mode != mode) return;
                              if (!error) {
                                const QJsonObject shell = result.toObject().value(QLatin1String("shell")).toObject();
                                SettingMode& setting = settings[target];
                                setting.accepted = true;
                                setting.mc = shell.value(QLatin1String("mc")).toString();
                                setting.epoch = shell.value(QLatin1String("epoch")).toString();
                                setting.rev = qint64(shell.value(QLatin1String("rev")).toDouble());
                                return settleModes();
                              }
                              settings.remove(target);
                              const bool runtime = kind == ModeKind::Runtime;
                              toast(runtime ? QStringLiteral("Failed to change the thread's access.")
                                            : QStringLiteral("Failed to change the thread's mode."),
                                    *error);
                              QString& shown = runtime ? m_drafts[target].runtimeMode : m_drafts[target].interactionMode;
                              if (shown != mode) return;
                              shown.clear();
                              save();
                              publish();
                            });
}

// Drops the drafts of mode changes the threads' rows now hold, whatever mode
// they show: the row and the MC's answer travel apart, and another device's
// change can land with ours or after it. A started thread's draft shows a
// mode of its own only while a change to it is on its way.
void ComposerController::settleModes() {
  bool changed = false;
  for (const ModeKind kind : {ModeKind::Runtime, ModeKind::Interaction}) {
    QHash<QString, SettingMode>& settings = settingModes(kind);
    for (auto it = settings.begin(); it != settings.end();) {
      // From an MC that names no version, the row is as good as it gets.
      const bool landed = it->accepted && (it->epoch.isEmpty() || m_store->reached(it->mc, it->epoch, it->rev));
      if (m_store->thread(it.key()) && !landed) {
        ++it;
        continue;
      }
      it = settings.erase(it);
    }
  }
  for (auto it = m_drafts.begin(); it != m_drafts.end(); ++it) {
    if ((it->runtimeMode.isEmpty() && it->interactionMode.isEmpty()) || !m_store->thread(it.key())) continue;
    if (!it->runtimeMode.isEmpty() && !m_settingMode.contains(it.key())) {
      it->runtimeMode.clear();
      changed = true;
    }
    if (!it->interactionMode.isEmpty() && !m_settingInteraction.contains(it.key())) {
      it->interactionMode.clear();
      changed = true;
    }
  }
  if (!changed) return;
  save();
  publish();
}

// A new thread's mode is its draft's; a started thread's is set now.
void ComposerController::setInteractionMode(const QString& target, const QString& mode) {
  if (mode != QLatin1String("plan") && mode != QLatin1String("default")) return;
  if (mode == QLatin1String("plan") && !planModeOn(instanceOf(selection(target)))) return;
  if (mode == interactionModeOf(target)) return;
  m_drafts[target].interactionMode = mode;
  m_drafts[target].carried = false;
  save();
  publish();
  setThreadMode(target, ModeKind::Interaction, mode);
}

void ComposerController::rememberModel(const QJsonObject& selection) {
  const QString instanceId = selection.value(QLatin1String("instanceId")).toString();
  if (!instanceId.isEmpty() && selection.contains(QLatin1String("options"))) {
    m_kept.modelOptions.insert(instanceId + u'\n' + selection.value(QLatin1String("model")).toString(),
                               selection.value(QLatin1String("options")).toArray());
  }
  if (instanceId.isEmpty() || (m_kept.lastInstance == instanceId && m_kept.lastModels.value(instanceId) == selection)) return;
  m_kept.lastInstance = instanceId;
  m_kept.lastModels.insert(instanceId, selection);
}

// A model its session cannot switch to says why instead; another provider
// takes the thread over on the next send.
bool ComposerController::selectModel(const QString& target, const QString& instanceId, const QString& model) {
  if (instanceId.isEmpty() || model.isEmpty()) return false;
  // Only what the picker offers: a ready provider's own models.
  const composer::Instance* next = composer::find(m_catalogue, instanceId);
  if (!next || !next->ready() || composer::findModel(*next, model).isEmpty()) return false;
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
  QJsonObject chosen{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}};
  // Options belong to the model they were picked with: this model's own come back.
  if (const auto remembered = m_kept.modelOptions.constFind(instanceId + u'\n' + model);
      remembered != m_kept.modelOptions.cend()) {
    chosen.insert(QStringLiteral("options"), *remembered);
  } else {
    // Nothing given to it on this device: the options the thread (or the
    // project's default, for a draft) already holds for this model, or the
    // ones the composer shows for it now, stay with it.
    for (const QJsonObject& held : {selection(target), baseSelection(target)}) {
      if (held.value(QLatin1String("instanceId")) == instanceId && held.value(QLatin1String("model")) == model &&
          held.contains(QLatin1String("options"))) {
        chosen.insert(QStringLiteral("options"), held.value(QLatin1String("options")));
        break;
      }
    }
  }
  notePick(target);
  kept.modelSelection = chosen;
  kept.multipleModels.reset();
  kept.carried = false;
  forgetTakenPicks();
  NativeShell::of(this)->controller<WorkspaceController>()->publish();
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
  // A choice the provider takes from the prompt (Claude's ultrathink) is only
  // typed, never picked; any other choice takes a typed one out.
  static const QRegularExpression prefix(QStringLiteral("^Ultrathink:\\s*"));
  for (const QJsonValue& entry : descriptors) {
    const QJsonObject descriptor = entry.toObject();
    const QJsonArray injected = descriptor.value(QLatin1String("promptInjectedValues")).toArray();
    if (str(descriptor, QLatin1String("id")) != id || injected.isEmpty()) continue;
    const QString text = draft(target).trimmed();
    if (effortLocked(descriptor, text) || injected.contains(QJsonValue::fromVariant(value))) return false;
    if (prefix.match(text).hasMatch()) {
      const QString next = QString(text).remove(prefix);
      setText(target, next, int(next.size()));
    }
  }
  const std::optional<QJsonArray> options = composer::applyOption(descriptors, id, value);
  if (!options) return false;
  chosen.insert(QStringLiteral("options"), *options);
  m_kept.modelOptions.insert(chosen.value(QLatin1String("instanceId")).toString() + u'\n' +
                                 chosen.value(QLatin1String("model")).toString(),
                             *options);
  notePick(target);
  m_drafts[target].modelSelection = chosen;
  m_drafts[target].carried = false;
  forgetTakenPicks();
  save();
  publish();
  return true;
}

// The effort one level up or down, as the picker would set it, without
// opening it (composer.increaseEffort / decreaseEffort). It stands down
// while something else owns the composer: an approval or question waiting,
// a queued message being edited, or the prompt's own ultrathink.
bool ComposerController::stepEffort(const QString& target, int direction) {
  const QJsonObject chosen = selection(target);
  const composer::Instance* instance = instanceOf(chosen);
  if (!instance || !instance->ready()) return false;
  if (m_queuedEdits.contains(target)) return false;
  if (target == m_thread) {
    const QVariantMap turn = turnState();
    if (!turn.value(QStringLiteral("approvals")).toList().isEmpty() || !turn.value(QStringLiteral("questions")).toList().isEmpty()) return false;
  }
  const QJsonArray descriptors =
      composer::descriptors(composer::findModel(*instance, chosen.value(QLatin1String("model")).toString()),
                            chosen.value(QLatin1String("options")).toArray(), planModeOn(instance));
  const qsizetype effort = composer::effortIndex(descriptors);
  if (effort < 0) return false;
  QJsonObject descriptor = descriptors.at(effort).toObject();
  const QString text = draft(target);
  if (effortLocked(descriptor, text)) return false;
  // The step starts from the effort shown: Ultrathink while the prompt
  // carries its prefix, though the saved level is underneath.
  const QJsonArray injected = descriptor.value(QLatin1String("promptInjectedValues")).toArray();
  if (!injected.isEmpty() && text.trimmed().startsWith(kUltrathinkPrefix.trimmed())) descriptor.insert(QStringLiteral("currentValue"), injected.first());
  const std::optional<QString> next = composer::steppedChoice(descriptor, direction);
  return next && setOption(target, str(descriptor, QLatin1String("id")), *next);
}

// An effort the prompt asks for in its own words is the prompt's to change.
bool ComposerController::effortLocked(const QJsonObject& descriptor, const QString& text) {
  return !descriptor.value(QLatin1String("promptInjectedValues")).toArray().isEmpty() && composer::ultrathinkInWords(text);
}

// Puts the suggestion in the trigger's place; the composer's own commands act instead.
bool ComposerController::selectSuggestion(const QString& target, const QString& id) {
  const QString text = draft(target);
  const std::optional<composer::Trigger> trigger = triggerOf(target);
  if (!trigger || m_drafts.value(target).dismissed) return false;
  const QList<composer::Suggestion> offered = suggestions(target, trigger);
  const auto chosen = std::find_if(offered.cbegin(), offered.cend(), [&](const composer::Suggestion& item) { return item.id == id; });
  if (chosen == offered.cend()) return false;
  QString replacement = chosen->replacement;
  if (chosen->kind == QLatin1String("thread")) {
    // The draft carries the thread as context; the text names it with the
    // record's link. Choosing it again reuses the same reference.
    const QString named = id.mid(QStringLiteral("thread:").size());
    const qsizetype split = named.indexOf(u':');
    const QString environmentId = named.left(split);
    const QString threadId = named.mid(split + 1);
    QList<Excerpt>& excerpts = m_drafts[target].excerpts;
    const auto held = std::find_if(excerpts.cbegin(), excerpts.cend(), [&](const Excerpt& context) {
      return context.thread.value(QLatin1String("environmentId")).toString() == environmentId &&
             context.thread.value(QLatin1String("threadId")).toString() == threadId;
    });
    QString excerptId;
    if (held != excerpts.cend()) {
      excerptId = held->id;
    } else {
      excerptId = newId();
      Excerpt excerpt;
      excerpt.id = excerptId;
      excerpt.thread = QJsonObject{{QStringLiteral("environmentId"), environmentId},
                                   {QStringLiteral("threadId"), threadId},
                                   {QStringLiteral("title"), chosen->label}};
      excerpts.append(excerpt);
    }
    QString label = chosen->label;
    label.replace(u'[', u' ').replace(u']', u' ');
    replacement = QStringLiteral("[@%1](hal-c2-context://v1/thread/thread_%2) ").arg(label.trimmed(), excerptId);
  }
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
  if (trigger->kind == QLatin1String("path")) {
    QList<composer::Suggestion> items;
    if (m_paths.target == target && m_paths.query == trigger->query) items = composer::pathItems(m_paths.entries);
    // Threads can be carried as context from the same menu, ranked by title.
    QList<std::pair<int, composer::Suggestion>> scored;
    const QString query = trigger->query.toLower();
    for (const sidebar::Thread& thread : m_store->threads()) {
      if (thread.archivedAt || thread.title.isEmpty()) continue;
      if (thread.environmentId + QLatin1Char(':') + thread.id == target) continue;
      const std::optional<int> score =
          query.isEmpty() ? std::optional<int>(0)
                          : composer::scoreQueryMatch(thread.title.toLower(), query, 0, 2, 4, 6, 100);
      if (!score) continue;
      scored.append({*score,
                     {QStringLiteral("thread:%1:%2").arg(thread.environmentId, thread.id), QStringLiteral("thread"),
                      thread.title, QStringLiteral("Thread"), QStringLiteral("@%1 ").arg(thread.title)}});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    for (const auto& [score, item] : scored.mid(0, 10)) items.append(item);
    return items;
  }
  return {};
}

// The @ menu asks the MC's workspace search (the Files tab's) for the
// route's checkout; the answer counts only while it is still the question.
void ComposerController::searchPaths(const QString& target) {
  const std::optional<composer::Trigger> trigger = triggerOf(target);
  if (!trigger || trigger->kind != QLatin1String("path") || trigger->query.isEmpty()) return;
  if (m_paths.target == target && m_paths.query == trigger->query) return;
  if (!canSearchPaths(target)) return;
  const auto [environmentId, cwd] = searchPlace(target);
  m_paths = {target, trigger->query, environmentId, cwd, false, false, {}, m_paths.request + 1};
  const int request = m_paths.request;
  WorkspaceFiles::searchEntries(m_client, this, environmentId, cwd, trigger->query, 80,
                                [this, request](const QList<FileTreeModel::Entry>& entries, bool,
                                                const std::optional<QString>& error) {
                                  if (request != m_paths.request) return;
                                  m_paths.done = true;
                                  m_paths.failed = error.has_value();
                                  for (const FileTreeModel::Entry& entry : entries) {
                                    m_paths.entries.append({entry.path, entry.directory});
                                  }
                                  publish();
                                });
}

// Where `target`'s @ words are searched: the route's own checkout, or the
// root of the project a page's ask runs in; empty when it is neither.
std::pair<QString, QString> ComposerController::searchPlace(const QString& target) const {
  if (onPage()) {
    if (target != pageKey(m_pageId)) return {};
    const QString environmentId = m_client->environment();
    return {environmentId, m_store->projectRow(environmentId, pageProject()).value(QLatin1String("workspaceRoot")).toString()};
  }
  const auto& place = NativeShell::of(this)->controller<WorkspaceController>()->place();
  if (!place || (place->draftId.isEmpty() ? place->threadKey() : place->draftId) != target) return {};
  return {place->environmentId, place->cwd()};
}

// Whether that place is known and its environment reachable.
bool ComposerController::canSearchPaths(const QString& target) const {
  const auto [environmentId, cwd] = searchPlace(target);
  return m_client->isReady() && !cwd.isEmpty() && m_store->environmentOnline(environmentId);
}

// The trigger at the draft's caret. On a page `/` picks a kind of block
// (SpacePage's menu) and the leading `@agent` is the ask, not a file.
std::optional<composer::Trigger> ComposerController::triggerOf(const QString& target) const {
  const QString text = draft(target);
  std::optional<composer::Trigger> trigger = composer::trigger(text, m_drafts.value(target).cursor);
  if (trigger && trigger->kind == QLatin1String("skill") && !composer::opensSkillMenu(instanceOf(selection(target)), trigger->query)) {
    return std::nullopt;
  }
  // A slash word in a sentence that starts no name is prose: no menu, so
  // Enter sends it.
  if (trigger && trigger->midLine && suggestions(target, trigger).isEmpty()) return std::nullopt;
  if (!trigger || !target.startsWith(pageKey({}))) return trigger;
  if (trigger->kind == QLatin1String("slash-command")) return std::nullopt;
  const bool first = text.left(trigger->start).trimmed().isEmpty();
  if (trigger->kind == QLatin1String("path") && first && QStringLiteral("agent").startsWith(trigger->query, Qt::CaseInsensitive)) {
    return std::nullopt;
  }
  return trigger;
}

// A search the environment took down with it (unanswered, or failed) is
// forgotten, as is one of a checkout the route has left, so the same word is
// asked again once it can be.
void ComposerController::refreshPathSearch() {
  const QString target = this->target();
  if (target.isEmpty()) return;
  bool stale = (!m_paths.done || m_paths.failed) && !canSearchPaths(m_paths.target);
  if (m_paths.target == target && canSearchPaths(target)) {
    const auto [environmentId, cwd] = searchPlace(target);
    stale = stale || m_paths.environmentId != environmentId || m_paths.cwd != cwd;
  }
  if (stale && !m_paths.query.isEmpty()) m_paths = {{}, {}, {}, {}, false, false, {}, m_paths.request + 1};
  searchPaths(target);
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
  const auto firstReady = [this]() -> QJsonObject {
    const auto ready = std::find_if(m_catalogue.cbegin(), m_catalogue.cend(),
                                    [](const composer::Instance& instance) { return instance.ready(); });
    if (ready == m_catalogue.cend()) return {};
    QJsonObject next{{QStringLiteral("instanceId"), ready->instanceId},
                     {QStringLiteral("model"), composer::defaultModel(*ready)}};
    if (const auto remembered = m_kept.modelOptions.constFind(
            ready->instanceId + u'\n' + next.value(QLatin1String("model")).toString());
        remembered != m_kept.modelOptions.cend()) {
      next.insert(QStringLiteral("options"), *remembered);
    }
    return next;
  };
  const QString instanceId = chosen.value(QLatin1String("instanceId")).toString();
  const bool isThread = bool(m_store->thread(target));
  // A started thread shows what it holds, unavailable as it may be: what a
  // send with no pick runs on is the thread's, never one made up here.
  if (instanceId.isEmpty()) return isThread ? chosen : firstReady();
  const QString model = chosen.value(QLatin1String("model")).toString();
  const composer::Instance* instance = instanceOf(chosen);
  if (instance && instance->ready()) {
    if (model.isEmpty()) {
      chosen.insert(QStringLiteral("model"), composer::defaultModel(*instance));
    } else if (!isThread && composer::findModel(*instance, model).isEmpty()) {
      // A draft still naming the model picked on another instance, whose own
      // catalogue has no such model: this instance's default, with the
      // options last given to it here.
      const QString own = composer::defaultModel(*instance);
      chosen.insert(QStringLiteral("model"), own);
      chosen.remove(QStringLiteral("options"));
      if (const auto remembered = m_kept.modelOptions.constFind(instanceId + u'\n' + own);
          remembered != m_kept.modelOptions.cend()) {
        chosen.insert(QStringLiteral("options"), *remembered);
      }
    }
    return chosen;
  }
  if (isThread) return chosen;
  // A draft's account cannot run a turn: another account of the same driver
  // that lists the model takes over, with the options last given to the model
  // there, or the ones picked for it here when it has none of its own.
  if (instance) {
    for (const composer::Instance& candidate : m_catalogue) {
      if (!candidate.ready() || candidate.driver != instance->driver || candidate.instanceId == instanceId) continue;
      const QString slug = composer::fallbackModelSlug(candidate, model);
      if (slug.isEmpty()) continue;
      chosen.insert(QStringLiteral("instanceId"), candidate.instanceId);
      chosen.insert(QStringLiteral("model"), slug);
      if (const auto remembered = m_kept.modelOptions.constFind(candidate.instanceId + u'\n' + slug);
          remembered != m_kept.modelOptions.cend()) {
        chosen.insert(QStringLiteral("options"), *remembered);
      }
      return chosen;
    }
  }
  // A draft or a page's ask starts on the first provider that can run instead.
  return firstReady();
}

bool ComposerController::planModeOn(const composer::Instance* instance) const {
  return instance && instance->showInteractionModeToggle && setting(QStringLiteral("planModeEnabled")).toBool();
}

QString ComposerController::runtimeModeOf(const QString& target) const {
  if (const QString mode = m_drafts.value(target).runtimeMode; !mode.isEmpty()) return mode;
  if (const auto thread = m_store->thread(target); thread && !thread->runtimeMode.isEmpty()) return thread->runtimeMode;
  // A new thread, or a page's ask: its project's default permissions, else
  // the default for new threads (Settings → Project defaults).
  if (onPage() && target == pageKey(m_pageId)) return newThreadRuntimeMode(m_client->environment(), pageProject());
  if (const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(target)) {
    return newThreadRuntimeMode(kept->environmentId, kept->projectId);
  }
  return QStringLiteral("full-access");
}

// The permissions a new thread of the target's project starts in: the
// composer names a thread's own only when they differ from these.
QString ComposerController::defaultRuntimeModeOf(const QString& target) const {
  if (onPage() && target == pageKey(m_pageId)) return newThreadRuntimeMode(m_client->environment(), pageProject());
  if (const auto thread = m_store->thread(target)) return newThreadRuntimeMode(thread->environmentId, thread->projectId);
  if (const auto kept = NativeShell::of(this)->controller<DraftController>()->draft(target)) {
    return newThreadRuntimeMode(kept->environmentId, kept->projectId);
  }
  return newThreadRuntimeMode(QString(), QString());
}

// The project's MC names what a new thread there starts in; from an MC that
// does not, the settings this client's MC holds.
QString ComposerController::newThreadRuntimeMode(const QString& environmentId, const QString& projectId) const {
  if (!projectId.isEmpty()) {
    const QString named = m_store->projectRow(environmentId, projectId).value(QLatin1String("newThreadRuntimeMode")).toString();
    if (!named.isEmpty()) return named;
  }
  if (const auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    for (const QString& path : {QStringLiteral("projectSettingsOverrides.%1.defaultRuntimeMode").arg(projectId),
                                QStringLiteral("defaultRuntimeMode")}) {
      if (const QString mode = settings->value(path).toString(); !mode.isEmpty()) return mode;
    }
  }
  return QStringLiteral("full-access");
}

// The mode a send uses: plan only while plan mode is on.
QString ComposerController::interactionModeOf(const QString& target) const {
  if (!planModeOn(instanceOf(selection(target)))) return QStringLiteral("default");
  if (const QString mode = m_drafts.value(target).interactionMode; !mode.isEmpty()) return mode;
  if (const auto thread = m_store->thread(target); thread && !thread->interactionMode.isEmpty()) {
    return thread->interactionMode;
  }
  return QStringLiteral("default");
}

// ShellComposerState.
QVariant ComposerController::composerState(const QVariantMap& turn) const {
  const QString target = this->target();
  if (target.isEmpty()) return QVariant::fromValue(nullptr);
  if (onImages()) return imagesComposerState();
  const bool isDraft = !m_draftId.isEmpty();
  const auto thread = m_store->thread(target);
  const Draft kept = m_drafts.value(target);
  const QString text = draft(target);
  const int cursor = std::clamp(kept.cursor, 0, int(text.size()));
  const QJsonObject chosen = selection(target);
  const composer::Instance* instance = instanceOf(chosen);
  const bool planOn = planModeOn(instance);

  const std::optional<composer::Trigger> trigger = kept.dismissed ? std::nullopt : triggerOf(target);
  QVariantList suggestionList;
  for (const composer::Suggestion& item : suggestions(target, trigger)) {
    suggestionList.append(QVariantMap{{QStringLiteral("id"), item.id},
                                      {QStringLiteral("kind"), item.kind},
                                      {QStringLiteral("label"), item.label},
                                      {QStringLiteral("description"), item.description}});
  }
  QVariant emptyText = QVariant::fromValue(nullptr);
  if (trigger && suggestionList.isEmpty()) {
    // A path search says it is searching until it has answered, and that it
    // could not search when it cannot or failed. A bare `@` is not searched,
    // so it says nothing matches at once, as the web's menu did.
    const bool searched = trigger->kind == QLatin1String("path") && !trigger->query.isEmpty();
    const bool answered = m_paths.target == target && m_paths.query == trigger->query && m_paths.done;
    if (searched && (answered ? m_paths.failed : !canSearchPaths(target))) {
      emptyText = composer::pathSearchUnavailableText();
    } else if (searched && !answered) {
      emptyText = composer::pathSearchingText();
    } else if (!composer::emptyText(trigger->kind).isEmpty()) {
      emptyText = composer::emptyText(trigger->kind);
    }
  }

  const QVariantList attachments = shownSent() + shownAttachments(kept.attachments, true);
  QVariantList terminalContexts;
  QVariantList reviewComments;
  QVariantList threadContexts;
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
    if (!context.thread.isEmpty()) {
      threadContexts.append(QVariantMap{{QStringLiteral("id"), context.id},
                                        {QStringLiteral("label"), context.thread.value(QLatin1String("title")).toString()},
                                        {QStringLiteral("threadId"), context.thread.value(QLatin1String("threadId")).toString()},
                                        {QStringLiteral("environmentId"), context.thread.value(QLatin1String("environmentId")).toString()}});
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
  const bool page = onPage();
  if (page) environmentId = m_client->environment();
  // A thread's message with no connection waits in the phone's outbox.
  const bool waitsForConnection = m_waitsOffline && !isDraft && !page && thread && (!m_client->isReady() || !m_store->threadOnline(target));
  const bool offline = !m_store->environmentOnline(environmentId) && !waitsForConnection;
  // A page writes blocks with no provider; an ask with none is refused by the MC.
  const bool noProvider = !page && std::none_of(m_catalogue.cbegin(), m_catalogue.cend(),
                                                [](const composer::Instance& entry) { return entry.ready(); });
  const bool busy = (isDraft || page) && m_launching.contains(target);
  const bool hasContent = !text.trimmed().isEmpty() || !attachments.isEmpty() || !kept.excerpts.isEmpty();
  const bool isRunning = page ? m_pageRunning : thread && thread->activeRunId.has_value();

  QString placeholder = QStringLiteral("Ask anything, @tag files/folders, $use skills, or / for commands");
  if (page) {
    placeholder = QStringLiteral("Write, type / for a kind of block, or @agent to ask an agent");
  } else if (!approvals.isEmpty()) {
    placeholder = QStringLiteral("Resolve this approval request to continue");
  } else if (showPlanFollowUp) {
    placeholder = QStringLiteral("Add feedback to refine the plan, or leave this blank to implement it");
  } else if (noProvider) {
    placeholder = QStringLiteral("Enable a provider in Settings to send a message");
  } else if (offline) {
    placeholder = QStringLiteral("Ask for changes, send follow-ups, or attach images");
  }
  // A started thread whose own provider cannot run here sends nothing until
  // the user picks one: the composer never swaps it for another. One the
  // catalogue cannot judge yet (none listed, or none named) is the MC's to run.
  const bool needsPick = thread && !isDraft && !page && !kept.modelSelection && !thread->modelSelection.isEmpty() &&
                         !m_catalogue.isEmpty() && (!instance || !instance->ready());
  QVariant disabledReason = QVariant::fromValue(nullptr);
  if (offline) {
    disabledReason = QStringLiteral("Not connected");
  } else if (noProvider) {
    disabledReason = QStringLiteral("No provider available");
  } else if (needsPick) {
    disabledReason = QStringLiteral("Choose a model to send");
  }

  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  const QString selectedInstance = chosen.value(QLatin1String("instanceId")).toString();
  const QString selectedModel = chosen.value(QLatin1String("model")).toString();
  const QJsonArray described =
      instance ? composer::descriptors(composer::findModel(*instance, selectedModel), chosen.value(QLatin1String("options")).toArray(), planOn)
               : QJsonArray();
  const QVariantList options = composer::shellOptions(described);
  // An effort the prompt asks for (Ultrathink) is only typed: the choices
  // leave it out unless the prompt asks for it, when it is the one shown.
  // Asked for in the prompt's own words, it cannot be changed until they go.
  QVariantList shownOptions = options;
  const bool asked = text.trimmed().startsWith(kUltrathinkPrefix.trimmed()) || composer::ultrathinkInWords(text);
  for (qsizetype i = 0; i < described.size() && i < shownOptions.size(); ++i) {
    const QJsonArray injected = described.at(i).toObject().value(QLatin1String("promptInjectedValues")).toArray();
    if (injected.isEmpty()) continue;
    QVariantMap option = shownOptions.at(i).toMap();
    if (asked) option.insert(QStringLiteral("value"), injected.first().toVariant());
    QVariantList choices;
    for (const QVariant& choice : option.value(QStringLiteral("choices")).toList()) {
      const QString choiceId = choice.toMap().value(QStringLiteral("id")).toString();
      if (!injected.contains(QJsonValue(choiceId)) || (asked && choiceId == injected.first().toString())) choices.append(choice);
    }
    option.insert(QStringLiteral("choices"), choices);
    if (effortLocked(described.at(i).toObject(), text)) {
      option.insert(QStringLiteral("lockedReason"), QStringLiteral("Your prompt contains \"ultrathink\" in the text. Remove it to change this option."));
    }
    shownOptions[i] = option;
  }
  // The effort is marked, with its bars for the composer to draw when
  // Appearance asks for them.
  if (const qsizetype at = composer::effortIndex(described); at >= 0 && at < shownOptions.size()) {
    QVariantMap option = shownOptions.at(at).toMap();
    option.insert(QStringLiteral("effort"), true);
    const QVariantMap bars = composer::effortBars(described.at(at).toObject(), option.value(QStringLiteral("value")).toString());
    if (!bars.isEmpty()) option.insert(QStringLiteral("bars"), bars);
    shownOptions[at] = option;
  }
  const auto orNull = [](const QString& value) { return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value); };
  // A page's ask: the project it runs in and the ones it could.
  QVariant project = QVariant::fromValue(nullptr);
  QVariantList projects;
  if (page) {
    const QString projectId = pageProject();
    for (const QJsonObject& row : m_store->projectRows(environmentId)) {
      const QVariantMap entry{{QStringLiteral("id"), row.value(QLatin1String("id")).toString()},
                              {QStringLiteral("title"), row.value(QLatin1String("title")).toString()}};
      if (entry.value(QStringLiteral("id")).toString() == projectId) project = entry;
      projects.append(entry);
    }
  }
  QVariantMap state{
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), page ? QStringLiteral("page") : isDraft ? QStringLiteral("draft") : QStringLiteral("server")},
      // The branch and worktree controls under the composer: a new thread's,
      // and kept once it has started only when the user asks (Composer context).
      // A page's agent runs in its project's own checkout.
      {QStringLiteral("showContextStrip"), !page && (isDraft || setting(QStringLiteral("persistComposerContextStrip")).toBool())},
      {QStringLiteral("edit"), kept.edit.isValid() ? kept.edit : QVariant::fromValue(nullptr)},
      {QStringLiteral("text"), text},
      {QStringLiteral("cursor"), cursor},
      {QStringLiteral("triggerKind"), trigger ? QVariant(trigger->kind) : QVariant::fromValue(nullptr)},
      {QStringLiteral("suggestions"), suggestionList},
      {QStringLiteral("suggestionsEmptyText"), emptyText},
      {QStringLiteral("attachments"), attachments},
      {QStringLiteral("terminalContexts"), terminalContexts},
      {QStringLiteral("reviewComments"), reviewComments},
      {QStringLiteral("threadContexts"), threadContexts},
      {QStringLiteral("citations"), citations},
      {QStringLiteral("placeholder"), placeholder},
      {QStringLiteral("editorDisabled"), !approvals.isEmpty() || choiceOnly},
      {QStringLiteral("canSend"), !(busy || offline || noProvider || needsPick) && (hasContent || showPlanFollowUp)},
      {QStringLiteral("sendDisabledReason"), disabledReason},
      {QStringLiteral("isRunning"), isRunning},
      // The send waits for the connection (setWaitsOffline): the send control says Queue.
      {QStringLiteral("waitsForConnection"), waitsForConnection},
      // More words for a page's working agent go to its thread, so a page
      // has no queue or steering: its send button sends, or stops.
      {QStringLiteral("followUpBehavior"), page ? QString()
                                         : !canSteerActive() || setting(QStringLiteral("followUpBehavior")).toString() == QLatin1String("queue")
                                               ? QStringLiteral("queue")
                                               : QStringLiteral("steer")},
      // A provider that cannot take a steer is offered no other way either.
      {QStringLiteral("canSteer"), canSteerActive()},
      {QStringLiteral("enterIntents"), composer::enterIntents(keys->resolved(), keys->mac(),
                                                              setting(QStringLiteral("sendShortcut")).toString(), isDraft,
                                                              isRunning && !page)},
      // A first message launching, or a message on its way to the MC.
      {QStringLiteral("isSendBusy"), busy || m_queues.contains(target)},
      {QStringLiteral("isConnecting"), false},
      {QStringLiteral("pendingApprovalCount"), approvals.size()},
      {QStringLiteral("pendingUserInputCount"), questions.size()},
      {QStringLiteral("showPlanFollowUpPrompt"), showPlanFollowUp},
      // What sending does to the offered plan (ComposerPrimaryActions):
      // "implement" with nothing typed, "refine" with feedback, else empty.
      {QStringLiteral("planAction"), !showPlanFollowUp ? QString()
                                     : text.trimmed().isEmpty() ? QStringLiteral("implement")
                                                                : QStringLiteral("refine")},
      {QStringLiteral("selectedInstanceId"), orNull(selectedInstance)},
      {QStringLiteral("selectedModel"), orNull(selectedModel)},
      {QStringLiteral("options"), shownOptions},
      {QStringLiteral("effortDisplay"), setting(QStringLiteral("effortDisplay")).toString()},
      {QStringLiteral("runtimeMode"), composer::shownRuntimeMode(instance, runtimeModeOf(target))},
      {QStringLiteral("defaultRuntimeMode"), composer::shownRuntimeMode(instance, defaultRuntimeModeOf(target))},
      {QStringLiteral("runtimeModes"), composer::runtimeModes(instance)},
      {QStringLiteral("interactionMode"), interactionModeOf(target)},
      {QStringLiteral("showInteractionModeToggle"), planOn},
      {QStringLiteral("usageLimits"), m_usageLimits.contains(target) ? QVariant(m_usageLimits.value(target)) : QVariant::fromValue(nullptr)},
      {QStringLiteral("editingQueuedRunId"), m_queuedEdits.contains(target) ? QVariant(m_queuedEdits.value(target).runId)
                                                                            : QVariant::fromValue(nullptr)},
  };
  if (page) {
    state.insert(QStringLiteral("pageId"), m_pageId);
    state.insert(QStringLiteral("project"), project);
    state.insert(QStringLiteral("projects"), projects);
  }
  return state;
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
  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  const auto key = [keys](const QString& command) { return composer::pickerKey(keys->resolved(), keys->mac(), command); };
  QVariantList jump;
  for (int n = 1; n <= 9; ++n) jump.append(key(QStringLiteral("modelPicker.jump.%1").arg(n)));
  const QVariant toggle = key(QStringLiteral("modelPicker.toggle"));
  return {
      {QStringLiteral("instances"),
       onImages() ? imagePickerInstances()
                  : composer::pickerInstances(m_catalogue, prefs, chosen.value(QLatin1String("instanceId")).toString(),
                                              chosen.value(QLatin1String("model")).toString(), thread && thread->runtime,
                                              current.value(QLatin1String("instanceId")).toString(),
                                              current.value(QLatin1String("model")).toString())},
      {QStringLiteral("locked"), !onImages() && thread && bool(thread->runtime)},
      // What stands where the model would be when no provider can run a turn.
      {QStringLiteral("noProvider"),
       onImages() ? QVariant::fromValue(nullptr)
                  : [&]() -> QVariant {
                      const QString standIn = composer::noProviderStandIn(m_catalogue);
                      return standIn.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(standIn);
                    }()},
      // Image models are not starred.
      {QStringLiteral("favorites"), !onImages()},
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

// The images' ShellComposerState: a prompt and an image model, nothing a turn carries.
QVariantMap ComposerController::imagesComposerState() const {
  const QString target = imagesKey(m_imagesSpace);
  const Draft kept = m_drafts.value(target);
  const QString text = draft(target);
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  const QVariantMap offer = spaces ? spaces->imageProviders() : QVariantMap();
  const QVariantList providers = offer.value(QStringLiteral("providers")).toList();
  const bool answered = !offer.isEmpty();
  const bool able = std::any_of(providers.cbegin(), providers.cend(), [](const QVariant& provider) {
    return provider.toMap().value(QStringLiteral("status")).toString() == QLatin1String("ready");
  });
  const bool busy = spaces && spaces->generatingImage();
  const bool offline = !m_store->environmentOnline(m_client->environment());
  const QJsonObject chosen = imageSelection(target);
  QVariant disabledReason = QVariant::fromValue(nullptr);
  if (offline) {
    disabledReason = QStringLiteral("Not connected");
  } else if (answered && !able) {
    disabledReason = QStringLiteral("No provider can generate images");
  }
  const auto orNull = [](const QString& value) { return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value); };
  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  return {
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), QStringLiteral("images")},
      {QStringLiteral("spaceId"), m_imagesSpace},
      {QStringLiteral("showContextStrip"), false},
      {QStringLiteral("edit"), kept.edit.isValid() ? kept.edit : QVariant::fromValue(nullptr)},
      {QStringLiteral("text"), text},
      {QStringLiteral("cursor"), std::clamp(kept.cursor, 0, int(text.size()))},
      {QStringLiteral("triggerKind"), QVariant::fromValue(nullptr)},
      {QStringLiteral("suggestions"), QVariantList()},
      {QStringLiteral("suggestionsEmptyText"), QVariant::fromValue(nullptr)},
      {QStringLiteral("attachments"), QVariantList()},
      {QStringLiteral("terminalContexts"), QVariantList()},
      {QStringLiteral("reviewComments"), QVariantList()},
      {QStringLiteral("threadContexts"), QVariantList()},
      {QStringLiteral("citations"), QVariantList()},
      {QStringLiteral("placeholder"), answered && !able
                                          ? QStringLiteral("No provider here can generate images. Set up Codex or Grok in Settings.")
                                          : QStringLiteral("What should the image show?")},
      {QStringLiteral("editorDisabled"), false},
      {QStringLiteral("canSend"), !(busy || offline) && able && !text.trimmed().isEmpty()},
      {QStringLiteral("sendDisabledReason"), disabledReason},
      {QStringLiteral("isRunning"), false},
      {QStringLiteral("followUpBehavior"), QString()},
      {QStringLiteral("canSteer"), true},
      {QStringLiteral("enterIntents"), composer::enterIntents(keys->resolved(), keys->mac(),
                                                              setting(QStringLiteral("sendShortcut")).toString(), false, false)},
      {QStringLiteral("isSendBusy"), busy},
      {QStringLiteral("isConnecting"), false},
      {QStringLiteral("pendingApprovalCount"), 0},
      {QStringLiteral("pendingUserInputCount"), 0},
      {QStringLiteral("showPlanFollowUpPrompt"), false},
      {QStringLiteral("selectedInstanceId"), orNull(chosen.value(QLatin1String("instanceId")).toString())},
      {QStringLiteral("selectedModel"), orNull(chosen.value(QLatin1String("model")).toString())},
      {QStringLiteral("options"), QVariantList()},
      {QStringLiteral("runtimeMode"), QString()},
      {QStringLiteral("defaultRuntimeMode"), QString()},
      {QStringLiteral("runtimeModes"), QVariantList()},
      {QStringLiteral("interactionMode"), QStringLiteral("default")},
      {QStringLiteral("showInteractionModeToggle"), false},
      {QStringLiteral("usageLimits"), QVariant::fromValue(nullptr)},
      {QStringLiteral("editingQueuedRunId"), QVariant::fromValue(nullptr)},
  };
}

// The picker's instances for the images' prompt: each provider that can make an
// image, drawn as the chat's picker draws it, with its image models.
QVariantList ComposerController::imagePickerInstances() const {
  const auto* spaces = NativeShell::of(this)->controller<SpaceController>();
  if (!spaces) return {};
  return composer::imagePickerInstances(spaces->imageProviders(), m_catalogue);
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
// runtimeMode, interactionMode, carried}}, stash: [{id, createdAt, text, attachments,
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
  const QJsonObject modelOptions = stored.value(QLatin1String("modelOptions")).toObject();
  for (auto it = modelOptions.begin(); it != modelOptions.end(); ++it) m_kept.modelOptions.insert(it.key(), it.value().toArray());
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
    kept.carried = entry.value(QLatin1String("carried")).toBool();
    if (const QJsonValue base = entry.value(QLatin1String("selectionBase")); base.isDouble()) kept.pickBase = qint64(base.toDouble());
    kept.projectId = entry.value(QLatin1String("projectId")).toString();
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
    // The outbox's waits to be sent (again: the MC carries a message out once).
    for (const QJsonValue& command : entry.value(QLatin1String("commands")).toArray()) kept.commands.append(command.toObject());
    if (!kept.commands.isEmpty()) {
      kept.choices = entry.value(QLatin1String("choices")).toObject();
      kept.kept = false;
      kept.waiting = true;
      kept.waited = true;
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

bool ComposerController::save() const {
  spread();
  if (m_kept.path.isEmpty()) return true;
  QJsonObject targets;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    const Draft& kept = it.value();
    // An edited queued message is not the thread's draft.
    const auto edit = m_queuedEdits.constFind(it.key());
    const QString text = edit != m_queuedEdits.cend() ? edit->saved : kept.text;
    QJsonObject entry;
    if (!text.isEmpty()) entry.insert(QStringLiteral("text"), text);
    if (kept.modelSelection) entry.insert(QStringLiteral("modelSelection"), *kept.modelSelection);
    if (!kept.runtimeMode.isEmpty()) entry.insert(QStringLiteral("runtimeMode"), kept.runtimeMode);
    if (!kept.interactionMode.isEmpty()) entry.insert(QStringLiteral("interactionMode"), kept.interactionMode);
    if (kept.carried) entry.insert(QStringLiteral("carried"), true);
    if (kept.pickBase) entry.insert(QStringLiteral("selectionBase"), double(*kept.pickBase));
    if (!kept.projectId.isEmpty()) entry.insert(QStringLiteral("projectId"), kept.projectId);
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
    if (!entry.commands.isEmpty()) {
      QJsonArray commands;
      for (const QJsonObject& command : entry.commands) commands.append(command);
      kept.insert(QStringLiteral("commands"), commands);
      kept.insert(QStringLiteral("choices"), entry.choices);
    }
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
  bool written = false;
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
    if (!m_kept.modelOptions.isEmpty()) {
      QJsonObject modelOptions;
      for (auto it = m_kept.modelOptions.cbegin(); it != m_kept.modelOptions.cend(); ++it) modelOptions.insert(it.key(), it.value());
      stored.insert(QStringLiteral("modelOptions"), modelOptions);
    }
    file.write(QJsonDocument(stored).toJson(QJsonDocument::Compact));
    written = file.commit();
  }
  // The drafts' images, apart: rewritten only when they change.
  QJsonObject images;
  for (auto it = m_drafts.cbegin(); it != m_drafts.cend(); ++it) {
    QJsonArray list;
    for (const Attachment& attachment : it.value().attachments) list.append(attachmentJson(attachment));
    if (!list.isEmpty()) images.insert(it.key(), list);
  }
  const QString joined = imagesSignature(images) + u'\n' + imagesSignature(unsentImages);
  if (joined == m_kept.images) return written;
  if (images.isEmpty() && unsentImages.isEmpty()) {
    if (QFile::remove(imagesPath()) || !QFile::exists(imagesPath())) m_kept.images = joined;
    return written;
  }
  QSaveFile imagesFile(imagesPath());
  if (!imagesFile.open(QIODevice::WriteOnly)) return written;
  QJsonObject kept{{QStringLiteral("targets"), images}};
  if (!unsentImages.isEmpty()) kept.insert(QStringLiteral("unsent"), unsentImages);
  imagesFile.write(QJsonDocument(kept).toJson(QJsonDocument::Compact));
  // Remembered once written, so a failed write is tried again on the next save.
  if (imagesFile.commit()) m_kept.images = joined;
  return written;
}
