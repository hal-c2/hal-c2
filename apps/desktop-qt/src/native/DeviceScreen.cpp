#include "DeviceScreen.h"

#include <QCoreApplication>
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGTexture>
#include <QtEndian>
#include <QtQml/qqml.h>
#include <rhi/qrhi.h>

namespace {

// One GPU texture a screen's pictures are uploaded into, re-created only
// when the picture's size changes (a rotation, a resized panel): a new
// texture per frame would allocate and free GPU memory 60 times a second.
// The scene graph uploads the newest picture when it next renders.
class FrameTexture : public QSGTexture {
public:
  ~FrameTexture() override {
    if (m_texture) m_texture->deleteLater();
  }

  void setImage(const QImage& image) {
    m_image = image;
    m_size = image.size();
  }

  qint64 comparisonKey() const override { return qint64(quintptr(this)); }
  QRhiTexture* rhiTexture() const override { return m_texture; }
  QSize textureSize() const override { return m_size; }
  bool hasAlphaChannel() const override { return false; }
  bool hasMipmaps() const override { return false; }

  void commitTextureOperations(QRhi* rhi, QRhiResourceUpdateBatch* updates) override {
    if (m_image.isNull()) return;
    // The decoder's RGB32 is BGRA in memory on little-endian machines.
    const bool bgra = QSysInfo::ByteOrder == QSysInfo::LittleEndian && rhi->isTextureFormatSupported(QRhiTexture::BGRA8);
    const QRhiTexture::Format format = bgra ? QRhiTexture::BGRA8 : QRhiTexture::RGBA8;
    if (m_texture && (m_texture->pixelSize() != m_size || m_texture->format() != format)) {
      m_texture->deleteLater();
      m_texture = nullptr;
    }
    if (!m_texture) {
      m_texture = rhi->newTexture(format, m_size);
      if (!m_texture->create()) {
        delete m_texture;
        m_texture = nullptr;
        return;
      }
    }
    updates->uploadTexture(m_texture, bgra ? m_image : m_image.convertToFormat(QImage::Format_RGBX8888));
    m_image = {};
  }

private:
  QImage m_image;
  QSize m_size;
  QRhiTexture* m_texture = nullptr;
};

}  // namespace

DeviceScreen::DeviceScreen(QQuickItem* parent) : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
}

void DeviceScreen::setStream(DeviceStream* stream) {
  if (stream == m_stream) return;
  if (m_stream) {
    m_stream->decoder()->disconnect(this);
    m_stream->disconnect(this);
  }
  m_stream = stream;
  drop();
  if (stream) {
    connect(stream->decoder(), &DeviceDecoder::frameReady, this, &DeviceScreen::take);
    connect(stream, &DeviceStream::targetChanged, this, &DeviceScreen::drop);
    // Waiting for a picture again (a reconnect, a restarted encoder) or not
    // streaming at all: the last picture no longer shows the device.
    connect(stream, &DeviceStream::statusChanged, this, [this] {
      const QString status = m_stream->status();
      if (status == QLatin1String("connecting") || status == QLatin1String("idle")) drop();
    });
    limit();
    take();
  }
  emit streamChanged();
}

void DeviceScreen::drop() {
  const bool had = !m_frame.isNull();
  m_frame = {};
  m_fresh = true;
  if (m_hasFrame) {
    m_hasFrame = false;
    emit hasFrameChanged();
  }
  if (had) update();
}

void DeviceScreen::take() {
  if (!m_stream) return;
  const QImage frame = m_stream->decoder()->frame();
  if (frame.isNull()) return;
  m_frame = frame;
  m_fresh = true;
  if (!m_hasFrame) {
    m_hasFrame = true;
    emit hasFrameChanged();
  }
  update();
}

void DeviceScreen::limit() {
  if (!m_stream) return;
  const qreal ratio = window() ? window()->effectiveDevicePixelRatio() : 1.0;
  // A turned picture turns the item with it: its size is the picture's.
  m_stream->decoder()->setMaximumSize((boundingRect().size() * ratio).toSize());
}

void DeviceScreen::geometryChange(const QRectF& next, const QRectF& previous) {
  QQuickItem::geometryChange(next, previous);
  if (next.size() != previous.size()) {
    limit();
    update();
  }
}

void DeviceScreen::itemChange(ItemChange change, const ItemChangeData& value) {
  QQuickItem::itemChange(change, value);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) limit();
}

QSGNode* DeviceScreen::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
  auto* node = static_cast<QSGImageNode*>(old);
  if (m_frame.isNull() || boundingRect().isEmpty()) {
    delete node;
    return nullptr;
  }
  // The software scene graph has no QRhi: it takes a texture per picture.
  const bool rhi = window()->rhi();
  if (!node) {
    node = window()->createImageNode();
    node->setOwnsTexture(true);
    if (rhi) node->setTexture(new FrameTexture);
    node->setFiltering(QSGTexture::Linear);
    m_fresh = true;
  }
  if (m_fresh) {
    if (rhi) {
      static_cast<FrameTexture*>(node->texture())->setImage(m_frame);
      node->markDirty(QSGNode::DirtyMaterial);
    } else {
      node->setTexture(window()->createTextureFromImage(m_frame));
    }
    m_fresh = false;
  }
  node->setRect(boundingRect());
  return node;
}

namespace {

void registerDeviceScreen() {
  qmlRegisterType<DeviceScreen>("HalC2.Shell", 1, 0, "DeviceScreen");
  qmlRegisterUncreatableType<DeviceStream>("HalC2.Shell", 1, 0, "DeviceStream", QStringLiteral("A device tab's stream"));
}

}  // namespace

Q_COREAPP_STARTUP_FUNCTION(registerDeviceScreen)
