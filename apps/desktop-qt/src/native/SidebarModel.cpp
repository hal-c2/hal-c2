#include "SidebarModel.h"

#include <QHash>
#include <QJsonArray>
#include <QRegularExpression>

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

// Missing and malformed timestamps sort as the epoch, as the web app's sorts do.
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
  thread.movingTo = stringField(row.value(QLatin1String("moving")).toObject(), "label");
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
    // Rows from before the MC stamped completion close the run at updatedAt.
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

QString mostUrgentStatus(const QStringList& statuses) {
  static const QStringList order{QStringLiteral("approval"), QStringLiteral("input"), QStringLiteral("working"),
                                 QStringLiteral("waiting"), QStringLiteral("limited"), QStringLiteral("failed")};
  for (const QString& candidate : order) {
    if (statuses.contains(candidate)) return candidate;
  }
  return QStringLiteral("ready");
}

QString workingLabel(const Thread& thread, qint64 nowMs) {
  if (status(thread) != QLatin1String("working") || !thread.latestRun) return {};
  const auto startedAt = parseIso(thread.latestRun->startedAt ? thread.latestRun->startedAt : thread.latestRun->requestedAt);
  if (!startedAt) return {};
  const qint64 minutes = std::max<qint64>(0, nowMs - *startedAt) / kMinuteMs;
  if (minutes < 1) return {};
  if (minutes < 60) return QStringLiteral("%1m").arg(minutes);
  return QStringLiteral("%1h %2m").arg(minutes / 60).arg(minutes % 60);
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

Project projectFromRow(const QString& environmentId, const QJsonObject& row) {
  Project project;
  project.environmentId = environmentId;
  project.id = row.value(QLatin1String("id")).toString();
  project.title = row.value(QLatin1String("title")).toString();
  project.workspaceRoot = row.value(QLatin1String("workspaceRoot")).toString();
  project.createdAt = row.value(QLatin1String("createdAt")).toString();
  project.updatedAt = row.value(QLatin1String("updatedAt")).toString();
  const QJsonValue identity = row.value(QLatin1String("repositoryIdentity"));
  if (identity.isObject()) {
    const QJsonObject fields = identity.toObject();
    project.repositoryIdentity = RepositoryIdentity{
        fields.value(QLatin1String("canonicalKey")).toString(),
        stringField(fields, "rootPath"),
        stringField(fields, "displayName"),
        stringField(fields, "name"),
    };
  }
  return project;
}

namespace {

bool isWindowsDrivePath(const QString& value) {
  static const QRegularExpression drive(QStringLiteral("^[a-zA-Z]:([/\\\\]|$)"));
  return drive.match(value).hasMatch();
}

QString trimTrailingSeparators(const QString& value) {
  static const QRegularExpression root(QStringLiteral("^([/\\\\]|[a-zA-Z]:[/\\\\])$"));
  if (value.isEmpty() || root.match(value).hasMatch()) return value;
  static const QRegularExpression unixTrailing(QStringLiteral("/+$"));
  static const QRegularExpression anyTrailing(QStringLiteral("[\\\\/]+$"));
  QString trimmed = value;
  trimmed.remove(value.startsWith(QLatin1Char('/')) ? unixTrailing : anyTrailing);
  if (trimmed.isEmpty()) return value;
  static const QRegularExpression bareDrive(QStringLiteral("^[a-zA-Z]:$"));
  return bareDrive.match(trimmed).hasMatch() ? trimmed + QLatin1Char('\\') : trimmed;
}

// Where a project sits under its repository root, "" at the root itself, or
// nothing when it is outside it.
Nullable repositoryRelativePath(const Project& project) {
  const QString rootPath = project.repositoryIdentity->rootPath.value_or(QString()).trimmed();
  if (rootPath.isEmpty()) return std::nullopt;
  const QString projectPath = normalizePath(project.workspaceRoot);
  const QString normalizedRoot = normalizePath(rootPath);
  if (projectPath.isEmpty() || normalizedRoot.isEmpty()) return std::nullopt;
  if (projectPath == normalizedRoot) return QString();
  const QString prefix = normalizedRoot + (normalizedRoot.contains(QLatin1Char('\\')) ? QLatin1Char('\\') : QLatin1Char('/'));
  if (!projectPath.startsWith(prefix)) return std::nullopt;
  return projectPath.mid(prefix.size()).replace(QLatin1Char('\\'), QLatin1Char('/'));
}

QString logicalKey(const Project& project, const QString& mode) {
  if (mode == QLatin1String("separate") || !project.repositoryIdentity ||
      project.repositoryIdentity->canonicalKey.isEmpty()) {
    return physicalKey(project);
  }
  const QString& canonicalKey = project.repositoryIdentity->canonicalKey;
  if (mode == QLatin1String("repository")) return canonicalKey;
  const Nullable relative = repositoryRelativePath(project);
  if (!relative || relative->isEmpty()) return canonicalKey;
  return canonicalKey + QStringLiteral("::") + *relative;
}

qint64 freshness(const Project& project) {
  if (const auto updated = parseIso(project.updatedAt)) return *updated;
  return parseIso(project.createdAt).value_or(0);
}

bool fresher(const Project& candidate, const Project& existing) {
  const qint64 delta = freshness(candidate) - freshness(existing);
  return delta > 0 || (delta == 0 && candidate.id > existing.id);
}

QStringList uniqueNonEmpty(const QStringList& values) {
  QStringList unique;
  for (const QString& value : values) {
    const QString trimmed = value.trimmed();
    if (!trimmed.isEmpty() && !unique.contains(trimmed)) unique.append(trimmed);
  }
  return unique;
}

QString groupLabel(const Project& representative, const QList<Project>& members) {
  QStringList titles, displayNames, names;
  for (const Project& member : members) {
    titles.append(member.title);
    if (member.repositoryIdentity) {
      displayNames.append(member.repositoryIdentity->displayName.value_or(QString()));
      names.append(member.repositoryIdentity->name.value_or(QString()));
    }
  }
  titles = uniqueNonEmpty(titles);
  displayNames = uniqueNonEmpty(displayNames);
  names = uniqueNonEmpty(names);
  if (titles.size() == 1 && !displayNames.contains(titles.first()) && !names.contains(titles.first())) {
    return titles.first();
  }
  if (displayNames.size() == 1) return displayNames.first();
  if (names.size() == 1) return names.first();
  return representative.title;
}

constexpr double kNever = -std::numeric_limits<double>::infinity();

double timestamp(const Nullable& iso) {
  const auto ms = parseIso(iso);
  return ms ? double(*ms) : kNever;
}

double firstTimestamp(const Nullable& first, const Nullable& second) {
  if (const auto ms = parseIso(first)) return double(*ms);
  return timestamp(second);
}

double threadSortTimestamp(const Thread& thread, const QString& sortOrder) {
  if (sortOrder == QLatin1String("created_at")) return firstTimestamp(thread.createdAt, thread.updatedAt);
  if (const auto ms = parseIso(thread.latestUserMessageAt)) return double(*ms);
  return firstTimestamp(thread.updatedAt, thread.createdAt);
}

}  // namespace

QString normalizePath(const QString& path) {
  const QString normalized = trimTrailingSeparators(path.trimmed());
  if (isWindowsDrivePath(normalized) || normalized.startsWith(QStringLiteral("\\\\"))) {
    return QString(normalized).replace(QLatin1Char('/'), QLatin1Char('\\')).toLower();
  }
  return normalized;
}

QString physicalKey(const Project& project) {
  return project.environmentId + QLatin1Char(':') + normalizePath(project.workspaceRoot);
}

QList<ProjectGroup> groupProjects(const QList<Project>& projects, const GroupingSettings& settings,
                                  const QString& preferredEnvironmentId, const QList<Thread>& threads) {
  // Folders in first-seen order, each with every project row claiming it.
  QStringList folderOrder;
  QHash<QString, QList<Project>> byFolder;
  for (const Project& project : projects) {
    const QString folder = physicalKey(project);
    if (!byFolder.contains(folder)) folderOrder.append(folder);
    byFolder[folder].append(project);
  }

  QStringList groupOrder;
  QHash<QString, QList<Project>> members;
  QHash<QString, QString> logicalByFolder;
  for (const QString& folder : std::as_const(folderOrder)) {
    const QList<Project>& claims = byFolder.value(folder);
    const Project* winner = &claims.first();
    for (const Project& candidate : claims) {
      if (fresher(candidate, *winner)) winner = &candidate;
    }
    // The winner names the repository unless only an older row knows it.
    const Project* identitySource = winner;
    if (!winner->repositoryIdentity) {
      const Project* identified = nullptr;
      for (const Project& candidate : claims) {
        if (candidate.repositoryIdentity && (!identified || fresher(candidate, *identified))) identified = &candidate;
      }
      if (identified) identitySource = identified;
    }
    const QString key = logicalKey(*identitySource, settings.overrides.value(folder, settings.mode));
    logicalByFolder.insert(folder, key);
    if (!members.contains(key)) groupOrder.append(key);
    members[key].append(*winner);
  }

  QHash<QString, QStringList> memberKeys;
  QSet<QString> seen;
  for (const Project& project : projects) {
    if (seen.contains(project.key())) continue;
    seen.insert(project.key());
    memberKeys[logicalByFolder.value(physicalKey(project))].append(project.key());
  }

  struct Sorted {
    ProjectGroup group;
    QString title;
    double at = kNever;
  };
  QList<Sorted> sorted;
  QHash<QString, qsizetype> indexByProjectKey;
  for (const QString& key : std::as_const(groupOrder)) {
    const QList<Project>& grouped = members.value(key);
    const Project* representative = &grouped.first();
    for (const Project& member : grouped) {
      if (!preferredEnvironmentId.isEmpty() && member.environmentId == preferredEnvironmentId) {
        representative = &member;
        break;
      }
    }
    Sorted entry;
    entry.group.key = key;
    entry.group.memberKeys = memberKeys.value(key);
    entry.group.members = grouped;
    entry.group.summary = QVariantMap{
        {QStringLiteral("key"), key},
        {QStringLiteral("displayName"),
         grouped.size() > 1 ? groupLabel(*representative, grouped) : representative->title},
        {QStringLiteral("environmentId"), representative->environmentId},
        {QStringLiteral("projectId"), representative->id},
        {QStringLiteral("workspaceRoot"), representative->workspaceRoot},
    };
    entry.title = representative->title;
    // A group without threads sorts by the representative's own stamps.
    entry.at = settings.sortOrder == QLatin1String("created_at")
                   ? timestamp(representative->createdAt)
                   : firstTimestamp(representative->updatedAt, representative->createdAt);
    for (const QString& member : std::as_const(entry.group.memberKeys)) indexByProjectKey.insert(member, sorted.size());
    sorted.append(entry);
  }

  // "manual" keeps the given order; the web app's hand-arranged order is not
  // carried over (native stores start fresh).
  if (settings.sortOrder != QLatin1String("manual")) {
    QSet<qsizetype> withThreads;
    for (const Thread& thread : threads) {
      if (thread.archivedAt) continue;
      const auto index = indexByProjectKey.constFind(thread.environmentId + QLatin1Char(':') + thread.projectId);
      if (index == indexByProjectKey.constEnd()) continue;
      Sorted& entry = sorted[*index];
      const double at = threadSortTimestamp(thread, settings.sortOrder);
      if (!withThreads.contains(*index)) {
        withThreads.insert(*index);
        entry.at = at;
      } else {
        entry.at = std::max(entry.at, at);
      }
    }
    std::stable_sort(sorted.begin(), sorted.end(), [](const Sorted& left, const Sorted& right) {
      if (left.at != right.at) return left.at > right.at;
      if (const int byTitle = left.title.localeAwareCompare(right.title)) return byTitle < 0;
      return left.group.key.localeAwareCompare(right.group.key) < 0;
    });
  }
  QList<ProjectGroup> groups;
  for (const Sorted& entry : std::as_const(sorted)) groups.append(entry.group);
  return groups;
}

std::optional<Project> mostRecentProject(const QList<Project>& projects, const QList<Thread>& threads) {
  const QString sortOrder = QStringLiteral("updated_at");
  QHash<QString, double> latest;
  for (const Thread& thread : threads) {
    if (thread.archivedAt) continue;
    const QString key = thread.environmentId + QLatin1Char(':') + thread.projectId;
    const double at = threadSortTimestamp(thread, sortOrder);
    const auto found = latest.constFind(key);
    latest.insert(key, found == latest.constEnd() ? at : std::max(*found, at));
  }
  const auto stamp = [&latest](const Project& project) {
    return latest.value(project.key(), firstTimestamp(project.updatedAt, project.createdAt));
  };
  // Ties go by title, then environment, then id.
  const auto before = [](const Project& left, const Project& right) {
    if (const int byTitle = left.title.localeAwareCompare(right.title)) return byTitle < 0;
    if (const int byEnvironment = left.environmentId.compare(right.environmentId)) return byEnvironment < 0;
    return left.id.compare(right.id) < 0;
  };
  const Project* best = nullptr;
  double bestAt = kNever;
  for (const Project& project : projects) {
    const double at = stamp(project);
    if (!best || at > bestAt || (at == bestAt && before(project, *best))) {
      best = &project;
      bestAt = at;
    }
  }
  return best ? std::optional<Project>(*best) : std::nullopt;
}

std::optional<QString> fallbackAfterDelete(const QList<Thread>& threads, const QString& key, const QString& sortOrder) {
  const auto deleted = std::find_if(threads.cbegin(), threads.cend(), [&key](const Thread& thread) { return thread.key() == key; });
  if (deleted == threads.cend()) return std::nullopt;
  const Thread* best = nullptr;
  double bestAt = kNever;
  for (const Thread& thread : threads) {
    if (thread.environmentId != deleted->environmentId || thread.projectId != deleted->projectId || thread.id == deleted->id ||
        thread.archivedAt || thread.subagent) {
      continue;
    }
    // Ties go to the greater id, as sortThreads.
    const double at = threadSortTimestamp(thread, sortOrder);
    if (!best || at > bestAt || (at == bestAt && thread.id > best->id)) {
      best = &thread;
      bestAt = at;
    }
  }
  return best ? std::optional<QString>(best->key()) : std::nullopt;
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
  QHash<QString, QStringList> threadStatuses;
  for (const Thread& thread : threads) {
    if (thread.archivedAt) continue;
    const auto logical = logicalKeyByPhysicalKey.constFind(thread.environmentId + QLatin1Char(':') + thread.projectId);
    if (logical == logicalKeyByPhysicalKey.constEnd()) continue;
    threadCounts[*logical] += 1;
    if (!thread.subagent) threadStatuses[*logical].append(status(thread));
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
      const bool offline = input.offlineEnvironments.contains(thread.environmentId);
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
          {QStringLiteral("wakeDescription"),
           snoozed && thread.snoozedUntil && input.describeWake ? QVariant(input.describeWake(*thread.snoozedUntil))
                                                                : QVariant::fromValue(nullptr)},
          {QStringLiteral("workingLabel"), workingLabel(thread, nowMs)},
          {QStringLiteral("movingTo"), nullable(thread.movingTo)},
          {QStringLiteral("selected"), input.selectedKeys.contains(thread.key())},
          {QStringLiteral("wokeAt"), nullable(visibleWokeAt(thread, nowMs))},
          {QStringLiteral("offline"), offline},
          {QStringLiteral("canSettle"), !offline && capabilities.settlement},
          {QStringLiteral("canSnooze"), !offline && capabilities.snooze && canSnooze(thread, nowMs)},
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
    project.insert(QStringLiteral("status"), mostUrgentStatus(threadStatuses.value(group.key)));
    projects.append(project);
  }
  QVariantList drafts;
  for (const QVariant& draft : input.drafts) {
    if (scoped && draft.toMap().value(QStringLiteral("projectKey")).toString() != scoped->key) continue;
    drafts.append(draft);
  }
  QVariantList localProjects;
  if (input.localEnvironmentId) {
    for (const ProjectGroup& group : input.projects) {
      for (const Project& member : group.members) {
        if (member.environmentId != *input.localEnvironmentId) continue;
        localProjects.append(QVariantMap{
            {QStringLiteral("key"), member.key()},
            {QStringLiteral("logicalProjectKey"), group.key},
            {QStringLiteral("displayName"), member.title},
            {QStringLiteral("environmentId"), member.environmentId},
            {QStringLiteral("projectId"), member.id},
            {QStringLiteral("workspaceRoot"), member.workspaceRoot},
        });
      }
    }
  }
  view.state = QVariantMap{
      {QStringLiteral("localEnvironmentId"), nullable(input.localEnvironmentId)},
      {QStringLiteral("localProjects"), localProjects},
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
  // In the order the rows render.
  QStringList selected;
  for (const QString& key : std::as_const(view.orderedKeys)) {
    if (input.selectedKeys.contains(key)) selected.append(key);
  }
  view.state.insert(QStringLiteral("selectedKeys"), selected);
  return view;
}

namespace {

const QString kOrderDigits = QStringLiteral("abcdefghijklmnopqrstuvwxyz");

bool validOrderKey(const QString& key) {
  if (key.isEmpty()) return false;
  for (const QChar c : key) {
    if (!kOrderDigits.contains(c)) return false;
  }
  // A trailing lowest digit leaves no room for a key just before this one.
  return key.back() != kOrderDigits.front();
}

// The midpoint of two digit strings read as fractions; "" is the open bound.
QString orderMidpoint(const QString& a, const QString& b) {
  if (!b.isEmpty()) {
    qsizetype n = 0;
    while (n < b.size() && (n < a.size() ? a.at(n) : kOrderDigits.front()) == b.at(n)) ++n;
    if (n > 0) return b.left(n) + orderMidpoint(a.mid(n), b.mid(n));
  }
  const qsizetype digitA = a.isEmpty() ? 0 : kOrderDigits.indexOf(a.front());
  const qsizetype digitB = b.isEmpty() ? kOrderDigits.size() : kOrderDigits.indexOf(b.front());
  if (digitB - digitA > 1) return QString(kOrderDigits.at((digitA + digitB + 1) / 2));
  if (b.size() > 1) return QString(b.front());
  return QString(kOrderDigits.at(digitA)) + orderMidpoint(a.mid(1), QString());
}

}  // namespace

Nullable orderKeyBetween(const Nullable& before, const Nullable& after) {
  const QString a = before.value_or(QString());
  const QString b = after.value_or(QString());
  if (!a.isEmpty() && !validOrderKey(a)) return std::nullopt;
  if (!b.isEmpty() && !validOrderKey(b)) return std::nullopt;
  if (!b.isEmpty() && a >= b) return std::nullopt;
  return orderMidpoint(a, b);
}

QStringList spreadOrderKeys(int count) {
  const qsizetype base = kOrderDigits.size();
  int width = 2;
  double space = double(base) * base;
  while (space <= (count + 1) * 2) {
    ++width;
    space *= base;
  }
  const double step = space / (count + 1);
  QStringList keys;
  for (int index = 0; index < count; ++index) {
    qint64 value = std::llround(step * (index + 1));
    if (value % base == 0) ++value;
    QString key;
    for (int digit = 0; digit < width; ++digit) {
      key.prepend(kOrderDigits.at(value % base));
      value /= base;
    }
    keys.append(key);
  }
  return keys;
}

QList<OrderAssignment> planReorder(const QStringList& orderedKeys, const QHash<QString, Nullable>& orderKeys,
                                   const QString& movedKey) {
  const qsizetype moved = orderedKeys.indexOf(movedKey);
  if (moved < 0) return {};
  QSet<QString> reserved;
  for (auto it = orderKeys.cbegin(); it != orderKeys.cend(); ++it) {
    if (!orderedKeys.contains(it.key()) && it.value()) reserved.insert(*it.value());
  }
  const bool hasBefore = moved > 0;
  const bool hasAfter = moved < orderedKeys.size() - 1;
  const Nullable beforeKey = hasBefore ? orderKeys.value(orderedKeys.at(moved - 1)) : std::nullopt;
  const Nullable afterKey = hasAfter ? orderKeys.value(orderedKeys.at(moved + 1)) : std::nullopt;
  if ((!hasBefore || beforeKey) && (!hasAfter || afterKey)) {
    Nullable key = orderKeyBetween(beforeKey, afterKey);
    while (key && reserved.contains(*key)) key = orderKeyBetween(key, afterKey);
    if (key) return {{movedKey, *key}};
  }
  // A neighbour without a key (or corrupt ones): the section gets fresh keys in the new order.
  QStringList fresh = spreadOrderKeys(int(orderedKeys.size() + reserved.size()));
  fresh.removeIf([&reserved](const QString& key) { return reserved.contains(key); });
  QList<OrderAssignment> assignments;
  for (qsizetype index = 0; index < orderedKeys.size(); ++index) {
    if (orderKeys.value(orderedKeys.at(index)) != fresh.at(index)) assignments.append({orderedKeys.at(index), fresh.at(index)});
  }
  return assignments;
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
