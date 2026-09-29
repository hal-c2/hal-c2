#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>

class FakeNode;

// The node's settings document and `config` shape (SettingsSteps.cpp): one
// versioned document, `hal-c2.readSettings` / `hal-c2.writeSettings` refusing
// a stale version as the node does, and the config frames for each
// environment's subscribers.
struct FakeConfig {
  QJsonObject settings;
  int version = 0;
  QJsonObject config;  // ServerConfig, less settings
  QHash<QString, QJsonArray> themes;  // by environment
  QHash<QString, QJsonObject> elsewhere;  // other environments' ServerConfig, by environment
  QList<QJsonObject> writes;  // every writeSettings payload, in order
  QList<bool> saved;  // whether each write was saved
  bool holdReads = false;
  bool editOnRead = false;  // another client saves right after each read
  QString refuseWrites;
};

FakeConfig& fakeConfig(FakeNode& node);
// Sends `config.themes` to the environment's config subscribers.
void publishThemes(FakeNode& node, const QString& environment, const QJsonArray& themes);
// Another client's save: the document moves on, announced as `config.settings`
// unless `quietly`.
void saveElsewhere(FakeNode& node, const QString& key, const QJsonValue& value, bool quietly = false);
// The node's providers become `providers`, announced as `config.providers`.
void publishProviders(FakeNode& node, const QJsonArray& providers);
