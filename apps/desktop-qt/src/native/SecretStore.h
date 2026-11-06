#pragma once

#include <QHash>
#include <QString>

#include <memory>
#include <optional>

// Where a client keeps the credentials of the environments it saved
// (EnvironmentCatalog), out of its own files: the system's secure storage.
//
// - Linux: the Secret Service (GNOME Keyring, KWallet, KeePassXC) over the
//   D-Bus the shell already links, so no new library ships.
// - macOS: the login Keychain. Windows: the Credential Manager.
// - Android: the app's private storage, a file only the app can read, until
//   the Keystore is used (hal-c2/hal-c2#1075).
//
// A desktop without any of those gets one that refuses every write: a
// credential is never written to disk in the clear.
class SecretStore {
public:
  virtual ~SecretStore() = default;

  // Keeps `secret` under `key`; false with `error` set when the store refuses.
  virtual bool write(const QString& key, const QString& secret, QString* error) = 0;
  // Nothing when the store has none under `key`, or cannot be read.
  virtual std::optional<QString> read(const QString& key) = 0;
  virtual void remove(const QString& key) = 0;
  // The user asked for a credential (Retry): a store whose unlock they
  // refused may ask them again. Reads otherwise do not ask twice.
  virtual void ask() {}

  // This system's store; `privateDir` is the app's own data directory, used
  // only where the system has no secure storage the app can reach (Android).
  static std::unique_ptr<SecretStore> system(const QString& privateDir);
};

// Refuses to keep anything: a system without secure storage.
class UnavailableSecretStore : public SecretStore {
public:
  explicit UnavailableSecretStore(QString why = {}) : m_why(std::move(why)) {}
  bool write(const QString&, const QString&, QString* error) override {
    if (error) *error = m_why.isEmpty() ? QStringLiteral("This system has no secure storage for credentials.") : m_why;
    return false;
  }
  std::optional<QString> read(const QString&) override { return std::nullopt; }
  void remove(const QString&) override {}

private:
  QString m_why;
};

// Keeps secrets in memory, for tests: one `Keys` shared between stores is the
// same keyring across a restart, and `refusing` turns it into one that is not
// available to the app.
class MemorySecretStore : public SecretStore {
public:
  struct Keys {
    QHash<QString, QString> secrets;
    bool refusing = false;
  };
  explicit MemorySecretStore(std::shared_ptr<Keys> keys = std::make_shared<Keys>()) : m_keys(std::move(keys)) {}
  bool write(const QString& key, const QString& secret, QString* error) override {
    if (m_keys->refusing) {
      if (error) *error = QStringLiteral("The system's secure storage is not available.");
      return false;
    }
    m_keys->secrets.insert(key, secret);
    return true;
  }
  std::optional<QString> read(const QString& key) override {
    if (m_keys->refusing) return std::nullopt;
    const auto it = m_keys->secrets.constFind(key);
    return it == m_keys->secrets.cend() ? std::nullopt : std::optional<QString>(*it);
  }
  void remove(const QString& key) override { m_keys->secrets.remove(key); }
  std::shared_ptr<Keys> keys() const { return m_keys; }

private:
  std::shared_ptr<Keys> m_keys;
};
