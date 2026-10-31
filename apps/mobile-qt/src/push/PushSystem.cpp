#include "PushSystem.h"

#include <QDateTime>

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#include <QJsonDocument>
#include <QPointer>
#include <QtCore/private/qandroidextras_p.h>

#include "PushInbox.h"
#endif

namespace {

// A build that cannot receive pushes: off Android, where no distributor runs.
class Unsupported final : public PushSystem {
public:
  bool supported() override { return false; }
  int sdk() override { return 0; }
  Permission permission() override { return Permission::Denied; }
  void requestPermission(QObject*, std::function<void(Permission)> answered) override { answered(Permission::Denied); }
  void openSettings() override {}
  void openLiveUpdateSettings() override {}
  QList<Distributor> distributors() override { return {}; }
  void subscribe(const QString&) override {}
  void unsubscribe() override {}
  void show(const QJsonObject&) override {}
  qint64 now() override { return QDateTime::currentMSecsSinceEpoch(); }
};

#ifdef Q_OS_ANDROID

constexpr const char* kPush = "io/github/halc2/mobile/Push";
const QString kPermission = QStringLiteral("android.permission.POST_NOTIFICATIONS");

QJniObject context() { return QNativeInterface::QAndroidApplication::context(); }

// Android's notifications and UnifiedPush, through Push.java. The endpoint a
// distributor gives reaches PushReceiver.java, which writes it to the inbox
// and calls Java_..._endpointChanged below.
class Android final : public PushSystem {
public:
  Android() { s_current = this; }
  ~Android() override { s_current = nullptr; }

  bool supported() override { return true; }
  int sdk() override { return QNativeInterface::QAndroidApplication::sdkVersion(); }
  Permission permission() override {
    // Below Android 13 the permission is granted at install, and the user
    // turns notifications off in the settings.
    const bool enabled = QJniObject::callStaticMethod<jboolean>(kPush, "enabled", "(Landroid/content/Context;)Z", context().object());
    if (enabled) return Permission::Granted;
    if (sdk() < 33) return Permission::Denied;
    return QtAndroidPrivate::checkPermission(kPermission).result() == QtAndroidPrivate::Denied ? Permission::Denied : Permission::Ask;
  }
  void requestPermission(QObject* context, std::function<void(Permission)> answered) override {
    if (sdk() < 33) {
      answered(permission());
      return;
    }
    QtAndroidPrivate::requestPermission(kPermission).then(context, [this, answered = std::move(answered)](QtAndroidPrivate::PermissionResult) {
      answered(permission());
    });
  }
  void openSettings() override { QJniObject::callStaticMethod<void>(kPush, "openSettings", "(Landroid/content/Context;)V", context().object()); }
  void openLiveUpdateSettings() override {
    QJniObject::callStaticMethod<void>(kPush, "openLiveUpdateSettings", "(Landroid/content/Context;)V", context().object());
  }
  QList<Distributor> distributors() override {
    // "id\tlabel" per line.
    const QString listed =
        QJniObject::callStaticObjectMethod(kPush, "distributors", "(Landroid/content/Context;)Ljava/lang/String;", context().object()).toString();
    QList<Distributor> found;
    for (const QString& line : listed.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
      const qsizetype tab = line.indexOf(QLatin1Char('\t'));
      found.append({line.left(tab), tab < 0 ? line : line.mid(tab + 1)});
    }
    return found;
  }
  void subscribe(const QString& distributor) override {
    QJniObject::callStaticMethod<void>(kPush, "subscribe", "(Landroid/content/Context;Ljava/lang/String;)V", context().object(),
                                       QJniObject::fromString(distributor).object<jstring>());
  }
  void unsubscribe() override { QJniObject::callStaticMethod<void>(kPush, "unsubscribe", "(Landroid/content/Context;)V", context().object()); }
  void show(const QJsonObject& effects) override {
    const QString json = QString::fromUtf8(QJsonDocument(effects).toJson(QJsonDocument::Compact));
    QJniObject::callStaticMethod<void>(kPush, "show", "(Landroid/content/Context;Ljava/lang/String;)V", context().object(),
                                       QJniObject::fromString(json).object<jstring>());
  }
  qint64 now() override { return QDateTime::currentMSecsSinceEpoch(); }

  static inline Android* s_current = nullptr;
};

#endif

}  // namespace

std::shared_ptr<PushSystem> devicePushSystem(const QString& dataDir) {
  Q_UNUSED(dataDir);
#ifdef Q_OS_ANDROID
  return std::make_shared<Android>();
#else
  return std::make_shared<Unsupported>();
#endif
}

#ifdef Q_OS_ANDROID

// What PushReceiver.java and DismissReceiver.java call, whether the app is
// running or the system started the process for them alone: the inbox's
// answer, as JSON, which Push.show renders.
namespace {

QString string(JNIEnv* env, jstring value) {
  if (!value) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  const QString text = QString::fromUtf8(chars);
  env->ReleaseStringUTFChars(value, chars);
  return text;
}

jstring json(JNIEnv* env, const QJsonObject& effects) {
  return env->NewStringUTF(QJsonDocument(effects).toJson(QJsonDocument::Compact).constData());
}

push::Device device(jboolean permitted, jint sdk) {
  return {QDateTime::currentMSecsSinceEpoch(), push::foreground(), bool(permitted), int(sdk)};
}

}  // namespace

extern "C" {

JNIEXPORT jstring JNICALL Java_io_github_halc2_mobile_PushReceiver_receive(JNIEnv* env, jclass, jstring dataDir, jbyteArray body,
                                                                         jboolean permitted, jint sdk) {
  const jsize size = env->GetArrayLength(body);
  QByteArray bytes(size, Qt::Uninitialized);
  env->GetByteArrayRegion(body, 0, size, reinterpret_cast<jbyte*>(bytes.data()));
  return json(env, push::Inbox(string(env, dataDir)).receive(bytes, device(permitted, sdk)));
}

JNIEXPORT void JNICALL Java_io_github_halc2_mobile_PushReceiver_endpoint(JNIEnv* env, jclass, jstring dataDir, jstring endpoint) {
  push::Inbox(string(env, dataDir)).setValue(QStringLiteral("endpoint"), string(env, endpoint));
  // The app, when it runs, registers the new endpoint with its MC.
  if (auto* app = QCoreApplication::instance()) {
    QMetaObject::invokeMethod(app, [] {
      if (Android::s_current && Android::s_current->changed) Android::s_current->changed();
    });
  }
}

JNIEXPORT jstring JNICALL Java_io_github_halc2_mobile_DismissReceiver_dismiss(JNIEnv* env, jclass, jstring dataDir) {
  return json(env, push::Inbox(string(env, dataDir)).dismiss());
}

}  // extern "C"

#endif
