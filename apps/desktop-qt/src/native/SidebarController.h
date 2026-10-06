#pragma once

#include <QDateTime>
#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QLocale>
#include <QObject>
#include <QSet>
#include <QTimeZone>
#include <QTimer>
#include <QVariant>

#include <functional>
#include <optional>

#include "SidebarModel.h"

class McClient;
class ShellBridge;
class ShellStore;
class ToastController;

// Owns the `sidebar` key once the shell has its MC's first snapshot: rows
// and projects come from ShellStore, grouped as the web app groups them
// (sidebar::groupProjects), drafts from DraftController, and the row actions
// (settle, snooze, wake, mark unread, dismiss the woke pill) and the project
// scope stay here.
//
// As the web app's SidebarDraftBlock, a draft is listed only once it holds
// something (ComposerController::draftPreview), newest first. The draft the
// window shows keeps the row it had when the window opened it: none for one
// that was empty then, and the same label however the user types.
class SidebarController : public QObject {
  Q_OBJECT

public:
  SidebarController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  // Starts publishing `sidebar` and claiming its actions.
  void activate();
  // Publishes `sidebar` from rows the cache kept, before the MC answers;
  // actions wait for activate().
  void preview();
  bool isActive() const { return m_active; }

  // The logical projects, in sidebar order.
  const QList<sidebar::ProjectGroup>& groups() const { return m_groups; }
  const sidebar::ProjectGroup* group(const QString& key) const;
  // The logical project `<environmentId>:<projectId>` belongs to.
  std::optional<QString> logicalProjectKey(const QString& environmentId, const QString& projectId) const;
  // The project the list is scoped to, if any.
  const sidebar::Nullable& scope() const { return m_scope; }
  // The rows' keys in the order they render.
  const QStringList& orderedKeys() const { return m_view.orderedKeys; }
  // The threads selected for a bulk action, in the order they render:
  // `thread.select.toggle {key}` adds or removes one, `thread.select.range
  // {key}` selects from the anchor (the last one toggled or opened) to it,
  // `thread.select.clear` drops them all, as does scoping the list or opening
  // a thread. As the web app's threadSelectionStore.
  QStringList selection() const;
  void clearSelection();
  void deselect(const QStringList& keys);

  // Tests pin the clock and locale; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  QDateTime now() const { return m_now(); }
  void setLocale(const QLocale& locale) { m_locale = locale; }
  void setTimeZone(const QTimeZone& zone) { m_zone = zone; }

  void refresh();
  // The draft `id` was edited in some window: refreshes when its row here
  // would change.
  void draftEdited(const QString& id);
  // The ShellBridge interceptor: true when the action was handled here.
  bool handle(const QString& action, const QVariant& payload);

  // Where a window that showed a parked thread goes, as the web app does:
  // settling and snoozing move to the next card, else a new thread in the
  // project (useThreadParking); archiving to a new thread in the project
  // (useThreadActions archiveThread); deleting to the project's first other
  // thread (fallbackAfterDelete), else nowhere, which lands the window on a
  // draft (DraftController::land).
  enum class Leave { NextCard, ProjectDraft, ProjectFallback };
  // Runs `command`, which takes the thread `key` out of the list (settle,
  // snooze, archive, delete); the window moves on as `leave` says when it
  // showed the thread, once the command lands. Failures toast `failureTitle`.
  void park(const QString& key, QJsonObject command, const QString& failureTitle, Leave leave,
            std::function<void()> onSuccess = {});
  // Whether park() is waiting on the MC for the thread `key`.
  bool parking(const QString& key) const { return m_pending.contains(key); }
  // Arranging: `thread.move {key, direction: "up"|"down"}` moves a pinned or
  // active row one place; `thread.drop {key, section, beforeKey}` puts a
  // dragged row before the row `beforeKey` of `section` (at its end without
  // one). A drop within the pinned or the active rows reorders them; into
  // another section it pins (at the drop position), unpins, settles,
  // un-settles or wakes the thread, and into the snoozed shelf does nothing.
  // The order is the environment's (sidebar::planReorder), which has to
  // support it (threadPinReorder, threadActiveReorder).
  // While the thread jump modifier is held (KeybindingController), the first
  // nine rows show the key that opens them (`jumpLabel`).
  void setJumpHints(const QStringList& labels, bool shown);
  // `thread.attachFiles {key, files}` (files dropped on a row, read by the
  // brick as the composer reads its own): opens the thread and attaches them.
  // A wake time of the user's own: every snooze menu ends in "Custom…"
  // (kCustomSnooze), which asks through `customSnooze` ({keys, date, time,
  // error}, the CustomSnoozeDialog brick). `snooze.custom.submit {mode, date,
  // time, amount, unit}` snoozes the threads it was asked for, or says what is
  // wrong with the time; `snooze.custom.cancel` closes it.
  static inline const QString kCustomSnooze = QStringLiteral("snooze:custom");
  void askCustomSnooze(const QStringList& keys);
  // Whether the row can move one place `up` or down within its section.
  bool canMove(const QString& key, bool up) const;
  // The snooze choices now, and snoozing the thread `key` until one's time,
  // with an Undo toast.
  QList<sidebar::SnoozePreset> snoozePresets() const;
  static QString snoozeLabel(const sidebar::SnoozePreset& preset);
  void snooze(const QString& key, const QString& snoozedUntil);

signals:
  // The logical projects were grouped differently: one came, went, or took
  // other folders (a checkout, or a change of grouping).
  void grouped();

private:
  void command(const QString& environmentId, QJsonObject command, const QString& failureTitle,
               std::function<void()> onSuccess = {});
  void openSnoozeMenu(const QString& key, double x, double y);
  // The keys the section ("pinned" or "active") lists, in order.
  QStringList sectionKeys(const QString& section) const;
  QString sectionOf(const QString& key) const;
  // Writes the order keys that put `key` where `ordered` has it; when
  // `pinning`, the thread is pinned with its key instead of reordered.
  void arrange(const QString& section, const QStringList& ordered, const QString& key, bool pinning = false);
  void drop(const QString& key, const QString& section, const QString& beforeKey);
  ToastController* toasts() const;
  // The client settings grouping, ordering and time labels read, from this
  // device's preferences (SettingsController), else their defaults.
  void readSettings();
  // Reading a thread is a visit: while the window shows one, the MC is told
  // the thread was seen up to its newest change (`thread.visit`, visitedAt
  // its updatedAt), which clears "Done" on every device. As the web app's
  // ChatView: once per change, an unseen completion at once and other
  // activity at most every few seconds; an MC that does not keep the
  // watermark (no `lastVisitedAt` on its rows) is not told.
  void visitOpenThread();
  // Threads the MC brought over from the first version (`historyOrigin`
  // "v1_import") are announced once per device, the first time they are listed.
  void announceMigratedThreads();
  // The open thread, from the shell's route.
  QString activeThreadKey() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTime(); };
  QLocale m_locale;
  QTimer m_minute;
  bool m_active = false;
  bool m_previewing = false;
  sidebar::GroupingSettings m_grouping;
  QString m_timestampFormat = QStringLiteral("locale");
  QString m_threadSortOrder = QStringLiteral("updated_at");
  QList<sidebar::ProjectGroup> m_groups;
  sidebar::Nullable m_scope;
  sidebar::View m_view;
  QSet<QString> m_pending;
  QTimeZone m_zone = QTimeZone::systemTimeZone();
  // The threads the custom snooze question is about.
  QStringList m_customSnoozeKeys;
  QStringList m_jumpLabels;
  bool m_showJumpHints = false;
  QString m_visited;  // "<thread key>:<updatedAt>" of the last visit sent
  QElapsedTimer m_sinceVisit;
  QTimer m_visitLater;
  QSet<QString> m_selected;
  QString m_anchor;
  // The listed drafts' labels, and the open draft's row as it was when the
  // window opened it (nothing when it was empty).
  QHash<QString, QString> m_draftLabels;
  QString m_openDraftId;
  std::optional<QString> m_openDraftLabel;
};
