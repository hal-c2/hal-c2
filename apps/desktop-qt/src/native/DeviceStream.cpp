#include "DeviceStream.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QUrl>
#include <QWebSocket>
#include <QtEndian>

#include <algorithm>

#include "NodeClient.h"

namespace {

constexpr int kRetryMs = 1000;
constexpr int kFirstFrameMs = 15000;
constexpr int kPrimeMs = 2000;
// Units the decoder refuses in a row, each time from a fresh keyframe, before
// the stream gives up: the video is not one it can decode.
constexpr int kMaxDecodeFailures = 3;

constexpr quint32 kSemuMagic = 0x53454d55;
constexpr int kSemuHeader = 16;

// serve-sim's input tags (to the helper), and its screen config (from it).
constexpr char kIosTouch = 0x03;
constexpr char kIosButton = 0x04;
constexpr char kIosKey = 0x06;
constexpr char kIosOrientation = 0x07;
constexpr char kIosHardwareKeyboard = 0x0d;
constexpr unsigned char kIosScreenConfig = 0x82;

const QStringList kIosOrientations{QStringLiteral("portrait"), QStringLiteral("landscape_left"),
                                   QStringLiteral("portrait_upside_down"), QStringLiteral("landscape_right")};

QByteArray tagged(char tag, const QJsonObject& payload) {
  return QByteArray(1, tag) + QJsonDocument(payload).toJson(QJsonDocument::Compact);
}

QByteArray json(const QJsonObject& payload) {
  return QJsonDocument(payload).toJson(QJsonDocument::Compact);
}

// Whether the node turned the socket away: its proxy refuses a handshake with
// 401 or 403, which Qt reports only in the error string (a 401 without a
// challenge it can answer as "Unsupported WWW-Authenticate challenges"), or a
// relay closes with a policy code.
bool refused(const QWebSocket* socket) {
  static const QRegularExpression status(QStringLiteral("status code: 40[13]\\b|WWW-Authenticate"));
  const int code = socket->closeCode();
  return socket->property("refused").toBool() || code == 1008 || code == 4401 || status.match(socket->errorString()).hasMatch();
}

QWebSocket* newSocket(QObject* parent) {
  auto* socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, parent);
  // Left unanswered, the handshake fails.
  QObject::connect(socket, &QWebSocket::authenticationRequired, socket, [socket] { socket->setProperty("refused", true); });
  return socket;
}

bool isLandscape(const QString& orientation) {
  return orientation == QLatin1String("landscape_left") || orientation == QLatin1String("landscape_right");
}

// Whether an Annex-B access unit holds an IDR slice (NAL type 5).
bool hasKeyframe(const QByteArray& unit) {
  const auto* bytes = reinterpret_cast<const uchar*>(unit.constData());
  const qsizetype length = unit.size();
  for (qsizetype i = 0; i + 3 < length; ++i) {
    if (bytes[i] || bytes[i + 1]) continue;
    int code = 0;
    if (bytes[i + 2] == 1) code = 3;
    else if (bytes[i + 2] == 0 && bytes[i + 3] == 1) code = 4;
    if (!code || i + code >= length) continue;
    if ((bytes[i + code] & 0x1f) == 5) return true;
    i += code;
  }
  return false;
}

// The USB HID usage serve-sim takes for a key, by the key a US layout
// produces it with (shifted symbols share their key's usage), or -1.
int hidUsage(int key) {
  if (key >= Qt::Key_A && key <= Qt::Key_Z) return 0x04 + (key - Qt::Key_A);
  if (key >= Qt::Key_1 && key <= Qt::Key_9) return 0x1e + (key - Qt::Key_1);
  switch (key) {
  case Qt::Key_0: case Qt::Key_ParenRight: return 0x27;
  case Qt::Key_Exclam: return 0x1e;
  case Qt::Key_At: return 0x1f;
  case Qt::Key_NumberSign: return 0x20;
  case Qt::Key_Dollar: return 0x21;
  case Qt::Key_Percent: return 0x22;
  case Qt::Key_AsciiCircum: return 0x23;
  case Qt::Key_Ampersand: return 0x24;
  case Qt::Key_Asterisk: return 0x25;
  case Qt::Key_ParenLeft: return 0x26;
  case Qt::Key_Return: case Qt::Key_Enter: return 0x28;
  case Qt::Key_Escape: return 0x29;
  case Qt::Key_Backspace: return 0x2a;
  case Qt::Key_Tab: case Qt::Key_Backtab: return 0x2b;
  case Qt::Key_Space: return 0x2c;
  case Qt::Key_Minus: case Qt::Key_Underscore: return 0x2d;
  case Qt::Key_Equal: case Qt::Key_Plus: return 0x2e;
  case Qt::Key_BracketLeft: case Qt::Key_BraceLeft: return 0x2f;
  case Qt::Key_BracketRight: case Qt::Key_BraceRight: return 0x30;
  case Qt::Key_Backslash: case Qt::Key_Bar: return 0x31;
  case Qt::Key_Semicolon: case Qt::Key_Colon: return 0x33;
  case Qt::Key_Apostrophe: case Qt::Key_QuoteDbl: return 0x34;
  case Qt::Key_QuoteLeft: case Qt::Key_AsciiTilde: return 0x35;
  case Qt::Key_Comma: case Qt::Key_Less: return 0x36;
  case Qt::Key_Period: case Qt::Key_Greater: return 0x37;
  case Qt::Key_Slash: case Qt::Key_Question: return 0x38;
  case Qt::Key_Delete: return 0x4c;
  case Qt::Key_Right: return 0x4f;
  case Qt::Key_Left: return 0x50;
  case Qt::Key_Down: return 0x51;
  case Qt::Key_Up: return 0x52;
  case Qt::Key_Control: return 0xe0;
  case Qt::Key_Shift: return 0xe1;
  case Qt::Key_Alt: return 0xe2;
  case Qt::Key_Meta: return 0xe3;
  default: return -1;
  }
}

// The Android keycode serve-emu takes for a key, or -1 (characters go as text).
int androidKeycode(int key) {
  switch (key) {
  case Qt::Key_Up: return 19;
  case Qt::Key_Down: return 20;
  case Qt::Key_Left: return 21;
  case Qt::Key_Right: return 22;
  case Qt::Key_Tab: return 61;
  case Qt::Key_Return: case Qt::Key_Enter: return 66;
  case Qt::Key_Backspace: return 67;
  case Qt::Key_Delete: return 112;
  case Qt::Key_Home: return 122;
  case Qt::Key_End: return 123;
  case Qt::Key_PageUp: return 92;
  case Qt::Key_PageDown: return 93;
  default: return -1;
  }
}

}  // namespace

DeviceStream::DeviceStream(NodeClient* client, QObject* parent)
    : QObject(parent), m_client(client), m_http(new QNetworkAccessManager(this)) {
  for (QTimer* timer : {&m_firstFrame, &m_readStall, &m_videoRetry, &m_inputRetry}) timer->setSingleShot(true);
  setTimeouts(kFirstFrameMs, kRetryMs);
  connect(&m_firstFrame, &QTimer::timeout, this,
          [this] { fail(QStringLiteral("No video received from the device. Reconnect to try again.")); });
  connect(&m_readStall, &QTimer::timeout, this,
          [this] { fail(QStringLiteral("Device stream stopped receiving video. Reconnect to try again.")); });
  connect(&m_videoRetry, &QTimer::timeout, this, &DeviceStream::readIosVideo);
  connect(&m_inputRetry, &QTimer::timeout, this, [this] { ios() ? primeIos() : connectAndroid(); });
  connect(&m_decoder, &DeviceDecoder::frameReady, this, &DeviceStream::onFrame);
  connect(&m_decoder, &DeviceDecoder::broken, this, [this] {
    if (!m_running) return;
    if (++m_decodeFailures >= kMaxDecodeFailures)
      return fail(QStringLiteral("The device's video could not be decoded. Reconnect to try again."));
    recover();
  });
  connect(&m_decoder, &DeviceDecoder::unsupported, this, [this](const QString& why) {
    fail(QStringLiteral("Cannot decode the device's video. %1").arg(why));
  });
}

DeviceStream::~DeviceStream() {
  stop();
}

void DeviceStream::setTarget(const QString& hubBase, const QString& platform, const QString& deviceId) {
  if (hubBase == m_hubBase && platform == m_platform && deviceId == m_deviceId) return;
  stop();
  m_hubBase = hubBase;
  m_platform = platform;
  m_deviceId = deviceId;
  m_width = m_height = 0;
  m_orientation = QStringLiteral("portrait");
  emit targetChanged();
  emit screenChanged();
  start();
}

void DeviceStream::setActive(bool active) {
  if (active == m_active) return;
  m_active = active;
  if (active) start();
  else stop();
}

void DeviceStream::setTimeouts(int firstFrameMs, int retryMs) {
  m_firstFrame.setInterval(firstFrameMs);
  m_readStall.setInterval(firstFrameMs);
  m_videoRetry.setInterval(retryMs);
  m_inputRetry.setInterval(retryMs);
}

void DeviceStream::reconnect() {
  stop();
  start();
}

int DeviceStream::rotation() const {
  if (!ios() || !m_width || m_width > m_height) return 0;
  if (m_orientation == QLatin1String("landscape_left")) return 90;
  if (m_orientation == QLatin1String("landscape_right")) return -90;
  if (m_orientation == QLatin1String("portrait_upside_down")) return 180;
  return 0;
}

double DeviceStream::aspect() const {
  if (!m_width || !m_height) return ios() ? 9.0 / 19.5 : 9.0 / 20.0;
  const int longer = std::max(m_width, m_height), shorter = std::min(m_width, m_height);
  return isLandscape(m_orientation) ? double(longer) / shorter : double(shorter) / longer;
}

QString DeviceStream::vendorPath(const QString& path) const {
  return m_hubBase + (ios() ? QStringLiteral("/vendor/serve-sim") : QStringLiteral("/vendor/serve-emu")) + path;
}

void DeviceStream::start() {
  if (m_running) return;
  if (!m_active || m_hubBase.isEmpty() || m_deviceId.isEmpty()) {
    setStatus(QStringLiteral("idle"));
    return;
  }
  m_running = true;
  m_decodeFailures = 0;
  connecting();
  if (ios()) {
    primeIos();
    readIosVideo();
  } else {
    connectAndroid();
  }
}

void DeviceStream::stop(const QString& status, const QString& detail) {
  m_running = false;
  for (QTimer* timer : {&m_firstFrame, &m_readStall, &m_videoRetry, &m_inputRetry}) timer->stop();
  for (QPointer<QNetworkReply>* slot : {&m_video, &m_prime}) {
    if (QNetworkReply* reply = slot->data()) {
      *slot = nullptr;
      reply->disconnect(this);
      reply->abort();
      reply->deleteLater();
    }
  }
  if (QWebSocket* socket = m_socket.data()) {
    m_socket = nullptr;
    socket->disconnect(this);
    socket->close();
    socket->deleteLater();
  }
  m_buffer.clear();
  m_decoder.reset();
  m_streaming = false;
  setInput(false);
  setStatus(status, detail);
}

void DeviceStream::setStatus(const QString& status, const QString& detail) {
  if (status == m_status && detail == m_detail) return;
  m_status = status;
  m_detail = detail;
  emit statusChanged();
}

void DeviceStream::setInput(bool connected) {
  if (connected == m_inputConnected) return;
  m_inputConnected = connected;
  emit inputChanged();
}

// Waiting for a picture again: one must come within the first-frame timeout.
void DeviceStream::connecting(const QString& detail) {
  m_streaming = false;
  if (!m_firstFrame.isActive()) m_firstFrame.start();
  setStatus(QStringLiteral("connecting"), detail);
}

void DeviceStream::fail(const QString& detail) {
  if (m_running) stop(QStringLiteral("error"), detail);
}

void DeviceStream::unauthorized() {
  fail(QStringLiteral("The node refused the device stream. Reconnect to try again."));
}

void DeviceStream::onFrame() {
  if (!m_running) return;
  if (!ios()) {
    // serve-emu's pictures come at the size the device is held.
    const QSize size = m_decoder.sourceSize();
    if (!size.isEmpty())
      setScreen(size.width(), size.height(),
                size.width() > size.height() ? QStringLiteral("landscape_left") : QStringLiteral("portrait"));
  }
  m_decodeFailures = 0;
  if (m_streaming) return;
  m_streaming = true;
  m_firstFrame.stop();
  setStatus(QStringLiteral("streaming"));
}

// The decoder fell behind or choked: start over from a keyframe, on iOS by
// reading the body again after the retry delay.
void DeviceStream::recover() {
  if (!m_running) return;
  if (ios()) {
    if (QNetworkReply* reply = m_video.data()) {
      m_video = nullptr;
      reply->disconnect(this);
      reply->abort();
      reply->deleteLater();
    }
    m_readStall.stop();
    m_decoder.reset();
    connecting(QStringLiteral("Video decoder restarted."));
    retry(m_videoRetry);
  } else {
    m_decoder.reset();
    m_awaitingKeyframe = true;
    connecting(QStringLiteral("Video decoder restarted."));
    requestKeyframe();
  }
}

void DeviceStream::retry(QTimer& timer) {
  if (m_running && !timer.isActive()) timer.start();
}

// iOS video: the AVCC body, demuxed into the decoder.
void DeviceStream::readIosVideo() {
  if (!m_running || m_video) return;
  m_buffer.clear();
  const QString device = QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId));
  QNetworkReply* reply = m_http->get(m_client->request(vendorPath(QStringLiteral("/helper/%1/stream.avcc").arg(device))));
  m_video = reply;
  m_readStall.start();
  connect(reply, &QNetworkReply::readyRead, this, &DeviceStream::onIosVideo);
  connect(reply, &QNetworkReply::finished, this, [this, reply] {
    if (m_video != reply) return;
    m_video = nullptr;
    reply->deleteLater();
    m_readStall.stop();
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (code == 401 || code == 403) return unauthorized();
    m_decoder.reset();
    connecting(reply->error() == QNetworkReply::NoError ? QString() : reply->errorString());
    retry(m_videoRetry);
  });
}

void DeviceStream::onIosVideo() {
  QNetworkReply* reply = m_video.data();
  if (!reply || !m_running) return;
  const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
  if (code == 401 || code == 403) return unauthorized();
  if (code && code / 100 != 2) {
    // The proxy's refusal (the hub is down or the device went away): retry.
    m_video = nullptr;
    reply->disconnect(this);
    reply->abort();
    reply->deleteLater();
    m_readStall.stop();
    connecting(QStringLiteral("stream %1").arg(code));
    retry(m_videoRetry);
    return;
  }
  // An AVCC body can stay open after its helper stops producing frames.
  m_readStall.start();
  m_buffer += reply->readAll();
  qsizetype offset = 0;
  while (m_buffer.size() - offset >= 4) {
    const quint32 length = qFromBigEndian<quint32>(m_buffer.constData() + offset);
    if (quint64(m_buffer.size() - offset - 4) < length) break;
    if (length >= 1) {
      const auto tag = uchar(m_buffer.at(offset + 4));
      const QByteArray payload = m_buffer.mid(offset + 5, qsizetype(length) - 1);
      if (tag == 1) {
        m_decoder.reset(payload);
      } else if (tag == 2 || tag == 3) {
        if (!m_decoder.push(payload, tag == 2)) {
          m_buffer.clear();
          recover();
          return;
        }
      } else if (tag == 4) {
        m_decoder.pushJpeg(payload);
      }
    }
    offset += 4 + qsizetype(length);
  }
  m_buffer.remove(0, offset);
}

// serve-sim's helper takes input and reports its screen only once capture
// runs, which the AVCC stream does not reliably start; one aborted MJPEG
// request does. The input socket follows either way.
void DeviceStream::primeIos() {
  if (!m_running || m_prime || m_socket) return;
  const QString device = QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId));
  QNetworkReply* reply = m_http->get(m_client->request(vendorPath(QStringLiteral("/helper/%1/stream.mjpeg").arg(device))));
  m_prime = reply;
  auto done = [this, reply] {
    if (m_prime != reply) return;
    m_prime = nullptr;
    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    reply->disconnect(this);
    reply->abort();
    reply->deleteLater();
    if (code == 401 || code == 403) return unauthorized();
    connectIosInput();
  };
  connect(reply, &QNetworkReply::readyRead, this, done);
  connect(reply, &QNetworkReply::finished, this, done);
  QTimer::singleShot(kPrimeMs, reply, done);
}

void DeviceStream::connectIosInput() {
  if (!m_running || m_socket) return;
  QWebSocket* socket = newSocket(this);
  m_socket = socket;
  connect(socket, &QWebSocket::connected, this, [this, socket] {
    if (m_socket != socket) return;
    socket->sendBinaryMessage(tagged(kIosHardwareKeyboard, {{QStringLiteral("enabled"), false}}));
    setInput(true);
  });
  connect(socket, &QWebSocket::binaryMessageReceived, this, [this, socket](const QByteArray& message) {
    if (m_socket != socket || message.isEmpty() || uchar(message.at(0)) != kIosScreenConfig) return;
    const QJsonObject config = QJsonDocument::fromJson(message.mid(1)).object();
    const int width = config.value(QLatin1String("width")).toInt();
    const int height = config.value(QLatin1String("height")).toInt();
    if (width > 0 && height > 0) setScreen(width, height, config.value(QLatin1String("orientation")).toString());
  });
  // A handshake that fails never connects, so only errorOccurred says so.
  const auto closed = [this, socket] {
    if (m_socket != socket) return;
    m_socket = nullptr;
    socket->disconnect(this);
    socket->deleteLater();
    setInput(false);
    if (refused(socket)) return unauthorized();
    retry(m_inputRetry);
  };
  connect(socket, &QWebSocket::disconnected, this, closed);
  connect(socket, &QWebSocket::errorOccurred, this, closed);
  socket->open(m_client->request(vendorPath(QStringLiteral("/helper/ws")),
                                 QStringLiteral("device=") + QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId)), true));
}

// Android: one socket for video and input.
void DeviceStream::connectAndroid() {
  if (!m_running || m_socket) return;
  QWebSocket* socket = newSocket(this);
  m_socket = socket;
  m_awaitingKeyframe = true;
  connect(socket, &QWebSocket::connected, this, [this, socket] {
    if (m_socket != socket) return;
    connecting();
    setInput(true);
  });
  connect(socket, &QWebSocket::binaryMessageReceived, this, [this, socket](const QByteArray& message) {
    if (m_socket == socket) onAndroidMessage(message);
  });
  connect(socket, &QWebSocket::textMessageReceived, this, [this, socket](const QString& message) {
    if (m_socket != socket) return;
    // The encoder restarts at a new size when the device rotates; the next
    // keyframe carries a fresh SPS.
    if (QJsonDocument::fromJson(message.toUtf8()).object().value(QLatin1String("type")) == QLatin1String("video-session")) {
      m_decoder.reset();
      m_awaitingKeyframe = true;
      connecting();
      requestKeyframe();
    }
  });
  const auto closed = [this, socket] {
    if (m_socket != socket) return;
    m_socket = nullptr;
    socket->disconnect(this);
    socket->deleteLater();
    m_decoder.reset();
    setInput(false);
    if (refused(socket)) return unauthorized();
    connecting(socket->closeReason());
    retry(m_inputRetry);
  };
  connect(socket, &QWebSocket::disconnected, this, closed);
  connect(socket, &QWebSocket::errorOccurred, this, closed);
  socket->open(m_client->request(vendorPath(QStringLiteral("/ws")),
                                 QStringLiteral("device=%1&frame-meta=1").arg(QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId))),
                                 true));
}

void DeviceStream::onAndroidMessage(const QByteArray& message) {
  QByteArray unit = message;
  int key = -1;
  if (message.size() > kSemuHeader && qFromBigEndian<quint32>(message.constData()) == kSemuMagic && message.at(4) == 1) {
    key = (message.at(5) & 1) ? 1 : 0;
    unit = message.mid(kSemuHeader);
  }
  const bool keyframe = key < 0 ? hasKeyframe(unit) : key == 1;
  if (m_awaitingKeyframe) {
    if (!keyframe) {
      requestKeyframe();
      return;
    }
    m_awaitingKeyframe = false;
  }
  if (!m_decoder.push(unit, keyframe)) recover();
}

void DeviceStream::requestKeyframe() {
  if (!ios()) send(json({{QStringLiteral("type"), QStringLiteral("reset-video")}, {QStringLiteral("ack"), false}}), false);
}

void DeviceStream::send(const QByteArray& message, bool binary) {
  QWebSocket* socket = m_socket.data();
  if (!m_running || !socket || socket->state() != QAbstractSocket::ConnectedState) return;
  if (binary) socket->sendBinaryMessage(message);
  else socket->sendTextMessage(QString::fromUtf8(message));
}

void DeviceStream::setScreen(int width, int height, const QString& orientation) {
  const QString known = kIosOrientations.contains(orientation) ? orientation : QStringLiteral("portrait");
  if (width == m_width && height == m_height && known == m_orientation) return;
  m_width = width;
  m_height = height;
  m_orientation = known;
  emit screenChanged();
}

void DeviceStream::touch(const QString& phase, double x, double y) {
  x = std::clamp(x, 0.0, 1.0);
  y = std::clamp(y, 0.0, 1.0);
  if (ios()) {
    // serve-sim takes points in its raw framebuffer, which stays portrait
    // while the device turns.
    double rawX = x, rawY = y;
    if (m_width && m_width <= m_height) {
      if (m_orientation == QLatin1String("landscape_left")) rawX = y, rawY = 1 - x;
      else if (m_orientation == QLatin1String("landscape_right")) rawX = 1 - y, rawY = x;
      else if (m_orientation == QLatin1String("portrait_upside_down")) rawX = 1 - x, rawY = 1 - y;
    }
    send(tagged(kIosTouch, {{QStringLiteral("type"), phase}, {QStringLiteral("x"), rawX}, {QStringLiteral("y"), rawY}}), true);
    return;
  }
  const QString action = phase == QLatin1String("begin") ? QStringLiteral("down")
                         : phase == QLatin1String("move") ? QStringLiteral("move")
                                                          : QStringLiteral("up");
  send(json({{QStringLiteral("type"), QStringLiteral("touch")},
             {QStringLiteral("action"), action},
             {QStringLiteral("x"), x},
             {QStringLiteral("y"), y}}),
       false);
}

void DeviceStream::key(int qtKey, const QString& text, bool command, bool down) {
  if (ios()) {
    const int usage = hidUsage(qtKey);
    if (usage >= 0)
      send(tagged(kIosKey, {{QStringLiteral("type"), down ? QStringLiteral("down") : QStringLiteral("up")},
                            {QStringLiteral("usage"), usage}}),
           true);
    return;
  }
  if (!down) return;
  if (qtKey == Qt::Key_Escape) return send(json({{QStringLiteral("type"), QStringLiteral("back")}}), false);
  const int keycode = androidKeycode(qtKey);
  if (keycode >= 0)
    return send(json({{QStringLiteral("type"), QStringLiteral("key")}, {QStringLiteral("keycode"), keycode}}), false);
  if (text.size() == 1 && text.at(0).isPrint() && !command)
    send(json({{QStringLiteral("type"), QStringLiteral("text")}, {QStringLiteral("text"), text}}), false);
}

void DeviceStream::pressButton(const QString& button) {
  if (ios()) {
    const QString name = button == QLatin1String("home")      ? QStringLiteral("home")
                         : button == QLatin1String("recents") ? QStringLiteral("app_switcher")
                         : button == QLatin1String("power")   ? QStringLiteral("lock")
                                                              : QString();
    if (!name.isEmpty()) send(tagged(kIosButton, {{QStringLiteral("button"), name}}), true);
    return;
  }
  static const QStringList buttons{QStringLiteral("home"), QStringLiteral("back"), QStringLiteral("recents"),
                                   QStringLiteral("power")};
  if (buttons.contains(button)) send(json({{QStringLiteral("type"), button}}), false);
}

void DeviceStream::rotate() {
  if (!ios()) return;
  const QString next = kIosOrientations.at((kIosOrientations.indexOf(m_orientation) + 1) % kIosOrientations.size());
  send(tagged(kIosOrientation, {{QStringLiteral("orientation"), next}}), true);
}
