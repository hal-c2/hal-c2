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
  // Qt for Android ships no TLS of its own: without one bundled, no https link pairs.
  if (!QSslSocket::supportsSsl()) qWarning("[pairing] this build has no TLS: https and wss addresses cannot be reached");
  load();
  publish();
}

void Pairing::start() {
  if (m_paired) m_shell->open(m_paired->origin, m_paired->token);
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
    askToForget();
  } else if (action == QLatin1String("pairing.forget")) {
    forget();
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
  const Environment next{result.origin, result.token, result.descriptor.value(QLatin1String("label")).toString(), environmentId};
  // On the device first: a session that is only in memory is gone at the
  // next start, and the one it replaced would be opened in its place. The
  // link is spent by now, and the session it bought is left with the MC.
  if (!save(next)) {
    m_error = tr("This environment could not be paired: its session could not be saved on this device. The link is used now, so ask the environment "
                 "for a fresh one.");
    publish();
    return;
  }
  if (!m_paired) {
    // Nothing to leave.
  } else if (m_paired->environmentId == environmentId) {
    // The same environment with a new session: what the shell shows of it stays.
    m_shell->client()->close();
  } else {
    m_shell->close();
  }
  m_paired = next;
  m_saved = true;
  m_adding = false;
  m_link.clear();
  m_offered.clear();
  m_error.clear();
  publish();
  m_shell->open(result.origin, result.token);
}

void Pairing::askToForget() {
  if (!m_paired) return;
  m_shell->controller<MenuController>()->confirm(
      tr("Forget %1?").arg(m_paired->label.isEmpty() ? tr("this environment") : m_paired->label),
      tr("This device signs out of the environment and stops showing its projects and threads. Nothing on the environment is deleted. Pair again "
         "with a fresh pairing link to come back."),
      tr("Forget"), true, [this] { forget(); });
}

void Pairing::forget() {
  // An exchange in flight has nobody to answer.
  ++m_attempt;
  m_pairing = false;
  // The session goes from the device first: one that stays would be opened
  // again at the next start, whatever the app says now.
  if (QFile::exists(m_path) && !QFile::remove(m_path)) {
    qWarning("pairing not forgotten: %s", qPrintable(m_path));
    m_error = tr("This environment could not be forgotten: its session could not be deleted from this device.");
    publish();
    return;
  }
  if (m_paired) m_shell->close();
  m_paired.reset();
  m_adding = false;
  m_link.clear();
  m_offered.clear();
  m_error.clear();
  publish();
}

void Pairing::remember(const QUrl& origin, const QString& token) {
  Environment next{origin, token, {}, {}};
  // A new session at the same address is the same MC until it says otherwise.
  if (m_paired && m_paired->origin == origin) {
    next.label = m_paired->label;
    next.environmentId = m_paired->environmentId;
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
                                saved.value(QLatin1String("label")).toString(), saved.value(QLatin1String("environmentId")).toString()};
  if (environment.origin.isValid() && !environment.origin.host().isEmpty() && !environment.token.isEmpty()) m_paired = environment;
}

bool Pairing::save(const Environment& environment) {
  QDir().mkpath(QFileInfo(m_path).absolutePath());
  QSaveFile file(m_path);
  const QJsonObject saved{{QStringLiteral("origin"), environment.origin.toString()},
                          {QStringLiteral("token"), environment.token},
                          {QStringLiteral("label"), environment.label},
                          {QStringLiteral("environmentId"), environment.environmentId}};
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
  const QString address = result.origin.authority();
  switch (result.outcome) {
    case pairing::Outcome::Unreachable:
      return tr("The environment at %1 could not be reached. Check the address, and that this device is on its network.").arg(address);
    case pairing::Outcome::NotMc:
      return tr("%1 answered, but it is not a HAL-C2 environment. Check the address.").arg(address);
    case pairing::Outcome::Incompatible: {
      QString label = result.descriptor.value(QLatin1String("label")).toString();
      if (label.isEmpty()) label = address;
      const bool appIsOlder = result.descriptor.value(QLatin1String("orchestrationProtocolVersion")).toInt() > McClient::kProtocol;
      return appIsOlder ? tr("This app is too old for %1. Update the app: the two need compatible versions of HAL-C2.").arg(label)
                        : tr("%1 runs an older HAL-C2 than this app. Update it: the two need compatible versions of HAL-C2.").arg(label);
    }
    case pairing::Outcome::Refused:
      return tr("Pairing failed: the link was already used or has expired. Ask the environment for a fresh one.");
    case pairing::Outcome::Paired:
      break;
  }
  return {};
}
