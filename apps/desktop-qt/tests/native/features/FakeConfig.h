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
  QHash<QString, QJsonArray> sources;  // usage-limit source snapshots, by environment
  QHash<QString, QJsonObject> elsewhere;  // other environments' ServerConfig, by environment
  // Other environments' settings documents, by environment: read, written and
  // published as this node's own is.
  struct Document {
    QJsonObject settings;
    int version = 0;
    QString refuseWrites;
  };
  QHash<QString, Document> documents;
  QList<QJsonObject> writes;  // every writeSettings payload, in order
  QList<bool> saved;  // whether each write was saved
  bool holdReads = false;
  bool editOnRead = false;  // another client saves right after each read
  QString refuseWrites;
  // Sensitive provider variables sealed out of the document, by
  // "<instance>/<name>" (HalC2.ProviderSecrets), and hub management keys by
  // "hub/<source id>" (HalC2.UsageLimitSources).
  QHash<QString, QString> secrets;
};

FakeConfig& fakeConfig(FakeNode& node);
// Sends `config.themes` to the environment's config subscribers.
void publishThemes(FakeNode& node, const QString& environment, const QJsonArray& themes);
// Another client's save: the document moves on, announced as `config.settings`
// unless `quietly`.
void saveElsewhere(FakeNode& node, const QString& key, const QJsonValue& value, bool quietly = false);
// The same on the environment's document ("" or the node's own for this
// node's), as the node saves a setting it owns (HalC2.Devices' device.configure).
void saveOn(FakeNode& node, const QString& environment, const QString& key, const QJsonValue& value);
// Another environment's document, created on first use; its config
// snapshot carries it.
FakeConfig::Document& documentOf(FakeNode& node, const QString& environment);
// The node's providers become `providers`, announced as `config.providers`.
void publishProviders(FakeNode& node, const QJsonArray& providers);
