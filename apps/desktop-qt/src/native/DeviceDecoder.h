#pragma once

#include <QByteArray>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QSize>
#include <QThread>

#include <deque>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;
struct SwsContext;

// A device's H.264 screen, decoded off the GUI thread with libavcodec: iOS
// sends AVCC (length-prefixed NAL units after an avcC record), Android sends
// Annex-B access units. Every unit is decoded, since later frames refer to
// earlier ones, but only the newest picture of a batch is converted to an
// image, so a decoder that falls behind skips pictures, never queues them.
// A backlog past kMaxQueued is dropped whole and decoding waits for the next
// keyframe: push() returns false and the stream asks the device for one.
//
// frameReady() fires on the GUI thread once per new picture that nobody has
// taken yet; frame() takes the newest.
class DeviceDecoder : public QObject {
  Q_OBJECT

public:
  static constexpr int kMaxQueued = 8;

  explicit DeviceDecoder(QObject* parent = nullptr);
  ~DeviceDecoder() override;

  // A new stream: `avcc` is its avcC record (AVCC units follow), or empty for
  // Annex-B. Drops what is queued and the newest picture, and decodes
  // nothing before a keyframe.
  void reset(const QByteArray& avcc = {});
  // Queues one access unit, the bytes of `unit` from `offset` on (a
  // message's header skipped without copying it); false when the backlog was
  // dropped instead.
  bool push(const QByteArray& unit, bool keyframe, qsizetype offset = 0);
  // A still picture (serve-sim's JPEG seed), shown until video arrives.
  void pushJpeg(const QByteArray& jpeg);
  // The largest picture worth converting to (the view's size in pixels);
  // pictures are scaled down to fit it, never up. Empty: full size.
  void setMaximumSize(const QSize& size);

  // The newest picture, and the size the device sent it at.
  QImage frame();
  QSize sourceSize();

signals:
  void frameReady();
  // A unit the decoder could not take: the stream should start over from a keyframe.
  void broken();
  // No H.264 decoder could start (`why`): retrying will not help.
  void unsupported(const QString& why);

private:
  struct Unit {
    QByteArray data;
    bool keyframe = false;
    bool jpeg = false;
    // reset() generation it belongs to.
    int epoch = 0;
    // Where the unit starts in `data`.
    qsizetype offset = 0;
  };

  // On the worker thread.
  void drain();
  // Empty, or why no decoder started.
  QString open(const QByteArray& avcc);
  void close();
  QImage convert(AVFrame* picture, const QSize& limit);

  QThread m_thread;
  QObject m_worker;

  // Shared, under m_mutex.
  QMutex m_mutex;
  std::deque<Unit> m_queue;
  int m_epoch = 0;
  QByteArray m_avcc;
  bool m_awaitingKeyframe = true;
  bool m_draining = false;
  bool m_notified = false;
  QSize m_maximum;
  QImage m_frame;
  QSize m_sourceSize;

  // The worker's own.
  int m_openEpoch = -1;
  AVCodecContext* m_context = nullptr;
  AVPacket* m_packet = nullptr;
  AVFrame* m_picture = nullptr;
  // The newest picture decoded.
  AVFrame* m_last = nullptr;
  SwsContext* m_scaler = nullptr;
};
