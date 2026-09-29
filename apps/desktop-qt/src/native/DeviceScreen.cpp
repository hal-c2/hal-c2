#include "DeviceScreen.h"

#include <QCoreApplication>
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGTexture>
#include <QtQml/qqml.h>

DeviceScreen::DeviceScreen(QQuickItem* parent) : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
}

void DeviceScreen::setStream(DeviceStream* stream) {
  if (stream == m_stream) return;
  if (m_stream) m_stream->decoder()->disconnect(this);
  m_stream = stream;
  m_frame = {};
  m_fresh = true;
  if (m_hasFrame) {
    m_hasFrame = false;
    emit hasFrameChanged();
  }
  if (stream) {
    connect(stream->decoder(), &DeviceDecoder::frameReady, this, &DeviceScreen::take);
    limit();
    take();
  }
  update();
  emit streamChanged();
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
  if (!node) {
    node = window()->createImageNode();
    node->setOwnsTexture(true);
    node->setFiltering(QSGTexture::Linear);
    m_fresh = true;
  }
  if (m_fresh) {
    node->setTexture(window()->createTextureFromImage(m_frame));
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
