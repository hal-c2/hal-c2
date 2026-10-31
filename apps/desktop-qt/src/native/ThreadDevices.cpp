#include "ThreadDevices.h"

#include <QJsonArray>
#include <QUrl>

#include <algorithm>

#include "McClient.h"

namespace {

const QString kPicker = QStringLiteral("device");
const QString kDeviceTab = QStringLiteral("device:");

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QString keyOf(const QString& hostId, const QString& deviceId) {
  return hostId + QChar(0) + deviceId;
}

}  // namespace

QString ThreadDevices::tabIdOf(const QString& hostId, const QString& deviceId) {
  return kDeviceTab + QString::fromLatin1(QUrl::toPercentEncoding(hostId)) + QLatin1Char(':') +
         QString::fromLatin1(QUrl::toPercentEncoding(deviceId));
}

std::pair<QString, QString> ThreadDevices::targetOf(const QString& tabId) {
  if (!tabId.startsWith(kDeviceTab)) return {};
  const QStringList parts = tabId.mid(kDeviceTab.size()).split(QLatin1Char(':'));
  if (parts.size() != 2 || parts[0].isEmpty() || parts[1].isEmpty()) return {};
  return {QUrl::fromPercentEncoding(parts[0].toLatin1()), QUrl::fromPercentEncoding(parts[1].toLatin1())};
}

ThreadDevices::ThreadDevices(McClient* client, QObject* parent)
    : QObject(parent), m_client(client), m_stream(client), m_tools(client) {
  publish();
}

ThreadDevices::~ThreadDevices() {
  unfollow();
}

void ThreadDevices::setThread(const QString& environmentId, const QString& threadId, const QString& mc) {
  if (environmentId == m_environment && threadId == m_thread && mc == m_mc) return;
  const bool moved = environmentId != m_environment || mc != m_mc;
  m_thread = threadId;
  m_pending.clear();
  m_error.clear();
  if (moved) {
    unfollow();
    m_environment = environmentId;
    m_mc = mc;
    ++m_generation;
    m_wizardPending.clear();
    m_wizardError.clear();
    m_retrying.clear();
    m_state = {};
    m_loaded = false;
    follow();
  } else {
    watchSessions();
  }
  retarget();
  publish();
}

void ThreadDevices::setTab(const QString& tabId) {
  if (tabId == m_tab) return;
  const bool shown = m_tab.isEmpty() && !tabId.isEmpty();
  if (shown) m_wizardDismissed = false;
  m_tab = tabId;
  // Showing the tab lists again.
  if (shown && m_loaded && text(m_state, QLatin1String("hostStatus")) != QLatin1String("disabled")) list();
  retarget();
  publish();
}

void ThreadDevices::follow() {
  if (m_subscription >= 0 || m_mc.isEmpty() || m_environment.isEmpty()) return;
  m_subscription = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("devices")}, {QStringLiteral("mc"), m_mc}},
                                       [this](const QJsonObject& frame) {
                                         if (frame.value(QLatin1String("t")) == QLatin1String("devices"))
                                           take(frame.value(QLatin1String("state")).toObject());
                                       });
}

void ThreadDevices::unfollow() {
  if (m_subscription < 0) return;
  m_client->unsubscribe(m_subscription);
  m_subscription = -1;
}

void ThreadDevices::list(const QJsonObject& input) {
  if (m_environment.isEmpty()) return;
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("device.list"), input,
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_generation != generation) return;
                   if (error) {
                     m_retrying.clear();
                     publish();
                     return;
                   }
                   take(result.toObject());
                 });
}

void ThreadDevices::take(const QJsonObject& state) {
  m_state = state;
  m_retrying.clear();
  const bool first = !m_loaded;
  m_loaded = true;
  if (first && !m_tab.isEmpty() && text(state, QLatin1String("hostStatus")) != QLatin1String("disabled")) list();
  watchSessions();
  retarget();
  publish();
  QStringList names;
  for (const QJsonValue& device : state.value(QLatin1String("devices")).toArray())
    names.append(text(device.toObject(), QLatin1String("id")) + QLatin1Char('=') + text(device.toObject(), QLatin1String("name")));
  if (names.join(QChar(0)) != m_names) {
    m_names = names.join(QChar(0));
    emit namesChanged();
  }
}

QJsonObject ThreadDevices::deviceOf(const QString& hostId, const QString& deviceId) const {
  for (const QJsonValue& value : m_state.value(QLatin1String("devices")).toArray()) {
    const QJsonObject device = value.toObject();
    if (text(device, QLatin1String("hostId")) == hostId && text(device, QLatin1String("id")) == deviceId) return device;
  }
  return {};
}

bool ThreadDevices::hasSession(const QString& hostId, const QString& deviceId) const {
  for (const QJsonValue& value : m_state.value(QLatin1String("sessions")).toArray()) {
    const QJsonObject session = value.toObject();
    if (text(session, QLatin1String("threadId")) == m_thread && text(session, QLatin1String("hostId")) == hostId &&
        text(session, QLatin1String("deviceId")) == deviceId)
      return true;
  }
  return false;
}

// A session the thread gained since the state was last seen was opened for
// it elsewhere (an agent's device.open, another client): its tab opens.
void ThreadDevices::watchSessions() {
  if (!m_loaded || m_thread.isEmpty()) return;
  QSet<QString> now;
  QStringList added;
  for (const QJsonValue& value : m_state.value(QLatin1String("sessions")).toArray()) {
    const QJsonObject session = value.toObject();
    if (text(session, QLatin1String("threadId")) != m_thread) continue;
    const QString hostId = text(session, QLatin1String("hostId")), deviceId = text(session, QLatin1String("deviceId"));
    if (deviceOf(hostId, deviceId).isEmpty()) continue;
    now.insert(keyOf(hostId, deviceId));
    added.append(tabIdOf(hostId, deviceId));
  }
  const QString threadKey = m_environment + QLatin1Char(':') + m_thread;
  const auto seen = m_sessionsSeen.constFind(threadKey);
  const bool baseline = seen == m_sessionsSeen.constEnd();
  const QSet<QString> before = baseline ? QSet<QString>() : *seen;
  m_sessionsSeen.insert(threadKey, now);
  if (baseline) return;
  for (const QString& tabId : added) {
    const auto [hostId, deviceId] = targetOf(tabId);
    if (!before.contains(keyOf(hostId, deviceId))) emit opened(tabId, true);
  }
}

// The shown device tab streams its device while the thread has it open.
void ThreadDevices::retarget() {
  const auto [hostId, deviceId] = targetOf(m_tab);
  const QJsonObject device = deviceOf(hostId, deviceId);
  if (!device.isEmpty() && hasSession(hostId, deviceId)) {
    m_stream.setTarget(text(m_state, QLatin1String("hubBasePath")), text(device, QLatin1String("platform")), deviceId);
    m_stream.setActive(true);
    m_tools.setTarget(m_environment, text(m_state, QLatin1String("hubBasePath")), hostId, deviceId,
                      text(device, QLatin1String("platform")));
  } else {
    m_stream.setActive(false);
    m_stream.setTarget({}, {}, {});
    m_tools.setTarget(m_environment, {}, {}, {}, {});
  }
}

QString ThreadDevices::titleOf(const QString& tabId) const {
  const auto [hostId, deviceId] = targetOf(tabId);
  const QString name = text(deviceOf(hostId, deviceId), QLatin1String("name"));
  return name.isEmpty() ? QStringLiteral("Device") : name;
}

void ThreadDevices::open(const QString& hostId, const QString& deviceId) {
  const QJsonObject device = deviceOf(hostId, deviceId);
  if (device.isEmpty() || !m_pending.isEmpty() || m_thread.isEmpty()) return;
  m_pending = keyOf(hostId, deviceId);
  m_error.clear();
  publish();
  const int generation = m_generation;
  const QString thread = m_thread;
  m_client->call(this, m_environment, QStringLiteral("device.open"),
                 QJsonObject{{QStringLiteral("threadId"), thread},
                             {QStringLiteral("hostId"), hostId},
                             {QStringLiteral("deviceId"), deviceId},
                             {QStringLiteral("platform"), device.value(QLatin1String("platform"))}},
                 [this, generation, thread, hostId, deviceId](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_generation != generation || m_thread != thread) return;
                   m_pending.clear();
                   if (error) {
                     m_error = *error;
                     publish();
                     return;
                   }
                   // The session is the MC's; seeing it later is not an agent's open.
                   const QJsonObject session = result.toObject();
                   const QString host = session.value(QLatin1String("hostId")).toString(hostId);
                   const QString id = session.value(QLatin1String("deviceId")).toString(deviceId);
                   m_sessionsSeen[m_environment + QLatin1Char(':') + thread].insert(keyOf(host, id));
                   publish();
                   emit opened(tabIdOf(host, id), false);
                 });
}

void ThreadDevices::powerOff() {
  const QString tab = m_tab;
  const auto [hostId, deviceId] = targetOf(tab);
  if (!hasSession(hostId, deviceId)) return;
  m_error.clear();
  publish();
  const QString environment = m_environment, thread = m_thread;
  m_client->call(this, environment, QStringLiteral("device.close"),
                 QJsonObject{{QStringLiteral("threadId"), thread},
                             {QStringLiteral("hostId"), hostId},
                             {QStringLiteral("deviceId"), deviceId},
                             {QStringLiteral("shutdown"), true}},
                 [this, environment, thread, tab](const QJsonValue&, const std::optional<QString>& error) {
                   const bool here = m_environment == environment && m_thread == thread;
                   if (error) {
                     // Only the thread that asked shows why.
                     if (!here) return;
                     m_error = *error;
                     publish();
                     return;
                   }
                   // The tab closes in the thread it was powered off from, shown or not.
                   emit closed(environment + QLatin1Char(':') + thread, tab);
                 });
}

void ThreadDevices::close() {
  if (!m_tab.isEmpty()) emit closed(m_environment + QLatin1Char(':') + m_thread, m_tab);
}

void ThreadDevices::refresh() {
  list();
}

void ThreadDevices::dismissError() {
  if (m_error.isEmpty()) return;
  m_error.clear();
  publish();
}

void ThreadDevices::retryHost(const QString& hostId) {
  if (hostId.isEmpty() || !m_retrying.isEmpty()) return;
  m_retrying = hostId;
  publish();
  list({{QStringLiteral("retryHostId"), hostId}});
}

void ThreadDevices::floatDevice() {
  if (!m_tab.isEmpty()) emit floated(m_tab);
}

void ThreadDevices::configure(const QString& pending, const QJsonObject& change) {
  if (!m_wizardPending.isEmpty() || m_environment.isEmpty()) return;
  m_wizardPending = pending;
  m_wizardError.clear();
  publish();
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("device.configure"), change,
                 [this, generation, pending](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_generation != generation) return;
                   m_wizardPending.clear();
                   m_wizardError = error.value_or(QString());
                   if (!error) take(result.toObject());
                   if (pending == QLatin1String("complete") && !error) m_wizardDismissed = true;
                   publish();
                 });
}

void ThreadDevices::wizardSetHub(bool on) {
  QJsonObject change{{QStringLiteral("enabled"), on}};
  // Turning the hub off turns agent access off with it.
  if (!on) change.insert(QStringLiteral("agentAccessEnabled"), false);
  configure(QStringLiteral("hub"), change);
}

void ThreadDevices::wizardSetAgent(bool on) {
  configure(QStringLiteral("agent"), {{QStringLiteral("agentAccessEnabled"), on}});
}

void ThreadDevices::wizardCheck() {
  if (!m_wizardPending.isEmpty()) return;
  m_wizardPending = QStringLiteral("check");
  m_wizardError.clear();
  publish();
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("device.list"), QJsonObject(),
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (m_generation != generation) return;
                   m_wizardPending.clear();
                   m_wizardError = error.value_or(QString());
                   if (!error) take(result.toObject());
                   publish();
                 });
}

void ThreadDevices::wizardDone() {
  configure(QStringLiteral("complete"), {{QStringLiteral("onboardingCompleted"), true}});
}

void ThreadDevices::wizardCancel() {
  m_wizardDismissed = true;
  publish();
}

QVariantList ThreadDevices::banners() const {
  QVariantList rows;
  if (text(m_state, QLatin1String("hostStatus")) == QLatin1String("disabled")) return rows;
  const QJsonObject statuses = m_state.value(QLatin1String("hostStatuses")).toObject();
  for (const QJsonValue& value : m_state.value(QLatin1String("hosts")).toArray()) {
    const QJsonObject host = value.toObject();
    const QString id = text(host, QLatin1String("id"));
    const QJsonObject status = statuses.value(id).toObject();
    const QString state = text(status, QLatin1String("status"));
    if (state != QLatin1String("installing") && state != QLatin1String("starting") && state != QLatin1String("failed")) continue;
    const bool failed = state == QLatin1String("failed");
    const QString fallback = failed ? QStringLiteral("Device support could not start.")
                             : state == QLatin1String("installing") ? QStringLiteral("Installing device tools…")
                                                                    : QStringLiteral("Starting device tools…");
    rows.append(QVariantMap{
        {QStringLiteral("hostId"), id},
        {QStringLiteral("label"), text(host, QLatin1String("label"))},
        {QStringLiteral("failed"), failed},
        {QStringLiteral("message"), status.value(QLatin1String("detail")).toString(fallback)},
        {QStringLiteral("advice"),
         failed ? QStringLiteral("Check the host connection and network access, then retry. Your device settings are saved.") : QString()},
        {QStringLiteral("canRetry"), failed && m_state.value(QLatin1String("supportsHostRetry")).toBool()},
        {QStringLiteral("retrying"), m_retrying == id},
    });
  }
  return rows;
}

QVariantMap ThreadDevices::wizardView() const {
  const QString hostStatus = text(m_state, QLatin1String("hostStatus"));
  const bool enabled = hostStatus != QLatin1String("disabled");
  const bool busy = hostStatus == QLatin1String("installing") || hostStatus == QLatin1String("starting");
  const bool ready = hostStatus == QLatin1String("ready");

  QString hubStatus;
  const bool hubPending = m_wizardPending == QLatin1String("hub") || (busy && m_wizardPending != QLatin1String("agent"));
  if (hubPending) {
    hubStatus = hostStatus == QLatin1String("installing") ? QStringLiteral("Installing device hub…")
                : hostStatus == QLatin1String("starting") ? QStringLiteral("Starting device hub…")
                                                           : QStringLiteral("Updating device hub…");
  } else if (ready) {
    hubStatus = QStringLiteral("Device hub is ready.");
  }

  QString agentStatus;
  if (m_wizardPending == QLatin1String("agent")) {
    agentStatus = hostStatus == QLatin1String("installing") ? QStringLiteral("Installing agent tools…")
                  : hostStatus == QLatin1String("starting") ? QStringLiteral("Starting agent tools…")
                                                             : QStringLiteral("Updating agent access…");
  } else if (m_state.value(QLatin1String("agentAccessEnabled")).toBool() && ready) {
    for (const QJsonValue& host : m_state.value(QLatin1String("hosts")).toArray()) {
      if (host.toObject().value(QLatin1String("agentDeviceInstalled")).toBool()) agentStatus = QStringLiteral("Agent tools are ready.");
    }
  }

  const auto platform = [this, ready](const QString& wanted) {
    QJsonObject availability;
    for (const QJsonValue& host : m_state.value(QLatin1String("hosts")).toArray()) {
      for (const QJsonValue& entry : host.toObject().value(QLatin1String("platforms")).toArray()) {
        if (availability.isEmpty() && text(entry.toObject(), QLatin1String("platform")) == wanted) availability = entry.toObject();
      }
    }
    const QString name = wanted == QLatin1String("ios") ? QStringLiteral("iOS") : QStringLiteral("Android");
    if (!availability.value(QLatin1String("available")).toBool()) {
      return QVariantMap{{QStringLiteral("platform"), name},
                         {QStringLiteral("ready"), false},
                         {QStringLiteral("message"),
                          availability.value(QLatin1String("reason")).toString(QStringLiteral("%1 support was not detected.").arg(name))}};
    }
    bool any = false;
    for (const QJsonValue& device : m_state.value(QLatin1String("devices")).toArray())
      any = any || text(device.toObject(), QLatin1String("platform")) == wanted;
    if (ready && !any) {
      return QVariantMap{{QStringLiteral("platform"), name},
                         {QStringLiteral("ready"), false},
                         {QStringLiteral("message"),
                          wanted == QLatin1String("ios")
                              ? QStringLiteral("Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components.")
                              : QStringLiteral("The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager.")}};
    }
    return QVariantMap{{QStringLiteral("platform"), name},
                       {QStringLiteral("ready"), true},
                       {QStringLiteral("message"), wanted == QLatin1String("ios") ? QStringLiteral("Xcode and iOS Simulator are available.")
                                                                                   : QStringLiteral("The Android SDK and Emulator are available.")}};
  };

  return {
      {QStringLiteral("hubOn"), enabled},
      {QStringLiteral("hubReady"), ready},
      {QStringLiteral("busy"), busy},
      {QStringLiteral("pending"), m_wizardPending},
      {QStringLiteral("hubStatus"), hubStatus},
      {QStringLiteral("agentOn"), m_state.value(QLatin1String("agentAccessEnabled")).toBool()},
      {QStringLiteral("agentStatus"), agentStatus},
      {QStringLiteral("platforms"), QVariantList{platform(QStringLiteral("ios")), platform(QStringLiteral("android"))}},
      {QStringLiteral("error"), !m_wizardError.isEmpty()                  ? m_wizardError
                                : hostStatus == QLatin1String("failed") ? text(m_state, QLatin1String("hostStatusDetail"))
                                                                        : QString()},
      {QStringLiteral("canContinue"), ready && m_wizardPending.isEmpty()},
  };
}

void ThreadDevices::publish() {
  const QString hostStatus = text(m_state, QLatin1String("hostStatus"));
  const QString hostDetail = text(m_state, QLatin1String("hostStatusDetail"));
  bool hostReady = false, hostBusy = false;
  const QJsonObject statuses = m_state.value(QLatin1String("hostStatuses")).toObject();
  for (const QJsonValue& value : statuses) {
    const QString status = text(value.toObject(), QLatin1String("status"));
    hostReady = hostReady || status == QLatin1String("ready");
    hostBusy = hostBusy || status == QLatin1String("installing") || status == QLatin1String("starting");
  }
  hostBusy = hostBusy && !hostReady;

  QHash<QString, QString> hostLabels;
  bool androidMissing = false;
  for (const QJsonValue& value : m_state.value(QLatin1String("hosts")).toArray()) {
    const QJsonObject host = value.toObject();
    hostLabels.insert(text(host, QLatin1String("id")), text(host, QLatin1String("label")));
    for (const QJsonValue& platform : host.value(QLatin1String("platforms")).toArray()) {
      const QJsonObject entry = platform.toObject();
      if (text(entry, QLatin1String("platform")) == QLatin1String("android") && !entry.value(QLatin1String("available")).toBool())
        androidMissing = true;
    }
  }
  const auto hostLabel = [&hostLabels](const QString& hostId) {
    const QString label = hostLabels.value(hostId);
    return label.isEmpty() ? QStringLiteral("Device host") : label;
  };

  // iOS Simulators, then Android Emulators; running first, then by name.
  QVariantList groups;
  bool anyAndroid = false;
  QJsonObject pendingDevice;
  for (const QString& platform : {QStringLiteral("ios"), QStringLiteral("android")}) {
    QList<QJsonObject> devices;
    for (const QJsonValue& value : m_state.value(QLatin1String("devices")).toArray()) {
      const QJsonObject device = value.toObject();
      if (keyOf(text(device, QLatin1String("hostId")), text(device, QLatin1String("id"))) == m_pending) pendingDevice = device;
      if (text(device, QLatin1String("platform")) == platform) devices.append(device);
    }
    if (devices.isEmpty()) continue;
    anyAndroid = anyAndroid || platform == QLatin1String("android");
    std::stable_sort(devices.begin(), devices.end(), [](const QJsonObject& a, const QJsonObject& b) {
      const bool left = a.value(QLatin1String("booted")).toBool(), right = b.value(QLatin1String("booted")).toBool();
      if (left != right) return left;
      return QString::localeAwareCompare(text(a, QLatin1String("name")), text(b, QLatin1String("name"))) < 0;
    });
    QVariantList rows;
    for (const QJsonObject& device : devices) {
      const bool booted = device.value(QLatin1String("booted")).toBool();
      const QString hostId = text(device, QLatin1String("hostId")), id = text(device, QLatin1String("id"));
      rows.append(QVariantMap{
          {QStringLiteral("key"), keyOf(hostId, id)},
          {QStringLiteral("tab"), tabIdOf(hostId, id)},
          {QStringLiteral("hostId"), hostId},
          {QStringLiteral("id"), id},
          {QStringLiteral("name"), text(device, QLatin1String("name"))},
          {QStringLiteral("platform"), platform},
          {QStringLiteral("detail"), QStringLiteral("%1 · %2 · %3")
                                         .arg(hostLabel(hostId), text(device, QLatin1String("version")),
                                              booted ? QStringLiteral("Running") : QStringLiteral("Stopped"))},
          {QStringLiteral("action"), booted ? QStringLiteral("Open") : QStringLiteral("Start")},
      });
    }
    groups.append(QVariantMap{{QStringLiteral("title"), platform == QLatin1String("ios") ? QStringLiteral("iOS Simulators")
                                                                                          : QStringLiteral("Android Emulators")},
                              {QStringLiteral("devices"), rows}});
  }

  QStringList booting;
  for (const QJsonValue& value : m_state.value(QLatin1String("bootingDevices")).toArray()) {
    const QJsonObject device = value.toObject();
    if (text(device, QLatin1String("threadId")) == m_thread) booting.append(text(device, QLatin1String("name")));
  }

  QVariant screen;
  const auto [hostId, deviceId] = targetOf(m_tab);
  const QJsonObject device = deviceOf(hostId, deviceId);
  if (!device.isEmpty() && hasSession(hostId, deviceId)) {
    screen = QVariantMap{{QStringLiteral("hostId"), hostId},
                         {QStringLiteral("id"), deviceId},
                         {QStringLiteral("name"), text(device, QLatin1String("name"))},
                         {QStringLiteral("platform"), text(device, QLatin1String("platform"))},
                         {QStringLiteral("description"), hostLabel(hostId) + QStringLiteral(" · ") + text(device, QLatin1String("version"))}};
  }

  QString loading;
  if (!pendingDevice.isEmpty()) {
    loading = pendingDevice.value(QLatin1String("booted")).toBool() ? QStringLiteral("Opening device…") : QStringLiteral("Starting device…");
  } else if (hostBusy || !m_loaded) {
    loading = hostStatus == QLatin1String("installing")
                  ? (hostDetail.isEmpty() ? QStringLiteral("Installing device support…") : hostDetail)
                  : QStringLiteral("Finding devices…");
  }
  QString empty;
  if (groups.isEmpty()) {
    empty = hostStatus == QLatin1String("failed")
                ? (hostDetail.isEmpty() ? QStringLiteral("The device hub failed to start.") : hostDetail)
                : QStringLiteral("No simulators or emulators were found on this environment.");
  }

  QVariantMap view{
      {QStringLiteral("loaded"), m_loaded},
      {QStringLiteral("setup"), m_loaded && (hostStatus == QLatin1String("disabled") ||
                                             !m_state.value(QLatin1String("onboardingCompleted")).toBool())},
      {QStringLiteral("loading"), loading},
      {QStringLiteral("empty"), empty},
      {QStringLiteral("hostDetail"), hostReady ? hostDetail : QString()},
      {QStringLiteral("starting"),
       booting.isEmpty() ? QString() : QStringLiteral("Starting %1… This can take a minute.").arg(booting.join(QStringLiteral(", ")))},
      {QStringLiteral("noAndroid"), hostReady && !anyAndroid && !androidMissing},
      {QStringLiteral("canRefresh"), m_loaded && !hostBusy},
      {QStringLiteral("error"), m_error},
      {QStringLiteral("pendingKey"), m_pending},
      {QStringLiteral("groups"), hostReady ? groups : QVariantList()},
      {QStringLiteral("banners"), banners()},
      {QStringLiteral("wizard"),
       m_loaded && !m_wizardDismissed &&
               (!m_state.value(QLatin1String("onboardingCompleted")).toBool() || hostStatus == QLatin1String("disabled"))
           ? QVariant(wizardView())
           : QVariant()},
      {QStringLiteral("screen"), screen},
  };
  if (view == m_view) return;
  m_view = view;
  emit viewChanged();
}
