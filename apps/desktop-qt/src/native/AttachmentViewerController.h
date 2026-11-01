#pragma once

#include <QObject>
#include <QVariant>

#include "NativeController.h"

class McClient;
class ShellBridge;

// An attachment opened to look at, of the draft or of a sent message: an image
// large, Markdown, a table or a page rendered or as its source, any other text
// as text, and what cannot be shown named as such.
//
// Publishes `attachmentViewer`, null while closed: {id, name, kind (image |
// markdown | table | page | text | unsupported | loading | failed), url, text,
// rendered (a table's Markdown), origin ("Draft" | "Sent"), removable, truncated
// (text stops at the preview limit), problem (why it failed), source (a page's
// text, fetched when asked for), sourceProblem}. Actions: `attachment.view {id}`
// (a draft attachment's), `attachment.sent.view {id, name, mimeType}` (of the
// active thread), `attachment.viewer.retry`, `.source` (a page's source, fetched
// again with a fresh address), `.copy`, `.save`, `.close`, and `.remove`, which
// takes the attachment off its draft and closes. The viewer closes when its
// draft attachment leaves the draft any other way (sent, removed from its chip).
class AttachmentViewerController : public QObject, public NativeController {
  Q_OBJECT

public:
  AttachmentViewerController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;
  // Where a save puts its file; the user's Downloads unless a scenario says.
  void setSaveFolder(const QString& folder) { m_saveFolder = folder; }

private:
  using Fetched = std::function<void(const QByteArray& bytes, const QString& problem, const QString& reason)>;
  void close();
  void show(QVariantMap preview);
  // Signs an address anew and reads it, so a viewer open for an hour still
  // reaches the MC. `problem` is what to tell the user when it could not.
  void fetch(Fetched done);
  void openSent();
  void save();

  ShellBridge* m_bridge;
  McClient* m_client;
  bool m_active = false;
  QString m_viewing;
  // The sent attachment on show: {environment, id, name, mimeType}; empty for a draft's.
  QVariantMap m_sent;
  QVariantMap m_shown;
  QString m_saveFolder;
  // Answers to anything but the latest request are for a viewer since closed.
  int m_request = 0;
};
