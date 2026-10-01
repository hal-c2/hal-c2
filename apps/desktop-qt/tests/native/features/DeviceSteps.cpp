// The right panel's Device tabs (ThreadDevices, DeviceStream, DeviceDecoder):
// the MC's DeviceServiceState on the `devices` shape and `device.list`,
// `device.open` and `device.close`, and a fake device hub behind the MC's
// `/api/device-hub/` proxy speaking serve-sim (AVCC video, `[tag][json]`
// input) and serve-emu (SEMU-framed Annex-B and JSON gestures on one socket).
// The pictures are the committed fixture, a solid red 72x160 H.264 clip.
//
// The tab is the desktop's own DevicePanel (qml/HalC2/Bricks), loaded over
// the scenario's ThreadDevices once the user looks at the thread: the user's
// clicks, drags and keys are QTest events on its window, and a step reads the
// picture back from the window as DeviceScreen drew it. Choosing which tab
// shows is the right panel's (PanelSteps), so those steps dispatch.
// features/preview/devices.feature.

#include <QFile>
#include <QImage>
#include <QTest>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTcpSocket>
#include <QUrl>
#include <QWebSocket>
#include <QWebSocketServer>
#include <QtEndian>

#include <memory>

#include "Brick.h"
#include "DeviceStream.h"
#include "FFmpeg.h"
#include "Harness.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadDevices.h"
#include "World.h"

namespace {

using namespace stream;

const QString kHost = QStringLiteral("local");
constexpr int kRetryMs = 50;
constexpr int kFirstFrameMs = 15000;

// The fixture's NAL units: its parameter sets and one slice per picture.
struct Fixture {
  QByteArray sps;
  QByteArray pps;
  QList<QByteArray> slices;
  QList<bool> keys;
};

const Fixture& fixture() {
  static const Fixture parsed = [] {
    QFile file(QStringLiteral(HAL_C2_DEVICE_FIXTURE));
    if (!file.open(QIODevice::ReadOnly)) qFatal("the device fixture is missing");
    const QByteArray data = file.readAll();
    QList<qsizetype> starts;
    for (qsizetype at = data.indexOf(QByteArray("\0\0\1", 3)); at >= 0; at = data.indexOf(QByteArray("\0\0\1", 3), at + 3)) starts.append(at + 3);
    Fixture fixture;
    for (qsizetype n = 0; n < starts.size(); ++n) {
      qsizetype end = n + 1 < starts.size() ? starts[n + 1] - 3 : data.size();
      if (n + 1 < starts.size() && data.at(end - 1) == 0) --end;  // a four-byte start code
      const QByteArray nal = data.mid(starts[n], end - starts[n]);
      const int type = nal.at(0) & 0x1f;
      if (type == 7 && fixture.sps.isEmpty()) fixture.sps = nal;
      if (type == 8 && fixture.pps.isEmpty()) fixture.pps = nal;
      if (type == 1 || type == 5) {
        fixture.slices.append(nal);
        fixture.keys.append(type == 5);
      }
    }
    return fixture;
  }();
  return parsed;
}

QByteArray u32(quint32 value) {
  QByteArray bytes(4, 0);
  qToBigEndian(value, bytes.data());
  return bytes;
}

QByteArray u16(quint16 value) {
  QByteArray bytes(2, 0);
  qToBigEndian(value, bytes.data());
  return bytes;
}

// serve-sim's stream.avcc body: the avcC record, then every picture. A
// `broken` record is one no decoder starts from.
QByteArray iosVideo(bool broken = false) {
  const Fixture& f = fixture();
  const auto envelope = [](char tag, const QByteArray& payload) { return u32(quint32(payload.size() + 1)) + tag + payload; };
  QByteArray avcc;
  avcc += char(1);
  avcc += f.sps.mid(1, 3);
  avcc += char(0xff);  // four-byte lengths
  avcc += char(0xe1);  // one SPS
  avcc += u16(quint16(f.sps.size())) + f.sps;
  avcc += char(1);
  avcc += u16(quint16(f.pps.size())) + f.pps;
  if (broken) avcc.truncate(4);
  QByteArray body = envelope(1, avcc);
  for (qsizetype n = 0; n < f.slices.size(); ++n)
    body += envelope(f.keys[n] ? 2 : 3, u32(quint32(f.slices[n].size())) + f.slices[n]);
  return body;
}

// serve-emu's frames: Annex-B access units behind a SEMU header.
QList<QByteArray> androidVideo() {
  const Fixture& f = fixture();
  const QByteArray start("\0\0\0\1", 4);
  QList<QByteArray> frames;
  for (qsizetype n = 0; n < f.slices.size(); ++n) {
    QByteArray header = u32(0x53454d55) + QByteArray(12, 0);
    header[4] = 1;
    header[5] = f.keys[n] ? 1 : 0;
    const QByteArray unit = (f.keys[n] ? start + f.sps + start + f.pps : QByteArray()) + start + f.slices[n];
    frames.append(header + unit);
  }
  return frames;
}

// The environment's devices and the hub the MC proxies to.
struct FakeHub {
  QJsonArray devices;
  QJsonArray sessions;
  QString hostStatus = QStringLiteral("ready");
  int revision = 0;
  // Why the MC fails `device.open`, when it does.
  QString refuseOpen;
  QList<QJsonObject> closes;
  // The proxy's status for every hub request (401: a refused credential), when not 200.
  int refuse = 0;
  // The device has sent no picture yet.
  bool silent = false;
  // Its video is not one the desktop can decode.
  bool undecodable = false;
  // Every request that reached the proxy: "<target> <authorization>".
  QStringList requests;
  std::unique_ptr<QWebSocketServer> sockets;
  QList<QPointer<QTcpSocket>> videos;
  QList<QPointer<QWebSocket>> inputs;
  // What the device received: serve-sim's `[tag][json]`, serve-emu's JSON.
  QList<QByteArray> binary;
  QList<QJsonObject> text;
  bool used = false;
  bool looking = false;
  // FFmpeg is made to look not installed, until this MC goes.
  bool noFFmpeg = false;
  ~FakeHub() {
    if (noFFmpeg) ffmpeg::pretendMissing(false);
  }
};

QJsonObject stateOf(FakeMc& mc) {
  FakeHub& hub = mc.part<FakeHub>();
  const QJsonArray platforms{QJsonObject{{QStringLiteral("platform"), QStringLiteral("ios")}, {QStringLiteral("available"), true}},
                             QJsonObject{{QStringLiteral("platform"), QStringLiteral("android")}, {QStringLiteral("available"), true}}};
  return {{QStringLiteral("hosts"), QJsonArray{QJsonObject{{QStringLiteral("id"), kHost},
                                                            {QStringLiteral("kind"), QStringLiteral("local")},
                                                            {QStringLiteral("label"), QStringLiteral("This Mac")},
                                                            {QStringLiteral("platforms"), platforms},
                                                            {QStringLiteral("hubInstalled"), true},
                                                            {QStringLiteral("agentDeviceInstalled"), true}}}},
          {QStringLiteral("hostStatus"), hub.hostStatus},
          {QStringLiteral("hostStatuses"), QJsonObject{{kHost, QJsonObject{{QStringLiteral("status"), hub.hostStatus}}}}},
          {QStringLiteral("devices"), hub.devices},
          {QStringLiteral("sessions"), hub.sessions},
          {QStringLiteral("onboardingCompleted"), hub.hostStatus != QLatin1String("disabled")},
          {QStringLiteral("agentAccessEnabled"), false},
          {QStringLiteral("hubBasePath"), QStringLiteral("/api/device-hub/mcs/") + QString::fromLatin1(QUrl::toPercentEncoding(mc.name))},
          {QStringLiteral("revision"), hub.revision}};
}

// The MC tells every watcher, as devices.ex does on each change.
void announce(FakeMc& mc) {
  ++mc.part<FakeHub>().revision;
  for (const int id : mc.subscribers(QStringLiteral("devices")))
    mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), stateOf(mc)}});
}

int sessionOf(const FakeHub& hub, const QString& deviceId, const QString& thread = kThread) {
  for (qsizetype n = 0; n < hub.sessions.size(); ++n) {
    const QJsonObject session = hub.sessions.at(n).toObject();
    if (session.value(QLatin1String("threadId")) == thread && session.value(QLatin1String("deviceId")) == deviceId) return int(n);
  }
  return -1;
}

QJsonObject deviceNamed(const FakeHub& hub, const QString& name) {
  for (const QJsonValue& device : hub.devices) {
    if (device.toObject().value(QLatin1String("name")) == name) return device.toObject();
  }
  fail(QStringLiteral("the hub has no device \"%1\"").arg(name));
}

void openSession(FakeMc& mc, const QJsonObject& device, const QString& thread = kThread) {
  FakeHub& hub = mc.part<FakeHub>();
  for (qsizetype n = 0; n < hub.devices.size(); ++n) {
    QJsonObject listed = hub.devices.at(n).toObject();
    if (listed.value(QLatin1String("id")) == device.value(QLatin1String("id"))) {
      listed.insert(QStringLiteral("booted"), true);
      hub.devices.replace(n, listed);
    }
  }
  if (sessionOf(hub, device.value(QLatin1String("id")).toString(), thread) < 0)
    hub.sessions.append(QJsonObject{{QStringLiteral("threadId"), thread},
                                    {QStringLiteral("hostId"), kHost},
                                    {QStringLiteral("deviceId"), device.value(QLatin1String("id"))},
                                    {QStringLiteral("platform"), device.value(QLatin1String("platform"))},
                                    {QStringLiteral("openedAt"), QStringLiteral("2026-09-23T10:00:00Z")}});
}

void sendVideo(FakeHub& hub) {
  for (const QPointer<QTcpSocket>& video : std::as_const(hub.videos)) {
    if (video && video->state() == QAbstractSocket::ConnectedState) video->write(iosVideo());
  }
  for (const QPointer<QWebSocket>& socket : std::as_const(hub.inputs)) {
    if (!socket || !socket->requestUrl().path().endsWith(QLatin1String("/serve-emu/ws"))) continue;
    for (const QByteArray& frame : androidVideo()) socket->sendBinaryMessage(frame);
  }
}

void respond(QTcpSocket* socket, int status) {
  socket->write(QStringLiteral("HTTP/1.1 %1 Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").arg(status).toUtf8());
  socket->disconnectFromHost();
}

QWebSocketServer& hubSockets(FakeMc& mc) {
  FakeHub& hub = mc.part<FakeHub>();
  if (hub.sockets) return *hub.sockets;
  hub.sockets = std::make_unique<QWebSocketServer>(QStringLiteral("fake-hub"), QWebSocketServer::NonSecureMode);
  QWebSocketServer* server = hub.sockets.get();
  QObject::connect(server, &QWebSocketServer::newConnection, server, [&mc, server] {
    while (QWebSocket* socket = server->nextPendingConnection()) {
      socket->setParent(server);
      FakeHub& hub = mc.part<FakeHub>();
      hub.inputs.append(socket);
      const bool android = socket->requestUrl().path().endsWith(QLatin1String("/serve-emu/ws"));
      QObject::connect(socket, &QWebSocket::binaryMessageReceived, server, [&mc](const QByteArray& message) {
        mc.part<FakeHub>().binary.append(message);
      });
      QObject::connect(socket, &QWebSocket::textMessageReceived, server, [&mc, socket](const QString& message) {
        FakeHub& hub = mc.part<FakeHub>();
        const QJsonObject parsed = QJsonDocument::fromJson(message.toUtf8()).object();
        hub.text.append(parsed);
        // serve-emu answers a keyframe request with a fresh keyframe.
        if (parsed.value(QLatin1String("type")) == QLatin1String("reset-video") && !hub.silent) {
          for (const QByteArray& frame : androidVideo()) socket->sendBinaryMessage(frame);
        }
      });
      if (android && !hub.silent) {
        for (const QByteArray& frame : androidVideo()) socket->sendBinaryMessage(frame);
      }
    }
  });
  return *server;
}

// The MC's devices as this file fakes them. IntegrationsSettingsSteps fakes
// the same shape and calls for the settings page, so a scenario that uses the
// hub takes them over on first use, before the shell connects.
FakeHub& fakeHub(World& world) {
  FakeMc& mc = world.mc;
  FakeHub& hub = mc.part<FakeHub>();
  if (hub.used) return hub;
  hub.used = true;
  // As an MC is named (`name@host`), which its hubBasePath carries encoded.
  mc.name = QStringLiteral("hal-c2@studio");
  mc.onShape(QStringLiteral("devices"), [&mc](int id, const QJsonObject&) {
    mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), stateOf(mc)}});
  });
  mc.onRpc(QStringLiteral("device.list"), [&mc](const FakeMc::Rpc& rpc) { mc.reply(rpc, stateOf(mc)); });
  mc.onRpc(QStringLiteral("device.open"), [&mc](const FakeMc::Rpc& rpc) {
    FakeHub& hub = mc.part<FakeHub>();
    if (!hub.refuseOpen.isEmpty()) return mc.refuse(rpc, hub.refuseOpen);
    QJsonObject device;
    for (const QJsonValue& listed : std::as_const(hub.devices)) {
      if (listed.toObject().value(QLatin1String("id")) == rpc.payload.value(QLatin1String("deviceId"))) device = listed.toObject();
    }
    if (device.isEmpty()) return mc.refuse(rpc, QStringLiteral("Device not found"));
    const QString thread = rpc.payload.value(QLatin1String("threadId")).toString();
    openSession(mc, device, thread);
    announce(mc);
    mc.reply(rpc, hub.sessions.at(sessionOf(hub, device.value(QLatin1String("id")).toString(), thread)));
  });
  mc.onRpc(QStringLiteral("device.close"), [&mc](const FakeMc::Rpc& rpc) {
    const auto close = [&mc, rpc] {
      FakeHub& hub = mc.part<FakeHub>();
      hub.closes.append(rpc.payload);
      const int at = sessionOf(hub, rpc.payload.value(QLatin1String("deviceId")).toString(), rpc.payload.value(QLatin1String("threadId")).toString());
      if (at >= 0) hub.sessions.removeAt(at);
      announce(mc);
      mc.reply(rpc, QJsonValue::Null);
    };
    if (mc.holding(QStringLiteral("device.close"))) return mc.defer(close);
    close();
  });
  return hub;
}

const FakeMc::Extension proxy([](FakeMc& mc) {
  // The MC's device proxy, and the hub behind it.
  mc.onRaw(QStringLiteral("/api/device-hub/"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    FakeHub& hub = mc.part<FakeHub>();
    const QList<QByteArray> lines = head.split('\n');
    const QString target = QString::fromUtf8(lines.value(0).split(' ').value(1));
    QString authorization;
    bool upgrade = false;
    for (const QByteArray& line : lines) {
      const QByteArray lower = line.trimmed().toLower();
      if (lower.startsWith("authorization:")) authorization = QString::fromUtf8(line.trimmed().mid(14).trimmed());
      if (lower.startsWith("upgrade:")) upgrade = true;
    }
    hub.requests.append(target + QLatin1Char(' ') + authorization);
    if (hub.refuse) {
      socket->read(head.size());
      return respond(socket, hub.refuse);
    }
    if (upgrade) return hubSockets(mc).handleConnection(socket);
    socket->read(head.size());
    const QString path = target.section(QLatin1Char('?'), 0, 0);
    if (path.endsWith(QLatin1String("/stream.mjpeg"))) {
      socket->write("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nConnection: close\r\n\r\n--frame\r\n");
      return;
    }
    if (path.endsWith(QLatin1String("/stream.avcc"))) {
      socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n");
      hub.videos.append(socket);
      if (!hub.silent) socket->write(iosVideo(hub.undecodable));
      return;
    }
    respond(socket, 404);
  });
});

RightPanelController& panel(World& world) {
  return *world.native().controller<RightPanelController>();
}

ThreadDevices& devices(World& world) {
  return *panel(world).device();
}

DeviceStream& deviceStream(World& world) {
  return *devices(world).stream();
}

QVariantMap view(World& world) {
  return devices(world).view();
}

QString describe(World& world) {
  DeviceStream& stream = deviceStream(world);
  return QStringLiteral("the panel is %1; the Device view is %2; the stream is %3 (%4), input %5; the hub saw %6")
      .arg(show(world.state(QStringLiteral("panel"))), show(view(world)), stream.status(), stream.detail(),
           stream.inputConnected() ? QStringLiteral("connected") : QStringLiteral("closed"),
           fakeHub(world).requests.join(QStringLiteral(", ")));
}

void addDevice(World& world, const QString& platform, const QString& name, bool booted) {
  const QString id = platform == QLatin1String("ios") ? QStringLiteral("UDID-") + QString(name).replace(QLatin1Char(' '), QLatin1Char('-')).toUpper()
                                                      : QStringLiteral("emulator-5554");
  fakeHub(world).devices.append(QJsonObject{{QStringLiteral("hostId"), kHost},
                                                        {QStringLiteral("id"), id},
                                                        {QStringLiteral("name"), name},
                                                        {QStringLiteral("platform"), platform},
                                                        {QStringLiteral("version"), platform == QLatin1String("ios") ? QStringLiteral("iOS 26.0") : QStringLiteral("Android 16")},
                                                        {QStringLiteral("booted"), booted},
                                                        {QStringLiteral("physical"), false}});
}

// The Device tab as the desktop draws it, over the scenario's ThreadDevices.
Brick& devicePanel(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nDevicePanel {}\n", QSize(420, 900));
    world.brick->root()->setProperty("source", QVariant::fromValue<QObject*>(&devices(world)));
  }
  return *world.brick;
}

// The user looks at thread-1, whose environment's devices the shell follows.
void look(World& world) {
  FakeHub& hub = fakeHub(world);
  if (hub.looking) return;
  hub.looking = true;
  world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()}});
  world.connect();
  world.sync();
  lookAtThread(world, kProject);
  deviceStream(world).setTimeouts(kFirstFrameMs, kRetryMs);
  devicePanel(world);
  world.waitFor([&] { return view(world).value(QStringLiteral("loaded")).toBool(); }, [&] { return describe(world); });
}

QString activeTab(World& world) {
  return at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")).toString();
}

QStringList tabTitles(World& world) {
  QStringList titles;
  for (const QVariant& tab : at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList())
    titles.append(at(tab, QStringLiteral("title")).toString());
  return titles;
}

QString tabOf(World& world, const QString& name) {
  return ThreadDevices::tabIdOf(kHost, deviceNamed(fakeHub(world), name).value(QLatin1String("id")).toString());
}

void addDeviceTab(World& world) {
  look(world);
  world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("device")}});
  world.sync();
  world.waitFor([&] { return activeTab(world) == QLatin1String("device") && view(world).value(QStringLiteral("loaded")).toBool(); },
                [&] { return describe(world); });
}

// The picker's row for the device named `name`.
QVariantMap rowOf(World& world, const QString& name, const QString& group = {}) {
  for (const QVariant& listed : view(world).value(QStringLiteral("groups")).toList()) {
    if (!group.isEmpty() && at(listed, QStringLiteral("title")) != group) continue;
    for (const QVariant& row : at(listed, QStringLiteral("devices")).toList()) {
      if (at(row, QStringLiteral("name")) == name) return row.toMap();
    }
  }
  return {};
}

void openFromPicker(World& world, const QString& name) {
  world.waitFor([&] { return !rowOf(world, name).isEmpty(); }, [&] { return describe(world); });
  const QString row = QStringLiteral("deviceRow-") + rowOf(world, name).value(QStringLiteral("id")).toString();
  Brick& panel = devicePanel(world);
  world.waitFor([&] { return panel.item(row)->isVisible() && panel.item(row)->isEnabled(); }, [&] { return describe(world); });
  panel.click(row);
  world.sync();
}

// The user shows the device's tab: activates it, or opens the device from
// the picker when the panel has no tab for it yet.
void showDeviceTab(World& world, const QString& name) {
  look(world);
  const QString tab = tabOf(world, name);
  if (tabTitles(world).contains(name)) {
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), tab}});
  } else {
    addDeviceTab(world);
    openFromPicker(world, name);
  }
  world.sync();
  world.waitFor([&] { return activeTab(world) == tab; }, [&] { return describe(world); });
}

QQuickItem* screenItem(World& world) {
  return devicePanel(world).item(QStringLiteral("deviceScreen"));
}

bool red(const QColor& colour) {
  return colour.red() > 160 && colour.green() < 90 && colour.blue() < 90;
}

// The colour the window shows at the middle of the device's screen.
QColor drawnAtScreen(World& world) {
  QQuickItem* screen = screenItem(world);
  const QImage drawn = devicePanel(world).grab();
  const QPointF middle = screen->mapToScene(QPointF(screen->width() / 2, screen->height() / 2)) * drawn.devicePixelRatio();
  return drawn.pixelColor(middle.toPoint());
}

QString describeScreen(World& world) {
  QQuickItem* screen = screenItem(world);
  return QStringLiteral("%1; the screen item has a picture: %2, shown %3, colour %4")
      .arg(describe(world))
      .arg(screen->property("hasFrame").toBool())
      .arg(screen->isVisible())
      .arg(drawnAtScreen(world).name());
}

// The tab drew the fixture's red screen: DeviceScreen took the picture the
// decoder announced (frameReady) and the window shows it.
void waitForScreen(World& world, const QString& name) {
  const QString tab = tabOf(world, name);
  QQuickItem* screen = screenItem(world);
  world.waitFor([&] {
    return activeTab(world) == tab && tabTitles(world).contains(name) && deviceStream(world).status() == QLatin1String("streaming") &&
           screen->property("hasFrame").toBool() && screen->isVisible();
  }, [&] { return describeScreen(world); });
  expect(red(drawnAtScreen(world)), describeScreen(world));
}

void watch(World& world, const QString& name) {
  showDeviceTab(world, name);
  waitForScreen(world, name);
  world.waitFor([&] { return deviceStream(world).inputConnected(); }, [&] { return describe(world); });
}

// serve-sim's input messages of `tag`, as JSON.
QList<QJsonObject> iosInput(World& world, char tag) {
  QList<QJsonObject> messages;
  for (const QByteArray& message : std::as_const(fakeHub(world).binary)) {
    if (!message.isEmpty() && message.at(0) == tag) messages.append(QJsonDocument::fromJson(message.mid(1)).object());
  }
  return messages;
}

QString describeInput(World& world) {
  QStringList received;
  for (const QByteArray& message : std::as_const(fakeHub(world).binary))
    received.append(QStringLiteral("%1 %2").arg(int(message.at(0))).arg(QString::fromUtf8(message.mid(1))));
  for (const QJsonObject& message : std::as_const(fakeHub(world).text))
    received.append(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
  return QStringLiteral("the device received %1").arg(received.join(QStringLiteral(", ")));
}

bool streamClosed(World& world) {
  FakeHub& hub = fakeHub(world);
  for (const QPointer<QTcpSocket>& video : std::as_const(hub.videos)) {
    if (video && video->state() == QAbstractSocket::ConnectedState) return false;
  }
  for (const QPointer<QWebSocket>& socket : std::as_const(hub.inputs)) {
    if (socket && socket->state() == QAbstractSocket::ConnectedState) return false;
  }
  return deviceStream(world).status() == QLatin1String("idle");
}

qsizetype videoRequests(World& world) {
  qsizetype count = 0;
  for (const QString& request : std::as_const(fakeHub(world).requests))
    count += request.contains(QLatin1String("/stream.avcc")) || request.contains(QLatin1String("/serve-emu/ws"));
  return count;
}

// A click on the screen at (fx, fy) of it as shown.
void tap(World& world, double fx, double fy) {
  Brick& panel = devicePanel(world);
  QTest::mouseClick(&panel.window(), Qt::LeftButton, Qt::NoModifier, panel.at(panel.item(QStringLiteral("deviceTouch")), fx, fy));
}

// A key typed on the screen, which has the keyboard once the user tapped it.
void press(World& world, Qt::Key key, char text = 0) {
  Brick& panel = devicePanel(world);
  expect(panel.item(QStringLiteral("deviceStage"))->hasActiveFocus(), QStringLiteral("the device's screen does not have the keyboard"));
  if (text) QTest::keyClick(&panel.window(), text);
  else QTest::keyClick(&panel.window(), key);
}

// Within a pixel of the screen as shown: clicks land on whole pixels.
bool near(double value, double wanted) {
  return std::abs(value - wanted) < 0.01;
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // The environment's devices.
  step(QStringLiteral("the thread's environment has an (iOS Simulator|Android Emulator) %1 (running|stopped)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addDevice(world, c[0] == QLatin1String("iOS Simulator") ? QStringLiteral("ios") : QStringLiteral("android"), c[1], c[2] == QLatin1String("running"));
       });
  step(QStringLiteral("a simulator is booted"), [](World& world, const Captures&, const Table&) {
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
  });
  step(QStringLiteral("the thread's environment has no simulators or emulators"), [](World& world, const Captures&, const Table&) { fakeHub(world); });
  step(QStringLiteral("device support is off on the thread's environment"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).hostStatus = QStringLiteral("disabled");
  });
  step(QStringLiteral("the thread has the (iOS Simulator|Android Emulator) %1 open").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, c[0] == QLatin1String("iOS Simulator") ? QStringLiteral("ios") : QStringLiteral("android"), c[1], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[1]));
  });
  step(QStringLiteral("the MC cannot open devices because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).refuseOpen = c[0];
  });
  step(QStringLiteral("the MC refuses the device stream"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).refuse = 401;
  });
  step(QStringLiteral("the device sends no picture yet"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).silent = true;
  });
  step(QStringLiteral("FFmpeg is not installed"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).noFFmpeg = true;
    ffmpeg::pretendMissing(true);
  });
  step(QStringLiteral("the tab says to install FFmpeg to watch device screens"), [](World& world, const Captures&, const Table&) {
    // The words the panel shows over where the picture would be.
    const auto shown = [&]() -> QString {
      const QQuickItem* status = devicePanel(world).item(QStringLiteral("deviceStatus"));
      if (!status || !status->isVisible()) return {};
      for (const QQuickItem* child : status->childItems()) {
        if (child->isVisible() && child->property("text").isValid()) return child->property("text").toString();
      }
      return {};
    };
    world.waitFor([&] { return shown().startsWith(QLatin1String("Install FFmpeg to watch device screens")); },
                  [&] { return shown() + QLatin1Char('\n') + describe(world); });
  });
  step(QStringLiteral("the device sends video the desktop cannot decode"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).undecodable = true;
  });
  step(QStringLiteral("the tab asked for the device's video (\\d+) times"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(videoRequests(world) == c[0].toInt(), describe(world));
  });
  step(QStringLiteral("the device starts sending pictures"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.silent = false;
    sendVideo(hub);
  });
  step(QStringLiteral("the device sends its video in pieces"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    const auto open = [&]() -> QTcpSocket* {
      for (const QPointer<QTcpSocket>& video : std::as_const(hub.videos)) {
        if (video && video->state() == QAbstractSocket::ConnectedState) return video;
      }
      return nullptr;
    };
    world.waitFor([&] { return open() != nullptr; }, [&] { return describe(world); });
    QTcpSocket* video = open();
    // Every envelope in three pieces: half its length, then the rest of its
    // header and half its payload, then the rest. A round trip through the
    // MC between pieces lets the desktop read each one on its own.
    const QByteArray body = iosVideo();
    QList<qsizetype> cuts;
    for (qsizetype at = 0; at < body.size(); at += 4 + qsizetype(qFromBigEndian<quint32>(body.constData() + at))) {
      const auto length = qsizetype(qFromBigEndian<quint32>(body.constData() + at));
      cuts << at + 2 << at + 4 + length / 2;
    }
    cuts << body.size();
    qsizetype from = 0;
    for (const qsizetype cut : std::as_const(cuts)) {
      video->write(body.mid(from, cut - from));
      video->flush();
      world.sync();
      from = cut;
    }
  });
  step(QStringLiteral("the user is looking at the thread"), [](World& world, const Captures&, const Table&) { look(world); });

  // Choosing.
  step(QStringLiteral("the user adds a Device tab"), [](World& world, const Captures&, const Table&) { addDeviceTab(world); });
  step(QStringLiteral("the user adds a device tab for it"), [](World& world, const Captures&, const Table&) {
    addDeviceTab(world);
    openFromPicker(world, QStringLiteral("iPhone 17"));
  });
  step(QStringLiteral("%1 is offered under %1( to start)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString action = c.value(2).isEmpty() ? QStringLiteral("Open") : QStringLiteral("Start");
    world.waitFor([&] { return rowOf(world, c[0], c[1]).value(QStringLiteral("action")) == action; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user opens %1 from the Device tab").arg(q), [](World& world, const Captures& c, const Table&) { openFromPicker(world, c[0]); });
  step(QStringLiteral("the thread has %1 open").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = deviceNamed(fakeHub(world), c[0]).value(QLatin1String("id")).toString();
    expect(sessionOf(fakeHub(world), id) >= 0, describe(world));
    world.waitFor([&] { return activeTab(world) == tabOf(world, c[0]) && !tabTitles(world).contains(QStringLiteral("Device")); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the tab says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap shown = view(world);
      const DeviceStream& stream = deviceStream(world);
      return shown.value(QStringLiteral("empty")) == c[0] || shown.value(QStringLiteral("error")) == c[0] ||
             (stream.status() == QLatin1String("error") && stream.detail() == c[0]);
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user dismisses the error"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("deviceDismissError"));
  });
  step(QStringLiteral("the tab shows no error"), [](World& world, const Captures&, const Table&) {
    expect(view(world).value(QStringLiteral("error")).toString().isEmpty(), describe(world));
  });
  step(QStringLiteral("the tab points to the Integrations settings"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return view(world).value(QStringLiteral("setup")).toBool(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user follows the tab to its settings"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return view(world).value(QStringLiteral("setup")).toBool(); }, [&] { return describe(world); });
    devicePanel(world).click(QStringLiteral("deviceOpenSettings"));
    world.sync();
  });

  // Watching.
  step(QStringLiteral("the user shows the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) { showDeviceTab(world, c[0]); });
  step(QStringLiteral("the user is watching the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) { watch(world, c[0]); });
  step(QStringLiteral("the tab %1 shows the device's screen").arg(q), [](World& world, const Captures& c, const Table&) { waitForScreen(world, c[0]); });
  step(QStringLiteral("the tab streams the simulator's screen"), [](World& world, const Captures&, const Table&) {
    waitForScreen(world, QStringLiteral("iPhone 17"));
  });
  step(QStringLiteral("the screen came through the MC's device proxy"), [](World& world, const Captures&, const Table&) {
    const QString id = deviceNamed(fakeHub(world), QStringLiteral("iPhone 17")).value(QLatin1String("id")).toString();
    // The MC's name is encoded once: `hal-c2%40studio`.
    const QString wanted = QStringLiteral("/api/device-hub/mcs/%1/vendor/serve-sim/helper/%2/stream.avcc Bearer mc-token")
                               .arg(QString::fromLatin1(QUrl::toPercentEncoding(world.mc.name)), id);
    expect(fakeHub(world).requests.contains(wanted), describe(world));
  });
  step(QStringLiteral("the tab says it is connecting to the device"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(deviceStream(world).status() == QLatin1String("connecting") && view(world).value(QStringLiteral("screen")).isValid() &&
               devicePanel(world).item(QStringLiteral("deviceStatus"))->isVisible(),
           describe(world));
  });
  step(QStringLiteral("the tab shows no picture"), [](World& world, const Captures&, const Table&) {
    world.sync();
    QQuickItem* screen = screenItem(world);
    expect(!screen->property("hasFrame").toBool() && !screen->isVisible() && !red(drawnAtScreen(world)), describeScreen(world));
  });
  step(QStringLiteral("no picture comes in time"), [](World& world, const Captures&, const Table&) {
    DeviceStream& stream = deviceStream(world);
    stream.setTimeouts(1, kRetryMs);
    world.waitFor([&] { return stream.status() == QLatin1String("error"); }, [&] { return describe(world); });
    stream.setTimeouts(kFirstFrameMs, kRetryMs);
  });
  step(QStringLiteral("the user reconnects"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("deviceReconnect"));
  });
  step(QStringLiteral("the device's stream ends"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.requests.append(QStringLiteral("-- ended --"));
    for (const QPointer<QTcpSocket>& video : std::as_const(hub.videos)) {
      if (video) video->disconnectFromHost();
    }
  });
  step(QStringLiteral("the tab connects to the device again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QStringList requests = fakeHub(world).requests;
      const qsizetype ended = requests.indexOf(QStringLiteral("-- ended --"));
      for (qsizetype n = ended + 1; n < requests.size(); ++n) {
        if (requests[n].contains(QLatin1String("/stream.avcc"))) return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the emulator's video restarts"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.text.clear();
    for (const QPointer<QWebSocket>& socket : std::as_const(hub.inputs)) {
      if (socket) socket->sendTextMessage(QStringLiteral("{\"type\":\"video-session\"}"));
    }
  });
  step(QStringLiteral("the device is asked for a fresh keyframe"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QJsonObject> received = fakeHub(world).text;
      return std::any_of(received.cbegin(), received.cend(),
                         [](const QJsonObject& message) { return message.value(QLatin1String("type")) == QLatin1String("reset-video"); });
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("no device stream is open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return streamClosed(world); }, [&] { return describe(world); });
    const qsizetype asked = videoRequests(world);
    world.sync();
    expect(videoRequests(world) == asked, describe(world));
  });

  // Driving.
  step(QStringLiteral("the user taps the middle of the screen"), [](World& world, const Captures&, const Table&) { tap(world, 0.5, 0.5); });
  step(QStringLiteral("the user taps the left middle of the screen"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).binary.clear();
    tap(world, 0.25, 0.5);
  });
  step(QStringLiteral("the user types %1 on the device").arg(q), [](World& world, const Captures& c, const Table&) {
    press(world, Qt::Key_unknown, c[0].at(0).toLatin1());
  });
  step(QStringLiteral("the user presses the device's (Home|Recents) button"), [](World& world, const Captures& c, const Table&) {
    devicePanel(world).click(QStringLiteral("device") + c[0]);
  });
  step(QStringLiteral("the user presses Escape on the device"), [](World& world, const Captures&, const Table&) { press(world, Qt::Key_Escape); });
  step(QStringLiteral("the user drags from the middle of the screen to its left middle and the touch is taken away"),
       [](World& world, const Captures&, const Table&) {
         fakeHub(world).binary.clear();
         Brick& panel = devicePanel(world);
         QQuickItem* touch = panel.item(QStringLiteral("deviceTouch"));
         QTest::mousePress(&panel.window(), Qt::LeftButton, Qt::NoModifier, panel.at(touch, 0.5, 0.5));
         QTest::mouseMove(&panel.window(), panel.at(touch, 0.25, 0.5));
         // What a popup or another item taking the mouse mid-drag does.
         touch->ungrabMouse();
         QTest::mouseRelease(&panel.window(), Qt::LeftButton, Qt::NoModifier, panel.at(touch, 0.25, 0.5));
       });
  step(QStringLiteral("the device receives a touch that ends at the left middle"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QJsonObject> touches = iosInput(world, 0x03);
      const auto ends = std::count_if(touches.cbegin(), touches.cend(), [](const QJsonObject& t) { return t.value(QLatin1String("type")) == QLatin1String("end"); });
      return !touches.isEmpty() && ends == 1 && touches.last().value(QLatin1String("type")) == QLatin1String("end") &&
             near(touches.last().value(QLatin1String("x")).toDouble(), 0.25) && near(touches.last().value(QLatin1String("y")).toDouble(), 0.5);
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("the device receives a touch that begins and ends at the middle"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QJsonObject> touches = iosInput(world, 0x03);
      return touches.size() == 2 && touches[0].value(QLatin1String("type")) == QLatin1String("begin") &&
             touches[1].value(QLatin1String("type")) == QLatin1String("end") && near(touches[1].value(QLatin1String("x")).toDouble(), 0.5) &&
             near(touches[1].value(QLatin1String("y")).toDouble(), 0.5);
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("the device receives the key %1 going down and up").arg(q), [](World& world, const Captures& c, const Table&) {
    const int usage = 0x04 + (c[0].at(0).toLower().unicode() - 'a');
    world.waitFor([&] {
      const QList<QJsonObject> keys = iosInput(world, 0x06);
      return keys.size() == 2 && keys[0] == QJsonObject{{QStringLiteral("type"), QStringLiteral("down")}, {QStringLiteral("usage"), usage}} &&
             keys[1] == QJsonObject{{QStringLiteral("type"), QStringLiteral("up")}, {QStringLiteral("usage"), usage}};
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("the device receives the %1 button").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return iosInput(world, 0x04) == QList<QJsonObject>{{{QStringLiteral("button"), c[0]}}}; },
                  [&] { return describeInput(world); });
  });
  step(QStringLiteral("the emulator receives a touch down and up at the middle"), [](World& world, const Captures&, const Table&) {
    const auto touchAt = [](const QList<QJsonObject>& received, const QString& action) {
      for (qsizetype n = 0; n < received.size(); ++n) {
        const QJsonObject& message = received[n];
        if (message.value(QLatin1String("type")) == QLatin1String("touch") && message.value(QLatin1String("action")) == action &&
            near(message.value(QLatin1String("x")).toDouble(), 0.5) && near(message.value(QLatin1String("y")).toDouble(), 0.5))
          return n;
      }
      return qsizetype(-1);
    };
    world.waitFor([&] {
      const QList<QJsonObject> received = fakeHub(world).text;
      const qsizetype down = touchAt(received, QStringLiteral("down"));
      return down >= 0 && touchAt(received, QStringLiteral("up")) > down;
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("the emulator receives the text %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return fakeHub(world).text.contains(QJsonObject{{QStringLiteral("type"), QStringLiteral("text")}, {QStringLiteral("text"), c[0]}});
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("the emulator receives the %1 button").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fakeHub(world).text.contains(QJsonObject{{QStringLiteral("type"), c[0]}}); },
                  [&] { return describeInput(world); });
  });
  step(QStringLiteral("the user rotates the device"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("deviceRotate"));
  });
  step(QStringLiteral("the device is asked to turn to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return iosInput(world, 0x07) == QList<QJsonObject>{{{QStringLiteral("orientation"), c[0]}}}; },
                  [&] { return describeInput(world); });
  });
  step(QStringLiteral("the device reports it is held %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // serve-sim's framebuffer stays portrait as the device turns.
    const QByteArray config = QByteArray(1, char(0x82)) +
                              QJsonDocument(QJsonObject{{QStringLiteral("width"), 1179}, {QStringLiteral("height"), 2556}, {QStringLiteral("orientation"), c[0]}})
                                  .toJson(QJsonDocument::Compact);
    for (const QPointer<QWebSocket>& socket : std::as_const(fakeHub(world).inputs)) {
      if (socket) socket->sendBinaryMessage(config);
    }
  });
  step(QStringLiteral("the screen is shown sideways and wider than tall"), [](World& world, const Captures&, const Table&) {
    QQuickItem* screen = screenItem(world);
    const auto shown = [&] { return screen->mapRectToScene(screen->boundingRect()); };
    world.waitFor([&] { return screen->rotation() == 90 && shown().width() > shown().height(); }, [&] {
      return QStringLiteral("the stream is %1; the screen is turned %2 and drawn %3x%4")
          .arg(deviceStream(world).orientation())
          .arg(screen->rotation())
          .arg(shown().width())
          .arg(shown().height());
    });
    expect(red(drawnAtScreen(world)), describeScreen(world));
  });
  step(QStringLiteral("the device receives the touch where it lands on its own portrait screen"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QJsonObject> touches = iosInput(world, 0x03);
      return touches.size() == 2 && near(touches[0].value(QLatin1String("x")).toDouble(), 0.5) && near(touches[0].value(QLatin1String("y")).toDouble(), 0.75);
    }, [&] { return describeInput(world); });
  });

  // Closing.
  step(QStringLiteral("the thread still has %1 open").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeHub& hub = fakeHub(world);
    expect(hub.closes.isEmpty() && sessionOf(hub, deviceNamed(hub, c[0]).value(QLatin1String("id")).toString()) >= 0, describe(world));
  });
  step(QStringLiteral("the user powers the device off"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("devicePowerOff"));
  });
  step(QStringLiteral("the MC is asked to close %1 and shut it down").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = deviceNamed(fakeHub(world), c[0]).value(QLatin1String("id")).toString();
    world.waitFor([&] {
      const QList<QJsonObject> closes = fakeHub(world).closes;
      return closes.size() == 1 && closes[0].value(QLatin1String("deviceId")) == id && closes[0].value(QLatin1String("threadId")) == kThread &&
             closes[0].value(QLatin1String("shutdown")).toBool();
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the MC is slow to close devices"), [](World& world, const Captures&, const Table&) {
    fakeHub(world);
    world.mc.hold(QStringLiteral("device.close"));
  });
  step(QStringLiteral("before the MC answers, the user switches to another thread showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(world.mc.holding(QStringLiteral("device.close")) && fakeHub(world).closes.isEmpty(), describe(world));
    const QString other = QStringLiteral("thread-2");
    world.mc.threads.insert(other, {{QStringLiteral("id"), other}, {QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("projectId"), kProject},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(other, world.mc.threads.value(other));
    world.sync();
    stream::look(world, world.mc.environmentId + QLatin1Char(':') + other);
    world.sync();
    // An agent opened the same device there: that thread has its own tab for it.
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]), other);
    announce(world.mc);
    world.sync();
    world.waitFor([&] { return activeTab(world) == tabOf(world, c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user goes back to the first thread"), [](World& world, const Captures&, const Table&) {
    stream::look(world, world.mc.environmentId + QLatin1Char(':') + kThread);
    world.sync();
  });
  step(QStringLiteral("the right panel has no %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    world.waitFor([&] { return !tabTitles(world).contains(c[0]); }, [&] { return describe(world); });
  });

  // An agent's devices.
  step(QStringLiteral("an agent (?:opens|opened) %1 in the thread").arg(q), [](World& world, const Captures& c, const Table&) {
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    announce(world.mc);
    world.sync();
    world.waitFor([&] { return activeTab(world) == tabOf(world, c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the agent closes %1 and opens it again").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeHub& hub = fakeHub(world);
    const QJsonObject device = deviceNamed(hub, c[0]);
    hub.sessions.removeAt(sessionOf(hub, device.value(QLatin1String("id")).toString()));
    announce(world.mc);
    world.sync();
    openSession(world.mc, device);
    announce(world.mc);
    world.sync();
  });
  step(QStringLiteral("the right panel shows the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return activeTab(world) == tabOf(world, c[0]) && tabTitles(world).contains(c[0]) && panel(world).isOpen(); },
                  [&] { return describe(world); });
  });
});

}  // namespace
