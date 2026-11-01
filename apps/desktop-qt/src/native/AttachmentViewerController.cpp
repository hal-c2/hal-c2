#include "AttachmentViewerController.h"

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonObject>
#include <QStandardPaths>
#include <QStringDecoder>
#include <QUrl>

#include "ComposerController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ThreadStore.h"
#include "ToastController.h"
#include "WorkspaceFiles.h"

namespace {

const NativeControllerRegistrar<AttachmentViewerController> registrar(QStringLiteral("attachmentViewer"), {QStringLiteral("attachmentViewer")});

// video, audio or document when that is what a preview holds; else empty.
QString mediaKind(const QVariantMap& preview) {
  const QString mime = preview.value(QStringLiteral("mimeType")).toString().section(QLatin1Char(';'), 0, 0).trimmed().toLower();
  if (mime.startsWith(QLatin1String("video/"))) return QStringLiteral("video");
  if (mime.startsWith(QLatin1String("audio/"))) return QStringLiteral("audio");
  if (mime == QLatin1String("application/pdf")) return QStringLiteral("document");
  const QString named = WorkspaceFiles::mediaKindOf(preview.value(QStringLiteral("name")).toString());
  if (named == QLatin1String("pdf")) return QStringLiteral("document");
  return named == QLatin1String("video") || named == QLatin1String("audio") ? named : QString();
}

// What this viewer draws a preview as.
QString kindOf(const QVariantMap& preview) {
  const QString mime = preview.value(QStringLiteral("mimeType")).toString().section(QLatin1Char(';'), 0, 0).trimmed().toLower();
  const QString name = preview.value(QStringLiteral("name")).toString().toLower();
  const QString extension = name.contains(QLatin1Char('.')) ? name.section(QLatin1Char('.'), -1) : QString();
  static const QStringList markdown{QStringLiteral("md"), QStringLiteral("markdown"), QStringLiteral("mdown"), QStringLiteral("mkd"), QStringLiteral("mdx")};
  if (mime.startsWith(QLatin1String("image/")) && !preview.value(QStringLiteral("url")).toString().isEmpty()) return QStringLiteral("image");
  const QString media = mediaKind(preview);
  if (!media.isEmpty()) return preview.value(QStringLiteral("url")).toString().isEmpty() ? QStringLiteral("unsupported") : media;
  if (!preview.contains(QStringLiteral("text"))) return QStringLiteral("unsupported");
  if (!WorkspaceFiles::previewDelimiter(name, mime).isNull()) return QStringLiteral("table");
  if (mime == QLatin1String("text/html") || extension == QLatin1String("html") || extension == QLatin1String("htm")) return QStringLiteral("page");
  if (mime == QLatin1String("text/markdown") || mime == QLatin1String("text/x-markdown") || markdown.contains(extension)) return QStringLiteral("markdown");
  return QStringLiteral("text");
}

// A viewer shows the first megabyte of a text, cut between characters.
constexpr qsizetype kPreviewLimit = 1024 * 1024;

QString wholeText(const QByteArray& bytes) {
  QByteArray kept = bytes.left(kPreviewLimit);
  while (bytes.size() > kPreviewLimit && !kept.isEmpty() && (uchar(bytes.at(kept.size())) & 0xC0) == 0x80) kept.chop(1);
  return QString::fromUtf8(kept);
}

bool validText(const QByteArray& bytes) {
  QStringDecoder decoder(QStringDecoder::Utf8);
  const QString decoded = decoder.decode(bytes);
  return !decoder.hasError() && !bytes.contains('\0');
}

}  // namespace

AttachmentViewerController::AttachmentViewerController(ShellBridge* bridge, McClient* client, QObject* parent) : QObject(parent), m_bridge(bridge), m_client(client) {}

void AttachmentViewerController::activate() {
  if (m_active) return;
  m_active = true;
  // The attachment went from its draft: nothing is left to look at.
  connect(m_bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant&) {
    if (key != QLatin1String("composer") || m_viewing.isEmpty() || !m_sent.isEmpty()) return;
    if (NativeShell::of(this)->controller<ComposerController>()->attachmentPreview(m_viewing).isEmpty()) close();
  });
  m_bridge->publish(QStringLiteral("attachmentViewer"), QVariant());
}

namespace {

// `text` with no line longer than a window could usefully wrap.
QString brokenForDisplay(const QString& text) {
  constexpr qsizetype longest = 2000;
  if (text.size() <= longest) return text;
  QString broken;
  broken.reserve(text.size() + text.size() / longest);
  qsizetype run = 0;
  for (const QChar c : text) {
    if (c == QLatin1Char('\n')) run = 0;
    else if (++run > longest) {
      broken.append(QLatin1Char('\n'));
      run = 1;
    }
    broken.append(c);
  }
  return broken;
}

}  // namespace

void AttachmentViewerController::close() {
  ++m_request;
  if (m_viewing.isEmpty()) return;
  m_viewing.clear();
  m_sent.clear();
  m_shown.clear();
  m_bridge->publish(QStringLiteral("attachmentViewer"), QVariant());
}

void AttachmentViewerController::show(QVariantMap preview) {
  m_shown = preview;
  // Laying out one enormous line freezes the window; copying still takes the original.
  for (const QString& field : {QStringLiteral("text"), QStringLiteral("source")}) {
    if (preview.contains(field)) preview.insert(field, brokenForDisplay(preview.value(field).toString()));
  }
  m_bridge->publish(QStringLiteral("attachmentViewer"), preview);
}

QUrl AttachmentViewerController::keepDocument(const QByteArray& bytes) {
  auto copy = std::make_unique<QTemporaryFile>(QDir::tempPath() + QStringLiteral("/hal-c2-XXXXXX.pdf"));
  if (!copy->open() || copy->write(bytes) != bytes.size() || !copy->flush()) return {};
  m_document = std::move(copy);
  return QUrl::fromLocalFile(m_document->fileName());
}

void AttachmentViewerController::sign(Signed done) {
  const QVariantMap sent = m_sent;
  m_client->call(this, sent.value(QStringLiteral("environment")).toString(), QStringLiteral("assets.createUrl"),
                 QJsonObject{{QStringLiteral("resource"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("attachment")},
                                                                       {QStringLiteral("attachmentId"), sent.value(QStringLiteral("id")).toString()},
                                                                       {QStringLiteral("fileName"), sent.value(QStringLiteral("name")).toString()},
                                                                       {QStringLiteral("mimeType"), sent.value(QStringLiteral("mimeType")).toString()}}}},
                 [this, done](const QJsonValue& result, const std::optional<QString>& error) {
                   const QString relative = result.toObject().value(QLatin1String("relativeUrl")).toString();
                   if (error || relative.isEmpty()) {
                     const QString said = error.value_or(tr("The attachment is unavailable."));
                     return done({}, said.startsWith(QLatin1String("not connected")) ? tr("Reconnect to the environment and try again.") : tr("The attachment is unavailable."), said);
                   }
                   done(relative, {}, {});
                 });
}

void AttachmentViewerController::fetch(Fetched done) {
  const int request = ++m_request;
  sign([=, this](const QString& relative, const QString& problem, const QString& reason) {
    if (request != m_request) return;
    if (!problem.isEmpty()) return done({}, problem, reason);
    m_client->download(this, relative, [=, this](const QByteArray& bytes, const std::optional<QString>& error) {
      if (request != m_request) return;
      if (!error) return done(bytes, {}, {});
      // Without an HTTP answer the MC said nothing about the file.
      done({}, error->startsWith(QLatin1String("HTTP ")) ? tr("The attachment is unavailable.") : tr("Reconnect to the environment and try again."), *error);
    });
  });
}

void AttachmentViewerController::openSent() {
  QVariantMap shown{{QStringLiteral("id"), m_sent.value(QStringLiteral("id"))},
                    {QStringLiteral("name"), m_sent.value(QStringLiteral("name"))},
                    {QStringLiteral("mimeType"), m_sent.value(QStringLiteral("mimeType"))},
                    {QStringLiteral("origin"), tr("Sent")},
                    {QStringLiteral("kind"), QStringLiteral("loading")}};
  show(shown);
  const auto failed = [this, shown](const QString& problem) {
    QVariantMap told = shown;
    told.insert(QStringLiteral("kind"), QStringLiteral("failed"));
    told.insert(QStringLiteral("problem"), problem);
    show(told);
  };
  const QString media = mediaKind(shown);
  // A player streams what it plays, from an address, rather than holding it here.
  if (media == QLatin1String("video") || media == QLatin1String("audio")) {
    const int request = ++m_request;
    sign([=, this](const QString& relative, const QString& problem, const QString&) {
      if (request != m_request) return;
      if (!problem.isEmpty()) return failed(problem);
      QVariantMap preview = shown;
      preview.insert(QStringLiteral("url"), m_client->origin().resolved(QUrl(relative)).toString());
      preview.insert(QStringLiteral("kind"), media);
      show(preview);
    });
    return;
  }
  fetch([this, shown](const QByteArray& bytes, const QString& problem, const QString&) mutable {
    if (!problem.isEmpty()) {
      shown.insert(QStringLiteral("kind"), QStringLiteral("failed"));
      shown.insert(QStringLiteral("problem"), problem);
      return show(shown);
    }
    QVariantMap preview = shown;
    const bool image = shown.value(QStringLiteral("mimeType")).toString().startsWith(QLatin1String("image/"));
    if (mediaKind(shown) == QLatin1String("document")) {
      preview.insert(QStringLiteral("url"), keepDocument(bytes).toString());
    } else if (image) {
      preview.insert(QStringLiteral("url"), QStringLiteral("data:%1;base64,%2").arg(shown.value(QStringLiteral("mimeType")).toString(), QString::fromLatin1(bytes.toBase64())));
    } else if (!bytes.contains('\0')) {
      preview.insert(QStringLiteral("text"), wholeText(bytes));
      preview.insert(QStringLiteral("truncated"), bytes.size() > kPreviewLimit);
    }
    const QString kind = kindOf(preview);
    preview.insert(QStringLiteral("kind"), kind);
    if (kind == QLatin1String("table")) {
      const QChar delimiter = WorkspaceFiles::previewDelimiter(shown.value(QStringLiteral("name")).toString(), shown.value(QStringLiteral("mimeType")).toString());
      preview.insert(QStringLiteral("rendered"), WorkspaceFiles::tableMarkdown(preview.value(QStringLiteral("text")).toString(), delimiter));
    }
    show(preview);
  });
}

void AttachmentViewerController::save() {
  if (m_sent.isEmpty()) return;
  const QString name = QFileInfo(m_sent.value(QStringLiteral("name")).toString()).fileName();
  const auto toast = [this](const QString& type, const QString& title, const QString& description) {
    if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) toasts->show(type, title, description);
  };
  fetch([=, this](const QByteArray& bytes, const QString& problem, const QString& reason) {
    const QString couldNot = tr("Could not save %1").arg(name);
    if (!problem.isEmpty()) return toast(QStringLiteral("error"), couldNot, reason.isEmpty() ? problem : problem + QStringLiteral(" (") + reason + u')');
    const QDir folder(m_saveFolder.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::DownloadLocation) : m_saveFolder);
    // A file already there keeps its name and contents.
    QString path = folder.filePath(name);
    const QFileInfo info(name);
    for (int copy = 1; QFile::exists(path); ++copy) {
      path = folder.filePath(info.suffix().isEmpty() ? QStringLiteral("%1 (%2)").arg(name).arg(copy) : QStringLiteral("%1 (%2).%3").arg(info.completeBaseName()).arg(copy).arg(info.suffix()));
    }
    QFile file(path);
    if (!folder.mkpath(QStringLiteral(".")) || !file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size()) return toast(QStringLiteral("error"), couldNot, file.errorString());
    toast(QStringLiteral("success"), tr("Saved %1").arg(QFileInfo(path).fileName()), QDir::toNativeSeparators(path));
  });
}

bool AttachmentViewerController::handle(const QString& action, const QVariant& payload) {
  if (action == QLatin1String("attachment.view")) {
    QVariantMap preview = NativeShell::of(this)->controller<ComposerController>()->attachmentPreview(payload.toMap().value(QStringLiteral("id")).toString());
    if (preview.isEmpty()) return true;
    m_viewing = preview.value(QStringLiteral("id")).toString();
    m_sent.clear();
    ++m_request;
    // What a draft's player or document view reads: the picked file, or what was captured.
    const QString media = mediaKind(preview);
    const QString path = preview.value(QStringLiteral("path")).toString();
    const QByteArray bytes = preview.take(QStringLiteral("bytes")).toByteArray();
    preview.remove(QStringLiteral("path"));
    if (!media.isEmpty() && !path.isEmpty()) {
      preview.insert(QStringLiteral("url"), QUrl::fromLocalFile(path).toString());
    } else if (media == QLatin1String("document") && !bytes.isEmpty()) {
      preview.insert(QStringLiteral("url"), keepDocument(bytes).toString());
    }
    const QString kind = kindOf(preview);
    preview.insert(QStringLiteral("kind"), kind);
    preview.insert(QStringLiteral("origin"), tr("Draft"));
    preview.insert(QStringLiteral("removable"), true);
    if (kind == QLatin1String("table")) {
      preview.insert(QStringLiteral("rendered"), WorkspaceFiles::tableMarkdown(preview.value(QStringLiteral("text")).toString(),
                                                                               WorkspaceFiles::previewDelimiter(preview.value(QStringLiteral("name")).toString(), preview.value(QStringLiteral("mimeType")).toString())));
    }
    show(preview);
  } else if (action == QLatin1String("attachment.sent.view")) {
    const QVariantMap wanted = payload.toMap();
    const QString thread = NativeShell::of(this)->controller<ThreadStore>()->activeThread();
    if (thread.isEmpty()) return true;
    m_viewing = wanted.value(QStringLiteral("id")).toString();
    m_sent = wanted;
    m_sent.insert(QStringLiteral("environment"), thread.left(thread.indexOf(QLatin1Char(':'))));
    openSent();
  } else if (action == QLatin1String("attachment.viewer.retry")) {
    if (!m_sent.isEmpty()) openSent();
  } else if (action == QLatin1String("attachment.viewer.source")) {
    if (m_sent.isEmpty()) return true;
    QVariantMap asking = m_shown;
    asking.remove(QStringLiteral("sourceProblem"));
    show(asking);
    fetch([this](const QByteArray& bytes, const QString& problem, const QString&) {
      QVariantMap shown = m_shown;
      if (!problem.isEmpty() || !validText(bytes)) {
        shown.insert(QStringLiteral("sourceProblem"), problem.isEmpty() ? tr("The source could not be loaded.") : problem);
      } else {
        shown.insert(QStringLiteral("source"), wholeText(bytes));
      }
      show(shown);
    });
  } else if (action == QLatin1String("attachment.viewer.mediaFailed")) {
    QVariantMap shown = m_shown;
    shown.insert(QStringLiteral("kind"), QStringLiteral("failed"));
    shown.insert(QStringLiteral("problem"), tr("The attachment is unavailable."));
    show(shown);
  } else if (action == QLatin1String("attachment.viewer.copy")) {
    QGuiApplication::clipboard()->setText(m_shown.value(QStringLiteral("text")).toString());
  } else if (action == QLatin1String("attachment.viewer.save")) {
    save();
  } else if (action == QLatin1String("attachment.viewer.close")) {
    close();
  } else if (action == QLatin1String("attachment.viewer.remove")) {
    const QString id = m_sent.isEmpty() ? m_viewing : QString();
    close();
    if (!id.isEmpty()) m_bridge->dispatch(QStringLiteral("composer.attachment.remove"), QVariantMap{{QStringLiteral("id"), id}});
  } else {
    return false;
  }
  return true;
}
