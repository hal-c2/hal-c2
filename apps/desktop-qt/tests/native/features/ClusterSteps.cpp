// This machine's cluster settings page on the desktop, and the MC's side of
// it (the @desktop scenarios of features/connections/cluster.feature).

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUrl>

#include <optional>

#include "Harness.h"
#include "World.h"

namespace {

// This machine's cluster as apps/server-ex lib/hal_c2/rpc.ex answers
// `cluster.*`: the other members, whether the MC listens only on loopback,
// and why it refuses to read the cluster or join (when it does). Reads are
// held while the MC holds `cluster.status`.
struct FakeCluster {
  QJsonArray members;
  bool loopbackOnly = false;
  QString statusRefusal;
  QString joinRefusal;
  QList<QPair<QString, QJsonObject>> calls;
};

QJsonObject clusterStatus(FakeMc& mc) {
  return {
      {QStringLiteral("clustered"), true},
      {QStringLiteral("id"), mc.environmentId},
      {QStringLiteral("label"), QStringLiteral("desk")},
      {QStringLiteral("mc"), mc.name},
      {QStringLiteral("addresses"), QJsonArray{QStringLiteral("desk:4369")}},
      {QStringLiteral("members"), mc.part<FakeCluster>().members},
  };
}

void answerCluster(FakeMc& mc, const FakeMc::Rpc& rpc) {
  FakeCluster& cluster = mc.part<FakeCluster>();
  cluster.calls.append({rpc.method, rpc.payload});
  const auto refuse = [&](const QString& message, const QString& reason) {
    mc.refuse(rpc, message,
                {{QStringLiteral("_tag"), QStringLiteral("ClusterError")}, {QStringLiteral("reason"), reason}});
  };
  QJsonValue result = clusterStatus(mc);
  if (rpc.method == QLatin1String("cluster.status") && !cluster.statusRefusal.isEmpty()) {
    refuse(cluster.statusRefusal, QStringLiteral("request_failed"));
    return;
  }
  // Answered with the cluster as it was when asked.
  if (rpc.method == QLatin1String("cluster.status") && mc.holding(QStringLiteral("cluster.status"))) {
    mc.defer([&mc, rpc, result] { mc.reply(rpc, result); });
    return;
  }
  if (rpc.method == QLatin1String("cluster.invite")) {
    const QString host = cluster.loopbackOnly ? QStringLiteral("127.0.0.1") : QStringLiteral("desk");
    result = QJsonObject{
        {QStringLiteral("link"), QStringLiteral("http://%1:3773/pair#token=invite-1").arg(host)},
        {QStringLiteral("expiresAt"), QStringLiteral("2026-09-23T10:15:00Z")},
        {QStringLiteral("localOnly"), cluster.loopbackOnly},
    };
  } else if (rpc.method == QLatin1String("cluster.join")) {
    if (!cluster.joinRefusal.isEmpty()) {
      refuse(cluster.joinRefusal, QStringLiteral("link_lacks_access"));
      return;
    }
    const QString host = QUrl(rpc.payload.value(QLatin1String("link")).toString()).host();
    cluster.members.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("env-") + host},
                                       {QStringLiteral("label"), host},
                                       {QStringLiteral("addresses"), QJsonArray{host + QStringLiteral(":4369")}},
                                       {QStringLiteral("connected"), true}});
    result = clusterStatus(mc);
  } else if (rpc.method == QLatin1String("cluster.remove")) {
    const QString removed = rpc.payload.value(QLatin1String("id")).toString();
    for (qsizetype index = cluster.members.size() - 1; index >= 0; --index) {
      if (cluster.members.at(index).toObject().value(QLatin1String("id")).toString() == removed) cluster.members.removeAt(index);
    }
    result = clusterStatus(mc);
  }
  mc.reply(rpc, result);
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("cluster."), [&mc](const FakeMc::Rpc& rpc) { answerCluster(mc, rpc); });
});

FakeCluster& fake(World& world) {
  return world.mc.part<FakeCluster>();
}

const Steps steps([] {
  const QString q = kQuoted;

  // The cluster settings page.
  const auto cluster = [](World& world) { return world.state(QStringLiteral("cluster")).toMap(); };
  const auto clusterCall = [](World& world, const QString& method) -> std::optional<QJsonObject> {
    world.sync();
    for (const auto& [called, payload] : fake(world).calls) {
      if (called == method) return payload;
    }
    return std::nullopt;
  };
  step(QStringLiteral("this machine is clustered with (.*)"), [](World& world, const Captures& c, const Table&) {
    static const QRegularExpression member(QStringLiteral("\"([^\"]*)\", which is (connected|offline)"));
    for (auto it = member.globalMatch(c[0]); it.hasNext();) {
      const QRegularExpressionMatch match = it.next();
      fake(world).members.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("env-") + match.captured(1)},
                                            {QStringLiteral("label"), match.captured(1)},
                                            {QStringLiteral("addresses"), QJsonArray()},
                                            {QStringLiteral("connected"), match.captured(2) == QLatin1String("connected")}});
    }
  });
  step(QStringLiteral("the MC listens only on loopback"), [](World& world, const Captures&, const Table&) {
    fake(world).loopbackOnly = true;
  });
  step(QStringLiteral("the MC refuses joins saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).joinRefusal = c[0];
  });
  step(QStringLiteral("the user opens Cluster in the desktop's settings"), [cluster](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.open"), {});
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("section")) == QStringLiteral("/settings/cluster"), QStringLiteral("the route is %1").arg(show(route)));
  });
  step(QStringLiteral("the MC can no longer read its cluster, saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).statusRefusal = c[0];
  });
  step(QStringLiteral("the MC is slow to read its cluster"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(QStringLiteral("cluster.status"));
  });
  step(QStringLiteral("the user makes a cluster invite"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.invite"), {});
  });
  step(QStringLiteral("the user joins with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.join"), QVariantMap{{QStringLiteral("link"), c[0]}});
  });
  step(QStringLiteral("the user removes %1 from the cluster").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), QStringLiteral("env-") + c[0]}});
  });
  step(QStringLiteral("the user goes back from settings"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("settings.back"), {});
  });
  step(QStringLiteral("the user picks the settings section %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), c[0]}});
  });
  step(QStringLiteral("the MC is asked for its cluster status"), [clusterCall](World& world, const Captures&, const Table&) {
    expect(clusterCall(world, QStringLiteral("cluster.status")).has_value(), QStringLiteral("the MC was not asked"));
  });
  step(QStringLiteral("the MC is asked for a cluster invite"), [clusterCall](World& world, const Captures&, const Table&) {
    expect(clusterCall(world, QStringLiteral("cluster.invite")).has_value(), QStringLiteral("the MC was not asked"));
  });
  step(QStringLiteral("the MC is asked to join with %1").arg(q), [clusterCall](World& world, const Captures& c, const Table&) {
    const auto payload = clusterCall(world, QStringLiteral("cluster.join"));
    expect(payload && payload->value(QLatin1String("link")).toString() == c[0],
           QStringLiteral("the MC was asked %1").arg(payload ? show(payload->toVariantMap()) : QStringLiteral("nothing")));
  });
  step(QStringLiteral("the MC is asked to remove %1").arg(q), [clusterCall](World& world, const Captures& c, const Table&) {
    const auto payload = clusterCall(world, QStringLiteral("cluster.remove"));
    expect(payload && payload->value(QLatin1String("id")).toString() == c[0],
           QStringLiteral("the MC was asked %1").arg(payload ? show(payload->toVariantMap()) : QStringLiteral("nothing")));
  });
  step(QStringLiteral("the invite link is copied"), [cluster](World& world, const Captures&, const Table&) {
    world.sync();
    const QString link = at(cluster(world), QStringLiteral("invite.link")).toString();
    const QString copied = QGuiApplication::clipboard()->text();
    expect(!link.isEmpty() && copied == link, QStringLiteral("copied \"%1\", the invite is %2").arg(copied, show(cluster(world))));
  });
  step(QStringLiteral("the cluster page shows the invite link"), [cluster](World& world, const Captures&, const Table&) {
    world.sync();
    expect(at(cluster(world), QStringLiteral("invite.link")).toString().startsWith(QLatin1String("http")),
           QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
  });
  step(QStringLiteral("the cluster page says %1").arg(q), [cluster](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(cluster(world), QStringLiteral("notice.text")).toString() == c[0],
           QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
  });
  step(QStringLiteral("the user is warned that only this machine can open the invite"), [cluster](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantMap notice = cluster(world).value(QStringLiteral("notice")).toMap();
    expect(notice.value(QStringLiteral("kind")) == QLatin1String("error") &&
               notice.value(QStringLiteral("text")).toString().contains(QLatin1String("Only this machine can open it")),
           QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
  });
  step(QStringLiteral("the cluster page lists (.*)"), [cluster](World& world, const Captures& c, const Table&) {
    world.sync();
    static const QRegularExpression member(QStringLiteral("\"([^\"]*)\" as (connected|offline)"));
    const QVariantList listed = at(cluster(world), QStringLiteral("status.members")).toList();
    for (auto it = member.globalMatch(c[0]); it.hasNext();) {
      const QRegularExpressionMatch match = it.next();
      bool found = false;
      for (const QVariant& row : listed) {
        found = found || (row.toMap().value(QStringLiteral("label")).toString() == match.captured(1) &&
                          row.toMap().value(QStringLiteral("connected")).toBool() == (match.captured(2) == QLatin1String("connected")));
      }
      expect(found, QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
    }
  });
  step(QStringLiteral("the cluster page does not list %1").arg(q), [cluster](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QVariant& row : at(cluster(world), QStringLiteral("status.members")).toList()) {
      expect(row.toMap().value(QStringLiteral("label")).toString() != c[0],
             QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
    }
  });
  step(QStringLiteral("the cluster page shows the error %1 instead of the machines").arg(q), [cluster](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariantMap page = cluster(world);
    expect(page.value(QStringLiteral("error")).toString() == c[0] && page.value(QStringLiteral("status")).isNull(),
           QStringLiteral("the cluster page is %1").arg(show(page)));
  });
  step(QStringLiteral("the cluster page says the session needs administrative access, with nothing to invite or join"),
       [cluster](World& world, const Captures&, const Table&) {
         world.sync();
         const QVariantMap page = cluster(world);
         expect(page.value(QStringLiteral("needsAdmin")).toBool() && page.value(QStringLiteral("error")).isNull() &&
                    page.value(QStringLiteral("status")).isNull(),
                QStringLiteral("the cluster page is %1").arg(show(page)));
       });
  // A machine that left.
  step(QStringLiteral("a client lists a machine that has left the cluster"), [cluster](World& world, const Captures&, const Table&) {
    fake(world).members.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("env-laptop")}, {QStringLiteral("label"), QStringLiteral("laptop")},
                                          {QStringLiteral("addresses"), QJsonArray()}, {QStringLiteral("connected"), false}});
    world.connect();
    world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
    world.bridge().dispatch(QStringLiteral("cluster.open"), {});
    world.waitFor([&] { return !at(cluster(world), QStringLiteral("status.members")).toList().isEmpty(); }, QStringLiteral("the cluster to be read"));
  });
  step(QStringLiteral("the machine stays listed"), [cluster](World& world, const Captures&, const Table&) {
    // Read again, it is still a member, shown as offline.
    const qsizetype reads = fake(world).calls.size();
    world.bridge().dispatch(QStringLiteral("cluster.refresh"), {});
    world.waitFor([&] { return fake(world).calls.size() > reads; }, QStringLiteral("the cluster to be read again"));
    world.sync();
    const QVariantList members = at(cluster(world), QStringLiteral("status.members")).toList();
    expect(members.size() == 1 && members[0].toMap().value(QStringLiteral("label")) == QLatin1String("laptop") &&
               !members[0].toMap().value(QStringLiteral("connected")).toBool(),
           QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
  });
  step(QStringLiteral("the user can remove it like any environment"), [cluster, clusterCall](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), QStringLiteral("env-laptop")}});
    world.waitFor([&] { return at(cluster(world), QStringLiteral("status.members")).toList().isEmpty() && !cluster(world).value(QStringLiteral("busy")).toBool(); },
                  [&] { return QStringLiteral("the machine to go; the cluster page is %1").arg(show(cluster(world))); });
    const auto payload = clusterCall(world, QStringLiteral("cluster.remove"));
    expect(payload && payload->value(QLatin1String("id")) == QLatin1String("env-laptop") &&
               at(cluster(world), QStringLiteral("notice.text")) == QLatin1String("Removed laptop from the cluster."),
           QStringLiteral("the cluster page is %1").arg(show(cluster(world))));
  });
  step(QStringLiteral("the cluster page closes"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("section")) != QStringLiteral("/settings/cluster"), QStringLiteral("the route is %1").arg(show(route)));
  });
});

}  // namespace
