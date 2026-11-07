#include "SecretStore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>

#if defined(HAL_C2_HAS_DBUS)
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusReply>
#include <QDBusVariant>
#include <QEventLoop>
#include <QTimer>
#endif

#if defined(Q_OS_MACOS)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif

#if defined(Q_OS_WIN)
#include <windows.h>
#include <wincred.h>
#endif

namespace {

// What every store files a credential under.
[[maybe_unused]] const QString kService = QStringLiteral("HAL-C2");

#if defined(Q_OS_ANDROID)
// The app's private storage: a file in its own data directory that only it
// can read (Android's sandbox). Not used on a desktop, where a file the user's
// other programs can read counts as in the clear.
class PrivateFileSecretStore : public SecretStore {
public:
  explicit PrivateFileSecretStore(const QString& dir) : m_path(QDir(dir).filePath(QStringLiteral("credentials.json"))) {}
  bool write(const QString& key, const QString& secret, QString* error) override {
    QJsonObject all = readAll();
    all.insert(key, secret);
    return save(all, error);
  }
  std::optional<QString> read(const QString& key) override {
    const QJsonValue value = readAll().value(key);
    return value.isString() ? std::optional<QString>(value.toString()) : std::nullopt;
  }
  void remove(const QString& key) override {
    QJsonObject all = readAll();
    all.remove(key);
    save(all, nullptr);
  }

private:
  QJsonObject readAll() const {
    QFile file(m_path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(file.readAll()).object();
  }
  bool save(const QJsonObject& all, QString* error) const {
    QDir().mkpath(QFileInfo(m_path).absolutePath());
    QSaveFile file(m_path);
    if (!file.open(QIODevice::WriteOnly)) {
      if (error) *error = file.errorString();
      return false;
    }
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    file.write(QJsonDocument(all).toJson(QJsonDocument::Compact));
    if (!file.commit()) {
      if (error) *error = file.errorString();
      return false;
    }
    return true;
  }
  QString m_path;
};
#endif

}  // namespace

#if defined(HAL_C2_HAS_DBUS)
namespace {
// org.freedesktop.Secret.Secret: (session, parameters, value, content_type).
struct DbusSecret {
  QDBusObjectPath session;
  QByteArray parameters;
  QByteArray value;
  QString contentType;
};

QDBusArgument& operator<<(QDBusArgument& argument, const DbusSecret& secret) {
  argument.beginStructure();
  argument << secret.session << secret.parameters << secret.value << secret.contentType;
  argument.endStructure();
  return argument;
}

const QDBusArgument& operator>>(const QDBusArgument& argument, DbusSecret& secret) {
  argument.beginStructure();
  argument >> secret.session >> secret.parameters >> secret.value >> secret.contentType;
  argument.endStructure();
  return argument;
}

}  // namespace

Q_DECLARE_METATYPE(DbusSecret)

namespace {

using Attributes = QMap<QString, QString>;

// The Secret Service (freedesktop.org) on the session bus, in the user's
// default collection. The secret crosses the bus to the keyring daemon in the
// `plain` transport, as libsecret's default does; the daemon keeps it
// encrypted on disk.
class SecretServiceStore : public SecretStore {
public:
  SecretServiceStore() {
    qDBusRegisterMetaType<DbusSecret>();
    qDBusRegisterMetaType<Attributes>();
  }

  bool write(const QString& key, const QString& secret, QString* error) override {
    // Pairing is the user's own act: it may ask to unlock again.
    m_refused = false;
    QString why;
    const QDBusObjectPath collection = defaultCollection(&why);
    if (collection.path().isEmpty() || !unlock({collection}, &why) || !openSession(&why)) {
      if (error) *error = why;
      return false;
    }
    QDBusInterface target(kBus, collection.path(), QStringLiteral("org.freedesktop.Secret.Collection"), bus());
    QVariantMap properties{{QStringLiteral("org.freedesktop.Secret.Item.Label"), QStringLiteral("HAL-C2 environment %1").arg(key)},
                           {QStringLiteral("org.freedesktop.Secret.Item.Attributes"), QVariant::fromValue(attributes(key))}};
    const DbusSecret value{m_session, {}, secret.toUtf8(), QStringLiteral("text/plain")};
    QDBusMessage reply = target.call(QStringLiteral("CreateItem"), properties, QVariant::fromValue(value), true);
    if (reply.type() == QDBusMessage::ErrorMessage) {
      if (error) *error = reply.errorMessage();
      return false;
    }
    runPrompt(qdbus_cast<QDBusObjectPath>(reply.arguments().value(1)));
    if (search(key).isEmpty()) {
      if (error) *error = QStringLiteral("The system's keyring did not keep the credential.");
      return false;
    }
    return true;
  }

  std::optional<QString> read(const QString& key) override {
    // One refused unlock answers for every read after it: the saved
    // environments read at start ask once, not once each.
    if (m_refused) return std::nullopt;
    QString why;
    const QList<QDBusObjectPath> items = search(key);
    if (items.isEmpty()) return std::nullopt;
    if (!unlock(items, &why)) {
      m_refused = true;
      return std::nullopt;
    }
    if (!openSession(&why)) return std::nullopt;
    QDBusInterface item(kBus, items.first().path(), QStringLiteral("org.freedesktop.Secret.Item"), bus());
    QDBusMessage reply = item.call(QStringLiteral("GetSecret"), QVariant::fromValue(m_session));
    if (reply.type() == QDBusMessage::ErrorMessage || reply.arguments().isEmpty()) return std::nullopt;
    const DbusSecret secret = qdbus_cast<DbusSecret>(reply.arguments().first());
    return QString::fromUtf8(secret.value);
  }

  void remove(const QString& key) override {
    for (const QDBusObjectPath& path : search(key)) {
      QDBusInterface item(kBus, path.path(), QStringLiteral("org.freedesktop.Secret.Item"), bus());
      QDBusMessage reply = item.call(QStringLiteral("Delete"));
      if (reply.type() != QDBusMessage::ErrorMessage) runPrompt(qdbus_cast<QDBusObjectPath>(reply.arguments().value(0)));
    }
  }

  void ask() override { m_refused = false; }

  // Whether a Secret Service answers on the session bus.
  static bool available() {
    const QDBusConnection connection = QDBusConnection::sessionBus();
    return connection.isConnected() && connection.interface() && connection.interface()->isServiceRegistered(kBus).value();
  }

private:
  static inline const QString kBus = QStringLiteral("org.freedesktop.secrets");
  static inline const QString kServicePath = QStringLiteral("/org/freedesktop/secrets");

  static QDBusConnection bus() { return QDBusConnection::sessionBus(); }

  static Attributes attributes(const QString& key) { return {{QStringLiteral("application"), kService}, {QStringLiteral("environment"), key}}; }

  QDBusInterface service() const { return QDBusInterface(kBus, kServicePath, QStringLiteral("org.freedesktop.Secret.Service"), bus()); }

  bool openSession(QString* error) {
    if (!m_session.path().isEmpty()) return true;
    QDBusInterface target = service();
    QDBusMessage reply = target.call(QStringLiteral("OpenSession"), QStringLiteral("plain"), QVariant::fromValue(QDBusVariant(QString())));
    if (reply.type() == QDBusMessage::ErrorMessage) {
      if (error) *error = reply.errorMessage();
      return false;
    }
    m_session = qdbus_cast<QDBusObjectPath>(reply.arguments().value(1));
    return true;
  }

  QDBusObjectPath defaultCollection(QString* error) const {
    QDBusInterface target = service();
    QDBusReply<QDBusObjectPath> reply = target.call(QStringLiteral("ReadAlias"), QStringLiteral("default"));
    if (!reply.isValid()) {
      if (error) *error = reply.error().message();
      return {};
    }
    if (reply.value().path() == QLatin1String("/")) {
      if (error) *error = QStringLiteral("The system's keyring has no default collection.");
      return {};
    }
    return reply.value();
  }

  QList<QDBusObjectPath> search(const QString& key) const {
    QDBusInterface target = service();
    QDBusMessage reply = target.call(QStringLiteral("SearchItems"), QVariant::fromValue(attributes(key)));
    if (reply.type() == QDBusMessage::ErrorMessage) return {};
    QList<QDBusObjectPath> items = qdbus_cast<QList<QDBusObjectPath>>(reply.arguments().value(0));
    items += qdbus_cast<QList<QDBusObjectPath>>(reply.arguments().value(1));
    return items;
  }

  bool unlock(const QList<QDBusObjectPath>& objects, QString* error) const {
    QDBusInterface target = service();
    QDBusMessage reply = target.call(QStringLiteral("Unlock"), QVariant::fromValue(objects));
    if (reply.type() == QDBusMessage::ErrorMessage) {
      if (error) *error = reply.errorMessage();
      return false;
    }
    runPrompt(qdbus_cast<QDBusObjectPath>(reply.arguments().value(1)));
    for (const QDBusObjectPath& object : objects) {
      const bool collection = object.path().startsWith(QLatin1String("/org/freedesktop/secrets/aliases/")) ||
                              object.path().startsWith(QLatin1String("/org/freedesktop/secrets/collection/")) && object.path().count(QLatin1Char('/')) == 4;
      if (locked(object, collection ? QStringLiteral("org.freedesktop.Secret.Collection") : QStringLiteral("org.freedesktop.Secret.Item"))) {
        if (error) *error = QStringLiteral("The system's keyring was not unlocked.");
        return false;
      }
    }
    return true;
  }

  // The keyring asks the user (to unlock it, say): waits up to two minutes for
  // the prompt to finish. "/" is no prompt at all. Callers check what it did.
  static void runPrompt(const QDBusObjectPath& prompt) {
    if (prompt.path().isEmpty() || prompt.path() == QLatin1String("/")) return;
    QEventLoop loop;
    bus().connect(kBus, prompt.path(), QStringLiteral("org.freedesktop.Secret.Prompt"), QStringLiteral("Completed"), &loop, SLOT(quit()));
    QDBusInterface target(kBus, prompt.path(), QStringLiteral("org.freedesktop.Secret.Prompt"), bus());
    if (target.call(QStringLiteral("Prompt"), QString()).type() == QDBusMessage::ErrorMessage) return;
    QTimer::singleShot(120000, &loop, &QEventLoop::quit);
    loop.exec(QEventLoop::ExcludeUserInputEvents);
  }

  static bool locked(const QDBusObjectPath& object, const QString& interface) {
    QDBusInterface target(kBus, object.path(), interface, bus());
    return target.property("Locked").toBool();
  }

  QDBusObjectPath m_session;
  bool m_refused = false;
};

}  // namespace

#endif

#if defined(Q_OS_MACOS) && !defined(Q_OS_IOS)
namespace {

// The login Keychain, as generic passwords of the service "HAL-C2".
class KeychainSecretStore : public SecretStore {
public:
  bool write(const QString& key, const QString& secret, QString* error) override {
    remove(key);
    const QByteArray account = key.toUtf8();
    const QByteArray value = secret.toUtf8();
    const QByteArray service = kService.toUtf8();
    CFStringRef serviceRef = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(service.constData()), service.size(), kCFStringEncodingUTF8, false);
    CFStringRef accountRef = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(account.constData()), account.size(), kCFStringEncodingUTF8, false);
    CFDataRef valueRef = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(value.constData()), value.size());
    const void* keys[] = {kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData};
    const void* values[] = {kSecClassGenericPassword, serviceRef, accountRef, valueRef};
    CFDictionaryRef query = CFDictionaryCreate(nullptr, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const OSStatus status = SecItemAdd(query, nullptr);
    CFRelease(query);
    CFRelease(valueRef);
    CFRelease(accountRef);
    CFRelease(serviceRef);
    if (status == errSecSuccess) return true;
    if (error) *error = QStringLiteral("The Keychain refused the credential (%1).").arg(status);
    return false;
  }

  std::optional<QString> read(const QString& key) override {
    CFDictionaryRef query = lookup(key, true);
    CFTypeRef result = nullptr;
    const OSStatus status = SecItemCopyMatching(query, &result);
    CFRelease(query);
    if (status != errSecSuccess || !result) return std::nullopt;
    const auto* data = static_cast<CFDataRef>(result);
    const QString secret = QString::fromUtf8(reinterpret_cast<const char*>(CFDataGetBytePtr(data)), CFDataGetLength(data));
    CFRelease(result);
    return secret;
  }

  void remove(const QString& key) override {
    CFDictionaryRef query = lookup(key, false);
    SecItemDelete(query);
    CFRelease(query);
  }

private:
  static CFDictionaryRef lookup(const QString& key, bool data) {
    const QByteArray account = key.toUtf8();
    const QByteArray service = kService.toUtf8();
    CFStringRef serviceRef = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(service.constData()), service.size(), kCFStringEncodingUTF8, false);
    CFStringRef accountRef = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(account.constData()), account.size(), kCFStringEncodingUTF8, false);
    const void* keys[] = {kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit};
    const void* values[] = {kSecClassGenericPassword, serviceRef, accountRef, kCFBooleanTrue, kSecMatchLimitOne};
    CFDictionaryRef query = CFDictionaryCreate(nullptr, keys, values, data ? 5 : 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(accountRef);
    CFRelease(serviceRef);
    return query;
  }
};

}  // namespace
#endif

#if defined(Q_OS_WIN)
namespace {

// The Windows Credential Manager, as generic credentials "HAL-C2:<key>".
class CredentialManagerSecretStore : public SecretStore {
public:
  bool write(const QString& key, const QString& secret, QString* error) override {
    const std::wstring target = (kService + QLatin1Char(':') + key).toStdWString();
    const QByteArray blob = secret.toUtf8();
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<LPWSTR>(target.c_str());
    credential.CredentialBlobSize = DWORD(blob.size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(blob.constData()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (CredWriteW(&credential, 0)) return true;
    if (error) *error = QStringLiteral("The Credential Manager refused the credential (%1).").arg(GetLastError());
    return false;
  }

  std::optional<QString> read(const QString& key) override {
    const std::wstring target = (kService + QLatin1Char(':') + key).toStdWString();
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) return std::nullopt;
    const QString secret = QString::fromUtf8(reinterpret_cast<const char*>(credential->CredentialBlob), int(credential->CredentialBlobSize));
    CredFree(credential);
    return secret;
  }

  void remove(const QString& key) override {
    const std::wstring target = (kService + QLatin1Char(':') + key).toStdWString();
    CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
  }
};

}  // namespace
#endif

std::unique_ptr<SecretStore> SecretStore::system(const QString& privateDir) {
#if defined(Q_OS_ANDROID)
  return std::make_unique<PrivateFileSecretStore>(privateDir);
#else
  Q_UNUSED(privateDir);
#if defined(Q_OS_MACOS) && !defined(Q_OS_IOS)
  return std::make_unique<KeychainSecretStore>();
#elif defined(Q_OS_WIN)
  return std::make_unique<CredentialManagerSecretStore>();
#else
#if defined(HAL_C2_HAS_DBUS)
  if (SecretServiceStore::available()) return std::make_unique<SecretServiceStore>();
#endif
  return std::make_unique<UnavailableSecretStore>(
      QStringLiteral("No keyring answers on this desktop (the Secret Service: GNOME Keyring, KWallet or KeePassXC)."));
#endif
#endif
}
