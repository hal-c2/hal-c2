#pragma once

#include <QByteArray>
#include <QNetworkRequest>
#include <QObject>
#include <QPointer>
#include <QSize>
#include <QString>
#include <QTimer>

#include "DeviceDecoder.h"

class McClient;
class QNetworkAccessManager;
class QNetworkReply;
class QWebSocket;

// One device's live screen and input, through the MC's device hub proxy
// (`<hubBase>/vendor/...`, never the device directly):
//
// - iOS (serve-sim): video is the `helper/<udid>/stream.avcc` body, envelopes
//   of `u32be length (tag included), u8 tag, payload` (1 avcC record,
//   2 keyframe, 3 delta, 4 JPEG seed); input goes over `helper/ws?device=`
//   as `[tag][json]`, and the helper answers with its screen config (0x82).
//   One aborted `stream.mjpeg` request first starts the helper's capture.
// - Android (serve-emu): one socket, `ws?device=<serial>&frame-meta=1`,
//   carries Annex-B access units behind a 16-byte SEMU header and takes JSON
//   gestures. `{"type":"video-session"}` means the encoder restarted (the
//   device rotated): decoding starts over from a requested keyframe.
//
// Decoding is DeviceDecoder's, off the GUI thread. A decoder that falls
// behind drops its backlog and the stream asks for a keyframe (Android) or
// reads the AVCC body again, which starts with one (iOS).
//
// status: idle (no target, or not shown), connecting, streaming (a picture
// arrived), or error with `detail` (reconnect() starts again). A dropped
// connection retries after a second; no picture within the first-frame
// timeout, an AVCC body that stops, a refused credential, a decoder that
// cannot start, or video it refuses three times running is an error, and so
// is FFmpeg not being installed (it is loaded at run time, see FFmpeg.h).
class DeviceStream : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString detail READ detail NOTIFY statusChanged)
  Q_PROPERTY(bool inputConnected READ inputConnected NOTIFY inputChanged)
  // Why the input connection dropped, while it reconnects; "" when it is up.
  Q_PROPERTY(QString inputDetail READ inputDetail NOTIFY inputChanged)
  // The MC has handed this client a hub base to read the device through
  // (the tools' read-only feeds need it; streaming alone does not say so).
  Q_PROPERTY(bool access READ access NOTIFY targetChanged)
  Q_PROPERTY(QString platform READ platform NOTIFY screenChanged)
  // portrait, landscape_left, portrait_upside_down or landscape_right.
  Q_PROPERTY(QString orientation READ orientation NOTIFY screenChanged)
  // Degrees the picture turns to show as the device is held: iOS streams its
  // raw portrait framebuffer while the device reports landscape.
  Q_PROPERTY(int rotation READ rotation NOTIFY screenChanged)
  // The device's width over height as the user sees it.
  Q_PROPERTY(double aspect READ aspect NOTIFY screenChanged)

public:
  explicit DeviceStream(McClient* client, QObject* parent = nullptr);
  ~DeviceStream() override;

  // The device to stream: its hub base path (DeviceServiceState's
  // hubBasePath), ios or android, and its id. Empty: none.
  void setTarget(const QString& hubBase, const QString& platform, const QString& deviceId);
  // Streams only while shown; hiding closes every connection.
  void setActive(bool active);
  void setTimeouts(int firstFrameMs, int retryMs);

  QString status() const { return m_status; }
  QString detail() const { return m_detail; }
  bool inputConnected() const { return m_inputConnected; }
  QString inputDetail() const { return m_inputDetail; }
  bool access() const { return !m_hubBase.isEmpty() && !m_deviceId.isEmpty(); }
  // The hub paths the tools read through the same proxy (`<hubBase>/vendor/...`).
  QString hubBase() const { return m_hubBase; }
  QString deviceId() const { return m_deviceId; }
  QString platform() const { return m_platform; }
  QString orientation() const { return m_orientation; }
  int rotation() const;
  double aspect() const;
  DeviceDecoder* decoder() { return &m_decoder; }

  // Starts over after an error.
  Q_INVOKABLE void reconnect();
  // A touch at x, y (0..1 across the picture as shown); phase begin, move or end.
  Q_INVOKABLE void touch(const QString& phase, double x, double y);
  // A key (Qt::Key) going down or up, with the text it types and whether
  // ctrl or meta is held.
  Q_INVOKABLE void key(int qtKey, const QString& text, bool command, bool down);
  // home, back, recents or power (iOS: home, recents as the app switcher,
  // power as lock; back does nothing).
  Q_INVOKABLE void pressButton(const QString& button);
  // iOS: the next orientation, clockwise from portrait.
  Q_INVOKABLE void rotate();
  // iOS: ask for one orientation (portrait, landscape_left, ...).
  Q_INVOKABLE void setOrientation(const QString& orientation);

signals:
  void statusChanged();
  void inputChanged();
  void screenChanged();
  // A different device (or none) is streamed.
  void targetChanged();

private:
  bool ios() const { return m_platform == QLatin1String("ios"); }
  QString vendorPath(const QString& path) const;
  // A proxied request, carrying the refreshed ticket once one was minted.
  QNetworkRequest hubRequest(const QString& path, const QString& query = {}, bool socket = false) const;
  void refreshAccess();
  void start();
  // Closes every connection, leaving `status`.
  void stop(const QString& status = QStringLiteral("idle"), const QString& detail = {});
  void setStatus(const QString& status, const QString& detail = {});
  void setInput(bool connected, const QString& detail = {});
  void connecting(const QString& detail = {});
  void fail(const QString& detail);
  void unauthorized();
  void onFrame();
  void recover();
  void retry(QTimer& timer);

  void readIosVideo();
  void onIosVideo();
  void primeIos();
  void connectIosInput();
  void connectAndroid();
  void onAndroidMessage(const QByteArray& message);
  void requestKeyframe();
  void send(const QByteArray& message, bool binary);
  void setScreen(int width, int height, const QString& orientation);

  McClient* m_client;
  QNetworkAccessManager* m_http;
  DeviceDecoder m_decoder;
  QString m_hubBase;
  QString m_platform;
  QString m_deviceId;
  bool m_active = false;
  bool m_running = false;

  QPointer<QNetworkReply> m_video;
  QPointer<QNetworkReply> m_prime;
  QPointer<QWebSocket> m_socket;
  QByteArray m_buffer;
  bool m_awaitingKeyframe = true;

  QTimer m_firstFrame;
  QTimer m_readStall;
  QTimer m_videoRetry;
  QTimer m_inputRetry;
  bool m_streaming = false;
  // Decoder refusals since the last picture.
  int m_decodeFailures = 0;

  QString m_status = QStringLiteral("idle");
  QString m_detail;
  bool m_inputConnected = false;
  QString m_inputDetail;
  // A fresh proxy ticket, minted once after the MC refused the stream
  // (its access expired); a second refusal is an error.
  QString m_ticket;
  bool m_refreshed = false;
  // The device's screen: iOS as its helper reports it, Android as its
  // pictures come.
  int m_width = 0;
  int m_height = 0;
  QString m_orientation = QStringLiteral("portrait");
};
