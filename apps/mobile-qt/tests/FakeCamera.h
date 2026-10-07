#pragma once

// The camera the phone's tests scan with (tst_Scanner, and the scenarios'
// World), in the place of the device's (ScanCamera): the user's answer to
// "may HAL-C2 use the camera" is scripted, as is a camera that does not
// start or stops by itself, and a picture is handed over as the frame a
// camera would deliver, in a camera's own pixel format.

#include <QImage>
#include <QMetaObject>
#include <QObject>
#include <QPainter>
#include <QPointer>
#include <QRandomGenerator>
#include <QVideoFrame>
#include <QVideoFrameFormat>
#include <QVideoSink>

#include <cstring>
#include <functional>
#include <optional>

#include "QrCode.h"
#include "ScanCamera.h"

namespace camera {

// `picture` as an NV12 frame, what a phone's camera delivers: a plane of
// brightness, then the colour at half the size, here none.
inline QVideoFrame nv12(const QImage& picture) {
  const QImage gray = picture.convertToFormat(QImage::Format_Grayscale8);
  QVideoFrame frame(QVideoFrameFormat(gray.size(), QVideoFrameFormat::Format_NV12));
  if (!frame.map(QVideoFrame::WriteOnly)) qFatal("cannot write a frame");
  for (int y = 0; y < gray.height(); ++y) std::memcpy(frame.bits(0) + y * frame.bytesPerLine(0), gray.constScanLine(y), gray.width());
  std::memset(frame.bits(1), 128, frame.mappedBytes(1));
  frame.unmap();
  return frame;
}

// What a camera sees of a desk with no code on it: light, edges, print, and
// squares in squares as a QR code's corners have them. The same each time.
inline QImage desk(const QSize& size = QSize(1280, 720)) {
  QImage picture(size, QImage::Format_RGB32);
  QPainter painter(&picture);
  painter.setRenderHint(QPainter::Antialiasing);
  QLinearGradient light(0, 0, size.width(), size.height());
  light.setColorAt(0, QColor(70, 66, 60));
  light.setColorAt(1, QColor(196, 190, 180));
  painter.fillRect(picture.rect(), light);
  QRandomGenerator random(7);
  for (int i = 0; i < 60; ++i) {
    const QColor colour(random.bounded(256), random.bounded(256), random.bounded(256));
    const QRect rect(random.bounded(size.width()), random.bounded(size.height()), 8 + random.bounded(size.width() / 5), 8 + random.bounded(size.height() / 5));
    if (i % 3 == 0) {
      painter.setPen(QPen(colour, 1 + random.bounded(6)));
      painter.drawLine(rect.topLeft(), rect.bottomRight());
    } else if (i % 3 == 1) {
      painter.fillRect(rect, colour);
    } else {
      painter.setPen(colour);
      QFont font;
      font.setPixelSize(10 + random.bounded(24));
      painter.setFont(font);
      painter.drawText(rect.topLeft(), QStringLiteral("Settings > Connections 0123456789"));
    }
  }
  for (const QPoint& corner : {QPoint(24, 24), QPoint(size.width() - 90, size.height() - 90)}) {
    painter.fillRect(QRect(corner, QSize(63, 63)), Qt::black);
    painter.fillRect(QRect(corner + QPoint(9, 9), QSize(45, 45)), Qt::white);
    painter.fillRect(QRect(corner + QPoint(18, 18), QSize(27, 27)), Qt::black);
  }
  return picture;
}

// The same desk with a screen on it that shows `text` as a QR code, drawn as
// the desktop draws it (qr::image): `side` pixels across, turned by
// `degrees`, off the picture's middle.
inline QImage sees(const QString& text, const QSize& size = QSize(1280, 720), int side = 320, qreal degrees = 0) {
  const QImage drawn = qr::image(qr::encode(text), 8);
  if (drawn.isNull()) qFatal("the text does not fit a QR code");
  QImage picture = desk(size);
  QPainter painter(&picture);
  painter.setRenderHint(QPainter::SmoothPixmapTransform);
  painter.translate(size.width() * 0.58, size.height() * 0.46);
  painter.rotate(degrees);
  painter.drawImage(QRectF(-side / 2.0, -side / 2.0, side, side), drawn);
  return picture;
}

}  // namespace camera

class FakeCamera : public ScanCamera {
public:
  // What the system holds for the app.
  Access held = Access::Undetermined;
  // What comes of asking: the user's answer, or the system's own when it no
  // longer asks. None leaves the question on screen until reply().
  std::optional<Access> answer;
  // What comes of starting the camera, later as a camera's own word comes:
  // a device with none, or one whose camera does not start. None starts it.
  std::optional<Failure> fault;
  int asked = 0;
  // How often the camera was asked to start, and how often it did.
  int attempts = 0;
  int starts = 0;
  int settingsOpened = 0;

  // Whether the app holds the camera: started and not stopped since, with
  // frames or without.
  bool inUse() const { return m_inUse; }
  // Whether it gives frames.
  bool running() const { return m_running; }
  // The running camera stops by itself: another app took it, or it was
  // unplugged.
  void fail(Failure why = Failure::Stopped) {
    if (!m_running) qFatal("the camera is not running");
    m_running = false;
    if (auto failed = std::exchange(m_failed, {})) failed(why);
  }
  // Whether the user is looking at the system's question.
  bool asking() const { return static_cast<bool>(m_answered); }
  // The user answers it.
  void reply(Access given) {
    held = given;
    if (auto answered = std::exchange(m_answered, {})) answered(given);
  }
  // The camera delivers `picture` as its next frame.
  void show(const QImage& picture) {
    if (!m_running || !m_sink) qFatal("the camera is not running");
    m_sink->setVideoFrame(camera::nv12(picture));
  }

  Access access() override { return held; }
  void requestAccess(QObject* context, std::function<void(Access)> answered) override {
    ++asked;
    m_answered = [context = QPointer<QObject>(context), answered = std::move(answered)](Access given) {
      // Later, as the system's answer comes.
      if (context) QMetaObject::invokeMethod(context, [answered, given] { answered(given); }, Qt::QueuedConnection);
    };
    if (answer) reply(*answer);
  }
  void start(QVideoSink* sink, QObject* context, std::function<void(Failure)> failed) override {
    stop();
    ++attempts;
    m_inUse = true;
    m_failed = std::move(failed);
    if (!fault) {
      ++starts;
      m_sink = sink;
      m_running = true;
      return;
    }
    QMetaObject::invokeMethod(
        context,
        [this, run = m_run, why = *fault] {
          if (run != m_run) return;
          if (auto failed = std::exchange(m_failed, {})) failed(why);
        },
        Qt::QueuedConnection);
  }
  void stop() override {
    ++m_run;
    m_inUse = false;
    m_running = false;
    m_sink = nullptr;
    m_failed = {};
  }
  void openSettings() override { ++settingsOpened; }

private:
  bool m_inUse = false;
  bool m_running = false;
  // Moves on with each stop: a failure on its way from before one is dropped.
  int m_run = 0;
  QPointer<QVideoSink> m_sink;
  std::function<void(Access)> m_answered;
  std::function<void(Failure)> m_failed;
};
