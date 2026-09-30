#include "FakeFiles.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>

#include "FakeNode.h"

FakeFiles& fakeFiles(FakeNode& node) {
  return node.part<FakeFiles>();
}

QStringList withFolders(const QString& path) {
  QStringList paths;
  const QStringList parts = path.split(QLatin1Char('/'));
  for (qsizetype i = 1; i <= parts.size(); ++i) paths.append(parts.mid(0, i).join(QLatin1Char('/')));
  return paths;
}

namespace {

QJsonObject entry(const FakeFiles& fake, const QString& path) {
  const bool directory = !fake.files.contains(path);
  bool ignored = false;
  for (const QString& folder : withFolders(path)) ignored = ignored || fake.ignored.contains(folder);
  return {{QStringLiteral("path"), path}, {QStringLiteral("kind"), directory ? QStringLiteral("directory") : QStringLiteral("file")},
          {QStringLiteral("ignored"), ignored}};
}

const FakeNode::Extension extension([](FakeNode& node) {
  node.onRpc(QStringLiteral("projects.listEntries"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(node);
    const QString folder = rpc.payload.value(QLatin1String("directoryPath")).toString();
    if (fake.cannotList || fake.failOnce.remove(folder)) {
      node.refuse(rpc, QStringLiteral("Could not list %1.").arg(folder.isEmpty() ? QStringLiteral("the project") : folder));
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
    node.reply(rpc, QJsonObject{{QStringLiteral("entries"), entries}, {QStringLiteral("truncated"), false}});
  });
  // By name; `kind` narrows to files or folders.
  node.onRpc(QStringLiteral("projects.searchEntries"), [&node](const FakeNode::Rpc& rpc) {
    const auto answer = [&node, rpc] {
      FakeFiles& fake = fakeFiles(node);
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
      node.reply(rpc, QJsonObject{{QStringLiteral("entries"), entries}, {QStringLiteral("truncated"), false}});
    };
    if (node.holding(QStringLiteral("search"))) {
      node.defer(answer);
    } else {
      answer();
    }
  });
  // Line by line; an unparseable regular expression falls back to the text.
  node.onRpc(QStringLiteral("projects.searchContents"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(node);
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
    node.reply(rpc, answer);
  });
  node.onRpc(QStringLiteral("projects.readFile"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(node);
    const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
    if (fake.readFailsOnce.remove(path) || !fake.files.contains(path)) {
      node.refuse(rpc, QStringLiteral("Could not read %1.").arg(path));
      return;
    }
    const QString contents = fake.files.value(path);
    node.reply(rpc, QJsonObject{{QStringLiteral("contents"), contents},
                                {QStringLiteral("byteLength"), double(fake.truncated.value(path, contents.toUtf8().size()))},
                                {QStringLiteral("truncated"), fake.truncated.contains(path)}});
  });
  // The folders in the typed path's parent whose names start with its last
  // segment; a path ending in "/" lists the whole folder.
  node.onRpc(QStringLiteral("filesystem.browse"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = fakeFiles(node);
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
    node.reply(rpc, QJsonObject{{QStringLiteral("parentPath"), parent}, {QStringLiteral("entries"), entries}});
  });
});

}  // namespace
