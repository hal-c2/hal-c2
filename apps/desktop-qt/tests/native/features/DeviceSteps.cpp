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
#include "DevicePanelSteps.h"
#include "DeviceStream.h"
#include "DeviceTools.h"
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
  // The local host's own status and detail, when they differ from the whole.
  QString localStatus;
  QString bannerDetail;
  QString hostLabel = QStringLiteral("This Mac");
  QString hostDetail;
  // A second machine offering devices, when the scenario has one.
  QString secondHostId;
  QString secondLabel;
  bool onboarding = true;
  bool agentAccess = false;
  bool agentInstalled = true;
  bool supportsRetry = false;
  // Platform availability by platform, when a scenario sets it.
  QHash<QString, QJsonObject> availability;
  QJsonArray booting;
  int revision = 0;
  // Why the MC fails `device.open`, when it does.
  QString refuseOpen;
  QString refuseClose;
  QList<QJsonObject> closes;
  QList<QJsonObject> configures;
  QList<QJsonObject> lists;
  // The tools' device: its settings, foreground app, and what it was asked.
  QJsonObject settings{{QStringLiteral("appearance"), QStringLiteral("light")},
                       {QStringLiteral("textSize"), QStringLiteral("default")},
                       {QStringLiteral("liquidGlass"), QStringLiteral("clear")},
                       {QStringLiteral("colorFilter"), QStringLiteral("none")},
                       {QStringLiteral("reduceMotion"), false},
                       {QStringLiteral("increaseContrast"), false},
                       {QStringLiteral("reduceTransparency"), false},
                       {QStringLiteral("showBorders"), false},
                       {QStringLiteral("voiceOver"), false},
                       {QStringLiteral("networkEnabled"), true}};
  QJsonValue foregroundApp = QJsonValue::Null;
  QList<QJsonObject> actions;
  QString refuseAction;
  // The stream's access expired: only a fresh ticket is let through.
  bool expired = false;
  int ticketRequests = 0;
  // The one ticket an expired stream may use: the latest given out.
  QString acceptedTicket;
  // Ticket requests kept unanswered, while holdTickets.
  bool holdTickets = false;
  QList<QPair<QPointer<QTcpSocket>, QString>> heldTickets;
  // The accessibility requests served, and whether they get an answer.
  int axRequests = 0;
  bool stallAx = false;
  QJsonObject androidAx;
  // Input sockets are closed as soon as they connect.
  bool dropInputs = false;
  // The accessibility tree the hub answers, and its event feeds.
  QJsonArray axTree;
  QList<QPair<QString, QPointer<QTcpSocket>>> feeds;
  int feedRequests = 0;
  int eventFeedRequests = 0;
  // What the tools steps typed last, and where they mean to place the device.
  QString lastField;
  QPair<double, double> wantedLocation{0, 0};
  double draggedYaw = 0;
  // The devices shape is not answered yet.
  bool holdState = false;
  // No hub base path: the client was given no device access.
  bool noAccess = false;
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

void answerTicket(FakeHub& hub, QTcpSocket* socket, const QString& ticket) {
  hub.acceptedTicket = ticket;
  const QByteArray json = QJsonDocument(QJsonObject{{QStringLiteral("ticket"), ticket}}).toJson(QJsonDocument::Compact);
  socket->write(QStringLiteral("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %1\r\nConnection: close\r\n\r\n").arg(json.size()).toUtf8() + json);
  socket->disconnectFromHost();
}

QJsonObject stateOf(FakeMc& mc) {
  FakeHub& hub = mc.part<FakeHub>();
  const auto availability = [&hub](const QString& platform) {
    if (hub.availability.contains(platform)) return hub.availability.value(platform);
    return QJsonObject{{QStringLiteral("platform"), platform}, {QStringLiteral("available"), true}};
  };
  const QJsonArray platforms{availability(QStringLiteral("ios")), availability(QStringLiteral("android"))};
  const auto host = [&hub, &platforms](const QString& id, const QString& kind, const QString& label) {
    return QJsonObject{{QStringLiteral("id"), id},
                       {QStringLiteral("kind"), kind},
                       {QStringLiteral("label"), label},
                       {QStringLiteral("platforms"), platforms},
                       {QStringLiteral("hubInstalled"), true},
                       {QStringLiteral("agentDeviceInstalled"), hub.agentInstalled}};
  };
  QJsonArray hosts{host(kHost, QStringLiteral("local"), hub.hostLabel)};
  const QString local = hub.localStatus.isEmpty() ? hub.hostStatus : hub.localStatus;
  QJsonObject localStatus{{QStringLiteral("status"), local}};
  if (!hub.bannerDetail.isEmpty()) localStatus.insert(QStringLiteral("detail"), hub.bannerDetail);
  QJsonObject statuses{{kHost, localStatus}};
  if (!hub.secondHostId.isEmpty()) {
    hosts.append(host(hub.secondHostId, QStringLiteral("ssh"), hub.secondLabel));
    statuses.insert(hub.secondHostId, QJsonObject{{QStringLiteral("status"), QStringLiteral("ready")}});
  }
  QJsonObject state{{QStringLiteral("hosts"), hosts},
                    {QStringLiteral("hostStatus"), hub.hostStatus},
                    {QStringLiteral("hostStatuses"), statuses},
                    {QStringLiteral("devices"), hub.devices},
                    {QStringLiteral("sessions"), hub.sessions},
                    {QStringLiteral("bootingDevices"), hub.booting},
                    {QStringLiteral("onboardingCompleted"), hub.onboarding},
                    {QStringLiteral("agentAccessEnabled"), hub.agentAccess},
                    {QStringLiteral("supportsHostRetry"), hub.supportsRetry},
                    {QStringLiteral("hubBasePath"),
                     hub.noAccess ? QString() : QStringLiteral("/api/device-hub/mcs/") + QString::fromLatin1(QUrl::toPercentEncoding(mc.name))},
                    {QStringLiteral("revision"), hub.revision}};
  if (!hub.hostDetail.isEmpty()) state.insert(QStringLiteral("hostStatusDetail"), hub.hostDetail);
  return state;
}

// The MC tells every watcher, as devices.ex does on each change.
void announce(FakeMc& mc) {
  ++mc.part<FakeHub>().revision;
  for (const int id : mc.subscribers(QStringLiteral("devices")))
    mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), stateOf(mc)}});
}

int sessionOf(const FakeHub& hub, const QString& deviceId, const QString& thread = kThread, const QString& host = {}) {
  for (qsizetype n = 0; n < hub.sessions.size(); ++n) {
    const QJsonObject session = hub.sessions.at(n).toObject();
    if (session.value(QLatin1String("threadId")) == thread && session.value(QLatin1String("deviceId")) == deviceId &&
        (host.isEmpty() || session.value(QLatin1String("hostId")) == host))
      return int(n);
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
  if (sessionOf(hub, device.value(QLatin1String("id")).toString(), thread, device.value(QLatin1String("hostId")).toString(kHost)) < 0)
    hub.sessions.append(QJsonObject{{QStringLiteral("threadId"), thread},
                                    {QStringLiteral("hostId"), device.value(QLatin1String("hostId")).toString(kHost)},
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
      if (hub.dropInputs) {
        socket->close(QWebSocketProtocol::CloseCodeNormal, QStringLiteral("socket closed"));
        continue;
      }
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
    if (mc.part<FakeHub>().holdState) return;
    mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), stateOf(mc)}});
  });
  mc.onRpc(QStringLiteral("device.list"), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeHub>().lists.append(rpc.payload);
    const auto answer = [&mc, rpc] { mc.reply(rpc, stateOf(mc)); };
    if (mc.holding(QStringLiteral("device.list"))) return mc.defer(answer);
    answer();
  });
  mc.onRpc(QStringLiteral("device.configure"), [&mc](const FakeMc::Rpc& rpc) {
    const auto answer = [&mc, rpc] {
      FakeHub& hub = mc.part<FakeHub>();
      hub.configures.append(rpc.payload);
      if (rpc.payload.contains(QLatin1String("enabled"))) {
        if (rpc.payload.value(QLatin1String("enabled")).toBool()) {
          if (hub.hostStatus == QLatin1String("disabled")) hub.hostStatus = QStringLiteral("installing");
        } else {
          hub.hostStatus = QStringLiteral("disabled");
        }
      }
      if (rpc.payload.contains(QLatin1String("agentAccessEnabled"))) hub.agentAccess = rpc.payload.value(QLatin1String("agentAccessEnabled")).toBool();
      if (rpc.payload.contains(QLatin1String("onboardingCompleted"))) hub.onboarding = rpc.payload.value(QLatin1String("onboardingCompleted")).toBool();
      announce(mc);
      mc.reply(rpc, stateOf(mc));
    };
    if (mc.holding(QStringLiteral("device.configure"))) return mc.defer(answer);
    answer();
  });
  mc.onRpc(QStringLiteral("device.detail"), [&mc](const FakeMc::Rpc& rpc) {
    const auto answer = [&mc, rpc] {
      FakeHub& hub = mc.part<FakeHub>();
      mc.reply(rpc, QJsonObject{{QStringLiteral("hostId"), rpc.payload.value(QLatin1String("hostId")).toString(kHost)},
                                {QStringLiteral("deviceId"), rpc.payload.value(QLatin1String("deviceId"))},
                                {QStringLiteral("settings"), hub.settings},
                                {QStringLiteral("foregroundApp"), hub.foregroundApp},
                                {QStringLiteral("readAt"), QStringLiteral("2026-09-23T10:00:00Z")}});
    };
    if (mc.holding(QStringLiteral("device.detail"))) return mc.defer(answer);
    answer();
  });
  mc.onRpc(QStringLiteral("device.action"), [&mc](const FakeMc::Rpc& rpc) {
    const auto answer = [&mc, rpc] {
      FakeHub& hub = mc.part<FakeHub>();
      hub.actions.append(rpc.payload);
      if (!hub.refuseAction.isEmpty()) return mc.refuse(rpc, hub.refuseAction);
      const QString type = rpc.payload.value(QLatin1String("type")).toString();
      if (type == QLatin1String("setAppearance")) hub.settings.insert(QStringLiteral("appearance"), rpc.payload.value(QLatin1String("value")));
      if (type == QLatin1String("setTextSize")) hub.settings.insert(QStringLiteral("textSize"), rpc.payload.value(QLatin1String("value")));
      if (type == QLatin1String("setLiquidGlass")) hub.settings.insert(QStringLiteral("liquidGlass"), rpc.payload.value(QLatin1String("value")));
      if (type == QLatin1String("setColorFilter")) hub.settings.insert(QStringLiteral("colorFilter"), rpc.payload.value(QLatin1String("value")));
      if (type == QLatin1String("setToggle")) hub.settings.insert(rpc.payload.value(QLatin1String("setting")).toString(), rpc.payload.value(QLatin1String("value")));
      if (type == QLatin1String("setLocation"))
        hub.settings.insert(QStringLiteral("location"), QJsonObject{{QStringLiteral("latitude"), rpc.payload.value(QLatin1String("latitude"))},
                                                                    {QStringLiteral("longitude"), rpc.payload.value(QLatin1String("longitude"))}});
      if (type == QLatin1String("clearLocation")) hub.settings.insert(QStringLiteral("location"), QJsonValue::Null);
      if (type == QLatin1String("terminateApp")) hub.foregroundApp = QJsonValue::Null;
      if (type == QLatin1String("launchApp"))
        hub.foregroundApp = QJsonObject{{QStringLiteral("id"), rpc.payload.value(QLatin1String("appId"))}};
      mc.reply(rpc, QJsonObject{{QStringLiteral("hostId"), rpc.payload.value(QLatin1String("hostId")).toString(kHost)},
                                {QStringLiteral("deviceId"), rpc.payload.value(QLatin1String("deviceId"))},
                                {QStringLiteral("settings"), hub.settings},
                                {QStringLiteral("foregroundApp"), hub.foregroundApp},
                                {QStringLiteral("readAt"), QStringLiteral("2026-09-23T10:00:00Z")}});
    };
    if (mc.holding(QStringLiteral("device.action"))) return mc.defer(answer);
    answer();
  });
  // Raw, like the connection-health fake's: FakeMc answers HTTP POSTs
  // through its raw handlers first.
  mc.onRaw(QStringLiteral("/api/auth/websocket-ticket"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    FakeHub& hub = mc.part<FakeHub>();
    const QString ticket = QStringLiteral("fresh%1").arg(++hub.ticketRequests);
    socket->read(head.size());
    if (hub.holdTickets) {
      hub.heldTickets.append({socket, ticket});
      return;
    }
    answerTicket(hub, socket, ticket);
  });
  mc.onRpc(QStringLiteral("device.open"), [&mc](const FakeMc::Rpc& rpc) {
    const auto answer = [&mc, rpc] {
      FakeHub& hub = mc.part<FakeHub>();
      if (!hub.refuseOpen.isEmpty()) return mc.refuse(rpc, hub.refuseOpen);
      QJsonObject device;
      for (const QJsonValue& listed : std::as_const(hub.devices)) {
        const QJsonObject candidate = listed.toObject();
        if (candidate.value(QLatin1String("id")) == rpc.payload.value(QLatin1String("deviceId")) &&
            (!rpc.payload.contains(QLatin1String("hostId")) || candidate.value(QLatin1String("hostId")) == rpc.payload.value(QLatin1String("hostId"))))
          device = candidate;
      }
      if (device.isEmpty()) return mc.refuse(rpc, QStringLiteral("Device not found"));
      const QString thread = rpc.payload.value(QLatin1String("threadId")).toString();
      openSession(mc, device, thread);
      announce(mc);
      mc.reply(rpc, hub.sessions.at(sessionOf(hub, device.value(QLatin1String("id")).toString(), thread, device.value(QLatin1String("hostId")).toString(kHost))));
    };
    if (mc.holding(QStringLiteral("device.open"))) return mc.defer(answer);
    answer();
  });
  mc.onRpc(QStringLiteral("device.close"), [&mc](const FakeMc::Rpc& rpc) {
    const auto close = [&mc, rpc] {
      FakeHub& hub = mc.part<FakeHub>();
      if (!hub.refuseClose.isEmpty()) return mc.refuse(rpc, hub.refuseClose);
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
    if (hub.expired && (hub.acceptedTicket.isEmpty() || !target.contains(QStringLiteral("wsTicket=") + hub.acceptedTicket))) {
      socket->read(head.size());
      return respond(socket, 401);
    }
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
    // The tools' read-only feeds: server-sent events, held open.
    if (path.endsWith(QLatin1String("/appstate")) || path.endsWith(QLatin1String("/api/event-log/events"))) {
      socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n");
      hub.feeds.append({path, socket});
      ++hub.feedRequests;
      return;
    }
    if (path.endsWith(QLatin1String("/ax")) || path.endsWith(QLatin1String("/api/accessibility"))) {
      ++hub.axRequests;
      if (hub.stallAx) return;
      const QByteArray json = hub.androidAx.isEmpty() ? QJsonDocument(hub.axTree).toJson(QJsonDocument::Compact) : QJsonDocument(hub.androidAx).toJson(QJsonDocument::Compact);
      socket->write(QStringLiteral("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %1\r\nConnection: close\r\n\r\n").arg(json.size()).toUtf8() + json);
      socket->disconnectFromHost();
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

void addDevice(World& world, const QString& platform, const QString& name, bool booted, const QString& host = kHost, const QString& wantedId = {}) {
  const QString id = !wantedId.isEmpty() ? wantedId
                     : platform == QLatin1String("ios")
                         ? QStringLiteral("UDID-") + QString(name).replace(QLatin1Char(' '), QLatin1Char('-')).toUpper() + (host == kHost ? QString() : QLatin1Char('-') + host.toUpper())
                         : QStringLiteral("emulator-5554");
  fakeHub(world).devices.append(QJsonObject{{QStringLiteral("hostId"), host},
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
  const QJsonObject device = deviceNamed(fakeHub(world), name);
  return ThreadDevices::tabIdOf(device.value(QLatin1String("hostId")).toString(kHost), device.value(QLatin1String("id")).toString());
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
  const QString row = QStringLiteral("deviceRow-") + rowOf(world, name).value(QStringLiteral("tab")).toString();
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
  // An announcement in flight may not have added the tab yet.
  world.waitFor([&] { return tabTitles(world).contains(name) || !rowOf(world, name).isEmpty(); }, [&] { return describe(world); });
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

DeviceTools& tools(World& world) {
  return *devices(world).tools();
}

QVariantMap toolsView(World& world) {
  return tools(world).view();
}

QVariantMap wizardViewOf(World& world) {
  return view(world).value(QStringLiteral("wizard")).toMap();
}

// The hub's state changes and every watcher is told, as devices.ex does.
void setHubStatus(World& world, const QString& status) {
  fakeHub(world).hostStatus = status;
  announce(world.mc);
  world.sync();
}

// The words the Device tab shows anywhere: its view's notes.
QStringList tabWords(World& world) {
  const QVariantMap shown = view(world);
  QStringList words;
  for (const QString& field : {QStringLiteral("loading"), QStringLiteral("empty"), QStringLiteral("error"),
                               QStringLiteral("hostDetail"), QStringLiteral("starting")}) {
    const QString value = shown.value(field).toString();
    if (!value.isEmpty()) words.append(value);
  }
  for (const QVariant& banner : shown.value(QStringLiteral("banners")).toList()) {
    words.append(at(banner, QStringLiteral("message")).toString());
    words.append(at(banner, QStringLiteral("advice")).toString());
  }
  const QVariantMap wizard = wizardViewOf(world);
  words.append(wizard.value(QStringLiteral("hubStatus")).toString());
  words.append(wizard.value(QStringLiteral("agentStatus")).toString());
  words.append(wizard.value(QStringLiteral("error")).toString());
  return words;
}

bool tabSays(World& world, const QString& words) {
  return tabWords(world).contains(words) || devicePanel(world).shows(words);
}

// The drawer is open; wait for its settings to have landed.
void openToolsReady(World& world) {
  world.waitFor([&] { return toolsView(world).value(QStringLiteral("open")).toBool() && toolsView(world).value(QStringLiteral("loaded")).toBool(); },
                [&] { return describe(world) + QStringLiteral("; the tools are %1").arg(show(toolsView(world))); });
}

// Opens the Tools drawer for the device shown and waits for its settings.
void openTools(World& world) {
  if (!toolsView(world).value(QStringLiteral("open")).toBool()) devicePanel(world).click(QStringLiteral("deviceTools"));
  world.waitFor([&] { return toolsView(world).value(QStringLiteral("open")).toBool() && toolsView(world).value(QStringLiteral("loaded")).toBool(); },
                [&] { return describe(world) + QStringLiteral("; the tools are %1").arg(show(toolsView(world))); });
}

// Types into a tools field the way a user does: click it, then keys.
void typeInto(World& world, const QString& objectName, const QString& text) {
  Brick& panel = devicePanel(world);
  panel.click(objectName);
  world.sync();
  for (const QChar ch : text) QTest::keyClick(&panel.window(), ch.toLatin1());
  world.sync();
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
      const DeviceStream& stream = deviceStream(world);
      return tabSays(world, c[0]) || (stream.status() == QLatin1String("error") && stream.detail() == c[0]);
    }, [&] { return tabWords(world).join(QStringLiteral(" | ")) + QLatin1Char('\n') + describe(world); });
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
    // The setup wizard sits in front of the tab; putting it away leaves the
    // tab's own pointer to the settings.
    if (view(world).value(QStringLiteral("wizard")).isValid()) devicePanel(world).click(QStringLiteral("wizardCancel"));
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

// The backlog steps: renaming and floating, the picker's ordering and
// messages, the stream's recovery, the setup wizard and its banners, and
// the Tools drawer.
struct PanelBrickPart {
  std::unique_ptr<Brick> brick;
};

Brick& panelBrick(World& world) {
  PanelBrickPart& part = world.mc.part<PanelBrickPart>();
  if (!part.brick) part.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nRightPanel {}\n", QSize(900, 600));
  return *part.brick;
}

const Steps backlogSteps([] {
  const QString q = kQuoted;

  // --- Tab names -----------------------------------------------------------
  step(QStringLiteral("the thread has %1 open in a tab").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    look(world);
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), tabOf(world, c[0])}});
    world.sync();
    world.waitFor([&] { return tabTitles(world).contains(c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user renames the tab to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = panelBrick(world);
    const QString tab = tabOf(world, QStringLiteral("iPhone 17"));
    QQuickItem* item = brick.item(QStringLiteral("panelTab-") + tab);
    QTest::mouseDClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item, 0.4, 0.5));
    world.waitFor([&] { return brick.item(QStringLiteral("panelRename-") + tab)->isVisible(); }, [&] { return describe(world); });
    for (const QChar ch : c[0]) QTest::keyClick(&brick.window(), ch.toLatin1());
    QTest::keyClick(&brick.window(), Qt::Key_Return);
    world.sync();
  });
  step(QStringLiteral("the tab is named %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return tabTitles(world).contains(c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the tab keeps that name when the device list is read again"), [](World& world, const Captures&, const Table&) {
    const QStringList before = tabTitles(world);
    announce(world.mc);
    world.sync();
    devices(world).refresh();
    world.sync();
    expect(tabTitles(world) == before, describe(world));
  });
  step(QStringLiteral("the user is renaming the tab %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    look(world);
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), tabOf(world, c[0])}});
    world.sync();
    Brick& brick = panelBrick(world);
    const QString tab = tabOf(world, c[0]);
    QQuickItem* item = brick.item(QStringLiteral("panelTab-") + tab);
    QTest::mouseDClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item, 0.4, 0.5));
    world.waitFor([&] { return brick.item(QStringLiteral("panelRename-") + tab)->isVisible(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user types %1 and presses Escape").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = panelBrick(world);
    for (const QChar ch : c[0]) QTest::keyClick(&brick.window(), ch.toLatin1());
    QTest::keyClick(&brick.window(), Qt::Key_Escape);
    world.sync();
  });
  step(QStringLiteral("the tab is still named %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(tabTitles(world).contains(c[0]) && !tabTitles(world).contains(QStringLiteral("Checkout flow")), describe(world));
  });

  // --- Two machines, one device id -----------------------------------------
  step(QStringLiteral("two connected machines each offer a simulator with the same device id"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.secondHostId = QStringLiteral("remote");
    hub.secondLabel = QStringLiteral("laptop");
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true, kHost, QStringLiteral("UDID-SHARED"));
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true, QStringLiteral("remote"), QStringLiteral("UDID-SHARED"));
  });
  step(QStringLiteral("the user opens both"), [](World& world, const Captures&, const Table&) {
    addDeviceTab(world);
    for (const QString& host : {QString(kHost), QStringLiteral("remote")}) {
      if (activeTab(world) != QLatin1String("device")) addDeviceTab(world);
      QVariantMap row;
      for (const QVariant& listed : view(world).value(QStringLiteral("groups")).toList())
        for (const QVariant& candidate : at(listed, QStringLiteral("devices")).toList())
          if (at(candidate, QStringLiteral("hostId")) == host) row = candidate.toMap();
      world.waitFor([&] { return !row.isEmpty(); }, [&] { return describe(world); });
      devicePanel(world).click(QStringLiteral("deviceRow-") + row.value(QStringLiteral("tab")).toString());
      world.sync();
      world.waitFor([&] { return activeTab(world) == ThreadDevices::tabIdOf(host, QStringLiteral("UDID-SHARED")); },
                    [&] { return describe(world); });
    }
  });
  step(QStringLiteral("each has its own tab"), [](World& world, const Captures&, const Table&) {
    const QVariantList tabs = at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList();
    QStringList ids;
    for (const QVariant& tab : tabs) ids.append(at(tab, QStringLiteral("id")).toString());
    expect(ids.contains(ThreadDevices::tabIdOf(kHost, QStringLiteral("UDID-SHARED"))) &&
               ids.contains(ThreadDevices::tabIdOf(QStringLiteral("remote"), QStringLiteral("UDID-SHARED"))),
           describe(world));
  });
  step(QStringLiteral("closing one leaves the other open"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.close"),
                            QVariantMap{{QStringLiteral("id"), ThreadDevices::tabIdOf(kHost, QStringLiteral("UDID-SHARED"))}});
    world.sync();
    const QVariantList tabs = at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList();
    QStringList ids;
    for (const QVariant& tab : tabs) ids.append(at(tab, QStringLiteral("id")).toString());
    expect(!ids.contains(ThreadDevices::tabIdOf(kHost, QStringLiteral("UDID-SHARED"))) &&
               ids.contains(ThreadDevices::tabIdOf(QStringLiteral("remote"), QStringLiteral("UDID-SHARED"))),
           describe(world));
  });

  // --- The picker's order and words ----------------------------------------
  step(QStringLiteral("the thread's environment has the iOS Simulators %1 stopped and %1 running").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addDevice(world, QStringLiteral("ios"), c[0], false);
         addDevice(world, QStringLiteral("ios"), c[1], true);
       });
  step(QStringLiteral("the thread's environment has the Android Emulators %1 and %1, both running").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addDevice(world, QStringLiteral("android"), c[0], true);
         addDevice(world, QStringLiteral("android"), c[1], true);
       });
  step(QStringLiteral("the thread's environment has the iOS Simulators %1 and %1 running").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addDevice(world, QStringLiteral("ios"), c[0], true);
         addDevice(world, QStringLiteral("ios"), c[1], true);
         // The open that follows stays in flight, so the picker can show
         // that only one device opens at a time.
         world.mc.hold(QStringLiteral("device.open"));
         addDeviceTab(world);
       });
  step(QStringLiteral("%1 is listed before %1 under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList names;
    for (const QVariant& listed : view(world).value(QStringLiteral("groups")).toList()) {
      if (at(listed, QStringLiteral("title")) != c[2]) continue;
      for (const QVariant& row : at(listed, QStringLiteral("devices")).toList()) names.append(at(row, QStringLiteral("name")).toString());
    }
    expect(names.indexOf(c[0]) >= 0 && names.indexOf(c[0]) < names.indexOf(c[1]),
           QStringLiteral("the order is %1").arg(names.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the machine %1 has the iOS Simulator %1 on iOS 26.0, (running|stopped)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         fakeHub(world).hostLabel = c[0];
         addDevice(world, QStringLiteral("ios"), c[1], c[2] == QLatin1String("running"));
       });
  step(QStringLiteral("the row for %1 reads \"([^\"]* · [^\"]*)\"").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rowOf(world, c[0]).value(QStringLiteral("detail")) == c[1]; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the row offers %1").arg(q), [](World& world, const Captures& c, const Table&) {
    bool offered = false;
    for (const QVariant& listed : view(world).value(QStringLiteral("groups")).toList())
      for (const QVariant& row : at(listed, QStringLiteral("devices")).toList())
        offered = offered || at(row, QStringLiteral("action")) == c[0];
    expect(offered, describe(world));
  });
  step(QStringLiteral("%1 cannot be chosen until %1 is open").arg(q), [](World& world, const Captures& c, const Table&) {
    // The first open is in flight (the Given held it); the other row must
    // be disabled while it is.
    expect(!view(world).value(QStringLiteral("pendingKey")).toString().isEmpty(), describe(world));
    const QVariantMap row = rowOf(world, c[0]);
    QQuickItem* item = devicePanel(world).item(QStringLiteral("deviceRow-") + row.value(QStringLiteral("tab")).toString());
    expect(!item->isEnabled(), describe(world));
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the Device tab says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return tabSays(world, c[0]); }, [&] { return tabWords(world).join(QStringLiteral(" | ")) + QLatin1Char('\n') + describe(world); });
  });
  step(QStringLiteral("the user opened %1, which is already running").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], true);
    world.mc.hold(QStringLiteral("device.open"));
    addDeviceTab(world);
    openFromPicker(world, c[0]);
  });
  step(QStringLiteral("the user opened %1, which is stopped").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], false);
    world.mc.hold(QStringLiteral("device.open"));
    addDeviceTab(world);
    openFromPicker(world, c[0]);
  });
  step(QStringLiteral("the device tools are still being installed"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).hostStatus = QStringLiteral("installing");
    addDeviceTab(world);
  });
  step(QStringLiteral("the device tools are being installed on the thread's environment"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).hostStatus = QStringLiteral("installing");
  });
  step(QStringLiteral("the list of devices has not arrived yet"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.holdState = true;
    hub.looking = true;
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
    lookAtThread(world, kProject);
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("device")}});
    world.sync();
  });
  step(QStringLiteral("the thread has %1 starting").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], false);
    FakeHub& hub = fakeHub(world);
    hub.booting.append(QJsonObject{{QStringLiteral("name"), c[0]}, {QStringLiteral("threadId"), kThread}});
    look(world);
  });
  step(QStringLiteral("%1 is running").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeHub& hub = fakeHub(world);
    for (qsizetype n = hub.booting.size() - 1; n >= 0; --n) {
      if (hub.booting.at(n).toObject().value(QLatin1String("name")) == c[0]) hub.booting.removeAt(n);
    }
    announce(world.mc);
    world.sync();
  });
  step(QStringLiteral("that message goes away"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return view(world).value(QStringLiteral("starting")).toString().isEmpty(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the device hub is installing on the thread's environment and reports %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         FakeHub& hub = fakeHub(world);
         hub.hostStatus = QStringLiteral("installing");
         hub.hostDetail = c[0];
       });
  step(QStringLiteral("the device hub failed to start on the thread's environment and says %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         FakeHub& hub = fakeHub(world);
         hub.hostStatus = QStringLiteral("failed");
         hub.hostDetail = c[0];
       });
  step(QStringLiteral("the device hub failed to start on the thread's environment without saying why"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).hostStatus = QStringLiteral("failed");
  });
  step(QStringLiteral("it has no simulators or emulators"), [](World& world, const Captures&, const Table&) { fakeHub(world); });
  step(QStringLiteral("the device hub is ready and reports %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).hostDetail = c[0];
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
  });
  step(QStringLiteral("the tab shows %1 above the list of devices").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return view(world).value(QStringLiteral("hostDetail")) == c[0] && devicePanel(world).shows(c[0]); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the thread's environment has the Android SDK"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).availability.insert(QStringLiteral("android"),
                                       QJsonObject{{QStringLiteral("platform"), QStringLiteral("android")}, {QStringLiteral("available"), true}});
  });
  step(QStringLiteral("it has no Android virtual devices"), [](World& world, const Captures&, const Table&) { fakeHub(world); });
  step(QStringLiteral("the user added a Device tab on an environment with no simulators"), [](World& world, const Captures&, const Table&) {
    fakeHub(world);
    addDeviceTab(world);
  });
  step(QStringLiteral("the machine gains the iOS Simulator %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], true);
  });
{}
  step(QStringLiteral("the tab does not offer \"Refresh devices\""), [](World& world, const Captures&, const Table&) {
    expect(!view(world).value(QStringLiteral("canRefresh")).toBool() && !devicePanel(world).item(QStringLiteral("deviceRefresh"))->isVisible(),
           describe(world));
  });
  step(QStringLiteral("device support is on and %1 was added since the list was last read").arg(q),
       [](World& world, const Captures& c, const Table&) {
         look(world);
         addDeviceTab(world);
         addDevice(world, QStringLiteral("ios"), c[0], true);
         world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("diff")}});
         world.sync();
       });
  step(QStringLiteral("the user shows the Device tab"), [](World& world, const Captures&, const Table&) {
    look(world);
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), QStringLiteral("device")}});
    world.sync();
  });
{}
  step(QStringLiteral("device support is off"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.hostStatus = QStringLiteral("disabled");
    announce(world.mc);
    world.sync();
  });
  step(QStringLiteral("nothing is installed or started on the environment"), [](World& world, const Captures&, const Table&) {
    const auto lists = fakeHub(world).lists.size();
    const auto configures = fakeHub(world).configures.size();
    world.sync();
    expect(fakeHub(world).configures.size() == configures && fakeHub(world).lists.size() == lists, describe(world));
  });
  step(QStringLiteral("the thread has %1 on iOS 26.0 open on the machine %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).hostLabel = c[1];
    addDevice(world, QStringLiteral("ios"), c[0], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    look(world);
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), tabOf(world, c[0])}});
    world.sync();
  });
  step(QStringLiteral("the tab's header reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return at(view(world).value(QStringLiteral("screen")), QStringLiteral("description")) == c[0] && devicePanel(world).shows(c[0]); },
                  [&] { return describe(world); });
  });

  // --- Watching ------------------------------------------------------------
  step(QStringLiteral("the thread has the iOS Simulator %1 opening").arg(q), [](World& world, const Captures& c, const Table&) {
    addDevice(world, QStringLiteral("ios"), c[0], true);
    fakeHub(world).silent = true;
    world.mc.hold(QStringLiteral("device.open"));
    addDeviceTab(world);
    openFromPicker(world, c[0]);
  });
  step(QStringLiteral("the tab shows its progress as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return devicePanel(world).shows(c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the device is open and no picture has arrived yet"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    world.sync();
    world.waitFor([&] { return deviceStream(world).status() == QLatin1String("connecting"); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the MC refuses the stream because its access has expired"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.expired = true;
    hub.acceptedTicket.clear();
    // The stream in flight ends; its next request is the refused one.
    for (const QPointer<QTcpSocket>& video : std::as_const(hub.videos)) {
      if (video) video->disconnectFromHost();
    }
    world.sync();
  });
  step(QStringLiteral("the tab asks the MC for fresh access"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fakeHub(world).ticketRequests > 0; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the tab asks the MC for fresh access again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fakeHub(world).ticketRequests > 1; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the MC is slow to give fresh access"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).holdTickets = true;
  });
  step(QStringLiteral("the user reconnects before the MC answers"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    world.waitFor([&] { return hub.ticketRequests == 1; }, [&] { return describe(world); });
    deviceStream(world).reconnect();
    // Refused again, the new connection asks for its own ticket.
    world.waitFor([&] { return hub.ticketRequests == 2; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the MC answers the earlier request"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    const auto first = hub.heldTickets.takeFirst();
    answerTicket(hub, first.first, first.second);
    expect(QTest::qWaitFor([&] { return !first.first || first.first->state() == QAbstractSocket::UnconnectedState; }, 5000), QStringLiteral("the answer was not delivered"));
    // That the tab ignores it takes a moment to show.
    QTest::qWait(200);
  });
  step(QStringLiteral("the tab does not use that answer"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    for (const QString& request : std::as_const(hub.requests)) {
      expect(!request.contains(QLatin1String("wsTicket=fresh1")), request);
    }
    expect(deviceStream(world).status() == QLatin1String("connecting"), describe(world));
  });
  step(QStringLiteral("the MC answers the later request"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.holdTickets = false;
    const auto last = hub.heldTickets.takeFirst();
    answerTicket(hub, last.first, last.second);
  });
  step(QStringLiteral("the tab %1 shows the device's screen again").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForScreen(world, c[0]);
  });
  step(QStringLiteral("the device's input connection drops with the reason %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.dropInputs = true;
    for (const QPointer<QWebSocket>& socket : std::as_const(hub.inputs)) {
      if (socket) socket->close(QWebSocketProtocol::CloseCodeNormal, c[0]);
    }
    world.sync();
    world.waitFor([&] { return !deviceStream(world).inputConnected(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the picture stays and the tab says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* screen = screenItem(world);
    world.waitFor([&] { return devicePanel(world).shows(c[0]) && screen->property("hasFrame").toBool() && screen->isVisible(); },
                  [&] { return describeScreen(world); });
    expect(red(drawnAtScreen(world)), describeScreen(world));
  });
  step(QStringLiteral("the device's buttons cannot be used"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("deviceHome"))->isEnabled(), describe(world));
  });
  step(QStringLiteral("the input connection returns"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).dropInputs = false;
    world.waitFor([&] { return deviceStream(world).inputConnected(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the message goes away and the buttons work again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return !devicePanel(world).item(QStringLiteral("deviceInputStatus"))->isVisible() &&
             devicePanel(world).item(QStringLiteral("deviceHome"))->isEnabled();
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user makes the panel narrower than the device is wide"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).window().resize(220, 900);
    devicePanel(world).root()->setSize(QSizeF(220, 900));
    world.sync();
  });
  step(QStringLiteral("the device is shown smaller with its own proportions"), [](World& world, const Captures&, const Table&) {
    QQuickItem* screen = screenItem(world);
    world.waitFor([&] {
      const double aspect = deviceStream(world).aspect();
      return screen->width() > 0 && std::abs(screen->width() / screen->height() - aspect) < 0.02 && screen->width() <= 224;
    }, [&] { return describeScreen(world); });
    expect(red(drawnAtScreen(world)), describeScreen(world));
  });
  step(QStringLiteral("a touch at the middle of the shown screen is sent as the middle of the device"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).binary.clear();
    tap(world, 0.5, 0.5);
    world.waitFor([&] {
      const QList<QJsonObject> touches = iosInput(world, 0x03);
      return touches.size() == 2 && near(touches[0].value(QLatin1String("x")).toDouble(), 0.5) &&
             near(touches[0].value(QLatin1String("y")).toDouble(), 0.5);
    }, [&] { return describeInput(world); });
  });

  // --- Driving -------------------------------------------------------------
  step(QStringLiteral("the tab offers (.+)"), [](World& world, const Captures& c, const Table&) {
    // The Given opened the device; showing its tab is what offers buttons.
    FakeHub& hub = fakeHub(world);
    const QJsonObject session = hub.sessions.isEmpty() ? QJsonObject() : hub.sessions.last().toObject();
    QString name;
    for (const QJsonValue& device : std::as_const(hub.devices)) {
      if (device.toObject().value(QLatin1String("id")) == session.value(QLatin1String("deviceId")))
        name = device.toObject().value(QLatin1String("name")).toString();
    }
    showDeviceTab(world, name);
    Brick& panel = devicePanel(world);
    const QHash<QString, QString> buttons{{QStringLiteral("Home"), QStringLiteral("deviceHome")},
                                          {QStringLiteral("Back"), QStringLiteral("deviceBack")},
                                          {QStringLiteral("Recents"), QStringLiteral("deviceRecents")},
                                          {QStringLiteral("Rotate"), QStringLiteral("deviceRotate")}};
    const QStringList wanted = c[0].split(QStringLiteral(", "));
    QStringList flat;
    for (const QString& part : wanted) flat += part.split(QStringLiteral(" and "));
    for (auto it = buttons.begin(); it != buttons.end(); ++it) {
      QQuickItem* item = panel.item(it.value());
      expect(item->isVisible() == flat.contains(it.key()),
             QStringLiteral("%1 offered: %2, wanted among %3").arg(it.key()).arg(item->isVisible()).arg(flat.join(QStringLiteral(", "))));
    }
  });
  step(QStringLiteral("the user types %1 in the tab's tools instead of on the screen").arg(q),
       [](World& world, const Captures& c, const Table&) {
         fakeHub(world).settings = {{QStringLiteral("appearance"), QStringLiteral("light")}};
         // Wide enough that the tools sit beside the screen, not over it.
         devicePanel(world).window().resize(900, 900);
         devicePanel(world).root()->setSize(QSizeF(900, 900));
         openTools(world);
         fakeHub(world).binary.clear();
         typeInto(world, QStringLiteral("toolsField-url"), c[0]);
       });
  step(QStringLiteral("the device receives no key"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(iosInput(world, 0x06).isEmpty() && fakeHub(world).text.isEmpty(), describeInput(world));
  });
  step(QStringLiteral("the user clicks the device's screen and types %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).binary.clear();
    tap(world, 0.5, 0.5);
    fakeHub(world).binary.clear();
    press(world, Qt::Key_unknown, c[0].at(0).toLatin1());
  });
  step(QStringLiteral("the user clicked the device's screen"), [](World& world, const Captures&, const Table&) {
    watch(world, QStringLiteral("iPhone 17"));
    tap(world, 0.5, 0.5);
    fakeHub(world).binary.clear();
  });
  step(QStringLiteral("the user presses Command with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& panel = devicePanel(world);
    const Qt::Key key = c[0] == QLatin1String("K") ? Qt::Key_K : Qt::Key_R;
    QTest::keyClick(&panel.window(), key, Qt::MetaModifier);
    world.sync();
  });
  step(QStringLiteral("the user holds Command with %1 and lets go of Command first").arg(q), [](World& world, const Captures&, const Table&) {
    Brick& panel = devicePanel(world);
    QTest::keyPress(&panel.window(), Qt::Key_R, Qt::MetaModifier);
    QTest::keyRelease(&panel.window(), Qt::Key_Meta, Qt::NoModifier);
    world.sync();
  });
  step(QStringLiteral("the device has both keys up"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      int downs = 0;
      for (const QJsonObject& key : iosInput(world, 0x06)) downs += key.value(QLatin1String("type")) == QLatin1String("down") ? 1 : -1;
      return !iosInput(world, 0x06).isEmpty() && downs == 0;
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("on a Mac the app keeps every Command chord but Command with \"R\""), [](World& world, const Captures&, const Table&) {
    QQuickItem* stage = devicePanel(world).item(QStringLiteral("deviceStage"));
    QVariant command;
    QMetaObject::invokeMethod(stage, "commandModifierOn", Q_RETURN_ARG(QVariant, command), Q_ARG(QVariant, QStringLiteral("osx")));
    expect(command.toInt() == int(Qt::ControlModifier), QStringLiteral("on a Mac Qt calls Command Control"));
    const auto appOwns = [&](int key, int modifiers) {
      QVariant owns;
      QMetaObject::invokeMethod(stage, "appOwns", Q_RETURN_ARG(QVariant, owns),
                                Q_ARG(QVariant, QVariantMap({{QStringLiteral("key"), key}, {QStringLiteral("modifiers"), modifiers}})), Q_ARG(QVariant, command));
      return owns.toBool();
    };
    expect(appOwns(Qt::Key_K, Qt::ControlModifier), QStringLiteral("Command+K went to the device"));
    expect(!appOwns(Qt::Key_R, Qt::ControlModifier), QStringLiteral("Command+R stayed with the app"));
    expect(appOwns(Qt::Key_R, Qt::MetaModifier), QStringLiteral("Control+R went to the device"));
    expect(!appOwns(Qt::Key_A, Qt::NoModifier), QStringLiteral("a plain key stayed with the app"));
  });
  step(QStringLiteral("the app handles the shortcut"), [](World& world, const Captures&, const Table&) {
    // The stage turns the key away: an event it is sent comes back unaccepted,
    // so the window's own shortcut handling sees it.
    QQuickItem* stage = devicePanel(world).item(QStringLiteral("deviceStage"));
    QKeyEvent event(QEvent::KeyPress, Qt::Key_K, Qt::MetaModifier, QStringLiteral("k"));
    QCoreApplication::sendEvent(stage, &event);
    expect(!event.isAccepted(), QStringLiteral("the stage took Command+K"));
  });
  step(QStringLiteral("the device receives the key %1 with Command").arg(q), [](World& world, const Captures& c, const Table&) {
    const int usage = 0x04 + (c[0].at(0).toLower().unicode() - 'a');
    world.waitFor([&] {
      const QList<QJsonObject> keys = iosInput(world, 0x06);
      bool metaDown = false, keyDown = false;
      for (const QJsonObject& key : keys) {
        if (key.value(QLatin1String("usage")).toInt() == 0xe3 && key.value(QLatin1String("type")) == QLatin1String("down")) metaDown = true;
        if (metaDown && key.value(QLatin1String("usage")).toInt() == usage && key.value(QLatin1String("type")) == QLatin1String("down")) keyDown = true;
      }
      return keyDown;
    }, [&] { return describeInput(world); });
  });

  // --- Closing -------------------------------------------------------------
  step(QStringLiteral("the MC cannot shut the device down because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).refuseClose = c[0];
  });
  step(QStringLiteral("the right panel still has the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return tabTitles(world).contains(c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user floats the device over the chat"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("deviceFloat"));
    world.sync();
  });
  step(QStringLiteral("the device floats over the conversation"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return at(world.state(QStringLiteral("panel")), QStringLiteral("floatingDevice")).toString() == tabOf(world, QStringLiteral("iPhone 17")) &&
             deviceStream(world).status() == QLatin1String("streaming");
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user opens the right panel"), [](World& world, const Captures&, const Table&) {
    panel(world).setOpen(true);
    world.sync();
  });
  step(QStringLiteral("the device no longer floats"), [](World& world, const Captures&, const Table&) {
    const QVariant floating = at(world.state(QStringLiteral("panel")), QStringLiteral("floatingDevice"));
    expect(floating.isNull() || floating.toString().isEmpty(), describe(world));
    expect(panel(world).isOpen(), describe(world));
  });
  step(QStringLiteral("the right panel closes"), [](World& world, const Captures&, const Table&) {
    expect(!panel(world).isOpen(), describe(world));
  });

  // --- The setup wizard ------------------------------------------------------
  const auto wizardAt = [](World& world, int step) {
    QQuickItem* wizard = devicePanel(world).item(QStringLiteral("deviceWizard"));
    wizard->setProperty("step", step);
    wizard->setProperty("furthest", step);
    world.sync();
  };
  const auto openWizard = [&wizardAt](World& world, int step = 0) {
    world.waitFor([&] { return view(world).value(QStringLiteral("wizard")).isValid(); }, [&] { return describe(world); });
    if (step > 0) wizardAt(world, step);
  };
  step(QStringLiteral("device support has never been set up on the thread's environment"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    hub.hostStatus = QStringLiteral("disabled");
  });
  step(QStringLiteral("a \"Set up devices\" wizard opens with the steps \"Device hub\", \"Simulators\" and \"Agent access\""),
       [](World& world, const Captures&, const Table&) {
         world.waitFor([&] {
           Brick& panel = devicePanel(world);
           return view(world).value(QStringLiteral("wizard")).isValid() && panel.item(QStringLiteral("deviceWizard"))->isVisible() &&
                  panel.shows(QStringLiteral("Set up devices")) && panel.shows(QStringLiteral("Device hub")) &&
                  panel.shows(QStringLiteral("Simulators")) && panel.shows(QStringLiteral("Agent access"));
         }, [&] { return describe(world); });
       });
{}  step(QStringLiteral("the user finished setting devices up"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = true;
  });
  step(QStringLiteral("later turned device support off"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).hostStatus = QStringLiteral("disabled");
  });
  step(QStringLiteral("the wizard opens at its first step"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return view(world).value(QStringLiteral("wizard")).isValid() &&
             devicePanel(world).item(QStringLiteral("deviceWizard"))->property("step").toInt() == 0 &&
             devicePanel(world).item(QStringLiteral("deviceWizard"))->isVisible();
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the wizard is at \"Device hub\" with the hub off"), [openWizard](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    hub.hostStatus = QStringLiteral("disabled");
    addDeviceTab(world);
    openWizard(world);
  });
  step(QStringLiteral("the wizard is at \"Device hub\" and the hub is off"), [openWizard](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    hub.hostStatus = QStringLiteral("disabled");
    addDeviceTab(world);
    openWizard(world);
  });
  step(QStringLiteral("the wizard is at \"Device hub\" with the hub ready"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world);
  });
  step(QStringLiteral("the wizard is at its first step"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world);
  });
  step(QStringLiteral("the wizard is at the \"Simulators\" step"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world, 1);
  });
  step(QStringLiteral("the user is at the \"Simulators\" step"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world, 1);
  });
  step(QStringLiteral("the user is at the \"Agent access\" step"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world, 2);
  });
  step(QStringLiteral("the user is at the \"Agent access\" step with the hub ready"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
    addDeviceTab(world);
    openWizard(world, 2);
  });
  step(QStringLiteral("the user turns on \"Enable device hub\""), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("wizardHubSwitch"));
    world.sync();
  });
  step(QStringLiteral("the user turned on \"Enable device hub\""), [openWizard](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    hub.hostStatus = QStringLiteral("disabled");
    addDeviceTab(world);
    openWizard(world);
    devicePanel(world).click(QStringLiteral("wizardHubSwitch"));
    world.sync();
  });
  step(QStringLiteral("the wizard says \"Installing device hub…\", then \"Starting device hub…\""), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return wizardViewOf(world).value(QStringLiteral("hubStatus")) == QStringLiteral("Installing device hub…"); },
                  [&] { return describe(world) + show(wizardViewOf(world)); });
    setHubStatus(world, QStringLiteral("starting"));
    world.waitFor([&] { return wizardViewOf(world).value(QStringLiteral("hubStatus")) == QStringLiteral("Starting device hub…"); },
                  [&] { return describe(world) + show(wizardViewOf(world)); });
    setHubStatus(world, QStringLiteral("ready"));
  });
  step(QStringLiteral("when the hub is up it says \"Device hub is ready.\""), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return wizardViewOf(world).value(QStringLiteral("hubStatus")) == QStringLiteral("Device hub is ready."); },
                  [&] { return describe(world) + show(wizardViewOf(world)); });
  });
  step(QStringLiteral("the user can continue to the next step"), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).item(QStringLiteral("wizardContinue"))->isEnabled(), describe(world));
  });
  step(QStringLiteral("the user cannot continue"), [](World& world, const Captures&, const Table&) {
    QQuickItem* next = devicePanel(world).item(QStringLiteral("wizardContinue"));
    QQuickItem* done = devicePanel(world).item(QStringLiteral("wizardDone"));
    expect(!next->isEnabled() && (!done->isVisible() || !done->isEnabled()), describe(world));
  });
  step(QStringLiteral("the hub is on and agents may control devices"), [openWizard](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    hub.agentAccess = true;
    addDeviceTab(world);
    openWizard(world);
  });
  step(QStringLiteral("the user turns off \"Enable device hub\" in the wizard"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("wizardHubSwitch"));
    world.sync();
  });
  step(QStringLiteral("agent access is off as well"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QJsonObject> configures = fakeHub(world).configures;
      return !configures.isEmpty() && configures.last().value(QLatin1String("enabled")) == false &&
             configures.last().value(QLatin1String("agentAccessEnabled")) == false && !wizardViewOf(world).value(QStringLiteral("agentOn")).toBool();
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the device hub is installing"), [openWizard](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    hub.hostStatus = QStringLiteral("installing");
    addDeviceTab(world);
    openWizard(world);
  });
  step(QStringLiteral("\"Enable device hub\" cannot be changed"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("wizardHubSwitch"))->isEnabled(), describe(world));
  });
  step(QStringLiteral("the user cannot go back or choose another step until it is done"), [](World& world, const Captures&, const Table&) {
    Brick& panel = devicePanel(world);
    expect(!panel.item(QStringLiteral("wizardStep-Simulators"))->isEnabled() && !panel.item(QStringLiteral("wizardBack"))->isEnabled(),
           describe(world));
  });
  step(QStringLiteral("the user chooses the step \"Agent access\" directly"), [](World& world, const Captures&, const Table&) {
    QQuickItem* step = devicePanel(world).item(QStringLiteral("wizardStep-Agent access"));
    expect(!step->isEnabled(), describe(world));
  });
  step(QStringLiteral("the wizard stays at \"Device hub\""), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).item(QStringLiteral("deviceWizard"))->property("step").toInt() == 0, describe(world));
  });
  step(QStringLiteral("the user continues twice and then chooses \"Device hub\""), [](World& world, const Captures&, const Table&) {
    Brick& panel = devicePanel(world);
    panel.click(QStringLiteral("wizardContinue"));
    panel.click(QStringLiteral("wizardContinue"));
    panel.click(QStringLiteral("wizardStep-Device hub"));
    world.sync();
  });
  step(QStringLiteral("the wizard returns to \"Device hub\""), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).item(QStringLiteral("deviceWizard"))->property("step").toInt() == 0, describe(world));
  });
  // The Simulators step's platform situations.
  const auto hubReadyWith = [](World& world, const std::function<void(FakeHub&)>& set) {
    FakeHub& hub = fakeHub(world);
    hub.onboarding = false;
    set(hub);
  };
  step(QStringLiteral("the hub is ready and iOS is not detected and the machine gives no reason"), [hubReadyWith](World& world, const Captures&, const Table&) {
    hubReadyWith(world, [](FakeHub& hub) {
      hub.availability.insert(QStringLiteral("ios"), QJsonObject{{QStringLiteral("platform"), QStringLiteral("ios")}, {QStringLiteral("available"), false}});
    });
  });
  step(QStringLiteral("the hub is ready and Android is not detected and the machine gives no reason"), [hubReadyWith](World& world, const Captures&, const Table&) {
    hubReadyWith(world, [](FakeHub& hub) {
      hub.availability.insert(QStringLiteral("android"),
                              QJsonObject{{QStringLiteral("platform"), QStringLiteral("android")}, {QStringLiteral("available"), false}});
    });
  });
  step(QStringLiteral("the hub is ready and iOS is unavailable because %1").arg(q), [hubReadyWith](World& world, const Captures& c, const Table&) {
    hubReadyWith(world, [&c](FakeHub& hub) {
      hub.availability.insert(QStringLiteral("ios"), QJsonObject{{QStringLiteral("platform"), QStringLiteral("ios")},
                                                                 {QStringLiteral("available"), false},
                                                                 {QStringLiteral("reason"), c[0]}});
    });
  });
  step(QStringLiteral("the hub is ready and Xcode is installed with no iOS Simulator runtime"), [hubReadyWith](World& world, const Captures&, const Table&) {
    hubReadyWith(world, [](FakeHub&) {});
  });
  step(QStringLiteral("the hub is ready and the Android SDK is installed with no virtual device"), [hubReadyWith](World& world, const Captures&, const Table&) {
    hubReadyWith(world, [](FakeHub&) {});
  });
  step(QStringLiteral("the hub is ready and Xcode has an iOS Simulator"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
  });
  step(QStringLiteral("the hub is ready and the Android SDK has an emulator"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDevice(world, QStringLiteral("android"), QStringLiteral("Pixel 9"), true);
  });
  step(QStringLiteral("the hub is ready and only Android has an emulator"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDevice(world, QStringLiteral("android"), QStringLiteral("Pixel 9"), true);
  });
  step(QStringLiteral("(iOS|Android) reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& platform : wizardViewOf(world).value(QStringLiteral("platforms")).toList()) {
        if (at(platform, QStringLiteral("platform")) == c[0]) return at(platform, QStringLiteral("message")) == c[1];
      }
      return false;
    }, [&] { return show(wizardViewOf(world)); });
  });
{}  step(QStringLiteral("the wizard says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return tabWords(world).contains(c[0]) || devicePanel(world).shows(c[0]); },
                  [&] { return tabWords(world).join(QStringLiteral(" | ")); });
  });
{}
  step(QStringLiteral("the user is at the \"Simulators\" step and iOS has no simulator runtime"), [openWizard](World& world, const Captures&, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world, 1);
  });
  step(QStringLiteral("the user installs a runtime and chooses \"Check again\""), [](World& world, const Captures&, const Table&) {
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
    world.mc.hold(QStringLiteral("device.list"));
    devicePanel(world).click(QStringLiteral("wizardCheckAgain"));
    world.sync();
  });
  step(QStringLiteral("the button says \"Checking…\" until the answer arrives"), [](World& world, const Captures&, const Table&) {
    expect(wizardViewOf(world).value(QStringLiteral("pending")) == QStringLiteral("check") &&
               devicePanel(world).item(QStringLiteral("wizardCheckAgain"))->property("text") == QStringLiteral("Checking…"),
           describe(world));
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the user turns on \"Allow agents to control devices\" and the hub is (installing agent tools|starting agent tools|updating|ready with agent tools)"),
       [](World& world, const Captures& c, const Table&) {
         // The switch is turned while the hub is ready; installing the
         // agent tools is what the hub then reports, held mid-answer.
         if (c[0] != QLatin1String("ready with agent tools")) world.mc.hold(QStringLiteral("device.configure"));
         devicePanel(world).click(QStringLiteral("wizardAgentSwitch"));
         world.sync();
         FakeHub& hub = fakeHub(world);
         if (c[0] == QLatin1String("installing agent tools")) hub.hostStatus = QStringLiteral("installing");
         if (c[0] == QLatin1String("starting agent tools")) hub.hostStatus = QStringLiteral("starting");
         if (c[0] == QLatin1String("installing agent tools") || c[0] == QLatin1String("starting agent tools")) {
           announce(world.mc);
           world.sync();
         }
       });
  step(QStringLiteral("\"Allow agents to control devices\" cannot be turned on while the hub is off"), [](World& world, const Captures&, const Table&) {
    setHubStatus(world, QStringLiteral("disabled"));
    expect(!devicePanel(world).item(QStringLiteral("wizardAgentSwitch"))->isEnabled(), describe(world));
  });
{}
  step(QStringLiteral("the button says \"Saving…\" until the answer arrives"), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).item(QStringLiteral("wizardDone"))->property("text") == QStringLiteral("Saving…"), describe(world));
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the wizard closes"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !view(world).value(QStringLiteral("wizard")).isValid(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the Device tab lists the environment's devices"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !rowOf(world, QStringLiteral("iPhone 17")).isEmpty(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user shows the Device tab in another thread"), [](World& world, const Captures&, const Table&) {
    const QString other = QStringLiteral("thread-2");
    world.mc.threads.insert(other, {{QStringLiteral("id"), other}, {QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("projectId"), kProject},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(other, world.mc.threads.value(other));
    world.sync();
    stream::look(world, world.mc.environmentId + QLatin1Char(':') + other);
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("device")}});
    world.sync();
  });
  step(QStringLiteral("no wizard opens"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!view(world).value(QStringLiteral("wizard")).isValid(), describe(world));
  });
{}
  step(QStringLiteral("device support stays as the user left it"), [](World& world, const Captures&, const Table&) {
    expect(fakeHub(world).configures.isEmpty(), describe(world));
  });
{}
  step(QStringLiteral("the wizard shows the \"Device hub\" step"), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).item(QStringLiteral("deviceWizard"))->property("step").toInt() == 0, describe(world));
  });
  step(QStringLiteral("the hub fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.hostStatus = QStringLiteral("failed");
    hub.hostDetail = c[0];
    announce(world.mc);
    world.sync();
  });
  step(QStringLiteral("the wizard shows %1 as an error").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return wizardViewOf(world).value(QStringLiteral("error")) == c[0] && devicePanel(world).shows(c[0]); },
                  [&] { return describe(world); });
  });

  // --- Banners -------------------------------------------------------------
  const auto setMachine = [](World& world, const QString& label, const QString& status, const QString& detail = {}) {
    FakeHub& hub = fakeHub(world);
    hub.hostLabel = label;
    hub.localStatus = status;
    hub.hostStatus = status;
    hub.bannerDetail = detail;
  };
  step(QStringLiteral("the machine %1 is installing its device tools").arg(q), [setMachine](World& world, const Captures& c, const Table&) {
    setMachine(world, c[0], QStringLiteral("installing"));
  });
  step(QStringLiteral("the machine %1 is starting its device tools").arg(q), [setMachine](World& world, const Captures& c, const Table&) {
    setMachine(world, c[0], QStringLiteral("starting"));
  });
  step(QStringLiteral("the machine %1 is installing and says %1").arg(q), [setMachine](World& world, const Captures& c, const Table&) {
    setMachine(world, c[0], QStringLiteral("installing"), c[1]);
  });
  step(QStringLiteral("the machine %1 failed to start its device tools without saying why").arg(q),
       [setMachine](World& world, const Captures& c, const Table&) { setMachine(world, c[0], QStringLiteral("failed")); });
  step(QStringLiteral("the machine %1 failed to start its device tools").arg(q),
       [setMachine](World& world, const Captures& c, const Table&) { setMachine(world, c[0], QStringLiteral("failed")); });
  step(QStringLiteral("the tab shows a banner for %1 saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& banner : view(world).value(QStringLiteral("banners")).toList()) {
        if (at(banner, QStringLiteral("label")) == c[0] && at(banner, QStringLiteral("message")) == c[1]) return devicePanel(world).shows(c[1]);
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the banner for %1 says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& banner : view(world).value(QStringLiteral("banners")).toList()) {
        if (at(banner, QStringLiteral("label")) == c[0]) return at(banner, QStringLiteral("message")) == c[1] && devicePanel(world).shows(c[1]);
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("it says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return devicePanel(world).shows(c[0]); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the MC can retry a single machine"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).supportsRetry = true;
  });
  step(QStringLiteral("the MC cannot retry a single machine"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).supportsRetry = false;
  });
  step(QStringLiteral("the user chooses \"Retry\" on its banner"), [](World& world, const Captures&, const Table&) {
    addDeviceTab(world);
    world.mc.hold(QStringLiteral("device.list"));
    devicePanel(world).click(QStringLiteral("deviceBannerRetry-") + QString(kHost));
    world.sync();
  });
  step(QStringLiteral("the banner for %1 offers no \"Retry\"").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !view(world).value(QStringLiteral("banners")).toList().isEmpty(); }, [&] { return describe(world); });
    expect(!devicePanel(world).item(QStringLiteral("deviceBannerRetry-") + QString(kHost))->isVisible(), describe(world));
  });
  step(QStringLiteral("the button says \"Retrying…\" until the answer arrives"), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).item(QStringLiteral("deviceBannerRetry-") + QString(kHost))->property("text") == QStringLiteral("Retrying…"),
           describe(world));
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("only %1 is retried").arg(q), [](World& world, const Captures& c, const Table&) {
    Q_UNUSED(c);
    const QList<QJsonObject> lists = fakeHub(world).lists;
    expect(!lists.isEmpty() && lists.last().value(QLatin1String("retryHostId")).toString() == kHost, describe(world));
  });
  step(QStringLiteral("device support is off and the machine %1 failed earlier").arg(q), [setMachine](World& world, const Captures& c, const Table&) {
    setMachine(world, c[0], QStringLiteral("failed"));
    fakeHub(world).hostStatus = QStringLiteral("disabled");
    look(world);
  });
  step(QStringLiteral("no banner is shown for %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(view(world).value(QStringLiteral("banners")).toList().isEmpty(), describe(world));
  });
  step(QStringLiteral("the setup wizard shows the banner for %1").arg(q), [openWizard](World& world, const Captures& c, const Table&) {
    fakeHub(world).onboarding = false;
    addDeviceTab(world);
    openWizard(world);
    world.waitFor([&] {
      for (const QVariant& banner : view(world).value(QStringLiteral("banners")).toList()) {
        if (at(banner, QStringLiteral("label")) == c[0]) return devicePanel(world).shows(at(banner, QStringLiteral("message")).toString());
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("so does the Device tab once setup is done"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("wizardCancel"));
    world.sync();
    const QVariantList banners = view(world).value(QStringLiteral("banners")).toList();
    expect(!banners.isEmpty() && devicePanel(world).shows(at(banners.first(), QStringLiteral("message")).toString()), describe(world));
  });

  // --- The Tools drawer ------------------------------------------------------
  // A device with a full set of reported settings, open on its tab.
  const auto toolDevice = [](World& world, const QString& platform, const QString& name) {
    FakeHub& hub = fakeHub(world);
    if (platform == QLatin1String("ios")) {
      hub.settings = {{QStringLiteral("appearance"), QStringLiteral("light")},
                      {QStringLiteral("textSize"), QStringLiteral("default")},
                      {QStringLiteral("liquidGlass"), QStringLiteral("clear")},
                      {QStringLiteral("colorFilter"), QStringLiteral("none")},
                      {QStringLiteral("reduceMotion"), false},
                      {QStringLiteral("increaseContrast"), false},
                      {QStringLiteral("reduceTransparency"), false},
                      {QStringLiteral("showBorders"), false},
                      {QStringLiteral("voiceOver"), false}};
    } else {
      hub.settings = {{QStringLiteral("appearance"), QStringLiteral("light")},
                      {QStringLiteral("textSize"), QStringLiteral("default")},
                      {QStringLiteral("reduceMotion"), false},
                      {QStringLiteral("networkEnabled"), true}};
    }
    hub.foregroundApp = QJsonObject{{QStringLiteral("id"), QStringLiteral("com.example.shop")}};
    addDevice(world, platform, name, true);
    openSession(world.mc, deviceNamed(fakeHub(world), name));
    announce(world.mc);
    showDeviceTab(world, name);
  };

  step(QStringLiteral("the user has the tools open for the (iOS Simulator|Android Emulator) %1").arg(q),
       [toolDevice](World& world, const Captures& c, const Table&) {
         toolDevice(world, c[0] == QLatin1String("iOS Simulator") ? QStringLiteral("ios") : QStringLiteral("android"), c[1]);
         // On the wide panel the drawer sits beside the screen, and every
         // control below can be clicked.
         devicePanel(world).window().resize(900, 1100);
         devicePanel(world).root()->setSize(QSizeF(900, 1100));
         openTools(world);
       });

  step(QStringLiteral("the tools say %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("error")) == c[0] || devicePanel(world).shows(c[0]); },
                  [&] { return show(toolsView(world)); });
  });

  step(QStringLiteral("the tools have no \"(.+)\""), [](World& world, const Captures& c, const Table&) {
    expect(!devicePanel(world).shows(c[0]), QStringLiteral("the tools show %1").arg(c[0]));
  });

  const auto axScreen = [](World& world) {
    fakeHub(world).axTree = {QJsonObject{{QStringLiteral("AXLabel"), QString()},
                                         {QStringLiteral("frame"), QJsonObject{{QStringLiteral("x"), 0}, {QStringLiteral("y"), 0}, {QStringLiteral("width"), 390}, {QStringLiteral("height"), 844}}},
                                         {QStringLiteral("children"), QJsonArray{QJsonObject{{QStringLiteral("AXLabel"), QStringLiteral("Buy")},
                                                                                            {QStringLiteral("frame"), QJsonObject{{QStringLiteral("x"), 39}, {QStringLiteral("y"), 84}, {QStringLiteral("width"), 78}, {QStringLiteral("height"), 42}}}}}}}};
  };

  step(QStringLiteral("the MC has given the client no device access yet"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.noAccess = true;
    announce(world.mc);
    world.sync();
    // The tools read their target again from the announcement.
    world.waitFor([&] { return !toolsView(world).value(QStringLiteral("axOffered")).toBool(); }, [&] { return show(toolsView(world)); });
  });

  step(QStringLiteral("\"Overlay element frames\" cannot be turned on"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    if (!toolsView(world).value(QStringLiteral("open")).toBool()) openTools(world);
    expect(!devicePanel(world).item(QStringLiteral("toolsAxOverlay"))->isEnabled(), describe(world));
  });

  // --- The Tools drawer as the ledger words it ------------------------------
  const auto widePanel = [](World& world) {
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
  };
  const auto narrowPanel = [](World& world) {
    devicePanel(world).window().resize(420, 900);
    devicePanel(world).root()->setSize(QSizeF(420, 900));
  };
{}
{}
  step(QStringLiteral("the tools open beside the screen when the panel is wide enough"), [widePanel](World& world, const Captures&, const Table&) {
    widePanel(world);
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("open")).toBool(); }, [&] { return describe(world); });
    QQuickItem* drawer = devicePanel(world).item(QStringLiteral("deviceToolsPanel"));
    QQuickItem* screen = screenItem(world);
    const QPointF drawerAt = drawer->mapToScene(QPointF(0, 0));
    const QPointF screenAt = screen->mapToScene(QPointF(0, 0));
    expect(drawer->isVisible() && screen->isVisible() && screenAt.x() + screen->width() <= drawerAt.x() + 1, describeScreen(world));
    world.mc.answerHeld();
  });
  step(QStringLiteral("over the screen when it is narrow"), [narrowPanel](World& world, const Captures&, const Table&) {
    narrowPanel(world);
    world.sync();
    QQuickItem* drawer = devicePanel(world).item(QStringLiteral("deviceToolsPanel"));
    QQuickItem* screen = screenItem(world);
    const QPointF drawerAt = drawer->mapToScene(QPointF(0, 0));
    const QPointF screenAt = screen->mapToScene(QPointF(0, 0));
    expect(drawer->isVisible() && drawerAt.x() < screenAt.x() + screen->width(), describeScreen(world));
  });
  step(QStringLiteral("the tools close"), [](World& world, const Captures&, const Table&) {
    expect(!toolsView(world).value(QStringLiteral("open")).toBool(), describe(world));
  });
  step(QStringLiteral("the tools say \"Reading device settings…\" and no control can be changed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return !toolsView(world).value(QStringLiteral("loaded")).toBool() && devicePanel(world).shows(QStringLiteral("Reading device settings…")) &&
             !devicePanel(world).item(QStringLiteral("toolsChoice-Appearance-Dark"))->isEnabled();
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the device's settings arrive"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the controls show what the device reports"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return toolsView(world).value(QStringLiteral("loaded")).toBool() &&
             toolsView(world).value(QStringLiteral("settings")).toMap().value(QStringLiteral("appearance")) == QStringLiteral("light") &&
             devicePanel(world).item(QStringLiteral("toolsChoice-Appearance-Dark"))->isEnabled();
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the thread has the iOS Simulator %1 open in light appearance").arg(q),
       [](World& world, const Captures& c, const Table&) {
         fakeHub(world).settings.insert(QStringLiteral("appearance"), QStringLiteral("light"));
         addDevice(world, QStringLiteral("ios"), c[0], true);
         openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
         showDeviceTab(world, c[0]);
       });
  step(QStringLiteral("the user has the tools open"), [](World& world, const Captures&, const Table&) {
    bool hasDevice = false;
    for (const QJsonValue& device : std::as_const(fakeHub(world).devices)) hasDevice = hasDevice || device.toObject().value(QLatin1String("name")) == QStringLiteral("iPhone 17");
    if (!hasDevice) {
      addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
      openSession(world.mc, deviceNamed(fakeHub(world), QStringLiteral("iPhone 17")));
      showDeviceTab(world, QStringLiteral("iPhone 17"));
    }
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
  });
  step(QStringLiteral("the device refuses to change appearance because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).refuseAction = c[0];
  });
  step(QStringLiteral("the tools show %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("error")) == c[0] && devicePanel(world).shows(c[0]); },
                  [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the appearance still reads \"Light\""), [](World& world, const Captures&, const Table&) {
    expect(toolsView(world).value(QStringLiteral("settings")).toMap().value(QStringLiteral("appearance")) == QStringLiteral("light"),
           show(toolsView(world)));
  });
  step(QStringLiteral("the user changes a setting and the device is slow to answer"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(QStringLiteral("device.action"));
    devicePanel(world).click(QStringLiteral("toolsChoice-Appearance-Dark"));
    world.sync();
  });
  step(QStringLiteral("a spinner shows beside \"Tools\""), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return toolsView(world).value(QStringLiteral("pending")).toBool() && devicePanel(world).item(QStringLiteral("toolsSpinner"))->isVisible();
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("no other control can be changed until it answers"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsSwitch-Reduce Motion"))->isEnabled(), describe(world));
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the user changed the location of %1 in the tools").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).foregroundApp = QJsonObject{{QStringLiteral("id"), QStringLiteral("com.example.shop")}};
    addDevice(world, QStringLiteral("ios"), c[0], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    showDeviceTab(world, c[0]);
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
    typeInto(world, QStringLiteral("toolsLatitude"), QStringLiteral("59.33"));
    typeInto(world, QStringLiteral("toolsLongitude"), QStringLiteral("18.07"));
    devicePanel(world).click(QStringLiteral("toolsLocationSet"));
    world.sync();
    // The other device, with its own settings.
    addDevice(world, QStringLiteral("android"), QStringLiteral("Pixel 9"), true);
    openSession(world.mc, deviceNamed(fakeHub(world), QStringLiteral("Pixel 9")));
    announce(world.mc);
    fakeHub(world).settings = {{QStringLiteral("appearance"), QStringLiteral("dark")},
                               {QStringLiteral("textSize"), QStringLiteral("large")},
                               {QStringLiteral("reduceMotion"), true},
                               {QStringLiteral("networkEnabled"), false}};
    world.sync();
  });
  step(QStringLiteral("the user shows the tab of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), tabOf(world, c[0])}});
    world.sync();
  });
  step(QStringLiteral("its tools show its own settings and an empty location"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return toolsView(world).value(QStringLiteral("loaded")).toBool() &&
             toolsView(world).value(QStringLiteral("settings")).toMap().value(QStringLiteral("appearance")) == QStringLiteral("dark") &&
             devicePanel(world).item(QStringLiteral("toolsLatitude"))->property("text").toString().isEmpty() &&
             devicePanel(world).item(QStringLiteral("toolsLongitude"))->property("text").toString().isEmpty();
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the tools list (.+) under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.answerHeld();
    openToolsReady(world);
    Brick& panel = devicePanel(world);
    expect(panel.shows(c[1]), describe(world));
    QStringList wanted;
    for (const QString& part : c[0].split(QStringLiteral(", "))) wanted += part.split(QStringLiteral(" and "));
    for (const QString& label : wanted) expect(panel.shows(label.trimmed()), QStringLiteral("no setting named %1").arg(label));
  });
  step(QStringLiteral("the user chooses %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c[1] == QLatin1String("Appearance") || c[1] == QLatin1String("Liquid Glass")) {
      devicePanel(world).click(QStringLiteral("toolsChoice-") + c[1] + QLatin1Char('-') + c[0]);
    } else {
      QQuickItem* combo = devicePanel(world).item(QStringLiteral("toolsChoice-") + c[1]);
      const QStringList model = combo->property("model").toStringList();
      const int index = int(model.indexOf(c[0]));
      expect(index >= 0, QStringLiteral("no choice %1 among %2").arg(c[0], model.join(QStringLiteral(", "))));
      QMetaObject::invokeMethod(combo, "activated", Q_ARG(int, index));
    }
    world.sync();
  });
  step(QStringLiteral("the device is asked to apply %1").arg(q), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> values{{QStringLiteral("Dark"), QStringLiteral("dark")},
                                                {QStringLiteral("Extra large"), QStringLiteral("extra-large")},
                                                {QStringLiteral("Tinted"), QStringLiteral("tinted")},
                                                {QStringLiteral("Red / green (protanopia)"), QStringLiteral("red-green")},
                                                {QStringLiteral("Landscape left"), QStringLiteral("landscape_left")}};
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("value")).toString() == values.value(c[0])) return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the control then shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> values{{QStringLiteral("Dark"), QStringLiteral("dark")},
                                                {QStringLiteral("Extra large"), QStringLiteral("extra-large")},
                                                {QStringLiteral("Tinted"), QStringLiteral("tinted")},
                                                {QStringLiteral("Red / green (protanopia)"), QStringLiteral("red-green")}};
    world.waitFor([&] {
      const QVariantMap settings = toolsView(world).value(QStringLiteral("settings")).toMap();
      if (c[0] == QLatin1String("Landscape left")) return !toolsView(world).value(QStringLiteral("pending")).toBool();
      for (const QVariant& value : settings.values()) {
        if (value.toString() == values.value(c[0])) return true;
      }
      return false;
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the user has the tools open for the iOS Simulator %1 with Reduce Motion off").arg(q),
       [toolDevice](World& world, const Captures& c, const Table&) {
         toolDevice(world, QStringLiteral("ios"), c[0]);
         devicePanel(world).window().resize(900, 1100);
         devicePanel(world).root()->setSize(QSizeF(900, 1100));
         openTools(world);
       });
  step(QStringLiteral("the user turns on \"Reduce Motion\""), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("toolsSwitch-Reduce Motion"));
    world.sync();
  });
  step(QStringLiteral("the device is asked to turn it on"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("type")) == QLatin1String("setToggle") &&
            action.value(QLatin1String("setting")) == QStringLiteral("reduceMotion") && action.value(QLatin1String("value")).toBool())
          return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the switch then reads on"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("settings")).toMap().value(QStringLiteral("reduceMotion")).toBool(); },
                  [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the device reports no value for %1").arg(q), [toolDevice](World& world, const Captures& c, const Table&) {
    toolDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"));
    fakeHub(world).settings.remove(QStringLiteral("liquidGlass"));
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    // The device named here is the one whose setting is missing.
    Q_UNUSED(c);
    openTools(world);
  });
  step(QStringLiteral("\"Liquid Glass\" cannot be changed"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsChoice-Liquid Glass-Tinted"))->isEnabled(), describe(world));
  });
  step(QStringLiteral("the iOS Simulator %1 has %1 in front").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).foregroundApp = QJsonObject{{QStringLiteral("id"), c[1]}};
    addDevice(world, QStringLiteral("ios"), c[0], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    showDeviceTab(world, c[0]);
  });
  step(QStringLiteral("%1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.answerHeld();
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("foreground")) == c[1] && devicePanel(world).shows(c[1]); },
                  [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the app is stopped"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("type")) == QLatin1String("terminateApp")) return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the app is started again"), [](World& world, const Captures&, const Table&) {
    // Relaunch after a terminate names the app that was in front.
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("type")) == QLatin1String("launchApp")) return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user has the tools open for %1 with %1 in front").arg(q), [toolDevice](World& world, const Captures& c, const Table&) {
    fakeHub(world).foregroundApp = QJsonObject{{QStringLiteral("id"), c[1]}};
    toolDevice(world, QStringLiteral("ios"), c[0]);
    fakeHub(world).foregroundApp = QJsonObject{{QStringLiteral("id"), c[1]}};
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
  });
  step(QStringLiteral("the user opens another app on the device"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    world.waitFor([&] {
      for (const auto& feed : std::as_const(hub.feeds)) {
        if (feed.first.endsWith(QLatin1String("/appstate")) && feed.second) return true;
      }
      return false;
    }, [&] { return QStringLiteral("no foreground feed; %1").arg(describe(world)); });
    for (const auto& feed : std::as_const(hub.feeds)) {
      if (feed.first.endsWith(QLatin1String("/appstate")) && feed.second) {
        feed.second->write("data: {\"bundleId\":\"com.example.other\"}\n\n");
        feed.second->flush();
      }
    }
    world.sync();
  });
  step(QStringLiteral("the foreground feed ends with %1 in front").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeHub& hub = fakeHub(world);
    hub.foregroundApp = QJsonObject{{QStringLiteral("id"), c[0]}};
    const int before = hub.feedRequests;
    for (const auto& feed : std::as_const(hub.feeds)) {
      if (feed.first.endsWith(QLatin1String("/appstate")) && feed.second) feed.second->disconnectFromHost();
    }
    world.waitFor([&] { return hub.feedRequests > before; }, [&] { return QStringLiteral("the feed was not followed again; %1").arg(describe(world)); });
  });
  step(QStringLiteral("\"Foreground\" reads the other app's id"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("foreground")) == QStringLiteral("com.example.other"); },
                  [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the device has no app in front"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).foregroundApp = QJsonValue::Null;
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
    openSession(world.mc, deviceNamed(fakeHub(world), QStringLiteral("iPhone 17")));
    showDeviceTab(world, QStringLiteral("iPhone 17"));
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
  });
  step(QStringLiteral("\"Terminate\" and \"Relaunch\" are not offered"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsTerminate"))->isVisible() &&
               !devicePanel(world).item(QStringLiteral("toolsRelaunch"))->isVisible(),
           describe(world));
  });
  step(QStringLiteral("the user types %1 into %1 and chooses %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString field = c[2] == QLatin1String("Open") ? QStringLiteral("url") : QStringLiteral("launch");
    typeInto(world, QStringLiteral("toolsField-") + field, c[0]);
    devicePanel(world).click(QStringLiteral("toolsSubmit-") + field);
    world.sync();
    // The field's name, for its emptiness to be checked against.
    fakeHub(world).lastField = field;
  });
  step(QStringLiteral("the device is asked to (open|launch) %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (c[0] == QLatin1String("open") && action.value(QLatin1String("type")) == QLatin1String("openUrl") &&
            action.value(QLatin1String("url")).toString() == c[1])
          return true;
        if (c[0] == QLatin1String("launch") && action.value(QLatin1String("type")) == QLatin1String("launchApp") &&
            action.value(QLatin1String("appId")).toString() == c[1])
          return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the field is empty again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return devicePanel(world).item(QStringLiteral("toolsField-") + fakeHub(world).lastField)->property("text").toString().isEmpty();
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("\"Open\" and \"Launch\" cannot be chosen while their fields are empty"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsSubmit-url"))->isEnabled() &&
               !devicePanel(world).item(QStringLiteral("toolsSubmit-launch"))->isEnabled(),
           describe(world));
  });
  step(QStringLiteral("the user types latitude %1 and longitude %1 and chooses \"Set\"").arg(q), [](World& world, const Captures& c, const Table&) {
    typeInto(world, QStringLiteral("toolsLatitude"), c[0]);
    typeInto(world, QStringLiteral("toolsLongitude"), c[1]);
    fakeHub(world).wantedLocation = {c[0].toDouble(), c[1].toDouble()};
    QQuickItem* set = devicePanel(world).item(QStringLiteral("toolsLocationSet"));
    if (set->isEnabled()) {
      devicePanel(world).click(QStringLiteral("toolsLocationSet"));
      world.sync();
    }
  });
  step(QStringLiteral("the device is placed there"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("type")) == QLatin1String("setLocation") &&
            near(action.value(QLatin1String("latitude")).toDouble(), fakeHub(world).wantedLocation.first) &&
            near(action.value(QLatin1String("longitude")).toDouble(), fakeHub(world).wantedLocation.second))
          return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("\"Set\" could not be chosen"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsLocationSet"))->isEnabled(), describe(world));
  });
  step(QStringLiteral("the user chooses the preset %1").arg(q), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QPair<double, double>> presets{{QStringLiteral("San Francisco"), {37.7749, -122.4194}},
                                                               {QStringLiteral("New York"), {40.7128, -74.006}},
                                                               {QStringLiteral("London"), {51.5074, -0.1278}},
                                                               {QStringLiteral("Stockholm"), {59.3293, 18.0686}},
                                                               {QStringLiteral("Tokyo"), {35.6762, 139.6503}}};
    fakeHub(world).wantedLocation = presets.value(c[0]);
    QQuickItem* combo = devicePanel(world).item(QStringLiteral("toolsLocationPreset"));
    const QStringList model = combo->property("model").toStringList();
    const int index = int(model.indexOf(c[0]));
    expect(index >= 0, QStringLiteral("no preset %1").arg(c[0]));
    QMetaObject::invokeMethod(combo, "activated", Q_ARG(int, index));
    world.sync();
  });
  step(QStringLiteral("the fields show the preset's latitude and longitude"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return devicePanel(world).item(QStringLiteral("toolsLatitude"))->property("text").toString() == QString::number(fakeHub(world).wantedLocation.first) &&
             devicePanel(world).item(QStringLiteral("toolsLongitude"))->property("text").toString() == QString::number(fakeHub(world).wantedLocation.second);
    }, [&] {
      return QStringLiteral("the fields read %1, %2").arg(devicePanel(world).item(QStringLiteral("toolsLatitude"))->property("text").toString(),
                                                          devicePanel(world).item(QStringLiteral("toolsLongitude"))->property("text").toString());
    });
  });
  step(QStringLiteral("the user has the tools open for the iOS Simulator %1 placed in Tokyo").arg(q), [toolDevice](World& world, const Captures& c, const Table&) {
    toolDevice(world, QStringLiteral("ios"), c[0]);
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
    QQuickItem* combo = devicePanel(world).item(QStringLiteral("toolsLocationPreset"));
    QMetaObject::invokeMethod(combo, "activated", Q_ARG(int, int(combo->property("model").toStringList().indexOf(QStringLiteral("Tokyo")))));
    world.sync();
  });
  step(QStringLiteral("the user chooses \"Clear\" under \"Location\""), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("toolsLocationClear"));
    world.sync();
  });
  step(QStringLiteral("the fields are empty and the simulator has no location"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      bool cleared = false;
      for (const QJsonObject& action : fakeHub(world).actions) cleared = cleared || action.value(QLatin1String("type")) == QLatin1String("clearLocation");
      return cleared && devicePanel(world).item(QStringLiteral("toolsLatitude"))->property("text").toString().isEmpty() &&
             devicePanel(world).item(QStringLiteral("toolsLongitude"))->property("text").toString().isEmpty();
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("\"Clear\" is not offered under \"Location\""), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsLocationClear"))->isVisible(), describe(world));
  });
  step(QStringLiteral("the user has the tools open for the (iOS Simulator|Android Emulator) %1 with \"com.example.shop\" in front").arg(q),
       [toolDevice](World& world, const Captures& c, const Table&) {
         toolDevice(world, c[0] == QLatin1String("iOS Simulator") ? QStringLiteral("ios") : QStringLiteral("android"), c[1]);
         devicePanel(world).window().resize(900, 1100);
         devicePanel(world).root()->setSize(QSizeF(900, 1100));
         openTools(world);
       });
  step(QStringLiteral("the user chooses the permission %1 and then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = c[0] == QLatin1String("Motion") && toolsView(world).value(QStringLiteral("platform")) == QStringLiteral("android")
                              ? QStringLiteral("Physical activity")
                              : c[0];
    // The decision is its button here; the label map above is the Android name.
    const QString button = c[1] == QLatin1String("grant") ? QStringLiteral("Grant") : c[1] == QLatin1String("revoke") ? QStringLiteral("Revoke") : QStringLiteral("Reset");
    QQuickItem* combo = devicePanel(world).item(QStringLiteral("toolsPermission"));
    const QStringList model = combo->property("model").toStringList();
    const int index = int(model.indexOf(label));
    expect(index >= 0, QStringLiteral("no permission %1 among %2").arg(label, model.join(QStringLiteral(", "))));
    combo->setProperty("currentIndex", index);
    devicePanel(world).click(QStringLiteral("toolsPermission") + button);
    world.sync();
  });
  step(QStringLiteral("the device is asked to (grant|revoke|reset) %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> values{{QStringLiteral("Camera"), QStringLiteral("camera")},
                                                {QStringLiteral("Face ID"), QStringLiteral("faceid")},
                                                {QStringLiteral("Photos"), QStringLiteral("photos")},
                                                {QStringLiteral("Motion"), QStringLiteral("motion")}};
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("type")) == QLatin1String("setPermission") && action.value(QLatin1String("decision")).toString() == c[0] &&
            action.value(QLatin1String("permission")).toString() == values.value(c[1]) && action.value(QLatin1String("appId")).toString() == c[2])
          return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user has the tools open with \"com.example.shop\" in front"), [toolDevice](World& world, const Captures&, const Table&) {
    toolDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"));
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
  });
  step(QStringLiteral("the user types %1 as the app and chooses \"Grant\" for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    typeInto(world, QStringLiteral("toolsPermissionApp"), c[0]);
    QQuickItem* combo = devicePanel(world).item(QStringLiteral("toolsPermission"));
    combo->setProperty("currentIndex", int(combo->property("model").toStringList().indexOf(c[1])));
    devicePanel(world).click(QStringLiteral("toolsPermissionGrant"));
    world.sync();
  });
  step(QStringLiteral("the device has no app in front and the user typed no app"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).foregroundApp = QJsonValue::Null;
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"), true);
    openSession(world.mc, deviceNamed(fakeHub(world), QStringLiteral("iPhone 17")));
    showDeviceTab(world, QStringLiteral("iPhone 17"));
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
  });
  step(QStringLiteral("\"Grant\", \"Revoke\" and \"Reset\" cannot be chosen"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).item(QStringLiteral("toolsPermissionGrant"))->isEnabled() &&
               !devicePanel(world).item(QStringLiteral("toolsPermissionRevoke"))->isEnabled() &&
               !devicePanel(world).item(QStringLiteral("toolsPermissionReset"))->isEnabled(),
           describe(world));
  });
  step(QStringLiteral("the permission list (.+)"), [](World& world, const Captures& c, const Table&) {
    const QStringList model = devicePanel(world).item(QStringLiteral("toolsPermission"))->property("model").toStringList();
    if (c[0].contains(QLatin1String("includes"))) {
      expect(model.contains(QStringLiteral("Reminders")) && model.contains(QStringLiteral("Media library")) && model.contains(QStringLiteral("Face ID")) &&
                 devicePanel(world).item(QStringLiteral("toolsPermissionReset"))->isVisible(),
             model.join(QStringLiteral(", ")));
    } else {
      expect(!model.contains(QStringLiteral("Reminders")) && !model.contains(QStringLiteral("Media library")) && !model.contains(QStringLiteral("Face ID")) &&
                 model.contains(QStringLiteral("Physical activity")) && !devicePanel(world).item(QStringLiteral("toolsPermissionReset"))->isVisible(),
             model.join(QStringLiteral(", ")));
    }
  });
  step(QStringLiteral("the user types %1 under \"Push notification\" and chooses \"Send\"").arg(q), [](World& world, const Captures& c, const Table&) {
    typeInto(world, QStringLiteral("toolsPushField"), c[0]);
    devicePanel(world).click(QStringLiteral("toolsPushSend"));
    world.sync();
  });
  step(QStringLiteral("the simulator is sent the notification for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& action : fakeHub(world).actions) {
        if (action.value(QLatin1String("type")) == QLatin1String("sendPush") && action.value(QLatin1String("appId")).toString() == c[0] &&
            action.value(QLatin1String("payload")) == QStringLiteral("Order shipped"))
          return true;
      }
      return false;
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user has the tools open for the iOS Simulator %1 with no app in front").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeHub(world).foregroundApp = QJsonValue::Null;
    addDevice(world, QStringLiteral("ios"), c[0], true);
    openSession(world.mc, deviceNamed(fakeHub(world), c[0]));
    showDeviceTab(world, c[0]);
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
  });
{}
  step(QStringLiteral("the tools have no \"Push notification\" section"), [](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).shows(QStringLiteral("Push notification")), describe(world));
  });
{}
  step(QStringLiteral("it says \"No events yet.\" until the simulator reports something"), [](World& world, const Captures&, const Table&) {
    expect(devicePanel(world).shows(QStringLiteral("No events yet.")), describe(world));
  });
  step(QStringLiteral("the simulator reports events"), [](World& world, const Captures&, const Table&) {
    QJsonArray events;
    for (int id = 1; id <= 105; ++id) {
      events.append(QJsonObject{{QStringLiteral("id"), id},
                                {QStringLiteral("timestamp"), QStringLiteral("2026-09-23T10:00:%1Z").arg(id % 60, 2, 10, QLatin1Char('0'))},
                                {QStringLiteral("summary"), QStringLiteral("Event %1").arg(id)}});
    }
    for (const auto& feed : std::as_const(fakeHub(world).feeds)) {
      if (feed.first.endsWith(QLatin1String("/api/event-log/events")) && feed.second) {
        feed.second->write("data: " + QJsonDocument(QJsonObject{{QStringLiteral("events"), events}}).toJson(QJsonDocument::Compact) + "\n\n");
        feed.second->flush();
      }
    }
    world.sync();
  });
  step(QStringLiteral("each is listed with its time and summary"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantList events = toolsView(world).value(QStringLiteral("events")).toList();
      return events.size() == 100 && devicePanel(world).shows(at(events.first(), QStringLiteral("time")).toString() + QStringLiteral("  ") +
                                                              at(events.first(), QStringLiteral("summary")).toString());
    }, [&] { return show(toolsView(world).value(QStringLiteral("events")).toList().size()); });
  });
  step(QStringLiteral("only the latest 100 are kept"), [](World& world, const Captures&, const Table&) {
    const QVariantList events = toolsView(world).value(QStringLiteral("events")).toList();
    expect(events.size() == 100 && at(events.first(), QStringLiteral("summary")) == QStringLiteral("Event 6"), show(events.size()));
  });
  step(QStringLiteral("the event log is open with entries"), [toolDevice](World& world, const Captures&, const Table&) {
    toolDevice(world, QStringLiteral("ios"), QStringLiteral("iPhone 17"));
    devicePanel(world).window().resize(900, 1100);
    devicePanel(world).root()->setSize(QSizeF(900, 1100));
    openTools(world);
    devicePanel(world).click(QStringLiteral("toolsEventLogToggle"));
    world.sync();
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("eventLogOpen")).toBool(); }, [&] { return show(toolsView(world)); });
    for (const auto& feed : std::as_const(fakeHub(world).feeds)) {
      if (feed.first.endsWith(QLatin1String("/api/event-log/events")) && feed.second) {
        feed.second->write("data: {\"events\":[{\"id\":1,\"timestamp\":\"2026-09-23T10:00:01Z\",\"summary\":\"Event 1\"}]}\n\n");
        feed.second->flush();
      }
    }
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("events")).toList().size() == 1; }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the user closes \"Event log\""), [](World& world, const Captures&, const Table&) {
    fakeHub(world).eventFeedRequests = fakeHub(world).feedRequests;
    devicePanel(world).click(QStringLiteral("toolsEventLogToggle"));
    world.sync();
  });
  step(QStringLiteral("the simulator's events are no longer read"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("events")).toList().isEmpty() && !toolsView(world).value(QStringLiteral("eventLogOpen")).toBool(); },
                  [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the user opens \"Event log\" again"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("toolsEventLogToggle"));
    world.sync();
  });
  step(QStringLiteral("it starts empty"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return toolsView(world).value(QStringLiteral("eventLogOpen")).toBool() && toolsView(world).value(QStringLiteral("events")).toList().isEmpty() &&
             devicePanel(world).shows(QStringLiteral("No events yet."));
    }, [&] { return show(toolsView(world)); });
  });

  // --- The 3D body and the accessibility overlay -----------------------------
  const auto bodyItem = [](World& world) {
    QQuickItem* loader = devicePanel(world).item(QStringLiteral("deviceBodyLoader"));
    return qobject_cast<QQuickItem*>(loader->property("item").value<QObject*>());
  };
  const auto showIn3d = [bodyItem](World& world) {
    // The device's own tab first, when the Given only opened it.
    if (!view(world).value(QStringLiteral("screen")).isValid()) {
      FakeHub& hub = fakeHub(world);
      if (!hub.sessions.isEmpty()) {
        const QString id = hub.sessions.last().toObject().value(QLatin1String("deviceId")).toString();
        for (const QJsonValue& device : std::as_const(hub.devices)) {
          if (device.toObject().value(QLatin1String("id")) == id) showDeviceTab(world, device.toObject().value(QLatin1String("name")).toString());
        }
      }
    }
    if (!devicePanel(world).root()->property("show3d").toBool()) devicePanel(world).click(QStringLiteral("device3dToggle"));
    world.waitFor([&] { return bodyItem(world) != nullptr; }, [&] { return describe(world); });
  };
  step(QStringLiteral("the user shows the device in 3D and drags across it"), [showIn3d, bodyItem](World& world, const Captures&, const Table&) {
    showIn3d(world);
    QQuickItem* body = bodyItem(world);
    Brick& panel = devicePanel(world);
    const QPoint from = panel.at(body, 0.3, 0.5);
    const QPoint to = panel.at(body, 0.75, 0.5);
    QTest::mousePress(&panel.window(), Qt::LeftButton, Qt::NoModifier, from);
    QTest::mouseMove(&panel.window(), to);
    world.sync();
    // The drag's turn is read before its release settles it.
    fakeHub(world).draggedYaw = body->property("yaw").toDouble();
    QTest::mouseRelease(&panel.window(), Qt::LeftButton, Qt::NoModifier, to);
    world.sync();
  });
  step(QStringLiteral("the body turns with the drag"), [](World& world, const Captures&, const Table&) {
    expect(std::abs(fakeHub(world).draggedYaw) > 5, QStringLiteral("the drag turned %1").arg(fakeHub(world).draggedYaw));
  });
  step(QStringLiteral("when the drag ends the body settles on the nearest view that faces its screen"), [bodyItem](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return bodyItem(world)->property("settled").toBool(); }, [&] { return describeScreen(world); });
  });
  step(QStringLiteral("the 3D screen stands upright on its body"), [bodyItem](World& world, const Captures&, const Table&) {
    QQuickItem* screen = bodyItem(world)->findChild<QQuickItem*>(QStringLiteral("deviceBodyScreen"));
    expect(screen, QStringLiteral("no screen on the body"));
    world.waitFor([&] { return screen->rotation() != 0; }, [&] { return describe(world); });
    expect(screen->rotation() == deviceStream(world).rotation(), describe(world));
    QQuickItem* texture = screen->parentItem();
    expect(texture->width() > texture->height() && screen->height() == texture->width(), describe(world));
  });
  step(QStringLiteral("the picture is decoded for the flat view's size"), [](World& world, const Captures&, const Table&) {
    QQuickItem* screen = devicePanel(world).item(QStringLiteral("deviceScreen"));
    world.waitFor([&] {
      return screen->isVisible() && deviceStream(world).decoder()->maximumSize() == (screen->boundingRect().size() * screen->window()->effectiveDevicePixelRatio()).toSize();
    }, [&] {
      const QSize limit = deviceStream(world).decoder()->maximumSize();
      return QStringLiteral("a limit of %1x%2 for a screen of %3x%4, %5").arg(limit.width()).arg(limit.height()).arg(screen->width()).arg(screen->height()).arg(screen->isVisible() ? QStringLiteral("shown") : QStringLiteral("hidden"));
    });
  });
  step(QStringLiteral("the accessibility requests stall"), [](World& world, const Captures&, const Table&) {
    fakeHub(world).stallAx = true;
  });
  step(QStringLiteral("no second accessibility request is out"), [](World& world, const Captures&, const Table&) {
    FakeHub& hub = fakeHub(world);
    world.waitFor([&] { return hub.axRequests > 0; }, [&] { return describe(world); });
    const int asked = hub.axRequests;
    // That nothing follows takes time to show: a few of the tools' refreshes.
    QTest::qWait(1600);
    expect(hub.axRequests == asked, QStringLiteral("%1 requests out").arg(hub.axRequests));
  });
  step(QStringLiteral("the device's screen has more elements than the overlay shows"), [](World& world, const Captures&, const Table&) {
    QJsonArray nodes{QJsonObject{{QStringLiteral("bounds"), QJsonObject{{QStringLiteral("right"), 1000}, {QStringLiteral("bottom"), 2000}}}}};
    for (int n = 0; n < 600; ++n) {
      nodes.append(QJsonObject{{QStringLiteral("text"), QStringLiteral("Item %1").arg(n)},
                               {QStringLiteral("bounds"), QJsonObject{{QStringLiteral("left"), 0}, {QStringLiteral("top"), n}, {QStringLiteral("right"), 100}, {QStringLiteral("bottom"), n + 1}}}});
    }
    fakeHub(world).androidAx = QJsonObject{{QStringLiteral("nodes"), nodes}};
  });
  step(QStringLiteral("the overlay outlines the first %1 of them").arg(QStringLiteral("(\\d+)")), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return toolsView(world).value(QStringLiteral("axElements")).toList().size() == c[0].toInt(); },
                  [&] { return QString::number(toolsView(world).value(QStringLiteral("axElements")).toList().size()); });
  });
  step(QStringLiteral("the user shows the device in 3D"), [showIn3d](World& world, const Captures&, const Table&) { showIn3d(world); });
  step(QStringLiteral("the device has no 3D model"), [](World& world, const Captures&, const Table&) { look(world); });
  step(QStringLiteral("the 3D model cannot be downloaded"), [showIn3d, bodyItem](World& world, const Captures&, const Table&) {
    showIn3d(world);
    bodyItem(world)->setProperty("modelOverride", QStringLiteral("models/no-such-model.glb"));
  });
  step(QStringLiteral("the 3D model file is not a valid model"), [showIn3d, bodyItem](World& world, const Captures&, const Table&) {
    QFile file(QStringLiteral("/tmp/hal-c2-not-a-model.glb"));
    if (file.open(QIODevice::WriteOnly)) file.write("this is not a glTF model");
    file.close();
    showIn3d(world);
    bodyItem(world)->setProperty("modelOverride", QStringLiteral("file:///tmp/hal-c2-not-a-model.glb"));
  });
  step(QStringLiteral("a plain body of the device's family is shown instead of an error"), [bodyItem](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      QQuickItem* body = bodyItem(world);
      return body && body->property("plain").toBool() && deviceStream(world).status() != QLatin1String("error");
    }, [&] { return describeScreen(world); });
  });
  step(QStringLiteral("the device's screen is still live on it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return deviceStream(world).status() == QLatin1String("streaming") && screenItem(world)->property("hasFrame").toBool(); },
                  [&] { return describeScreen(world); });
  });
  const auto viewingIpad = [showIn3d](World& world, bool in3d, bool attached) {
    fakeHub(world).foregroundApp = QJsonObject{{QStringLiteral("id"), QStringLiteral("com.example.shop")}};
    addDevice(world, QStringLiteral("ios"), QStringLiteral("iPad Pro 13-inch"), true);
    openSession(world.mc, deviceNamed(fakeHub(world), QStringLiteral("iPad Pro 13-inch")));
    showDeviceTab(world, QStringLiteral("iPad Pro 13-inch"));
    waitForScreen(world, QStringLiteral("iPad Pro 13-inch"));
    if (attached) devicePanel(world).root()->setProperty("keyboardAttached", true);
    if (in3d) showIn3d(world);
    world.sync();
  };
  step(QStringLiteral("the user is viewing the iOS Simulator \"iPad Pro 13-inch\" in 3D with the Magic Keyboard attached"),
       [viewingIpad](World& world, const Captures&, const Table&) { viewingIpad(world, true, true); });
  step(QStringLiteral("the user is viewing the iOS Simulator \"iPad Pro 13-inch\" in the flat view with the Magic Keyboard attached"),
       [viewingIpad](World& world, const Captures&, const Table&) { viewingIpad(world, false, true); });
  step(QStringLiteral("the user is viewing the iOS Simulator \"iPad Pro 13-inch\" in 3D with no keyboard attached"),
       [viewingIpad](World& world, const Captures&, const Table&) { viewingIpad(world, true, false); });
  step(QStringLiteral("the user is viewing the iOS Simulator \"iPad Pro 13-inch\" in portrait with no keyboard attached"),
       [viewingIpad](World& world, const Captures&, const Table&) { viewingIpad(world, false, false); });
  step(QStringLiteral("the user switches to the flat view"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("device3dToggle"));
    world.sync();
  });
  step(QStringLiteral("the user switches to the 3D view"), [showIn3d](World& world, const Captures&, const Table&) { showIn3d(world); });
  step(QStringLiteral("the user attaches the Magic Keyboard"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("deviceKeyboardToggle"));
    world.sync();
  });
  step(QStringLiteral("the user detaches the Magic Keyboard"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("deviceKeyboardToggle"));
    world.sync();
  });
  step(QStringLiteral("the live screen fills the panel"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return screenItem(world)->isVisible() && red(drawnAtScreen(world)); }, [&] { return describeScreen(world); });
  });
  step(QStringLiteral("the Magic Keyboard is not shown"), [bodyItem](World& world, const Captures&, const Table&) {
    expect(!devicePanel(world).root()->property("show3d").toBool() || bodyItem(world) == nullptr, describeScreen(world));
  });
  step(QStringLiteral("the Magic Keyboard is shown attached to the iPad"), [bodyItem](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      QQuickItem* body = bodyItem(world);
      if (!body) return false;
      QQuickItem* marker = body->findChild<QQuickItem*>(QStringLiteral("deviceMagicKeyboard"));
      return marker && marker->isVisible() && body->property("keyboardAttached").toBool();
    }, [&] { return describeScreen(world); });
  });
  step(QStringLiteral("the Magic Keyboard is no longer shown"), [bodyItem](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      QQuickItem* body = bodyItem(world);
      if (!body) return false;
      QQuickItem* marker = body->findChild<QQuickItem*>(QStringLiteral("deviceMagicKeyboard"));
      return marker && !marker->isVisible() && !body->property("keyboardAttached").toBool();
    }, [&] { return describeScreen(world); });
  });
  step(QStringLiteral("the device is asked to turn to landscape"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& input : iosInput(world, 0x07)) {
        if (input.value(QLatin1String("orientation")).toString().startsWith(QLatin1String("landscape"))) return true;
      }
      return false;
    }, [&] { return describeInput(world); });
  });
  step(QStringLiteral("the user turns on \"Overlay element frames\" in the tools"), [axScreen](World& world, const Captures&, const Table&) {
    axScreen(world);
    openTools(world);
    devicePanel(world).click(QStringLiteral("toolsAxOverlay"));
    world.sync();
  });
  step(QStringLiteral("each accessibility element on the device is outlined over the screen with its label"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return toolsView(world).value(QStringLiteral("axElements")).toList().size() == 1 &&
             devicePanel(world).item(QStringLiteral("deviceAxOverlay"))->isVisible() && devicePanel(world).shows(QStringLiteral("Buy"));
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the outlines follow the device as its screen changes"), [](World& world, const Captures&, const Table&) {
    QJsonObject root = fakeHub(world).axTree.at(0).toObject();
    QJsonArray children = root.value(QLatin1String("children")).toArray();
    QJsonObject child = children.at(0).toObject();
    QJsonObject frame = child.value(QLatin1String("frame")).toObject();
    frame.insert(QStringLiteral("x"), 195);
    frame.insert(QStringLiteral("y"), 422);
    child.insert(QStringLiteral("frame"), frame);
    children[0] = child;
    root.insert(QStringLiteral("children"), children);
    fakeHub(world).axTree = {root};
    world.waitFor([&] {
      const QVariantList elements = toolsView(world).value(QStringLiteral("axElements")).toList();
      return elements.size() == 1 && std::abs(at(elements.first(), QStringLiteral("x")).toDouble() - 0.5) < 0.01;
    }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the user turns it off or shows another tab"), [](World& world, const Captures&, const Table&) {
    devicePanel(world).click(QStringLiteral("toolsAxOverlay"));
    world.sync();
  });
  step(QStringLiteral("the outlines go away"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !devicePanel(world).item(QStringLiteral("deviceAxOverlay"))->isVisible(); }, [&] { return show(toolsView(world)); });
  });
  step(QStringLiteral("the thread has %1 open and the MC has given the client no device access yet").arg(q),
       [toolDevice](World& world, const Captures& c, const Table&) {
         toolDevice(world, QStringLiteral("ios"), c[0]);
         FakeHub& hub = fakeHub(world);
         hub.noAccess = true;
         announce(world.mc);
         world.sync();
         world.waitFor([&] { return !toolsView(world).value(QStringLiteral("axOffered")).toBool(); }, [&] { return show(toolsView(world)); });
       });
});

}  // namespace

bool deviceChooses(World& world, const QString& what) {
  if (!world.brick) return false;
  if (what == QLatin1String("Refresh devices")) {
    devicePanel(world).click(QStringLiteral("deviceRefresh"));
  } else if (what == QLatin1String("Done")) {
    // The wizard's finish, held so its Saving… can be seen.
    if (!devices(world).view().value(QStringLiteral("wizard")).isValid()) return false;
    world.mc.hold(QStringLiteral("device.configure"));
    devicePanel(world).click(QStringLiteral("wizardDone"));
  } else if (what == QLatin1String("Cancel")) {
    if (!devices(world).view().value(QStringLiteral("wizard")).isValid()) return false;
    devicePanel(world).click(QStringLiteral("wizardCancel"));
  } else if (what == QLatin1String("Back")) {
    if (!devices(world).view().value(QStringLiteral("wizard")).isValid()) return false;
    devicePanel(world).click(QStringLiteral("wizardBack"));
  } else if (what == QLatin1String("Dark") || what == QLatin1String("Light") || what == QLatin1String("Clear") || what == QLatin1String("Tinted")) {
    if (!devices(world).tools()->view().value(QStringLiteral("open")).toBool()) return false;
    const QString control = what == QLatin1String("Dark") || what == QLatin1String("Light") ? QStringLiteral("Appearance") : QStringLiteral("Liquid Glass");
    devicePanel(world).click(QStringLiteral("toolsChoice-") + control + QLatin1Char('-') + what);
  } else if (what == QLatin1String("Close tools")) {
    if (!devices(world).tools()->view().value(QStringLiteral("open")).toBool()) return false;
    devicePanel(world).click(QStringLiteral("toolsClose"));
  } else if (what == QLatin1String("Terminate") || what == QLatin1String("Relaunch") || what == QLatin1String("Set") || what == QLatin1String("Clear")) {
    if (!devices(world).tools()->view().value(QStringLiteral("open")).toBool()) return false;
    devicePanel(world).click(what == QLatin1String("Terminate")   ? QStringLiteral("toolsTerminate")
                             : what == QLatin1String("Relaunch") ? QStringLiteral("toolsRelaunch")
                             : what == QLatin1String("Set")      ? QStringLiteral("toolsLocationSet")
                                                                 : QStringLiteral("toolsLocationClear"));
  } else {
    return false;
  }
  world.sync();
  return true;
}

bool deviceOpens(World& world, const QString& what) {
  auto* controller = world.native().controller<RightPanelController>();
  if (!controller) return false;
  // Only a world with a device open has Tools to open; a thread merely
  // named "Tools" has no session in the fake hub. The hub is only looked
  // at: fakeHub() would set one up (and rename the MC) in every world.
  const FakeHub& hub = world.mc.part<FakeHub>();
  const bool showing = controller->device()->view().value(QStringLiteral("screen")).isValid();
  if (!showing && (!hub.used || hub.sessions.isEmpty())) return false;
  // The device's own tab first, when the scenario only opened the device.
  if (!showing) {
    const QString id = hub.sessions.last().toObject().value(QLatin1String("deviceId")).toString();
    bool shown = false;
    for (const QJsonValue& device : std::as_const(hub.devices)) {
      if (device.toObject().value(QLatin1String("id")) == id) {
        showDeviceTab(world, device.toObject().value(QLatin1String("name")).toString());
        shown = true;
      }
    }
    if (!shown) return false;
  }
  if (what == QLatin1String("Tools")) {
    // The read is held, so a scenario can watch it land; the others'
    // settings arrive when their next step answers the held call.
    world.mc.hold(QStringLiteral("device.detail"));
    devicePanel(world).click(QStringLiteral("deviceTools"));
  } else if (what == QLatin1String("Event log")) {
    devicePanel(world).click(QStringLiteral("toolsEventLogToggle"));
    world.sync();
    world.waitFor([&] {
      for (const auto& feed : std::as_const(fakeHub(world).feeds)) {
        if (feed.first.endsWith(QLatin1String("/api/event-log/events")) && feed.second) return true;
      }
      return false;
    }, [&] { return QStringLiteral("no event feed; %1").arg(describe(world)); });
    return true;
  } else {
    return false;
  }
  world.sync();
  return true;
}

bool checkDeviceCannotChoose(World& world, const QString& what) {
  if (!world.brick || what != QLatin1String("Send")) return false;
  if (!devices(world).tools()->view().value(QStringLiteral("open")).toBool()) return false;
  expect(!devicePanel(world).item(QStringLiteral("toolsPushSend"))->isEnabled(), describe(world));
  return true;
}

bool checkDeviceCanContinue(World& world) {
  if (!world.brick || !devices(world).view().value(QStringLiteral("wizard")).isValid()) return false;
  expect(devicePanel(world).item(QStringLiteral("wizardContinue"))->isEnabled(), describe(world));
  return true;
}

bool checkDeviceOffered(World& world, const QString& name) {
  auto* controller = world.native().controller<RightPanelController>();
  if (!controller || !controller->device()) return false;
  // Only where the Device tab is the panel in play: its picker has loaded
  // and lists devices (a thread-move world has none).
  const QVariantMap deviceView = controller->device()->view();
  if (!deviceView.value(QStringLiteral("loaded")).toBool() || deviceView.value(QStringLiteral("groups")).toList().isEmpty()) return false;
  world.waitFor([&] { return !rowOf(world, name).isEmpty(); }, [&] { return describe(world); });
  return true;
}
