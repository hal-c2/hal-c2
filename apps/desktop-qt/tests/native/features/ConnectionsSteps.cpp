// The desktop's Connections settings page (ConnectionsController): who may
// reach this machine (features/settings/connections.feature and the desktop
// scenarios of connections/pairing.feature).

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "World.h"

namespace {

// Who may reach the MC, as apps/server-ex lib/hal_c2/rpc.ex answers `hal-c2.*`
// access calls and the `authAccess` shape.
struct FakeAccess {
  bool admin = true;
  bool refuseCreate = false;
  QJsonArray pairingLinks;
  QJsonArray clients{QJsonObject{
      {QStringLiteral("sessionId"), QStringLiteral("session-desktop")},
      {QStringLiteral("subject"), QStringLiteral("owner")},
      {QStringLiteral("client"), QJsonObject{{QStringLiteral("deviceType"), QStringLiteral("desktop")},
                                             {QStringLiteral("label"), QStringLiteral("This desktop")}}},
      {QStringLiteral("connected"), true},
      {QStringLiteral("current"), true},
  }};
  // Unused pairing links' credentials, by link id.
  QHash<QString, QString> credentials;
  QList<QPair<QString, QJsonObject>> calls;
  int next = 1;
  int revision = 0;
};

FakeAccess& fake(World& world) {
  return world.mc.part<FakeAccess>();
}

void sendAccess(FakeMc& mc, const QString& type, const QJsonObject& payload, int only = -1) {
  FakeAccess& access = mc.part<FakeAccess>();
  const QJsonObject event{{QStringLiteral("version"), 1},
                          {QStringLiteral("revision"), ++access.revision},
                          {QStringLiteral("type"), type},
                          {QStringLiteral("payload"), payload}};
  for (const int id : mc.subscribers(QStringLiteral("authAccess"))) {
    if (only >= 0 && id != only) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("authAccess")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
  }
}

void removeWhere(QJsonArray& list, const QString& key, const QString& value) {
  for (qsizetype index = list.size() - 1; index >= 0; --index) {
    if (list.at(index).toObject().value(key).toString() == value) list.removeAt(index);
  }
}

void answerAccess(FakeMc& mc, const FakeMc::Rpc& rpc) {
  FakeAccess& access = mc.part<FakeAccess>();
  access.calls.append({rpc.method, rpc.payload});
  const QString method = rpc.method;
  const bool reads = method == QLatin1String("hal-c2.pairingLinks") || method == QLatin1String("hal-c2.clients");
  if (!access.admin) {
    mc.refuse(rpc, reads ? QStringLiteral("access:read is required") : QStringLiteral("access:write is required"));
    return;
  }
  if (method == QLatin1String("hal-c2.createPairingLink")) {
    if (access.refuseCreate) {
      mc.refuse(rpc, QStringLiteral("the MC could not store the pairing link"));
      return;
    }
    const QString id = QStringLiteral("link-%1").arg(access.next);
    const QString credential = QStringLiteral("secret-%1").arg(access.next++);
    QJsonObject link{{QStringLiteral("id"), id},
                     {QStringLiteral("scopes"), rpc.payload.value(QLatin1String("scopes"))},
                     {QStringLiteral("subject"), QStringLiteral("owner")},
                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-29T10:00:00Z")},
                     {QStringLiteral("expiresAt"), QStringLiteral("2026-09-29T10:05:00Z")}};
    if (rpc.payload.contains(QLatin1String("label"))) link.insert(QStringLiteral("label"), rpc.payload.value(QLatin1String("label")));
    access.pairingLinks.append(link);
    access.credentials.insert(id, credential);
    sendAccess(mc, QStringLiteral("pairingLinkUpserted"), link);
    QJsonObject result = link;
    result.insert(QStringLiteral("credential"), credential);
    mc.reply(rpc, result);
  } else if (method == QLatin1String("hal-c2.revokePairingLink")) {
    const QString id = rpc.payload.value(QLatin1String("id")).toString();
    removeWhere(access.pairingLinks, QStringLiteral("id"), id);
    access.credentials.remove(id);
    sendAccess(mc, QStringLiteral("pairingLinkRemoved"), {{QStringLiteral("id"), id}});
    mc.reply(rpc, QJsonObject{{QStringLiteral("revoked"), true}});
  } else if (method == QLatin1String("hal-c2.revokeClient")) {
    const QString id = rpc.payload.value(QLatin1String("sessionId")).toString();
    removeWhere(access.clients, QStringLiteral("sessionId"), id);
    sendAccess(mc, QStringLiteral("clientRemoved"), {{QStringLiteral("sessionId"), id}});
    mc.reply(rpc, QJsonObject{{QStringLiteral("revoked"), true}});
  } else if (method == QLatin1String("hal-c2.revokeOtherClients")) {
    int count = 0;
    for (qsizetype index = access.clients.size() - 1; index >= 0; --index) {
      const QJsonObject client = access.clients.at(index).toObject();
      if (client.value(QLatin1String("current")).toBool()) continue;
      access.clients.removeAt(index);
      sendAccess(mc, QStringLiteral("clientRemoved"), {{QStringLiteral("sessionId"), client.value(QLatin1String("sessionId"))}});
      count++;
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("revokedCount"), count}});
  } else {
    mc.reply(rpc, QJsonValue::Null);
  }
}

const FakeMc::Extension extension([](FakeMc& mc) {
  for (const char* method : {"createPairingLink", "revokePairingLink", "pairingLinks", "clients", "revokeClient",
                             "revokeOtherClients"}) {
    mc.onRpc(QStringLiteral("hal-c2.") + QLatin1String(method), [&mc](const FakeMc::Rpc& rpc) { answerAccess(mc, rpc); });
  }
  mc.onShape(QStringLiteral("authAccess"), [&mc](int id, const QJsonObject&) {
    FakeAccess& access = mc.part<FakeAccess>();
    if (!access.admin) {
      mc.send({{QStringLiteral("t"), QStringLiteral("error")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("reason"), QStringLiteral("access:read is required")}});
      mc.forget(id);
      return;
    }
    sendAccess(mc, QStringLiteral("snapshot"),
               {{QStringLiteral("pairingLinks"), access.pairingLinks}, {QStringLiteral("clientSessions"), access.clients}}, id);
  });
});

// "Build box" is the machine at build-box.
QString hostOf(const QString& label) {
  return label.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

QVariantMap connections(World& world) {
  world.sync();
  return world.state(QStringLiteral("connections")).toMap();
}

QVariantList listed(World& world, const QString& list) {
  return at(connections(world), QStringLiteral("access.") + list).toList();
}

void expectNotice(World& world, const QString& kind, const std::function<bool(const QString&)>& says) {
  const QVariantMap page = connections(world);
  const QVariantMap notice = page.value(QStringLiteral("notice")).toMap();
  expect(notice.value(QStringLiteral("kind")) == kind && says(notice.value(QStringLiteral("text")).toString()),
         QStringLiteral("the Connections page is %1").arg(show(page)));
}

bool called(World& world, const QString& method) {
  world.sync();
  for (const auto& [name, payload] : fake(world).calls) {
    if (name == method) return true;
  }
  return false;
}

void openConnections(World& world) {
  if (!world.native().isActive()) {
    world.connect();
    world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
  }
  world.bridge().dispatch(QStringLiteral("connections.open"), {});
  world.sync();
  const QVariant route = world.state(QStringLiteral("route"));
  expect(at(route, QStringLiteral("section")) == QStringLiteral("/settings/connections"), QStringLiteral("the route is %1").arg(show(route)));
}

void createLink(World& world, const QString& label, const QStringList& scopes) {
  world.bridge().dispatch(QStringLiteral("connections.pairingLink.create"),
                          QVariantMap{{QStringLiteral("label"), label}, {QStringLiteral("scopes"), scopes}});
}

void addClient(World& world, const QString& label) {
  FakeAccess& access = fake(world);
  const QJsonObject client{
      {QStringLiteral("sessionId"), QStringLiteral("session-") + hostOf(label)},
      {QStringLiteral("subject"), QStringLiteral("owner")},
      {QStringLiteral("client"), QJsonObject{{QStringLiteral("deviceType"), QStringLiteral("mobile")}, {QStringLiteral("label"), label}}},
      {QStringLiteral("connected"), true},
      {QStringLiteral("current"), false},
  };
  access.clients.append(client);
  sendAccess(world.mc, QStringLiteral("clientUpserted"), client);
}

bool clientListed(World& world, const QString& label) {
  for (const QVariant& client : listed(world, QStringLiteral("clients"))) {
    if (at(client, QStringLiteral("client.label")) == label) return true;
  }
  return false;
}

const QStringList kStandardScopes{QStringLiteral("orchestration:read"), QStringLiteral("orchestration:operate"),
                                  QStringLiteral("terminal:operate"), QStringLiteral("review:write"),
                                  QStringLiteral("relay:read")};

const Steps steps([] {
  const QString q = kQuoted;

  // The MC and the session.
  step(QStringLiteral("a running MC"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
  });
  step(QStringLiteral("the user has opened the Connections settings"), [](World& world, const Captures&, const Table&) {
    openConnections(world);
  });
  step(QStringLiteral("the user's session may manage this machine's access"), [](World& world, const Captures&, const Table&) {
    fake(world).admin = true;
    expect(connections(world).value(QStringLiteral("access")).isValid() &&
               !connections(world).value(QStringLiteral("access")).isNull(),
           QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("the user's session may not manage this machine's access"), [](World& world, const Captures&, const Table&) {
    fake(world).admin = false;
    world.bridge().dispatch(QStringLiteral("connections.refresh"), {});
  });
  step(QStringLiteral("the user is told administrative access is required"), [](World& world, const Captures&, const Table&) {
    const QVariantMap page = connections(world);
    const auto needsAdmin = [](const QString& text) { return text.contains(QLatin1String("needs an administrator session")); };
    const bool told = needsAdmin(page.value(QStringLiteral("accessError")).toString()) ||
                      needsAdmin(at(page, QStringLiteral("notice.text")).toString());
    expect(told, QStringLiteral("the Connections page is %1").arg(show(page)));
  });
  step(QStringLiteral("no pairing links or clients are listed"), [](World& world, const Captures&, const Table&) {
    const QVariantMap page = connections(world);
    expect(page.value(QStringLiteral("access")).isNull(), QStringLiteral("the Connections page is %1").arg(show(page)));
  });

  // Pairing links.
  step(QStringLiteral("the user creates a pairing link labelled %1 allowed to view the environment and operate tasks").arg(q),
       [](World& world, const Captures& c, const Table&) {
         createLink(world, c[0], {QStringLiteral("orchestration:read"), QStringLiteral("orchestration:operate")});
       });
  step(QStringLiteral("a pairing link labelled %1 is listed with those permissions and its expiry").arg(q),
       [](World& world, const Captures& c, const Table&) {
         bool found = false;
         for (const QVariant& link : listed(world, QStringLiteral("pairingLinks"))) {
           const QVariantMap map = link.toMap();
           found = found || (map.value(QStringLiteral("label")) == c[0] &&
                             map.value(QStringLiteral("scopes")).toStringList() ==
                                 QStringList{QStringLiteral("orchestration:read"), QStringLiteral("orchestration:operate")} &&
                             !map.value(QStringLiteral("expiresAt")).toString().isEmpty());
         }
         expect(found, QStringLiteral("the Connections page is %1").arg(show(connections(world))));
       });
  step(QStringLiteral("the user tries to create a pairing link with no permissions"), [](World& world, const Captures&, const Table&) {
    createLink(world, QStringLiteral("Phone"), {});
  });
  step(QStringLiteral("the user is told to select at least one permission"), [](World& world, const Captures&, const Table&) {
    expectNotice(world, QStringLiteral("error"), [](const QString& text) { return text == QLatin1String("Select at least one permission."); });
  });
  step(QStringLiteral("no link is created"), [](World& world, const Captures&, const Table&) {
    expect(!called(world, QStringLiteral("hal-c2.createPairingLink")), QStringLiteral("the MC was asked for a pairing link"));
    expect(listed(world, QStringLiteral("pairingLinks")).isEmpty(), QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("the server refuses to create pairing links"), [](World& world, const Captures&, const Table&) {
    fake(world).refuseCreate = true;
  });
  step(QStringLiteral("the user creates a pairing link"), [](World& world, const Captures&, const Table&) {
    createLink(world, {}, kStandardScopes);
  });
  step(QStringLiteral("the user is told the pairing URL could not be created"), [](World& world, const Captures&, const Table&) {
    expectNotice(world, QStringLiteral("error"), [](const QString& text) { return text.startsWith(QLatin1String("Could not create the pairing URL")); });
  });
  step(QStringLiteral("(a pairing link is listed|the user created a pairing link)"), [](World& world, const Captures&, const Table&) {
    if (!world.state(QStringLiteral("route")).isValid() ||
        at(world.state(QStringLiteral("route")), QStringLiteral("section")) != QStringLiteral("/settings/connections")) {
      openConnections(world);
    }
    createLink(world, QStringLiteral("Phone"), kStandardScopes);
    const QVariantMap page = connections(world);
    expect(listed(world, QStringLiteral("pairingLinks")).size() == 1 && !page.value(QStringLiteral("created")).isNull(),
           QStringLiteral("the Connections page is %1").arg(show(page)));
  });
  step(QStringLiteral("the user copies the link"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::clipboard()->clear();
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.copy"), {});
  });
  step(QStringLiteral("the link is on the clipboard"), [](World& world, const Captures&, const Table&) {
    const QString url = at(connections(world), QStringLiteral("created.url")).toString();
    const QString copied = QGuiApplication::clipboard()->text();
    expect(!url.isEmpty() && copied == url && copied.endsWith(QLatin1String("/pair#token=secret-1")) &&
               copied.startsWith(world.mc.origin().toString()),
           QStringLiteral("copied \"%1\", the page is %2").arg(copied, show(connections(world))));
  });
  step(QStringLiteral("the user is told it was copied"), [](World& world, const Captures&, const Table&) {
    expectNotice(world, QStringLiteral("success"), [](const QString& text) { return text == QLatin1String("Pairing link copied."); });
  });
  step(QStringLiteral("the user revokes it"), [](World& world, const Captures&, const Table&) {
    const QVariantList links = listed(world, QStringLiteral("pairingLinks"));
    expect(!links.isEmpty(), QStringLiteral("no pairing link is listed"));
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.revoke"),
                            QVariantMap{{QStringLiteral("id"), links.first().toMap().value(QStringLiteral("id"))}});
  });
  step(QStringLiteral("the link is no longer listed"), [](World& world, const Captures&, const Table&) {
    expect(listed(world, QStringLiteral("pairingLinks")).isEmpty(), QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("a device can no longer pair with it"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).credentials.isEmpty(), QStringLiteral("the MC still pairs with %1").arg(fake(world).credentials.values().join(u", ")));
    expect(connections(world).value(QStringLiteral("created")).isNull(), QStringLiteral("the revoked link can still be copied"));
  });
  step(QStringLiteral("the user leaves the Connections page and comes back"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("connections.close"), {});
    world.sync();
    openConnections(world);
  });
  step(QStringLiteral("the link is listed without its secret"), [](World& world, const Captures&, const Table&) {
    const QVariantMap page = connections(world);
    const QVariantList links = listed(world, QStringLiteral("pairingLinks"));
    expect(links.size() == 1 && page.value(QStringLiteral("created")).isNull() && !show(page).contains(QLatin1String("secret-")),
           QStringLiteral("the Connections page is %1").arg(show(page)));
  });
  step(QStringLiteral("the user must create another link to share"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::clipboard()->clear();
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.copy"), {});
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.copy"), QVariantMap{{QStringLiteral("what"), QStringLiteral("code")}});
    expect(QGuiApplication::clipboard()->text().isEmpty(), QStringLiteral("copied \"%1\"").arg(QGuiApplication::clipboard()->text()));
  });

  // Clients.
  step(QStringLiteral("the client %1 is connected").arg(q), [](World& world, const Captures& c, const Table&) {
    addClient(world, c[0]);
    expect(clientListed(world, c[0]), QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("the user revokes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("connections.client.revoke"), QVariantMap{{QStringLiteral("sessionId"), QStringLiteral("session-") + hostOf(c[0])}});
  });
  step(QStringLiteral("%1 is signed out and no longer listed").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(called(world, QStringLiteral("hal-c2.revokeClient")), QStringLiteral("the MC was not asked to revoke it"));
    expect(!clientListed(world, c[0]), QStringLiteral("the Connections page is %1").arg(show(connections(world))));
    expectNotice(world, QStringLiteral("success"), [&c](const QString& text) { return text == c[0] + QStringLiteral(" was signed out."); });
  });
  step(QStringLiteral("three clients are listed including this one"), [](World& world, const Captures&, const Table&) {
    addClient(world, QStringLiteral("Phone"));
    addClient(world, QStringLiteral("Laptop"));
    expect(listed(world, QStringLiteral("clients")).size() == 3, QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("the user revokes the others"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("connections.clients.revokeOthers"), {});
  });
  step(QStringLiteral("only this client is listed"), [](World& world, const Captures&, const Table&) {
    const QVariantList clients = listed(world, QStringLiteral("clients"));
    expect(clients.size() == 1 && clients.first().toMap().value(QStringLiteral("current")).toBool(),
           QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("the user is told (\\d+) clients were revoked"), [](World& world, const Captures& c, const Table&) {
    expectNotice(world, QStringLiteral("success"), [&c](const QString& text) { return text == c[0] + QStringLiteral(" clients were revoked."); });
  });
  step(QStringLiteral("there are no pairing links or client sessions"), [](World& world, const Captures&, const Table&) {
    fake(world).pairingLinks = {};
    fake(world).clients = {};
    world.bridge().dispatch(QStringLiteral("connections.refresh"), {});
  });
  step(QStringLiteral("the user is told there are no pairing links or client sessions"), [](World& world, const Captures&, const Table&) {
    const QVariantMap page = connections(world);
    // ConnectionsSettings.qml says so when both lists are empty.
    expect(!page.value(QStringLiteral("access")).isNull() && listed(world, QStringLiteral("pairingLinks")).isEmpty() &&
               listed(world, QStringLiteral("clients")).isEmpty(),
           QStringLiteral("the Connections page is %1").arg(show(page)));
  });

  // Other machines.
  step(QStringLiteral("the user goes on to this machine's cluster"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.open"), {});
  });
});

}  // namespace
