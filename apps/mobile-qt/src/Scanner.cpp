#include "Scanner.h"

#include <QGuiApplication>
#include <QVariantMap>
#include <QVideoFrame>
#include <QVideoSink>
#include <QtConcurrentRun>

#include "PairingExchange.h"
#include "QrReader.h"
#include "ShellBridge.h"

namespace {

const QString kKey = QStringLiteral("scanner");

}  // namespace

Scanner::Scanner(ShellBridge* bridge, std::shared_ptr<ScanCamera> camera, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_camera(std::move(camera)) {
  bridge->declareKey(kKey);
  // The bridge keeps its interceptors for good.
  bridge->addInterceptor([self = QPointer<Scanner>(this)](const QString& action, const QVariant& payload) {
    return self && self->handle(action, payload);
  });
  connect(&m_reading, &QFutureWatcher<QStringList>::finished, this, [this] { found(m_reading.result()); });
  // Behind another app the camera is off; back at the front, the user may
  // have been to the system's settings to allow it.
  connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
    if (state == Qt::ApplicationActive && m_open && !m_asking) m_access = m_camera->access();
    update();
  });
  publish();
}

Scanner::~Scanner() {
  if (m_running) m_camera->stop();
}

bool Scanner::handle(const QString& action, const QVariant& payload) {
  if (action == QLatin1String("scanner.open")) {
    open();
  } else if (action == QLatin1String("scanner.close")) {
    close();
  } else if (action == QLatin1String("scanner.preview")) {
    preview(qobject_cast<QVideoSink*>(payload.toMap().value(QStringLiteral("sink")).value<QObject*>()));
  } else if (action == QLatin1String("scanner.settings")) {
    m_camera->openSettings();
  } else if (action == QLatin1String("scanner.retry")) {
    retry();
  } else {
    return false;
  }
  return true;
}

void Scanner::open() {
  if (m_open) return;
  m_open = true;
  m_access = m_camera->access();
  // Asked whenever the app does not have it: only the system knows whether
  // it will still put the question, and it answers at once when it will not.
  if (m_access != ScanCamera::Access::Granted && !m_asking) {
    m_asking = true;
    m_camera->requestAccess(this, [this](ScanCamera::Access answered) {
      m_asking = false;
      m_access = answered;
      update();
    });
  }
  update();
}

void Scanner::close() {
  if (!m_open) return;
  m_open = false;
  m_failed = false;
  m_message.clear();
  update();
}

void Scanner::retry() {
  if (!m_open || !m_failed) return;
  m_failed = false;
  m_message.clear();
  update();
}

void Scanner::failed(ScanCamera::Failure why) {
  // The camera's to let go of, for whichever app has it now; what a frame
  // from before held is dropped with it (found).
  m_camera->stop();
  m_running = false;
  m_failed = true;
  m_message = why == ScanCamera::Failure::NoCamera
                  ? tr("This device has no camera. Go back and enter the pairing link instead.")
                  : tr("The camera cannot be used right now. Another app may be using it: close that app and try again, or go back and enter the pairing link.");
  publish();
}

void Scanner::preview(QVideoSink* sink) {
  if (m_sink == sink) return;
  if (m_sink) disconnect(m_sink, nullptr, this, nullptr);
  // A camera that runs is drawing into the old one.
  if (m_running) {
    m_camera->stop();
    m_running = false;
  }
  m_sink = sink;
  if (sink) {
    connect(sink, &QVideoSink::videoFrameChanged, this, &Scanner::frame);
    // The screen went, however that came about.
    connect(sink, &QObject::destroyed, this, [this] { update(); });
  }
  update();
}

void Scanner::update() {
  const bool wanted = m_open && !m_failed && m_access == ScanCamera::Access::Granted && m_sink && qGuiApp->applicationState() == Qt::ApplicationActive;
  if (wanted && !m_running) {
    m_running = true;
    ++m_run;
    m_camera->start(m_sink, this, [this](ScanCamera::Failure why) { failed(why); });
  } else if (!wanted && m_running) {
    m_camera->stop();
    m_running = false;
  }
  publish();
}

void Scanner::frame(const QVideoFrame& frame) {
  if (!m_running || m_reading.isRunning()) return;
  const QImage picture = qr::luminance(frame);
  if (picture.isNull()) return;
  m_readFrom = m_run;
  m_reading.setFuture(QtConcurrent::run([picture] { return qr::read(picture); }));
}

void Scanner::found(const QStringList& codes) {
  // Read off a frame from before the camera stopped, even if it runs again.
  if (!m_running || m_readFrom != m_run || codes.isEmpty()) return;
  for (const QString& code : codes) {
    const auto invitation = pairing::readInvitation(code);
    if (!invitation) continue;
    close();
    m_bridge->dispatch(QStringLiteral("pairing.pair"), QVariantMap{{QStringLiteral("link"), invitation->link}});
    return;
  }
  m_message = tr("That is not a HAL-C2 pairing code. Scan the code under Settings → Connections on the machine that runs HAL-C2.");
  publish();
}

void Scanner::publish() {
  const QString access = m_asking                                    ? QStringLiteral("asking")
                         : m_access == ScanCamera::Access::Granted ? QStringLiteral("granted")
                         : m_access == ScanCamera::Access::Denied  ? QStringLiteral("denied")
                                                                   : QStringLiteral("unknown");
  const QVariantMap state{
      {QStringLiteral("open"), m_open}, {QStringLiteral("access"), access}, {QStringLiteral("failed"), m_failed}, {QStringLiteral("message"), m_message}};
  if (state == m_published) return;
  m_published = state;
  m_bridge->publish(kKey, state);
}
