// The composer's pure parts: what the text before the caret asks for
// (composer::trigger), starring models (composer::toggleFavorite), what waits
// behind the running turn (composer::queued) and the rich text drawing
// (ComposerHighlighter), and whose limits "/usage-limits" shows
// (composer::usageLimitsReport).

#include <QJsonArray>
#include <QJsonObject>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>

#include "ComposerHighlighter.h"
#include "ComposerModel.h"
#include "Prop.h"

namespace {

// Text made of the characters the triggers and the Markdown care about.
rc::Gen<QString> composerText() {
  static const std::vector<QChar> alphabet{u'a', u'b', u' ', u'\n', u'/', u'@', u'#', u'$', u'*', u'_', u'`', u'~', u'-'};
  return rc::gen::map(rc::gen::container<std::vector<QChar>>(rc::gen::elementOf(alphabet)),
                      [](const std::vector<QChar>& chars) { return QString(chars.data(), qsizetype(chars.size())); });
}

// A queued run as the MC streams it: the run, and its message, which can come
// before it, after it, or not yet.
struct QueuedRun {
  QString id;
  int position = 0;
  QString status;  // queued, running or completed
  int kind = 0;    // 0 the user's, 1 a task's result, 2 one stored as its envelope, 3 a wake-up
  bool messageHere = false;
};

void showValue(const QueuedRun& run, std::ostream& os) {
  os << run.id.toStdString() << "@" << run.position << " " << run.status.toStdString() << " kind " << run.kind
     << (run.messageHere ? "" : " (no message)");
}

QJsonObject messageOf(const QueuedRun& run) {
  const QString id = QStringLiteral("message-") + run.id;
  QJsonObject message{{QStringLiteral("id"), id}, {QStringLiteral("role"), QStringLiteral("user")}};
  const QJsonObject completion{{QStringLiteral("taskId"), run.id}, {QStringLiteral("status"), QStringLiteral("failed")}};
  switch (run.kind) {
    case 0:
      message.insert(QStringLiteral("text"), QStringLiteral("follow up ") + run.id);
      break;
    case 1:
      message.insert(QStringLiteral("text"), QStringLiteral("<delegated_task_result>"));
      message.insert(QStringLiteral("createdBy"), QStringLiteral("system"));
      message.insert(QStringLiteral("delegatedCompletion"), completion);
      message.insert(QStringLiteral("notification"),
                     QJsonObject{{QStringLiteral("summary"), QStringLiteral("Task ") + run.id + QStringLiteral(" failed")}, {QStringLiteral("outcome"), QStringLiteral("failed")}});
      break;
    case 2:
      message.insert(QStringLiteral("text"), QStringLiteral("<delegated_task_result taskId=\"%1\" title=\"Task %1\" status=\"failed\" childThreadId=\"c\">\nno\n</delegated_task_result>").arg(run.id));
      message.insert(QStringLiteral("createdBy"), QStringLiteral("system"));
      message.insert(QStringLiteral("delegatedCompletion"), completion);
      break;
    default:
      message.insert(QStringLiteral("text"), QStringLiteral("Background task completed."));
      message.insert(QStringLiteral("createdBy"), QStringLiteral("agent"));
      message.insert(QStringLiteral("creationSource"), QStringLiteral("provider"));
      message.insert(QStringLiteral("providerWake"), true);
      break;
  }
  return message;
}

}  // namespace

class ComposerPureProp : public QObject {
  Q_OBJECT

private slots:
  void queuedRunsAreListedOnceTheirMessageIsHere() {
    QVERIFY(rc::check("what waits behind the turn is the queued runs whose message is here, the user's apart from the agent's", [] {
      const std::vector<QString> ids{QStringLiteral("run-a"), QStringLiteral("run-b"), QStringLiteral("run-c"), QStringLiteral("run-d"), QStringLiteral("run-e")};
      const std::vector<QString> statuses{QStringLiteral("queued"), QStringLiteral("queued"), QStringLiteral("running"), QStringLiteral("completed")};
      std::vector<QueuedRun> runs;
      for (const QString& id : ids) {
        if (!*rc::gen::arbitrary<bool>()) continue;
        runs.push_back({id, *rc::gen::inRange(0, 3), *rc::gen::elementOf(statuses), *rc::gen::inRange(0, 4), *rc::gen::arbitrary<bool>()});
      }
      // The order the runs came in.
      const std::vector<QueuedRun> arrived = *rc::gen::elementOf(std::vector<std::vector<QueuedRun>>{runs, {runs.rbegin(), runs.rend()}});

      QList<QJsonObject> entities;
      QHash<QString, QJsonObject> messages;
      for (const QueuedRun& run : arrived) {
        entities.append({{QStringLiteral("id"), run.id},
                         {QStringLiteral("status"), run.status},
                         {QStringLiteral("queuePosition"), run.position},
                         {QStringLiteral("userMessageId"), QStringLiteral("message-") + run.id}});
        if (run.messageHere) messages.insert(QStringLiteral("message-") + run.id, messageOf(run));
      }

      std::vector<QueuedRun> expected;
      for (const QueuedRun& run : runs) {
        if (run.status == QLatin1String("queued") && run.messageHere) expected.push_back(run);
      }
      std::sort(expected.begin(), expected.end(), [](const QueuedRun& a, const QueuedRun& b) {
        return a.position != b.position ? a.position < b.position : a.id < b.id;
      });
      QVariantList queue;
      QVariantList waiting;
      for (const QueuedRun& run : expected) {
        if (run.kind == 0) {
          queue.append(QVariantMap{{QStringLiteral("runId"), run.id},
                                   {QStringLiteral("messageId"), QStringLiteral("message-") + run.id},
                                   {QStringLiteral("text"), QStringLiteral("follow up ") + run.id},
                                   {QStringLiteral("attachments"), QVariantList()}});
        } else if (run.kind == 3) {
          waiting.append(QVariantMap{{QStringLiteral("runId"), run.id},
                                     {QStringLiteral("summary"), QStringLiteral("Background activity updated")},
                                     {QStringLiteral("outcome"), QStringLiteral("updated")},
                                     {QStringLiteral("workerThreadId"), QString()}});
        } else {
          waiting.append(QVariantMap{{QStringLiteral("runId"), run.id},
                                     {QStringLiteral("summary"), QStringLiteral("Task ") + run.id + QStringLiteral(" failed")},
                                     {QStringLiteral("outcome"), QStringLiteral("failed")},
                                     {QStringLiteral("workerThreadId"), QString()}});
        }
      }

      const composer::Queued queued = composer::queued(entities, messages);
      RC_ASSERT(queued.queue == queue);
      RC_ASSERT(queued.waiting == waiting);
    }));
  }

  void triggerStaysBeforeTheCaret() {
    QVERIFY(rc::check("a trigger spans the text it was read from, ending at the caret", [] {
      const QString text = *composerText();
      // The caret at the start is a case of its own.
      const int cursor = *rc::gen::weightedOneOf<int>({{1, rc::gen::just(0)}, {3, rc::gen::inRange(0, int(text.size()) + 1)}});
      const auto found = composer::trigger(text, cursor);
      if (!found) return;
      RC_ASSERT(0 <= found->start);
      RC_ASSERT(found->start < found->end);
      RC_ASSERT(found->end == cursor);
      // The marker, then the query.
      RC_ASSERT(text.mid(found->start + 1, found->end - found->start - 1) == found->query);
    }));
  }

  void starringTogglesOneModel() {
    QVERIFY(rc::check("starring a model stars or unstars it alone", [] {
      const std::vector<QString> instances{QStringLiteral("codex"), QStringLiteral("claude")};
      const std::vector<QString> models{QStringLiteral("gpt-a"), QStringLiteral("gpt-b"), QStringLiteral("opus")};
      const auto toggles = *rc::gen::container<std::vector<std::pair<QString, QString>>>(
          rc::gen::pair(rc::gen::elementOf(instances), rc::gen::elementOf(models)));
      QJsonArray favorites;
      QSet<QString> expected;
      for (const auto& [instance, model] : toggles) {
        favorites = composer::toggleFavorite(favorites, instance, model);
        const QString key = instance + u'\n' + model;
        if (!expected.remove(key)) expected.insert(key);
        RC_ASSERT(composer::modelPrefs(favorites, QJsonValue()).favorites == expected);
        RC_ASSERT(favorites.size() == expected.size());
      }
    }));
  }

  void shownPermissionsStayOffered() {
    QVERIFY(rc::check("the shown permissions are always one the provider offers", [] {
      const std::vector<QString> modes{QStringLiteral("approval-required"), QStringLiteral("auto-accept-edits"),
                                       QStringLiteral("auto"), QStringLiteral("full-access")};
      const auto supported = *rc::gen::container<std::vector<QString>>(rc::gen::elementOf(modes));
      const QString saved = *rc::gen::elementOf(modes);
      composer::Instance instance;
      for (const QString& mode : supported) {
        if (!instance.runtimeModes.contains(mode)) instance.runtimeModes.append(mode);
      }
      const QString shown = composer::shownRuntimeMode(&instance, saved);
      // Every mode is offered when the provider names none.
      const bool offered = instance.runtimeModes.isEmpty() || instance.runtimeModes.contains(shown);
      RC_ASSERT(offered);
      if (instance.runtimeModes.isEmpty() || instance.runtimeModes.contains(saved)) {
        RC_ASSERT(shown == saved);
      } else if (instance.runtimeModes.contains(QStringLiteral("approval-required"))) {
        RC_ASSERT(shown == QLatin1String("approval-required"));
      }
    }));
    QVERIFY(rc::check("with no ready provider, its stand-in names setup only when one can be set up", [] {
      const int count = *rc::gen::inRange(0, 5);
      QList<composer::Instance> list;
      bool ready = false;
      bool setUp = false;
      for (int i = 0; i < count; ++i) {
        composer::Instance instance;
        instance.enabled = *rc::gen::arbitrary<bool>();
        instance.available = *rc::gen::arbitrary<bool>();
        instance.status = *rc::gen::arbitrary<bool>() ? QStringLiteral("ready") : QStringLiteral("error");
        instance.canSetUp = *rc::gen::arbitrary<bool>();
        ready = ready || instance.ready();
        setUp = setUp || instance.canSetUp;
        list.append(instance);
      }
      const QString label = composer::noProviderLabel(list);
      if (ready || list.isEmpty()) {
        RC_ASSERT(label.isEmpty());
      } else {
        RC_ASSERT(label == (setUp ? QLatin1String("Open provider settings") : QLatin1String("No provider available")));
      }
    }));
  }

  void highlightingKeepsTheText() {
    QVERIFY(rc::check("rich text draws the draft without changing it, inside each line", [] {
      const QString text = *composerText();
      const bool rich = *rc::gen::arbitrary<bool>();
      QTextDocument document;
      document.setPlainText(text);
      ComposerHighlighter highlighter;
      highlighter.setRich(rich);
      highlighter.setDocument(&document);
      highlighter.rehighlight();
      RC_ASSERT(document.toPlainText() == text);
      for (QTextBlock block = document.begin(); block.isValid(); block = block.next()) {
        const QList<QTextLayout::FormatRange> formats = block.layout()->formats();
        if (!rich) RC_ASSERT(formats.isEmpty());
        for (const QTextLayout::FormatRange& range : formats) {
          RC_ASSERT(range.start >= 0);
          RC_ASSERT(range.length > 0);
          RC_ASSERT(range.start + range.length <= block.length());
        }
      }
    }));
  }
  void underscoresNeverItalicise() {
    QVERIFY(rc::check("with rich text on, no run of letters, spaces and underscores is drawn italic", [] {
      const std::string typed = *rc::gen::container<std::string>(rc::gen::elementOf(std::vector<char>{'_', '_', 'a', 'b', ' ', '\n'}));
      QTextDocument document;
      document.setPlainText(QString::fromStdString(typed));
      ComposerHighlighter highlighter;
      highlighter.setRich(true);
      highlighter.setDocument(&document);
      highlighter.rehighlight();
      for (QTextBlock block = document.begin(); block.isValid(); block = block.next()) {
        for (const QTextLayout::FormatRange& range : block.layout()->formats()) RC_ASSERT(!range.format.fontItalic());
      }
    }));
  }
  void usageLimitsCountEachAccountOnce() {
    QVERIFY(rc::check("/usage-limits lists each account of the driver once, and its summary names the one or counts them", [] {
      const std::vector<QString> emails{QString(), QStringLiteral("sam@example.com"), QStringLiteral("ada@example.com")};
      const std::vector<QString> drivers{QStringLiteral("codex"), QStringLiteral("claudeAgent")};
      const QJsonObject windows{{QStringLiteral("checkedAt"), QStringLiteral("2026-01-01T00:00:00.000Z")},
                                {QStringLiteral("windows"), QJsonArray{QJsonObject{{QStringLiteral("label"), QStringLiteral("5-hour")},
                                                                                   {QStringLiteral("usedPercent"), 40}}}}};
      const QJsonObject failed{{QStringLiteral("windows"), QJsonArray()},
                               {QStringLiteral("unavailable"), QJsonObject{{QStringLiteral("reason"), QStringLiteral("probeFailed")}}}};
      // Instances: a driver, an email, and limits (none, read, failed).
      const int instanceCount = *rc::gen::inRange(1, 4);
      QJsonArray providers;
      QSet<QString> signedIn;  // emails of the codex accounts read natively
      int native = 0;
      for (int i = 0; i < instanceCount; ++i) {
        const QString driver = i == 0 ? QStringLiteral("codex") : *rc::gen::elementOf(drivers);
        const QString email = *rc::gen::elementOf(emails);
        const int read = *rc::gen::inRange(0, 3);
        QJsonObject provider{{QStringLiteral("instanceId"), driver + QString::number(i)}, {QStringLiteral("driver"), driver},
                             {QStringLiteral("enabled"), true}, {QStringLiteral("auth"), QJsonObject{{QStringLiteral("email"), email}}}};
        if (read > 0) provider.insert(QStringLiteral("usageLimits"), read == 1 ? windows : failed);
        if (driver == QLatin1String("codex") && read > 0) {
          ++native;
          if (read == 1 && !email.isEmpty()) signedIn.insert(email);
        }
        providers.append(provider);
      }
      QJsonArray accounts;
      int fromHub = 0;
      const int hubCount = *rc::gen::inRange(0, 4);
      for (int i = 0; i < hubCount; ++i) {
        const QString driver = *rc::gen::elementOf(drivers);
        const QString email = *rc::gen::elementOf(emails);
        accounts.append(QJsonObject{{QStringLiteral("id"), email.isEmpty() ? QStringLiteral("account-%1").arg(i) : email}, {QStringLiteral("driver"), driver},
                                    {QStringLiteral("email"), email}, {QStringLiteral("usageLimits"), windows}});
        if (driver == QLatin1String("codex") && !signedIn.contains(email)) ++fromHub;
      }
      const QJsonArray sources{QJsonObject{{QStringLiteral("id"), QStringLiteral("hub")}, {QStringLiteral("label"), QStringLiteral("Hub")},
                                           {QStringLiteral("accounts"), accounts}}};

      const QVariantMap report = composer::usageLimitsReport(QStringLiteral("codex0"), providers, sources);
      const QVariantList listed = report.value(QStringLiteral("accounts")).toList();
      RC_ASSERT(listed.size() == native + fromHub);
      const QVariantMap summary = report.value(QStringLiteral("summary")).toMap();
      if (listed.size() == 1) {
        RC_ASSERT(summary == listed.first().toMap());
      } else if (listed.isEmpty()) {
        RC_ASSERT(summary.value(QStringLiteral("label")).toString().isEmpty());
      } else {
        RC_ASSERT(summary.value(QStringLiteral("label")).toString() == QStringLiteral("%1 accounts").arg(listed.size()));
      }
      // The hub is named apart from the account, so scrambling one leaves the other.
      int hubListed = 0;
      for (const QVariant& value : listed) hubListed += value.toMap().value(QStringLiteral("source")).toString() == QLatin1String("Hub");
      RC_ASSERT(hubListed == fromHub);
      for (const QVariant& value : listed) {
        const QVariantMap account = value.toMap();
        // Either windows or the reason there are none.
        RC_ASSERT(account.value(QStringLiteral("windows")).toList().isEmpty() != account.value(QStringLiteral("notice")).toString().isEmpty());
        RC_ASSERT(account.value(QStringLiteral("sensitive")).toBool() == account.value(QStringLiteral("label")).toString().contains(u'@'));
      }
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerPureProp)
#include "tst_ComposerPureProp.moc"
