#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;
class SettingsController;
class TerminalSession;

// The first-run gate and the welcome wizard (the web's FirstRunGate and
// WelcomeWizard). Whether setup is done is this device's
// `onboardingCompletedAt`; a device without it that already has projects or
// threads counts as done, which is saved quietly. Until the MC's first
// snapshot the gate is pending, and after 4 s it offers to reconnect.
// Preferences that cannot be read stop it before anything else.
//
// Publishes `onboarding`:
//   {gate: "pending" | "wizard" | "app", recovery: null | "connection" | "settings",
//    step: "connection" | "agents" | "import", stage, importing, finishing,
//    computers: [{environmentId, label, connected, selected}], canContinue,
//    pairing, pairingError, pairingDetail,
//    agents: [{environmentId, label, cards: [{driver, name, state, headline, detail,
//              terminalOpen, terminalAvailable}]}],
//    terminal: null | {environmentId, driver, command, status: "preparing" | "ready" | "openFailed", message},
//    import: {loading, multiple, total, selectedCount, error, scans: [{environmentId, label,
//             pending, error, truncated, empty, repositories: [group], other: {count, checked,
//             partial, candidates}}]}}
// where a group is {key, label, secondary, single, checked, partial, threadCount,
// age, claude, codex, candidates: [{key, path, checked, threadCount, age, claude, codex}]}.
//
// Actions: onboarding.reload, onboarding.retry (reads the preferences again),
// onboarding.select {environmentId, selected}, onboarding.pair {pairingUrl},
// onboarding.continue, onboarding.stage {index}, onboarding.agent {environmentId,
// driver} (opens its setup terminal), onboarding.terminal.retry,
// onboarding.terminal.close, onboarding.scan.retry {environmentId},
// onboarding.project {keys, selected}, onboarding.selectAll, onboarding.selectNone,
// onboarding.import, onboarding.skip (finishes without importing, or without the
// rest after a partial import).
//
// The setup terminal is `Onboarding.terminal` in QML, a TerminalSession the
// MC runs with the provider instance's own env and home.
class OnboardingController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(QObject* terminal READ terminal NOTIFY terminalChanged)

public:
  OnboardingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~OnboardingController() override;

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  QObject* terminal() const;
  // How long the gate waits for the MC before offering to reconnect.
  void setDecisionTimeout(int ms);
  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

signals:
  void terminalChanged();

private:
  struct Scan {
    bool pending = true;
    QString error;
    QJsonObject data;
  };
  struct Config {
    QJsonObject config;
    int subscription = 0;
  };
  struct Setup {
    QString environmentId;
    QString driver;
    QString instanceId;
    QString cwd;
    QString command;
    QString terminalId;
    QString status;
  };

  SettingsController* settings() const;
  void decide();
  void settle(const QString& gate);
  void updateComputers();
  void pair(const QString& url);
  void startSetup();
  void setStage(int index);
  void watchConfigs();
  void openSetup(const QString& environmentId, const QString& driver);
  void startTerminal();
  void closeSetup();
  void scan(const QString& environmentId);
  QList<QJsonObject> candidates() const;
  QSet<QString> selectedKeys() const;
  void runImport();
  void importNext();
  void afterImport();
  void finishAfterImport();
  void land(const QString& environmentId, const QString& projectId);
  void finish(std::optional<QPair<QString, QString>> project = std::nullopt);
  QVariantMap agents() const;
  QVariantMap importState() const;
  QString label(const QString& environmentId) const;
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QTimer m_timeout;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };

  QString m_gate = QStringLiteral("pending");
  bool m_stalled = false;
  QString m_step = QStringLiteral("connection");
  bool m_finishing = false;
  QString m_finishToast;

  // Connect: every computer offered once is selected once.
  QStringList m_computers;
  QSet<QString> m_offered;
  QSet<QString> m_selected;
  bool m_pairing = false;
  QString m_pairingError;
  QString m_pairingDetail;
  QStringList m_setupIds;

  // Agents.
  QHash<QString, Config> m_configs;
  std::optional<Setup> m_setup;
  QPointer<TerminalSession> m_session;

  // Import.
  QHash<QString, Scan> m_scans;
  std::optional<QSet<QString>> m_selection;
  bool m_importing = false;
  QString m_importError;
  QList<QJsonObject> m_queue;
  QStringList m_lastSelection;
  QHash<QString, QPair<QString, QString>> m_imported;
  QHash<QString, QPair<QString, QString>> m_withHistory;
  QHash<QString, QString> m_attempts;
  int m_importedProjects = 0;
  int m_importedThreads = 0;
  int m_skippedThreads = 0;
  int m_selectionSize = 0;
  QSet<QString> m_rescan;
  // The project the wizard lands on once the shell lists it.
  std::optional<QPair<QString, QString>> m_landing;
};
