#include "DeviceDecoder.h"

#include <QMutexLocker>

#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/macros.h>
#include <libavutil/mem.h>
#include <libswscale/swscale.h>
}

DeviceDecoder::DeviceDecoder(QObject* parent) : QObject(parent) {
  m_thread.setObjectName(QStringLiteral("device-decoder"));
  m_worker.moveToThread(&m_thread);
  m_thread.start();
}

DeviceDecoder::~DeviceDecoder() {
  {
    QMutexLocker lock(&m_mutex);
    m_queue.clear();
  }
  m_thread.quit();
  m_thread.wait();
  close();
}

void DeviceDecoder::reset(const QByteArray& avcc) {
  QMutexLocker lock(&m_mutex);
  ++m_epoch;
  m_avcc = avcc;
  m_queue.clear();
  m_awaitingKeyframe = true;
}

bool DeviceDecoder::push(const QByteArray& unit, bool keyframe) {
  QMutexLocker lock(&m_mutex);
  if (m_awaitingKeyframe) {
    if (!keyframe) return true;
    m_awaitingKeyframe = false;
  }
  if (m_queue.size() >= size_t(kMaxQueued)) {
    // Behind: what is queued is stale; start again from a keyframe.
    m_queue.clear();
    m_awaitingKeyframe = true;
    if (!keyframe) return false;
    m_awaitingKeyframe = false;
  }
  m_queue.push_back({unit, keyframe, false, m_epoch});
  if (!m_draining) {
    m_draining = true;
    QMetaObject::invokeMethod(&m_worker, [this] { drain(); }, Qt::QueuedConnection);
  }
  return true;
}

void DeviceDecoder::pushJpeg(const QByteArray& jpeg) {
  QMutexLocker lock(&m_mutex);
  m_queue.push_back({jpeg, false, true, m_epoch});
  if (!m_draining) {
    m_draining = true;
    QMetaObject::invokeMethod(&m_worker, [this] { drain(); }, Qt::QueuedConnection);
  }
}

void DeviceDecoder::setMaximumSize(const QSize& size) {
  QMutexLocker lock(&m_mutex);
  m_maximum = size;
}

QImage DeviceDecoder::frame() {
  QMutexLocker lock(&m_mutex);
  m_notified = false;
  return m_frame;
}

QSize DeviceDecoder::sourceSize() {
  QMutexLocker lock(&m_mutex);
  return m_sourceSize;
}

// Decodes everything queued, then converts only the newest picture.
void DeviceDecoder::drain() {
  for (;;) {
    std::deque<Unit> batch;
    QSize limit;
    QByteArray avcc;
    int epoch = 0;
    {
      QMutexLocker lock(&m_mutex);
      if (m_queue.empty()) {
        m_draining = false;
        return;
      }
      batch.swap(m_queue);
      limit = m_maximum;
      avcc = m_avcc;
      epoch = m_epoch;
    }
    QImage newest;
    QSize source;
    bool failed = false;
    // No decoder to decode with: nothing later will do better.
    QString unusable;
    bool decoded = false;
    for (const Unit& unit : batch) {
      if (unit.epoch != epoch) continue;
      if (unit.jpeg) {
        QImage still = QImage::fromData(unit.data, "JPEG");
        if (still.isNull()) continue;
        source = still.size();
        if (!limit.isEmpty() && (still.width() > limit.width() || still.height() > limit.height())) {
          still = still.scaled(limit, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        }
        newest = still.convertToFormat(QImage::Format_RGB32);
        decoded = false;
        continue;
      }
      if (m_openEpoch != epoch) {
        unusable = open(avcc);
        if (!unusable.isEmpty()) {
          failed = true;
          break;
        }
      }
      m_openEpoch = epoch;
      av_packet_unref(m_packet);
      if (av_new_packet(m_packet, int(unit.data.size())) < 0) {
        failed = true;
        break;
      }
      std::memcpy(m_packet->data, unit.data.constData(), size_t(unit.data.size()));
      if (unit.keyframe) m_packet->flags |= AV_PKT_FLAG_KEY;
      if (avcodec_send_packet(m_context, m_packet) < 0) {
        failed = true;
        break;
      }
      // Keeps the newest picture; the ones before it are never shown.
      while (avcodec_receive_frame(m_context, m_picture) == 0) {
        av_frame_unref(m_last);
        av_frame_move_ref(m_last, m_picture);
        decoded = true;
      }
    }
    if (decoded && !failed) {
      source = QSize(m_last->width, m_last->height);
      newest = convert(m_last, limit);
    }
    bool notify = false;
    {
      QMutexLocker lock(&m_mutex);
      if (epoch != m_epoch) continue;
      if (failed) {
        m_queue.clear();
        m_awaitingKeyframe = true;
        m_openEpoch = -1;
      } else if (!newest.isNull()) {
        m_frame = newest;
        m_sourceSize = source;
        notify = !m_notified;
        m_notified = true;
      }
    }
    if (!unusable.isEmpty()) emit unsupported(unusable);
    else if (failed) emit broken();
    if (notify) emit frameReady();
  }
}

QString DeviceDecoder::open(const QByteArray& avcc) {
  close();
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  if (!codec) return QStringLiteral("This FFmpeg has no H.264 decoder.");
  const QString failed = QStringLiteral("The H.264 decoder did not start.");
  m_context = avcodec_alloc_context3(codec);
  if (!m_context) return failed;
  // A live screen: no reordering delay, and slice threads (frame threads
  // hold pictures back one per thread).
  m_context->flags |= AV_CODEC_FLAG_LOW_DELAY;
  m_context->thread_type = FF_THREAD_SLICE;
  m_context->thread_count = 0;
  if (!avcc.isEmpty()) {
    m_context->extradata = static_cast<uint8_t*>(av_mallocz(size_t(avcc.size()) + AV_INPUT_BUFFER_PADDING_SIZE));
    if (!m_context->extradata) return failed;
    std::memcpy(m_context->extradata, avcc.constData(), size_t(avcc.size()));
    m_context->extradata_size = int(avcc.size());
  }
  if (avcodec_open2(m_context, codec, nullptr) < 0) return failed;
  m_packet = av_packet_alloc();
  m_picture = av_frame_alloc();
  m_last = av_frame_alloc();
  return m_packet && m_picture && m_last ? QString() : failed;
}

void DeviceDecoder::close() {
  if (m_context) avcodec_free_context(&m_context);
  if (m_packet) av_packet_free(&m_packet);
  if (m_picture) av_frame_free(&m_picture);
  if (m_last) av_frame_free(&m_last);
  if (m_scaler) {
    sws_freeContext(m_scaler);
    m_scaler = nullptr;
  }
}

QImage DeviceDecoder::convert(AVFrame* picture, const QSize& limit) {
  QSize size(picture->width, picture->height);
  if (size.isEmpty()) return {};
  if (!limit.isEmpty() && (size.width() > limit.width() || size.height() > limit.height())) {
    size = size.scaled(limit, Qt::KeepAspectRatio).expandedTo(QSize(1, 1));
  }
  m_scaler = sws_getCachedContext(m_scaler, picture->width, picture->height, AVPixelFormat(picture->format), size.width(),
                                  size.height(), AV_PIX_FMT_RGB32, SWS_BILINEAR, nullptr, nullptr, nullptr);
  if (!m_scaler) return {};
  // swscale's SIMD writes whole vectors, past the last pixel of a row and of
  // the picture: it gets aligned rows and a padded buffer, which the image
  // then owns.
  const int stride = FFALIGN(size.width() * 4, 64);
  auto* bits = static_cast<uint8_t*>(av_malloc(size_t(stride) * size_t(size.height()) + 64));
  if (!bits) return {};
  uint8_t* planes[4] = {bits, nullptr, nullptr, nullptr};
  int strides[4] = {stride, 0, 0, 0};
  sws_scale(m_scaler, picture->data, picture->linesize, 0, picture->height, planes, strides);
  return QImage(bits, size.width(), size.height(), stride, QImage::Format_RGB32, [](void* data) { av_free(data); }, bits);
}
