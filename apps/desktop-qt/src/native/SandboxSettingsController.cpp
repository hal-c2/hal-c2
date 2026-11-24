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
// whether an operation runs on the MC, or one this page asked for has not yet
// been refused or shown running in a frame; the actions are off while it is or when
// this session may not manage the MC's machine (manageReason says why).
// `confirm` asks before an operation this page asked for stops this MC's
// reviews (or runs without knowing whether it would).
//
// Actions: `sandboxSettings.refresh`, `sandboxSettings.run` {operation},
// `sandboxSettings.confirm`, `sandboxSettings.cancel`.

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

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
    m_refusal.clear();
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
  // closed is not asked about when it opens again.
  void closePage() {
    if (m_subscription >= 0) m_client->unsubscribe(m_subscription);
    m_subscription = -1;
    m_asked.clear();
    m_starting = false;
    m_refusal.clear();
    clearConfirm();
    publish();
  }

  bool busy() const { return m_starting || m_operation.value(QLatin1String("running")).toBool(); }

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
    m_refusal.clear();
    clearConfirm();
    QJsonObject payload = flags;
    payload.insert(QStringLiteral("operation"), operation);
    m_client->call(this, m_client->environment(), QStringLiteral("server.runOpenShellOperation"), payload,
                   [this, operation](const QJsonValue&, const std::optional<QString>& error) {
                     if (!error) return;
                     m_starting = false;
                     if (m_asked == operation) m_asked.clear();
                     m_refusal = error->isEmpty() ? QStringLiteral("The MC did not say why.") : *error;
                     publish();
                   });
    publish();
  }

  // The openShell shape: the operation running or last run on the MC.
  void follow(const QJsonObject& next) {
    const QString operation = next.value(QLatin1String("operation")).toString();
    const bool running = next.value(QLatin1String("running")).toBool();
    // The actions stay off from a run until a frame shows it running: its reply
    // may land before or after that frame, and a second press in between would
    // be refused as busy, and that refusal would forget what this page asked
    // for. A frame from before the run (the shape's first, another device's
    // last) is shown, but neither reopens the actions nor answers the run.
    if (m_starting && !(running && operation == m_asked)) {
      m_operation = next;
      publish();
      return;
    }
    const bool ended = busy() && !running;
    m_operation = next;
    m_starting = false;
    const QJsonValue result = next.value(QLatin1String("result"));
    if (!running && result.isObject() && !m_asked.isEmpty() && m_asked == operation) {
      m_asked.clear();
      answer(operation, result.toObject());
    }
    // What is installed changed: say so.
    if (ended && m_open) {
      read();
    } else {
      publish();
    }
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
  // A run this page sent that no frame has shown running yet and the MC has not refused.
  bool m_starting = false;
  QString m_refusal;
  // What a yes reruns: the operation and the flag (drain or force) it adds.
  QString m_confirmOperation;
  QString m_confirmFlag;
  QString m_confirmText;
};

namespace {
const NativeControllerRegistrar<SandboxSettingsController> registrar(QStringLiteral("sandboxSettings"), {QStringLiteral("sandboxSettings")});
}  // namespace
