#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <functional>
#include <optional>

class NativeShell;
class QNetworkAccessManager;
class ShellBridge;

namespace maintenance {

// What a machine's host lets the phone do about a server behind it
// (apps/tui updatePath): update it itself, have its desktop app update
// itself, only update the desktop app by hand on that machine, or run the
// command there.
enum class Path { Update, Desktop, DesktopManual, Command };
Path pathOf(const QJsonObject& capabilities);

// The channel a HAL-C2 version is on: "nightly", "preview" or "stable".
QString channelOf(const QString& version);
// The newest release of the index page on `channel` (tags `mc-v<version>`,
// drafts skipped), or nothing when the page has none.
std::optional<QString> newestOn(const QJsonArray& releases, const QString& channel);

// A provider the phone offers to update (canUpdateEnvironmentProvider):
// installed, available, behind a latest release that works, updatable by
// its MC, and not already updating.
bool canUpdateProvider(const QJsonObject& provider);
// What a finished provider update came to (apps/tui providerOutcome).
QString providerOutcome(const QJsonObject& provider);

}  // namespace maintenance

// The phone's maintenance of the environments it reaches (upstream T3 Code's
// environment detail screen, and the TUI's Updates page): each machine's
// HAL-C2 version against this app's and the newest release on the channel it
// follows, the update to that version, and the enabled providers on it with
// their updates. Only while the phone is connected and its session may
// operate (`orchestration:operate`); otherwise it says why.
//
// Publishes `maintenance`:
//   {appVersion,
//    machines: [{environmentId, label, version, online, local,
//                blocked:   why nothing can be started here, "" when it can,
//                path:      update | desktop | desktop-manual | command,
//                target:    the version an update moves it to, "" for none,
//                command:   what to run there by hand (`npx hal-c2@<target>`),
//                updating:  its update is running,
//                outcome:   {ok, text} of its last update, or null,
//                release:   {checking, text, available} of its release check, or null,
//                providers: [{instanceId, driver, name, version, latest,
//                             canUpdate, updating, status, outcome, failed}],
//                providersError}],
//    updatable: how many machines "Update all machines" would update,
//    groups:    [{driver, name, count}], a provider behind on several machines,
//    confirm:   {text} the user is asked before the desktop apps relaunch, or null,
//    message:   {ok, text} for the user, or null}
//
// Actions: `maintenance.open` and `maintenance.close` (the page is shown or
// left: providers and the session are read while it shows),
// `maintenance.check {environment}`, `maintenance.update {environment}`,
// `maintenance.updateAll`, `maintenance.confirm`, `maintenance.cancel`,
// `maintenance.copyCommand {environment}`, `maintenance.refreshProviders
// {environment}`, `maintenance.updateProvider {environment, instanceId}` and
// `maintenance.updateProviders {driver}` for every machine it is behind on.
class Maintenance : public QObject {
  Q_OBJECT

public:
  Maintenance(ShellBridge* bridge, NativeShell* shell, QObject* parent = nullptr);

  // Seams: the version this app is, the clipboard, and where releases are
  // listed (`%1` is the page).
  void setAppVersion(const QString& version);
  void setClipboardWriter(std::function<bool(const QString&)> write) { m_writeClipboard = std::move(write); }
  void setReleaseIndex(const QString& url) { m_releaseIndex = url; }
  // How long an answered server update may take to come back on another version.
  void setReconnectDeadline(int ms) { m_reconnectDeadline = ms; }

private:
  struct Machine {
    QString environmentId;
    QString label;
    QString version;
    bool online = false;
    bool local = false;
    QJsonObject capabilities;
  };
  struct Release {
    bool checking = false;
    QString text;
    QString available;
  };
  struct Outcome {
    bool ok = false;
    QString text;
  };

  bool handle(const QString& action, const QVariant& payload);
  QList<Machine> machines() const;
  std::optional<Machine> machine(const QString& environmentId) const;
  // Why nothing can be started on the machine, "" when it can.
  QString blocked(const Machine& machine) const;
  QString target(const Machine& machine) const;
  QJsonArray providersOf(const Machine& machine) const;
  QList<Machine> updatable() const;
  void readSession();
  void readProviders();
  void refreshProviders(const QString& environmentId, bool announce);
  void check(const Machine& machine);
  void checkPage(const Machine& machine, const QString& channel, int page);
  void update(const QStringList& environments);
  void updateServer(const Machine& machine);
  // A server update the MC answered: done once the machine is back on another version.
  void settle();
  // Waits for the machine to come back, or to say the update it answered failed.
  void awaitReconnect(const Machine& machine, const QString& left, const QString& token);
  void reconnectFailed(const QString& environmentId, const QString& why);
  void endReconnect(const QString& environmentId);
  void copyCommand(const Machine& machine);
  void updateProvider(const Machine& machine, const QString& instanceId);
  void publish();

  ShellBridge* m_bridge;
  NativeShell* m_shell;
  QNetworkAccessManager* m_http;
  QString m_appVersion;
  QString m_releaseIndex;
  std::function<bool(const QString&)> m_writeClipboard;
  bool m_open = false;
  // The session's word on operating: unknown until read, then may or may not.
  enum class Session { Unknown, Reading, May, MayNot, Failed };
  Session m_session = Session::Unknown;
  quint64 m_generation = 0;
  // Other machines' providers, as `server.refreshProviders` last answered.
  QHash<QString, QJsonArray> m_providers;
  QHash<QString, QString> m_providerErrors;
  QHash<QString, Release> m_releases;
  // Server updates running, by environment, and the version each left.
  QHash<QString, QString> m_updating;
  // Server updates the MC answered, until the machine is back on another version.
  QHash<QString, QString> m_reconnecting;
  // What each of them waits on: its deadline's run, and its config subscription.
  struct Waiting {
    quint64 run = 0;
    int subscription = -1;
  };
  QHash<QString, Waiting> m_waiting;
  // Machines it stopped waiting for, by the version they left.
  QHash<QString, QString> m_gaveUpOn;
  quint64 m_waitRun = 0;
  int m_reconnectDeadline = 180'000;
  QHash<QString, Outcome> m_outcomes;
  // Provider updates running ("<environment>\n<instance>"), and how each ended.
  QSet<QString> m_providerUpdates;
  QHash<QString, Outcome> m_providerOutcomes;
  // The machines waiting on the user's word that their desktop apps relaunch.
  QStringList m_confirming;
  QString m_confirmText;
  std::optional<Outcome> m_message;
  QVariantMap m_published;
};
