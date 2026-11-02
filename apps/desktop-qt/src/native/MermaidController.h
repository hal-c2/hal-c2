#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QStringList>
#include <QVariantMap>

#include <functional>

#include "McClient.h"
#include "NativeController.h"

class ShellBridge;

// Mermaid diagrams, drawn by the MC (`mermaid.render`, packages/contracts
// mermaid.ts) and kept here by theme and source, so a block scrolled back into
// view, laid out again or shown in another window is not asked for twice.
//
// QML reads them through the `Diagrams` singleton (Bricks/MermaidDiagram.qml):
// diagram(source, theme) answers at once with what is known, {status:
// "drawing"} while the MC is asked, then {status: "drawn", kind, url (a
// data: URL of the SVG), width, height} or {status: "unsupported" | "invalid" |
// "failed", kind, reason, line?, column?}; `revision` changes with every
// answer, so a binding that reads it asks again. Drawn, unsupported and invalid
// answers are kept; a failed one (the MC could not draw it, or could not be
// reached) is asked again by retry() and once the MC is back. Past 256 answers
// the oldest go, never one a block has read since the last answer.
class MermaidController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)

public:
  // Sends one `mermaid.render` input; the reply is never synchronous.
  using Ask = std::function<void(QObject* context, const QJsonObject& input, McClient::Reply reply)>;

  MermaidController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override {}
  bool handle(const QString&, const QVariant&) override { return false; }

  int revision() const { return m_revision; }
  Q_INVOKABLE QVariantMap diagram(const QString& source, const QString& theme);
  Q_INVOKABLE void retry(const QString& source, const QString& theme);

  // For tests: how the MC is asked, the MC coming back, and how many answers
  // are kept.
  void setAsk(Ask ask) { m_ask = std::move(ask); }
  void reconnected();
  void setKept(int kept) { m_kept = kept; }

signals:
  void revisionChanged();

private:
  struct Entry {
    QString source;
    QString theme;
    QVariantMap answer;
    bool pending = false;
    int request = 0;
    // The revision it was last read in: one read in this one is on screen.
    int seen = 0;
  };

  void ask(const QString& key);
  void answered(const QString& key, int request, const QJsonValue& result, const std::optional<QString>& error);

  Ask m_ask;
  QHash<QString, Entry> m_entries;  // theme + "\n" + source
  QStringList m_order;              // keys, oldest first
  int m_revision = 0;
  int m_nextRequest = 1;
  int m_kept = 256;
};
