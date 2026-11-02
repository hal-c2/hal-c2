#include "MermaidController.h"

namespace {

const NativeControllerRegistrar<MermaidController> registrar(QStringLiteral("mermaid"), {}, "Diagrams",
                                                            NativeControllerScope::Shared);

QString keyOf(const QString& source, const QString& theme) { return theme + QLatin1Char('\n') + source; }

}  // namespace

MermaidController::MermaidController(ShellBridge*, McClient* client, QObject* parent) : QObject(parent) {
  m_ask = [client](QObject* context, const QJsonObject& input, McClient::Reply reply) {
    client->call(context, client->environment(), QStringLiteral("mermaid.render"), input, std::move(reply));
  };
  connect(client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready) reconnected();
  });
}

QVariantMap MermaidController::diagram(const QString& source, const QString& theme) {
  const QString key = keyOf(source, theme);
  auto found = m_entries.constFind(key);
  if (found != m_entries.constEnd()) {
    return found->pending ? QVariantMap{{QStringLiteral("status"), QStringLiteral("drawing")}} : found->answer;
  }
  m_entries.insert(key, {source, theme, {}, false, 0});
  m_order.append(key);
  // Room for this one: the oldest answers go, never one still being asked for.
  for (qsizetype i = 0; m_order.size() > kKept && i < m_order.size();) {
    if (m_entries.value(m_order.at(i)).pending || m_order.at(i) == key) {
      ++i;
    } else {
      m_entries.remove(m_order.takeAt(i));
    }
  }
  ask(key);
  return {{QStringLiteral("status"), QStringLiteral("drawing")}};
}

void MermaidController::retry(const QString& source, const QString& theme) {
  const QString key = keyOf(source, theme);
  auto found = m_entries.constFind(key);
  if (found == m_entries.constEnd() || found->pending || found->answer.value(QStringLiteral("status")) != QLatin1String("failed")) return;
  ask(key);
  ++m_revision;
  emit revisionChanged();
}

void MermaidController::reconnected() {
  bool asked = false;
  for (const QString& key : std::as_const(m_order)) {
    const Entry& entry = m_entries[key];
    if (entry.pending || entry.answer.value(QStringLiteral("status")) != QLatin1String("failed")) continue;
    ask(key);
    asked = true;
  }
  if (!asked) return;
  ++m_revision;
  emit revisionChanged();
}

void MermaidController::ask(const QString& key) {
  Entry& entry = m_entries[key];
  entry.pending = true;
  entry.request = m_nextRequest++;
  const int request = entry.request;
  m_ask(this,
        QJsonObject{{QStringLiteral("source"), entry.source},
                    {QStringLiteral("format"), QStringLiteral("svg")},
                    {QStringLiteral("theme"), entry.theme}},
        [this, key, request](const QJsonValue& result, const std::optional<QString>& error) { answered(key, request, result, error); });
}

void MermaidController::answered(const QString& key, int request, const QJsonValue& result, const std::optional<QString>& error) {
  auto found = m_entries.find(key);
  // Gone to make room, or asked again since.
  if (found == m_entries.end() || found->request != request) return;
  const QJsonObject answer = result.toObject();
  const QString status = answer.value(QLatin1String("status")).toString();
  QVariantMap shown;
  if (error) {
    const bool away = *error == QLatin1String("not connected") || *error == QLatin1String("disconnected");
    shown = {{QStringLiteral("status"), QStringLiteral("failed")},
             {QStringLiteral("reason"), away ? QStringLiteral("The MC could not be reached to draw this diagram.") : *error}};
  } else if (status == QLatin1String("drawn") && answer.value(QLatin1String("svg")).isString()) {
    // Kept as the data: URL an Image loads, so a block shown again costs nothing.
    shown = {{QStringLiteral("status"), status},
             {QStringLiteral("kind"), answer.value(QLatin1String("kind")).toString()},
             {QStringLiteral("url"), QString(QStringLiteral("data:image/svg+xml;base64,") +
                                             QString::fromLatin1(answer.value(QLatin1String("svg")).toString().toUtf8().toBase64()))},
             {QStringLiteral("width"), answer.value(QLatin1String("width")).toDouble()},
             {QStringLiteral("height"), answer.value(QLatin1String("height")).toDouble()}};
  } else if (status == QLatin1String("unsupported") || status == QLatin1String("invalid") || status == QLatin1String("failed")) {
    shown = {{QStringLiteral("status"), status},
             {QStringLiteral("kind"), answer.value(QLatin1String("kind")).toString()},
             {QStringLiteral("reason"), answer.value(QLatin1String("reason")).toString()}};
    // Where the mistake is, when the renderer says (null otherwise).
    for (const QString field : {QStringLiteral("line"), QStringLiteral("column")}) {
      if (answer.value(field).isDouble()) shown.insert(field, answer.value(field).toInt());
    }
  } else {
    shown = {{QStringLiteral("status"), QStringLiteral("failed")},
             {QStringLiteral("reason"), QStringLiteral("The MC answered with no diagram.")}};
  }
  found->answer = shown;
  found->pending = false;
  ++m_revision;
  emit revisionChanged();
}
