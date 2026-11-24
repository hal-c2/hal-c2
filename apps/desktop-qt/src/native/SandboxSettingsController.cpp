// Settings → Review sandboxes: whether this environment can run code reviews
// in an OpenShell sandbox, and when it can't, why and what to do, from the
// MC's `server.getOpenShellStatus` (apps/server-ex HalC2.OpenShell.Command),
// read when the page opens, on refresh and after each operation; and the
// operations that status offers (Install, Check, Rotate certificates,
// Uninstall, …), run with `server.runOpenShellOperation` while their steps and
// outcome come from the openShell shape, followed while the page is open, so
// an operation another device started shows here too.
//
// Publishes `sandboxSettings`: {
//   loading,
//   state: loading | error | unsupported | attention | ready,
//   summary, detail, error (string | null),
//   problems: [{code, message}],
//   actions: [{operation, label}], canManage, manageReason (string | null),
//   busy,
//   operation: {operation, running, label, steps: [string],
//               result: {ok, message} | null} | null,
//   refusal (string | null),
//   confirm: {text} | null}
// where state is what the last answer said (loading until one lands) and
// `loading` is whether a read is out. Only the latest read lands. `busy` is
// whether an operation runs on the MC, or one this page asked for has been
// neither refused nor followed by a frame of its run (by the number its reply
// carries); the actions are off while it is or when this session may not manage
// the MC's machine (manageReason says why).
// `confirm` asks before an operation this page asked for stops this MC's
// reviews (or runs without knowing whether it would). `refusal` also says when
// the MC restarted before the run this page asked for told how it went.
//
// Actions: `sandboxSettings.refresh`, `sandboxSettings.run` {operation},
// `sandboxSettings.confirm`, `sandboxSettings.cancel`.

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>
#include <optional>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"

namespace {

const QString kSection = QStringLiteral("/settings/sandboxes");

QString modeName(const QString& mode) {
  if (mode == QLatin1String("managed")) return QStringLiteral("run by this MC");
  if (mode == QLatin1String("external")) return QStringLiteral("a gateway you run");
  if (mode == QLatin1String("foreground")) return QStringLiteral("the dev run");
  return mode;
}

QString runningLabel(const QString& operation) {
  if (operation == QLatin1String("install")) return QStringLiteral("Installing OpenShell…");
  if (operation == QLatin1String("check")) return QStringLiteral("Checking OpenShell…");
  if (operation == QLatin1String("rotate")) return QStringLiteral("Replacing OpenShell's certificates…");
  if (operation == QLatin1String("uninstall")) return QStringLiteral("Removing OpenShell…");
  return QString();
}

QString reviews(int count) {
  return count == 1 ? QStringLiteral("1 review") : QStringLiteral("%1 reviews").arg(count);
}

QVariant orNull(const QString& text) { return text.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(text); }

}  // namespace

class SandboxSettingsController : public QObject, public NativeController {
public:
  SandboxSettingsController(ShellBridge* bridge, McClient* client, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    auto opened = [navigation] { return navigation->route() == NavigationController::Route::settings(kSection); };
    connect(navigation, &NavigationController::changed, this, [this, opened] {
      const bool open = opened();
      if (open == m_open) return;
      m_open = open;
      if (open) {
        openPage();
      } else {
        closePage();
      }
    });
    m_open = opened();
    if (m_open) openPage();
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active) return false;
    if (action == QLatin1String("sandboxSettings.refresh")) {
      read();
    } else if (action == QLatin1String("sandboxSettings.run")) {
      const QString operation = payload.toMap().value(QStringLiteral("operation")).toString();
      // Only what the status offers, on the page, while nothing runs and this
      // session may.
      if (m_open && offered(operation) && m_status.value(QLatin1String("canManage")).toBool() && !busy()) run(operation, {});
    } else if (action == QLatin1String("sandboxSettings.confirm")) {
      if (m_confirmOperation.isEmpty()) return true;
      const QString operation = m_confirmOperation;
      const QString flag = m_confirmFlag;
      clearConfirm();
      run(operation, {{flag, true}});
    } else if (action == QLatin1String("sandboxSettings.cancel")) {
      clearConfirm();
      publish();
    } else {
      return false;
    }
    return true;
  }

private:
  // What the page shows of an operation comes from the shape's first frame; the
  // last status stands until the read asked for here lands.
  void openPage() {
    m_operation = QJsonObject();
    m_asked.clear();
    m_starting = false;
    m_awaited = -1;
    m_refusal.clear();
    m_followed = false;
    m_known.reset();
    clearConfirm();
    if (m_subscription >= 0) m_client->unsubscribe(m_subscription);
    const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("openShell")},
                            {QStringLiteral("environment"), m_client->environment()}};
    m_subscription = m_client->subscribe(this, shape, [this](const QJsonObject& frame) {
      if (frame.value(QLatin1String("t")) != QLatin1String("openShell")) return;
      follow(frame.value(QLatin1String("operation")).toObject());
    });
    read();
  }

  // What this page asked for is forgotten: an outcome that lands while it is
  // closed is not asked about when it opens again, and a reply that lands after
  // it reopens touches nothing.
  void closePage() {
    if (m_subscription >= 0) m_client->unsubscribe(m_subscription);
    m_subscription = -1;
    ++m_request;
    m_asked.clear();
    m_starting = false;
    m_awaited = -1;
    m_refusal.clear();
    clearConfirm();
    publish();
  }

  bool busy() const { return m_starting || m_operation.value(QLatin1String("running")).toBool(); }

  // A frame's or reply's run number: 0 before any run, -1 before any frame.
  static qint64 runOf(const QJsonObject& state) { return state.isEmpty() ? -1 : state.value(QLatin1String("run")).toInteger(); }

  bool offered(const QString& operation) const {
    for (const QJsonValue& value : m_status.value(QLatin1String("actions")).toArray()) {
      if (value.toObject().value(QLatin1String("operation")).toString() == operation) return true;
    }
    return false;
  }

  void clearConfirm() {
    m_confirmOperation.clear();
    m_confirmFlag.clear();
    m_confirmText.clear();
  }

  void read() {
    m_loading = true;
    const quint64 generation = ++m_generation;
    m_client->call(this, m_client->environment(), QStringLiteral("server.getOpenShellStatus"), QJsonObject(),
                   [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation) return;
                     m_loading = false;
                     m_landed = true;
                     m_error = error ? (error->isEmpty() ? QStringLiteral("The MC did not say why.") : *error) : QString();
                     m_status = error ? QJsonObject() : result.toObject();
                     publish();
                   });
    publish();
  }

  void run(const QString& operation, const QJsonObject& flags) {
    m_asked = operation;
    m_starting = true;
    m_awaited = -1;
    m_refusal.clear();
    clearConfirm();
    QJsonObject payload = flags;
    payload.insert(QStringLiteral("operation"), operation);
    const quint64 request = ++m_request;
    m_client->call(this, m_client->environment(), QStringLiteral("server.runOpenShellOperation"), payload,
                   [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                     // Only the latest press on this opening of the page: one from
                     // before the page closed, or before a later press, is forgotten.
                     if (request != m_request) return;
                     if (!error) {
                       // The reply names the run; a frame of it that came first settles it now.
                       if (!m_starting) return;
                       m_awaited = runOf(result.toObject());
                       if (runOf(m_operation) >= m_awaited) settle(m_operation);
                       return;
                     }
                     m_starting = false;
                     m_asked.clear();
                     m_refusal = error->isEmpty() ? QStringLiteral("The MC did not say why.") : *error;
                     publish();
                   });
    publish();
  }

  // The openShell shape: the operation running or last run on the MC.
  void follow(const QJsonObject& next) {
    // The MC sends a subscription's frames in order, and the first after a
    // reconnect is its state then, so a number below the last frame's is from an
    // MC whose clock went back across a restart (operations.ex's number/1). The
    // old MC's numbers then say nothing of the new one's runs.
    const qint64 number = runOf(next);
    const bool back = m_followed && number < m_last;
    if (back) m_known.reset();
    if (!m_followed && !next.value(QLatin1String("running")).toBool()) m_known = number;
    m_followed = true;
    m_last = number;
    // The actions stay off from a run until its reply has named it and a frame
    // of it (or a later run) has landed: a second press in between would be
    // refused as busy, and that refusal would forget what this page asked for.
    // A frame from before the run (the shape's first, another device's last) is
    // shown, but neither reopens the actions nor answers the run. Whichever of
    // the reply and the frame lands second settles it, so a run that ended
    // while the connection was down settles on the first frame after it.
    if (m_starting && !back && (m_awaited < 0 || number < m_awaited)) {
      m_operation = next;
      if (!reread(next, false)) publish();
      return;
    }
    settle(next, back);
  }

  // What is installed may have changed once a run ended: the status is read
  // again for each run seen ended, once, whether or not this page saw it run (it
  // may have ended on another device while the connection was down), and for a
  // run this page saw going that went with a restart (`ended`).
  bool reread(const QJsonObject& next, bool ended) {
    const qint64 number = runOf(next);
    if (!m_open || next.value(QLatin1String("running")).toBool() || m_known == number ||
        (next.value(QLatin1String("operation")).toString().isEmpty() && !ended))
      return false;
    m_known = number;
    read();
    return true;
  }

  void settle(const QJsonObject& next, bool back = false) {
    const QString operation = next.value(QLatin1String("operation")).toString();
    const bool running = next.value(QLatin1String("running")).toBool();
    const bool ended = busy() && !running;
    m_operation = next;
    m_starting = false;
    const QJsonValue result = next.value(QLatin1String("result"));
    if (!running && result.isObject() && !m_asked.isEmpty() && m_asked == operation && runOf(next) == m_awaited) {
      m_asked.clear();
      answer(operation, result.toObject());
    } else if (!m_asked.isEmpty() && m_awaited >= 0 && (back || (operation.isEmpty() && runOf(next) > m_awaited))) {
      // A frame with no operation is from an MC that has run none since it
      // started, and its number is when it started. Above the run's number, it
      // started after the run did: it restarted, and the run's outcome went with
      // the old one. This holds whatever the frame's order: a frame from before
      // the run (the shape's first, one sent before a reconnect) carries a
      // smaller number, as the run's is larger than every number before it. An
      // MC whose clock went back across the restart numbers below the run, and
      // the number going below the last frame's says so instead.
      m_asked.clear();
      m_refusal = QStringLiteral("The MC restarted during the run; check the status and try again.");
    }
    if (!reread(next, ended)) publish();
  }

  // An outcome this page asked for may need the user's yes to go on.
  void answer(const QString& operation, const QJsonObject& result) {
    if (result.value(QLatin1String("ok")).toBool()) return;
    const QString code = result.value(QLatin1String("code")).toString();
    const QString message = result.value(QLatin1String("message")).toString();
    const QJsonValue sandboxes = result.value(QLatin1String("sandboxes"));
    if (code == QLatin1String("sandboxes-running") && sandboxes.isDouble()) {
      m_confirmOperation = operation;
      m_confirmFlag = QStringLiteral("drain");
      m_confirmText = QStringLiteral("Stop %1 and go ahead? %2").arg(reviews(sandboxes.toInt()), message);
    } else if (code == QLatin1String("sandboxes-unknown")) {
      m_confirmOperation = operation;
      m_confirmFlag = QStringLiteral("force");
      m_confirmText = QStringLiteral("Go ahead anyway? %1").arg(message);
    }
  }

  QVariant operationState() const {
    const QString operation = m_operation.value(QLatin1String("operation")).toString();
    if (operation.isEmpty()) return QVariant::fromValue(nullptr);
    QVariantList steps;
    for (const QJsonValue& step : m_operation.value(QLatin1String("steps")).toArray()) steps.append(step.toString());
    const QJsonValue result = m_operation.value(QLatin1String("result"));
    const bool running = m_operation.value(QLatin1String("running")).toBool();
    return QVariantMap{
        {QStringLiteral("operation"), operation},
        {QStringLiteral("running"), running},
        {QStringLiteral("label"), running ? runningLabel(operation) : QString()},
        {QStringLiteral("steps"), steps},
        {QStringLiteral("result"),
         !running && result.isObject()
             ? QVariant(QVariantMap{{QStringLiteral("ok"), result.toObject().value(QLatin1String("ok")).toBool()},
                                    {QStringLiteral("message"), result.toObject().value(QLatin1String("message")).toString()}})
             : QVariant::fromValue(nullptr)}};
  }

  void publish() {
    if (!m_active) return;
    QVariantList problems;
    for (const QJsonValue& value : m_status.value(QLatin1String("problems")).toArray()) {
      const QJsonObject problem = value.toObject();
      problems.append(QVariantMap{{QStringLiteral("code"), problem.value(QLatin1String("code")).toString()},
                                  {QStringLiteral("message"), problem.value(QLatin1String("message")).toString()}});
    }
    QVariantList actions;
    for (const QJsonValue& value : m_status.value(QLatin1String("actions")).toArray()) {
      const QJsonObject action = value.toObject();
      actions.append(QVariantMap{{QStringLiteral("operation"), action.value(QLatin1String("operation")).toString()},
                                 {QStringLiteral("label"), action.value(QLatin1String("label")).toString()}});
    }
    QString state;
    QString summary;
    QString detail;
    if (!m_landed) {
      state = QStringLiteral("loading");
      summary = QStringLiteral("Asking the MC whether review sandboxes can run here…");
    } else if (!m_error.isEmpty()) {
      state = QStringLiteral("error");
      summary = QStringLiteral("Could not read whether review sandboxes can run here.");
    } else if (!m_status.value(QLatin1String("supported")).toBool()) {
      state = QStringLiteral("unsupported");
      summary = QStringLiteral("Review sandboxes can't run on this machine.");
      detail = QStringLiteral("Code reviews run without a sandbox here.");
    } else if (!m_status.value(QLatin1String("ready")).toBool()) {
      state = QStringLiteral("attention");
      summary = QStringLiteral("Review sandboxes can't run here yet.");
      detail = QStringLiteral("OpenShell %1 is the version this MC pins.").arg(m_status.value(QLatin1String("pinnedVersion")).toString());
    } else {
      state = QStringLiteral("ready");
      summary = QStringLiteral("Review sandboxes can run here.");
      const QString version = m_status.value(QLatin1String("version")).toString();
      detail = (version.isEmpty() ? QStringLiteral("OpenShell, %1.") : QStringLiteral("OpenShell %2, %1."))
                   .arg(modeName(m_status.value(QLatin1String("mode")).toString()), version);
    }
    const bool canManage = m_status.value(QLatin1String("canManage")).toBool();
    m_bridge->publish(
        QStringLiteral("sandboxSettings"),
        QVariantMap{{QStringLiteral("loading"), m_loading},
                    {QStringLiteral("state"), state},
                    {QStringLiteral("summary"), summary},
                    {QStringLiteral("detail"), detail},
                    {QStringLiteral("error"), orNull(m_error)},
                    {QStringLiteral("problems"), problems},
                    {QStringLiteral("actions"), actions},
                    {QStringLiteral("canManage"), canManage},
                    {QStringLiteral("manageReason"), canManage ? QVariant::fromValue(nullptr)
                                                               : orNull(m_status.value(QLatin1String("manageReason")).toString())},
                    {QStringLiteral("busy"), busy()},
                    {QStringLiteral("operation"), operationState()},
                    {QStringLiteral("refusal"), orNull(m_refusal)},
                    {QStringLiteral("confirm"), m_confirmOperation.isEmpty()
                                                    ? QVariant::fromValue(nullptr)
                                                    : QVariant(QVariantMap{{QStringLiteral("text"), m_confirmText}})}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  bool m_active = false;
  bool m_open = false;
  bool m_loading = false;
  // An answer, or an error, has landed.
  bool m_landed = false;
  quint64 m_generation = 0;
  QString m_error;
  QJsonObject m_status;
  int m_subscription = -1;
  // The openShell shape's last frame: {operation, running, steps, result}.
  QJsonObject m_operation;
  // The operation this page asked for, until its outcome arrives.
  QString m_asked;
  // A run this page sent that the MC has not refused and no frame of has
  // landed since its reply.
  bool m_starting = false;
  // The run's number, from its reply: -1 until it lands.
  qint64 m_awaited = -1;
  // The latest run asked for, so an older one's reply is not taken for it.
  quint64 m_request = 0;
  QString m_refusal;
  // A frame of this opening has landed, and the last one's number.
  bool m_followed = false;
  qint64 m_last = 0;
  // The ended run the status was last read for: the one the shape's first frame
  // showed ended (the read the page opened with covers it), then each one after.
  std::optional<qint64> m_known;
  // What a yes reruns: the operation and the flag (drain or force) it adds.
  QString m_confirmOperation;
  QString m_confirmFlag;
  QString m_confirmText;
};

namespace {
const NativeControllerRegistrar<SandboxSettingsController> registrar(QStringLiteral("sandboxSettings"), {QStringLiteral("sandboxSettings")});
}  // namespace
