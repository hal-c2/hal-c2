#pragma once

#include <QHash>
#include <QObject>
#include <QVariantMap>

#include <functional>
#include <map>
#include <memory>

#include "EnvironmentCatalog.h"
#include "NativeController.h"
#include "PairingExchange.h"

class McClient;
class QNetworkAccessManager;
class SecretStore;
class ShellBridge;
class ShellStore;

// The environments the user paired this client with beside the one it starts
// with (the desktop's own MC), each on a connection of its own: one that
// refuses this client, or cannot be reached, stops or retries alone while the
// others stay connected. Their records and credentials are the
// EnvironmentCatalog's; their projects and threads join the shell's
// (ShellStore::addLink), and the shell's client routes calls about them to
// their connection (McClient::setRoute).
//
// Publishes `savedEnvironments`:
//   {environments: [{id, label, origin, state: connecting | connected |
//                    reconnecting | offline | refused | blocked | closed,
//                    message: why it is not connected, "" when it is}],
//    pairing: a link is being spent, error: why the last pairing failed, "" if
//    it did not, damaged: where a damaged record file was set aside, "" if none}
// Actions: `savedEnvironments.pair {link}` pairs with the MC a pairing link
// names and saves it (nothing is listed when its credential cannot be kept);
// `savedEnvironments.remove {id}`, the way back out: its connection closes and
// its record, credential and everything the client kept of it go;
// `savedEnvironments.retry {id}` tries one again now.
class SavedEnvironmentsController : public QObject, public NativeController {
  Q_OBJECT

public:
  SavedEnvironmentsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~SavedEnvironmentsController() override;

  void activate() override {}
  bool handle(const QString& action, const QVariant& payload) override;

  // Reads the catalog in `dataDir` and connects to every saved environment.
  void start(const QString& dataDir);
  // What the MCs list this client as when it pairs.
  void setDevice(const pairing::Client& device) { m_device = device; }
  // The secure storage every later start() uses; the system's (SecretStore::system)
  // unless tests say.
  static void setSecretStoreFactory(std::function<std::unique_ptr<SecretStore>(const QString& dataDir)> factory);

  EnvironmentCatalog* catalog() const { return m_catalog.get(); }
  // The connection to a saved environment; null while it has none (blocked
  // before connecting, or not saved).
  McClient* client(const QString& id) const;
  // Its entry as `savedEnvironments` lists it.
  QVariantMap status(const QString& id) const;
  // Connects to `id` as the catalog has it now, replacing any connection it had.
  void connectTo(const QString& id);
  // Pairs with the MC the link names and saves it; `done` gets why it failed,
  // or nothing.
  void pair(const QString& link, std::function<void(const QString& error)> done = {});
  void remove(const QString& id);

signals:
  void changed();

private:
  struct Link {
    std::unique_ptr<McClient> client;
    // Why it is not connected when it never could be (EnvironmentCatalog::connect).
    QString blocked;
  };
  void disconnect(const QString& id, bool forget);
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::unique_ptr<SecretStore> m_secrets;
  std::unique_ptr<EnvironmentCatalog> m_catalog;
  std::map<QString, Link> m_links;
  QNetworkAccessManager* m_http = nullptr;
  pairing::Client m_device;
  quint64 m_attempt = 0;
  bool m_pairing = false;
  QString m_error;
};
