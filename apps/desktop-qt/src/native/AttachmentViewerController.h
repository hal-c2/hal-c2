#pragma once

#include <QObject>
#include <QVariant>

#include "NativeController.h"

class McClient;
class ShellBridge;

// An attachment of the draft opened to look at (the web's
// AttachmentFilePreview): an image large, Markdown rendered or as its source,
// any other text as text, and what cannot be shown named as such.
//
// Publishes `attachmentViewer`, null while closed: {id, name, kind (image |
// markdown | text | unsupported), url, text, origin ("Draft")}. Actions:
// `attachment.view {id}` (a draft attachment's), `attachment.viewer.close`,
// and `attachment.viewer.remove`, which takes the attachment off its draft
// and closes. The viewer closes when its attachment leaves the draft any
// other way (sent, removed from its chip).
class AttachmentViewerController : public QObject, public NativeController {
  Q_OBJECT

public:
  AttachmentViewerController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  void close();

  ShellBridge* m_bridge;
  bool m_active = false;
  QString m_viewing;
};
