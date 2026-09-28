// Runs the desktop shell's native scenarios (features/desktop/native-*.feature)
// against a fake protocol-3 node: a small Gherkin reader, a table of step
// definitions, and one QTest row per scenario. HAL_C2_FEATURES narrows the run
// to other globs under features/ (space separated).

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QPointer>
#include <QQmlPropertyMap>
#include <QRegularExpression>
#include <QTest>
#include <QUrlQuery>
#include <QWebSocket>
#include <QWebSocketServer>

#include <ctime>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>

#include "NativeShell.h"
#include "ShellBridge.h"

namespace {

// ---- Gherkin ---------------------------------------------------------------

using Table = QList<QStringList>;

struct Step {
  QString text;
  Table table;
  int line = 0;
};

struct Scenario {
  QString file;
  QString name;
  QStringList tags;
  QList<Step> steps;
};

QStringList tableCells(const QString& line) {
  QStringList cells = line.trimmed().split(QLatin1Char('|'));
  cells.removeFirst();
  cells.removeLast();
  for (QString& cell : cells) cell = cell.trimmed();
  return cells;
}

// Enough Gherkin for this repo: tags, Feature, Rule, Background, Scenario,
// Scenario Outline with Examples, and data tables. Doc strings are not used.
QList<Scenario> parseFeature(const QString& path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) qFatal("cannot read %s", qPrintable(path));
  const QStringList lines = QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'));

  QList<Scenario> scenarios;
  QStringList pendingTags, featureTags, ruleTags;
  QList<Step> featureBackground, ruleBackground;
  QList<Step>* steps = nullptr;
  bool inRule = false;

  struct Current {
    QString name;
    QStringList tags;
    QList<Step> steps;
    bool outline = false;
    QList<std::pair<QStringList, Table>> examples;  // tags, header + rows
  };
  std::optional<Current> current;
  Table* examples = nullptr;

  const auto flush = [&] {
    if (!current) return;
    const QList<Step> background = featureBackground + ruleBackground;
    if (!current->outline) {
      scenarios.append({path, current->name, current->tags, background + current->steps});
    }
    for (const auto& [exampleTags, table] : current->examples) {
      if (table.isEmpty()) continue;
      const QStringList& header = table.first();
      for (qsizetype row = 1; row < table.size(); ++row) {
        const auto substitute = [&](QString text) {
          for (qsizetype column = 0; column < header.size(); ++column) {
            text.replace(QLatin1Char('<') + header.at(column) + QLatin1Char('>'), table.at(row).value(column));
          }
          return text;
        };
        QList<Step> expanded = background;
        for (Step step : current->steps) {
          step.text = substitute(step.text);
          for (QStringList& cells : step.table) {
            for (QString& cell : cells) cell = substitute(cell);
          }
          expanded.append(step);
        }
        scenarios.append({path, current->name + QStringLiteral(" [") + table.at(row).join(QStringLiteral(", ")) +
                                    QLatin1Char(']'),
                          current->tags + exampleTags, expanded});
      }
    }
    current.reset();
  };

  static const QRegularExpression stepKeyword(QStringLiteral("^(Given|When|Then|And|But|\\*)\\s+(.*)$"));
  for (qsizetype index = 0; index < lines.size(); ++index) {
    const QString line = lines.at(index).trimmed();
    if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;
    if (line.startsWith(QLatin1Char('@'))) {
      pendingTags += line.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
      continue;
    }
    if (line.startsWith(QLatin1String("Feature:"))) {
      featureTags = std::exchange(pendingTags, {});
      steps = nullptr;
    } else if (line.startsWith(QLatin1String("Rule:"))) {
      flush();
      inRule = true;
      ruleTags = std::exchange(pendingTags, {});
      ruleBackground.clear();
      steps = nullptr;
    } else if (line.startsWith(QLatin1String("Background:"))) {
      flush();
      steps = inRule ? &ruleBackground : &featureBackground;
      examples = nullptr;
    } else if (line.startsWith(QLatin1String("Scenario Outline:")) ||
               line.startsWith(QLatin1String("Scenario Template:")) || line.startsWith(QLatin1String("Scenario:")) ||
               line.startsWith(QLatin1String("Example:"))) {
      flush();
      const qsizetype colon = line.indexOf(QLatin1Char(':'));
      current = Current{line.mid(colon + 1).trimmed(), featureTags + ruleTags + std::exchange(pendingTags, {}), {},
                        line.startsWith(QLatin1String("Scenario Outline:")) ||
                            line.startsWith(QLatin1String("Scenario Template:")),
                        {}};
      steps = &current->steps;
      examples = nullptr;
    } else if (line.startsWith(QLatin1String("Examples:")) || line.startsWith(QLatin1String("Scenarios:"))) {
      current->examples.append({std::exchange(pendingTags, {}), {}});
      examples = &current->examples.last().second;
      steps = nullptr;
    } else if (line.startsWith(QLatin1Char('|'))) {
      if (examples) {
        examples->append(tableCells(line));
      } else if (steps && !steps->isEmpty()) {
        steps->last().table.append(tableCells(line));
      }
    } else if (const auto match = stepKeyword.match(line); match.hasMatch() && steps) {
      steps->append({match.captured(2), {}, static_cast<int>(index + 1)});
    }
    // Anything else is a description.
  }
  flush();
  return scenarios;
}

// ---- The fake node ----------------------------------------------------------

QJsonObject threadRow(const QStringList& header, const QStringList& cells) {
  QJsonObject row;
  for (qsizetype column = 0; column < header.size(); ++column) {
    const QString& value = cells.value(column);
    if (value.isEmpty()) continue;
    QString name = header.at(column);
    if (name == QLatin1String("project")) name = QStringLiteral("projectId");
    row.insert(name, value);
  }
  if (!row.contains(QLatin1String("createdAt"))) row.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z"));
  if (!row.contains(QLatin1String("updatedAt"))) row.insert(QStringLiteral("updatedAt"), row.value(QLatin1String("createdAt")));
  return row;
}

void setField(QJsonObject& row, const QString& name, const QString& value) {
  // The node sends the background tasks themselves; only their count matters here.
  if (name == QLatin1String("pendingBackgroundTasks")) {
    QJsonArray tasks;
    for (int task = 0; task < value.toInt(); ++task) tasks.append(QJsonObject{{QStringLiteral("id"), task}});
    row.insert(name, tasks);
  } else {
    row.insert(name, value);
  }
}

// One node of protocol 3 (apps/server-ex lib/hal_c2/web/protocol.ex): hello,
// the shell shape, and `orchestration.dispatchCommand`, which it records and
// answers (or refuses, or holds until told to answer). Terminals attach with
// the `terminal` shape and are listed by `terminals`; `terminal.*` calls are
// recorded and act on them the way the node's terminal manager does.
class FakeNode : public QObject {
public:
  FakeNode() : m_server(QStringLiteral("fake-node"), QWebSocketServer::NonSecureMode) {
    if (!m_server.listen(QHostAddress::LocalHost)) qFatal("fake node cannot listen");
    m_port = m_server.serverPort();
    QObject::connect(&m_server, &QWebSocketServer::newConnection, this, [this] { accept(); });
  }

  QUrl origin() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(m_port)); }

  struct Terminal {
    QJsonObject summary;
    QString history;
  };

  QString name = QStringLiteral("node-a");
  QString environmentId = QStringLiteral("env-a");
  QMap<QString, QJsonObject> threads;
  QMap<QString, QJsonObject> projects;
  // By "threadId/terminalId".
  QMap<QString, Terminal> terminals;
  // Every terminal.* call, as {method, payload}.
  QList<QJsonObject> terminalCalls;
  QList<QUrl> connections;
  QList<QJsonObject> subscriptions;
  QList<QJsonObject> commands;
  QHash<QString, QString> refusals;
  QJsonObject capabilities{
      {QStringLiteral("threadSettlement"), true},
      {QStringLiteral("threadSnooze"), true},
      {QStringLiteral("threadVisitedTracking"), true},
  };
  bool holdSnapshot = false;
  bool holdAnswers = false;

  void sendSnapshot() {
    if (!m_socket || m_shellSubscription < 0) return;
    QJsonArray rows;
    for (auto it = threads.cbegin(); it != threads.cend(); ++it) {
      rows.append(QJsonArray{name, it.key(), QStringLiteral("thread"), *it});
    }
    for (auto it = projects.cbegin(); it != projects.cend(); ++it) {
      rows.append(QJsonArray{name, it.key(), QStringLiteral("project"), *it});
    }
    send({
        {QStringLiteral("t"), QStringLiteral("shell")},
        {QStringLiteral("id"), m_shellSubscription},
        {QStringLiteral("nodes"),
         QJsonArray{QJsonObject{
             {QStringLiteral("node"), name},
             {QStringLiteral("online"), true},
             {QStringLiteral("environment"),
              QJsonObject{
                  {QStringLiteral("environmentId"), environmentId},
                  {QStringLiteral("capabilities"), capabilities},
              }},
         }}},
        {QStringLiteral("rows"), rows},
    });
  }

  void sendRow(const QString& id, const QJsonObject& row) {
    if (!m_socket || m_shellSubscription < 0) return;
    send({
        {QStringLiteral("t"), QStringLiteral("shell.rows")},
        {QStringLiteral("id"), m_shellSubscription},
        {QStringLiteral("node"), name},
        {QStringLiteral("rows"), QJsonArray{QJsonArray{id, QStringLiteral("thread"), row}}},
    });
  }

  // A terminal the node already runs, as another client left it.
  void addTerminal(const QString& threadId, const QString& terminalId, const QString& label, bool busy) {
    QJsonObject summary = terminalSummary(threadId, terminalId, QStringLiteral("/work"));
    summary.insert(QStringLiteral("label"), label);
    summary.insert(QStringLiteral("hasRunningSubprocess"), busy);
    terminals.insert(threadId + QLatin1Char('/') + terminalId, {summary, QString()});
    sendTerminals({{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
  }

  void print(const QString& threadId, const QString& terminalId, const QString& data) {
    const QString key = threadId + QLatin1Char('/') + terminalId;
    terminals[key].history += data;
    sendTerminal(key, {{QStringLiteral("type"), QStringLiteral("output")}, {QStringLiteral("data"), data}});
  }

  void closeTerminal(const QString& threadId, const QString& terminalId) {
    const QString key = threadId + QLatin1Char('/') + terminalId;
    if (!terminals.remove(key)) return;
    sendTerminal(key, {{QStringLiteral("type"), QStringLiteral("closed")}});
    sendTerminals({{QStringLiteral("type"), QStringLiteral("remove")},
                   {QStringLiteral("threadId"), threadId},
                   {QStringLiteral("terminalId"), terminalId}});
  }

  // The `terminal` subscriptions still attached, by terminal key.
  QStringList attached() const { return m_terminalSubscriptions.values(); }

  void answerHeld() {
    const auto held = std::exchange(m_held, {});
    for (const auto& answer : held) answer();
  }

  void drop() {
    if (m_socket) m_socket->close();
  }

  void stopAccepting() { m_server.close(); }

private:
  void accept() {
    while (QWebSocket* socket = m_server.nextPendingConnection()) {
      socket->setParent(this);
      connections.append(socket->requestUrl());
      m_socket = socket;
      m_shellSubscription = -1;
      m_terminalsSubscription = -1;
      m_terminalSubscriptions.clear();
      QObject::connect(socket, &QWebSocket::textMessageReceived, this,
                       [this, socket](const QString& text) { onMessage(socket, text); });
      QObject::connect(socket, &QWebSocket::disconnected, socket, &QObject::deleteLater);
      send({{QStringLiteral("t"), QStringLiteral("hello")}, {QStringLiteral("node"), name}});
    }
  }

  void onMessage(QWebSocket* socket, const QString& text) {
    if (socket != m_socket) return;
    const QJsonObject message = QJsonDocument::fromJson(text.toUtf8()).object();
    const QString type = message.value(QLatin1String("t")).toString();
    const int id = message.value(QLatin1String("id")).toInt();
    if (type == QLatin1String("sub")) {
      subscriptions.append(message);
      const QJsonObject shape = message.value(QLatin1String("shape")).toObject();
      const QString kind = shape.value(QLatin1String("type")).toString();
      if (kind == QLatin1String("shell")) {
        m_shellSubscription = id;
        if (!holdSnapshot) sendSnapshot();
      } else if (kind == QLatin1String("terminals")) {
        m_terminalsSubscription = id;
        QJsonArray list;
        for (const Terminal& terminal : std::as_const(terminals)) list.append(terminal.summary);
        sendTerminals({{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("terminals"), list}});
      } else if (kind == QLatin1String("terminal")) {
        attach(id, shape.value(QLatin1String("input")).toObject());
      }
    } else if (type == QLatin1String("unsub")) {
      m_terminalSubscriptions.remove(id);
    } else if (type == QLatin1String("ping")) {
      send({{QStringLiteral("t"), QStringLiteral("pong")}});
    } else if (type == QLatin1String("rpc")) {
      const QString method = message.value(QLatin1String("method")).toString();
      if (method.startsWith(QLatin1String("terminal."))) {
        terminalCall(socket, id, method, message.value(QLatin1String("payload")).toObject());
        return;
      }
      if (method != QLatin1String("orchestration.dispatchCommand")) {
        send({{QStringLiteral("t"), QStringLiteral("rpc.result")}, {QStringLiteral("id"), id}, {QStringLiteral("result"), QJsonValue::Null}});
        return;
      }
      const QJsonObject command = message.value(QLatin1String("payload")).toObject();
      commands.append(command);
      const QString refusal = refusals.value(command.value(QLatin1String("type")).toString());
      QPointer<QWebSocket> target = socket;
      auto answer = [this, target, id, refusal, known = refusals.contains(command.value(QLatin1String("type")).toString())] {
        if (target != m_socket) return;
        if (known) {
          send({{QStringLiteral("t"), QStringLiteral("rpc.error")}, {QStringLiteral("id"), id}, {QStringLiteral("error"), refusal}});
        } else {
          send({{QStringLiteral("t"), QStringLiteral("rpc.result")},
                {QStringLiteral("id"), id},
                {QStringLiteral("result"), QJsonObject{{QStringLiteral("sequence"), commands.size()}}}});
        }
      };
      if (holdAnswers) {
        m_held.append(answer);
      } else {
        answer();
      }
    }
  }

  void send(const QJsonObject& frame) {
    if (m_socket) m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(frame).toJson(QJsonDocument::Compact)));
  }

  QJsonObject terminalSummary(const QString& threadId, const QString& terminalId, const QString& cwd) const {
    return {
        {QStringLiteral("threadId"), threadId},
        {QStringLiteral("terminalId"), terminalId},
        {QStringLiteral("cwd"), cwd},
        {QStringLiteral("worktreePath"), QJsonValue::Null},
        {QStringLiteral("status"), QStringLiteral("running")},
        {QStringLiteral("pid"), 100},
        {QStringLiteral("exitCode"), QJsonValue::Null},
        {QStringLiteral("exitSignal"), QJsonValue::Null},
        {QStringLiteral("hasRunningSubprocess"), false},
        {QStringLiteral("label"), QString()},
        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
    };
  }

  // Opens the terminal when the input says where (as terminal.open does);
  // returns false when it does not exist and cannot be opened.
  bool ensureTerminal(const QJsonObject& input) {
    const QString threadId = input.value(QLatin1String("threadId")).toString();
    const QString terminalId = input.value(QLatin1String("terminalId")).toString();
    const QString key = threadId + QLatin1Char('/') + terminalId;
    if (terminals.contains(key)) return true;
    if (!input.contains(QLatin1String("cwd"))) return false;
    const QJsonObject summary = terminalSummary(threadId, terminalId, input.value(QLatin1String("cwd")).toString());
    terminals.insert(key, {summary, QString()});
    sendTerminals({{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
    return true;
  }

  void attach(int id, const QJsonObject& input) {
    if (!ensureTerminal(input)) {
      send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("Unknown terminal")}});
      return;
    }
    const QString key = input.value(QLatin1String("threadId")).toString() + QLatin1Char('/') +
                        input.value(QLatin1String("terminalId")).toString();
    m_terminalSubscriptions.insert(id, key);
    const Terminal& terminal = terminals[key];
    QJsonObject snapshot = terminal.summary;
    snapshot.insert(QStringLiteral("history"), terminal.history);
    send({{QStringLiteral("t"), QStringLiteral("terminal")},
          {QStringLiteral("id"), id},
          {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("snapshot"), snapshot}}}});
  }

  void terminalCall(QWebSocket* socket, int id, const QString& method, const QJsonObject& payload) {
    terminalCalls.append({{QStringLiteral("method"), method}, {QStringLiteral("payload"), payload}});
    const QString threadId = payload.value(QLatin1String("threadId")).toString();
    const QString terminalId = payload.value(QLatin1String("terminalId")).toString();
    if (method == QLatin1String("terminal.open")) ensureTerminal(payload);
    QPointer<QWebSocket> target = socket;
    auto answer = [this, target, id, method, threadId, terminalId] {
      if (target != m_socket) return;
      if (method == QLatin1String("terminal.close")) closeTerminal(threadId, terminalId);
      send({{QStringLiteral("t"), QStringLiteral("rpc.result")}, {QStringLiteral("id"), id}, {QStringLiteral("result"), QJsonValue::Null}});
    };
    if (holdAnswers) {
      m_held.append(answer);
    } else {
      answer();
    }
  }

  void sendTerminal(const QString& key, const QJsonObject& event) {
    for (auto it = m_terminalSubscriptions.cbegin(); it != m_terminalSubscriptions.cend(); ++it) {
      if (*it == key) send({{QStringLiteral("t"), QStringLiteral("terminal")}, {QStringLiteral("id"), it.key()}, {QStringLiteral("event"), event}});
    }
  }

  void sendTerminals(const QJsonObject& event) {
    if (m_terminalsSubscription < 0) return;
    send({{QStringLiteral("t"), QStringLiteral("terminals")}, {QStringLiteral("id"), m_terminalsSubscription}, {QStringLiteral("event"), event}});
  }

  QWebSocketServer m_server;
  quint16 m_port = 0;
  QPointer<QWebSocket> m_socket;
  int m_shellSubscription = -1;
  int m_terminalsSubscription = -1;
  QHash<int, QString> m_terminalSubscriptions;
  QList<std::function<void()>> m_held;
};

// ---- The world a scenario runs in -------------------------------------------

struct Failure : std::runtime_error {
  using std::runtime_error::runtime_error;
};

[[noreturn]] void fail(const QString& message) {
  throw Failure(message.toStdString());
}

void expect(bool condition, const QString& message) {
  if (!condition) fail(message);
}

QString show(const QVariant& value) {
  return QString::fromUtf8(QJsonDocument::fromVariant(value).toJson(QJsonDocument::Compact));
}

QVariant at(const QVariant& value, const QString& path) {
  QVariant current = value;
  for (const QString& part : path.split(QLatin1Char('.'))) current = current.toMap().value(part);
  return current;
}

struct PageAction {
  QString type;
  QVariantMap payload;
};

// The shell as main.cpp builds it, the page as a recorder of what the shell
// asks of it (plus the composer echo the real page makes), and the node.
class World {
public:
  World() {
    m_native.client()->setRetryDelays({20});
    m_native.sidebar()->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
    setTime(QStringLiteral("2026-09-23T10:00:00Z"));
    QObject::connect(&m_bridge, &ShellBridge::actionRequested, &m_bridge,
                     [this](const QString& type, const QVariant& payload) { onPageAction(type, payload.toMap()); });
  }

  FakeNode node;
  QList<PageAction> pageActions;
  QVariant pageNative;  // what the last `shell.native` told the page
  QVariantMap sidebarInput{{QStringLiteral("projects"), QVariantList()},
                           {QStringLiteral("drafts"), QVariantList()},
                           {QStringLiteral("localProjects"), QVariantList()},
                           {QStringLiteral("timestampFormat"), QStringLiteral("locale")}};
  QVariantMap composer;
  std::optional<qsizetype> command;  // the command the last "receives" step found
  QSet<qsizetype> checkedCommands;
  int nextEdit = 1;

  ShellBridge& bridge() { return m_bridge; }
  NativeShell& native() { return m_native; }
  QVariant state(const QString& key) const { return m_bridge.state()->value(key); }

  void setTime(const QString& iso) {
    const QDateTime now = QDateTime::fromString(iso, Qt::ISODate).toLocalTime();
    m_native.sidebar()->setClock([now] { return now; });
    m_native.composer()->setClock([now] { return now.toUTC(); });
  }

  void publishSidebarInput() { m_bridge.publish(QStringLiteral("sidebarInput"), sidebarInput); }
  void publishComposer() { m_bridge.publish(QStringLiteral("composer"), composer); }

  void connect(const QString& token = QStringLiteral("node-token")) {
    m_native.open(node.origin(), token);
    waitFor([this] { return shellSubscriptions() >= 1; }, QStringLiteral("the shell to subscribe"));
  }

  int shellSubscriptions() const {
    int count = 0;
    for (const QJsonObject& sub : node.subscriptions) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) count++;
    }
    return count;
  }

  // `what` is read on timeout, so it can describe the state the wait gave up on.
  void waitFor(const std::function<bool()>& condition, const std::function<QString()>& what) {
    if (!QTest::qWaitFor(condition, 5000)) fail(QStringLiteral("timed out waiting for ") + what());
  }
  void waitFor(const std::function<bool()>& condition, const QString& what) {
    waitFor(condition, [what] { return what; });
  }

  // A round trip through the node: everything the node sent before, and every
  // answer to a command sent before, has been handled once it returns.
  void sync() {
    bool done = false;
    m_native.client()->call(node.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                            [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    waitFor([&done] { return done; }, QStringLiteral("a round trip through the node"));
  }

  QList<PageAction> actionsOf(const QString& type) const {
    QList<PageAction> result;
    for (const PageAction& action : pageActions) {
      if (action.type == type) result.append(action);
    }
    return result;
  }

  QString describePage() const {
    QStringList lines;
    for (const PageAction& action : pageActions) lines.append(action.type + QLatin1Char(' ') + show(action.payload));
    return lines.isEmpty() ? QStringLiteral("(nothing)") : lines.join(QStringLiteral("; "));
  }

  QString describeCommands() const {
    QStringList lines;
    for (const QJsonObject& command : node.commands) {
      lines.append(QString::fromUtf8(QJsonDocument(command).toJson(QJsonDocument::Compact)));
    }
    return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
  }

private:
  void onPageAction(const QString& type, const QVariantMap& payload) {
    // The page's record of who owns what, not a request for it to act on.
    if (type == QLatin1String("shell.native")) {
      pageNative = payload;
      return;
    }
    pageActions.append({type, payload});
    // The page applies a text change to its draft and publishes it back.
    if (type == QLatin1String("composer.text.set") &&
        payload.value(QStringLiteral("target")) == composer.value(QStringLiteral("target"))) {
      composer.insert(QStringLiteral("text"), payload.value(QStringLiteral("text")));
      composer.insert(QStringLiteral("nativeSend"), QVariant::fromValue(nullptr));
      publishComposer();
    }
  }

  // Declared in teardown order: the shell goes before the bridge it intercepts.
  ShellBridge m_bridge;
  NativeShell m_native{&m_bridge};
};

// ---- Steps ------------------------------------------------------------------

using Captures = QStringList;
using StepFn = std::function<void(World&, const Captures&, const Table&)>;

struct Definition {
  QRegularExpression pattern;
  StepFn run;
};

QList<Definition>& definitions() {
  static QList<Definition> list;
  return list;
}

void step(const QString& pattern, StepFn run) {
  definitions().append({QRegularExpression(QLatin1Char('^') + pattern + QLatin1Char('$')), std::move(run)});
}

QVariantMap keyed(const QString& key) {
  return {{QStringLiteral("key"), key}};
}

QString sectionTitles(World& world, const QString& section) {
  QStringList titles;
  for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), section).toList()) {
    titles.append(row.toMap().value(QStringLiteral("title")).toString());
  }
  return titles.join(QStringLiteral(", "));
}

// Finds the first unchecked command of `type` (for `threadId`, when given).
std::optional<qsizetype> findCommand(World& world, const QString& type, const QString& threadId = {}) {
  for (qsizetype index = 0; index < world.node.commands.size(); ++index) {
    const QJsonObject& command = world.node.commands.at(index);
    if (world.checkedCommands.contains(index)) continue;
    if (command.value(QLatin1String("type")).toString() != type) continue;
    if (!threadId.isEmpty() && command.value(QLatin1String("threadId")).toString() != threadId) continue;
    return index;
  }
  return std::nullopt;
}

void expectField(const QJsonObject& command, const QString& path, const QString& expected) {
  const QVariant actual = at(command.toVariantMap(), path);
  expect(actual.toString() == expected, QStringLiteral("expected %1 to be \"%2\" in %3")
                                            .arg(path, expected, QString::fromUtf8(QJsonDocument(command).toJson(QJsonDocument::Compact))));
}

void composerOn(World& world, const QString& target, const QString& routeKind, const QString& prompt,
                const QVariant& nativeSend) {
  world.composer = {
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), routeKind},
      {QStringLiteral("text"), prompt},
      {QStringLiteral("cursor"), prompt.size()},
      {QStringLiteral("nativeSend"), nativeSend},
  };
  world.publishComposer();
}

QVariantMap plainSend(const QString& prompt, const QString& runtimeMode, const QString& interactionMode) {
  const QString text = prompt.trimmed();
  return {
      {QStringLiteral("prompt"), prompt},
      {QStringLiteral("text"), text},
      {QStringLiteral("titleSeed"), text},
      {QStringLiteral("modelSelection"),
       QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}},
      {QStringLiteral("runtimeMode"), runtimeMode},
      {QStringLiteral("interactionMode"), interactionMode},
  };
}

// Gherkin cells and strings spell control characters as `\r` and `\n`.
QString unescaped(QString text) {
  return text.replace(QStringLiteral("\\r"), QStringLiteral("\r")).replace(QStringLiteral("\\n"), QStringLiteral("\n"));
}

QString tabLabels(World& world) {
  QStringList labels;
  for (const TerminalTabs::Row& row : world.native().terminals()->tabs()->rows()) labels.append(row.label);
  return labels.join(QStringLiteral(", "));
}

TerminalSession* terminalSession(World& world, const QString& terminalId) {
  for (const TerminalTabs::Row& row : world.native().terminals()->tabs()->rows()) {
    if (row.terminalId == terminalId) return row.session;
  }
  fail(QStringLiteral("no tab for %1; the tabs are %2").arg(terminalId, tabLabels(world)));
}

// The `input` of the latest `terminal` subscription for this terminal.
std::optional<QJsonObject> terminalAttach(World& world, const QString& threadId, const QString& terminalId) {
  for (qsizetype index = world.node.subscriptions.size() - 1; index >= 0; --index) {
    const QJsonObject shape = world.node.subscriptions.at(index).value(QLatin1String("shape")).toObject();
    const QJsonObject input = shape.value(QLatin1String("input")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("terminal") &&
        input.value(QLatin1String("threadId")) == threadId && input.value(QLatin1String("terminalId")) == terminalId) {
      return input;
    }
  }
  return std::nullopt;
}

std::optional<QJsonObject> terminalCall(World& world, const QString& method, const QString& threadId,
                                        const QString& terminalId) {
  for (const QJsonObject& call : world.node.terminalCalls) {
    const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
    if (call.value(QLatin1String("method")) == method && payload.value(QLatin1String("threadId")) == threadId &&
        payload.value(QLatin1String("terminalId")) == terminalId) {
      return payload;
    }
  }
  return std::nullopt;
}

QString describeTerminalCalls(World& world) {
  QStringList lines;
  for (const QJsonObject& call : world.node.terminalCalls) {
    lines.append(QString::fromUtf8(QJsonDocument(call).toJson(QJsonDocument::Compact)));
  }
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}

QStringList terminalWrites(World& world, const QString& terminalId) {
  QStringList writes;
  for (const QJsonObject& call : world.node.terminalCalls) {
    const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
    if (call.value(QLatin1String("method")) == QLatin1String("terminal.write") &&
        payload.value(QLatin1String("terminalId")) == terminalId) {
      writes.append(payload.value(QLatin1String("data")).toString());
    }
  }
  return writes;
}

void defineSteps() {
  const QString q = QStringLiteral("\"([^\"]*)\"");

  // The node and the page.
  step(QStringLiteral("the desktop's node %1 serves the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.name = c[0];
    world.node.environmentId = c[1];
  });
  step(QStringLiteral("the node's environment does not track visits"), [](World& world, const Captures&, const Table&) {
    world.node.capabilities.remove(QStringLiteral("threadVisitedTracking"));
  });
  step(QStringLiteral("the node has these threads:"), [](World& world, const Captures&, const Table& table) {
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QJsonObject thread = threadRow(table.first(), table.at(row));
      world.node.threads.insert(thread.value(QLatin1String("id")).toString(), thread);
    }
  });
  step(QStringLiteral("the page groups %1 as the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const qsizetype colon = c[0].indexOf(QLatin1Char(':'));
    QVariantList projects = world.sidebarInput.value(QStringLiteral("projects")).toList();
    projects.append(QVariantMap{
        {QStringLiteral("key"), c[1]},
        {QStringLiteral("displayName"), c[1]},
        {QStringLiteral("environmentId"), c[0].left(colon)},
        {QStringLiteral("projectId"), c[0].mid(colon + 1)},
        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[1]},
        {QStringLiteral("memberKeys"), QStringList{c[0]}},
    });
    world.sidebarInput.insert(QStringLiteral("projects"), projects);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page stops grouping %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantList projects;
    for (const QVariant& project : world.sidebarInput.value(QStringLiteral("projects")).toList()) {
      if (!project.toMap().value(QStringLiteral("memberKeys")).toStringList().contains(c[0])) projects.append(project);
    }
    world.sidebarInput.insert(QStringLiteral("projects"), projects);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("activeThreadKey"), c[0]);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page's sidebar is scoped to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("scopeProjectKey"), c[0]);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page's timestamps are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("timestampFormat"), c[0]);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the time is %1").arg(q), [](World& world, const Captures& c, const Table&) { world.setTime(c[0]); });

  // Connecting.
  step(QStringLiteral("the desktop shell connects to its node with the token %1").arg(q),
       [](World& world, const Captures& c, const Table&) { world.connect(c[0]); });
  step(QStringLiteral("the desktop shell connects to its node"), [](World& world, const Captures&, const Table&) { world.connect(); });
  step(QStringLiteral("the desktop shell is connected to its node"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); },
                  QStringLiteral("the shell to take over"));
  });
  step(QStringLiteral("the node holds back its snapshot"), [](World& world, const Captures&, const Table&) {
    world.node.holdSnapshot = true;
  });
  step(QStringLiteral("the node sends its snapshot"), [](World& world, const Captures&, const Table&) {
    world.node.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("the node stops accepting connections"), [](World& world, const Captures&, const Table&) {
    world.node.stopAccepting();
  });
  step(QStringLiteral("the node drops the connection"), [](World& world, const Captures&, const Table&) {
    world.node.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the node was reached with the token %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!world.node.connections.isEmpty(), QStringLiteral("the node was never reached"));
    const QUrl url = world.node.connections.first();
    expect(url.path() == QLatin1String("/ws"), QStringLiteral("connected to %1, not /ws").arg(url.path()));
    const QString token = QUrlQuery(url).queryItemValue(QStringLiteral("token"));
    expect(token == c[0], QStringLiteral("connected with the token \"%1\"").arg(token));
  });
  step(QStringLiteral("the shell subscribed to the node's %1 shape( again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const int wanted = c.value(1).isEmpty() ? 1 : 2;
    world.waitFor([&] {
      int count = 0;
      for (const QJsonObject& sub : world.node.subscriptions) {
        if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")).toString() == c[0]) count++;
      }
      return count >= wanted;
    }, QStringLiteral("%1 subscription(s) to %2").arg(wanted).arg(c[0]));
  });
  step(QStringLiteral("the shell reconnects to the node"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return world.node.connections.size() >= 2 && world.native().client()->isReady(); },
                  QStringLiteral("a second connection"));
  });
  step(QStringLiteral("the shell has not taken over from the page"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.state(QStringLiteral("native")).isValid(),
           QStringLiteral("native is %1").arg(show(world.state(QStringLiteral("native")))));
  });
  step(QStringLiteral("the shell tells the page it owns the sidebar and the composer"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return world.pageNative.isValid(); }, QStringLiteral("the page to be told"));
    const QVariantMap native = world.pageNative.toMap();
    expect(native.value(QStringLiteral("sidebar")).toBool() && native.value(QStringLiteral("composer")).toBool(),
           QStringLiteral("the page was told %1").arg(show(native)));
    expect(world.state(QStringLiteral("native")) == world.pageNative,
           QStringLiteral("native is %1").arg(show(world.state(QStringLiteral("native")))));
  });
  step(QStringLiteral("the shell tells the page it owns the composer but not the sidebar"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return world.pageNative.isValid() && !world.pageNative.toMap().value(QStringLiteral("sidebar")).toBool(); },
                  [&world] { return QStringLiteral("the page to keep the sidebar; it was told %1").arg(show(world.pageNative)); });
    expect(world.pageNative.toMap().value(QStringLiteral("composer")).toBool(),
           QStringLiteral("the page was told %1").arg(show(world.pageNative)));
    expect(world.state(QStringLiteral("native")) == world.pageNative,
           QStringLiteral("native is %1").arg(show(world.state(QStringLiteral("native")))));
  });
  step(QStringLiteral("the page has not been told who owns the sidebar"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.pageNative.isValid(), QStringLiteral("the page was told %1").arg(show(world.pageNative)));
  });
  step(QStringLiteral("the page forgets who owns the sidebar"), [](World& world, const Captures&, const Table&) {
    world.pageNative = QVariant();
  });
  step(QStringLiteral("the page asks who owns the sidebar"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("shell.native.query"));
  });
  step(QStringLiteral("the page publishes its own sidebar"), [](World& world, const Captures&, const Table&) {
    auto* channel = static_cast<ShellChannel*>(world.bridge().channel());
    channel->publish(QStringLiteral("sidebar"), QVariantMap{{QStringLiteral("active"), QVariantList()}});
  });

  // Node updates.
  step(QStringLiteral("the node updates the thread %1 with the title %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject& row = world.node.threads[c[0]];
    row.insert(QStringLiteral("title"), c[1]);
    world.node.sendRow(c[0], row);
    world.sync();
  });
  step(QStringLiteral("the node updates the thread %1 with:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QJsonObject& row = world.node.threads[c[0]];
    for (const QStringList& cells : table) setField(row, cells.value(0), cells.value(1));
    world.node.sendRow(c[0], row);
    world.sync();
  });
  step(QStringLiteral("the node deletes the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject row = world.node.threads.take(c[0]);
    row.insert(QStringLiteral("deletedAt"), QStringLiteral("2026-09-23T10:00:00Z"));
    world.node.sendRow(c[0], row);
    world.sync();
  });
  step(QStringLiteral("the node refuses %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.refusals.insert(c[0], c[1]);
  });
  step(QStringLiteral("the node holds its answers"), [](World& world, const Captures&, const Table&) {
    world.node.holdAnswers = true;
  });
  step(QStringLiteral("the node answers"), [](World& world, const Captures&, const Table&) {
    world.sync();  // every held command has reached the node
    world.node.holdAnswers = false;
    world.node.answerHeld();
    world.sync();
  });

  // The user in the shell.
  const auto dispatch = [](const QString& type) {
    return [type](World& world, const Captures& c, const Table&) { world.bridge().dispatch(type, keyed(c[0])); };
  };
  step(QStringLiteral("the user settles %1").arg(q), dispatch(QStringLiteral("thread.settle")));
  step(QStringLiteral("the user un-settles %1").arg(q), dispatch(QStringLiteral("thread.unsettle")));
  step(QStringLiteral("the user wakes %1").arg(q), dispatch(QStringLiteral("thread.unsnooze")));
  step(QStringLiteral("the user marks %1 unread").arg(q), dispatch(QStringLiteral("thread.markUnread")));
  step(QStringLiteral("the user dismisses the woke pill on %1").arg(q), dispatch(QStringLiteral("thread.wokeDismiss")));
  step(QStringLiteral("the user dispatches %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(c[0], keyed(c[1]));
  });
  step(QStringLiteral("the user scopes the sidebar to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("sidebar.scope"), QVariantMap{{QStringLiteral("projectKey"), c[0]}});
  });
  step(QStringLiteral("the user clears the sidebar's scope"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("sidebar.scope"),
                            QVariantMap{{QStringLiteral("projectKey"), QVariant::fromValue(nullptr)}});
  });
  step(QStringLiteral("the user opens the snooze menu for %1 at (\\d+), (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.snoozeMenu"), QVariantMap{
                                                                     {QStringLiteral("key"), c[0]},
                                                                     {QStringLiteral("x"), c[1].toDouble()},
                                                                     {QStringLiteral("y"), c[2].toDouble()},
                                                                 });
  });
  const auto choose = [](World& world, const QVariant& id) {
    const QVariant menu = world.state(QStringLiteral("contextMenu"));
    expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
    world.bridge().dispatch(QStringLiteral("contextMenu.select"),
                            QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
  };
  step(QStringLiteral("the user picks %1").arg(q), [choose](World& world, const Captures& c, const Table&) { choose(world, c[0]); });
  step(QStringLiteral("the user dismisses the menu"), [choose](World& world, const Captures&, const Table&) {
    choose(world, QVariant::fromValue(nullptr));
  });

  // The composer.
  step(QStringLiteral("the composer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("server"), QString(), QVariant::fromValue(nullptr));
  });
  step(QStringLiteral("the composer shows %1 with the plain prompt %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("server"), c[1], plainSend(c[1], QStringLiteral("full-access"), QStringLiteral("default")));
  });
  step(QStringLiteral("the composer shows %1 with the plain prompt %1 in %1 and %1 modes").arg(q),
       [](World& world, const Captures& c, const Table&) {
         composerOn(world, c[0], QStringLiteral("server"), c[1], plainSend(c[1], c[2], c[3]));
       });
  step(QStringLiteral("the composer shows the draft %1 with the plain prompt %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("draft"), c[1], plainSend(c[1], QStringLiteral("full-access"), QStringLiteral("default")));
  });
  step(QStringLiteral("the user stops the turn"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.interrupt"));
  });
  step(QStringLiteral("the user sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{
                                {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                     {QStringLiteral("revision"), world.nextEdit++}}},
                                {QStringLiteral("text"), c[0]},
                                {QStringLiteral("intent"), QStringLiteral("foreground")},
                            });
  });
  step(QStringLiteral("the user types %1 into the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    world.composer.insert(QStringLiteral("text"), c[0]);
    world.publishComposer();
  });

  // What the node received.
  step(QStringLiteral("the node receives an? %1 command for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return findCommand(world, c[0], c[1]).has_value(); },
                  [&] { return QStringLiteral("a %1 command for %2; the node has %3").arg(c[0], c[1], world.describeCommands()); });
    world.command = findCommand(world, c[0], c[1]);
    world.checkedCommands.insert(*world.command);
  });
  step(QStringLiteral("the command's %1 is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.command.has_value(), QStringLiteral("no command was found before"));
    expectField(world.node.commands.at(*world.command), c[0], c[1]);
  });
  step(QStringLiteral("the command %1 has %1 %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QJsonObject& command : world.node.commands) {
      if (command.value(QLatin1String("type")).toString() == c[0]) return expectField(command, c[1], c[2]);
    }
    fail(QStringLiteral("no %1 command; the node has %2").arg(c[0], world.describeCommands()));
  });
  step(QStringLiteral("the node receives these commands in order:"), [](World& world, const Captures&, const Table& table) {
    const qsizetype wanted = table.size() - 1;
    world.waitFor([&] { return world.node.commands.size() >= wanted; }, QStringLiteral("%1 commands").arg(wanted));
    world.sync();
    expect(world.node.commands.size() == wanted, QStringLiteral("the node has %1").arg(world.describeCommands()));
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QString type = world.node.commands.at(row - 1).value(QLatin1String("type")).toString();
      expect(type == table.at(row).value(0), QStringLiteral("command %1 is %2, not %3").arg(row).arg(type, table.at(row).value(0)));
      world.checkedCommands.insert(row - 1);
    }
  });
  step(QStringLiteral("the node receives these messages in order:"), [](World& world, const Captures&, const Table& table) {
    const auto texts = [&] {
      QStringList texts;
      for (const QJsonObject& command : world.node.commands) {
        if (command.value(QLatin1String("type")).toString() == QLatin1String("message.dispatch")) {
          texts.append(command.value(QLatin1String("text")).toString());
        }
      }
      return texts;
    };
    QStringList wanted;
    for (qsizetype row = 1; row < table.size(); ++row) wanted.append(table.at(row).value(0));
    world.waitFor([&] { return texts().size() >= wanted.size(); }, QStringLiteral("%1 messages").arg(wanted.size()));
    world.sync();
    expect(texts() == wanted, QStringLiteral("the node has the messages %1").arg(texts().join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the node receives no commands"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.node.commands.isEmpty(), QStringLiteral("the node has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the node receives no other commands"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.node.commands.size() == world.checkedCommands.size(),
           QStringLiteral("the node has %1").arg(world.describeCommands()));
  });

  // The sidebar and menu the shell shows.
  step(QStringLiteral("the sidebar's %1 section lists %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString titles = sectionTitles(world, c[0]);
    expect(titles == c[1], QStringLiteral("%1 lists \"%2\"").arg(c[0], titles));
  });
  step(QStringLiteral("the sidebar's %1 section is empty").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString titles = sectionTitles(world, c[0]);
    expect(titles.isEmpty(), QStringLiteral("%1 lists \"%2\"").arg(c[0], titles));
  });
  step(QStringLiteral("the page is told the sidebar is scoped to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QList<PageAction> scopes = world.actionsOf(QStringLiteral("sidebar.scope"));
    expect(!scopes.isEmpty() && scopes.last().payload.value(QStringLiteral("projectKey")) == c[0],
           QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the sidebar is not scoped"), [](World& world, const Captures&, const Table&) {
    const QVariant scope = at(world.state(QStringLiteral("sidebar")), QStringLiteral("scopeProjectKey"));
    expect(scope.isNull(), QStringLiteral("the sidebar is scoped to %1").arg(scope.toString()));
  });
  step(QStringLiteral("the shell shows a menu at (\\d+), (\\d+) with:"), [](World& world, const Captures& c, const Table& table) {
    const QVariant menu = world.state(QStringLiteral("contextMenu"));
    expect(at(menu, QStringLiteral("x")).toInt() == c[0].toInt() && at(menu, QStringLiteral("y")).toInt() == c[1].toInt(),
           QStringLiteral("the menu is %1").arg(show(menu)));
    Table actual{table.first()};
    for (const QVariant& item : at(menu, QStringLiteral("items")).toList()) {
      actual.append({item.toMap().value(QStringLiteral("id")).toString(), item.toMap().value(QStringLiteral("label")).toString()});
    }
    expect(actual == table, QStringLiteral("the menu is %1").arg(show(menu)));
  });
  step(QStringLiteral("the menu closes"), [](World& world, const Captures&, const Table&) {
    const QVariant menu = world.state(QStringLiteral("contextMenu"));
    expect(menu.isNull(), QStringLiteral("the menu is %1").arg(show(menu)));
  });

  // What the page is asked to do.
  step(QStringLiteral("nothing reaches the page"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.pageActions.isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the action %1 for %1 reaches the page").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const PageAction& action : world.actionsOf(c[0])) {
      if (action.payload.value(QStringLiteral("key")).toString() == c[1]) return;
    }
    fail(QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the action %1 reaches the page").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!world.actionsOf(c[0]).isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the page shows an? %1 toast %1 saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const PageAction& toast : world.actionsOf(QStringLiteral("toast.show"))) {
        if (toast.payload.value(QStringLiteral("toastType")) == c[0] && toast.payload.value(QStringLiteral("title")) == c[1] &&
            toast.payload.value(QStringLiteral("description")) == c[2]) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("the toast; the page got %1").arg(world.describePage()); });
  });
  step(QStringLiteral("the page shows an? %1 toast %1 with an %1 action that dispatches %1 for %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.waitFor([&] { return !world.actionsOf(QStringLiteral("toast.show")).isEmpty(); }, QStringLiteral("a toast"));
         const QVariantMap toast = world.actionsOf(QStringLiteral("toast.show")).last().payload;
         const QVariantMap expected{
             {QStringLiteral("toastType"), c[0]},
             {QStringLiteral("title"), c[1]},
             {QStringLiteral("action.label"), c[2]},
             {QStringLiteral("action.dispatch.type"), c[3]},
             {QStringLiteral("action.dispatch.payload.key"), c[4]},
         };
         for (auto it = expected.cbegin(); it != expected.cend(); ++it) {
           expect(at(toast, it.key()).toString() == it->toString(), QStringLiteral("the toast is %1").arg(show(toast)));
         }
       });
  const auto opened = [](World& world, const QString& type, const QString& field, const QString& value) {
    world.waitFor([&] {
      for (const PageAction& action : world.actionsOf(type)) {
        if (action.payload.value(field).toString() == value) return true;
      }
      return false;
    }, [&] { return QStringLiteral("%1 %2; the page got %3").arg(type, value, world.describePage()); });
  };
  step(QStringLiteral("the page is asked to open %1").arg(q), [opened](World& world, const Captures& c, const Table&) {
    opened(world, QStringLiteral("thread.open"), QStringLiteral("key"), c[0]);
  });
  step(QStringLiteral("the page is asked to open a new thread in %1").arg(q), [opened](World& world, const Captures& c, const Table&) {
    opened(world, QStringLiteral("thread.new"), QStringLiteral("projectKey"), c[0]);
  });
  step(QStringLiteral("the page is not asked to open anything"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.actionsOf(QStringLiteral("thread.open")).isEmpty() && world.actionsOf(QStringLiteral("thread.new")).isEmpty(),
           QStringLiteral("the page got %1").arg(world.describePage()));
  });
  const auto textSet = [](World& world, const QString& target, const QString& text) {
    for (const PageAction& action : world.actionsOf(QStringLiteral("composer.text.set"))) {
      if (action.payload.value(QStringLiteral("target")) == target && action.payload.value(QStringLiteral("text")) == text) {
        return true;
      }
    }
    return false;
  };
  step(QStringLiteral("the page is asked to set the composer text for %1 to %1").arg(q), [textSet](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return textSet(world, c[0], c[1]); },
                  [&] { return QStringLiteral("the composer text; the page got %1").arg(world.describePage()); });
  });
  step(QStringLiteral("the page is asked to set the composer text for %1 to the prompts:").arg(q),
       [textSet](World& world, const Captures& c, const Table& table) {
         QStringList prompts;
         for (qsizetype row = 1; row < table.size(); ++row) prompts.append(table.at(row).value(0));
         const QString text = prompts.join(QStringLiteral("\n\n"));
         world.waitFor([&] { return textSet(world, c[0], text); },
                       [&] { return QStringLiteral("the composer text; the page got %1").arg(world.describePage()); });
       });
  step(QStringLiteral("the page is not asked to set the composer text for %1 to %1").arg(q),
       [textSet](World& world, const Captures& c, const Table&) {
         world.sync();
         expect(!textSet(world, c[0], c[1]), QStringLiteral("the page got %1").arg(world.describePage()));
       });
  // The terminal drawer.
  const auto terminals = [](World& world) { return world.native().terminals(); };
  step(QStringLiteral("the node has the project %1 at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), c[1]}, {QStringLiteral("scripts"), QJsonArray()}});
  });
  step(QStringLiteral("the project %1 has these scripts:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QJsonArray scripts;
    for (qsizetype row = 1; row < table.size(); ++row) {
      QJsonObject script;
      for (qsizetype column = 0; column < table.first().size(); ++column) script.insert(table.first().at(column), table.at(row).value(column));
      scripts.append(script);
    }
    world.node.projects[c[0]].insert(QStringLiteral("scripts"), scripts);
  });
  step(QStringLiteral("the node runs these terminals for %1:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QStringList& header = table.first();
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QStringList& cells = table.at(row);
      world.node.addTerminal(c[0], cells.value(header.indexOf(QStringLiteral("terminal"))),
                             header.contains(QStringLiteral("label")) ? cells.value(header.indexOf(QStringLiteral("label"))) : QString(),
                             header.contains(QStringLiteral("busy")) && cells.value(header.indexOf(QStringLiteral("busy"))) == QLatin1String("yes"));
    }
    world.sync();
  });
  step(QStringLiteral("the node prints %1 in %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.print(c[2], c[1], unescaped(c[0]));
    world.sync();
  });
  step(QStringLiteral("the node closes %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.closeTerminal(c[1], c[0]);
    world.sync();
  });
  step(QStringLiteral("the user toggles the terminal drawer"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user opens a new terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.new"));
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user selects %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.select"), QVariantMap{{QStringLiteral("terminalId"), c[0]}});
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user closes the active terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.close"));
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user runs the script %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), c[0]}});
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user types %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    terminalSession(world, c[1])->write(unescaped(c[0]));
  });
  step(QStringLiteral("the terminal drawer is unavailable"), [terminals](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!terminals(world)->available(), QStringLiteral("the terminal drawer is available"));
  });
  step(QStringLiteral("the terminal drawer is closed"), [terminals](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer to close"));
  });
  step(QStringLiteral("the terminal drawer shows the tabs %1").arg(q), [terminals](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return terminals(world)->isOpen() && tabLabels(world) == c[0]; },
                  [&] { return QStringLiteral("the tabs %1; the drawer is %2 with %3").arg(c[0], terminals(world)->isOpen() ? QStringLiteral("open") : QStringLiteral("closed"), tabLabels(world)); });
  });
  step(QStringLiteral("the active terminal is %1").arg(q), [terminals](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return terminals(world)->activeTerminalId() == c[0]; },
                  [&] { return QStringLiteral("%1 to be active; it is %2").arg(c[0], terminals(world)->activeTerminalId()); });
  });
  step(QStringLiteral("the node attaches %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto input = terminalAttach(world, c[1], c[0]);
      return input && input->value(QLatin1String("cwd")) == c[2];
    }, QStringLiteral("%1 of %2 to attach in %3").arg(c[0], c[1], c[2]));
  });
  step(QStringLiteral("%1 of %1 starts with %1 set to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto input = terminalAttach(world, c[1], c[0]);
    expect(input.has_value(), QStringLiteral("%1 of %2 never attached").arg(c[0], c[1]));
    const QString value = input->value(QLatin1String("env")).toObject().value(c[2]).toString();
    expect(value == c[3], QStringLiteral("%1 is \"%2\"").arg(c[2], value));
  });
  step(QStringLiteral("%1 of %1 is still attached").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(world.node.attached().contains(c[1] + QLatin1Char('/') + c[0]), QStringLiteral("%1 of %2 was let go").arg(c[0], c[1]));
  });
  step(QStringLiteral("the node is asked to open %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.open"), c[1], c[0]);
      return payload && payload->value(QLatin1String("cwd")) == c[2];
    }, [&] { return QStringLiteral("terminal.open; the node got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the node is not asked to open a terminal"), [](World& world, const Captures&, const Table&) {
    world.sync();
    for (const QJsonObject& call : world.node.terminalCalls) {
      expect(call.value(QLatin1String("method")) != QLatin1String("terminal.open"), QStringLiteral("the node got %1").arg(describeTerminalCalls(world)));
    }
  });
  step(QStringLiteral("the node is asked to close %1 of %1 and delete its history").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.close"), c[1], c[0]);
      return payload && payload->value(QLatin1String("deleteHistory")).toBool();
    }, [&] { return QStringLiteral("terminal.close; the node got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the node receives these writes to %1:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QStringList wanted;
    for (qsizetype row = 1; row < table.size(); ++row) wanted.append(unescaped(table.at(row).value(0)));
    world.waitFor([&] { return terminalWrites(world, c[0]).size() >= wanted.size(); },
                  [&] { return QStringLiteral("%1 writes; the node got %2").arg(wanted.size()).arg(describeTerminalCalls(world)); });
    world.sync();
    expect(terminalWrites(world, c[0]) == wanted, QStringLiteral("the node got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("%1 shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString transcript = terminalSession(world, c[0])->transcript();
    expect(transcript.contains(unescaped(c[1])), QStringLiteral("%1 shows \"%2\"").arg(c[0], transcript));
  });
  step(QStringLiteral("the page shows an? %1 toast %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const PageAction& toast : world.actionsOf(QStringLiteral("toast.show"))) {
        if (toast.payload.value(QStringLiteral("toastType")) == c[0] && toast.payload.value(QStringLiteral("title")) == c[1]) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the toast; the page got %1").arg(world.describePage()); });
  });
}

void runStep(World& world, const Step& step) {
  const Definition* found = nullptr;
  QRegularExpressionMatch match;
  for (const Definition& definition : definitions()) {
    QRegularExpressionMatch candidate = definition.pattern.match(step.text);
    if (!candidate.hasMatch()) continue;
    if (found) fail(QStringLiteral("ambiguous step: ") + step.text);
    found = &definition;
    match = candidate;
  }
  if (!found) fail(QStringLiteral("undefined step: ") + step.text);
  Captures captures = match.capturedTexts();
  captures.removeFirst();
  found->run(world, captures, step.table);
}

QList<Scenario> collectScenarios() {
  const QDir root(QStringLiteral(HAL_C2_FEATURES_DIR));
  QStringList globs{QStringLiteral("desktop/native-*.feature")};
  if (const QString requested = qEnvironmentVariable("HAL_C2_FEATURES"); !requested.isEmpty()) {
    globs = requested.split(QLatin1Char(' '), Qt::SkipEmptyParts);
  }
  QStringList files;
  QDirIterator it(root.path(), {QStringLiteral("*.feature")}, QDir::Files, QDirIterator::Subdirectories);
  while (it.hasNext()) {
    const QString path = it.next();
    const QString relative = root.relativeFilePath(path);
    for (const QString& glob : globs) {
      if (QRegularExpression::fromWildcard(glob, Qt::CaseSensitive, QRegularExpression::NonPathWildcardConversion)
              .match(relative)
              .hasMatch()) {
        files.append(path);
        break;
      }
    }
  }
  files.sort();
  QList<Scenario> scenarios;
  for (const QString& file : files) {
    for (const Scenario& scenario : parseFeature(file)) {
      if (!scenario.tags.contains(QStringLiteral("@desktop"))) continue;
      if (scenario.tags.contains(QStringLiteral("@backlog")) || scenario.tags.contains(QStringLiteral("@dropped"))) continue;
      scenarios.append(scenario);
    }
  }
  return scenarios;
}

}  // namespace

class tst_Features : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() {
    defineSteps();
    m_scenarios = collectScenarios();
    QVERIFY2(!m_scenarios.isEmpty(), "no scenarios matched");
  }

  void scenarios_data() {
    QTest::addColumn<int>("index");
    const QDir root(QStringLiteral(HAL_C2_FEATURES_DIR));
    for (qsizetype index = 0; index < m_scenarios.size(); ++index) {
      const Scenario& scenario = m_scenarios.at(index);
      QTest::newRow(qPrintable(root.relativeFilePath(scenario.file) + QStringLiteral(": ") + scenario.name))
          << static_cast<int>(index);
    }
  }

  void scenarios() {
    QFETCH(int, index);
    const Scenario& scenario = m_scenarios.at(index);
    World world;
    for (const Step& step : scenario.steps) {
      try {
        runStep(world, step);
      } catch (const Failure& failure) {
        const QString message = QStringLiteral("%1:%2 %3\n  %4")
                                    .arg(QDir(QStringLiteral(HAL_C2_FEATURES_DIR)).relativeFilePath(scenario.file))
                                    .arg(step.line)
                                    .arg(step.text, QString::fromStdString(failure.what()));
        QFAIL(qPrintable(message));
      }
    }
  }

private:
  QList<Scenario> m_scenarios;
};

int main(int argc, char** argv) {
  // Snooze presets and wake labels are wall-clock times: pin them to UTC.
  qputenv("TZ", "UTC");
  tzset();
  QGuiApplication app(argc, argv);
  tst_Features test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_Features.moc"
