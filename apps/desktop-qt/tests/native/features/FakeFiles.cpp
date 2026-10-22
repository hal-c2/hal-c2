#include "FakeFiles.h"

#include <QBuffer>
#include <QDateTime>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QTcpSocket>

#include "FakeMc.h"

FakeFiles& fakeFiles(FakeMc& mc) {
  return mc.part<FakeFiles>();
}

QStringList withFolders(const QString& path) {
  QStringList paths;
  const QStringList parts = path.split(QLatin1Char('/'));
  for (qsizetype i = 1; i <= parts.size(); ++i) paths.append(parts.mid(0, i).join(QLatin1Char('/')));
  return paths;
}

bool signFile(FakeMc& mc, const FakeMc::Rpc& rpc) {
  const QJsonObject resource = rpc.payload.value(QLatin1String("resource")).toObject();
  const QString tag = resource.value(QLatin1String("_tag")).toString();
  if (tag != QLatin1String("workspace-file") && tag != QLatin1String("draft-workspace-file") && tag != QLatin1String("media-file")) return false;
  FakeFiles& fake = fakeFiles(mc);
  const QString path = resource.value(QLatin1String("path")).toString();
  if (!fake.files.contains(path) && !fake.outside.contains(path)) {
    mc.refuse(rpc, QStringLiteral("Workspace file was not found."));
    return true;
  }
  const QString token = QStringLiteral("file-%1").arg(fake.signedFiles.size() + 1);
  fake.signedFiles.insert(token, path);
  mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/api/assets/%1/%2").arg(token, path.section(QLatin1Char('/'), -1))},
                            {QStringLiteral("expiresAt"), double(QDateTime::currentMSecsSinceEpoch() + 3600 * 1000)}});
  return true;
}

namespace {

// A 4x3 PNG, what an image file holds.
QByteArray png() {
  QImage image(4, 3, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  QByteArray bytes;
  QBuffer buffer(&bytes);
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return bytes;
}

QJsonObject entry(const FakeFiles& fake, const QString& path) {
  const bool directory = !fake.files.contains(path);
  bool ignored = false;
  for (const QString& folder : withFolders(path)) ignored = ignored || fake.ignored.contains(folder);
  return {{QStringLiteral("path"), path}, {QStringLiteral("kind"), directory ? QStringLiteral("directory") : QStringLiteral("file")},
          {QStringLiteral("ignored"), ignored}};
}

const FakeMc::Extension extension([](FakeMc& mc) {
  // A signed file's bytes, or a 404 once when its download fails.
  mc.onRaw(QStringLiteral("/api/assets/file-"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    socket->read(head.size());
    FakeFiles& fake = fakeFiles(mc);
    const QString token = QString::fromUtf8(head.left(head.indexOf('\r')).split(' ').value(1)).section(QLatin1Char('/'), 3, 3);
    const QString path = fake.signedFiles.value(token);
    if (path.isEmpty() || fake.loadFailsOnce.remove(path)) {
      socket->write("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    } else {
      fake.downloaded.append(path);
      const bool image = QRegularExpression(QStringLiteral("\\.(png|jpe?g|gif|webp|bmp)$")).match(path).hasMatch();
      const QByteArray body = image ? png() : fake.files.value(path, fake.outside.value(path)).toUtf8();
      socket->write("HTTP/1.1 200 OK\r\nContent-Type: " + QByteArray(image ? "image/png" : "application/octet-stream") +
                    "\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    }
    socket->disconnectFromHost();
  });
  mc.onRpc(QStringLiteral("projects.listEntries"), [&mc](const FakeMc::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(mc);
    const QString folder = rpc.payload.value(QLatin1String("directoryPath")).toString();
    if (fake.cannotList || fake.failOnce.remove(folder)) {
      mc.refuse(rpc, QStringLiteral("Could not list %1.").arg(folder.isEmpty() ? QStringLiteral("the project") : folder));
      return;
    }
    QSet<QString> children;
    for (auto it = fake.files.cbegin(); it != fake.files.cend(); ++it) {
      for (const QString& path : withFolders(it.key())) {
        const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
        if ((slash < 0 ? QString() : path.left(slash)) == folder) children.insert(path);
      }
    }
    QJsonArray entries;
    for (const QString& path : children) entries.append(entry(fake, path));
    mc.reply(rpc, QJsonObject{{QStringLiteral("entries"), entries}, {QStringLiteral("truncated"), false}});
  });
  // By name; `kind` narrows to files or folders.
  mc.onRpc(QStringLiteral("projects.searchEntries"), [&mc](const FakeMc::Rpc& rpc) {
    ++fakeFiles(mc).searches;
    const auto answer = [&mc, rpc] {
      FakeFiles& fake = fakeFiles(mc);
      const QString query = rpc.payload.value(QLatin1String("query")).toString();
      const QString kind = rpc.payload.value(QLatin1String("kind")).toString();
      QSet<QString> matches;
      for (auto it = fake.files.cbegin(); it != fake.files.cend(); ++it) {
        for (const QString& path : withFolders(it.key())) {
          if (path.section(QLatin1Char('/'), -1).contains(query, Qt::CaseInsensitive)) matches.insert(path);
        }
      }
      QJsonArray entries;
      for (const QString& path : matches) {
        const QJsonObject found = entry(fake, path);
        if (kind == QLatin1String("file") && found.value(QLatin1String("kind")) != QLatin1String("file")) continue;
        entries.append(found);
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("entries"), entries}, {QStringLiteral("truncated"), false}});
    };
    if (mc.holding(QStringLiteral("search"))) {
      mc.defer(answer);
    } else {
      answer();
    }
  });
  // Line by line; an unparseable regular expression falls back to the text.
  mc.onRpc(QStringLiteral("projects.searchContents"), [&mc](const FakeMc::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(mc);
    const QString query = rpc.payload.value(QLatin1String("query")).toString();
    const bool caseSensitive = rpc.payload.value(QLatin1String("caseSensitive")).toBool();
    QString pattern = QRegularExpression::escape(query);
    QJsonObject answer;
    if (rpc.payload.value(QLatin1String("useRegex")).toBool()) {
      if (QRegularExpression(query).isValid()) {
        pattern = query;
      } else {
        answer.insert(QStringLiteral("regexFallbackError"), QStringLiteral("Unmatched parenthesis"));
      }
    }
    if (rpc.payload.value(QLatin1String("wholeWord")).toBool()) pattern = QStringLiteral("\\b(?:%1)\\b").arg(pattern);
    const QRegularExpression expression(pattern, caseSensitive ? QRegularExpression::NoPatternOption
                                                               : QRegularExpression::CaseInsensitiveOption);
    QJsonArray matches;
    for (auto it = fake.files.cbegin(); it != fake.files.cend(); ++it) {
      const QStringList lines = it.value().split(QLatin1Char('\n'));
      for (qsizetype line = 0; line < lines.size(); ++line) {
        const QRegularExpressionMatch match = expression.match(lines.at(line));
        if (!match.hasMatch()) continue;
        matches.append(QJsonObject{
            {QStringLiteral("path"), it.key()},
            {QStringLiteral("lineNumber"), line + 1},
            {QStringLiteral("lineContent"), lines.at(line)},
            {QStringLiteral("matchRanges"), QJsonArray{QJsonObject{{QStringLiteral("start"), match.capturedStart()},
                                                                   {QStringLiteral("end"), match.capturedEnd()}}}}});
      }
    }
    answer.insert(QStringLiteral("matches"), matches);
    answer.insert(QStringLiteral("truncated"), false);
    mc.reply(rpc, answer);
  });
  mc.onRpc(QStringLiteral("projects.readFile"), [&mc](const FakeMc::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(mc);
    const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
    if (fake.readFailsOnce.remove(path) || (!fake.files.contains(path) && !fake.outside.contains(path))) {
      mc.refuse(rpc, QStringLiteral("Could not read %1.").arg(path));
      return;
    }
    const QString contents = fake.files.contains(path) ? fake.files.value(path) : fake.outside.value(path);
    mc.reply(rpc, QJsonObject{{QStringLiteral("contents"), contents},
                                {QStringLiteral("byteLength"), double(fake.truncated.value(path, contents.toUtf8().size()))},
                                {QStringLiteral("truncated"), fake.truncated.contains(path)}});
  });
  // The folders in the typed path's parent whose names start with its last
  // segment; a path ending in "/" lists the whole folder.
  mc.onRpc(QStringLiteral("filesystem.browse"), [&mc](const FakeMc::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(mc);
    QString partial = rpc.payload.value(QLatin1String("partialPath")).toString();
    if (partial == QLatin1String("~")) partial = QStringLiteral("~/");
    if (partial.startsWith(QLatin1Char('~'))) partial = fake.home + partial.mid(1);
    const qsizetype slash = partial.lastIndexOf(QLatin1Char('/'));
    QString parent = partial.left(slash);
    if (parent.isEmpty()) parent = QStringLiteral("/");
    const QString prefix = partial.mid(slash + 1);
    QJsonArray entries;
    for (const QString& folder : std::as_const(fake.folders)) {
      const qsizetype at = folder.lastIndexOf(QLatin1Char('/'));
      const QString in = at <= 0 ? QStringLiteral("/") : folder.left(at);
      const QString name = folder.mid(at + 1);
      if (in == parent && name.startsWith(prefix, Qt::CaseInsensitive)) {
        entries.append(QJsonObject{{QStringLiteral("name"), name}, {QStringLiteral("fullPath"), folder}});
      }
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("parentPath"), parent}, {QStringLiteral("entries"), entries}});
  });
});

}  // namespace
