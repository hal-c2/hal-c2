#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QString>

#include <optional>

// What the desktop says about provider updates, from the providers the MC
// reports (`config.providers`): the launch offer, its progress, the sidebar's
// notice, and the per-environment rows of an offer that spans several
// environments. Pure, so ProviderUpdateNotice only wires it to the MC and
// the toasts; ported from upstream's ProviderUpdateLaunchNotification.logic.ts.
namespace providerUpdates {

// packages/contracts PROVIDER_DISPLAY_NAMES.
QString driverName(const QString& driver);
// "0.51.0" as "v0.51.0".
QString version(const QString& value);
// A string by dotted path ("versionAdvisory.latestVersion").
QString field(const QJsonObject& object, const QString& path);
// updateState.status: queued, running, succeeded, failed, unchanged, or "".
QString status(const QJsonObject& provider);
// Queued or running.
bool active(const QJsonObject& provider);
// Enabled, behind a latest release this app can use.
bool candidate(const QJsonObject& provider);
// One provider per driver, in the order drivers first appear: its default
// instance (named after the driver), else the one checked last.
QList<QJsonObject> byDriver(const QList<QJsonObject>& providers);
// The outdated providers, one per driver.
QList<QJsonObject> candidates(const QJsonArray& providers);
// Updated in one click: not already updating, and every outdated instance of
// its driver updates here with the same command.
bool oneClick(const QJsonObject& candidate, const QJsonArray& providers);
// The versions on offer, "codex:0.51.0|claudeAgent:2.1.0" sorted; empty for none.
QString key(const QList<QJsonObject>& candidates);
// "Codex", "Codex and Claude", "Codex, Claude, and Cursor".
QString list(const QList<QJsonObject>& providers);
// The newest checkedAt of `providers`; empty when none says.
QString latestCheckedAt(const QJsonArray& providers);

// A toast's reading of an update.
struct View {
  // initial, running, failed, unchanged, succeeded.
  QString phase;
  // warning, loading, error, success.
  QString type;
  QString title;
  QString description;
  bool terminal() const;
};

// The offer: "Update Available: Codex v0.51.0", and whether it updates here.
View offer(const QList<QJsonObject>& candidates, bool oneClick);
// An update of `count` providers under way.
View running(int count);
// An update the MC refused outright.
View rejected(int count, const QString& message);
// How the update of `count` providers stands from their snapshots: failed,
// then unchanged, then running until every one reports it succeeded.
View progress(const QList<QJsonObject>& snapshots, int count);
// One snapshot per driver of an update across instances, the worst of how
// each went: failed, then unchanged, then running, then succeeded.
QList<QJsonObject> worstByDriver(const QList<QJsonObject>& snapshots);

// The sidebar's notice of a provider update: what runs, then the latest of
// what failed, stayed outdated or succeeded.
struct Notice {
  // Changes with the providers' update states, so a dismissed one returns
  // only once they change.
  QString key;
  // loading, error, warning, success.
  QString tone;
  QString title;
  QString description;
  bool dismissible = false;
  // A success goes away by itself after this long.
  int dismissAfterMs = 0;
};
// Only updates that finished at or after `visibleAfter` (an ISO time) are
// announced; every one when it is empty. A notice whose key is in `dismissed`
// gives way to the next.
std::optional<Notice> notice(const QList<QJsonObject>& providers, const QString& visibleAfter,
                             const QSet<QString>& dismissed = {});
std::optional<Notice> notice(const QJsonArray& providers, const QString& visibleAfter,
                             const QSet<QString>& dismissed = {});

// One environment of an offer that spans several.
struct Group {
  QString environmentId;
  QString label;
  // Its providers have not arrived yet (its MC still connecting).
  bool settling = false;
  // Its outdated providers that update here in one click.
  QList<QJsonObject> candidates;
  QJsonArray providers;
};
Group group(const QString& environmentId, const QString& label, const QJsonArray& providers, bool settling = false);
// "env-a=codex:0.51.0|wsl=claudeAgent:2.1.0": the set on offer; empty for none.
QString key(const QList<Group>& groups);

// How one environment's row stands.
struct RowStatus {
  // idle, loading, success, failed, unchanged.
  QString kind;
  QString text;
};

// The update of each environment of an offer: running, timed out, or how
// its answer said it went. Each start is a request with its own version, so
// an answer to one the user started again is dropped; an answer to the
// current one, however late, replaces a timeout.
class Rows {
public:
  // How long an update may go unanswered (upstream's PENDING_EXPIRY_MS).
  static constexpr qint64 kExpiryMs = 6 * 60 * 1000;

  // Starts an update on the environment: its request version, none while
  // one runs there.
  std::optional<int> start(const QString& environmentId, const QDateTime& now);
  // The answer to request `version`: an error, or the view of its snapshots;
  // only a terminal view is kept, the live state saying the rest.
  void settle(const QString& environmentId, int version, const QString& error, const std::optional<View>& result = {});
  // The environment's row says why it could not start.
  void refuse(const QString& environmentId, const QString& error);
  // The updates unanswered for kExpiryMs give up; whether any did.
  bool expire(const QDateTime& now);
  std::optional<QDateTime> deadline() const;
  bool running(const QString& environmentId) const;
  // The row, from its error, its kept result, the live state of its
  // candidates (finished at or after `visibleAfter`), then whether it runs.
  RowStatus status(const Group& group, const QString& visibleAfter) const;
  void clear() { m_rows.clear(); }

private:
  struct Row {
    int version = 0;
    bool running = false;
    std::optional<QDateTime> deadline;
    QString error;
    std::optional<View> result;
  };
  QHash<QString, Row> m_rows;
};

// What the sidebar shows of the environment's providers: announced once
// they finished after the providers were first seen, a success going away
// after its time, a dismissed one gone until its key changes.
class Sidebar {
public:
  // Whether the notice changed.
  bool setProviders(const QJsonArray& providers, const QDateTime& now);
  bool dismiss(const QDateTime& now);
  bool expire(const QDateTime& now);
  std::optional<QDateTime> deadline() const { return m_deadline; }
  const std::optional<Notice>& current() const { return m_notice; }

private:
  bool refresh(const QDateTime& now);

  QJsonArray m_providers;
  std::optional<QString> m_visibleAfter;
  QSet<QString> m_dismissed;
  std::optional<Notice> m_notice;
  std::optional<QDateTime> m_deadline;
};

// The ISO time the MC's timestamps compare with.
QString iso(const QDateTime& time);

}  // namespace providerUpdates
