#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QLocale>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTimeZone>
#include <QVariantMap>

#include <functional>
#include <optional>

// The native sidebar's rules: the MC's thread rows in, the `sidebar` view
// model out. A port of the web app's shell sidebar (apps/web/src/shell/
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

// One thread row of the MC's shell shape, as the sidebar and composer read it.
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
  // The machine the thread is on its way to, while a move is under way.
  Nullable movingTo;
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
// The most urgent of `statuses` (approval, input, working, waiting, then the
// rest), as the web app's resolveProjectStatusIndicator; "ready" when none is.
QString mostUrgentStatus(const QStringList& statuses);
// How long a working thread's run has been going ("3m", "1h 5m"); empty
// under a minute and for a thread that is not working.
QString workingLabel(const Thread& thread, qint64 nowMs);
Nullable statusLabel(const Thread& thread);
bool unread(const Thread& thread);
Nullable visibleWokeAt(const Thread& thread, qint64 nowMs);

struct Capabilities {
  bool settlement = false;
  bool snooze = false;
  // The MC keeps the visited watermark; without it there are no unread markers.
  bool visitedTracking = false;
  bool pinning = false;
  bool titleRegeneration = false;
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

// One project row of the MC's shell shape.
struct RepositoryIdentity {
  QString canonicalKey;
  Nullable rootPath;
  Nullable displayName;
  Nullable name;
};

struct Project {
  QString environmentId;
  QString id;
  QString title;
  QString workspaceRoot;
  QString createdAt;
  QString updatedAt;
  std::optional<RepositoryIdentity> repositoryIdentity;

  QString key() const { return environmentId + QLatin1Char(':') + id; }
};

Project projectFromRow(const QString& environmentId, const QJsonObject& row);

// A workspace path in the form two paths compare in: trimmed, without trailing
// separators, and Windows paths case- and separator-folded (@hal-c2/shared/path).
QString normalizePath(const QString& path);
// `<environmentId>:<normalized workspace root>`: one folder on one machine.
QString physicalKey(const Project& project);

// The client settings grouping and ordering read: sidebarProjectGroupingMode
// ("repository", "repository_path" or "separate"), its per-folder overrides
// keyed by physical key, and sidebarProjectSortOrder ("updated_at",
// "created_at" or "manual").
struct GroupingSettings {
  QString mode = QStringLiteral("repository");
  QHash<QString, QString> overrides;
  QString sortOrder = QStringLiteral("updated_at");
};

// A logical project: the folders grouped as one, across environments.
struct ProjectGroup {
  QString key;
  QVariantMap summary;  // key, displayName, environmentId, projectId, workspaceRoot
  // Every `<environmentId>:<projectId>` the group covers.
  QStringList memberKeys;
  // One winning project per folder, the navigation and creation targets.
  QList<Project> members;
};

// The web app's logical grouping (client-runtime's state/projectGrouping.ts) and
// sidebar order (Sidebar.logic.ts sortLogicalProjectsForSidebar), from every
// project the shell sees. Linked environments' projects are just more rows.
QList<ProjectGroup> groupProjects(const QList<Project>& projects, const GroupingSettings& settings,
                                  const QString& preferredEnvironmentId, const QList<Thread>& threads);

// The project a window with no thread lands in: the first of every project the
// shell sees in the web app's "updated_at" order (Sidebar.logic.ts
// sortScopedProjectsForSidebar), whatever order the sidebar is set to.
std::optional<Project> mostRecentProject(const QList<Project>& projects, const QList<Thread>& threads);

// Where a window that showed the deleted thread `key` goes: the first other
// thread of its project on its environment in `sortOrder` ("updated_at" or
// "created_at"), as the web app's getFallbackThreadIdAfterDelete, leaving out the
// archived and subagent rows the sidebar does not list either.
std::optional<QString> fallbackAfterDelete(const QList<Thread>& threads, const QString& key, const QString& sortOrder);

struct Input {
  QList<ProjectGroup> projects;
  // The environment of the MC the shell runs against; its folders are the
  // ones the folder explorer lists.
  Nullable localEnvironmentId;
  // Environments that are listed but unreachable; their rows stay, marked
  // offline, with the actions that need the environment off.
  QSet<QString> offlineEnvironments;
  // Drafts as the sidebar lists them: draftId, projectKey (logical), label.
  QVariantList drafts;
  Nullable activeThreadKey;
  QVariant activeDraftId;
  // The shortcut labels of the first rows' jump commands (thread.jump.1..9),
  // in order; each row carries its own while `showJumpHints`.
  QStringList jumpLabels;
  bool showJumpHints = false;
  // The rows selected for a bulk action.
  QSet<QString> selectedKeys;
  // A snoozed row's wake time in the user's clock format ("tomorrow 9:00");
  // the row has none when unset.
  std::function<QString(const QString& snoozedUntil)> describeWake;

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

// The order of the pinned and the active threads is kept as one key per
// thread (pinOrderKey, activeOrderKey): base-26 strings that sort as text, so
// moving a thread writes its own key only. A port of client-runtime's
// state/threadSort.ts (pinOrderKeyBetween, generateSpreadPinOrderKeys,
// planPinnedReorder).
//
// A key strictly between two neighbours; no bound is the section's edge.
// Nothing when the bounds are corrupt or out of order.
Nullable orderKeyBetween(const Nullable& before, const Nullable& after);
// `count` evenly spaced keys, for a section whose threads have none yet.
QStringList spreadOrderKeys(int count);
struct OrderAssignment {
  QString key;  // the thread's key
  QString orderKey;
};
// The writes that put `movedKey` where `orderedKeys` (the section as it
// should read) has it: one for the moved thread between keyed neighbours, or
// fresh keys for the whole section when a neighbour has none. `orderKeys`
// holds every thread of the section, the ones not shown too, whose keys stay.
QList<OrderAssignment> planReorder(const QStringList& orderedKeys, const QHash<QString, Nullable>& orderKeys,
                                   const QString& movedKey);

struct SnoozePreset {
  QString id;
  QString label;
  QString whenLabel;
  QString snoozedUntil;
};

// A wake time the user wrote: a date and a time of day in `zone`
// ("2026-09-25", "08:30"), or an amount of minutes, hours or days from now.
// Nothing for what cannot be read, is not in the future, or is a time of day
// the zone skips (a daylight saving change). As client-runtime's
// resolveCustomSnooze.
struct CustomSnooze {
  QString mode;  // "date" or "duration"
  QString date;
  QString time;
  QString amount;
  QString unit;  // "minutes", "hours" or "days"
};
Nullable resolveCustomSnooze(const CustomSnooze& input, const QDateTime& now, const QTimeZone& zone);

// "12-hour", "24-hour" or "locale", as the web app's timestampFormat setting.
QString timeOfDay(const QDateTime& local, const QString& timestampFormat, const QLocale& locale);
QList<SnoozePreset> snoozePresets(const QDateTime& now, const QString& timestampFormat,
                                  const QLocale& locale);
// "17:30" today, "tomorrow 9:00", "Mon 9:00", "Jan 5, 9:00".
QString wakeDescription(const QString& snoozedUntil, const QDateTime& now,
                        const QString& timestampFormat, const QLocale& locale);

}  // namespace sidebar
