#pragma once

#include <QImage>
#include <QPointer>
#include <QQuickItem>

#include "DeviceStream.h"

// A device's live picture in QML (HalC2.Shell's DeviceScreen): the newest
// frame its stream decoded, stretched over the item. It repaints only when
// the decoder has a new picture, and asks the decoder for pictures no larger
// than the item in device pixels, so a small panel converts small frames.
class DeviceScreen : public QQuickItem {
  Q_OBJECT
  Q_PROPERTY(DeviceStream* stream READ stream WRITE setStream NOTIFY streamChanged)
  // Whether a picture is shown: one arrived since the stream was set, its
  // target changed or it last went back to connecting or idle.
  Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)

public:
  explicit DeviceScreen(QQuickItem* parent = nullptr);

  DeviceStream* stream() const { return m_stream; }
  void setStream(DeviceStream* stream);
  bool hasFrame() const { return m_hasFrame; }

signals:
  void streamChanged();
  void hasFrameChanged();

protected:
  QSGNode* updatePaintNode(QSGNode* node, UpdatePaintNodeData* data) override;
  void geometryChange(const QRectF& next, const QRectF& previous) override;
  void itemChange(ItemChange change, const ItemChangeData& value) override;

private:
  void take();
  void drop();
  void limit();

  QPointer<DeviceStream> m_stream;
  QImage m_frame;
  bool m_fresh = false;
  bool m_hasFrame = false;
};
