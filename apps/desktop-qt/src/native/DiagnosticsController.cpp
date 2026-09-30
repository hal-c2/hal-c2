// Settings → Diagnostics, natively (the web's DiagnosticsSettings): what this
// node started and how much it uses, its resource history, and its recent
// trace failures, from the node's `server.getProcessDiagnostics`,
// `server.getProcessResourceHistory`, `server.getTraceDiagnostics` and
// `server.signalProcess` (apps/server-ex HalC2.Diagnostics). Read when the
// page opens and on refresh.
//
// Publishes `diagnostics`: {
//   processes: {loading, error, serverPid, count, cpu, memory,
//     rows: [{pid, name, command, cpu, memory, type, depth, signaling}]},
//   history: {loading, error, windowMs, windows: [{label, windowMs}],
//     cpuTime, samples, interval, count,
//     rows: [{pid, name, command, avgCpu, maxCpu, maxMemory, cpuTime}]},
//   traces: {loading, error, spans, failures, slowSpans, parseErrors,
//     latestFailures: [{name, cause, duration}], commonFailures: [{name, cause, count}],
//     slowestSpans: [{name, duration}]},
//   logs: {available, error}}
// with numbers formatted as the web formats them.
//
// Actions: `diagnostics.refresh`, `diagnostics.window {windowMs}`,
// `diagnostics.signal {pid, signal}` (SIGINT, or SIGKILL once the user
// confirms), `diagnostics.openLogs` (the logs folder in the preferred
// editor).

#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>
#include <QRegularExpression>
#include <QVariantMap>

#include "MenuController.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const QString kSection = QStringLiteral("/settings/diagnostics");
const QString kLastEditor = QStringLiteral("lastEditor");

struct Window {
  const char* label;
  int windowMs;
  int bucketMs;
};
constexpr Window kWindows[] = {
    {"5m", 5 * 60'000, 30'000},
    {"15m", 15 * 60'000, 60'000},
    {"30m", 30 * 60'000, 2 * 60'000},
    {"1h", 60 * 60'000, 5 * 60'000},
};

QString count(double value) { return QLocale(QLocale::English).toString(qint64(value)); }

QString duration(double ms) {
  if (ms < 1000) return QStringLiteral("%1 ms").arg(qRound64(ms));
  return QStringLiteral("%1 s").arg(ms / 1000, 0, 'f', ms >= 10'000 ? 1 : 2);
}

QString bytes(double value) {
  if (value < 1024) return QStringLiteral("%1 B").arg(qint64(value));
  static const char* units[] = {"KB", "MB", "GB"};
  int unit = -1;
  do {
    value /= 1024;
    ++unit;
  } while (value >= 1024 && unit < 2);
  return QStringLiteral("%1 %2").arg(value, 0, 'f', value >= 10 ? 1 : 2).arg(QLatin1String(units[unit]));
}

QString cpuTime(double seconds) {
  if (seconds < 60) return QStringLiteral("%1s").arg(seconds, 0, 'f', seconds >= 10 ? 1 : 2);
  const double minutes = seconds / 60;
  if (minutes < 60) return QStringLiteral("%1m").arg(minutes, 0, 'f', minutes >= 10 ? 1 : 2);
  return QStringLiteral("%1h").arg(minutes / 60, 0, 'f', 2);
}

QString percent(double value) { return QStringLiteral("%1%").arg(value, 0, 'f', 1); }

// The executable's name, as the web's formatProcessName.
QString processName(const QString& command) {
  static const QRegularExpression space(QStringLiteral("\\s+"));
  QString first = command.trimmed().split(space).value(0);
  if (first.isEmpty()) return command;
  if (first.startsWith(QLatin1Char('"')) || first.startsWith(QLatin1Char('\''))) first.remove(0, 1);
  if (first.endsWith(QLatin1Char('"')) || first.endsWith(QLatin1Char('\''))) first.chop(1);
  static const QRegularExpression separator(QStringLiteral("[\\\\/]"));
  const QStringList segments = first.split(separator, Qt::SkipEmptyParts);
  return segments.isEmpty() ? first : segments.last();
}

QString processType(const QJsonObject& process) {
  if (process.value(QLatin1String("depth")).toInt() > 0) return QStringLiteral("Subprocess");
  static const QRegularExpression agent(QStringLiteral("\\b(codex|claude|opencode|cursor)\\b"),
                                        QRegularExpression::CaseInsensitiveOption);
  return agent.match(process.value(QLatin1String("command")).toString()).hasMatch() ? QStringLiteral("Agent")
                                                                                    : QStringLiteral("Process");
}

// An Option's value (`{_tag: "Some", value}`), or null.
QJsonValue option(const QJsonValue& value) {
  const QJsonObject object = value.toObject();
  return object.value(QLatin1String("_tag")) == QLatin1String("Some") ? object.value(QLatin1String("value")) : QJsonValue();
}

QVariant nullable(const QString& value) {
  return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value);
}

}  // namespace

class DiagnosticsController : public QObject, public NativeController {
public:
  DiagnosticsController(ShellBridge* bridge, NodeClient* client, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    m_bridge->claimKey(QStringLiteral("diagnostics"));
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    auto opened = [navigation] { return navigation->route() == NavigationController::Route::settings(kSection); };
    connect(navigation, &NavigationController::changed, this, [this, opened] {
      const bool open = opened();
      if (open == m_open) return;
      m_open = open;
      if (open) refresh();
    });
    connect(settings(), &SettingsController::configChanged, this, &DiagnosticsController::publish);
    m_open = opened();
    if (m_open) refresh();
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("diagnostics."))) return false;
    const QVariantMap input = payload.toMap();
    if (action == QLatin1String("diagnostics.refresh")) {
      refresh();
    } else if (action == QLatin1String("diagnostics.window")) {
      const int windowMs = input.value(QStringLiteral("windowMs")).toInt();
      if (std::any_of(std::begin(kWindows), std::end(kWindows), [&](const Window& w) { return w.windowMs == windowMs; })) {
        m_windowMs = windowMs;
        readHistory();
      }
    } else if (action == QLatin1String("diagnostics.signal")) {
      signal(input.value(QStringLiteral("pid")).toInt(), input.value(QStringLiteral("signal")).toString());
    } else if (action == QLatin1String("diagnostics.openLogs")) {
      openLogs();
    }
    return true;
  }

private:
  struct Read {
    bool loading = false;
    QString error;
    QJsonObject data;
    quint64 generation = 0;
  };

  SettingsController* settings() const { return NativeShell::of(this)->controller<SettingsController>(); }

  void refresh() {
    readProcesses();
    readHistory();
    read(m_traces, QStringLiteral("server.getTraceDiagnostics"), QJsonObject());
  }
  void readProcesses() { read(m_processes, QStringLiteral("server.getProcessDiagnostics"), QJsonObject()); }
  void readHistory() {
    int bucketMs = 60'000;
    for (const Window& window : kWindows) {
      if (window.windowMs == m_windowMs) bucketMs = window.bucketMs;
    }
    read(m_history, QStringLiteral("server.getProcessResourceHistory"),
         QJsonObject{{QStringLiteral("windowMs"), m_windowMs}, {QStringLiteral("bucketMs"), bucketMs}});
  }

  // Only the latest read of each lands.
  void read(Read& slot, const QString& method, const QJsonObject& payload) {
    slot.loading = true;
    const quint64 generation = ++slot.generation;
    Read* target = &slot;
    m_client->call(this, m_client->environment(), method, payload,
                   [this, target, generation](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != target->generation) return;
                     target->loading = false;
                     target->error = error.value_or(QString());
                     if (!error) target->data = result.toObject();
                     publish();
                   });
    publish();
  }

  // The web's signalProcess: SIGKILL asks first, and a process that is no
  // longer the one listed is left alone.
  void signal(int pid, const QString& signal) {
    if (signal != QLatin1String("SIGINT") && signal != QLatin1String("SIGKILL")) return;
    if (m_signaling != 0) return;
    const QJsonObject process = listed(pid);
    if (process.isEmpty()) return;
    const qint64 startTimeMs = process.value(QLatin1String("startTimeMs")).toInteger();
    auto send = [this, pid, signal, startTimeMs] {
      if (m_signaling != 0) return;
      if (listed(pid).value(QLatin1String("startTimeMs")).toInteger() != startTimeMs) return;
      m_signaling = pid;
      publish();
      auto* toasts = NativeShell::of(this)->controller<ToastController>();
      m_client->call(this, m_client->environment(), QStringLiteral("server.signalProcess"),
                     QJsonObject{{QStringLiteral("pid"), pid}, {QStringLiteral("startTimeMs"), startTimeMs}, {QStringLiteral("signal"), signal}},
                     [this, toasts, signal](const QJsonValue& result, const std::optional<QString>& error) {
                       m_signaling = 0;
                       if (error) {
                         toasts->error(QStringLiteral("Could not send %1").arg(signal), *error);
                         publish();
                         return;
                       }
                       const QJsonObject answer = result.toObject();
                       if (!answer.value(QLatin1String("signaled")).toBool()) {
                         const QString message = option(answer.value(QLatin1String("message"))).toString();
                         if (message.contains(QLatin1String("not a live descendant")) || message == QLatin1String("That process has already exited.")) {
                           toasts->show(QStringLiteral("info"), QStringLiteral("Process already exited"),
                                        QStringLiteral("The process is not a child of the HAL-C2 Server. It might already have exited."));
                         } else {
                           toasts->error(QStringLiteral("Could not send %1").arg(signal),
                                         message.isEmpty() ? QStringLiteral("Failed to send %1.").arg(signal) : message);
                         }
                       }
                       readProcesses();
                     });
    };
    if (signal == QLatin1String("SIGKILL")) {
      NativeShell::of(this)->controller<MenuController>()->confirm(
          QStringLiteral("Send SIGKILL to process %1? This cannot be handled by the process.").arg(pid), QString(),
          QStringLiteral("Send SIGKILL"), true, send);
    } else {
      send();
    }
  }

  QJsonObject listed(int pid) const {
    for (const QJsonValue& value : m_processes.data.value(QLatin1String("processes")).toArray()) {
      if (value.toObject().value(QLatin1String("pid")).toInt() == pid) return value.toObject();
    }
    return {};
  }

  QString logsPath() const {
    return settings()->config().value(QLatin1String("observability")).toObject().value(QLatin1String("logsDirectoryPath")).toString();
  }

  // The web's openLogsDirectory: the editor last used when the node has it,
  // else the first it has.
  void openLogs() {
    const QString path = logsPath();
    if (path.isEmpty()) return;
    const QJsonArray available = settings()->config().value(QLatin1String("availableEditors")).toArray();
    const QString last = settings()->deviceValue(kLastEditor).toString();
    const QString editor = available.contains(last) ? last : available.isEmpty() ? QString() : available.first().toString();
    if (editor.isEmpty()) {
      m_logsError = QStringLiteral("No available editors found.");
      publish();
      return;
    }
    settings()->writeDevice(kLastEditor, editor);
    m_logsError.clear();
    publish();
    m_client->call(this, m_client->environment(), QStringLiteral("shell.openInEditor"),
                   QJsonObject{{QStringLiteral("cwd"), path}, {QStringLiteral("editor"), editor}},
                   [this](const QJsonValue&, const std::optional<QString>& error) {
                     if (!error) return;
                     m_logsError = error->isEmpty() ? QStringLiteral("Unable to open logs folder.") : *error;
                     publish();
                   });
  }

  QVariantMap processes() const {
    const QJsonObject& data = m_processes.data;
    const bool read = !data.isEmpty();
    QVariantList rows;
    for (const QJsonValue& value : data.value(QLatin1String("processes")).toArray()) {
      const QJsonObject process = value.toObject();
      const int pid = process.value(QLatin1String("pid")).toInt();
      rows.append(QVariantMap{
          {QStringLiteral("pid"), pid},
          {QStringLiteral("name"), processName(process.value(QLatin1String("command")).toString())},
          {QStringLiteral("command"), process.value(QLatin1String("command")).toString()},
          {QStringLiteral("cpu"), percent(process.value(QLatin1String("cpuPercent")).toDouble())},
          {QStringLiteral("memory"), bytes(process.value(QLatin1String("rssBytes")).toDouble())},
          {QStringLiteral("type"), processType(process)},
          {QStringLiteral("depth"), process.value(QLatin1String("depth")).toInt()},
          {QStringLiteral("signaling"), m_signaling == pid},
      });
    }
    const QString failure = option(data.value(QLatin1String("error"))).toObject().value(QLatin1String("message")).toString();
    const QString dots = QStringLiteral("...");
    return {
        {QStringLiteral("loading"), m_processes.loading},
        {QStringLiteral("error"), nullable(!m_processes.error.isEmpty() ? m_processes.error : failure)},
        {QStringLiteral("serverPid"), read ? QString::number(data.value(QLatin1String("serverPid")).toInt()) : dots},
        {QStringLiteral("count"), read ? count(data.value(QLatin1String("processCount")).toDouble()) : dots},
        {QStringLiteral("cpu"), read ? percent(data.value(QLatin1String("totalCpuPercent")).toDouble()) : dots},
        {QStringLiteral("memory"), read ? bytes(data.value(QLatin1String("totalRssBytes")).toDouble()) : dots},
        {QStringLiteral("rows"), rows},
    };
  }

  QVariantMap history() const {
    const QJsonObject& data = m_history.data;
    const bool read = !data.isEmpty();
    QVariantList windows;
    for (const Window& window : kWindows) {
      windows.append(QVariantMap{{QStringLiteral("label"), QLatin1String(window.label)}, {QStringLiteral("windowMs"), window.windowMs}});
    }
    QVariantList rows;
    const QJsonArray top = data.value(QLatin1String("topProcesses")).toArray();
    for (const QJsonValue& value : top) {
      const QJsonObject process = value.toObject();
      rows.append(QVariantMap{
          {QStringLiteral("pid"), process.value(QLatin1String("pid")).toInt()},
          {QStringLiteral("name"), processName(process.value(QLatin1String("command")).toString())},
          {QStringLiteral("command"), process.value(QLatin1String("command")).toString()},
          {QStringLiteral("avgCpu"), percent(process.value(QLatin1String("avgCpuPercent")).toDouble())},
          {QStringLiteral("maxCpu"), percent(process.value(QLatin1String("maxCpuPercent")).toDouble())},
          {QStringLiteral("maxMemory"), bytes(process.value(QLatin1String("maxRssBytes")).toDouble())},
          {QStringLiteral("cpuTime"), cpuTime(process.value(QLatin1String("cpuSecondsApprox")).toDouble())},
      });
    }
    const QString failure = option(data.value(QLatin1String("error"))).toObject().value(QLatin1String("message")).toString();
    const QString dots = QStringLiteral("...");
    return {
        {QStringLiteral("loading"), m_history.loading},
        {QStringLiteral("error"), nullable(!m_history.error.isEmpty() ? m_history.error : failure)},
        {QStringLiteral("windowMs"), m_windowMs},
        {QStringLiteral("windows"), windows},
        {QStringLiteral("cpuTime"), read ? cpuTime(data.value(QLatin1String("totalCpuSecondsApprox")).toDouble()) : dots},
        {QStringLiteral("samples"), read ? count(data.value(QLatin1String("retainedSampleCount")).toDouble()) : dots},
        {QStringLiteral("interval"), read ? duration(data.value(QLatin1String("sampleIntervalMs")).toDouble()) : dots},
        {QStringLiteral("count"), read ? count(top.size()) : dots},
        {QStringLiteral("rows"), rows},
    };
  }

  QVariantMap traces() const {
    const QJsonObject& data = m_traces.data;
    const bool read = !data.isEmpty();
    const auto rows = [&data](const char* key, auto row) {
      QVariantList list;
      for (const QJsonValue& value : data.value(QLatin1String(key)).toArray()) list.append(row(value.toObject()));
      return list;
    };
    const auto text = [](const QJsonObject& object, const char* key) { return object.value(QLatin1String(key)).toString(); };
    QString failure = option(data.value(QLatin1String("error"))).toObject().value(QLatin1String("message")).toString();
    if (!failure.isEmpty() && option(data.value(QLatin1String("partialFailure"))).toBool()) {
      failure = QStringLiteral("Some trace files could not be read, so diagnostics may be incomplete. ") + failure;
    }
    const QString dots = QStringLiteral("...");
    return {
        {QStringLiteral("loading"), m_traces.loading},
        {QStringLiteral("error"), nullable(!m_traces.error.isEmpty() ? m_traces.error : failure)},
        {QStringLiteral("spans"), read ? count(data.value(QLatin1String("recordCount")).toDouble()) : dots},
        {QStringLiteral("failures"), read ? count(data.value(QLatin1String("failureCount")).toDouble()) : dots},
        {QStringLiteral("slowSpans"), read ? count(data.value(QLatin1String("slowSpanCount")).toDouble()) : dots},
        {QStringLiteral("parseErrors"), read ? count(data.value(QLatin1String("parseErrorCount")).toDouble()) : dots},
        {QStringLiteral("latestFailures"), rows("latestFailures", [&](const QJsonObject& o) {
           return QVariantMap{{QStringLiteral("name"), text(o, "name")}, {QStringLiteral("cause"), text(o, "cause")},
                              {QStringLiteral("duration"), duration(o.value(QLatin1String("durationMs")).toDouble())}};
         })},
        {QStringLiteral("commonFailures"), rows("commonFailures", [&](const QJsonObject& o) {
           return QVariantMap{{QStringLiteral("name"), text(o, "name")}, {QStringLiteral("cause"), text(o, "cause")},
                              {QStringLiteral("count"), count(o.value(QLatin1String("count")).toDouble())}};
         })},
        {QStringLiteral("slowestSpans"), rows("slowestSpans", [&](const QJsonObject& o) {
           return QVariantMap{{QStringLiteral("name"), text(o, "name")},
                              {QStringLiteral("duration"), duration(o.value(QLatin1String("durationMs")).toDouble())}};
         })},
    };
  }

  void publish() {
    if (!m_active) return;
    m_bridge->publish(QStringLiteral("diagnostics"),
                      QVariantMap{
                          {QStringLiteral("processes"), processes()},
                          {QStringLiteral("history"), history()},
                          {QStringLiteral("traces"), traces()},
                          {QStringLiteral("logs"), QVariantMap{{QStringLiteral("available"), !logsPath().isEmpty()},
                                                               {QStringLiteral("error"), nullable(m_logsError)}}},
                      });
  }

  ShellBridge* m_bridge;
  NodeClient* m_client;
  bool m_active = false;
  bool m_open = false;
  int m_windowMs = 15 * 60'000;
  int m_signaling = 0;
  QString m_logsError;
  Read m_processes;
  Read m_history;
  Read m_traces;
};

namespace {
const NativeControllerRegistrar<DiagnosticsController> registrar(QStringLiteral("diagnostics"), {QStringLiteral("diagnostics")});
}  // namespace
