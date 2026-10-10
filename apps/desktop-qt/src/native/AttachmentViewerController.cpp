#include "AttachmentViewerController.h"

#include "ComposerController.h"
#include "NativeShell.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<AttachmentViewerController> registrar(QStringLiteral("attachmentViewer"), {QStringLiteral("attachmentViewer")});

// What this viewer draws a preview as.
QString kindOf(const QVariantMap& preview) {
  const QString mime = preview.value(QStringLiteral("mimeType")).toString().section(QLatin1Char(';'), 0, 0).trimmed().toLower();
  const QString name = preview.value(QStringLiteral("name")).toString().toLower();
  const QString extension = name.contains(QLatin1Char('.')) ? name.section(QLatin1Char('.'), -1) : QString();
  static const QStringList markdown{QStringLiteral("md"), QStringLiteral("markdown"), QStringLiteral("mdown"), QStringLiteral("mkd"), QStringLiteral("mdx")};
  if (mime.startsWith(QLatin1String("image/")) && !preview.value(QStringLiteral("url")).toString().isEmpty()) return QStringLiteral("image");
  // A PDF, a video or anything binary came with no text this machine can show.
  if (mime == QLatin1String("application/pdf") || extension == QLatin1String("pdf") || !preview.contains(QStringLiteral("text"))) {
    return QStringLiteral("unsupported");
  }
  if (mime == QLatin1String("text/markdown") || mime == QLatin1String("text/x-markdown") || markdown.contains(extension)) return QStringLiteral("markdown");
  return QStringLiteral("text");
}

}  // namespace

AttachmentViewerController::AttachmentViewerController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {}

void AttachmentViewerController::activate() {
  if (m_active) return;
  m_active = true;
  // The attachment went from its draft: nothing is left to look at.
  connect(m_bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant&) {
    if (key != QLatin1String("composer") || m_viewing.isEmpty()) return;
    if (NativeShell::of(this)->controller<ComposerController>()->attachmentPreview(m_viewing).isEmpty()) close();
  });
  m_bridge->publish(QStringLiteral("attachmentViewer"), QVariant());
}

void AttachmentViewerController::close() {
  if (m_viewing.isEmpty()) return;
  m_viewing.clear();
  m_bridge->publish(QStringLiteral("attachmentViewer"), QVariant());
}

bool AttachmentViewerController::handle(const QString& action, const QVariant& payload) {
  if (action == QLatin1String("attachment.view")) {
    QVariantMap preview = NativeShell::of(this)->controller<ComposerController>()->attachmentPreview(payload.toMap().value(QStringLiteral("id")).toString());
    if (preview.isEmpty()) return true;
    m_viewing = preview.value(QStringLiteral("id")).toString();
    preview.insert(QStringLiteral("kind"), kindOf(preview));
    preview.insert(QStringLiteral("origin"), tr("Draft"));
    m_bridge->publish(QStringLiteral("attachmentViewer"), preview);
  } else if (action == QLatin1String("attachment.viewer.close")) {
    close();
  } else if (action == QLatin1String("attachment.viewer.remove")) {
    const QString id = m_viewing;
    close();
    if (!id.isEmpty()) m_bridge->dispatch(QStringLiteral("composer.attachment.remove"), QVariantMap{{QStringLiteral("id"), id}});
  } else {
    return false;
  }
  return true;
}
