#include "ProjectIdentity.h"

#include <QHash>
#include <QRegularExpression>

namespace projectidentity {

namespace {

// By code point: a glyph outside the basic plane is one character.
QList<char32_t> glyphs(const QString& text) {
  QList<char32_t> list;
  for (const uint glyph : text.toUcs4()) list.append(char32_t(glyph));
  return list;
}

QString fromGlyph(char32_t glyph) {
  return QString::fromUcs4(&glyph, 1);
}

QString normalized(const QString& name) {
  return name.normalized(QString::NormalizationForm_KC).trimmed();
}

QString text(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

}  // namespace

const QStringList& colors() {
  static const QStringList list{
      QStringLiteral("gray"),   QStringLiteral("red"),     QStringLiteral("orange"), QStringLiteral("amber"),  QStringLiteral("yellow"),
      QStringLiteral("lime"),   QStringLiteral("green"),   QStringLiteral("emerald"), QStringLiteral("teal"),   QStringLiteral("cyan"),
      QStringLiteral("sky"),    QStringLiteral("blue"),    QStringLiteral("indigo"), QStringLiteral("violet"), QStringLiteral("purple"),
      QStringLiteral("fuchsia"), QStringLiteral("pink"),   QStringLiteral("rose"),
  };
  return list;
}

QString tint(const QString& color) {
  // Tailwind's 500s, as the web's swatches.
  static const QHash<QString, QString> hex{
      {QStringLiteral("gray"), QStringLiteral("#6b7280")},    {QStringLiteral("red"), QStringLiteral("#ef4444")},
      {QStringLiteral("orange"), QStringLiteral("#f97316")},  {QStringLiteral("amber"), QStringLiteral("#f59e0b")},
      {QStringLiteral("yellow"), QStringLiteral("#eab308")},  {QStringLiteral("lime"), QStringLiteral("#84cc16")},
      {QStringLiteral("green"), QStringLiteral("#22c55e")},   {QStringLiteral("emerald"), QStringLiteral("#10b981")},
      {QStringLiteral("teal"), QStringLiteral("#14b8a6")},    {QStringLiteral("cyan"), QStringLiteral("#06b6d4")},
      {QStringLiteral("sky"), QStringLiteral("#0ea5e9")},     {QStringLiteral("blue"), QStringLiteral("#3b82f6")},
      {QStringLiteral("indigo"), QStringLiteral("#6366f1")},  {QStringLiteral("violet"), QStringLiteral("#8b5cf6")},
      {QStringLiteral("purple"), QStringLiteral("#a855f7")},  {QStringLiteral("fuchsia"), QStringLiteral("#d946ef")},
      {QStringLiteral("pink"), QStringLiteral("#ec4899")},    {QStringLiteral("rose"), QStringLiteral("#f43f5e")},
  };
  return hex.value(color, QStringLiteral("#6b7280"));
}

const QStringList& symbols() {
  static const QStringList list{
      QStringLiteral("folder-code"), QStringLiteral("rocket"),   QStringLiteral("package"),  QStringLiteral("database"),
      QStringLiteral("shopping-cart"), QStringLiteral("book"),   QStringLiteral("bug"),      QStringLiteral("cpu"),
      QStringLiteral("flask-conical"), QStringLiteral("gamepad-2"), QStringLiteral("music"), QStringLiteral("palette"),
      QStringLiteral("shield"),      QStringLiteral("heart"),    QStringLiteral("globe"),    QStringLiteral("terminal"),
      QStringLiteral("code"),        QStringLiteral("zap"),      QStringLiteral("star"),     QStringLiteral("bot"),
      QStringLiteral("brain"),       QStringLiteral("sparkles"), QStringLiteral("lightbulb"), QStringLiteral("server"),
      QStringLiteral("cloud"),       QStringLiteral("laptop"),   QStringLiteral("smartphone"), QStringLiteral("wrench"),
      QStringLiteral("hammer"),      QStringLiteral("image"),
  };
  return list;
}

Identity derive(const QString& name) {
  static const QRegularExpression word(QStringLiteral("[\\p{L}\\p{N}]+"), QRegularExpression::UseUnicodePropertiesOption);
  const QString clean = normalized(name);
  QStringList words;
  for (auto it = word.globalMatch(clean); it.hasNext();) words.append(it.next().captured());
  QString letters = QStringLiteral("PR");
  if (!words.isEmpty()) {
    const QList<char32_t> first = glyphs(words.first());
    QString second;
    for (qsizetype i = 1; i < first.size() && second.isEmpty(); ++i) {
      if (QChar::isDigit(first.at(i)) || QChar::category(first.at(i)) == QChar::Number_Letter || QChar::category(first.at(i)) == QChar::Number_Other) {
        second = fromGlyph(first.at(i));
      }
    }
    if (second.isEmpty()) second = fromGlyph(words.size() > 1 ? glyphs(words.last()).first() : first.last());
    const QList<char32_t> pair = glyphs((fromGlyph(first.first()) + second).toUpper());
    letters = QString::fromUcs4(pair.constData(), std::min<qsizetype>(2, pair.size()));
  }
  QString seed = clean.toLower();
  if (seed.isEmpty()) seed = QStringLiteral("project");
  qsizetype index = 0;
  for (const char32_t glyph : glyphs(seed)) index = (index * 31 + qsizetype(glyph)) % colors().size();
  return {letters, colors().at(index)};
}

QString monogram(const QString& typed) {
  return normalized(typed).toUpper();
}

bool validMonogram(const QString& value) {
  static const QRegularExpression pattern(QStringLiteral("^[\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}\\x{200c}\\x{200d}]*$"),
                                          QRegularExpression::UseUnicodePropertiesOption);
  if (!pattern.match(value).hasMatch()) return false;
  // Marks and joiners ride on the character before them.
  int characters = 0;
  for (const char32_t glyph : glyphs(value)) {
    const QChar::Category category = QChar::category(glyph);
    const bool rides = category == QChar::Mark_NonSpacing || category == QChar::Mark_SpacingCombining || category == QChar::Mark_Enclosing ||
                       glyph == 0x200c || glyph == 0x200d;
    if (!rides) ++characters;
  }
  return characters >= 1 && characters <= 2;
}

QVariantMap icon(const QJsonObject& row) {
  const QJsonObject picked = row.value(QLatin1String("projectIcon")).toObject();
  const QString kind = text(picked, "kind");
  QString letters = kind == QLatin1String("monogram") ? text(picked, "text") : text(picked, "monogramText");
  if (letters.isEmpty() && kind == QLatin1String("lucide")) letters = text(picked, "monogram");
  if (kind == QLatin1String("emoji")) {
    return {{QStringLiteral("kind"), kind}, {QStringLiteral("emoji"), text(picked, "emoji")}, {QStringLiteral("automatic"), false}};
  }
  if (!letters.isEmpty()) {
    return {{QStringLiteral("kind"), QStringLiteral("monogram")}, {QStringLiteral("text"), letters}, {QStringLiteral("color"), text(picked, "color")},
            {QStringLiteral("tint"), tint(text(picked, "color"))}, {QStringLiteral("automatic"), false}};
  }
  if (kind == QLatin1String("lucide")) {
    // A symbol this build cannot draw shows as the folder the web falls back to.
    const QString name = symbols().contains(text(picked, "name")) ? text(picked, "name") : QStringLiteral("folder-code");
    return {{QStringLiteral("kind"), kind}, {QStringLiteral("name"), name}, {QStringLiteral("symbol"), text(picked, "name")},
            {QStringLiteral("color"), text(picked, "color")}, {QStringLiteral("tint"), tint(text(picked, "color"))}, {QStringLiteral("automatic"), false}};
  }
  const Identity automatic = derive(text(row, "title"));
  return {{QStringLiteral("kind"), QStringLiteral("monogram")}, {QStringLiteral("text"), automatic.monogram}, {QStringLiteral("color"), automatic.color},
          {QStringLiteral("tint"), tint(automatic.color)}, {QStringLiteral("automatic"), true}};
}

QJsonObject wire(const QString& kind, const QString& value, const QString& color) {
  if (kind == QLatin1String("emoji")) return {{QStringLiteral("kind"), kind}, {QStringLiteral("emoji"), value}};
  if (kind == QLatin1String("monogram")) {
    return {{QStringLiteral("kind"), QStringLiteral("lucide")}, {QStringLiteral("name"), QStringLiteral("folder-code")}, {QStringLiteral("color"), color},
            {QStringLiteral("monogramText"), value}};
  }
  return {{QStringLiteral("kind"), QStringLiteral("lucide")}, {QStringLiteral("name"), value}, {QStringLiteral("color"), color}};
}

bool isImage(const QString& path) {
  static const QStringList extensions{QStringLiteral("png"), QStringLiteral("jpg"), QStringLiteral("jpeg"), QStringLiteral("gif"), QStringLiteral("svg"),
                                      QStringLiteral("webp"), QStringLiteral("ico"), QStringLiteral("avif"), QStringLiteral("bmp")};
  const qsizetype dot = path.lastIndexOf(QLatin1Char('.'));
  return dot >= 0 && extensions.contains(path.mid(dot + 1).toLower());
}

}  // namespace projectidentity
