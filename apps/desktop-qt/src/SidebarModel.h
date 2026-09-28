#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QLocale>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <functional>
#include <optional>

// The native sidebar's rules: the node's thread rows in, the `sidebar` view
// model out. A port of the page's shell sidebar (apps/web/src/shell/
// shellSidebarState.ts, Sidebar.logic.ts and client-runtime's
// state/threadSettled.ts, state/threadSort.ts), so both render the same rows.
// Pure: every clock is passed in.
namespace sidebar {

using Nullable = std::optional<QString>;

struct RunSummary {
  QString runId;
  QString status;
  Nullable requestedAt;
  Nullable startedAt;
  Nullable completedAt;
};

struct RuntimeSummary {
  QString status;
  Nullable activeRunId;
  Nullable lastErrorClass;
  QString updatedAt;
};

// One thread row of the node's shell shape, as the sidebar and composer read it.
struct Thread {
  QString environmentId;
  QString id;
  QString projectId;
  QString title;
  Nullable branch;
  QString createdAt;
  QString updatedAt;
  Nullable latestUserMessageAt;
  Nullable archivedAt;
  bool subagent = false;
  QString interactionMode;
  QString runtimeMode;
  QJsonObject modelSelection;
  Nullable settledOverride;
  Nullable settledAt;
  Nullable unsettledAt;
  Nullable snoozedUntil;
  Nullable snoozedAt;
  Nullable pinnedAt;
  Nullable pinOrderKey;
  Nullable activeOrderKey;
  Nullable lastVisitedAt;
  Nullable latestRunId;
  Nullable activeRunId;
  Nullable activityRunStatus;
  std::optional<RunSummary> latestRun;
  std::optional<RuntimeSummary> runtime;
  bool hasPendingApprovals = false;
  bool hasPendingUserInput = false;
  bool hasActionableProposedPlan = false;
  int pendingBackgroundTasks = 0;

  QString key() const { return environmentId + QLatin1Char(':') + id; }
};

Thread threadFromRow(const QString& environmentId, const QJsonObject& row);

// Epoch milliseconds of an ISO timestamp, or nothing when it does not parse.
std::optional<qint64> parseIso(const Nullable& iso);
QString formatIso(const QDateTime& time);

bool hasQueuedTurnStart(const Thread& thread, qint64 nowMs);
bool raisedHandWhileSnoozed(const Thread& thread);
bool canSnooze(const Thread& thread, qint64 nowMs);
bool effectiveSnoozed(const Thread& thread, qint64 nowMs);
Nullable wokeAt(const Thread& thread, qint64 nowMs);
QString wakeLabel(const QString& snoozedUntil, qint64 nowMs);
QString status(const Thread& thread);
Nullable statusLabel(const Thread& thread);
bool unread(const Thread& thread);
Nullable visibleWokeAt(const Thread& thread, qint64 nowMs);

struct Capabilities {
  bool settlement = false;
  bool snooze = false;
  // The node keeps the visited watermark; without it the page keeps unread markers.
  bool visitedTracking = false;
};
using CapabilitiesFor = std::function<Capabilities(const QString& environmentId)>;

struct Partition {
  QList<Thread> pinned;
  QList<Thread> active;
  QList<Thread> snoozed;
  QList<Thread> settled;
};

// `scopedProjectKeys` holds `<environmentId>:<projectId>` keys; none means every project.
Partition partition(const QList<Thread>& threads, const std::optional<QSet<QString>>& scopedProjectKeys,
                    const CapabilitiesFor& capabilitiesFor, qint64 nowMs);

// What the page publishes under `sidebarInput`: the project groups (they come
// from client settings and the page's own ordering), drafts and the route.
struct ProjectGroup {
  QString key;
  QVariantMap summary;  // key, displayName, environmentId, projectId, workspaceRoot
  QStringList memberKeys;
};

struct Input {
  QList<ProjectGroup> projects;
  QVariant localEnvironmentId;
  QVariantList localProjects;
  QVariantList drafts;
  Nullable activeThreadKey;
  QVariant activeDraftId;
  QString timestampFormat;

  static Input fromVariant(const QVariant& value);
  const ProjectGroup* group(const QString& key) const;
};

struct View {
  QVariantMap state;
  // Rows in the order they render (pinned, active, snoozed, settled), and
  // which of them are parked (snoozed or settled).
  QStringList orderedKeys;
  QSet<QString> parkedKeys;
};

inline constexpr int kSettledLimit = 50;

View build(const QList<Thread>& threads, const Input& input, const Nullable& scopeProjectKey,
           const CapabilitiesFor& capabilitiesFor, qint64 nowMs);

struct SnoozePreset {
  QString id;
  QString label;
  QString whenLabel;
  QString snoozedUntil;
};

// "12-hour", "24-hour" or "locale", as the page's timestampFormat setting.
QString timeOfDay(const QDateTime& local, const QString& timestampFormat, const QLocale& locale);
QList<SnoozePreset> snoozePresets(const QDateTime& now, const QString& timestampFormat,
                                  const QLocale& locale);
// "17:30" today, "tomorrow 9:00", "Mon 9:00", "Jan 5, 9:00".
QString wakeDescription(const QString& snoozedUntil, const QDateTime& now,
                        const QString& timestampFormat, const QLocale& locale);

}  // namespace sidebar
