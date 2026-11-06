#include "TimelineModel.h"

#include <QCache>
#include <QDir>
#include <QClipboard>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QLocale>
#include <QRegularExpression>
#include <QTextBlock>
#include <QTextDocument>

#include <algorithm>
#include <cmath>
#include <optional>
#include <utility>

#include "CommandLabel.h"
#include "ComposerModel.h"
#include "SidebarModel.h"
#include "SubagentDisplay.h"
#include "TimelineSummary.h"

namespace {

// The entity kinds the timeline reads; the stream's others (nodes, provider
// sessions, ...) are left out. Plans and the user's messages are kept for the
// composer (turnChanged), checkpoints for the diff panel (checkpointsChanged)
// and a reply's revert (checkpointOf), subagents for the Agents tab
// (agentsChanged); they draw no rows.
const QSet<QString> kKinds{QStringLiteral("turn-item"),       QStringLiteral("run"),  QStringLiteral("run-attempt"),
                           QStringLiteral("runtime-request"), QStringLiteral("plan"), QStringLiteral("message"),
                           QStringLiteral("checkpoint"),      QStringLiteral("subagent")};
// The kinds a window bounds (HalC2.Streams.View): the client holds those of
// the runs from its floor on. The rest are held whole.
const QSet<QString> kWindowed{QStringLiteral("turn-item"), QStringLiteral("message")};
// Turn items the composer's turn state reads (requests).
const QSet<QString> kTurnItems{QStringLiteral("approval_request"), QStringLiteral("user_input_request")};
// Turn item fields that move, regroup or refold rows. Anything else (text,
// output, status) only redraws the row showing the item.
const QSet<QString> kStructural{QStringLiteral("type"),    QStringLiteral("runId"),       QStringLiteral("ordinal"),
                                QStringLiteral("streaming"), QStringLiteral("inputIntent"), QStringLiteral("nodeId")};
const QSet<QString> kSettled{QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("interrupted"),
                             QStringLiteral("cancelled")};
const QSet<QString> kRunning{QStringLiteral("preparing"), QStringLiteral("starting"), QStringLiteral("running"),
                             QStringLiteral("waiting")};

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QDateTime timeOf(const QJsonValue& value) {
  return QDateTime::fromString(value.toString(), Qt::ISODateWithMs);
}

// The checkpoints that count as diff turns, in run order: ready ones of
// completed runs, as the MC counts getTurnDiff's turns (turn N is the Nth
// of these, so rewound and unfinished runs leave no gaps). A run the
// entities do not hold is not evidence against a checkpoint.
QList<QPair<QString, QJsonObject>> diffCheckpoints(const QHash<QString, QJsonObject>& checkpoints,
                                                   const QHash<QString, QJsonObject>& runs) {
  QList<QPair<QString, QJsonObject>> counted;
  for (auto it = checkpoints.cbegin(); it != checkpoints.cend(); ++it) {
    if (!it->value(QLatin1String("appRunOrdinal")).isDouble()) continue;
    if (it->value(QLatin1String("status")).toString() != QLatin1String("ready")) continue;
    const auto run = runs.constFind(it->value(QLatin1String("runId")).toString());
    if (run != runs.constEnd() && run->value(QLatin1String("status")).toString() != QLatin1String("completed")) continue;
    counted.append({it.key(), *it});
  }
  std::sort(counted.begin(), counted.end(), [](const QPair<QString, QJsonObject>& left, const QPair<QString, QJsonObject>& right) {
    return left.second.value(QLatin1String("appRunOrdinal")).toInt() < right.second.value(QLatin1String("appRunOrdinal")).toInt();
  });
  return counted;
}

// A run's diff turn: its counted checkpoint's position, from 1, or 0.
int diffTurnOf(const QHash<QString, QJsonObject>& checkpoints, const QHash<QString, QJsonObject>& runs, const QString& runId) {
  const QList<QPair<QString, QJsonObject>> counted = diffCheckpoints(checkpoints, runs);
  for (qsizetype index = 0; index < counted.size(); ++index) {
    if (counted.at(index).second.value(QLatin1String("runId")).toString() == runId) return int(index) + 1;
  }
  return 0;
}

// Held for the user and never started: still queued, or cancelled while held.
bool heldNeverStarted(const QJsonObject& run) {
  const QString status = text(run, QLatin1String("status"));
  return (status == QLatin1String("queued") || status == QLatin1String("cancelled")) && run.value(QLatin1String("queueHeld")).toBool();
}

// Whether a run ever started: not one still queued, held or not, nor one that
// ended with no start time (cancelled from the queue, its workspace never ready).
bool everStarted(const QJsonObject& run) {
  const QString status = text(run, QLatin1String("status"));
  if (status == QLatin1String("queued") || heldNeverStarted(run)) return false;
  const bool endedEarly = status == QLatin1String("cancelled") || status == QLatin1String("failed") || status == QLatin1String("interrupted");
  return !endedEarly || run.value(QLatin1String("startedAt")).isString();
}

// When a turn item happened: its start, else its last update.
QDateTime itemTime(const QJsonObject& item) {
  const QDateTime started = timeOf(item.value(QLatin1String("startedAt")));
  return started.isValid() ? started : timeOf(item.value(QLatin1String("updatedAt")));
}

// The locale's numeric date, as Intl's {month: "numeric", day: "numeric"}
// (and year: "numeric" with `withYear`): "9/20", "9/20/2025".
QString numericDate(const QDate& date, bool withYear, const QLocale& locale) {
  QString format = locale.dateFormat(QLocale::ShortFormat);
  static const QRegularExpression days(QStringLiteral("d+"));
  static const QRegularExpression months(QStringLiteral("M+"));
  static const QRegularExpression years(QStringLiteral("y+"));
  format.replace(days, QStringLiteral("d"));
  format.replace(months, QStringLiteral("M"));
  if (withYear) {
    format.replace(years, QStringLiteral("yyyy"));
  } else {
    // The year and the separator joining it to the day or month.
    static const QRegularExpression year(QStringLiteral("^y+[^dMy]*|[^dMy]*y+$|y+[^dMy]*"));
    format.remove(year);
  }
  return locale.toString(date, format);
}

// formatDayAwareTimestamp for a time that has happened: "9:41 AM",
// "yesterday at 9:41 AM", "9/20 9:41 AM".
QString dayAware(const QDateTime& local, const QDate& today, const QString& timestampFormat, const QLocale& locale) {
  const QString time = sidebar::timeOfDay(local, timestampFormat, locale);
  const qint64 days = local.date().daysTo(today);
  if (days <= 0) return time;
  if (days == 1) return QStringLiteral("yesterday at ") + time;
  return numericDate(local.date(), local.date().year() != today.year(), locale) + QLatin1Char(' ') + time;
}

// A changed file as the row labels it: relative to the workspace, when it is
// inside it.
QString workspacePath(const QString& path, const QString& root) {
  QString base = root;
  while (base.size() > 1 && base.endsWith(QLatin1Char('/'))) base.chop(1);
  if (base.isEmpty() || base == QLatin1String("/") || !path.startsWith(base + QLatin1Char('/'))) return path;
  return path.mid(base.size() + 1);
}

// Whether a command's output is only its own text echoed back
// (commandDetailRepeatsCommand): equal to it, or a start of it cut off with
// "..." or "…".
bool repeatsCommand(const QString& output, const QStringList& commands) {
  const QString shown = output.trimmed();
  QString cut;
  if (shown.endsWith(QLatin1String("..."))) cut = shown.chopped(3);
  else if (shown.endsWith(QChar(0x2026))) cut = shown.chopped(1);
  return std::any_of(commands.cbegin(), commands.cend(), [&](const QString& candidate) {
    const QString command = candidate.trimmed();
    if (command.isEmpty()) return false;
    return command == shown || (!cut.isEmpty() && command.size() > cut.size() && command.startsWith(cut));
  });
}

// A web address the details may link to: http(s) only, "//host" read as
// https (resolveExternalWebLinkHref); empty for anything else.
QString safeWebAddress(const QString& address) {
  if (address.isEmpty()) return {};
  const QUrl url(address.startsWith(QLatin1String("//")) ? QStringLiteral("https:") + address : address, QUrl::StrictMode);
  const QString scheme = url.scheme().toLower();
  if (!url.isValid() || (scheme != QLatin1String("http") && scheme != QLatin1String("https")) || url.host().isEmpty()) return {};
  return url.toString(QUrl::FullyEncoded);
}

// An image a call viewed that the thread's workspace can serve: relative to
// the workspace (the path as it is in it), with an image's extension; empty
// for one outside it or any other file.
QString workspaceImage(const QString& path, const QString& root) {
  static const QStringList kImages{QStringLiteral("avif"), QStringLiteral("gif"), QStringLiteral("ico"), QStringLiteral("jpeg"),
                                   QStringLiteral("jpg"), QStringLiteral("png"), QStringLiteral("svg"), QStringLiteral("webp")};
  const QString trimmed = path.trimmed();
  if (trimmed.isEmpty() || trimmed.contains(QLatin1Char('\n')) || trimmed.contains(QLatin1Char('\r'))) return {};
  if (!kImages.contains(QFileInfo(trimmed).suffix().toLower())) return {};
  const QString relative = workspacePath(trimmed, root);
  // A full path left as it was is outside the workspace; so is one climbing out of it.
  if (relative.startsWith(QLatin1Char('/')) || relative.contains(QLatin1String(":\\")) || relative.startsWith(QLatin1String("~"))) return {};
  const QString clean = QDir::cleanPath(relative);
  if (clean == QLatin1String("..") || clean.startsWith(QLatin1String("../"))) return {};
  return clean;
}

// An icon address a provider supplied: http(s) or a data: image.
QString explicitIconUrl(const QJsonValue& value) {
  const QString address = value.toString();
  if (address.isEmpty() || address.size() > 4096) return {};
  const QUrl url(address);
  const QString scheme = url.scheme().toLower();
  return url.isValid() && (scheme == QLatin1String("http") || scheme == QLatin1String("https") || scheme == QLatin1String("data")) ? url.toString()
                                                                                                                                     : QString();
}

// The site's own icon for a page, in one appearance (toolActivityFaviconUrl):
// what the provider supplied, a site whose usual favicon is illegible in that
// appearance, then the origin's favicon.ico.
QString websiteIconUrl(const QJsonObject& icon, bool dark) {
  static const QHash<QString, QPair<QString, QString>> kThemed{
      {QStringLiteral("github.com"),
       {QStringLiteral("https://github.githubassets.com/favicons/favicon.svg"), QStringLiteral("https://github.githubassets.com/favicons/favicon-dark.svg")}}};
  const QString page = text(icon, QLatin1String("pageUrl"));
  const QUrl url(page);
  const bool web = page.size() <= 4096 && url.isValid() && (url.scheme() == QLatin1String("http") || url.scheme() == QLatin1String("https"));
  const auto themed = kThemed.constFind(url.host().toLower());
  const QString site = web && themed != kThemed.cend() ? (dark ? themed->second : themed->first) : QString();
  const QString origin = web ? url.resolved(QUrl(QStringLiteral("/favicon.ico"))).toString() : QString();
  QString chosen = dark ? explicitIconUrl(icon.value(QLatin1String("faviconUrlDark"))) : explicitIconUrl(icon.value(QLatin1String("faviconUrl")));
  if (chosen.isEmpty()) chosen = site;
  if (chosen.isEmpty() && dark) chosen = explicitIconUrl(icon.value(QLatin1String("faviconUrl")));
  return chosen.isEmpty() ? origin : chosen;
}

// One answer as its preview reads (getQuestionAnswerText): text, a list's
// items joined, an object's `answers`.
QString answerText(const QJsonValue& value) {
  if (value.isString()) return value.toString();
  if (value.isArray()) {
    QStringList parts;
    for (const QJsonValue& part : value.toArray()) {
      if (const QString shown = answerText(part); !shown.isEmpty()) parts.append(shown);
    }
    return parts.join(QStringLiteral(", "));
  }
  return value.isObject() ? answerText(value.toObject().value(QLatin1String("answers"))) : QString();
}

// What the user answered a question with, on one line
// (getQuestionAnswerPreview): the answers, else the files sent, else the
// questions themselves.
QString answerPreview(const QJsonObject& answer) {
  QStringList parts;
  const QJsonObject answers = answer.value(QLatin1String("answers")).toObject();
  for (auto it = answers.constBegin(); it != answers.constEnd(); ++it) {
    if (const QString shown = answerText(*it); !shown.isEmpty()) parts.append(shown);
  }
  QString preview = parts.join(QStringLiteral(" · "));
  if (preview.isEmpty()) {
    const QJsonObject attachments = answer.value(QLatin1String("attachmentsByQuestionId")).toObject();
    for (auto it = attachments.constBegin(); it != attachments.constEnd(); ++it) {
      for (const QJsonValue& attachment : it->toArray()) parts.append(attachment.toObject().value(QLatin1String("name")).toString());
    }
    preview = parts.join(QStringLiteral(", "));
  }
  if (preview.isEmpty()) {
    const QJsonObject questions = answer.value(QLatin1String("questionTextById")).toObject();
    for (auto it = questions.constBegin(); it != questions.constEnd(); ++it) parts.append(it->toString());
    preview = parts.join(QStringLiteral(" · "));
  }
  static const QRegularExpression space(QStringLiteral(R"(\s+)"));
  return preview.replace(space, QStringLiteral(" ")).trimmed();
}

// A thought as its row labels it: the words
// of its Markdown on one line, which the row elides. Only its start is read,
// and the lines are kept: reading Markdown takes a tenth of a millisecond, and
// a row asks for its labels again each time it redraws.
QString thoughtLine(const QString& thought) {
  static const QRegularExpression space(QStringLiteral(R"(\s+)"), QRegularExpression::UseUnicodePropertiesOption);
  static QCache<QString, QString> lines(256);
  const QString start = thought.left(600);
  if (const QString* kept = lines.object(start)) return *kept;
  QTextDocument document;
  document.setMarkdown(start);
  QString line;
  for (QTextBlock block = document.begin(); block.isValid(); block = block.next()) {
    for (QTextBlock::iterator it = block.begin(); !it.atEnd(); ++it) {
      const QTextCharFormat format = it.fragment().charFormat();
      // An image reads as its alt text.
      line += format.isImageFormat() ? format.stringProperty(QTextFormat::ImageAltText) : it.fragment().text();
    }
    line += QLatin1Char(' ');
  }
  line = line.replace(space, QStringLiteral(" ")).trimmed().left(200);
  lines.insert(start, new QString(line));
  return line;
}

// The icon of a turn item the native timeline shows as a call or a row.
QString iconOf(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("command_execution")) return QStringLiteral("terminal");
  if (type == QLatin1String("file_change")) return QStringLiteral("square-pen");
  if (timeline::isFileRead(item)) return QStringLiteral("eye");
  if (type == QLatin1String("file_search")) return QStringLiteral("search");
  if (type == QLatin1String("web_search")) return QStringLiteral("globe");
  if (type == QLatin1String("dynamic_tool")) return QStringLiteral("wrench");
  if (type == QLatin1String("reasoning")) return QStringLiteral("brain");
  if (type == QLatin1String("approval_request") || type == QLatin1String("user_input_request")) {
    return QStringLiteral("message-circle");
  }
  if (type == QLatin1String("subagent")) return QStringLiteral("bot");
  if (type == QLatin1String("error")) return QStringLiteral("circle-alert");
  if (const auto notice = timeline::noticeOf(item)) {
    return notice->outcome == QLatin1String("failed") ? QStringLiteral("circle-alert") : QStringLiteral("zap");
  }
  // V2LifecycleRow's dividers and interrupt request.
  if (type == QLatin1String("compaction")) return QStringLiteral("minus");
  if (type == QLatin1String("fork")) return QStringLiteral("git-fork");
  if (type == QLatin1String("handoff")) return QStringLiteral("arrow-right-left");
  if (type == QLatin1String("thread_created")) return QStringLiteral("message-square");
  if (type == QLatin1String("run_interrupt_request")) return QStringLiteral("square");
  if (type == QLatin1String("run_interrupt_result")) return QStringLiteral("x");
  // The info tone (todo lists, notices).
  return QStringLiteral("check");
}

QString ordinalSuffix(int day) {
  const int lastTwo = day % 100;
  if (lastTwo >= 11 && lastTwo <= 13) return QStringLiteral("th");
  switch (day % 10) {
    case 1:
      return QStringLiteral("st");
    case 2:
      return QStringLiteral("nd");
    case 3:
      return QStringLiteral("rd");
    default:
      return QStringLiteral("th");
  }
}

// HalC2.Patch: `s` sets, `u` unsets, `a` appends to strings, `d` deletes
// (alone) or replaces (with `s`/`a`). nullopt when the entity is gone.
std::optional<QJsonObject> patched(const QJsonObject& entity, const QJsonObject& patch) {
  const bool replace = patch.value(QLatin1String("d")).toBool();
  if (replace && !patch.contains(QLatin1String("s")) && !patch.contains(QLatin1String("a"))) return std::nullopt;
  QJsonObject next = replace ? QJsonObject() : entity;
  const QJsonObject set = patch.value(QLatin1String("s")).toObject();
  for (auto it = set.begin(); it != set.end(); ++it) next.insert(it.key(), it.value());
  for (const QJsonValue& field : patch.value(QLatin1String("u")).toArray()) next.remove(field.toString());
  const QJsonObject append = patch.value(QLatin1String("a")).toObject();
  for (auto it = append.begin(); it != append.end(); ++it) {
    next.insert(it.key(), next.value(it.key()).toString() + it.value().toString());
  }
  return next;
}

// packages/shared/src/orchestrationTiming.ts formatDuration: tenths under ten
// seconds, then hours, minutes and seconds, leaving out the empty ones.
QString formatDuration(qint64 ms) {
  if (ms < 0) return QStringLiteral("0ms");
  if (ms < 1000) return QStringLiteral("%1ms").arg(std::max<qint64>(1, ms));
  if (ms < 10000) {
    const double tenths = std::round(ms / 100.0) / 10.0;
    return tenths >= 10 ? QStringLiteral("10s") : QStringLiteral("%1s").arg(tenths, 0, 'f', 1);
  }
  if (ms < 60000) return QStringLiteral("%1s").arg(std::llround(ms / 1000.0));
  const qint64 total = std::llround(ms / 1000.0);
  QStringList parts;
  if (total >= 3600) parts.append(QStringLiteral("%1h").arg(total / 3600));
  if (total % 3600 >= 60) parts.append(QStringLiteral("%1m").arg(total % 3600 / 60));
  if (total % 60 > 0) parts.append(QStringLiteral("%1s").arg(total % 60));
  return parts.join(QLatin1Char(' '));
}

enum class Kind { Message, Work, Plan, Subagent, Error, Marker, Checkpoint };

Kind classify(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (timeline::noticeOf(item)) return Kind::Marker;
  if (type == QLatin1String("user_message") || type == QLatin1String("assistant_message")) return Kind::Message;
  if (type == QLatin1String("proposed_plan")) return Kind::Plan;
  if (type == QLatin1String("subagent")) return Kind::Subagent;
  if (type == QLatin1String("error")) return Kind::Error;
  if (type == QLatin1String("checkpoint")) return Kind::Checkpoint;
  if (type == QLatin1String("fork") || type == QLatin1String("handoff") || type == QLatin1String("compaction") ||
      type == QLatin1String("thread_created")) {
    return Kind::Marker;
  }
  return Kind::Work;
}

QString kindName(Kind kind) {
  switch (kind) {
    case Kind::Message:
      return QStringLiteral("message");
    case Kind::Work:
      return QStringLiteral("work");
    case Kind::Plan:
      return QStringLiteral("plan");
    case Kind::Subagent:
      return QStringLiteral("subagent");
    case Kind::Error:
      return QStringLiteral("error");
    case Kind::Marker:
    case Kind::Checkpoint:
      break;
  }
  return QStringLiteral("marker");
}

// apps/tui/src/worklog.ts: how a tool call ended; empty once it completed.
QString callStatusLabel(const QString& status) {
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Stopped");
  if (status == QLatin1String("declined")) return QStringLiteral("Declined");
  if (status == QLatin1String("completed")) return {};
  return QStringLiteral("Running");
}

// How a subagent's status reads.
QString subagentStatusLabel(const QString& status) {
  if (status == QLatin1String("idle")) return QStringLiteral("Idle · resumable");
  if (status == QLatin1String("completed")) return QStringLiteral("Completed");
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Stopped");
  return QStringLiteral("Working");
}

QString intentMarker(const QString& intent) {
  if (intent == QLatin1String("queued_turn")) return QStringLiteral("Queued behind the active turn");
  if (intent == QLatin1String("steer")) return QStringLiteral("Steered the active turn");
  if (intent == QLatin1String("promoted_queued_to_steer")) {
    return QStringLiteral("Originally queued, then promoted to steer the active turn");
  }
  return {};
}

// apps/tui/src/proposedPlan.ts: the first heading, else "Proposed plan".
QString planTitle(const QString& markdown) {
  static const QRegularExpression heading(QStringLiteral("^\\s{0,3}#{1,6}\\s+(.+)$"),
                                          QRegularExpression::MultilineOption);
  const QString title = heading.match(markdown).captured(1).trimmed();
  return title.isEmpty() ? QStringLiteral("Proposed plan") : title;
}

// The plan's markdown without the heading it opens with (the card's title) or a
// "Summary" heading after it.
QString planBody(const QString& markdown) {
  static const QRegularExpression heading(QStringLiteral("^\\s{0,3}#{1,6}\\s+(.+)$"));
  QString trimmed = markdown;
  while (!trimmed.isEmpty() && trimmed.back().isSpace()) trimmed.chop(1);
  QStringList lines = trimmed.split(QRegularExpression(QStringLiteral("\\r?\\n")));
  const auto dropBlank = [&lines] {
    while (!lines.isEmpty() && lines.constFirst().trimmed().isEmpty()) lines.removeFirst();
  };
  if (!lines.isEmpty() && heading.match(lines.constFirst()).hasMatch()) lines.removeFirst();
  dropBlank();
  if (!lines.isEmpty() &&
      heading.match(lines.constFirst()).captured(1).trimmed().compare(QLatin1String("summary"), Qt::CaseInsensitive) == 0) {
    lines.removeFirst();
    dropBlank();
  }
  return lines.join(QLatin1Char('\n'));
}

// A long plan's preview (apps/web/src/proposedPlan.ts
// buildCollapsedProposedPlanPreviewMarkdown, ProposedPlanCard's canCollapse):
// its first ten lines with text, and "..." when there is more; empty for a plan
// short enough to show whole.
QString planPreview(const QString& markdown) {
  if (markdown.size() <= 900 && markdown.count(QLatin1Char('\n')) + 1 <= 20) return {};
  constexpr int maxLines = 10;
  QString body = planBody(markdown);
  while (!body.isEmpty() && body.back().isSpace()) body.chop(1);
  QStringList preview;
  int visible = 0;
  bool more = false;
  for (QString line : body.split(QRegularExpression(QStringLiteral("\\r?\\n")))) {
    while (!line.isEmpty() && line.back().isSpace()) line.chop(1);
    const bool shown = !line.trimmed().isEmpty();
    if (shown && visible >= maxLines) {
      more = true;
      break;
    }
    preview.append(line);
    if (shown) ++visible;
  }
  while (!preview.isEmpty() && preview.constLast().trimmed().isEmpty()) preview.removeLast();
  if (preview.isEmpty()) return planTitle(markdown);
  if (more) preview << QString() << QStringLiteral("...");
  return preview.join(QLatin1Char('\n'));
}

QString legacyTaskId(const QJsonObject& item) {
  static const QRegularExpression id(QStringLiteral("scheduled-task-message:(.+):\\d+:(?:scheduled|manual)$"));
  return id.match(text(item, QLatin1String("id"))).captured(1);
}

// The prefix an older MC put on a scheduled task's message in place of its
// id (client-runtime userMessage.ts LEGACY_AUTOMATION_PREFIX): its length, or 0.
qsizetype legacyAutomationPrefix(const QJsonObject& item) {
  static const QRegularExpression prefix(QStringLiteral("^\\[Triggered by schedule task: [^\\r\\n]+\\]\\r?\\n\\r?\\n"));
  const QRegularExpressionMatch match = prefix.match(text(item, QLatin1String("text")));
  if (!match.hasMatch()) return 0;
  return legacyTaskId(item).isEmpty() && text(item, QLatin1String("createdBy")) != QLatin1String("agent") ? 0 : match.capturedLength();
}

// The scheduled task that sent a user message: its id, or the one an older
// MC wrote into the message's id (turn items keep it after their own prefix).
QString scheduledTaskOf(const QJsonObject& item) {
  if (!text(item, QLatin1String("scheduledTaskId")).isEmpty()) return text(item, QLatin1String("scheduledTaskId"));
  return legacyAutomationPrefix(item) > 0 ? legacyTaskId(item) : QString();
}

QString markerTitle(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("fork")) {
    // This thread's own start, or a fork made from it (V2LifecycleRow).
    return text(item.value(QLatin1String("source")).toObject(), QLatin1String("type")) == QLatin1String("run") ? QStringLiteral("Forked from conversation")
                                                                                                               : QStringLiteral("Conversation fork");
  }
  if (type == QLatin1String("handoff")) return QStringLiteral("Context handoff");
  if (type == QLatin1String("compaction")) {
    const QString status = text(item, QLatin1String("status"));
    if (status == QLatin1String("failed")) return QStringLiteral("Context compaction failed");
    if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Context compaction stopped");
    if (status == QLatin1String("pending") || status == QLatin1String("running") || status == QLatin1String("waiting")) return QStringLiteral("Compacting context");
    return QStringLiteral("Context compacted");
  }
  if (type == QLatin1String("thread_created")) return QStringLiteral("Created thread");
  // A notification's work row is its summary alone.
  const auto notice = timeline::noticeOf(item);
  return !notice || notice->summary.isEmpty() ? QStringLiteral("Notification") : notice->summary;
}

QString markerDetail(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("thread_created")) return text(item, QLatin1String("title"));
  if (type == QLatin1String("compaction")) {
    // Its summary, else the tokens it went from and to.
    if (!text(item, QLatin1String("summary")).isEmpty()) return text(item, QLatin1String("summary"));
    const auto count = [&item](QLatin1StringView field) {
      return item.value(field).isDouble() ? QString::number(item.value(field).toInteger()) : QStringLiteral("?");
    };
    if (!item.value(QLatin1String("beforeTokenCount")).isDouble() && !item.value(QLatin1String("afterTokenCount")).isDouble()) return {};
    return QStringLiteral("%1 → %2 tokens").arg(count(QLatin1String("beforeTokenCount")), count(QLatin1String("afterTokenCount")));
  }
  // A worker's result, which the card under its title shows.
  if (const auto notice = timeline::noticeOf(item); notice && !notice->workerThreadId.isEmpty()) return notice->detail;
  return {};
}

}  // namespace

TimelineModel::TimelineModel(const QString& threadKey, QObject* parent)
    : QAbstractListModel(parent), m_threadKey(threadKey) {
  m_flushTimer.setSingleShot(true);
  m_flushTimer.setInterval(flushDelayMs);
  connect(&m_flushTimer, &QTimer::timeout, this, &TimelineModel::flush);
  connect(this, &QAbstractItemModel::rowsInserted, this, &TimelineModel::refreshLatest);
  connect(this, &QAbstractItemModel::rowsRemoved, this, &TimelineModel::refreshLatest);
  connect(this, &QAbstractItemModel::modelReset, this, &TimelineModel::refreshLatest);
  connect(this, &QAbstractItemModel::dataChanged, this, [this](const QModelIndex&, const QModelIndex& last) {
    // Only the newest rows can change the line.
    if (last.row() >= rowCount() - 4) refreshLatest();
  });
}

void TimelineModel::refreshLatest() {
  // The first line with words in it, as plain text.
  const auto lineOf = [](const QString& text) {
    static const QRegularExpression lead(QStringLiteral(R"(^[#>\s]+)"));
    for (const QString& line : text.split(QLatin1Char('\n'))) {
      if (line.trimmed().startsWith(QLatin1String("```"))) continue;
      const QString plain = timeline::plainDetail(line).remove(lead);
      if (!plain.isEmpty()) return plain.left(240);
    }
    return QString();
  };
  QString latest;
  for (int at = rowCount() - 1; at >= 0 && latest.isEmpty(); --at) {
    const QModelIndex row = index(at);
    const QString kind = data(row, KindRole).toString();
    if (kind == QLatin1String("fold")) continue;
    if (kind == QLatin1String("work")) {
      latest = lineOf(data(row, SummaryRole).toString());
      const QVariantList entries = data(row, EntriesRole).toList();
      if (latest.isEmpty() && !entries.isEmpty()) {
        const QVariantMap entry = entries.last().toMap();
        latest = lineOf(QStringList{entry.value(QStringLiteral("label")).toString(), entry.value(QStringLiteral("detail")).toString()}.join(QLatin1Char(' ')));
      }
      continue;
    }
    latest = lineOf(data(row, TextRole).toString());
    if (latest.isEmpty()) latest = lineOf(data(row, TitleRole).toString());
    if (!latest.isEmpty() && kind == QLatin1String("message") && data(row, AuthorRole).toString() == QLatin1String("user")) latest = QStringLiteral("You: ") + latest;
  }
  if (latest == m_latest) return;
  m_latest = latest;
  emit latestChanged();
}

void TimelineModel::setStatus(const QString& status, const QString& problem) {
  if (status == m_status && problem == m_problem) return;
  m_status = status;
  m_problem = problem;
  // Earlier turns only come over a stream that is live.
  if (status != QLatin1String("live") && std::exchange(m_loadingEarlier, false)) emit earlierChanged();
  emit statusChanged();
}

QString TimelineModel::durationText(qint64 ms) {
  return formatDuration(ms);
}

QString TimelineModel::workingLabel() const {
  if (!working()) return {};
  const qint64 seconds = std::max<qint64>(0, m_workingSince.secsTo(m_now()));
  return seconds < 1 ? QStringLiteral("Working") : QStringLiteral("Working for %1").arg(formatDuration(seconds * 1000));
}

void TimelineModel::setTimestampFormat(const QString& format) {
  const QString next = format.isEmpty() ? QStringLiteral("locale") : format;
  if (next == m_timestampFormat) return;
  m_timestampFormat = next;
  redrawTimes();
}

void TimelineModel::setFolds(Folds folds) {
  if (folds == m_folds) return;
  m_folds = folds;
  restructure({});
  emit foldsChanged();
}

void TimelineModel::setBackgroundWork(bool running) {
  if (running == m_backgroundWork) return;
  m_backgroundWork = running;
  if (phone()) restructure({});
}

void TimelineModel::setLocale(const QLocale& locale) {
  if (locale == m_locale) return;
  m_locale = locale;
  redrawTimes();
}

void TimelineModel::redrawTimes() {
  emit timesChanged();
  if (m_rows.isEmpty()) return;
  emit dataChanged(index(0), index(int(m_rows.size()) - 1), {TimeRole, EntriesRole});
}

QDateTime TimelineModel::rowTime(const Row& row) const {
  if (row.kind == QLatin1String("fold")) return row.at;
  if (row.kind == QLatin1String("work") || row.items.isEmpty()) return {};
  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.constFirst());
  // A reply is stamped when it finished, so not while it streams.
  if (text(item, QLatin1String("type")) == QLatin1String("assistant_message")) {
    if (item.value(QLatin1String("streaming")).toBool()) return {};
    return timeOf(item.value(QLatin1String("updatedAt")));
  }
  return itemTime(item);
}

// A time as the day-aware stamp reads it, on local calendar days.
QString TimelineModel::stamp(const QDateTime& at) const {
  if (!at.isValid()) return {};
  return dayAware(at.toLocalTime(), m_now().toLocalTime().date(), m_timestampFormat, m_locale);
}

QString TimelineModel::upcoming(const QDateTime& at) const {
  return upcomingStamp(at, m_now(), m_timestampFormat, m_locale);
}

QString upcomingStamp(const QDateTime& at, const QDateTime& now, const QString& timestampFormat, const QLocale& locale) {
  if (!at.isValid()) return {};
  const QDateTime local = at.toLocalTime();
  const QDate today = now.toLocalTime().date();
  const qint64 days = today.daysTo(local.date());
  if (days < 0) return dayAware(local, today, timestampFormat, locale);
  const QString time = sidebar::timeOfDay(local, timestampFormat, locale);
  if (days == 0) return time;
  if (days == 1) return QStringLiteral("tomorrow at ") + time;
  return numericDate(local.date(), local.date().year() != today.year(), locale) + QLatin1Char(' ') + time;
}

QString shortDate(const QDateTime& at, const QDateTime& now, const QLocale& locale) {
  if (!at.isValid()) return {};
  const QDate date = at.toLocalTime().date();
  return numericDate(date, date.year() != now.toLocalTime().date().year(), locale);
}

QString shortDateTime(const QDateTime& at, const QDateTime& now, const QString& timestampFormat, const QLocale& locale) {
  if (!at.isValid()) return {};
  return shortDate(at, now, locale) + QLatin1Char(' ') + sidebar::timeOfDay(at.toLocalTime(), timestampFormat, locale);
}

QString relativeTime(const QDateTime& at, const QDateTime& now) {
  if (!at.isValid()) return {};
  const qint64 seconds = at.secsTo(now);
  const qint64 span = seconds < 0 ? -seconds : seconds;
  if (span < 60) return QStringLiteral("just now");
  const QString amount = span < 3600    ? QStringLiteral("%1m").arg(span / 60)
                         : span < 86400 ? QStringLiteral("%1h").arg(span / 3600)
                                        : QStringLiteral("%1d").arg(span / 86400);
  return seconds < 0 ? QStringLiteral("in ") + amount : amount + QStringLiteral(" ago");
}

// The tooltip of a row's time, in English.
QString TimelineModel::timeTitle(const QString& rowId, const QString& entryId) const {
  const int at = indexOf(rowId);
  if (at < 0) return {};
  const Row& row = m_rows.at(at);
  QDateTime when;
  if (entryId.isEmpty()) {
    when = rowTime(row);
  } else if (row.items.contains(entryId)) {
    when = itemTime(entity(QStringLiteral("turn-item"), entryId));
  }
  if (!when.isValid()) return {};
  const QDateTime local = when.toLocalTime();
  const int day = local.date().day();
  return QStringLiteral("%1, %2%3 %4 %5")
      .arg(sidebar::timeOfDay(local, m_timestampFormat, m_locale))
      .arg(day)
      .arg(ordinalSuffix(day), QLocale(QLocale::English).monthName(local.date().month()))
      .arg(local.date().year());
}

// --- The fold ------------------------------------------------------------------------

QJsonObject TimelineModel::streamKinds() {
  QJsonObject kinds;
  for (const QString& kind : kKinds) kinds.insert(kind, QJsonObject());
  // The agent's replies are their turn items'; only the user's messages are kept.
  kinds.insert(QStringLiteral("message"), QJsonObject{{QStringLiteral("role"), QStringLiteral("user")}});
  return kinds;
}

bool TimelineModel::folds(const QString& kind, const QJsonObject& entity) {
  if (!kKinds.contains(kind)) return false;
  return kind != QLatin1String("message") || text(entity, QLatin1String("role")) == QLatin1String("user");
}

QJsonObject TimelineModel::subscribing() {
  m_catchingUp = true;
  m_catchUp.clear();
  m_page.clear();
  m_incoming.clear();
  if (std::exchange(m_loadingEarlier, false)) emit earlierChanged();
  if (m_cursor.offset < 0) {
    return {{QStringLiteral("offset"), QJsonValue::Null},
            {QStringLiteral("window"), QJsonObject{{QStringLiteral("items"), windowItems}}}};
  }
  const QJsonValue floor = m_cursor.floor ? QJsonValue(*m_cursor.floor) : QJsonValue(QJsonValue::Null);
  QJsonObject resume{{QStringLiteral("offset"), m_cursor.offset},
                     {QStringLiteral("window"), QJsonObject{{QStringLiteral("floor"), floor}}}};
  if (!m_cursor.handle.isEmpty()) resume.insert(QStringLiteral("handle"), m_cursor.handle);
  return resume;
}

void TimelineModel::receive(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("snapshot")) {
    snapshot(frame);
  } else if (type == QLatin1String("events")) {
    eventsFrame(frame);
  } else if (type == QLatin1String("live")) {
    live(frame);
  } else if (type == QLatin1String("page")) {
    page(frame);
  } else if (type == QLatin1String("resync")) {
    // The MC dropped events it could not send: the resubscription that
    // follows continues from the offset it names, never from an earlier one.
    const QJsonValue offset = frame.value(QLatin1String("offset"));
    if (offset.isDouble() && m_cursor.offset >= 0 && qint64(offset.toDouble()) > m_cursor.offset) {
      m_cursor.offset = qint64(offset.toDouble());
      m_cursorDirty = true;
    }
  }
}

void TimelineModel::snapshot(const QJsonObject& frame) {
  if (frame.value(QLatin1String("part")).toInt() == 0) m_incoming.clear();
  for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
    const QJsonArray row = value.toArray();
    const QString kind = row.at(0).toString();
    const QJsonObject entity = row.at(2).toObject();
    if (folds(kind, entity)) m_incoming[kind].insert(row.at(1).toString(), entity);
  }
  if (!frame.value(QLatin1String("done")).toBool()) return;
  // The rows keep their ids; only the ones that read differently are redrawn.
  const Entities before = std::exchange(m_entities, std::exchange(m_incoming, {}));
  m_catchUp.clear();
  const bool hadEarlier = hasEarlier();
  const QJsonValue offset = frame.value(QLatin1String("offset"));
  const QJsonValue floor = frame.value(QLatin1String("floor"));
  m_cursor.handle = frame.value(QLatin1String("handle")).toString();
  m_cursor.offset = offset.isDouble() ? qint64(offset.toDouble()) : 0;
  m_cursor.floor = floor.isDouble() ? std::optional<qint64>(qint64(floor.toDouble())) : std::nullopt;
  everythingChanged(changedSince(before));
  if (hasEarlier() != hadEarlier) emit earlierChanged();
  m_dirtyAll = true;
  flush();
}

QSet<QString> TimelineModel::changedSince(const Entities& before) const {
  const QHash<QString, QJsonObject> items = m_entities.value(QStringLiteral("turn-item"));
  const QHash<QString, QJsonObject> wereItems = before.value(QStringLiteral("turn-item"));
  const auto differs = [&](const QString& kind, const QString& id) {
    return !id.isEmpty() && before.value(kind).value(id) != entity(kind, id);
  };
  QSet<QString> changed;
  for (auto it = items.cbegin(); it != items.cend(); ++it) {
    if (wereItems.value(it.key()) != *it || differs(QStringLiteral("runtime-request"), text(*it, QLatin1String("requestId"))) ||
        differs(QStringLiteral("subagent"), text(*it, QLatin1String("subagentId")))) {
      changed.insert(it.key());
    }
  }
  return changed;
}

void TimelineModel::everythingChanged(const QSet<QString>& changed) {
  sortItems();
  restructure(changed);
  emit turnChanged();
  emit checkpointsChanged();
  emit agentsChanged();
  emit workspaceChanged();
}

void TimelineModel::eventsFrame(const QJsonObject& frame) {
  const QJsonValue offset = frame.value(QLatin1String("offset"));
  const qint64 reached = offset.isDouble() ? qint64(offset.toDouble()) : -1;
  // A catch-up that takes several frames is one set of merged changes: its
  // parts carry the offset the client is at, the last one the offset they
  // bring it to. Applied part-way and cut off, it would be applied again.
  if (m_catchingUp && reached >= 0 && reached <= m_cursor.offset) {
    m_catchUp.append(frame.value(QLatin1String("events")).toArray());
    return;
  }
  // As one change: an item added and removed again while away redraws nothing.
  m_catchUp.append(frame.value(QLatin1String("events")).toArray());
  events(caughtUp());
  // Only a copy has an offset to move: events before any snapshot do not make one.
  if (m_cursor.offset >= 0 && reached > m_cursor.offset) m_cursor.offset = reached;
  m_cursorDirty = true;
  if (!m_flushTimer.isActive()) m_flushTimer.start();
}

QJsonArray TimelineModel::caughtUp() {
  QJsonArray all;
  for (const QJsonArray& part : std::exchange(m_catchUp, {})) {
    for (const QJsonValue& event : part) all.append(event);
  }
  return all;
}

void TimelineModel::live(const QJsonObject& frame) {
  m_catchingUp = false;
  if (!m_catchUp.isEmpty()) events(caughtUp());
  const QJsonValue offset = frame.value(QLatin1String("offset"));
  if (m_cursor.offset >= 0 && offset.isDouble() && qint64(offset.toDouble()) > m_cursor.offset) {
    m_cursor.offset = qint64(offset.toDouble());
    m_cursorDirty = true;
  }
  // An MC that names its log now did not when the copy was taken: the copy
  // is the log's from here on, and the cache has none of it yet.
  const QString handle = frame.value(QLatin1String("handle")).toString();
  if (!handle.isEmpty() && handle != m_cursor.handle) {
    m_cursor.handle = handle;
    m_dirtyAll = true;
  }
  flush();
  setStatus(QStringLiteral("live"));
}

void TimelineModel::page(const QJsonObject& frame) {
  m_page.append(frame.value(QLatin1String("rows")).toArray());
  if (!frame.value(QLatin1String("done")).toBool()) return;
  for (const QJsonArray& rows : std::exchange(m_page, {})) {
    for (const QJsonValue& value : rows) {
      const QJsonArray row = value.toArray();
      const QString kind = row.at(0).toString();
      const QJsonObject entity = row.at(2).toObject();
      if (!folds(kind, entity)) continue;
      m_entities[kind].insert(row.at(1).toString(), entity);
      m_dirty.insert({kind, row.at(1).toString()});
    }
  }
  const QJsonValue offset = frame.value(QLatin1String("offset"));
  const QJsonValue floor = frame.value(QLatin1String("floor"));
  if (offset.isDouble() && qint64(offset.toDouble()) > m_cursor.offset) m_cursor.offset = qint64(offset.toDouble());
  m_cursor.floor = floor.isDouble() ? std::optional<qint64>(qint64(floor.toDouble())) : std::nullopt;
  m_cursorDirty = true;
  m_loadingEarlier = false;
  // The earlier turns' rows go in above; the ones held keep their place.
  sortItems();
  restructure({});
  emit turnChanged();
  emit agentsChanged();
  emit earlierChanged();
  flush();
}

void TimelineModel::loadEarlier() {
  if (!hasEarlier() || m_loadingEarlier || m_status != QLatin1String("live")) return;
  m_loadingEarlier = true;
  emit earlierChanged();
  emit earlierWanted(windowItems);
}

void TimelineModel::keepFrom(int row) {
  if (m_loadingEarlier || m_status != QLatin1String("live") || m_cursor.offset < 0) return;
  if (row < 0 || row >= m_rows.size()) return;
  const QHash<QString, QJsonObject> runs = m_entities.value(QStringLiteral("run"));
  const auto ordinalOf = [&](const QString& runId) -> std::optional<qint64> {
    const auto run = runs.constFind(runId);
    if (run == runs.cend()) return std::nullopt;
    return qint64(run->value(QLatin1String("ordinal")).toDouble());
  };
  // The oldest run of the rows from `row` on (a fold's, or its items'): rows
  // and runs need not be in the same order.
  std::optional<qint64> reading;
  const auto read = [&](const std::optional<qint64>& ordinal) {
    if (ordinal && (!reading || *ordinal < *reading)) reading = ordinal;
  };
  for (int at = row; at < m_rows.size(); ++at) {
    const Row& shown = m_rows.at(at);
    if (shown.id.startsWith(QLatin1String("fold:"))) read(ordinalOf(shown.id.mid(5)));
    for (const QString& item : shown.items) read(ordinalOf(text(entity(QStringLiteral("turn-item"), item), QLatin1String("runId"))));
  }
  if (!reading) return;
  // The MC holds a queued run's items whatever the floor
  // (HalC2.Streams.View.in_window?): the floor stays below the oldest.
  for (const QJsonObject& run : runs) {
    if (text(run, QLatin1String("status")) == QLatin1String("queued")) reading = std::min(*reading, qint64(run.value(QLatin1String("ordinal")).toDouble()));
  }
  // Above the run read, the newest runs that together hold m_keep turn items
  // stay (HalC2.Streams.View.take_runs); the floor is the oldest of them.
  QHash<qint64, int> counts;
  for (const QJsonObject& item : m_entities.value(QStringLiteral("turn-item"))) {
    const auto run = runs.constFind(text(item, QLatin1String("runId")));
    if (run == runs.cend() || text(*run, QLatin1String("status")) == QLatin1String("rolled_back")) continue;
    const qint64 ordinal = qint64(run->value(QLatin1String("ordinal")).toDouble());
    if (ordinal < *reading) ++counts[ordinal];
  }
  QList<qint64> above = counts.keys();
  std::sort(above.begin(), above.end(), std::greater<>());
  std::optional<qint64> floor;
  int kept = 0;
  int dropped = 0;
  for (const qint64 ordinal : std::as_const(above)) {
    if (floor) {
      dropped += counts.value(ordinal);
    } else if ((kept += counts.value(ordinal)) >= m_keep) {
      floor = ordinal;
    }
  }
  // Not worth a resubscription until it frees as much as a page brings.
  if (!floor || dropped < m_keep || (m_cursor.floor && *floor <= *m_cursor.floor)) return;
  for (const QString& kind : kWindowed) {
    QHash<QString, QJsonObject>& byKind = m_entities[kind];
    for (auto it = byKind.begin(); it != byKind.end();) {
      const std::optional<qint64> ordinal = ordinalOf(text(*it, QLatin1String("runId")));
      if (ordinal && *ordinal < *floor) {
        m_dirty.remove({kind, it.key()});
        it = byKind.erase(it);
      } else {
        ++it;
      }
    }
  }
  // The captures' JSON of the dropped turns is made again when they come back.
  m_accessJson.clear();
  m_cursor.floor = floor;
  m_cursorDirty = true;
  // The cache raises its floor and drops the turns below it first, then takes the cursor.
  if (m_cache && !m_cursor.handle.isEmpty()) m_cache->trimThread(m_threadKey, *floor);
  flush();
  sortItems();
  restructure({});
  emit turnChanged();
  emit agentsChanged();
  emit earlierChanged();
  emit windowRaised();
}

// --- The cache -----------------------------------------------------------------------

cache::Entity TimelineModel::cached(const QString& kind, const QString& id, const QJsonObject& fields) const {
  cache::Entity entity{kind, id, fields, std::nullopt};
  if (!kWindowed.contains(kind)) return entity;
  const QJsonObject run = this->entity(QStringLiteral("run"), text(fields, QLatin1String("runId")));
  if (!run.isEmpty()) entity.run = qint64(run.value(QLatin1String("ordinal")).toDouble());
  return entity;
}

void TimelineModel::restore(const cache::Thread& thread) {
  // Without the handle its offset came with, a copy cannot say what it is a copy of.
  if (!thread.found() || thread.cursor.handle.isEmpty() || m_cursor.offset >= 0) return;
  const Entities before = m_entities;
  for (const cache::Entity& entity : thread.entities) {
    if (!folds(entity.kind, entity.fields)) continue;
    // Another window on the thread may have held more of it than the cursor says.
    if (entity.run && thread.cursor.floor && *entity.run < *thread.cursor.floor) continue;
    m_entities[entity.kind].insert(entity.id, entity.fields);
  }
  m_cursor = thread.cursor;
  everythingChanged(changedSince(before));
  if (hasEarlier()) emit earlierChanged();
}

void TimelineModel::flush() {
  m_flushTimer.stop();
  const bool all = std::exchange(m_dirtyAll, false);
  const QSet<QPair<QString, QString>> dirty = std::exchange(m_dirty, {});
  const bool cursor = std::exchange(m_cursorDirty, false);
  if (!m_cache || m_cursor.offset < 0 || m_cursor.handle.isEmpty()) return;
  if (!all && !cursor && dirty.isEmpty()) return;
  cache::ThreadUpdate update{m_threadKey, m_cursor, all, {}, {}};
  if (all) {
    for (auto kind = m_entities.cbegin(); kind != m_entities.cend(); ++kind) {
      for (auto it = kind->cbegin(); it != kind->cend(); ++it) update.put.append(cached(kind.key(), it.key(), *it));
    }
  } else {
    for (const auto& [kind, id] : dirty) {
      const QHash<QString, QJsonObject> entities = m_entities.value(kind);
      const auto found = entities.constFind(id);
      if (found == entities.cend()) {
        update.gone.append({kind, id});
      } else {
        update.put.append(cached(kind, id, *found));
      }
    }
  }
  m_cache->storeThread(update);
}

void TimelineModel::park() {
  flush();
  if (!m_cache || m_cursor.offset < 0 || m_cursor.handle.isEmpty()) return;
  // The newest runs of the window that together hold windowItems turn items
  // (HalC2.Streams.View.take_runs); the runs before them leave the copy.
  QHash<QString, int> counts;
  for (const QJsonObject& item : m_entities.value(QStringLiteral("turn-item"))) ++counts[text(item, QLatin1String("runId"))];
  QList<QPair<qint64, QString>> runs;
  const QHash<QString, QJsonObject> held = m_entities.value(QStringLiteral("run"));
  for (auto it = held.cbegin(); it != held.cend(); ++it) {
    const qint64 ordinal = qint64(it->value(QLatin1String("ordinal")).toDouble());
    if (text(*it, QLatin1String("status")) == QLatin1String("rolled_back")) continue;
    if (m_cursor.floor && ordinal < *m_cursor.floor) continue;
    runs.append({ordinal, it.key()});
  }
  std::sort(runs.begin(), runs.end(), std::greater<>());
  int count = 0;
  for (qsizetype i = 0; i + 1 < runs.size(); ++i) {
    count += counts.value(runs.at(i).second);
    if (count < windowItems) continue;
    m_cache->trimThread(m_threadKey, runs.at(i).first);
    return;
  }
}

void TimelineModel::events(const QJsonArray& events) {
  QSet<QString> changed;
  bool structural = false;
  m_turnTouched = false;
  m_checkpointsTouched = false;
  m_agentsTouched = false;
  m_workspaceTouched = false;
  m_reshaped.clear();
  m_agentModels.clear();
  for (const QJsonValue& value : events) {
    const QJsonArray event = value.toArray();
    // An event the copy already holds (a frame sent again on a reconnect) would append its text twice.
    if (m_cursor.offset >= 0 && event.at(0).isDouble() && qint64(event.at(0).toDouble()) <= m_cursor.offset) continue;
    structural |= apply(event.at(1).toString(), event.at(2).toString(), event.at(3).toObject(), changed);
  }
  if (m_turnTouched) emit turnChanged();
  if (m_checkpointsTouched) emit checkpointsChanged();
  if (m_agentsTouched) emit agentsChanged();
  // A subagent's row shows its entity's model, status and latest words.
  if (!m_agentModels.isEmpty()) {
    const QHash<QString, QJsonObject>& items = m_entities[QStringLiteral("turn-item")];
    for (int row = 0; row < m_rows.size(); ++row) {
      const bool group = m_rows.at(row).kind == QLatin1String("subagents");
      if (m_rows.at(row).kind != QLatin1String("subagent") && !group) continue;
      bool moved = false;
      // A group counts its members' states and spans their times.
      for (const QString& member : m_rows.at(row).items) {
        const QString agent = text(items.value(member), QLatin1String("subagentId"));
        const auto was = m_agentModels.constFind(agent);
        if (was == m_agentModels.cend()) continue;
        const QJsonObject now = entity(QStringLiteral("subagent"), agent);
        for (const auto field : {QLatin1String("model"), QLatin1String("status"), QLatin1String("progress"), QLatin1String("result"),
                                 QLatin1String("startedAt"), QLatin1String("completedAt"), QLatin1String("title")}) {
          moved |= was->value(field) != now.value(field);
        }
      }
      if (moved && group) emit dataChanged(index(row), index(row));
      else if (moved) emit dataChanged(index(row), index(row), {ModelRole, StatusRole, StatusLabelRole, TextRole});
    }
  }
  if (m_workspaceTouched) emit workspaceChanged();
  if (structural) {
    restructure(changed);
    return;
  }
  // A row whose items only grew by streamed text says which role that is, so
  // a delta does not make its delegate read every other one again.
  QHash<int, bool> redraw;  // row -> only its text grew
  for (const QString& id : std::as_const(changed)) {
    const int row = m_rowOfItem.value(id, -1);
    if (row < 0 || !shows(m_rows.at(row), id)) continue;
    const bool textOnly = !m_reshaped.contains(id);
    // An open phone group's subagent is also counted by the group above it.
    if (m_rows.at(row).kind == QLatin1String("subagent")) {
      for (int above = row - 1; above >= 0 && m_rows.at(above).kind == QLatin1String("subagent"); --above) {
        if (above > 0 && m_rows.at(above - 1).kind == QLatin1String("subagents") && m_rows.at(above - 1).items.contains(id)) redraw.insert(above - 1, false);
      }
      if (row > 0 && m_rows.at(row - 1).kind == QLatin1String("subagents") && m_rows.at(row - 1).items.contains(id)) redraw.insert(row - 1, false);
    }
    const auto known = redraw.find(row);
    if (known == redraw.end()) {
      redraw.insert(row, textOnly);
    } else {
      *known = *known && textOnly;
    }
  }
  for (auto it = redraw.cbegin(); it != redraw.cend(); ++it) {
    const QString& kind = m_rows.at(it.key()).kind;
    QList<int> roles;
    if (*it && kind == QLatin1String("message")) roles = {TextRole};
    if (*it && kind == QLatin1String("work")) roles = {EntriesRole};
    emit dataChanged(index(it.key()), index(it.key()), roles);
  }
}

QVariantMap TimelineModel::liveEntry(const Row& row) const {
  if (row.kind != QLatin1String("work") || row.items.isEmpty()) return {};
  const bool live = row.live && m_expandedGroups.contains(row.id) == row.startsOpen;
  return entry(entity(QStringLiteral("turn-item"), row.items.last()), live);
}

bool TimelineModel::shows(const Row& row, const QString& item) const {
  // A collapsed work group draws its last entries and, summarized, a summary of all of them.
  if (row.kind != QLatin1String("work") || row.summarized || m_expandedGroups.contains(row.id) != row.startsOpen) return true;
  return row.items.indexOf(item) >= row.items.size() - visibleWorkEntries;
}

bool TimelineModel::apply(const QString& kind, const QString& id, const QJsonObject& patch, QSet<QString>& changed) {
  if (!kKinds.contains(kind)) return false;
  m_dirty.insert({kind, id});
  QHash<QString, QJsonObject>& byKind = m_entities[kind];
  const auto current = byKind.constFind(id);
  const bool existed = current != byKind.cend();
  const std::optional<QJsonObject> next = patched(existed ? *current : QJsonObject(), patch);
  if (kind == QLatin1String("checkpoint") || kind == QLatin1String("subagent")) {
    (kind == QLatin1String("subagent") ? m_agentsTouched : m_checkpointsTouched) = true;
    if (kind == QLatin1String("checkpoint")) m_workspaceTouched = true;
    if (kind == QLatin1String("subagent") && !m_agentModels.contains(id)) m_agentModels.insert(id, existed ? *current : QJsonObject());
    if (next) {
      byKind.insert(id, *next);
    } else {
      byKind.remove(id);
    }
    return false;
  }
  if (kind == QLatin1String("plan") || kind == QLatin1String("message")) {
    // The agent's streamed replies are the turn items'; only the user's
    // messages (a queued run's text) are kept.
    if (kind == QLatin1String("message") && text(next ? *next : QJsonObject(), QLatin1String("role")) != QLatin1String("user")) {
      byKind.remove(id);
      return false;
    }
    m_turnTouched = true;
    if (next) {
      byKind.insert(id, *next);
    } else {
      byKind.remove(id);
    }
    return false;
  }
  if (kind != QLatin1String("turn-item")) {
    m_turnTouched = true;
    // A run rolled back drops its commands from the Agents tab.
    if (kind == QLatin1String("run")) m_agentsTouched = true;
    // Runs, attempts and requests change fold labels, visibility and the
    // working state; they change far less often than items.
    const QJsonValue wasOrdinal = existed ? current->value(QLatin1String("ordinal")) : QJsonValue();
    if (next) {
      byKind.insert(id, *next);
    } else {
      byKind.remove(id);
    }
    // A renumbered run (it took its start ordinal) moves its windowed
    // entities' cached run_ord with it: re-cache them, or restore()/park()
    // would filter and trim by the stale ordinal until they next change.
    if (kind == QLatin1String("run") && existed && next && wasOrdinal != next->value(QLatin1String("ordinal"))) {
      for (const QString& windowed : kWindowed) {
        for (auto it = m_entities[windowed].cbegin(); it != m_entities[windowed].cend(); ++it) {
          if (text(*it, QLatin1String("runId")) == id) m_dirty.insert({windowed, it.key()});
        }
      }
    }
    return true;
  }
  changed.insert(id);
  const QString type = text(next ? *next : existed ? *current : QJsonObject(), QLatin1String("type"));
  if (kTurnItems.contains(type)) m_turnTouched = true;
  if ((type == QLatin1String("command_execution") || type == QLatin1String("file_change")) && !patch.contains(QLatin1String("a"))) {
    m_workspaceTouched = true;
  }
  const bool replaced = patch.value(QLatin1String("d")).toBool();
  // A command or a background tool starting, settling or going away; not its
  // streamed output.
  if ((type == QLatin1String("command_execution") || type == QLatin1String("dynamic_tool")) &&
      (!existed || !next || replaced || patch.contains(QLatin1String("s")) || patch.contains(QLatin1String("u")))) {
    m_agentsTouched = true;
  }
  bool structural = !existed || !next || replaced;
  QStringList fields = patch.value(QLatin1String("s")).toObject().keys();
  for (const QJsonValue& field : patch.value(QLatin1String("u")).toArray()) fields.append(field.toString());
  for (const QString& field : std::as_const(fields)) structural = structural || kStructural.contains(field);
  // On the phone, how a call ends decides whether it is listed and whether the live row thinks.
  static const QSet<QString> ending{QStringLiteral("status"), QStringLiteral("exitCode"), QStringLiteral("outputIndicatesFailure"),
                                    QStringLiteral("output"), QStringLiteral("input")};
  for (const QString& field : std::as_const(fields)) structural = structural || (phone() && ending.contains(field));
  // Anything but text appended to the item as it streams.
  const QJsonObject appended = patch.value(QLatin1String("a")).toObject();
  if (!existed || !next || replaced || !fields.isEmpty() || appended.size() != 1 || !appended.contains(QLatin1String("text"))) {
    m_reshaped.insert(id);
  }
  const bool moves = !existed || !next || replaced || fields.contains(QStringLiteral("ordinal"));
  if (existed && moves) unplace(id);
  if (next) {
    byKind.insert(id, *next);
    if (moves) place(id);
  } else {
    byKind.remove(id);
  }
  return structural;
}

void TimelineModel::place(const QString& itemId) {
  const QHash<QString, QJsonObject>& items = m_entities[QStringLiteral("turn-item")];
  const double ordinal = items.value(itemId).value(QLatin1String("ordinal")).toDouble();
  const auto at = std::lower_bound(m_order.begin(), m_order.end(), itemId, [&](const QString& other, const QString&) {
    const double otherOrdinal = items.value(other).value(QLatin1String("ordinal")).toDouble();
    return otherOrdinal != ordinal ? otherOrdinal < ordinal : other < itemId;
  });
  m_order.insert(at, itemId);
}

void TimelineModel::unplace(const QString& itemId) {
  m_order.removeOne(itemId);
}

// Turn items are shown in ordinal order, as the MC sends them.
void TimelineModel::sortItems() {
  const QHash<QString, QJsonObject> items = m_entities.value(QStringLiteral("turn-item"));
  m_order = items.keys();
  std::sort(m_order.begin(), m_order.end(), [&](const QString& a, const QString& b) {
    const double left = items.value(a).value(QLatin1String("ordinal")).toDouble();
    const double right = items.value(b).value(QLatin1String("ordinal")).toDouble();
    return left != right ? left < right : a < b;
  });
}

// --- The projection ---------------------------------------------------------------

void TimelineModel::restructure(const QSet<QString>& changed) {
  applyRows(project(), changed);
  m_rowOfItem.clear();
  for (int row = 0; row < m_rows.size(); ++row) {
    for (const QString& item : std::as_const(m_rows.at(row).items)) m_rowOfItem.insert(item, row);
    if (!m_rows.at(row).checkpoint.isEmpty()) m_rowOfItem.insert(m_rows.at(row).checkpoint, row);
  }
  updateWorking();
}

QList<TimelineModel::Row> TimelineModel::project() const {
  const QHash<QString, QJsonObject> items = m_entities.value(QStringLiteral("turn-item"));
  const QHash<QString, QJsonObject> runs = m_entities.value(QStringLiteral("run"));

  // Items of a rolled-back run, queued
  // messages of a cancelled run, and the interrupt result a plain steer leaves
  // behind are hidden.
  QSet<QString> superseded;
  for (const QJsonObject& attempt : m_entities.value(QStringLiteral("run-attempt"))) {
    if (text(attempt, QLatin1String("status")) != QLatin1String("superseded")) continue;
    superseded.insert(text(attempt, QLatin1String("runId")) + QLatin1Char('\n') + text(attempt, QLatin1String("rootNodeId")));
  }
  QSet<QString> interruptRequested;
  for (const QJsonObject& item : items) {
    if (text(item, QLatin1String("type")) == QLatin1String("run_interrupt_request")) {
      interruptRequested.insert(text(item, QLatin1String("runId")));
    }
  }
  // The phone (apps/mobile/src/lib/threadActivity.ts): the subagents whose cards
  // the timeline shows, by run, stand in for the calls that delegated them.
  QSet<QString> carded;
  if (phone()) {
    for (const QJsonObject& item : items) {
      if (text(item, QLatin1String("type")) != QLatin1String("subagent") || text(item, QLatin1String("origin")) != QLatin1String("app_owned")) continue;
      carded.insert(text(item, QLatin1String("runId")) + QLatin1Char('\n') + text(item, QLatin1String("subagentId")));
    }
  }
  const auto visible = [&](const QJsonObject& item) {
    const QString runId = text(item, QLatin1String("runId"));
    const QString type = text(item, QLatin1String("type"));
    const QString status = text(runs.value(runId), QLatin1String("status"));
    if (status == QLatin1String("rolled_back")) return false;
    if (phone()) {
      // A call that never said it ended once its turn settled, the
      // workspace's preparation, and a delegation its subagent's card shows.
      if (!m_backgroundWork && kSettled.contains(status) && classify(item) == Kind::Work &&
          text(item, QLatin1String("status")) == QLatin1String("running")) {
        return false;
      }
      if (type == QLatin1String("command_execution") && text(item, QLatin1String("input")) == QLatin1String("Preparing workspace")) return false;
      const QString task = timeline::delegatedTask(item);
      if (!task.isEmpty() && carded.contains(runId + QLatin1Char('\n') + task)) return false;
    }
    if (status == QLatin1String("cancelled") && type == QLatin1String("user_message") &&
        text(item, QLatin1String("inputIntent")) == QLatin1String("queued_turn")) {
      return false;
    }
    return !(type == QLatin1String("run_interrupt_result") && !runId.isEmpty() &&
             superseded.contains(runId + QLatin1Char('\n') + text(item, QLatin1String("nodeId"))) &&
             !interruptRequested.contains(runId));
  };

  // The thread's latest run, as the MC's (HalC2.Projection.Shell.latest_run/1): a
  // run held for the user that never started (still queued, or cancelled while
  // held) waits numbered above the run that passed it. Equal ordinals (legacy runs
  // stored without one read 0) go to the later-starting run for runs with an item
  // here: a run is as new as its first item in timeline order. That is start
  // order, where the MC's tie-break is newest *made*; for legacy ties where a
  // later-made run passed an earlier-made one the two can disagree on the pick.
  // Runs
  // with no item here (none created yet, or outside the window) are settled by id
  // instead, where the MC would take the newest made; the pick never depends on
  // hash order either way. The item index is built only when the highest ordinal
  // actually ties, so the common case is one pass over the runs.
  QString latestRun;
  double latestOrdinal = -1;
  bool latestTied = false;
  for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
    if (heldNeverStarted(*it)) continue;
    const double ordinal = it->value(QLatin1String("ordinal")).toDouble();
    if (ordinal > latestOrdinal) {
      latestOrdinal = ordinal;
      latestRun = it.key();
      latestTied = false;
    } else if (ordinal == latestOrdinal) {
      latestTied = true;
    }
  }
  if (latestTied) {
    QHash<QString, int> firstItem;
    for (int i = 0; i < m_order.size(); ++i) {
      const QString runId = text(items.value(m_order.at(i)), QLatin1String("runId"));
      if (!runId.isEmpty() && !firstItem.contains(runId)) firstItem.insert(runId, i);
    }
    int latestFirst = -1;
    for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
      if (heldNeverStarted(*it) || it->value(QLatin1String("ordinal")).toDouble() != latestOrdinal) continue;
      const int first = firstItem.value(it.key(), -1);
      if (first > latestFirst || (first == latestFirst && it.key() > latestRun)) {
        latestFirst = first;
        latestRun = it.key();
      }
    }
  }

  // Each run's items after the user message that started it.
  struct Turn {
    QStringList items;
    QString first;       // its first assistant message
    QString terminal;    // its last assistant message
    QString checkpoint;  // its latest checkpoint with files
    bool streaming = false;
    QDateTime boundary;
  };
  QList<QJsonObject> shown;
  QHash<QString, Turn> turns;
  QList<QString> turnOrder;
  QSet<QString> asked;  // runs whose opening message came by
  QDateTime boundary;
  for (const QString& id : m_order) {
    const QJsonObject item = items.value(id);
    if (!visible(item)) continue;
    shown.append(item);
    const QString type = text(item, QLatin1String("type"));
    const QString runId = text(item, QLatin1String("runId"));
    // A run begins at the user's message, or at what the MC sent in its place:
    // a notification ahead of everything else of its run.
    if (type == QLatin1String("user_message") ||
        (type == QLatin1String("notification") && !runId.isEmpty() && !asked.contains(runId) && !turns.contains(runId))) {
      asked.insert(runId);
      boundary = timeOf(item.value(QLatin1String("startedAt")));
      if (!boundary.isValid()) boundary = timeOf(item.value(QLatin1String("updatedAt")));
      continue;
    }
    if (runId.isEmpty()) continue;
    if (!turns.contains(runId)) {
      turns[runId].boundary = std::exchange(boundary, QDateTime());
      turnOrder.append(runId);
    }
    Turn& turn = turns[runId];
    turn.items.append(id);
    if (type == QLatin1String("assistant_message")) {
      if (turn.first.isEmpty()) turn.first = id;
      turn.terminal = id;
      turn.streaming = turn.streaming || item.value(QLatin1String("streaming")).toBool();
    } else if (type == QLatin1String("checkpoint") && !item.value(QLatin1String("files")).toArray().isEmpty()) {
      turn.checkpoint = id;
    }
  }

  // A settled turn folds its work (tool calls, commentary) behind how long it
  // took, leaving its last reply in view.
  struct Fold {
    QString runId;
    QString label;
    int hidden = 0;
    bool open = false;
    QDateTime at;
  };
  QHash<QString, Fold> foldAt;  // by the turn's first item
  QHash<QString, QString> folded;  // hidden item -> run
  const bool phone = m_folds == Folds::Phone;
  const auto failed = [&](const QString& runId) {
    return text(runs.value(runId), QLatin1String("status")) == QLatin1String("failed");
  };
  for (const QString& runId : std::as_const(turnOrder)) {
    const Turn& turn = turns[runId];
    const QJsonObject run = runs.value(runId);
    const QString status = text(run, QLatin1String("status"));
    if (!kSettled.contains(status) || turn.streaming || (phone && failed(runId))) continue;
    QStringList hidden;
    for (const QString& id : turn.items) {
      if (id == turn.terminal || (phone && id == turn.first)) continue;
      const Kind kind = classify(items.value(id));
      // Work a turn left running (a background command) stays in view.
      if (kind == Kind::Work && text(items.value(id), QLatin1String("status")) == QLatin1String("running")) continue;
      if (kind == Kind::Work || kind == Kind::Message) hidden.append(id);
    }
    if (hidden.isEmpty()) continue;
    const bool interrupted = runId == latestRun && status == QLatin1String("interrupted");
    const QDateTime started = timeOf(run.value(QLatin1String("startedAt")));
    const QDateTime completed = timeOf(run.value(QLatin1String("completedAt")));
    std::optional<qint64> elapsed;
    if (started.isValid() && completed.isValid()) {
      elapsed = started.msecsTo(completed);
    } else if (!interrupted) {
      // No run times: from the user's message to the last item's update.
      const QJsonObject first = items.value(turn.items.first());
      QDateTime from = turn.boundary.isValid() ? turn.boundary : timeOf(first.value(QLatin1String("startedAt")));
      QDateTime to;
      for (const QString& id : turn.items) to = std::max(to, timeOf(items.value(id).value(QLatin1String("updatedAt"))));
      if (from.isValid() && to.isValid()) elapsed = std::max<qint64>(0, from.msecsTo(to));
    }
    // A run stopped before it started has no duration.
    QString label;
    if (interrupted) {
      label = elapsed ? QStringLiteral("You stopped after %1").arg(formatDuration(*elapsed))
                      : QStringLiteral("You stopped this response");
    } else {
      label = elapsed ? QStringLiteral("Worked for %1").arg(formatDuration(*elapsed)) : QStringLiteral("Worked");
    }
    const bool open = m_expandedFolds.contains(runId) != m_keptOpen.contains(runId);
    // A turn fold reads the user's message's time, else its first item's.
    const QDateTime at = turn.boundary.isValid() ? turn.boundary : itemTime(items.value(turn.items.first()));
    foldAt.insert(turn.items.first(), {runId, label, int(hidden.size()), open, at});
    if (!open) {
      for (const QString& id : std::as_const(hidden)) folded.insert(id, runId);
    }
  }

  // Once a turn settles, the threads it created are listed after its last
  // reply as cards (upstream's resource summaries) in place of their markers.
  QHash<QString, QStringList> created;  // by run
  if (!phone) {
    for (const QJsonObject& item : std::as_const(shown)) {
      const QString runId = text(item, QLatin1String("runId"));
      const Turn turn = turns.value(runId);
      if (text(item, QLatin1String("type")) != QLatin1String("thread_created") || turn.terminal.isEmpty() || turn.streaming ||
          !kSettled.contains(text(runs.value(runId), QLatin1String("status")))) {
        continue;
      }
      created[runId].append(text(item, QLatin1String("id")));
    }
  }
  // A fork's history ends at a marker of where it was forked from, which
  // HAL-C2 adds (HalC2.Projection.Timeline.fork_marker/3).
  const QSet<QString> inherited = phone ? QSet<QString>() : inheritedRuns();
  qsizetype lastInherited = -1;
  for (qsizetype i = 0; i < shown.size(); ++i) {
    if (inherited.contains(text(shown.at(i), QLatin1String("runId")))) lastInherited = i;
  }

  QList<Row> rows;
  for (qsizetype i = 0; i < shown.size();) {
    const QJsonObject& item = shown.at(i);
    const QString id = text(item, QLatin1String("id"));
    if (i == lastInherited + 1 && lastInherited >= 0) {
      rows.append({forkMarkerId(), QStringLiteral("marker")});
    }
    if (const auto fold = foldAt.constFind(id); fold != foldAt.cend()) {
      rows.append({QStringLiteral("fold:") + fold->runId, QStringLiteral("fold"), {}, {}, fold->label, fold->hidden,
                   fold->open, fold->at});
    }
    const Kind kind = classify(item);
    if (folded.contains(id) || kind == Kind::Checkpoint) {
      ++i;
      continue;
    }
    const QString runId = text(item, QLatin1String("runId"));
    if (kind == Kind::Work) {
      // Consecutive calls of one turn make a group.
      Row row{QStringLiteral("work:") + id, QStringLiteral("work")};
      qsizetype next = i;
      for (; next < shown.size(); ++next) {
        const QJsonObject& call = shown.at(next);
        const QString callId = text(call, QLatin1String("id"));
        if (next > i && foldAt.contains(callId)) break;
        const Kind callKind = classify(call);
        if (callKind == Kind::Checkpoint) continue;
        if (callKind != Kind::Work || folded.contains(callId) || text(call, QLatin1String("runId")) != runId) break;
        row.items.append(callId);
        // On the phone a failed turn shows each call on its own row.
        if (phone && failed(runId)) {
          ++next;
          break;
        }
      }
      row.live = !kSettled.contains(text(runs.value(runId), QLatin1String("status")));
      row.summarized = row.items.size() > 1 && !row.live;
      row.startsOpen = m_keptOpen.contains(runId);
      rows.append(row);
      i = next;
      continue;
    }
    // Subagents one turn started together are one group that opens to their
    // rows (V2SubagentGroup, thread-subagent-group.tsx); a lone one is its own row.
    if (kind == Kind::Subagent) {
      const QString turnId = text(item, QLatin1String("providerTurnId"));
      QStringList members;
      qsizetype next = i;
      for (; next < shown.size(); ++next) {
        const QJsonObject& other = shown.at(next);
        const QString otherId = text(other, QLatin1String("id"));
        if (next > i && foldAt.contains(otherId)) break;
        const Kind otherKind = classify(other);
        if (otherKind == Kind::Checkpoint) continue;
        if (otherKind != Kind::Subagent || folded.contains(otherId) || text(other, QLatin1String("runId")) != runId ||
            text(other, QLatin1String("providerTurnId")) != turnId) {
          break;
        }
        members.append(otherId);
      }
      if (members.size() > 1) {
        const QString group = QStringLiteral("subagents:") + id;
        const bool open = m_openSubagentGroups.contains(group);
        rows.append({group, QStringLiteral("subagents"), members, {}, {}, 0, open});
        if (open) {
          for (const QString& member : std::as_const(members)) rows.append({member, QStringLiteral("subagent"), {member}});
        }
        i = next;
        continue;
      }
    }
    if (text(item, QLatin1String("type")) == QLatin1String("thread_created") && created.contains(runId)) {
      ++i;
      continue;
    }
    Row row{id, kindName(kind), {id}};
    if (kind == Kind::Message && !runId.isEmpty() && turns.value(runId).terminal == id) {
      const Turn& turn = turns[runId];
      row.checkpoint = turn.checkpoint;
      row.meta = !turn.streaming && kSettled.contains(text(runs.value(runId), QLatin1String("status")));
    }
    rows.append(row);
    ++i;
    if (row.meta) {
      for (const QString& thread : created.value(runId)) rows.append({QStringLiteral("summary:") + thread, QStringLiteral("resource"), {thread}});
    }
  }
  if (lastInherited == shown.size() - 1 && lastInherited >= 0) rows.append({forkMarkerId(), QStringLiteral("marker")});
  // On the phone, a running turn ends in one live row: its latest call when that
  // says what the agent is doing (still running, or done without failing), a
  // reply it is writing or a compaction under way, else that it is thinking.
  if (phone && kRunning.contains(text(runs.value(latestRun), QLatin1String("status")))) {
    bool told = false;
    if (!rows.isEmpty() && !rows.last().items.isEmpty()) {
      const QJsonObject last = items.value(rows.last().items.last());
      const QString type = text(last, QLatin1String("type"));
      const QString status = text(last, QLatin1String("status"));
      if (text(last, QLatin1String("runId")) != latestRun) {
        told = false;
      } else if (rows.last().kind == QLatin1String("work")) {
        told = status == QLatin1String("running") || (status == QLatin1String("completed") && !timeline::callFailed(last));
      } else {
        told = (type == QLatin1String("assistant_message") && last.value(QLatin1String("streaming")).toBool()) ||
               (type == QLatin1String("compaction") && status == QLatin1String("running"));
      }
    }
    if (!told) rows.append({QStringLiteral("thinking:") + latestRun, QStringLiteral("thinking")});
  }
  return rows;
}

// Brings the rows in line with `rows` by id: removes, inserts and moves them,
// and redraws the ones whose shape or items changed.
void TimelineModel::applyRows(const QList<Row>& rows, const QSet<QString>& changed) {
  const qsizetype before = m_rows.size();
  QSet<QString> wanted;
  for (const Row& row : rows) wanted.insert(row.id);
  for (qsizetype last = m_rows.size() - 1; last >= 0; --last) {
    if (wanted.contains(m_rows.at(last).id)) continue;
    qsizetype first = last;
    while (first > 0 && !wanted.contains(m_rows.at(first - 1).id)) --first;
    beginRemoveRows(QModelIndex(), int(first), int(last));
    m_rows.remove(first, last - first + 1);
    endRemoveRows();
    last = first;
  }
  QSet<QString> present;
  for (const Row& row : std::as_const(m_rows)) present.insert(row.id);
  const auto dirty = [&](const Row& row) {
    for (const QString& item : row.items) {
      if (changed.contains(item) && shows(row, item)) return true;
    }
    return !row.checkpoint.isEmpty() && changed.contains(row.checkpoint);
  };
  for (qsizetype i = 0; i < rows.size();) {
    const Row& want = rows.at(i);
    if (!present.contains(want.id)) {
      qsizetype last = i;
      while (last + 1 < rows.size() && !present.contains(rows.at(last + 1).id)) ++last;
      beginInsertRows(QModelIndex(), int(i), int(last));
      for (qsizetype k = i; k <= last; ++k) m_rows.insert(k, rows.at(k));
      endInsertRows();
      i = last + 1;
      continue;
    }
    if (m_rows.at(i).id != want.id) {
      qsizetype from = i + 1;
      while (m_rows.at(from).id != want.id) ++from;
      beginMoveRows(QModelIndex(), int(from), int(from), QModelIndex(), int(i));
      m_rows.move(from, i);
      endMoveRows();
    }
    // A turn settling ends its live call, which redraws only if that changes
    // how the call reads.
    Row unlive = want;
    unlive.live = m_rows.at(i).live;
    const bool relabelled = unlive.live != want.live && liveEntry(unlive) != liveEntry(want);
    if (m_rows.at(i) != unlive || relabelled || dirty(want)) {
      m_rows[i] = want;
      emit dataChanged(index(int(i)), index(int(i)));
    } else {
      m_rows[i] = want;
    }
    ++i;
  }
  if (m_rows.size() != before) emit countChanged();
}

// The thread works while a run is under way, since the earliest one started.
void TimelineModel::updateWorking() {
  QDateTime since;
  for (const QJsonObject& run : m_entities.value(QStringLiteral("run"))) {
    if (!kRunning.contains(text(run, QLatin1String("status")))) continue;
    // From when the run began, or from the message that asked for it while its
    // session starts (deriveActiveWorkStartedAt). Not requestedAt once begun: a
    // queued message keeps the time it was queued.
    QDateTime started = timeOf(run.value(QLatin1String("startedAt")));
    if (!started.isValid()) started = timeOf(run.value(QLatin1String("requestedAt")));
    if (!started.isValid()) started = m_now();
    if (!since.isValid() || started < since) since = started;
  }
  if (since == m_workingSince) return;
  m_workingSince = since;
  emit workingChanged();
}

void TimelineModel::keepOpen(const QString& runId) {
  if (runId.isEmpty() || m_keptOpen.contains(runId)) return;
  m_keptOpen.insert(runId);
  restructure({});
}

void TimelineModel::toggle(const QString& rowId) {
  if (rowId.startsWith(QLatin1String("subagents:"))) {
    if (!m_openSubagentGroups.remove(rowId)) m_openSubagentGroups.insert(rowId);
    restructure({});
    return;
  }
  if (rowId.startsWith(QLatin1String("fold:"))) {
    const QString runId = rowId.mid(5);
    if (!m_expandedFolds.remove(runId)) m_expandedFolds.insert(runId);
    restructure({});
    return;
  }
  const int row = indexOf(rowId);
  // A work group opens to its calls, a long plan to its whole text.
  const QString kind = row < 0 ? QString() : m_rows.at(row).kind;
  if (kind != QLatin1String("work") && kind != QLatin1String("plan")) return;
  if (!m_expandedGroups.remove(rowId)) m_expandedGroups.insert(rowId);
  emit dataChanged(index(row), index(row), {EntriesRole, HiddenCountRole, ExpandedRole});
}

int TimelineModel::indexOf(const QString& rowId) const {
  for (int row = 0; row < m_rows.size(); ++row) {
    if (m_rows.at(row).id == rowId) return row;
  }
  return -1;
}

QString TimelineModel::copy(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0 || m_rows.at(at).kind != QLatin1String("message")) return QStringLiteral("The message is no longer shown.");
  const QString text = data(index(at), TextRole).toString();
  if (m_writeClipboard) return m_writeClipboard(text) ? QString() : QStringLiteral("The clipboard could not be written.");
  QClipboard* clipboard = QGuiApplication::clipboard();
  if (!clipboard) return QStringLiteral("This system has no clipboard.");
  clipboard->setText(text);
  return {};
}

QString TimelineModel::finishedRunOf(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0) return {};
  const Row& row = m_rows.at(at);
  if (row.kind != QLatin1String("message") || row.items.isEmpty()) return {};
  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.constFirst());
  if (text(item, QLatin1String("type")) != QLatin1String("assistant_message")) return {};
  const QString runId = text(item, QLatin1String("runId"));
  return text(entity(QStringLiteral("run"), runId), QLatin1String("status")) == QLatin1String("completed") ? runId : QString();
}

QVariantMap TimelineModel::rewindPointOf(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0) return {};
  const Row& row = m_rows.at(at);
  if (row.kind != QLatin1String("message") || row.items.isEmpty()) return {};
  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.constFirst());
  if (text(item, QLatin1String("type")) != QLatin1String("user_message")) return {};
  const QString runId = text(item, QLatin1String("runId"));
  const auto runs = m_entities.value(QStringLiteral("run"));
  const auto checkpoints = m_entities.value(QStringLiteral("checkpoint"));
  // The turn's number: its checkpoint's diff turn, else its place among the
  // runs that started and are still shown.
  int turn = diffTurnOf(checkpoints, runs, runId);
  const double ordinal = runs.value(runId).value(QLatin1String("ordinal")).toDouble();
  if (turn <= 0) {
    for (auto other = runs.cbegin(); other != runs.cend(); ++other) {
      if (other->value(QLatin1String("ordinal")).toDouble() > ordinal || text(*other, QLatin1String("status")) == QLatin1String("rolled_back")) continue;
      if (other.key() == runId || everStarted(*other)) ++turn;
    }
  }
  QVariantMap point{{QStringLiteral("turn"), turn},
                    {QStringLiteral("text"), text(item, QLatin1String("text"))},
                    {QStringLiteral("attachments"), item.value(QLatin1String("attachments")).toArray().toVariantList()}};
  // The checkpoint to rewind to: the last counted one before this run (a run
  // number one less is not it when a rewound or unfinished run sits between).
  for (const auto& [id, checkpoint] : diffCheckpoints(checkpoints, runs)) {
    const auto countedRun = runs.constFind(text(checkpoint, QLatin1String("runId")));
    const double countedOrdinal = countedRun != runs.constEnd() ? countedRun->value(QLatin1String("ordinal")).toDouble()
                                                                 : checkpoint.value(QLatin1String("appRunOrdinal")).toDouble();
    if (countedOrdinal >= ordinal) break;
    point.insert(QStringLiteral("checkpointId"), id);
    point.insert(QStringLiteral("scopeId"), text(checkpoint, QLatin1String("scopeId")));
  }
  if (!point.contains(QStringLiteral("checkpointId")) && turn == 1) {
    for (auto it = checkpoints.cbegin(); it != checkpoints.cend(); ++it) {
      if (text(*it, QLatin1String("status")) != QLatin1String("ready") || it->value(QLatin1String("appRunOrdinal")).toInt() != 0) continue;
      // Before the first turn it is the thread's baseline, which has no turn.
      if (it->value(QLatin1String("appRunOrdinal")).isDouble() || text(*it, QLatin1String("runId")) != runId) continue;
      point.insert(QStringLiteral("checkpointId"), it.key());
      point.insert(QStringLiteral("scopeId"), text(*it, QLatin1String("scopeId")));
    }
  }
  return point;
}

QVariantMap TimelineModel::checkpointOf(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0) return {};
  const Row& row = m_rows.at(at);
  const bool work = row.kind == QLatin1String("work");
  if ((row.kind != QLatin1String("message") && !work) || row.items.isEmpty()) return {};
  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.constFirst());
  if (!work && text(item, QLatin1String("type")) != QLatin1String("assistant_message")) return {};
  const QString runId = text(item, QLatin1String("runId"));
  const QJsonObject run = entity(QStringLiteral("run"), runId);
  if (!kSettled.contains(text(run, QLatin1String("status")))) return {};
  const auto checkpoints = m_entities.value(QStringLiteral("checkpoint"));
  for (auto it = checkpoints.cbegin(); it != checkpoints.cend(); ++it) {
    if (text(*it, QLatin1String("runId")) != runId || text(*it, QLatin1String("status")) != QLatin1String("ready")) continue;
    // The MC's turn number (the diff panel's). A ready checkpoint that does
    // not count as a diff turn (its run never completed) has no point at
    // all: its callers read turn 0 as "the shown or latest turn", so Revert
    // and Open diff would act on a different turn.
    const int turn = diffTurnOf(checkpoints, m_entities.value(QStringLiteral("run")), runId);
    if (turn <= 0) return {};
    return {{QStringLiteral("checkpointId"), it.key()},
            {QStringLiteral("scopeId"), text(*it, QLatin1String("scopeId"))},
            {QStringLiteral("turn"), turn}};
  }
  return {};
}

void TimelineModel::loadAttachment(const QString& id) {
  const auto known = m_attachmentUrls.constFind(id);
  if (known != m_attachmentUrls.cend() && (!known->expiresAt.isValid() || known->expiresAt > m_now())) return;
  m_attachmentUrls.insert(id, {});
  emit attachmentWanted(id);
}

QUrl TimelineModel::attachmentAddress(const QString& id) const {
  const AttachmentUrl known = m_attachmentUrls.value(id);
  return known.expiresAt > m_now() ? known.url : QUrl();
}

void TimelineModel::setAttachmentUrl(const QString& id, const QUrl& url, const QDateTime& expiresAt) {
  emit attachmentSigned(id, url);
  if (url.isEmpty()) {
    m_attachmentUrls.remove(id);
    return;
  }
  const AttachmentUrl was = m_attachmentUrls.value(id);
  m_attachmentUrls.insert(id, {url, expiresAt});
  const bool icon = id.startsWith(QLatin1String("native-app-icon:"));
  if (icon || id.startsWith(QLatin1String("workspace-file:"))) {
    // An app's icon or an image a call viewed: the work groups with a call on
    // screen that shows it, unless its address is the one they already show.
    if (was.url == url && was.expiresAt > m_now()) return;
    const QString key = icon ? QStringLiteral("iconId") : QStringLiteral("imageId");
    for (int row = 0; row < m_rows.size(); ++row) {
      if (m_rows.at(row).kind != QLatin1String("work")) continue;
      const QVariantList entries = data(index(row), EntriesRole).toList();
      if (std::any_of(entries.cbegin(), entries.cend(), [&](const QVariant& entry) { return entry.toMap().value(key) == id; })) {
        emit dataChanged(index(row), index(row), {EntriesRole});
      }
    }
    return;
  }
  for (int row = 0; row < m_rows.size(); ++row) {
    if (m_rows.at(row).kind != QLatin1String("message")) continue;
    const QJsonArray attachments =
        entity(QStringLiteral("turn-item"), m_rows.at(row).items.value(0)).value(QLatin1String("attachments")).toArray();
    for (const QJsonValue& attachment : attachments) {
      if (text(attachment.toObject(), QLatin1String("id")) != id) continue;
      emit dataChanged(index(row), index(row), {AttachmentsRole});
      return;
    }
  }
}

QString TimelineModel::accessJson(const QString& id, const QJsonObject& tree) const {
  auto known = m_accessJson.find(id);
  if (known == m_accessJson.end()) known = m_accessJson.insert(id, QString::fromUtf8(QJsonDocument(tree).toJson()));
  return *known;
}

// --- Rows --------------------------------------------------------------------------

int TimelineModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QHash<int, QByteArray> TimelineModel::roleNames() const {
  return {
      {IdRole, "rowId"},         {KindRole, "kind"},         {AuthorRole, "author"},
      {TextRole, "text"},        {StreamingRole, "streaming"}, {TitleRole, "title"},
      {StatusRole, "status"},    {StatusLabelRole, "statusLabel"}, {MarkerRole, "marker"},
      {EntriesRole, "entries"},  {HiddenCountRole, "hiddenCount"}, {ExpandedRole, "expanded"},
      {FilesRole, "files"},      {TimeRole, "time"},         {IconRole, "icon"},
      {IntentRole, "intent"},    {AttributionRole, "attribution"}, {MetaRole, "meta"},
      {SummaryRole, "summary"},  {SummaryFailedRole, "summaryFailed"}, {ThreadRole, "thread"},
      {ModelRole, "agentModel"}, {PullRequestUrlRole, "pullRequestUrl"},
      {MessageIdRole, "messageId"},
      {AttachmentsRole, "attachments"},
      {SentFilesRole, "sentFiles"},
      {WarningRole, "warning"},
      {PreviewRole, "preview"},
      {ActionRole, "action"},
      {VisibilityRole, "visibility"},
      {SourceRole, "source"},
      {HandoffRole, "handoff"},
      {AvatarsRole, "avatars"},
      {MoreRole, "more"},
      {SpanRole, "span"}, {ScheduledTaskRole, "scheduledTask"},
  };
}

// One tool call of a work group (apps/tui/src/orchestrationV2Adapter.ts itemSummary).
QVariantMap TimelineModel::entry(const QJsonObject& item, bool live) const {
  const QString type = text(item, QLatin1String("type"));
  const QString status = text(item, QLatin1String("status"));
  const QString title = text(item, QLatin1String("title")).trimmed();
  QVariantMap entry{
      {QStringLiteral("id"), text(item, QLatin1String("id"))},
      {QStringLiteral("type"), type},
      {QStringLiteral("status"), status},
      // A call the provider finished whose result says it failed reads as failed.
      {QStringLiteral("statusLabel"), status == QLatin1String("completed") && timeline::callFailed(item) ? QStringLiteral("Failed")
                                                                                                         : callStatusLabel(status)},
      {QStringLiteral("icon"), iconOf(item)},
      {QStringLiteral("time"), stamp(itemTime(item))},
  };
  // A website's, an integration's or an app's own icon, drawn over the kind's
  // until it loads (ToolActivityIconView): an address for each appearance, or
  // an app's icon the environment serves, signed like an attachment.
  QJsonObject toolIcon = item.value(QLatin1String("toolIcon")).toObject();
  if (toolIcon.isEmpty()) toolIcon = item.value(QLatin1String("toolSource")).toObject().value(QLatin1String("icon")).toObject();
  const QString iconTag = text(toolIcon, QLatin1String("_tag"));
  if (iconTag == QLatin1String("website")) {
    entry.insert(QStringLiteral("iconUrl"), websiteIconUrl(toolIcon, false));
    entry.insert(QStringLiteral("iconUrlDark"), websiteIconUrl(toolIcon, true));
  } else if (iconTag == QLatin1String("themed-logo")) {
    const QString light = explicitIconUrl(toolIcon.value(QLatin1String("logoUrl")));
    const QString dark = explicitIconUrl(toolIcon.value(QLatin1String("logoUrlDark")));
    entry.insert(QStringLiteral("iconUrl"), light);
    entry.insert(QStringLiteral("iconUrlDark"), dark.isEmpty() ? light : dark);
  } else if (iconTag == QLatin1String("native-app") && toolIcon.value(QLatin1String("app")).isObject()) {
    const QString id = QStringLiteral("native-app-icon:") +
                       QString::fromUtf8(QJsonDocument(toolIcon.value(QLatin1String("app")).toObject()).toJson(QJsonDocument::Compact));
    const AttachmentUrl known = m_attachmentUrls.value(id);
    const QString signedUrl = known.expiresAt > m_now() ? known.url.toString() : QString();
    entry.insert(QStringLiteral("iconId"), id);
    entry.insert(QStringLiteral("iconUrl"), signedUrl);
    entry.insert(QStringLiteral("iconUrlDark"), signedUrl);
  }
  QString label;
  QString detail;
  if (type == QLatin1String("reasoning")) {
    const bool thinking = item.value(QLatin1String("streaming")).toBool() || status == QLatin1String("running");
    detail = text(item, QLatin1String("text"));
    const QString line = thinking ? QString() : thoughtLine(detail);
    label = thinking ? QStringLiteral("Thinking") : line.isEmpty() ? QStringLiteral("Thought") : line;
  } else if (type == QLatin1String("command_execution")) {
    const QString command = timeline::commandDisplayText(text(item, QLatin1String("input")));
    label = command.isEmpty() ? QStringLiteral("Ran command") : command;
    if (live) {
      // The running turn's latest command, named by its program and how it went.
      const QString ended = entry.value(QStringLiteral("statusLabel")).toString();
      const QString program = timeline::commandProgramName(text(item, QLatin1String("input")));
      label = (ended.isEmpty() ? QStringLiteral("Ran") : ended) + QLatin1Char(' ') + (program.isEmpty() ? QStringLiteral("command") : program);
    }
    detail = text(item, QLatin1String("output"));
    // An output that only echoes the command says nothing new.
    if (repeatsCommand(detail, {text(item, QLatin1String("input")), command})) detail.clear();
    entry.insert(QStringLiteral("command"), text(item, QLatin1String("input")));
    const QJsonValue exitCode = item.value(QLatin1String("exitCode"));
    if (exitCode.isDouble()) entry.insert(QStringLiteral("exitCode"), exitCode.toInt());
  } else if (type == QLatin1String("file_change")) {
    const QString root = m_workspaceRoot ? m_workspaceRoot() : QString();
    label = workspacePath(text(item, QLatin1String("fileName")), root);
    entry.insert(QStringLiteral("path"), text(item, QLatin1String("fileName")));
    // The turn's diff names it as the checkpoint does: relative to the project.
    entry.insert(QStringLiteral("diffPath"), label);
    const QJsonValue additions = item.value(QLatin1String("additions"));
    const QJsonValue deletions = item.value(QLatin1String("deletions"));
    if (additions.isDouble() || deletions.isDouble()) {
      entry.insert(QStringLiteral("additions"), additions.toInt());
      entry.insert(QStringLiteral("deletions"), deletions.toInt());
    }
    // What each change did, a rename with where the file came from.
    QStringList changes;
    for (const QJsonValue& value : item.value(QLatin1String("changes")).toArray()) {
      const QJsonObject change = value.toObject();
      const QString from = text(change, QLatin1String("oldPath"));
      changes.append(QStringLiteral("%1 %2%3").arg(text(change, QLatin1String("operation")),
                                                   from.isEmpty() ? QString() : workspacePath(from, root) + QStringLiteral(" → "),
                                                   workspacePath(text(change, QLatin1String("path")), root)));
    }
    entry.insert(QStringLiteral("changes"), changes);
  } else if (type == QLatin1String("file_search")) {
    // What it looked for; a read's file (an ACP agent's `read`).
    label = timeline::isFileRead(item) ? QStringLiteral("Read file") : QStringLiteral("Searched files");
    detail = text(item, QLatin1String("pattern"));
    // Where each match is, as "path:line:column", with its line.
    const QString root = m_workspaceRoot ? m_workspaceRoot() : QString();
    QVariantList matches;
    for (const QJsonValue& value : item.value(QLatin1String("results")).toArray()) {
      const QJsonObject result = value.toObject();
      QString location = workspacePath(text(result, QLatin1String("fileName")), root);
      if (const QJsonValue line = result.value(QLatin1String("line")); line.isDouble()) {
        location += QStringLiteral(":%1").arg(line.toInt());
        if (const QJsonValue column = result.value(QLatin1String("column")); column.isDouble()) location += QStringLiteral(":%1").arg(column.toInt());
      }
      matches.append(QVariantMap{{QStringLiteral("location"), location}, {QStringLiteral("preview"), text(result, QLatin1String("preview")).trimmed()}});
    }
    entry.insert(QStringLiteral("matches"), matches);
  } else if (type == QLatin1String("web_search")) {
    label = QStringLiteral("Searched the web");
    QStringList patterns;
    for (const QJsonValue& pattern : item.value(QLatin1String("patterns")).toArray()) patterns.append(pattern.toString());
    detail = patterns.join(QLatin1Char('\n'));
    // A result links to its page only at a web address; any other stays text.
    QVariantList results;
    for (const QJsonValue& value : item.value(QLatin1String("results")).toArray()) {
      const QJsonObject result = value.toObject();
      const QString title = text(result, QLatin1String("title")).trimmed();
      const QString address = text(result, QLatin1String("url")).trimmed();
      results.append(QVariantMap{
          {QStringLiteral("title"), !title.isEmpty() ? title : !address.isEmpty() ? address : QStringLiteral("Search result")},
          {QStringLiteral("url"), safeWebAddress(address)},
      });
    }
    entry.insert(QStringLiteral("results"), results);
  } else if (type == QLatin1String("dynamic_tool")) {
    label = item.value(QLatin1String("toolName")).toString(QStringLiteral("Used tool"));
    if (const QString name = timeline::halC2ToolDisplayName(label); !name.isEmpty()) label = name;
    // Its input; a result's body is not shown (docs/user/activity-log.md).
    if (const QJsonValue input = item.value(QLatin1String("input")); input.isObject() && !input.toObject().isEmpty()) {
      detail = QString::fromUtf8(QJsonDocument(input.toObject()).toJson(QJsonDocument::Indented)).trimmed();
    } else if (input.isString()) {
      detail = input.toString();
    }
    // An image the agent looked at: shown only from the workspace, else its path.
    if (const QString viewed = text(item, QLatin1String("viewedImagePath")); !viewed.isEmpty()) {
      const QString image = workspaceImage(viewed, m_workspaceRoot ? m_workspaceRoot() : QString());
      entry.insert(QStringLiteral("viewedPath"), viewed);
      if (!image.isEmpty()) {
        const QString id = QStringLiteral("workspace-file:") + image;
        const AttachmentUrl known = m_attachmentUrls.value(id);
        entry.insert(QStringLiteral("imageId"), id);
        entry.insert(QStringLiteral("imageUrl"), known.expiresAt > m_now() ? known.url : QUrl());
      }
    }
  } else if (type == QLatin1String("approval_request") || type == QLatin1String("user_input_request")) {
    // Answered in the composer (ComposerController); the row records the ask.
    const bool approval = type == QLatin1String("approval_request");
    label = approval ? QStringLiteral("Approval requested") : QStringLiteral("Input requested");
    if (approval) {
      detail = text(item, QLatin1String("prompt"));
    } else {
      QStringList questions;
      for (const QJsonValue& question : item.value(QLatin1String("questions")).toArray()) {
        questions.append(text(question.toObject(), QLatin1String("question")));
      }
      detail = questions.join(QLatin1Char('\n'));
      // Answered: what the user said.
      if (const QJsonValue answer = item.value(QLatin1String("questionAnswer")); answer.isObject()) {
        entry.insert(QStringLiteral("preview"), answerPreview(answer.toObject()));
      }
    }
    const QJsonObject request = entity(QStringLiteral("runtime-request"), text(item, QLatin1String("requestId")));
    if (text(request, QLatin1String("decision")) == QLatin1String("decline")) {
      entry.insert(QStringLiteral("statusLabel"), QStringLiteral("Declined"));
    } else if (text(request, QLatin1String("status")) == QLatin1String("pending")) {
      entry.insert(QStringLiteral("statusLabel"), approval ? QStringLiteral("Waiting for approval") : QStringLiteral("Waiting for an answer"));
    }
  } else if (type == QLatin1String("todo_list")) {
    label = QStringLiteral("Updated plan");
    QStringList steps;
    for (const QJsonValue& step : item.value(QLatin1String("steps")).toArray()) {
      const bool done = text(step.toObject(), QLatin1String("status")) == QLatin1String("completed");
      steps.append((done ? QStringLiteral("✓ ") : QStringLiteral("○ ")) + text(step.toObject(), QLatin1String("text")));
    }
    detail = steps.join(QLatin1Char('\n'));
  } else if (type == QLatin1String("run_interrupt_request")) {
    label = QStringLiteral("Interrupt requested");
    detail = text(item, QLatin1String("message"));
  } else if (type == QLatin1String("run_interrupt_result")) {
    label = QStringLiteral("Run interrupted");
    detail = text(item, QLatin1String("message"));
  } else if (type == QLatin1String("system_notice")) {
    label = text(item, QLatin1String("message"));
  } else {
    label = type;
  }
  if (!title.isEmpty() && type != QLatin1String("reasoning")) label = title;
  entry.insert(QStringLiteral("label"), label);
  entry.insert(QStringLiteral("detail"), detail);
  return entry;
}

QVariant TimelineModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  if (role == IdRole) return row.id;
  if (role == KindRole) return row.kind;
  if (row.kind == QLatin1String("fold")) {
    if (role == TitleRole) return row.label;
    if (role == HiddenCountRole) return row.hidden;
    if (role == ExpandedRole) return row.expanded;
    if (role == TimeRole) return stamp(row.at);
    return {};
  }
  if (row.kind == QLatin1String("thinking")) {
    if (role == TitleRole) return QStringLiteral("Thinking");
    if (role == IconRole) return QStringLiteral("brain");
    return {};
  }
  if (row.kind == QLatin1String("work")) {
    const bool expanded = m_expandedGroups.contains(row.id) != row.startsOpen;
    // A summarized group collapses into its summary alone.
    const int shown = row.summarized ? 0 : visibleWorkEntries;
    if (role == ExpandedRole) return expanded;
    if (role == HiddenCountRole) return std::max<int>(0, int(row.items.size()) - shown);
    if (role == EntriesRole) {
      QVariantList entries;
      const qsizetype first = expanded ? 0 : std::max<qsizetype>(0, row.items.size() - shown);
      const QSet<QString> inherited = inheritedRuns();
      for (qsizetype i = first; i < row.items.size(); ++i) {
        const QJsonObject call = entity(QStringLiteral("turn-item"), row.items.at(i));
        QVariantMap shown = entry(call, row.live && !expanded && i == row.items.size() - 1);
        // Work a fork carried over from its source says so, and where from.
        if (inherited.contains(text(call, QLatin1String("runId")))) {
          shown.insert(QStringLiteral("visibility"), QStringLiteral("Inherited"));
          shown.insert(QStringLiteral("source"), forkSource());
        }
        entries.append(shown);
      }
      return entries;
    }
    if (role == SummaryRole || role == SummaryFailedRole) {
      if (!row.summarized) return role == SummaryRole ? QVariant(QString()) : QVariant(false);
      QList<QJsonObject> calls;
      for (const QString& id : row.items) calls.append(entity(QStringLiteral("turn-item"), id));
      const timeline::GroupSummary summary = timeline::summarize(calls);
      return role == SummaryRole ? QVariant(summary.text) : QVariant(summary.failed);
    }
    return {};
  }

  if (row.kind == QLatin1String("subagents")) {
    QList<QJsonObject> members;
    for (const QString& id : row.items) members.append(subagentOf(entity(QStringLiteral("turn-item"), id)));
    switch (role) {
      case TitleRole:
        return QStringLiteral("%1 subagents").arg(members.size());
      case TextRole: {
        QStringList statuses;
        for (const QJsonObject& member : std::as_const(members)) statuses.append(text(member, QLatin1String("status")));
        return subagents::summarizeStatuses(statuses);
      }
      case StatusRole: {
        for (const QJsonObject& member : std::as_const(members)) {
          if (subagents::live(text(member, QLatin1String("status")))) return QStringLiteral("running");
        }
        return QStringLiteral("completed");
      }
      case ExpandedRole:
        return m_openSubagentGroups.contains(row.id);
      case AvatarsRole: {
        QVariantList avatars;
        for (qsizetype i = 0; i < std::min<qsizetype>(3, members.size()); ++i) {
          avatars.append(QVariantMap{{QStringLiteral("title"), subagents::displayTitle(text(members.at(i), QLatin1String("title")))},
                                     {QStringLiteral("status"), text(members.at(i), QLatin1String("status"))}});
        }
        return avatars;
      }
      case MoreRole:
        return std::max<int>(0, int(members.size()) - 3);
      case SpanRole: {
        const subagents::Span span = subagents::groupSpan(members);
        if (!span.start.isValid()) return QString();
        if (span.end.isValid()) return subagents::formatElapsed(span.start.secsTo(span.end));
        return span.live ? subagents::formatElapsed(span.start.secsTo(m_now())) : QString();
      }
      case TimeRole:
        return stamp(rowTime(row));
      case IconRole:
        return QStringLiteral("bot");
      default:
        return {};
    }
  }

  const QJsonObject item = row.id == forkMarkerId() ? syntheticFork() : entity(QStringLiteral("turn-item"), row.items.value(0));
  const QString type = text(item, QLatin1String("type"));
  if (row.kind == QLatin1String("resource")) {
    // A thread the turn created, as a card after its last reply.
    switch (role) {
      case TitleRole:
        return text(item, QLatin1String("title")).isEmpty() ? QStringLiteral("Created thread") : text(item, QLatin1String("title"));
      case ActionRole:
        return QStringLiteral("Open chat");
      case ThreadRole:
        return text(item, QLatin1String("targetThreadId"));
      case IconRole:
        return QStringLiteral("message-square");
      case TimeRole:
        return stamp(itemTime(item));
      default:
        return {};
    }
  }
  // A subagent's row follows its entity, which moves on after the turn item.
  const QJsonObject agent = row.kind == QLatin1String("subagent") ? entity(QStringLiteral("subagent"), text(item, QLatin1String("subagentId"))) : QJsonObject();
  const QString status = text(agent.contains(QLatin1String("status")) ? agent : item, QLatin1String("status"));
  switch (role) {
    case AuthorRole:
      return type == QLatin1String("user_message") ? QStringLiteral("user") : QStringLiteral("assistant");
    case StreamingRole:
      return item.value(QLatin1String("streaming")).toBool();
    case StatusRole:
      return status;
    case MarkerRole:
      return intentMarker(text(item, QLatin1String("inputIntent")));
    case IntentRole:
      return text(item, QLatin1String("inputIntent"));
    case AttributionRole:
      // Only a user message mentions a pull request. Nor is what the agent was sent
      // for itself anyone's message (noticeOf).
      if (type != QLatin1String("user_message") || row.kind != QLatin1String("message")) return QString();
      if (!text(item, QLatin1String("scheduledTaskId")).isEmpty() || legacyAutomationPrefix(item) > 0) return QStringLiteral("Sent by automation");
      if (text(item, QLatin1String("createdBy")) == QLatin1String("agent")) {
        const QString sender = text(item, QLatin1String("senderThreadId"));
        const QString title = sender.isEmpty() || !m_threadTitle ? QString() : m_threadTitle(sender);
        return title.isEmpty() ? QStringLiteral("Sent by another agent") : QStringLiteral("From %1").arg(title);
      }
      return QString();
    case ThreadRole:
      if (row.kind == QLatin1String("subagent")) return text(item, QLatin1String("childThreadId"));
      if (type == QLatin1String("user_message") && text(item, QLatin1String("createdBy")) == QLatin1String("agent")) {
        // Only a thread this environment knows opens.
        const QString sender = text(item, QLatin1String("senderThreadId"));
        const bool known = !sender.isEmpty() && m_threadTitle && !m_threadTitle(sender).isEmpty();
        return known && legacyAutomationPrefix(item) == 0 ? sender : QString();
      }
      if (type == QLatin1String("fork")) {
        const QJsonObject source = item.value(QLatin1String("source")).toObject();
        return text(source, QLatin1String("type")) == QLatin1String("run") ? text(source, QLatin1String("threadId")) : text(item, QLatin1String("targetThreadId"));
      }
      if (type == QLatin1String("thread_created")) return text(item, QLatin1String("targetThreadId"));
      // A finished worker's notification opens the worker's thread.
      if (row.kind == QLatin1String("marker")) {
        if (const auto notice = timeline::noticeOf(item)) return notice->workerThreadId;
      }
      return QString();
    case PullRequestUrlRole: {
      if (row.kind != QLatin1String("message")) return QString();
      // GitHub and Forgejo pulls, GitLab
      // merge requests, Bitbucket and Azure pull requests.
      static const QRegularExpression address(
          QStringLiteral("https?://[^\\s<>()\\[\\]\"']+/(?:pull|pulls|merge_requests|pull-requests|pullrequest)/\\d+"));
      return address.match(text(item, QLatin1String("text"))).captured(0);
    }
    case ModelRole:
      if (row.kind != QLatin1String("subagent")) return QString();
      return subagents::formatModelSlugName(text(entity(QStringLiteral("subagent"), text(item, QLatin1String("subagentId"))), QLatin1String("model")));
    case ActionRole:
      if (type == QLatin1String("fork")) {
        return text(item.value(QLatin1String("source")).toObject(), QLatin1String("type")) == QLatin1String("run") ? QStringLiteral("Open source conversation")
                                                                                                                 : QStringLiteral("Open fork");
      }
      return type == QLatin1String("thread_created") && !text(item, QLatin1String("targetThreadId")).isEmpty() ? QStringLiteral("Open chat") : QString();
    case VisibilityRole:
      if (item.value(QLatin1String("synthetic")).toBool()) return QStringLiteral("Synthetic");
      return inheritedRuns().contains(text(item, QLatin1String("runId"))) ? QStringLiteral("Inherited") : QString();
    case SourceRole:
      return inheritedRuns().contains(text(item, QLatin1String("runId"))) ? forkSource() : QString();
    case HandoffRole:
      return type == QLatin1String("handoff") ? handoffEnds(item) : QVariantList();
    case MetaRole:
      return row.meta;
    case MessageIdRole:
      return type == QLatin1String("assistant_message") ? text(item, QLatin1String("messageId")) : QString();
    case IconRole:
      return row.kind == QLatin1String("message") || row.kind == QLatin1String("plan") ? QString() : iconOf(item);
    case TimeRole:
      return stamp(rowTime(row));
    case StatusLabelRole:
      return row.kind == QLatin1String("subagent") ? subagentStatusLabel(status) : QString();
    case TitleRole:
      if (row.kind == QLatin1String("plan")) return planTitle(text(item, QLatin1String("markdown")));
      if (row.kind == QLatin1String("marker")) return markerTitle(item);
      // The MC names what it recorded ("Provider retry"); a plain failure is an error.
      if (row.kind == QLatin1String("error")) {
        const QJsonObject failure = item.value(QLatin1String("failure")).toObject();
        if (text(failure, QLatin1String("class")) == QLatin1String("usage_limit")) {
          // One line, the wait named by when it ends.
          const QString reset = upcoming(timeOf(failure.value(QLatin1String("resetAt"))));
          return reset.isEmpty() ? QStringLiteral("Usage limit reached.") : QStringLiteral("Usage limit reached. Retry after %1.").arg(reset);
        }
        return text(item, QLatin1String("title")).isEmpty() ? QStringLiteral("Error") : text(item, QLatin1String("title"));
      }
      if (row.kind == QLatin1String("subagent")) {
        const QString title = subagents::displayTitle(text(item, QLatin1String("title")).trimmed());
        return title.isEmpty() ? QStringLiteral("Subagent") : title;
      }
      return {};
    case TextRole:
      if (row.kind == QLatin1String("plan")) return planBody(text(item, QLatin1String("markdown")));
      if (row.kind == QLatin1String("marker")) return markerDetail(item);
      if (row.kind == QLatin1String("error")) {
        const QJsonObject failure = item.value(QLatin1String("failure")).toObject();
        // The agent's own sentence stays in the conversation.
        return text(failure, QLatin1String("class")) == QLatin1String("usage_limit") ? QString() : text(failure, QLatin1String("message"));
      }
      if (row.kind == QLatin1String("subagent")) {
        const auto field = [&](QLatin1StringView name) { return agent.contains(name) ? text(agent, name) : text(item, name); };
        const QString detail = timeline::subagentDetail(timeline::subagentSettled(status), field(QLatin1String("progress")),
                                                       field(QLatin1String("result")));
        return detail.isEmpty() ? timeline::plainDetail(text(item, QLatin1String("prompt"))) : detail;
      }
      if (type == QLatin1String("user_message")) return text(item, QLatin1String("text")).mid(legacyAutomationPrefix(item));
      return text(item, QLatin1String("text"));
    case PreviewRole:
      return row.kind == QLatin1String("plan") ? planPreview(text(item, QLatin1String("markdown"))) : QString();
    case ExpandedRole:
      return row.kind == QLatin1String("plan") && m_expandedGroups.contains(row.id);
    case ScheduledTaskRole:
      return type == QLatin1String("user_message") && row.kind == QLatin1String("message") ? scheduledTaskOf(item) : QString();
    case WarningRole:
      return row.kind == QLatin1String("error") &&
             text(item.value(QLatin1String("failure")).toObject(), QLatin1String("class")) == QLatin1String("usage_limit");
    case AttachmentsRole: {
      QVariantList images;
      if (type != QLatin1String("user_message")) return images;
      for (const QJsonValue& value : item.value(QLatin1String("attachments")).toArray()) {
        const QJsonObject attachment = value.toObject();
        if (text(attachment, QLatin1String("type")) != QLatin1String("image")) continue;
        const QString id = text(attachment, QLatin1String("id"));
        const AttachmentUrl known = m_attachmentUrls.value(id);
        QVariantMap image{
            {QStringLiteral("id"), id},
            {QStringLiteral("name"), text(attachment, QLatin1String("name"))},
            {QStringLiteral("url"), known.expiresAt > m_now() ? known.url : QUrl()},
        };
        // A Snap Shot's capture: its tree as JSON, or its flat text.
        const QJsonObject source = attachment.value(QLatin1String("source")).toObject();
        const QJsonObject tree = source.value(QLatin1String("accessibility")).toObject();
        const QString flat = text(tree, QLatin1String("format")) == QLatin1String("flat-text") ? text(tree, QLatin1String("text")) : text(source, QLatin1String("accessibleText"));
        if (!tree.isEmpty() && text(tree, QLatin1String("format")) != QLatin1String("flat-text")) {
          image.insert(QStringLiteral("accessFormat"), QStringLiteral("json"));
          image.insert(QStringLiteral("accessText"), accessJson(id, tree));
        } else if (!flat.isEmpty()) {
          image.insert(QStringLiteral("accessFormat"), QStringLiteral("text"));
          image.insert(QStringLiteral("accessText"), flat);
        }
        images.append(image);
      }
      return images;
    }
    case SentFilesRole: {
      QVariantList files;
      if (type != QLatin1String("user_message")) return files;
      for (const QJsonValue& value : item.value(QLatin1String("attachments")).toArray()) {
        const QJsonObject attachment = value.toObject();
        const QString kind = text(attachment, QLatin1String("type"));
        if (kind == QLatin1String("image")) continue;
        const QString name = text(attachment, QLatin1String("name"));
        QString detail;
        if (kind == QLatin1String("file")) {
          const QString suffix = QFileInfo(name).suffix().toUpper();
          const QString size = QLocale(QLocale::English, QLocale::UnitedStates)
                                   .formattedDataSize(attachment.value(QLatin1String("sizeBytes")).toInteger(), 1, QLocale::DataSizeIecFormat);
          detail = suffix.isEmpty() ? size : QStringLiteral("%1 · %2").arg(suffix, size);
        }
        files.append(QVariantMap{{QStringLiteral("id"), text(attachment, QLatin1String("id"))},
                                 {QStringLiteral("name"), name},
                                 {QStringLiteral("mimeType"), text(attachment, QLatin1String("mimeType"))},
                                 {QStringLiteral("detail"), detail}});
      }
      return files;
    }
    case FilesRole: {
      QVariantList files;
      const QJsonObject checkpoint = entity(QStringLiteral("turn-item"), row.checkpoint);
      for (const QJsonValue& value : checkpoint.value(QLatin1String("files")).toArray()) {
        const QJsonObject file = value.toObject();
        files.append(QVariantMap{
            {QStringLiteral("path"), text(file, QLatin1String("path"))},
            {QStringLiteral("additions"), file.value(QLatin1String("additions")).toInt()},
            {QStringLiteral("deletions"), file.value(QLatin1String("deletions")).toInt()},
        });
      }
      return files;
    }
    default:
      return {};
  }
}

QString TimelineModel::forkMarkerId() const {
  return QStringLiteral("turn-item:fork:") + m_threadKey.mid(m_threadKey.indexOf(QLatin1Char(':')) + 1);
}

QJsonObject TimelineModel::forkedFrom() const {
  if (!m_threadRow) return {};
  const QJsonObject from = m_threadRow(m_threadKey.mid(m_threadKey.indexOf(QLatin1Char(':')) + 1)).value(QLatin1String("forkedFrom")).toObject();
  return text(from, QLatin1String("type")) == QLatin1String("run") ? from : QJsonObject();
}

QSet<QString> TimelineModel::inheritedRuns() const {
  const QJsonObject from = forkedFrom();
  QSet<QString> inherited;
  if (from.isEmpty()) return inherited;
  const QHash<QString, QJsonObject> runs = m_entities.value(QStringLiteral("run"));
  const auto at = runs.constFind(text(from, QLatin1String("runId")));
  if (at == runs.cend()) return inherited;
  const double point = at->value(QLatin1String("ordinal")).toDouble();
  for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
    if (it->value(QLatin1String("ordinal")).toDouble() <= point) inherited.insert(it.key());
  }
  return inherited;
}

QString TimelineModel::forkSource() const {
  const QString source = text(forkedFrom(), QLatin1String("threadId"));
  const QString title = source.isEmpty() || !m_threadTitle ? QString() : m_threadTitle(source);
  return QStringLiteral("From %1").arg(title.isEmpty() ? source : title);
}

QJsonObject TimelineModel::syntheticFork() const {
  const QJsonObject from = forkedFrom();
  const QString thread = m_threadKey.mid(m_threadKey.indexOf(QLatin1Char(':')) + 1);
  const QString created = m_threadRow ? text(m_threadRow(thread), QLatin1String("createdAt")) : QString();
  return {{QStringLiteral("id"), forkMarkerId()}, {QStringLiteral("type"), QStringLiteral("fork")}, {QStringLiteral("status"), QStringLiteral("completed")},
          {QStringLiteral("source"), from}, {QStringLiteral("targetThreadId"), thread}, {QStringLiteral("synthetic"), true},
          {QStringLiteral("completedAt"), created}, {QStringLiteral("updatedAt"), created}};
}

QJsonObject TimelineModel::subagentOf(const QJsonObject& item) const {
  QJsonObject merged = item;
  const QJsonObject agent = entity(QStringLiteral("subagent"), text(item, QLatin1String("subagentId")));
  for (auto it = agent.begin(); it != agent.end(); ++it) {
    if (it.key() != QLatin1String("id") && !it.value().isNull()) merged.insert(it.key(), it.value());
  }
  return merged;
}

QString TimelineModel::providerName(const QString& instanceId) const {
  const QList<composer::Instance> known = composer::instances(m_providers ? m_providers() : QJsonArray());
  const composer::Instance* instance = composer::find(known, instanceId);
  return instance && !instance->displayName.isEmpty() ? instance->displayName : instanceId;
}

QString TimelineModel::modelName(const QString& instanceId, const QString& model) const {
  if (model.isEmpty()) return {};
  const QList<composer::Instance> known = composer::instances(m_providers ? m_providers() : QJsonArray());
  const composer::Instance* instance = composer::find(known, instanceId);
  if (!instance) {
    for (const composer::Instance& any : known) {
      if (!composer::findModel(any, model).isEmpty()) instance = &any;
    }
  }
  const QString name = instance ? text(composer::findModel(*instance, model), QLatin1String("name")) : QString();
  return name.isEmpty() ? subagents::formatModelSlugName(model) : name;
}

// A handoff's ends (client-runtime handoff.ts resolveHandoffEndpoints): the
// selections it came from, else the latest model each source instance ran
// before it, and the model it went to, else its own run's.
QVariantList TimelineModel::handoffEnds(const QJsonObject& item) const {
  const QHash<QString, QJsonObject> runs = m_entities.value(QStringLiteral("run"));
  const QJsonObject handoffRun = runs.value(text(item, QLatin1String("runId")));
  const bool placed = !handoffRun.isEmpty();
  const double before = handoffRun.value(QLatin1String("ordinal")).toDouble();
  const auto runInstance = [](const QJsonObject& run) {
    const QString instance = text(run, QLatin1String("providerInstanceId"));
    return instance.isEmpty() ? text(run.value(QLatin1String("modelSelection")).toObject(), QLatin1String("instanceId")) : instance;
  };
  const auto end = [this](const QString& side, const QString& instance, const QString& model) {
    const QString provider = providerName(instance);
    const QString name = modelName(instance, model);
    return QVariantMap{{QStringLiteral("side"), side},
                       {QStringLiteral("provider"), provider},
                       {QStringLiteral("model"), name},
                       {QStringLiteral("tooltip"), name.isEmpty() ? provider : QStringLiteral("%1 · %2").arg(provider, name)}};
  };
  QVariantList ends;
  const QJsonArray selections = item.value(QLatin1String("fromModelSelections")).toArray();
  if (!selections.isEmpty()) {
    for (const QJsonValue& value : selections) {
      ends.append(end(QStringLiteral("from"), text(value.toObject(), QLatin1String("instanceId")), text(value.toObject(), QLatin1String("model"))));
    }
  } else {
    for (const QJsonValue& value : item.value(QLatin1String("fromProviderInstanceIds")).toArray()) {
      const QString instance = value.toString();
      QJsonObject latest;
      for (const QJsonObject& run : runs) {
        if (runInstance(run) != instance || (placed && run.value(QLatin1String("ordinal")).toDouble() >= before)) continue;
        if (latest.isEmpty() || run.value(QLatin1String("ordinal")).toDouble() > latest.value(QLatin1String("ordinal")).toDouble()) latest = run;
      }
      ends.append(end(QStringLiteral("from"), instance, text(latest.value(QLatin1String("modelSelection")).toObject(), QLatin1String("model"))));
    }
  }
  const QString to = text(item, QLatin1String("toProviderInstanceId"));
  QString toModel = text(item, QLatin1String("toModel"));
  if (toModel.isEmpty() && placed && runInstance(handoffRun) == to) toModel = text(handoffRun.value(QLatin1String("modelSelection")).toObject(), QLatin1String("model"));
  ends.append(end(QStringLiteral("to"), to, toModel));
  return ends;
}

QVariantMap TimelineModel::subagentCard(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0 || m_rows.at(at).kind != QLatin1String("subagent")) return {};
  const QJsonObject agent = subagentOf(entity(QStringLiteral("turn-item"), m_rows.at(at).items.value(0)));
  const QString status = text(agent, QLatin1String("status"));
  QVariantMap card;
  const QString model = text(agent, QLatin1String("model")).trimmed();
  card.insert(QStringLiteral("model"), model.isEmpty() ? QStringLiteral("Not reported") : modelName(text(agent, QLatin1String("providerInstanceId")), model));
  // How long it has worked, or worked.
  const QDateTime started = timeOf(agent.value(QLatin1String("startedAt")));
  const QDateTime completed = timeOf(agent.value(QLatin1String("completedAt")));
  const QDateTime until = subagents::live(status) || !completed.isValid() ? m_now() : completed;
  card.insert(QStringLiteral("elapsed"), started.isValid() ? subagents::formatElapsed(started.secsTo(until)) : QString());
  // Where it works, where that is not where its parent does.
  const QString thread = m_threadKey.mid(m_threadKey.indexOf(QLatin1Char(':')) + 1);
  const QJsonObject parent = m_threadRow ? m_threadRow(thread) : QJsonObject();
  const QJsonObject child = m_threadRow && !text(agent, QLatin1String("childThreadId")).isEmpty() ? m_threadRow(text(agent, QLatin1String("childThreadId"))) : QJsonObject();
  const QString project = text(child, QLatin1String("projectId"));
  card.insert(QStringLiteral("project"), !project.isEmpty() && project != text(parent, QLatin1String("projectId")) && m_projectTitle ? m_projectTitle(project) : QString());
  const QString branch = text(child, QLatin1String("branch"));
  const QString worktree = text(child, QLatin1String("worktreePath"));
  QString place;
  if (!branch.isEmpty() && branch != text(parent, QLatin1String("branch"))) place = branch;
  else if (branch.isEmpty() && !worktree.isEmpty() && worktree != text(parent, QLatin1String("worktreePath"))) place = QFileInfo(QDir::cleanPath(worktree)).fileName();
  card.insert(QStringLiteral("place"), place);
  // Its answer once it ended, else its latest word (subagentDetailPreview).
  QString preview = timeline::subagentDetail(timeline::subagentSettled(status), text(agent, QLatin1String("progress")), text(agent, QLatin1String("result")));
  preview = preview.simplified();
  if (preview.size() > 280) preview = preview.left(280) + QStringLiteral("…");
  card.insert(QStringLiteral("preview"), preview);
  return card;
}

QString TimelineModel::workspaceMutation() const {
  QString item;
  int ordinal = -1;
  const QHash<QString, QJsonObject> items = entities(QStringLiteral("turn-item"));
  for (auto it = items.cbegin(); it != items.cend(); ++it) {
    const QString type = it->value(QLatin1String("type")).toString();
    if (type != QLatin1String("command_execution") && type != QLatin1String("file_change")) continue;
    const QString status = it->value(QLatin1String("status")).toString();
    if (status == QLatin1String("pending") || status == QLatin1String("running") || status == QLatin1String("waiting")) continue;
    if (const int at = it->value(QLatin1String("ordinal")).toInt(); at > ordinal) {
      ordinal = at;
      item = it.key();
    }
  }
  QStringList checkpoints;
  const QHash<QString, QJsonObject> kept = entities(QStringLiteral("checkpoint"));
  for (auto it = kept.cbegin(); it != kept.cend(); ++it) checkpoints.append(it.key() + QLatin1Char('=') + it->value(QLatin1String("status")).toString());
  checkpoints.sort();
  return item + QLatin1Char('\n') + checkpoints.join(QLatin1Char(','));
}
