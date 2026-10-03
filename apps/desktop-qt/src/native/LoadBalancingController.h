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
// useLoadBalancedEnvironment): with this device's `loadBalancingEnabled` on, a
// new thread's draft in a project several connected machines have a checkout
// of moves to the one with the most free CPU and memory, weighted by
// `loadBalancingWeights` (100 prefer, 50 normal, 25 less often, 0 manual
// only). A draft the user tied to a machine (Run on, a branch, a worktree) is
// left alone, and one balanced once stays where it was put.
//
// Each candidate is asked `server.getHostResources` and `server.getConfig` (its providers); a
// machine that does not answer keeps its last sample, which goes stale after
// 15 seconds (packages/client-runtime load-balancing.ts).
//
// Publishes `loadBalancing`: null with fewer than two connected machines, else
// {enabled, summary ("Off", the machines not at Normal, or ""), machines:
// [{environmentId, label, preference}], preferences: [{value, label}]}.
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
  // Moves the window's draft, when it is one balancing may place.
  void balance();
  void decide(const QString& draftId, const QList<Member>& members, const QString& ownEnvironment);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<qint64()> m_clock;
  bool m_active = false;
  QHash<QString, Sample> m_samples;
  QHash<QString, QJsonArray> m_providers;
  // The draft being placed, and those already placed (or found unplaceable).
  QString m_placing;
  QSet<QString> m_placed;
  int m_waiting = 0;
};
