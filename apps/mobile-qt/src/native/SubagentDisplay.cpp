#include "SubagentDisplay.h"

#include <QRegularExpression>

#include <algorithm>

namespace subagents {

namespace {

// formatCodexModelName: "gpt" reads "GPT", and each letter after a dash is capitalised.
QString codexModelName(const QString& name) {
  static const QRegularExpression gpt(QStringLiteral("^gpt"), QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression dashed(QStringLiteral("-([a-z])"));
  QString result = name;
  result.replace(gpt, QStringLiteral("GPT"));
  QString out;
  qsizetype from = 0;
  for (auto it = dashed.globalMatch(result); it.hasNext();) {
    const QRegularExpressionMatch match = it.next();
    out += result.mid(from, match.capturedStart() - from) + QLatin1Char('-') + match.captured(1).toUpper();
    from = match.capturedEnd();
  }
  return out + result.mid(from);
}

QDateTime timeOf(const QJsonObject& object, QLatin1StringView field) {
  return QDateTime::fromString(object.value(field).toString(), Qt::ISODateWithMs);
}

}  // namespace

QString formatModelSlugName(const QString& slug) {
  static const QRegularExpression codex(QStringLiteral("^gpt-\\d"), QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression known(QStringLiteral("^(claude-(opus|sonnet|haiku|fable)|gemini|grok|composer)-\\d"),
                                        QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression version(QStringLiteral("^(claude-[a-z]+-\\d+)-(\\d{1,2})(?=-|\\[|$)"),
                                          QRegularExpression::CaseInsensitiveOption);
  const qsizetype separator = slug.lastIndexOf(QLatin1Char('/')) + 1;
  const QString prefix = slug.left(separator);
  QString name = slug.mid(separator);
  if (codex.match(name).hasMatch()) return prefix + codexModelName(name);
  if (!known.match(name).hasMatch()) return slug;
  name.replace(version, QStringLiteral("\\1.\\2"));
  QStringList parts = name.split(QLatin1Char('-'));
  for (QString& part : parts) {
    if (!part.isEmpty()) part[0] = part.at(0).toUpper();
  }
  return prefix + parts.join(QLatin1Char(' '));
}

QString displayTitle(const QString& title) {
  static const QRegularExpression prefix(QStringLiteral("^Subagent:\\s*"), QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression path(QStringLiteral("^/root/(?:[^/]+/)*([^/]+)/?$"));
  static const QRegularExpression spaces(QStringLiteral("[_\\s]+"));
  QString shown = title;
  shown.remove(prefix);
  const QRegularExpressionMatch match = path.match(shown);
  if (!match.hasMatch()) return shown;
  QStringList words = match.captured(1).replace(spaces, QStringLiteral(" ")).trimmed().split(QLatin1Char(' '), Qt::SkipEmptyParts);
  if (words.isEmpty()) return shown;
  for (QString& word : words) word[0] = word.at(0).toUpper();
  return words.join(QLatin1Char(' '));
}

bool live(const QString& status) {
  return status == QLatin1String("pending") || status == QLatin1String("running") || status == QLatin1String("waiting");
}

QString summarizeStatuses(const QStringList& statuses) {
  int working = 0, done = 0, failed = 0, stopped = 0, idle = 0;
  for (const QString& status : statuses) {
    if (live(status)) ++working;
    else if (status == QLatin1String("completed")) ++done;
    else if (status == QLatin1String("failed")) ++failed;
    else if (status == QLatin1String("idle")) ++idle;
    else ++stopped;
  }
  QStringList parts;
  const auto add = [&parts](int count, const char* word) {
    if (count > 0) parts.append(QStringLiteral("%1 %2").arg(count).arg(QLatin1String(word)));
  };
  add(working, "working");
  add(done, "done");
  add(failed, "failed");
  add(stopped, "stopped");
  add(idle, "idle");
  return parts.join(QStringLiteral(" · "));
}

Span groupSpan(const QList<QJsonObject>& members) {
  Span span;
  QDateTime end;
  bool endUnknown = false;
  for (const QJsonObject& member : members) {
    const QDateTime started = timeOf(member, QLatin1String("startedAt"));
    if (started.isValid() && (!span.start.isValid() || started < span.start)) span.start = started;
    const QDateTime completed = timeOf(member, QLatin1String("completedAt"));
    if (completed.isValid()) {
      if (!end.isValid() || completed > end) end = completed;
    } else {
      endUnknown = true;
    }
    span.live = span.live || live(member.value(QLatin1String("status")).toString());
  }
  if (!span.live && !endUnknown) span.end = end;
  return span;
}

QString formatElapsed(qint64 total) {
  const qint64 seconds = std::max<qint64>(0, total);
  const qint64 minutes = seconds / 60;
  if (minutes == 0) return QStringLiteral("%1s").arg(seconds);
  const qint64 hours = minutes / 60;
  if (hours == 0) return QStringLiteral("%1m %2s").arg(minutes).arg(seconds % 60, 2, 10, QLatin1Char('0'));
  return QStringLiteral("%1h %2m").arg(hours).arg(minutes % 60, 2, 10, QLatin1Char('0'));
}

}  // namespace subagents
