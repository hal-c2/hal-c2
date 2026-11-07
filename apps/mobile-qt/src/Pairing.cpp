#include "Pairing.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QSaveFile>
#include <QSslSocket>
#include <QSysInfo>
#include <QVariantMap>
#include <QtLogging>

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QJniObject>
#endif

#include "ConnectionHealthController.h"
#include "McClient.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "SavedEnvironmentsController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("pairing");

}  // namespace

Pairing::Pairing(ShellBridge* bridge, NativeShell* shell, const QString& dataDir, const pairing::Client& device, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_shell(shell),
      m_path(QDir(dataDir).filePath(QStringLiteral("pairing.json"))),
      m_device(device),
      m_http(new QNetworkAccessManager(this)) {
  bridge->declareKey(kKey);
  // The bridge keeps its interceptors for good.
  bridge->addInterceptor([self = QPointer<Pairing>(this)](const QString& action, const QVariant& payload) {
    return self && self->handle(action, payload);
  });
  // Pairing again with an MC that refused the session says the same of this device.
  if (auto* health = shell->shared<ConnectionHealthController>()) health->setPairingClient(device);
  connect(shell, &NativeShell::opened, this, &Pairing::remember);
  connect(shell->client(), &McClient::readyChanged, this, [this](bool ready) {
    if (ready) describe();
  });
  // A renewed session lasts longer; the next start renews by the new date.
  connect(shell->client(), &McClient::credentialRenewed, this, [this](const QDateTime& expiresAt) {
    if (!m_paired || m_paired->expiresAt == expiresAt) return;
    m_paired->expiresAt = expiresAt;
    m_saved = save(*m_paired);
  });
  // Qt for Android ships no TLS of its own: without one bundled, no https link pairs.
  if (!QSslSocket::supportsSsl()) qWarning("[pairing] this build has no TLS: https and wss addresses cannot be reached");
  load();
  publish();
}

void Pairing::start() {
  // One the device kept beside a forgotten one it could not yet put in its place.
  if (!m_paired) {
    promote();
    return;
  }
  // The environment it paired with, not whichever answers at its address now.
  m_shell->client()->setCredentialExpiry(m_paired->expiresAt);
  m_shell->open(m_paired->origin, m_paired->token, m_paired->environmentId);
}

pairing::Client Pairing::thisDevice() {
  QString kind = QStringLiteral("mobile");
#if defined(Q_OS_ANDROID)
  const QString model = QJniObject::getStaticObjectField("android/os/Build", "MODEL", "Ljava/lang/String;").toString();
  const QString os = QStringLiteral("Android");
  // A laptop says it is a PC (PackageManager.FEATURE_PC), and a tablet's
  // shorter side is 600 dp or more, as Android's own sw600dp resources have it.
  const QJniObject context = QNativeInterface::QAndroidApplication::context();
  if (context.isValid()) {
    const QJniObject pc = QJniObject::fromString(QStringLiteral("android.hardware.type.pc"));
    const QJniObject packages = context.callObjectMethod("getPackageManager", "()Landroid/content/pm/PackageManager;");
    const QJniObject configuration = context.callObjectMethod("getResources", "()Landroid/content/res/Resources;")
                                         .callObjectMethod("getConfiguration", "()Landroid/content/res/Configuration;");
    if (packages.callMethod<jboolean>("hasSystemFeature", "(Ljava/lang/String;)Z", pc.object<jstring>())) {
      kind = QStringLiteral("desktop");
    } else if (configuration.getField<jint>("smallestScreenWidthDp") >= 600) {
      kind = QStringLiteral("tablet");
    }
  }
#else
  const QString model = QSysInfo::machineHostName();
#if defined(Q_OS_IOS)
  const QString os = QStringLiteral("iOS");
#elif defined(Q_OS_MACOS)
  const QString os = QStringLiteral("macOS");
#elif defined(Q_OS_WIN)
  const QString os = QStringLiteral("Windows");
#else
  const QString os = QStringLiteral("Linux");
#endif
#endif
  return {model.trimmed().isEmpty() ? QStringLiteral("HAL-C2 mobile") : QStringLiteral("HAL-C2 on %1").arg(model.trimmed()), kind, os};
}

void Pairing::openLink(const QUrl& url) {
  QMetaObject::invokeMethod(this, [this, url] { offer(url.toString(QUrl::FullyEncoded)); }, Qt::QueuedConnection);
}

bool Pairing::handle(const QString& action, const QVariant& payload) {
  if (action == QLatin1String("pairing.pair")) {
    pair(payload.toMap().value(QStringLiteral("link")).toString());
  } else if (action == QLatin1String("pairing.add")) {
    add();
  } else if (action == QLatin1String("pairing.cancel")) {
    cancel();
  } else if (action == QLatin1String("pairing.askToForget")) {
    askToForget(payload.toMap().value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("pairing.forget")) {
    forget(payload.toMap().value(QStringLiteral("id")).toString());
  } else {
    return false;
  }
  return true;
}

void Pairing::offer(const QString& received) {
  // The user's own attempt is waiting for its answer.
  if (m_pairing) return;
  const auto invitation = pairing::readInvitation(received);
  if (!invitation) {
    const QString said = tr("The link that opened HAL-C2 is not a pairing link. Nothing was changed.");
    if (m_paired && !m_adding) {
      // No pairing screen to say it on.
      m_shell->controller<ToastController>()->show(QStringLiteral("warning"), tr("Not a pairing link"), said);
    } else {
      m_error = said;
      publish();
    }
    return;
  }
  m_link = invitation->link;
  m_offered = invitation->address;
  m_adding = m_paired.has_value();
  m_error.clear();
  publish();
  // It is the pairing screen's to show: not under a scanner left open.
  m_bridge->dispatch(QStringLiteral("scanner.close"));
}

void Pairing::add() {
  if (!m_paired || m_pairing || m_adding) return;
  m_adding = true;
  m_link.clear();
  m_offered.clear();
  m_error.clear();
  publish();
}

void Pairing::cancel() {
  // Not while a link is being spent: the session it buys is this device's,
  // and the answer is seconds away.
  if (!m_adding || m_pairing) return;
  m_adding = false;
  m_link.clear();
  m_offered.clear();
  m_error.clear();
  publish();
}

void Pairing::pair(const QString& link) {
  if (m_pairing) return;
  // The address was the offered link's, not that of what the user wrote over it.
  if (link.trimmed() != m_link) m_offered.clear();
  m_link = link;
  const auto read = pairing::readLink(link);
  if (!read) {
    m_error = tr("That is not a pairing link. Enter the link the environment gave you, with its token.");
    publish();
    return;
  }
  m_pairing = true;
  m_error.clear();
  publish();
  pairing::exchange(m_http, this, *read, m_device, [this, attempt = ++m_attempt](const pairing::Result& result) {
    if (attempt != m_attempt) return;
    m_pairing = false;
    if (result.outcome == pairing::Outcome::Paired) return paired(result);
    m_error = explain(result);
    publish();
  });
}

void Pairing::paired(const pairing::Result& result) {
  const QString environmentId = result.descriptor.value(QLatin1String("environmentId")).toString();
  const Environment next{result.origin, result.token, result.descriptor.value(QLatin1String("label")).toString(), environmentId,
                         result.expiresAt};
  const QString notSaved = tr("This environment could not be paired: its session could not be saved on this device. The link is used now, so ask "
                              "the environment for a fresh one.");
  // An environment beside the one the shell connects to is on a connection of
  // its own (SavedEnvironmentsController), which keeps it before connecting.
  // One the device knew before it described itself is told by its address.
  const bool same = m_paired && (m_paired->environmentId.isEmpty() ? m_paired->origin == next.origin : m_paired->environmentId == environmentId);
  if (m_paired && !same) {
    auto* saved = m_shell->shared<SavedEnvironmentsController>();
    if (const auto refused = saved ? saved->add(result) : std::optional<QString>(tr("Saved environments are not available."))) {
      qWarning("pairing not saved beside the environment: %s", qPrintable(*refused));
      m_error = notSaved;
      publish();
      return;
    }
    m_adding = false;
    m_link.clear();
    m_offered.clear();
    m_error.clear();
    publish();
    return;
  }
  // On the device first: a session that is only in memory is gone at the
  // next start. The link is spent by now, and the session it bought is left
  // with the MC.
  if (!save(next)) {
    m_error = notSaved;
    publish();
    return;
  }
  // The same environment with a new session: what the shell shows of it stays.
  if (m_paired) m_shell->client()->close();
  const bool moved = m_paired && m_paired->origin != next.origin;
  // Nor is it listed beside itself.
  if (auto* saved = beside(environmentId)) saved->remove(environmentId);
  m_paired = next;
  m_saved = true;
  m_adding = false;
  m_link.clear();
  m_offered.clear();
  m_error.clear();
  publish();
  m_shell->client()->setCredentialExpiry(result.expiresAt);
  m_shell->open(result.origin, result.token);
  // At another address the shell's rows were emptied, the others' too: they are sent again.
  if (auto* saved = moved ? m_shell->shared<SavedEnvironmentsController>() : nullptr) saved->reconnect();
}

SavedEnvironmentsController* Pairing::beside(const QString& id) const {
  if (id.isEmpty() || (m_paired && m_paired->environmentId == id)) return nullptr;
  auto* saved = m_shell->shared<SavedEnvironmentsController>();
  return saved && saved->catalog() && saved->catalog()->find(id) ? saved : nullptr;
}

void Pairing::askToForget(const QString& id) {
  QString label;
  if (auto* saved = beside(id)) {
    label = saved->status(id).value(QStringLiteral("label")).toString();
  } else if (m_paired && (id.isEmpty() || id == m_paired->environmentId)) {
    label = m_paired->label;
  } else {
    return;
  }
  m_shell->controller<MenuController>()->confirm(
      tr("Forget %1?").arg(label.isEmpty() ? tr("this environment") : label),
      tr("This device signs out of the environment and stops showing its projects and threads. Nothing on the environment is deleted. Pair again "
         "with a fresh pairing link to come back."),
      tr("Forget"), true, [this, id] { forget(id); });
}

void Pairing::forget(const QString& id) {
  // One beside the shell's own goes alone, the others untouched.
  if (auto* saved = beside(id)) {
    saved->remove(id);
    m_error.clear();
    publish();
    return;
  }
  if (!id.isEmpty() && (!m_paired || id != m_paired->environmentId)) return;
  // The session goes from the device first: one that stays would be opened
  // again at the next start, whatever the app says now. Until it is gone,
  // nothing is forgotten, an exchange in flight included.
  if (QFile::exists(m_path) && !QFile::remove(m_path)) {
    qWarning("pairing not forgotten: %s", qPrintable(m_path));
    m_error = tr("This environment could not be forgotten: its session could not be deleted from this device.");
    publish();
    return;
  }
  // An exchange in flight has nobody to answer.
  ++m_attempt;
  m_pairing = false;
  emit forgetting();
  // The session is gone, so the environment is forgotten whatever follows;
  // what the device had kept of its threads may still be on disk.
  const bool closed = m_paired.has_value();
  const bool emptied = !closed || m_shell->close();
  m_paired.reset();
  m_adding = false;
  m_link.clear();
  m_offered.clear();
  m_error = emptied ? QString() : tr("The environment is forgotten, but what this device kept of its threads could not be deleted.");
  // One paired beside it takes its place, so the device stays paired while it has any.
  // With none to, the rows closing emptied, those beside it too, are sent again.
  auto* saved = m_shell->shared<SavedEnvironmentsController>();
  if (!promote() && closed && saved) saved->reconnect();
  publish();
}

bool Pairing::promote() {
  auto* saved = m_shell->shared<SavedEnvironmentsController>();
  EnvironmentCatalog* catalog = saved ? saved->catalog() : nullptr;
  if (m_paired || !catalog) return false;
  for (const SavedEnvironment& environment : catalog->environments()) {
    const EnvironmentCatalog::Connection connection = catalog->connect(environment.id);
    if (!connection.blocked.isEmpty()) continue;
    const Environment next{environment.origin, connection.credential, environment.label, environment.id, environment.expiresAt};
    // Kept as the shell's own before it leaves the saved ones: there is
    // always one place on the device it is in.
    if (!save(next)) return false;
    saved->remove(environment.id);
    m_paired = next;
    m_saved = true;
    m_shell->client()->setCredentialExpiry(next.expiresAt);
    m_shell->open(next.origin, next.token, next.environmentId);
    // Opening another MC emptied the shell's rows, the others' too: they are sent again.
    saved->reconnect();
    return true;
  }
  return false;
}

void Pairing::remember(const QUrl& origin, const QString& token) {
  Environment next{origin, token, {}, {}, {}};
  // A new session at the same address is the same MC until it says otherwise.
  if (m_paired && m_paired->origin == origin) {
    next.label = m_paired->label;
    next.environmentId = m_paired->environmentId;
    if (token == m_paired->token) next.expiresAt = m_paired->expiresAt;
  }
  if (m_paired == next) return;
  // The shell is connected with it already, so it is this device's session
  // whether or not it can be saved: the one on the device is the one the MC
  // refused, and is what the next start would open.
  m_paired = next;
  m_saved = save(next);
  if (!m_saved) {
    m_shell->controller<ToastController>()->show(
        QStringLiteral("warning"), tr("Session not saved"),
        tr("The new session with %1 could not be saved on this device. It stays connected, and may need a fresh pairing link the next time HAL-C2 "
           "starts.")
            .arg(next.label.isEmpty() ? tr("this environment") : next.label),
        {}, 0);
  }
  publish();
}

void Pairing::describe() {
  if (!m_paired) return;
  const McClient* client = m_shell->client();
  const QJsonObject descriptor = client->descriptor();
  Environment next = *m_paired;
  next.environmentId = client->environment();
  if (descriptor.value(QLatin1String("environmentId")).toString() == next.environmentId) {
    next.label = descriptor.value(QLatin1String("label")).toString();
  }
  if (m_paired == next && m_saved) return;
  // What the MC says of itself is shown whether or not it can be saved: the
  // device keeps it only to have something to show before the MC next
  // answers, and then this runs again. So the user is not told.
  m_paired = next;
  m_saved = save(next);
  publish();
}

void Pairing::load() {
  QFile file(m_path);
  if (!file.open(QIODevice::ReadOnly)) return;
  const QJsonObject saved = QJsonDocument::fromJson(file.readAll()).object();
  const Environment environment{QUrl(saved.value(QLatin1String("origin")).toString()), saved.value(QLatin1String("token")).toString(),
                                saved.value(QLatin1String("label")).toString(), saved.value(QLatin1String("environmentId")).toString(),
                                QDateTime::fromString(saved.value(QLatin1String("expiresAt")).toString(), Qt::ISODateWithMs)};
  if (environment.origin.isValid() && !environment.origin.host().isEmpty() && !environment.token.isEmpty()) m_paired = environment;
}

bool Pairing::save(const Environment& environment) {
  QDir().mkpath(QFileInfo(m_path).absolutePath());
  QSaveFile file(m_path);
  QJsonObject saved{{QStringLiteral("origin"), environment.origin.toString()},
                    {QStringLiteral("token"), environment.token},
                    {QStringLiteral("label"), environment.label},
                    {QStringLiteral("environmentId"), environment.environmentId}};
  if (environment.expiresAt.isValid()) saved.insert(QStringLiteral("expiresAt"), environment.expiresAt.toUTC().toString(Qt::ISODateWithMs));
  // The token is the session: nobody else on the device reads it.
  const bool done = file.open(QIODevice::WriteOnly) && file.setPermissions(QFile::ReadOwner | QFile::WriteOwner) &&
                    file.write(QJsonDocument(saved).toJson(QJsonDocument::Compact)) >= 0 && file.commit();
  if (!done) qWarning("pairing not saved: %s", qPrintable(file.errorString()));
  return done;
}

void Pairing::publish() {
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("phase"), m_pairing  ? QStringLiteral("pairing")
                                                        : m_paired ? QStringLiteral("paired")
                                                                   : QStringLiteral("unpaired")},
                              {QStringLiteral("error"), m_error},
                              {QStringLiteral("link"), m_link},
                              {QStringLiteral("origin"), m_paired ? m_paired->origin.toString() : QString()},
                              {QStringLiteral("label"), m_paired ? m_paired->label : QString()},
                              {QStringLiteral("adding"), m_adding},
                              {QStringLiteral("offered"), m_offered},
                          });
}

QString Pairing::explain(const pairing::Result& result) const {
  return pairing::explain(result);
}
