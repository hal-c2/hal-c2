#pragma once

#include <QObject>
#include <QVariantMap>

#include <functional>

#include "NativeController.h"

class McClient;
class NativeWindow;
class QNetworkAccessManager;
class ShellBridge;
class ShellStore;

// How the shell's one connection to its MC is doing, said in words: the
// McClient owns the retries (its phases), and this turns them into what every
// window shows (the ConnectionNotice brick, the first row of Connections
// settings). One per process.
//
// Publishes `connection`:
//   {phase: connecting | connected | reconnecting | offline | refused |
//           blocked | problem,
//    status,          the row's words: "Connected", "Reconnecting: timeout", ...
//    title, detail,   the notice's words; empty while connected
//    reason,          why the last connection ended, or ""
//    traceId,         the failed attempt's trace id, or ""
//    canRetry, needsPairing, pairing, pairingError,
//    versionWarning:  null | {clientVersion, serverVersion, text}}
// `connected` is not said before the MC's shell snapshot lands on this
// connection: the socket alone shows nothing. `problem` is a socket that is
// fine while the MC turned the shell subscription down, which is not a
// reconnect.
//
// Actions: `connection.retry`, `connection.copyTraceId`, `connection.pair
// {pairingUrl}` (a fresh link for the same MC replaces the session the MC
// refused; rows, drafts and the route stay), and
// `connection.dismissVersionWarning` (kept on this device per pair of versions).
class ConnectionHealthController : public QObject, public NativeController {
  Q_OBJECT

public:
  ConnectionHealthController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  void attach(NativeWindow* window) override;
  bool handle(const QString& action, const QVariant& payload) override;

  // This app's version (QCoreApplication::applicationVersion by default).
  void setClientVersion(const QString& version);
  void setClipboardWriter(std::function<bool(const QString&)> write) { m_writeClipboard = std::move(write); }

  // Whether a server on `server` is behind a client on `client` (apps/web
  // versionSkew.ts): two nightlies compare whole, anything else by its core
  // major.minor.patch, so a release and a nightly of one core do not differ.
  static bool serverBehind(const QString& client, const QString& server);

private:
  void update();
  void pair(const QString& pairingUrl);
  QString label() const;
  QVariant versionWarning() const;
  QStringList dismissed() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  QNetworkAccessManager* m_http = nullptr;
  std::function<bool(const QString&)> m_writeClipboard;
  QString m_clientVersion;
  // The store's snapshot count when the socket last became ready: the
  // connection is described once it grows.
  quint64 m_snapshotsAtReady = 0;
  bool m_pairing = false;
  QString m_pairingError;
};
