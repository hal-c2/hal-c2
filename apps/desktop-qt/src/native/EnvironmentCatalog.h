#pragma once

#include <QDateTime>
#include <QList>
#include <QString>
#include <QUrl>

#include <optional>

class SecretStore;

// The environments a client saved by pairing with them, beside the one it
// starts with (the desktop's own MC, the phone's first pairing).
//
// The records sit in one file, `saved-environments.json` in the app's data
// directory: each one's id, label, origin and when its credential expires.
// The credentials themselves never do: they go to the SecretStore, under the
// environment's id. A record is saved only once its credential is kept, so a
// store that refuses leaves nothing listed.
//
// A record file the client cannot read is not overwritten: it is moved aside
// (`saved-environments.json.damaged-<UTC time>`), for someone to inspect, and
// an empty one is written in its place, so the app starts with none and can
// pair again. A record the file lists without an address, or one whose
// credential the store no longer has, is still listed, but connecting to it
// is blocked with what is missing (connect()).
struct SavedEnvironment {
  QString id;
  QString label;
  QUrl origin;
  // When the credential runs out; invalid when it never does or is unknown.
  QDateTime expiresAt;
  // Whether the record says where the environment is.
  bool complete() const { return !id.isEmpty() && origin.isValid() && !origin.host().isEmpty(); }
  bool operator==(const SavedEnvironment&) const = default;
};

class EnvironmentCatalog {
public:
  // `secrets` outlives the catalog.
  EnvironmentCatalog(const QString& path, SecretStore* secrets);

  // Reads the record file again. A damaged one is moved aside (damaged()).
  void load();
  QList<SavedEnvironment> environments() const { return m_environments; }
  std::optional<SavedEnvironment> find(const QString& id) const;
  // Keeps the credential, then the record, in the place of any of the same
  // id. Nothing when saved; else why not, for the user, and nothing changed.
  std::optional<QString> save(const SavedEnvironment& environment, const QString& credential);
  // The record and the credential both go.
  void forget(const QString& id);
  // A renewed credential runs out at `expiresAt`.
  void setExpiry(const QString& id, const QDateTime& expiresAt);

  // What connecting to `id` takes: its record and credential, or why it is
  // blocked ("Connection profile <id> is unavailable." when the record is
  // gone, "Connection credential <id> is unavailable." when the credential is).
  struct Connection {
    SavedEnvironment environment;
    QString credential;
    QString blocked;
  };
  Connection connect(const QString& id) const;

  // Where the last damaged record file was moved to; empty when none was.
  QString damaged() const { return m_damaged; }
  QString path() const { return m_path; }

  static QString profileMissing(const QString& id) { return QStringLiteral("Connection profile %1 is unavailable.").arg(id); }
  static QString credentialMissing(const QString& id) { return QStringLiteral("Connection credential %1 is unavailable.").arg(id); }

private:
  bool write();

  QString m_path;
  SecretStore* m_secrets;
  QList<SavedEnvironment> m_environments;
  QString m_damaged;
};
