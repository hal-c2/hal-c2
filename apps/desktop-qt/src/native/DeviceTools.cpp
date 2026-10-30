#include "DeviceTools.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QUrl>

#include "McClient.h"

namespace {

// The drawer's labels for the settings' values (DeviceToolsPanel upstream).
const QHash<QString, QString> kTextSizes{{QStringLiteral("Small"), QStringLiteral("small")},
                                         {QStringLiteral("Default"), QStringLiteral("default")},
                                         {QStringLiteral("Large"), QStringLiteral("large")},
                                         {QStringLiteral("Extra large"), QStringLiteral("extra-large")}};
const QHash<QString, QString> kColorFilters{{QStringLiteral("None"), QStringLiteral("none")},
                                            {QStringLiteral("Grayscale"), QStringLiteral("grayscale")},
                                            {QStringLiteral("Red / green (protanopia)"), QStringLiteral("red-green")},
                                            {QStringLiteral("Green / red (deuteranopia)"), QStringLiteral("green-red")},
                                            {QStringLiteral("Blue / yellow (tritanopia)"), QStringLiteral("blue-yellow")}};
const QHash<QString, QString> kOrientations{{QStringLiteral("Portrait"), QStringLiteral("portrait")},
                                            {QStringLiteral("Landscape left"), QStringLiteral("landscape_left")},
                                            {QStringLiteral("Upside down"), QStringLiteral("portrait_upside_down")},
                                            {QStringLiteral("Landscape right"), QStringLiteral("landscape_right")}};
// Permission labels, by platform spelling, to the contract's values.
const QHash<QString, QString> kPermissions{
    {QStringLiteral("Camera"), QStringLiteral("camera")},         {QStringLiteral("Microphone"), QStringLiteral("microphone")},
    {QStringLiteral("Photos"), QStringLiteral("photos")},         {QStringLiteral("Contacts"), QStringLiteral("contacts")},
    {QStringLiteral("Calendar"), QStringLiteral("calendar")},     {QStringLiteral("Reminders"), QStringLiteral("reminders")},
    {QStringLiteral("Location"), QStringLiteral("location")},     {QStringLiteral("Notifications"), QStringLiteral("notifications")},
    {QStringLiteral("Motion"), QStringLiteral("motion")},         {QStringLiteral("Physical activity"), QStringLiteral("motion")},
    {QStringLiteral("Media library"), QStringLiteral("media-library")},
    {QStringLiteral("Face ID"), QStringLiteral("faceid")},
};
const QHash<QString, std::pair<double, double>> kPresets{{QStringLiteral("San Francisco"), {37.7749, -122.4194}},
                                                         {QStringLiteral("New York"), {40.7128, -74.006}},
                                                         {QStringLiteral("London"), {51.5074, -0.1278}},
                                                         {QStringLiteral("Stockholm"), {59.3293, 18.0686}},
                                                         {QStringLiteral("Tokyo"), {35.6762, 139.6503}}};
constexpr int kEventLogLimit = 100;
constexpr int kAxElementLimit = 500;
constexpr int kAxRefreshMs = 500;

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

double numberOr(const QJsonValue& value, double fallback) {
  return value.isDouble() ? value.toDouble() : fallback;
}

// serve-sim's nested accessibility tree, flattened: nodes covering the
// whole screen are skipped, frames normalized to the root's (upstream
// deviceHubApi's flattenIosAxTree).
void flattenAx(const QJsonValue& node, double screenWidth, double screenHeight, const QString& path, QVariantList& out) {
  if (out.size() >= kAxElementLimit || !node.isObject()) return;
  const QJsonObject object = node.toObject();
  const QJsonObject frame = object.value(QLatin1String("frame")).toObject();
  const double width = numberOr(frame.value(QLatin1String("width")), 0);
  const double height = numberOr(frame.value(QLatin1String("height")), 0);
  const bool covers = std::abs(width - screenWidth) < 0.5 && std::abs(height - screenHeight) < 0.5;
  if (!covers && width > 0 && height > 0) {
    out.append(QVariantMap{{QStringLiteral("label"), text(object, QLatin1String("AXLabel"))},
                           {QStringLiteral("x"), numberOr(frame.value(QLatin1String("x")), 0) / screenWidth},
                           {QStringLiteral("y"), numberOr(frame.value(QLatin1String("y")), 0) / screenHeight},
                           {QStringLiteral("width"), width / screenWidth},
                           {QStringLiteral("height"), height / screenHeight}});
  }
  const QJsonArray children = object.value(QLatin1String("children")).toArray();
  for (qsizetype n = 0; n < children.size(); ++n) flattenAx(children.at(n), screenWidth, screenHeight, path + QLatin1Char('.') + QString::number(n), out);
}

}  // namespace

DeviceTools::DeviceTools(McClient* client, QObject* parent)
    : QObject(parent), m_client(client), m_http(new QNetworkAccessManager(this)) {
  m_axTimer.setInterval(kAxRefreshMs);
  connect(&m_axTimer, &QTimer::timeout, this, &DeviceTools::fetchAx);
  publish();
}

DeviceTools::~DeviceTools() {
  unfollow(m_foregroundFeed);
  unfollow(m_eventFeed);
}

void DeviceTools::setTarget(const QString& environment, const QString& hubBase, const QString& hostId, const QString& deviceId,
                            const QString& platform) {
  if (environment == m_environment && hubBase == m_hubBase && hostId == m_hostId && deviceId == m_deviceId && platform == m_platform)
    return;
  ++m_generation;
  unfollow(m_foregroundFeed);
  unfollow(m_eventFeed);
  m_environment = environment;
  m_hubBase = hubBase;
  m_hostId = hostId;
  m_deviceId = deviceId;
  m_platform = platform;
  m_loaded = false;
  m_pending = false;
  m_error.clear();
  m_settings = {};
  m_foreground.clear();
  m_foregroundKnown = false;
  m_foregroundLive = false;
  m_latitude.clear();
  m_longitude.clear();
  m_events.clear();
  m_eventLogOpen = false;
  m_axOverlay = false;
  m_axTimer.stop();
  m_axElements.clear();
  if (m_open && !m_deviceId.isEmpty()) {
    read();
    followForeground();
  }
  publish();
}

void DeviceTools::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  if (open) {
    // The settings are read again on every open: they may have changed on
    // the device while the drawer was away.
    if (!m_deviceId.isEmpty()) {
      m_loaded = false;
      read();
    }
    followForeground();
  } else {
    unfollow(m_foregroundFeed);
    unfollow(m_eventFeed);
    m_events.clear();
    m_eventLogOpen = false;
    setAxOverlay(false);
  }
  publish();
}

void DeviceTools::read() {
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("device.detail"),
                 QJsonObject{{QStringLiteral("hostId"), m_hostId}, {QStringLiteral("deviceId"), m_deviceId}},
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     m_error = *error;
                     publish();
                     return;
                   }
                   take(result.toObject(), false);
                 });
}

void DeviceTools::take(const QJsonObject& detail, bool fromAction) {
  m_settings = detail.value(QLatin1String("settings")).toObject();
  if (!m_foregroundLive) {
    const QJsonValue app = detail.value(QLatin1String("foregroundApp"));
    m_foreground = app.isObject() ? text(app.toObject(), QLatin1String("id")) : QString();
    m_foregroundKnown = true;
  }
  if (!m_foreground.isEmpty()) m_lastForeground = m_foreground;
  m_loaded = true;
  if (fromAction) m_pending = false;
  publish();
}

void DeviceTools::act(const QJsonObject& action) {
  if (m_pending || m_deviceId.isEmpty()) return;
  m_pending = true;
  m_error.clear();
  publish();
  QJsonObject input = action;
  input.insert(QStringLiteral("hostId"), m_hostId);
  input.insert(QStringLiteral("deviceId"), m_deviceId);
  const int generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("device.action"), input,
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     m_pending = false;
                     m_error = *error;
                     publish();
                     return;
                   }
                   take(result.toObject(), true);
                 });
}

void DeviceTools::choose(const QString& control, const QString& choice) {
  if (control == QLatin1String("Appearance")) {
    act({{QStringLiteral("type"), QStringLiteral("setAppearance")},
         {QStringLiteral("value"), choice == QLatin1String("Dark") ? QStringLiteral("dark") : QStringLiteral("light")}});
  } else if (control == QLatin1String("Text size")) {
    act({{QStringLiteral("type"), QStringLiteral("setTextSize")}, {QStringLiteral("value"), kTextSizes.value(choice)}});
  } else if (control == QLatin1String("Liquid Glass")) {
    act({{QStringLiteral("type"), QStringLiteral("setLiquidGlass")},
         {QStringLiteral("value"), choice == QLatin1String("Tinted") ? QStringLiteral("tinted") : QStringLiteral("clear")}});
  } else if (control == QLatin1String("Color filter")) {
    act({{QStringLiteral("type"), QStringLiteral("setColorFilter")}, {QStringLiteral("value"), kColorFilters.value(choice)}});
  } else if (control == QLatin1String("Orientation")) {
    act({{QStringLiteral("type"), QStringLiteral("setOrientation")}, {QStringLiteral("value"), kOrientations.value(choice)}});
  }
}

void DeviceTools::setSwitch(const QString& setting, bool on) {
  static const QHash<QString, QString> toggles{{QStringLiteral("Reduce Motion"), QStringLiteral("reduceMotion")},
                                               {QStringLiteral("Increase Contrast"), QStringLiteral("increaseContrast")},
                                               {QStringLiteral("Reduce Transparency"), QStringLiteral("reduceTransparency")},
                                               {QStringLiteral("Show Borders"), QStringLiteral("showBorders")},
                                               {QStringLiteral("VoiceOver"), QStringLiteral("voiceOver")},
                                               {QStringLiteral("Network"), QStringLiteral("networkEnabled")}};
  const QString key = toggles.value(setting, setting);
  act({{QStringLiteral("type"), QStringLiteral("setToggle")}, {QStringLiteral("setting"), key}, {QStringLiteral("value"), on}});
}

void DeviceTools::submit(const QString& field, const QString& value) {
  const QString trimmed = value.trimmed();
  if (trimmed.isEmpty()) return;
  if (field == QLatin1String("url"))
    act({{QStringLiteral("type"), QStringLiteral("openUrl")}, {QStringLiteral("url"), trimmed}});
  else if (field == QLatin1String("launch"))
    act({{QStringLiteral("type"), QStringLiteral("launchApp")}, {QStringLiteral("appId"), trimmed}});
}

void DeviceTools::terminate() {
  if (!m_foreground.isEmpty()) act({{QStringLiteral("type"), QStringLiteral("terminateApp")}, {QStringLiteral("appId"), m_foreground}});
}

void DeviceTools::relaunch() {
  const QString app = m_foreground.isEmpty() ? m_lastForeground : m_foreground;
  if (!app.isEmpty()) act({{QStringLiteral("type"), QStringLiteral("launchApp")}, {QStringLiteral("appId"), app}});
}

void DeviceTools::setLocationText(const QString& latitude, const QString& longitude) {
  if (latitude == m_latitude && longitude == m_longitude) return;
  m_latitude = latitude;
  m_longitude = longitude;
  publish();
}

void DeviceTools::applyLocation() {
  bool latOk = false, lonOk = false;
  const double latitude = m_latitude.trimmed().toDouble(&latOk);
  const double longitude = m_longitude.trimmed().toDouble(&lonOk);
  if (!latOk || !lonOk || std::abs(latitude) > 90 || std::abs(longitude) > 180) return;
  act({{QStringLiteral("type"), QStringLiteral("setLocation")}, {QStringLiteral("latitude"), latitude}, {QStringLiteral("longitude"), longitude}});
}

void DeviceTools::applyPreset(const QString& city) {
  const auto preset = kPresets.constFind(city);
  if (preset == kPresets.constEnd()) return;
  m_latitude = QString::number(preset->first);
  m_longitude = QString::number(preset->second);
  publish();
  act({{QStringLiteral("type"), QStringLiteral("setLocation")},
       {QStringLiteral("latitude"), preset->first},
       {QStringLiteral("longitude"), preset->second}});
}

void DeviceTools::clearLocation() {
  m_latitude.clear();
  m_longitude.clear();
  publish();
  act({{QStringLiteral("type"), QStringLiteral("clearLocation")}});
}

void DeviceTools::decide(const QString& appId, const QString& permission, const QString& decision) {
  const QString app = appId.trimmed().isEmpty() ? m_foreground : appId.trimmed();
  if (app.isEmpty()) return;
  act({{QStringLiteral("type"), QStringLiteral("setPermission")},
       {QStringLiteral("appId"), app},
       {QStringLiteral("permission"), kPermissions.value(permission)},
       {QStringLiteral("decision"), decision.toLower()}});
}

void DeviceTools::sendPush(const QString& text) {
  if (m_foreground.isEmpty() || text.trimmed().isEmpty()) return;
  act({{QStringLiteral("type"), QStringLiteral("sendPush")}, {QStringLiteral("appId"), m_foreground}, {QStringLiteral("payload"), text.trimmed()}});
}

QString DeviceTools::vendorPath(const QString& path) const {
  return m_hubBase + (m_platform == QLatin1String("ios") ? QStringLiteral("/vendor/serve-sim") : QStringLiteral("/vendor/serve-emu")) + path;
}

void DeviceTools::follow(Feed& feed, const QString& path, const std::function<void(const QJsonObject&)>& onEvent) {
  unfollow(feed);
  const QString device = QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId));
  QNetworkReply* reply = m_http->get(m_client->request(vendorPath(path), QStringLiteral("device=") + device));
  feed.reply = reply;
  feed.buffer.clear();
  connect(reply, &QNetworkReply::readyRead, this, [&feed, reply, onEvent] {
    feed.buffer += reply->readAll();
    qsizetype at;
    while ((at = feed.buffer.indexOf('\n')) >= 0) {
      const QByteArray line = feed.buffer.left(at).trimmed();
      feed.buffer.remove(0, at + 1);
      if (!line.startsWith("data:")) continue;
      const QJsonObject event = QJsonDocument::fromJson(line.mid(5).trimmed()).object();
      if (!event.isEmpty()) onEvent(event);
    }
  });
  connect(reply, &QNetworkReply::finished, this, [reply] { reply->deleteLater(); });
}

void DeviceTools::unfollow(Feed& feed) {
  if (QNetworkReply* reply = feed.reply.data()) {
    feed.reply = nullptr;
    reply->disconnect(this);
    reply->abort();
    reply->deleteLater();
  }
  feed.buffer.clear();
}

void DeviceTools::followForeground() {
  // iOS only: serve-sim pushes the frontmost app as it changes.
  if (!m_open || m_platform != QLatin1String("ios") || m_hubBase.isEmpty() || m_deviceId.isEmpty()) return;
  const int generation = m_generation;
  follow(m_foregroundFeed, QStringLiteral("/appstate"), [this, generation](const QJsonObject& event) {
    if (generation != m_generation || !event.contains(QLatin1String("bundleId"))) return;
    m_foreground = text(event, QLatin1String("bundleId"));
    m_foregroundKnown = true;
    m_foregroundLive = true;
    if (!m_foreground.isEmpty()) m_lastForeground = m_foreground;
    publish();
  });
}

void DeviceTools::followEventLog() {
  if (m_platform != QLatin1String("ios") || m_hubBase.isEmpty() || m_deviceId.isEmpty()) return;
  const int generation = m_generation;
  const auto take = [this, generation](const QJsonValue& raw, bool reset) {
    if (generation != m_generation) return;
    if (reset) m_events.clear();
    const auto add = [this](const QJsonObject& entry) {
      if (!entry.value(QLatin1String("id")).isDouble()) return;
      const QString stamp = text(entry, QLatin1String("timestamp"));
      m_events.append(QVariantMap{{QStringLiteral("time"), stamp.size() >= 19 ? stamp.mid(11, 8) : stamp},
                                  {QStringLiteral("summary"), entry.contains(QLatin1String("summary")) ? text(entry, QLatin1String("summary"))
                                                                                                        : text(entry, QLatin1String("msg"))}});
    };
    if (raw.isArray()) {
      for (const QJsonValue& entry : raw.toArray()) add(entry.toObject());
    } else {
      add(raw.toObject());
    }
    while (m_events.size() > kEventLogLimit) m_events.removeFirst();
    publish();
  };
  follow(m_eventFeed, QStringLiteral("/api/event-log/events"), [take](const QJsonObject& event) {
    if (event.value(QLatin1String("events")).isArray()) take(event.value(QLatin1String("events")), true);
    else if (event.contains(QLatin1String("event"))) take(event.value(QLatin1String("event")), false);
  });
}

void DeviceTools::setEventLogOpen(bool open) {
  if (open == m_eventLogOpen) return;
  m_eventLogOpen = open;
  if (open) {
    m_events.clear();
    followEventLog();
  } else {
    unfollow(m_eventFeed);
    m_events.clear();
  }
  publish();
}

void DeviceTools::setAxOverlay(bool on) {
  if (on == m_axOverlay) return;
  m_axOverlay = on;
  if (on) {
    fetchAx();
    m_axTimer.start();
  } else {
    m_axTimer.stop();
    m_axElements.clear();
  }
  publish();
}

void DeviceTools::fetchAx() {
  if (!m_axOverlay || m_hubBase.isEmpty() || m_deviceId.isEmpty()) return;
  const int generation = m_generation;
  QNetworkReply* reply;
  if (m_platform == QLatin1String("ios")) {
    const QString device = QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId));
    reply = m_http->get(m_client->request(vendorPath(QStringLiteral("/helper/%1/ax").arg(device))));
  } else {
    const QString device = QString::fromLatin1(QUrl::toPercentEncoding(m_deviceId));
    reply = m_http->get(m_client->request(vendorPath(QStringLiteral("/api/accessibility")), QStringLiteral("device=") + device));
  }
  connect(reply, &QNetworkReply::finished, this, [this, reply, generation] {
    reply->deleteLater();
    if (generation != m_generation || !m_axOverlay) return;
    const QJsonDocument document = QJsonDocument::fromJson(reply->readAll());
    QVariantList elements;
    if (m_platform == QLatin1String("ios")) {
      if (!document.isArray()) return;
      const QJsonArray roots = document.array();
      const QJsonObject rootFrame = roots.isEmpty() ? QJsonObject() : roots.at(0).toObject().value(QLatin1String("frame")).toObject();
      const double width = std::max(1.0, numberOr(rootFrame.value(QLatin1String("width")), 1));
      const double height = std::max(1.0, numberOr(rootFrame.value(QLatin1String("height")), 1));
      for (qsizetype n = 0; n < roots.size(); ++n) flattenAx(roots.at(n), width, height, QString::number(n), elements);
    } else {
      const QJsonArray nodes = document.object().value(QLatin1String("nodes")).toArray();
      if (nodes.isEmpty()) return;
      const QJsonObject root = nodes.at(0).toObject().value(QLatin1String("bounds")).toObject();
      const double width = std::max(1.0, numberOr(root.value(QLatin1String("right")), 1));
      const double height = std::max(1.0, numberOr(root.value(QLatin1String("bottom")), 1));
      for (qsizetype n = 1; n < nodes.size(); ++n) {
        const QJsonObject node = nodes.at(n).toObject();
        const QJsonObject bounds = node.value(QLatin1String("bounds")).toObject();
        const double left = numberOr(bounds.value(QLatin1String("left")), 0);
        const double top = numberOr(bounds.value(QLatin1String("top")), 0);
        const double w = (numberOr(bounds.value(QLatin1String("right")), left) - left) / width;
        const double h = (numberOr(bounds.value(QLatin1String("bottom")), top) - top) / height;
        QString label = text(node, QLatin1String("text"));
        if (label.isEmpty()) label = text(node, QLatin1String("contentDescription"));
        if ((w >= 0.95 && h >= 0.9) || (label.isEmpty() && !node.value(QLatin1String("clickable")).toBool())) continue;
        elements.append(QVariantMap{{QStringLiteral("label"), label},
                                    {QStringLiteral("x"), left / width},
                                    {QStringLiteral("y"), top / height},
                                    {QStringLiteral("width"), w},
                                    {QStringLiteral("height"), h}});
      }
    }
    if (elements == m_axElements) return;
    m_axElements = elements;
    publish();
  });
}

void DeviceTools::publish() {
  const bool access = !m_hubBase.isEmpty() && !m_deviceId.isEmpty();
  QVariantMap settings;
  for (auto it = m_settings.begin(); it != m_settings.end(); ++it) settings.insert(it.key(), it.value().toVariant());
  QVariantMap view{
      {QStringLiteral("open"), m_open},
      {QStringLiteral("platform"), m_platform},
      {QStringLiteral("loaded"), m_loaded},
      {QStringLiteral("pending"), m_pending},
      {QStringLiteral("error"), m_error},
      {QStringLiteral("foreground"), m_foreground.isEmpty() ? QStringLiteral("—") : m_foreground},
      {QStringLiteral("hasForeground"), !m_foreground.isEmpty()},
      {QStringLiteral("canRelaunch"), !m_lastForeground.isEmpty()},
      {QStringLiteral("settings"), settings},
      {QStringLiteral("latitude"), m_latitude},
      {QStringLiteral("longitude"), m_longitude},
      {QStringLiteral("eventLogOffered"), access && m_platform == QLatin1String("ios")},
      {QStringLiteral("eventLogOpen"), m_eventLogOpen},
      {QStringLiteral("events"), m_events},
      {QStringLiteral("axOverlay"), m_axOverlay},
      {QStringLiteral("axOffered"), access},
      {QStringLiteral("axElements"), m_axElements},
  };
  if (view == m_view) return;
  m_view = view;
  emit viewChanged();
}
