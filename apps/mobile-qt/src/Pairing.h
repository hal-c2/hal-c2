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
//   {phase:   unpaired | pairing | paired,
//    error:   a sentence for the user, "" when none,
//    link:    what the user last entered or was handed, kept after a failure,
//             "" once paired,
//    origin:  the paired MC's origin, "" when unpaired,
//    label:   the paired MC's label from its descriptor, "" when unpaired,
//    adding:  a paired device shows the pairing screen, to pair with another,
//    offered: the address `link` would pair with, while it is a link from
//             outside the app that waits for the user; "" otherwise}
// How the connection to a paired MC is doing is `connection`
// (ConnectionHealthController), which also pairs again with an MC that refused
// the session (`connection.pair`): the session that buys is remembered here too.
//
// Actions: `pairing.pair {link}` and `pairing.forget`, the way back out: the
// session is deleted from this device, the connection closes, and the shell
// shows nothing of the environment. `pairing.askToForget` is what the user's
// own button dispatches: the shell's question first (MenuController, the
// ConfirmDialog brick), which needs no connection, then `pairing.forget`.
// `pairing.add` brings the pairing screen up on a paired device and
// `pairing.cancel` takes it away again, the environment it has untouched
// (not while a link is being spent).
//
// A link from outside the app (openLink) is anybody's: a web page or a QR
// code can hold one. It is never paired with by itself. It is put in the
// pairing screen's field with the address it leads to (`offered`), in the
// place of a scanner left open (`scanner.close`), and the user's own
// `pairing.pair` is what spends it.
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

public slots:
  // A link the system opened the app with, as QDesktopServices hands it to
  // the handler of its scheme. Qt for Android calls that from Android's own
  // thread when the app is already running, so this only passes the link on
  // to the pairing's thread.
  void openLink(const QUrl& url);

public:

  // This device as an MC's client list should show it: "HAL-C2 on <model>",
  // what kind of device it is (a phone, a tablet, or a laptop, which the MC
  // lists as a desktop), and its OS.
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
  // A link from outside the app: shown, never spent.
  void offer(const QString& received);
  void add();
  void cancel();
  void paired(const pairing::Result& result);
  void askToForget();
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
  bool m_adding = false;
  QString m_offered;
};
