#include "SidebarModel.h"

#include <QHash>
#include <QJsonArray>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>

namespace sidebar {

namespace {

constexpr qint64 kMinuteMs = 60 * 1000;
constexpr qint64 kHourMs = 60 * kMinuteMs;
constexpr qint64 kDayMs = 24 * kHourMs;
constexpr qint64 kQueuedTurnStartGraceMs = 2 * kMinuteMs;

Nullable stringField(const QJsonObject& row, const char* key) {
  const QJsonValue value = row.value(QLatin1String(key));
  return value.isString() ? Nullable(value.toString()) : std::nullopt;
}

bool present(const QJsonObject& row, const char* key) {
  const QJsonValue value = row.value(QLatin1String(key));
  return !value.isUndefined() && !value.isNull();
}

bool terminalRunStatus(const QString& status) {
  return status == QLatin1String("completed") || status == QLatin1String("interrupted") ||
         status == QLatin1String("failed") || status == QLatin1String("cancelled") ||
         status == QLatin1String("rolled_back");
}

bool activeRunStatus(const QString& status) {
  return status == QLatin1String("preparing") || status == QLatin1String("queued") ||
         status == QLatin1String("starting") || status == QLatin1String("running") ||
         status == QLatin1String("waiting");
}

QVariant nullable(const Nullable& value) {
  return value ? QVariant(*value) : QVariant::fromValue(nullptr);
}

// Missing and malformed timestamps sort as the epoch, as the page's sorts do.
qint64 sortableMs(const Nullable& iso) {
  return parseIso(iso).value_or(0);
}

int compareIdentity(const Thread& left, const Thread& right) {
  if (const int byId = QString::compare(left.id, right.id)) return byId;
  return QString::compare(left.environmentId, right.environmentId);
}

void sortPinned(QList<Thread>& threads) {
  std::stable_sort(threads.begin(), threads.end(), [](const Thread& left, const Thread& right) {
    // User-arranged keys first, keyless pins newest-created below.
    if (left.pinOrderKey.has_value() != right.pinOrderKey.has_value()) {
      return left.pinOrderKey.has_value();
    }
    if (left.pinOrderKey) {
      if (*left.pinOrderKey != *right.pinOrderKey) return *left.pinOrderKey < *right.pinOrderKey;
    } else {
      const qint64 leftMs = sortableMs(left.createdAt);
      const qint64 rightMs = sortableMs(right.createdAt);
      if (leftMs != rightMs) return leftMs > rightMs;
    }
    return compareIdentity(left, right) < 0;
  });
}

void sortActive(QList<Thread>& threads) {
  const auto anchor = [](const Thread& thread) {
    return std::max(sortableMs(thread.createdAt), sortableMs(thread.unsettledAt));
  };
  std::stable_sort(threads.begin(), threads.end(), [&anchor](const Thread& left, const Thread& right) {
    // New and reopened threads lead; arranged threads follow their keys.
    if (left.activeOrderKey.has_value() != right.activeOrderKey.has_value()) {
      return !left.activeOrderKey.has_value();
    }
    if (left.activeOrderKey) {
      if (*left.activeOrderKey != *right.activeOrderKey) {
        return *left.activeOrderKey < *right.activeOrderKey;
      }
    } else {
      const qint64 leftMs = anchor(left);
      const qint64 rightMs = anchor(right);
      if (leftMs != rightMs) return leftMs > rightMs;
    }
    return compareIdentity(left, right) < 0;
  });
}

// Settled rows are history: they order by when the work ended.
Nullable settledTimestamp(const Thread& thread) {
  if (parseIso(thread.settledAt)) return thread.settledAt;
  Nullable latest;
  qint64 latestMs = std::numeric_limits<qint64>::min();
  const Nullable candidates[] = {
      thread.latestUserMessageAt,
      thread.latestRun ? thread.latestRun->requestedAt : std::nullopt,
      thread.latestRun ? thread.latestRun->startedAt : std::nullopt,
      thread.latestRun ? thread.latestRun->completedAt : std::nullopt,
  };
  for (const Nullable& candidate : candidates) {
    const auto parsed = parseIso(candidate);
    if (parsed && *parsed > latestMs) {
      latest = candidate;
      latestMs = *parsed;
    }
  }
  if (latest) return latest;
  return parseIso(thread.updatedAt) ? Nullable(thread.updatedAt) : std::nullopt;
}

void sortSettled(QList<Thread>& threads) {
  std::stable_sort(threads.begin(), threads.end(), [](const Thread& left, const Thread& right) {
    const qint64 leftMs = sortableMs(settledTimestamp(left));
    const qint64 rightMs = sortableMs(settledTimestamp(right));
    if (leftMs != rightMs) return leftMs > rightMs;
    return QString::compare(left.id, right.id) < 0;
  });
}

bool latestRunSettled(const Thread& thread) {
  if (!thread.latestRun) return false;
  if (activeRunStatus(thread.latestRun->status)) return false;
  return !(thread.runtime && thread.runtime->activeRunId == thread.latestRun->runId);
}

bool latestRunCompletedAfterSnooze(const Thread& thread) {
  const auto snoozedAt = parseIso(thread.snoozedAt);
  if (!snoozedAt || !thread.latestRun || thread.latestRun->status != QLatin1String("completed")) {
    return false;
  }
  const auto completedAt = parseIso(thread.latestRun->completedAt);
  return completedAt && *completedAt > *snoozedAt;
}

QDateTime localAt(const QDate& date, int hour) {
  return QDateTime(date, QTime(hour, 0));
}

}  // namespace

std::optional<qint64> parseIso(const Nullable& iso) {
  if (!iso || iso->isEmpty()) return std::nullopt;
  const QDateTime parsed = QDateTime::fromString(*iso, Qt::ISODateWithMs);
  if (!parsed.isValid()) return std::nullopt;
  return parsed.toMSecsSinceEpoch();
}

QString formatIso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

Thread threadFromRow(const QString& environmentId, const QJsonObject& row) {
  Thread thread;
  thread.environmentId = environmentId;
  thread.id = row.value(QLatin1String("id")).toString();
  thread.projectId = row.value(QLatin1String("projectId")).toString();
  thread.title = row.value(QLatin1String("title")).toString();
  thread.branch = stringField(row, "branch");
  thread.createdAt = row.value(QLatin1String("createdAt")).toString();
  thread.updatedAt = row.value(QLatin1String("updatedAt")).toString();
  thread.latestUserMessageAt = stringField(row, "latestUserMessageAt");
  thread.archivedAt = stringField(row, "archivedAt");
  thread.subagent = row.value(QLatin1String("lineage")).toObject().value(QLatin1String("relationshipToParent")).toString() ==
                    QLatin1String("subagent");
  thread.interactionMode = row.value(QLatin1String("interactionMode")).toString(QStringLiteral("default"));
  thread.runtimeMode = row.value(QLatin1String("runtimeMode")).toString();
  thread.modelSelection = row.value(QLatin1String("modelSelection")).toObject();
  thread.settledOverride = stringField(row, "settledOverride");
  thread.settledAt = stringField(row, "settledAt");
  thread.unsettledAt = stringField(row, "unsettledAt");
  thread.snoozedUntil = stringField(row, "snoozedUntil");
  thread.snoozedAt = stringField(row, "snoozedAt");
  thread.pinnedAt = stringField(row, "pinnedAt");
  thread.pinOrderKey = stringField(row, "pinOrderKey");
  thread.activeOrderKey = stringField(row, "activeOrderKey");
  thread.lastVisitedAt = stringField(row, "lastVisitedAt");
  thread.latestRunId = stringField(row, "latestRunId");
  thread.activeRunId = stringField(row, "activeRunId");
  thread.activityRunStatus = stringField(row, "activityRunStatus");
  thread.hasActionableProposedPlan = row.value(QLatin1String("hasActionableProposedPlan")).toBool();
  thread.pendingBackgroundTasks = row.value(QLatin1String("pendingBackgroundTasks")).toArray().size();

  const QString status = row.value(QLatin1String("status")).toString(QStringLiteral("idle"));
  if (thread.latestRunId) {
    RunSummary run;
    run.runId = *thread.latestRunId;
    run.status = status == QLatin1String("idle") ? QStringLiteral("completed") : status;
    run.requestedAt = stringField(row, "latestRunRequestedAt");
    run.startedAt = stringField(row, "latestRunStartedAt");
    // Rows from before the node stamped completion close the run at updatedAt.
    if (row.contains(QLatin1String("latestRunCompletedAt"))) {
      run.completedAt = stringField(row, "latestRunCompletedAt");
    } else if (status == QLatin1String("idle") || terminalRunStatus(status)) {
      run.completedAt = thread.updatedAt;
    }
    thread.latestRun = run;
  }
  if (thread.latestRunId || present(row, "activeProviderThreadId")) {
    RuntimeSummary runtime;
    // Background tasks still open after the run park the runtime at idle ("Waiting").
    runtime.status = thread.pendingBackgroundTasks > 0 ? QStringLiteral("idle")
                                                       : thread.activityRunStatus.value_or(status);
    runtime.activeRunId = thread.activeRunId;
    runtime.lastErrorClass = stringField(row, "lastErrorClass");
    runtime.updatedAt = thread.updatedAt;
    thread.runtime = runtime;
  }
  const QJsonValue request = row.value(QLatin1String("pendingRuntimeRequest"));
  if (request.isObject()) {
    const QString kind = request.toObject().value(QLatin1String("kind")).toString();
    thread.hasPendingUserInput = kind == QLatin1String("user_input");
    thread.hasPendingApprovals = kind != QLatin1String("user_input") && kind != QLatin1String("auth_refresh");
  }
  return thread;
}

bool hasQueuedTurnStart(const Thread& thread, qint64 nowMs) {
  if (thread.runtime && (thread.runtime->status == QLatin1String("preparing") ||
                         thread.runtime->status == QLatin1String("queued") ||
                         thread.runtime->status == QLatin1String("starting"))) {
    return true;
  }
  const auto messageAt = parseIso(thread.latestUserMessageAt);
  if (!messageAt) return false;
  if (thread.runtime && thread.runtime->status == QLatin1String("error")) return false;
  // Bounded both ways: the message clock may run ahead of this one.
  if (std::abs(nowMs - *messageAt) > kQueuedTurnStartGraceMs) return false;
  if (!thread.latestRun) return true;
  for (const Nullable& candidate :
       {thread.latestRun->requestedAt, thread.latestRun->startedAt, thread.latestRun->completedAt}) {
    if (!candidate) continue;
    const auto at = parseIso(candidate);
    if (!at || *at >= *messageAt) return false;
  }
  return true;
}

bool raisedHandWhileSnoozed(const Thread& thread) {
  if (thread.hasPendingApprovals || thread.hasPendingUserInput) return true;
  // Only a failure newer than the snooze raises the hand.
  if (thread.runtime && (thread.runtime->status == QLatin1String("error") ||
                         thread.runtime->status == QLatin1String("failed"))) {
    if (!thread.snoozedAt) return true;
    const auto failedAt = parseIso(thread.runtime->updatedAt);
    const auto snoozedAt = parseIso(thread.snoozedAt);
    if (failedAt && snoozedAt && *failedAt > *snoozedAt) return true;
  }
  return latestRunCompletedAfterSnooze(thread);
}

bool canSnooze(const Thread& thread, qint64 nowMs) {
  if (thread.hasPendingApprovals || thread.hasPendingUserInput) return false;
  return !hasQueuedTurnStart(thread, nowMs);
}

bool effectiveSnoozed(const Thread& thread, qint64 nowMs) {
  const auto wakeMs = parseIso(thread.snoozedUntil);
  // Malformed data never hides a thread.
  if (!wakeMs || *wakeMs <= nowMs) return false;
  return !raisedHandWhileSnoozed(thread);
}

Nullable wokeAt(const Thread& thread, qint64 nowMs) {
  const auto wakeMs = parseIso(thread.snoozedUntil);
  if (!wakeMs) return std::nullopt;
  if (raisedHandWhileSnoozed(thread)) {
    if (latestRunCompletedAfterSnooze(thread)) return thread.latestRun->completedAt;
    if (thread.runtime) return thread.runtime->updatedAt;
    return thread.snoozedAt;
  }
  return *wakeMs <= nowMs ? thread.snoozedUntil : std::nullopt;
}

QString wakeLabel(const QString& snoozedUntil, qint64 nowMs) {
  const auto wakeMs = parseIso(snoozedUntil);
  if (!wakeMs) return QStringLiteral("now");
  const qint64 remaining = *wakeMs - nowMs;
  const auto ceilDiv = [](qint64 value, qint64 unit) { return (value + unit - 1) / unit; };
  if (remaining <= 0) return QStringLiteral("now");
  if (remaining < kHourMs) return QStringLiteral("%1m").arg(std::max<qint64>(1, ceilDiv(remaining, kMinuteMs)));
  if (remaining < kDayMs) return QStringLiteral("%1h").arg(ceilDiv(remaining, kHourMs));
  return QStringLiteral("%1d").arg(ceilDiv(remaining, kDayMs));
}

QString status(const Thread& thread) {
  if (thread.hasPendingApprovals) return QStringLiteral("approval");
  if (thread.hasPendingUserInput) return QStringLiteral("input");
  if (!thread.runtime) return QStringLiteral("ready");
  const QString& runtime = thread.runtime->status;
  if (activeRunStatus(runtime)) return QStringLiteral("working");
  if (runtime == QLatin1String("idle")) return QStringLiteral("waiting");
  if (runtime == QLatin1String("failed")) {
    return thread.runtime->lastErrorClass == QStringLiteral("usage_limit") ? QStringLiteral("limited")
                                                                           : QStringLiteral("failed");
  }
  return QStringLiteral("ready");
}

bool unread(const Thread& thread) {
  if (!thread.latestRun) return false;
  const auto completedAt = parseIso(thread.latestRun->completedAt);
  if (!completedAt) return false;
  if (!thread.lastVisitedAt || thread.lastVisitedAt->isEmpty()) return false;
  const auto visitedAt = parseIso(thread.lastVisitedAt);
  if (!visitedAt) return true;
  return *completedAt > *visitedAt;
}

Nullable statusLabel(const Thread& thread) {
  if (thread.hasPendingApprovals) return QStringLiteral("Pending Approval");
  if (thread.hasPendingUserInput) return QStringLiteral("Awaiting Input");
  const QString runtime = thread.runtime ? thread.runtime->status : QString();
  if (runtime == QLatin1String("running") || runtime == QLatin1String("waiting")) {
    return QStringLiteral("Working");
  }
  if (runtime == QLatin1String("preparing") || runtime == QLatin1String("starting") ||
      runtime == QLatin1String("queued")) {
    return QStringLiteral("Connecting");
  }
  if (thread.pendingBackgroundTasks > 0) return QStringLiteral("Waiting");
  if (thread.interactionMode == QLatin1String("plan") && latestRunSettled(thread) &&
      thread.hasActionableProposedPlan) {
    return QStringLiteral("Plan Ready");
  }
  if (unread(thread)) return QStringLiteral("Completed");
  return std::nullopt;
}

Nullable visibleWokeAt(const Thread& thread, qint64 nowMs) {
  // A thread settled by hand has nothing left to wake for.
  if (thread.settledOverride == QStringLiteral("settled")) return std::nullopt;
  const Nullable woke = wokeAt(thread, nowMs);
  if (!woke) return std::nullopt;
  if (!thread.lastVisitedAt) return woke;
  const auto visitedAt = parseIso(thread.lastVisitedAt);
  const auto wokeMs = parseIso(woke);
  if (!visitedAt || (wokeMs && *visitedAt < *wokeMs)) return woke;
  return std::nullopt;
}

Partition partition(const QList<Thread>& threads, const std::optional<QSet<QString>>& scopedProjectKeys,
                    const CapabilitiesFor& capabilitiesFor, qint64 nowMs) {
  Partition result;
  for (const Thread& thread : threads) {
    // Archived threads are hidden; subagents live in their parent's Agents surface.
    if (thread.archivedAt || thread.subagent) continue;
    if (scopedProjectKeys &&
        !scopedProjectKeys->contains(thread.environmentId + QLatin1Char(':') + thread.projectId)) {
      continue;
    }
    // Environments without the capability never shelve a thread the user
    // could not bring back.
    const Capabilities capabilities = capabilitiesFor(thread.environmentId);
    if (capabilities.snooze && effectiveSnoozed(thread, nowMs)) {
      result.snoozed.append(thread);
    } else if (capabilities.settlement && thread.settledOverride == QStringLiteral("settled")) {
      result.settled.append(thread);
    } else if (thread.pinnedAt) {
      result.pinned.append(thread);
    } else {
      result.active.append(thread);
    }
  }
  sortPinned(result.pinned);
  sortActive(result.active);
  // Soonest wake first.
  std::stable_sort(result.snoozed.begin(), result.snoozed.end(), [](const Thread& left, const Thread& right) {
    return sortableMs(left.snoozedUntil) < sortableMs(right.snoozedUntil);
  });
  sortSettled(result.settled);
  return result;
}

Input Input::fromVariant(const QVariant& value) {
  const QVariantMap map = value.toMap();
  Input input;
  for (const QVariant& entry : map.value(QStringLiteral("projects")).toList()) {
    QVariantMap project = entry.toMap();
    ProjectGroup group;
    group.key = project.value(QStringLiteral("key")).toString();
    group.memberKeys = project.take(QStringLiteral("memberKeys")).toStringList();
    group.summary = project;
    input.projects.append(group);
  }
  input.localEnvironmentId = map.value(QStringLiteral("localEnvironmentId"), QVariant::fromValue(nullptr));
  input.localProjects = map.value(QStringLiteral("localProjects")).toList();
  input.drafts = map.value(QStringLiteral("drafts")).toList();
  const QVariant activeThreadKey = map.value(QStringLiteral("activeThreadKey"));
  if (activeThreadKey.typeId() == QMetaType::QString) input.activeThreadKey = activeThreadKey.toString();
  input.activeDraftId = map.value(QStringLiteral("activeDraftId"), QVariant::fromValue(nullptr));
  input.timestampFormat = map.value(QStringLiteral("timestampFormat"), QStringLiteral("locale")).toString();
  const QVariant scopeProjectKey = map.value(QStringLiteral("scopeProjectKey"));
  if (scopeProjectKey.typeId() == QMetaType::QString) input.scopeProjectKey = scopeProjectKey.toString();
  return input;
}

const ProjectGroup* Input::group(const QString& key) const {
  for (const ProjectGroup& group : projects) {
    if (group.key == key) return &group;
  }
  return nullptr;
}

View build(const QList<Thread>& threads, const Input& input, const Nullable& scopeProjectKey,
           const CapabilitiesFor& capabilitiesFor, qint64 nowMs) {
  QHash<QString, QString> logicalKeyByPhysicalKey;
  for (const ProjectGroup& group : input.projects) {
    for (const QString& member : group.memberKeys) logicalKeyByPhysicalKey.insert(member, group.key);
  }
  QHash<QString, int> threadCounts;
  for (const Thread& thread : threads) {
    if (thread.archivedAt) continue;
    const auto logical = logicalKeyByPhysicalKey.constFind(thread.environmentId + QLatin1Char(':') + thread.projectId);
    if (logical != logicalKeyByPhysicalKey.constEnd()) threadCounts[*logical] += 1;
  }

  const ProjectGroup* scoped = scopeProjectKey ? input.group(*scopeProjectKey) : nullptr;
  std::optional<QSet<QString>> scopedProjectKeys;
  if (scoped) scopedProjectKeys = QSet<QString>(scoped->memberKeys.begin(), scoped->memberKeys.end());
  const Partition sections = partition(threads, scopedProjectKeys, capabilitiesFor, nowMs);

  View view;
  const auto convert = [&](const QList<Thread>& section, bool snoozed, bool parked, qsizetype limit) {
    QVariantList rows;
    for (const Thread& thread : section) {
      view.orderedKeys.append(thread.key());
      if (parked) view.parkedKeys.insert(thread.key());
      if (rows.size() >= limit) continue;
      const QString physical = thread.environmentId + QLatin1Char(':') + thread.projectId;
      const Capabilities capabilities = capabilitiesFor(thread.environmentId);
      rows.append(QVariantMap{
          {QStringLiteral("key"), thread.key()},
          {QStringLiteral("threadId"), thread.id},
          {QStringLiteral("environmentId"), thread.environmentId},
          {QStringLiteral("projectKey"), logicalKeyByPhysicalKey.value(physical, physical)},
          {QStringLiteral("title"), thread.title},
          {QStringLiteral("status"), status(thread)},
          {QStringLiteral("statusLabel"), nullable(statusLabel(thread))},
          {QStringLiteral("unread"), unread(thread)},
          {QStringLiteral("branch"), nullable(thread.branch)},
          {QStringLiteral("createdAt"), thread.createdAt},
          {QStringLiteral("latestUserMessageAt"), nullable(thread.latestUserMessageAt)},
          {QStringLiteral("updatedAt"), thread.updatedAt},
          {QStringLiteral("pinned"), thread.pinnedAt.has_value()},
          {QStringLiteral("snoozedUntil"), nullable(thread.snoozedUntil)},
          {QStringLiteral("wakeLabel"),
           snoozed && thread.snoozedUntil ? QVariant(wakeLabel(*thread.snoozedUntil, nowMs))
                                          : QVariant::fromValue(nullptr)},
          {QStringLiteral("wokeAt"), nullable(visibleWokeAt(thread, nowMs))},
          {QStringLiteral("canSettle"), capabilities.settlement},
          {QStringLiteral("canSnooze"), capabilities.snooze && canSnooze(thread, nowMs)},
      });
    }
    return rows;
  };
  const qsizetype unlimited = std::numeric_limits<qsizetype>::max();
  const QVariantList pinned = convert(sections.pinned, false, false, unlimited);
  const QVariantList active = convert(sections.active, false, false, unlimited);
  const QVariantList snoozed = convert(sections.snoozed, true, true, unlimited);
  const QVariantList settled = convert(sections.settled, false, true, kSettledLimit);

  QVariantList projects;
  for (const ProjectGroup& group : input.projects) {
    QVariantMap project = group.summary;
    project.insert(QStringLiteral("threadCount"), threadCounts.value(group.key));
    projects.append(project);
  }
  QVariantList drafts;
  for (const QVariant& draft : input.drafts) {
    if (scoped && draft.toMap().value(QStringLiteral("projectKey")).toString() != scoped->key) continue;
    drafts.append(draft);
  }
  view.state = QVariantMap{
      {QStringLiteral("localEnvironmentId"), input.localEnvironmentId},
      {QStringLiteral("localProjects"), input.localProjects},
      {QStringLiteral("projects"), projects},
      {QStringLiteral("scopeProjectKey"), nullable(scopeProjectKey)},
      {QStringLiteral("pinned"), pinned},
      {QStringLiteral("active"), active},
      {QStringLiteral("snoozed"), snoozed},
      {QStringLiteral("settled"), settled},
      {QStringLiteral("settledTotal"), sections.settled.size()},
      {QStringLiteral("drafts"), drafts},
      {QStringLiteral("activeThreadKey"), nullable(input.activeThreadKey)},
      {QStringLiteral("activeDraftId"), input.activeDraftId},
  };
  return view;
}

QString timeOfDay(const QDateTime& local, const QString& timestampFormat, const QLocale& locale) {
  if (timestampFormat == QLatin1String("12-hour")) return locale.toString(local.time(), QStringLiteral("h:mm AP"));
  if (timestampFormat == QLatin1String("24-hour")) return locale.toString(local.time(), QStringLiteral("HH:mm"));
  return locale.toString(local.time(), QLocale::ShortFormat);
}

QList<SnoozePreset> snoozePresets(const QDateTime& now, const QString& timestampFormat,
                                  const QLocale& locale) {
  const auto time = [&](const QDateTime& at) { return timeOfDay(at, timestampFormat, locale); };
  const QDateTime inAnHour = now.addMSecs(kHourMs);
  const QDateTime inThreeHours = now.addMSecs(3 * kHourMs);
  QList<SnoozePreset> presets{
      {QStringLiteral("hour"), QStringLiteral("In 1 hour"), time(inAnHour), formatIso(inAnHour)},
      {QStringLiteral("three-hours"), QStringLiteral("In 3 hours"), time(inThreeHours), formatIso(inThreeHours)},
  };
  // "This evening" only while it is meaningfully ahead.
  const QDateTime evening = localAt(now.date(), 18);
  if (now.msecsTo(evening) > kHourMs) {
    presets.append({QStringLiteral("evening"), QStringLiteral("This evening"), time(evening), formatIso(evening)});
  }
  // Calendar-day steps, not 24h offsets, so DST days land on the right date.
  const QDateTime tomorrow = localAt(now.date().addDays(1), 9);
  presets.append({QStringLiteral("tomorrow"), QStringLiteral("Tomorrow"), time(tomorrow), formatIso(tomorrow)});
  const int weekday = now.date().dayOfWeek() % 7;  // Sunday = 0, as JavaScript counts
  const int daysUntilMonday = (1 - weekday + 7) % 7 == 0 ? 7 : (1 - weekday + 7) % 7;
  const QDateTime nextWeek = localAt(now.date().addDays(daysUntilMonday), 9);
  // On Sundays "Tomorrow" already is next week.
  if (nextWeek != tomorrow) {
    presets.append({QStringLiteral("next-week"), QStringLiteral("Next week"),
                    locale.toString(nextWeek.date(), QStringLiteral("ddd")) + QLatin1Char(' ') + time(nextWeek),
                    formatIso(nextWeek)});
  }
  return presets;
}

QString wakeDescription(const QString& snoozedUntil, const QDateTime& now,
                        const QString& timestampFormat, const QLocale& locale) {
  const auto wakeMs = parseIso(snoozedUntil);
  if (!wakeMs) return {};
  const QDateTime wake = QDateTime::fromMSecsSinceEpoch(*wakeMs).toLocalTime();
  const QString time = timeOfDay(wake, timestampFormat, locale);
  const qint64 sinceStartOfToday = QDateTime(now.toLocalTime().date(), QTime(0, 0)).msecsTo(wake);
  const qint64 dayDelta = static_cast<qint64>(std::floor(static_cast<double>(sinceStartOfToday) / kDayMs));
  if (dayDelta == 0) return time;
  if (dayDelta == 1) return QStringLiteral("tomorrow ") + time;
  if (dayDelta < 7) return locale.toString(wake.date(), QStringLiteral("ddd")) + QLatin1Char(' ') + time;
  return locale.toString(wake.date(), QStringLiteral("MMM d")) + QStringLiteral(", ") + time;
}

}  // namespace sidebar
