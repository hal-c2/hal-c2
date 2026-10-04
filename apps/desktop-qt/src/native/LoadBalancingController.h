#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariant>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// Balancing new threads across machines (the web's LoadBalancingSettings and
// useLoadBalancedEnvironment), the one place a draft's machine is picked for
// it: place() moves a draft on "Auto balance" (WorkspaceController::Checkout
// `automatic`) to the machine with the most free CPU and memory among the
// connected ones with a checkout of its project, weighted by this device's
// `loadBalancingWeights` (100 prefer, 50 normal, 25 less often, 0 manual
// only). It is asked for two ways: the composer's Run on picker ("Auto
// balance", workspace.environment.set), and, while this device's
// `loadBalancingEnabled` is on, for every new draft the user has not tied to
// a machine (Run on, a branch, a worktree). A draft placed once stays where
// it was put.
//
// Each candidate is asked `server.getHostResources` and `server.getConfig`
// (its providers); a machine that does not answer keeps its last sample, which
// goes stale after 15 seconds (packages/client-runtime load-balancing.ts).
//
// Publishes `loadBalancing`: null with fewer than two connected machines, else
// {enabled, summary ("Off", the machines not at Normal, or ""), machines:
// [{environmentId, label, preference}], preferences: [{value, label}]}: the
// Connections page's group, the one place the switch is shown.
// Actions: `loadBalancing.enable {enabled}`, `loadBalancing.prefer
// {environmentId, value}`.
class LoadBalancingController : public QObject, public NativeController {
  Q_OBJECT

public:
  static constexpr qint64 kStaleMs = 15000;

  struct Candidate {
    QString environmentId;
    // HostResourcesSnapshot (packages/contracts resourceTelemetry.ts); empty when never sampled.
    QJsonObject resources;
    // When this client got the sample, so clocks on different machines are not compared.
    qint64 receivedAt = 0;
    int weight = 50;
  };
  // The machine with the most room, or "" when none can take work.
  static QString choose(const QList<Candidate>& candidates, qint64 now);

  LoadBalancingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Milliseconds since the epoch; the system's unless tests say.
  void setClock(std::function<qint64()> clock) { m_clock = std::move(clock); }

  // Asks the machines and moves the window's draft `draftId` to the one with
  // the most room. `quietly` is a new draft's own placement: the draft goes on
  // Auto balance only once a machine is picked, so until then the picker
  // shows the machine it is on and it can be sent there.
  void place(const QString& draftId, bool quietly = false);
  // A draft's check: still asking, or over with a machine that could not be asked and none picked.
  struct State {
    bool pending = false;
    bool failed = false;
  };
  State state(const QString& draftId) const;

private:
  struct Sample {
    QJsonObject resources;
    qint64 receivedAt = 0;
  };
  struct Member {
    QString environmentId;
    QString projectId;
  };
  bool enabled() const;
  QJsonObject weights() const;
  QStringList machines() const;
  QString label(const QString& environmentId) const;
  void publish();
  // Puts the window's draft on Auto balance, when it is a new one load balancing may place.
  void balance();
  void decide(const QString& draftId, int request, const QList<Member>& members, const QString& ownEnvironment);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<qint64()> m_clock;
  bool m_active = false;
  QHash<QString, Sample> m_samples;
  QHash<QString, QJsonArray> m_providers;
  // Machines that answered `server.getConfig`: only their providers are known.
  QSet<QString> m_configured;
  // Each draft's check under way or last made.
  struct Check {
    int request = 0;
    int waiting = 0;
    bool failed = false;
    bool quiet = false;
  };
  // The new drafts load balancing has placed, or tried to.
  QSet<QString> m_tried;
  QHash<QString, Check> m_checks;
};
