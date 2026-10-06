#pragma once

#include <QObject>
#include <QString>
#include <QUrl>

#include <optional>

#include "PairingExchange.h"

class NativeShell;
class QNetworkAccessManager;
class ShellBridge;

// The phone's one paired environment. A phone runs no MC and has no host
// process to hand it one (the desktop's host/main.ts), so it pairs by itself:
// it reads a pairing link, spends its token on a session with the MC there
// (PairingExchange), remembers that session between runs, and opens the
// shell's connection with it.
//
// One environment at a time: MCs cluster and share one sidebar, so one
// pairing already shows every machine of the cluster. Pairing with another MC
// replaces the one remembered.
//
// Publishes `pairing`:
//   {phase:  unpaired | pairing | paired,
//    error:  a sentence for the user, "" when none,
//    link:   what the user last entered, kept after a failure, "" once paired,
//    origin: the paired MC's origin, "" when unpaired,
//    label:  the paired MC's label from its descriptor, "" when unpaired}
// How the connection to a paired MC is doing is `connection`
// (ConnectionHealthController), which also pairs again with an MC that refused
// the session (`connection.pair`): the session that buys is remembered here too.
//
// Actions: `pairing.pair {link}` and `pairing.forget`, the way back out: the
// session is deleted from this device, the connection closes, and the shell
// shows nothing of the environment.
class Pairing : public QObject {
  Q_OBJECT

public:
  // `dataDir` is where the session is kept (`pairing.json`, readable by the
  // user alone): the app's private storage on a phone. `device` is what the MC
  // lists this client as.
  Pairing(ShellBridge* bridge, NativeShell* shell, const QString& dataDir, const pairing::Client& device = thisDevice(),
          QObject* parent = nullptr);

  // Connects to the remembered environment, if there is one. Once, when the
  // shell is set up.
  void start();

  // This device as an MC's client list should show it: "HAL-C2 on <model>",
  // a phone, and its OS.
  static pairing::Client thisDevice();

private:
  struct Environment {
    QUrl origin;
    QString token;
    QString label;
    QString environmentId;
    bool operator==(const Environment&) const = default;
  };

  bool handle(const QString& action, const QVariant& payload);
  void pair(const QString& link);
  void paired(const pairing::Result& result);
  void forget();
  // The shell connected with this credential: it is the one to remember.
  void remember(const QUrl& origin, const QString& token);
  // The connected MC described itself: its label and environment may be news.
  void describe();
  void load();
  void save();
  void publish();
  QString explain(const pairing::Result& result) const;

  ShellBridge* m_bridge;
  NativeShell* m_shell;
  QString m_path;
  pairing::Client m_device;
  QNetworkAccessManager* m_http;
  std::optional<Environment> m_paired;
  // The exchange in flight, if any; an answer to an older one is ignored.
  quint64 m_attempt = 0;
  bool m_pairing = false;
  QString m_error;
  QString m_link;
};
