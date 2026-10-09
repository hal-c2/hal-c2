#pragma once

// What every property test shares (README.md): a home of its own, the main that
// runs a QtTest object's properties, and waits on signals instead of time.
//
//   class SidebarProp : public QObject {
//     Q_OBJECT
//   private slots:
//     void model() { QVERIFY(rc::check("...", [] { rc::state::check(...); })); }
//   };
//   HAL_C2_PROP_MAIN(SidebarProp)
//   #include "tst_SidebarProp.moc"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QEventLoop>
#include <QGuiApplication>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QList>
#include <QMap>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QUrl>
#include <QVariant>

#include <rapidcheck.h>
#include <rapidcheck/state.h>

#include "TestTime.h"

#include <cstdlib>
#include <functional>
#include <ostream>

// How RapidCheck prints Qt values in a counterexample, found by argument-dependent
// lookup; anything else Qt prints through its QDebug operator (halc2::prop::debug).
inline void showValue(const QString& value, std::ostream& os) { rc::show(value.toStdString(), os); }
inline void showValue(const QByteArray& value, std::ostream& os) { rc::show(value.toStdString(), os); }
inline void showValue(const QUrl& value, std::ostream& os) { rc::show(value.toString().toStdString(), os); }
inline void showValue(const QJsonObject& value, std::ostream& os) {
  os << QJsonDocument(value).toJson(QJsonDocument::Compact).toStdString();
}
inline void showValue(const QJsonArray& value, std::ostream& os) {
  os << QJsonDocument(value).toJson(QJsonDocument::Compact).toStdString();
}
inline void showValue(const QJsonValue& value, std::ostream& os) {
  os << QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact).toStdString();
}
inline void showValue(const QVariant& value, std::ostream& os) { showValue(QJsonValue::fromVariant(value), os); }
template <typename T>
void showValue(const QList<T>& value, std::ostream& os) {
  os << "[";
  for (qsizetype i = 0; i < value.size(); ++i) {
    os << (i == 0 ? "" : ", ");
    rc::show(value.at(i), os);
  }
  os << "]";
}
template <typename K, typename V>
void showValue(const QMap<K, V>& value, std::ostream& os) {
  os << "{";
  for (auto it = value.begin(); it != value.end(); ++it) {
    os << (it == value.begin() ? "" : ", ");
    rc::show(it.key(), os);
    os << ": ";
    rc::show(it.value(), os);
  }
  os << "}";
}
template <typename K, typename V>
void showValue(const QHash<K, V>& value, std::ostream& os) { showValue(QMap<K, V>(value.begin(), value.end()), os); }

namespace halc2::prop {

// Points HOME, the XDG directories and HAL_C2_HOME into one temporary directory
// (under TMPDIR) before anything reads them, so nothing a property runs can
// reach the user's HAL-C2 install. Removed when the test exits.
class IsolatedHome {
public:
  IsolatedHome() : m_dir(QDir::tempPath() + QStringLiteral("/hal-c2-prop-XXXXXX")) {
    if (!m_dir.isValid()) {
      qFatal("prop: no temporary home under %s", qPrintable(QDir::tempPath()));
    }
    const QByteArray root = QFile::encodeName(m_dir.path());
    QDir(m_dir.path()).mkpath(QStringLiteral("runtime"));
    QFile::setPermissions(m_dir.path() + QStringLiteral("/runtime"), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    qputenv("HOME", root);
    qputenv("HAL_C2_HOME", root + "/hal-c2");
    qputenv("XDG_CONFIG_HOME", root + "/config");
    qputenv("XDG_DATA_HOME", root + "/data");
    qputenv("XDG_STATE_HOME", root + "/state");
    qputenv("XDG_CACHE_HOME", root + "/cache");
    qputenv("XDG_RUNTIME_DIR", root + "/runtime");
    qputenv("TZ", "UTC");
    QStandardPaths::setTestModeEnabled(true);
  }

  QString path() const { return m_dir.path(); }

private:
  QTemporaryDir m_dir;
};

// What Qt's debug operator prints for `value`: for RC_ASSERT messages and `show`
// of Qt types the overloads above leave out.
template <typename T>
std::string debug(const T& value) {
  QString out;
  QDebug(&out).noquote().nospace() << value;
  return out.toStdString();
}

// Runs the event loop until `done` holds, or `ms` pass (stretched by
// HAL_C2_TEST_TIME_SCALE, see TestTime.h). For a property's assertions
// (RC_ASSERT(prop::until(...))), where QTRY_* cannot return.
inline bool until(const std::function<bool()>& done, int ms = 5000) {
  if (done()) {
    return true;
  }
  QEventLoop loop;
  QTimer limit;
  limit.setSingleShot(true);
  QObject::connect(&limit, &QTimer::timeout, &loop, &QEventLoop::quit);
  QTimer poll;
  QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
    if (done()) {
      loop.quit();
    }
  });
  limit.start(test::scaled(ms));
  poll.start(0);
  loop.exec();
  return done();
}

// Waits for `signal` on `sender`, or `ms` to pass. True when it came.
template <typename Signal>
bool await(const typename QtPrivate::FunctionPointer<Signal>::Object* sender, Signal signal, int ms = 5000) {
  QSignalSpy spy(sender, signal);
  return spy.wait(test::scaled(ms));
}

// Delivers what is posted, deferred deletes included, without waiting for more.
inline void settle() {
  QCoreApplication::sendPostedEvents();
  QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
  QCoreApplication::processEvents();
}

} // namespace halc2::prop

#define HAL_C2_PROP_MAIN(TestObject)                    \
  int main(int argc, char** argv) {                     \
    halc2::prop::IsolatedHome home;                     \
    QGuiApplication app(argc, argv);                    \
    TestObject test;                                    \
    return QTest::qExec(&test, argc, argv);             \
  }
