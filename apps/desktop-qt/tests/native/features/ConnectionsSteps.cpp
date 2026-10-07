// The desktop's Connections settings page (ConnectionsController): who may
// reach this machine (features/settings/connections.feature and the desktop
// scenarios of connections/pairing.feature).

#include <QClipboard>
#include <QGuiApplication>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QtMath>

#include "Brick.h"
#include "Harness.h"
#include "QrCode.h"
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
  // Unused pairing links' credentials, by link id, and the machine each link
  // is on (its environment, "" for the MC's own): only that one revokes it.
  QHash<QString, QString> credentials;
  QHash<QString, QString> linkMachine;
  // Where Tailscale Serve publishes each machine, by environment ("" for the
  // MC's own); one without a name cannot be reached over Tailscale. Asked
  // without Tailscale, a machine names the loopback address it listens on.
  QHash<QString, QString> tailnet;
  // Machines from before a pairing link named its address.
  QSet<QString> silent;
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
  const QString method = rpc.method;
  // A link asked for while the MC holds its answers is made once it answers, late.
  if (method == QLatin1String("hal-c2.createPairingLink") && mc.holding(QStringLiteral("answers"))) {
    mc.defer([&mc, rpc] { answerAccess(mc, rpc); });
    return;
  }
  FakeAccess& access = mc.part<FakeAccess>();
  access.calls.append({rpc.method, rpc.payload});
  const bool reads = method == QLatin1String("hal-c2.pairingLinks") || method == QLatin1String("hal-c2.clients");
  if (!access.admin) {
    mc.refuse(rpc, reads ? QStringLiteral("access:read is required") : QStringLiteral("access:write is required"));
    return;
  }
  // The machine the call is for: "" for the MC's own.
  const QString machine = rpc.environment == mc.environmentId ? QString() : rpc.environment;
  if (method == QLatin1String("hal-c2.createPairingLink")) {
    if (access.refuseCreate) {
      mc.refuse(rpc, QStringLiteral("the MC could not store the pairing link"));
      return;
    }
    const bool tailscale = rpc.payload.value(QLatin1String("tailscale")).toBool();
    if (tailscale && !access.tailnet.contains(machine)) {
      mc.refuse(rpc, QStringLiteral("Could not talk to Tailscale. Is tailscaled running? Try `tailscale status`."));
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
    access.credentials.insert(id, credential);
    access.linkMachine.insert(id, machine);
    // The access list is of the MC's own links.
    if (machine.isEmpty()) {
      access.pairingLinks.append(link);
      sendAccess(mc, QStringLiteral("pairingLinkUpserted"), link);
    }
    QJsonObject result = link;
    result.insert(QStringLiteral("credential"), credential);
    if (!access.silent.contains(machine)) {
      const QString loopback = machine.isEmpty() ? mc.origin().toString() : QStringLiteral("http://127.0.0.1:3780");
      result.insert(QStringLiteral("address"), tailscale ? access.tailnet.value(machine) : loopback);
      result.insert(QStringLiteral("localOnly"), !tailscale);
    }
    mc.reply(rpc, result);
  } else if (method == QLatin1String("hal-c2.revokePairingLink")) {
    const QString id = rpc.payload.value(QLatin1String("id")).toString();
    const bool revoked = access.credentials.contains(id) && access.linkMachine.value(id) == machine;
    if (revoked) {
      access.credentials.remove(id);
      access.linkMachine.remove(id);
    }
    if (revoked && machine.isEmpty()) {
      removeWhere(access.pairingLinks, QStringLiteral("id"), id);
      sendAccess(mc, QStringLiteral("pairingLinkRemoved"), {{QStringLiteral("id"), id}});
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("revoked"), revoked}});
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

// The Connections page on screen, `width` wide (its last width when 0): what
// the user chooses and is shown there.
Brick& page(World& world, int width = 0) {
  if (!world.brick || (width > 0 && world.brick->window().width() != width)) {
    world.brick.reset();
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nConnectionsSettings {}\n",
                                          QSize(width > 0 ? width : 900, 1400));
  }
  world.sync();
  return *world.brick;
}

// The machines the page offers a pairing link for, by label; none while there is no choice.
QStringList offeredMachines(World& world) {
  QQuickItem* choice = page(world).item(QStringLiteral("connectionsMachine"));
  if (!choice->isVisible()) return {};
  // The labels are a JavaScript array.
  QVariant labels = choice->property("model");
  if (labels.metaType() == QMetaType::fromType<QJSValue>()) labels = labels.value<QJSValue>().toVariant();
  return labels.toStringList();
}

void leaveConnections(World& world) {
  world.bridge().dispatch(QStringLiteral("connections.close"), {});
  world.sync();
}

// Asks for a link from the page, over Tailscale or not, and waits for the MC to hear of it.
void askFromPage(World& world, bool tailscale) {
  Brick& brick = page(world);
  const qsizetype asked = world.mc.calls.size();
  brick.click(tailscale ? QStringLiteral("connectionsCreateLinkTailscale") : QStringLiteral("connectionsCreateLink"));
  world.waitFor([&] { return world.mc.calls.size() > asked; },
                [&] { return QStringLiteral("the MC to be asked; the Connections page is %1").arg(show(connections(world))); });
}

// Creates a link from the page, and waits for the MC's answer.
void createFromPage(World& world, bool tailscale) {
  askFromPage(world, tailscale);
  world.waitFor([&] { return !connections(world).value(QStringLiteral("busy")).toBool(); },
                [&] { return QStringLiteral("the MC to answer; the Connections page is %1").arg(show(connections(world))); });
}

// Picks `label` where the page offers the machines, with the keyboard.
void chooseMachine(World& world, const QString& label) {
  Brick& brick = page(world);
  QQuickItem* choice = brick.item(QStringLiteral("connectionsMachine"));
  const qsizetype wanted = offeredMachines(world).indexOf(label);
  expect(wanted >= 0, QStringLiteral("%1 is not offered: %2").arg(label, offeredMachines(world).join(u", ")));
  choice->forceActiveFocus();
  for (int index = choice->property("currentIndex").toInt(); index != wanted; index += index < wanted ? 1 : -1) {
    expect(brick.press(index < wanted ? QStringLiteral("down") : QStringLiteral("up")), QStringLiteral("the machine choice took no key"));
  }
  expect(choice->property("displayText").toString() == label,
         QStringLiteral("%1 is chosen").arg(choice->property("displayText").toString()));
}

// The last call of `method`, and the machine it was for.
FakeMc::Rpc lastCall(World& world, const QString& method) {
  world.sync();
  for (qsizetype index = world.mc.calls.size() - 1; index >= 0; --index) {
    if (world.mc.calls.at(index).method == method) return world.mc.calls.at(index);
  }
  fail(QStringLiteral("the MC was not asked for %1").arg(method));
}

// The link the page shows, in its field.
QString shownLink(World& world) {
  QQuickItem* field = page(world).item(QStringLiteral("connectionsCreatedLink"));
  expect(field->isVisible(), QStringLiteral("no link is shown; the Connections page is %1").arg(show(connections(world))));
  return field->property("text").toString();
}

// The page's QR code as it is drawn: every module, and the quiet zone around
// them, read off the window at its centre and held against the code of `text`.
// Black on white exactly, whatever the theme.
void expectQrCodeOf(World& world, const QString& text) {
  Brick& brick = page(world);
  QQuickItem* drawn = brick.item(QStringLiteral("connectionsQr"));
  expect(drawn->isVisible(), QStringLiteral("no QR code is shown; the Connections page is %1").arg(show(connections(world))));
  const qr::Code code = qr::encode(text);
  const int module = drawn->property("moduleSize").toInt();
  const int quiet = drawn->property("quietZone").toInt();
  expect(!code.isNull() && drawn->property("modules").toInt() == code.size && quiet >= 4 && module >= 1 &&
             qRound(drawn->width()) == (code.size + 2 * quiet) * module && qRound(drawn->height()) == qRound(drawn->width()),
         QStringLiteral("the code of %1 has %2 modules; %3 are drawn, %4 px each, in %5x%6 with a quiet zone of %7")
             .arg(text).arg(code.size).arg(drawn->property("modules").toInt()).arg(module).arg(drawn->width()).arg(drawn->height()).arg(quiet));
  const QImage image = brick.grab();
  const QPointF corner = drawn->mapToScene(QPointF(0, 0));
  expect(corner.x() >= 0 && corner.y() >= 0 && corner.y() + drawn->height() <= brick.window().height(),
         QStringLiteral("the code is at %1,%2, out of the window").arg(corner.x()).arg(corner.y()));
  QStringList wrong;
  for (int y = -quiet; y < code.size + quiet; ++y) {
    for (int x = -quiet; x < code.size + quiet; ++x) {
      const bool dark = x >= 0 && y >= 0 && x < code.size && y < code.size && code.dark(x, y);
      const QPoint centre = ((corner + QPointF((x + quiet + 0.5) * module, (y + quiet + 0.5) * module)) * image.devicePixelRatio()).toPoint();
      if (!image.rect().contains(centre)) continue;  // off a window too narrow for it
      const QColor colour = image.pixelColor(centre);
      if (colour != QColor(dark ? Qt::black : Qt::white)) {
        wrong.append(QStringLiteral("(%1,%2) is %3").arg(x).arg(y).arg(colour.name()));
      }
    }
  }
  expect(wrong.isEmpty(), QStringLiteral("%1 modules are not the code's: %2").arg(wrong.size()).arg(wrong.mid(0, 8).join(u", ")));
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
    leaveConnections(world);
    openConnections(world);
  });
  step(QStringLiteral("the user leaves the Connections page"), [](World& world, const Captures&, const Table&) { leaveConnections(world); });
  step(QStringLiteral("the user comes back to the Connections page"), [](World& world, const Captures&, const Table&) { openConnections(world); });
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

  // Where a link's machine is reached, the machine it is for, and its QR code.
  step(QStringLiteral("this machine is reached over Tailscale at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).tailnet.insert(QString(), c[0]);
  });
  step(QStringLiteral("Tailscale is not running on this machine"), [](World& world, const Captures&, const Table&) {
    fake(world).tailnet.remove(QString());
  });
  step(QStringLiteral("the cluster also has the machine %1(?:, reached over Tailscale at %1)?").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.mc.join(c[0]);
         if (!c.value(1).isEmpty()) fake(world).tailnet.insert(c[0], c[1]);
         world.waitFor([&] { return offeredMachines(world).contains(c[0]); },
                       [&] { return QStringLiteral("%1 to be offered; the Connections page is %2").arg(c[0], show(connections(world))); });
       });
  step(QStringLiteral("the cluster also has the machines %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.join(c[0]);
    world.mc.join(c[1]);
    world.waitFor([&] { return offeredMachines(world).size() == 3; },
                  [&] { return QStringLiteral("both to be offered; the Connections page is %1").arg(show(connections(world))); });
  });
  step(QStringLiteral("(this machine|%1) runs a HAL-C2 from before pairing links named their address").arg(q),
       [](World& world, const Captures& c, const Table&) { fake(world).silent.insert(c.value(1)); });
  step(QStringLiteral("the Connections settings are shown in (a wide window|a narrow window|a window narrower than a code can be read)"),
       [](World& world, const Captures& c, const Table&) {
         page(world, c[0] == QLatin1String("a wide window") ? 900 : c[0] == QLatin1String("a narrow window") ? 300 : 200);
       });
  step(QStringLiteral("the user creates a pairing link over Tailscale"), [](World& world, const Captures&, const Table&) {
    createFromPage(world, true);
  });
  step(QStringLiteral("the user creates a pairing link at the address this machine listens on"), [](World& world, const Captures&, const Table&) {
    createFromPage(world, false);
  });
  step(QStringLiteral("the user (?:creates|created) a pairing link for %1( over Tailscale)?").arg(q),
       [](World& world, const Captures& c, const Table&) {
         chooseMachine(world, c[0]);
         createFromPage(world, !c.value(1).isEmpty());
       });
  // Its answer is the scenario's to wait for ("the MC holds its answers").
  step(QStringLiteral("the user asks for a pairing link for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseMachine(world, c[0]);
    askFromPage(world, false);
  });
  step(QStringLiteral("(this machine|%1) is asked for the pairing link over Tailscale").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeMc::Rpc asked = lastCall(world, QStringLiteral("hal-c2.createPairingLink"));
    const QString machine = c.value(1).isEmpty() ? world.mc.environmentId : c[1];
    expect(asked.environment == machine && asked.payload.value(QLatin1String("tailscale")).toBool(),
           QStringLiteral("%1 was asked with %2").arg(asked.environment, show(asked.payload.toVariantMap())));
  });
  step(QStringLiteral("the link shown starts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString link = shownLink(world);
    const QString code = at(connections(world), QStringLiteral("created.code")).toString();
    expect(!code.isEmpty() && link == c[0] + code, QStringLiteral("the link shown is %1").arg(link));
  });
  step(QStringLiteral("the link shown starts with the address this desktop reached the machine at"), [](World& world, const Captures&, const Table&) {
    const QString link = shownLink(world);
    expect(link.startsWith(world.mc.origin().toString() + QStringLiteral("/pair#token=secret-")), QStringLiteral("the link shown is %1").arg(link));
  });
  step(QStringLiteral("a QR code of the link shown is offered, dark on light"), [](World& world, const Captures&, const Table&) {
    expectQrCodeOf(world, shownLink(world));
  });
  step(QStringLiteral("the QR code of the link shown is (whole, at its full size|whole, smaller|no smaller than a phone can scan)"),
       [](World& world, const Captures& c, const Table&) {
         expectQrCodeOf(world, shownLink(world));
         Brick& brick = page(world);
         QQuickItem* drawn = brick.item(QStringLiteral("connectionsQr"));
         const int module = drawn->property("moduleSize").toInt();
         const int full = qCeil(drawn->property("preferredSide").toReal() / drawn->property("side").toInt());
         // The page's content ends its margin short of the window's edge.
         const qreal room = brick.root()->property("contentWidth").toReal();
         const QString is = QStringLiteral("each module is %1 px (%2 at full size), the code is %3 wide where the page has %4")
                                .arg(module).arg(full).arg(drawn->width()).arg(room);
         if (c[0] == QLatin1String("whole, at its full size")) {
           expect(module == full && drawn->width() <= room, is);
         } else if (c[0] == QLatin1String("whole, smaller")) {
           expect(module < full && module >= 4 && drawn->width() <= room, is);
         } else {
           // Four pixels a module is as small as it gets, though the page has less room than that.
           expect(module == 4 && drawn->width() > room, is);
         }
       });
  step(QStringLiteral("no QR code is offered"), [](World& world, const Captures&, const Table&) {
    const QVariantMap created = connections(world).value(QStringLiteral("created")).toMap();
    expect(!created.isEmpty() && created.value(QStringLiteral("qr")).isNull() &&
               !page(world).item(QStringLiteral("connectionsQr"))->isVisible(),
           QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("the user is told to create the link over Tailscale or start the machine on a network address"),
       [](World& world, const Captures&, const Table&) {
         QQuickItem* told = page(world).item(QStringLiteral("connectionsLocalOnly"));
         const QString text = told->property("text").toString();
         expect(told->isVisible() && text.contains(QLatin1String("No QR code")) && text.contains(QLatin1String("over Tailscale")) &&
                    text.contains(QLatin1String("HAL_C2_MC_HOST")),
                QStringLiteral("the page says \"%1\" (shown: %2)").arg(text).arg(told->isVisible()));
       });
  step(QStringLiteral("no pairing link is shown"), [](World& world, const Captures&, const Table&) {
    expect(connections(world).value(QStringLiteral("created")).isNull() &&
               !page(world).item(QStringLiteral("connectionsCreatedLink"))->isVisible() &&
               !page(world).item(QStringLiteral("connectionsQr"))->isVisible(),
           QStringLiteral("the Connections page is %1").arg(show(connections(world))));
  });
  step(QStringLiteral("a pairing link can be for this machine(?:, %1)? or %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList wanted{QStringLiteral("This machine")};
    for (const QString& label : c) {
      if (!label.isEmpty()) wanted.append(label);
    }
    world.waitFor([&] { return offeredMachines(world) == wanted; },
                  [&] { return QStringLiteral("%1 to be offered; offered are %2").arg(wanted.join(u", "), offeredMachines(world).join(u", ")); });
  });
  step(QStringLiteral("no choice of machine is offered for a pairing link"), [](World& world, const Captures&, const Table&) {
    expect(offeredMachines(world).isEmpty() && page(world).item(QStringLiteral("connectionsCreateLink"))->isVisible(),
           QStringLiteral("offered are %1").arg(offeredMachines(world).join(u", ")));
  });
  step(QStringLiteral("the user revokes that link"), [](World& world, const Captures&, const Table&) {
    page(world).click(QStringLiteral("connectionsRevokeCreated"));
  });
  step(QStringLiteral("%1 is asked to revoke it").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeMc::Rpc asked = lastCall(world, QStringLiteral("hal-c2.revokePairingLink"));
    expect(asked.environment == c[0], QStringLiteral("%1 was asked").arg(asked.environment));
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
