#pragma once

// What every fuzz test shares (README.md): Qt values made of the engine's, a
// JSON domain the MC's messages are built from, and settling the event loop.
// FuzzMain.cpp gives the main: a home of its own and a QGuiApplication
// (offscreen) before any FUZZ_TEST runs.
//
//   void ShortcutParses(const std::string& text) {
//     keybindings::parseShortcut(halc2::fuzz::utf8(text));
//   }
//   FUZZ_TEST(Keybindings, ShortcutParses)
//       .WithDomains(halc2::fuzz::Text({"mod", "shift", "+"}));
//
//   void FramesFold(const std::vector<halc2::fuzz::JsonSteps>& frames) {
//     TimelineModel model(...);
//     for (const auto& frame : frames) model.receive(halc2::fuzz::object(frame));
//   }
//   FUZZ_TEST(Timeline, FramesFold)
//       .WithDomains(fuzztest::VectorOf(halc2::fuzz::Json(kKeys, kTexts)).WithMaxSize(8))
//       .WithSeeds([] { return std::vector<std::tuple<std::vector<halc2::fuzz::JsonSteps>>>{
//           {halc2::fuzz::messages({R"({"t":"live","offset":1})"})}}; });

#include <QByteArray>
#include <QCoreApplication>
#include <QEvent>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>

#include <cstdint>
#include <initializer_list>
#include <ostream>
#include <string>
#include <string_view>
#include <vector>

#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

namespace halc2::fuzz {

// The engine's bytes as Qt's.
inline QByteArray bytes(const std::string& value) { return QByteArray(value.data(), qsizetype(value.size())); }
// Bytes read as UTF-8, as a socket's text frame or a file is: what is not
// UTF-8 becomes U+FFFD.
inline QString utf8(const std::string& value) { return QString::fromUtf8(value.data(), qsizetype(value.size())); }
// Bytes read as UTF-16 code units, two each (an odd last byte dropped): text
// that can hold what UTF-8 cannot, as lone surrogates, which a JSON string's
// `\ud800` escape delivers.
inline QString utf16(const std::string& value) {
  return QString(reinterpret_cast<const QChar*>(value.data()), qsizetype(value.size() / 2));
}

// Arbitrary bytes whose mutations splice in `words`: the tokens a parser looks
// for, which the engine cannot learn from Qt's comparisons (Qt is not
// instrumented).
inline auto Text(std::vector<std::string> words) {
  return fuzztest::Arbitrary<std::string>().WithDictionary(std::move(words));
}
// One of `words` as it is, or bytes that splice them in: a key or a value a
// handler compares against.
inline auto Word(std::vector<std::string> words) {
  return fuzztest::OneOf(fuzztest::ElementOf(words), Text(words));
}

// One step of building a JSON value; a list of them (JsonSteps) is one value,
// read by object() or array(). Within an object every step's `key` is the key
// it goes under; within an array keys are ignored. Opening steps nest (as far
// as kJsonDepth), Close ends the innermost, and whatever is open at the end
// closes. Any list reads as some JSON, so the engine's mutations stay inside
// what a parsed message can be, while the keys and words a handler looks for
// come from its dictionary (Json()).
struct JsonStep {
  enum Op : std::uint8_t { Object, Array, Close, String, Integer, Real, True, False, Null, OpCount };
  std::uint8_t op = Null;
  std::string key;
  std::string text;      // a String's
  std::int64_t integer = 0;  // an Integer's
  double real = 0;       // a Real's
};
using JsonSteps = std::vector<JsonStep>;
// Deeper openings are read as null; Qt's parser stops at 1024.
constexpr int kJsonDepth = 64;

// JSON whose keys are mostly `keys` and whose strings are mostly `texts`.
inline auto Json(std::vector<std::string> keys, std::vector<std::string> texts, std::size_t maxSteps = 256) {
  return fuzztest::VectorOf(fuzztest::StructOf<JsonStep>(fuzztest::InRange<std::uint8_t>(0, JsonStep::OpCount - 1),
                                                         Word(std::move(keys)), Word(std::move(texts)),
                                                         fuzztest::Arbitrary<std::int64_t>(), fuzztest::Finite<double>()))
      .WithMaxSize(maxSteps);
}

namespace detail {

struct Open {
  bool isObject = true;
  QString key;  // where it goes in its parent
  QJsonObject object;
  QJsonArray array;
  QJsonValue value() const { return isObject ? QJsonValue(object) : QJsonValue(array); }
};

inline void put(Open& into, const QString& key, const QJsonValue& value) {
  if (into.isObject) {
    into.object.insert(key, value);
  } else {
    into.array.append(value);
  }
}

inline Open read(const JsonSteps& steps, bool isObject) {
  std::vector<Open> open{Open{isObject}};
  const auto close = [&] {
    Open done = std::move(open.back());
    open.pop_back();
    put(open.back(), done.key, done.value());
  };
  for (const JsonStep& step : steps) {
    const QString key = utf8(step.key);
    switch (step.op) {
      case JsonStep::Object:
      case JsonStep::Array:
        if (int(open.size()) > kJsonDepth) {
          put(open.back(), key, QJsonValue::Null);
        } else {
          open.push_back(Open{step.op == JsonStep::Object, key});
        }
        break;
      case JsonStep::Close:
        if (open.size() > 1) close();
        break;
      case JsonStep::String: put(open.back(), key, utf8(step.text)); break;
      case JsonStep::Integer: put(open.back(), key, double(step.integer)); break;
      case JsonStep::Real: put(open.back(), key, step.real); break;
      case JsonStep::True: put(open.back(), key, true); break;
      case JsonStep::False: put(open.back(), key, false); break;
      default: put(open.back(), key, QJsonValue::Null); break;
    }
  }
  while (open.size() > 1) close();
  return std::move(open.front());
}

inline void write(const QString& key, const QJsonValue& value, JsonSteps& steps) {
  const std::string name = key.toStdString();
  if (value.isObject()) {
    steps.push_back({JsonStep::Object, name});
    const QJsonObject object = value.toObject();
    for (auto it = object.begin(); it != object.end(); ++it) write(it.key(), it.value(), steps);
    steps.push_back({JsonStep::Close});
  } else if (value.isArray()) {
    steps.push_back({JsonStep::Array, name});
    for (const QJsonValue& item : value.toArray()) write({}, item, steps);
    steps.push_back({JsonStep::Close});
  } else if (value.isString()) {
    steps.push_back({JsonStep::String, name, value.toString().toStdString()});
  } else if (value.isDouble()) {
    const double number = value.toDouble();
    // The range first: a double outside int64 is undefined to cast.
    if (number > -9e18 && number < 9e18 && number == double(std::int64_t(number))) {
      steps.push_back({JsonStep::Integer, name, {}, std::int64_t(number)});
    } else {
      steps.push_back({JsonStep::Real, name, {}, 0, number});
    }
  } else if (value.isBool()) {
    steps.push_back({value.toBool() ? JsonStep::True : JsonStep::False, name});
  } else {
    steps.push_back({JsonStep::Null, name});
  }
}

}  // namespace detail

// The object `steps` build (the steps are its members).
inline QJsonObject object(const JsonSteps& steps) { return detail::read(steps, true).object; }
// The array `steps` build (the steps are its items).
inline QJsonArray array(const JsonSteps& steps) { return detail::read(steps, false).array; }

// The steps object() or array() reads back as `json`, a JSON object or array
// written out: for seeds, in the shape the MC sends. Aborts on anything else,
// so a seed with a typo fails loudly instead of seeding nothing.
inline JsonSteps steps(std::string_view json) {
  QJsonParseError error;
  const QJsonDocument document = QJsonDocument::fromJson(QByteArray(json.data(), qsizetype(json.size())), &error);
  if (document.isNull()) qFatal("fuzz: seed is not JSON (%s): %.*s", qPrintable(error.errorString()), int(json.size()), json.data());
  JsonSteps steps;
  if (document.isObject()) {
    const QJsonObject root = document.object();
    for (auto it = root.begin(); it != root.end(); ++it) detail::write(it.key(), it.value(), steps);
  } else {
    for (const QJsonValue& item : document.array()) detail::write({}, item, steps);
  }
  return steps;
}
// A sequence of messages written out, for a seed of a VectorOf(Json(...)).
inline std::vector<JsonSteps> messages(std::initializer_list<std::string_view> json) {
  std::vector<JsonSteps> all;
  for (std::string_view one : json) all.push_back(steps(one));
  return all;
}

// What a value reads as, compact, for a regression test made from a finding.
// Printed to stderr when HAL_C2_FUZZ_PRINT is set (README.md, "When it finds something").
inline void print(const QJsonObject& value) {
  if (qEnvironmentVariableIsSet("HAL_C2_FUZZ_PRINT")) {
    fprintf(stderr, "fuzz: %s\n", QJsonDocument(value).toJson(QJsonDocument::Compact).constData());
  }
}
inline void print(const QJsonArray& value) {
  if (qEnvironmentVariableIsSet("HAL_C2_FUZZ_PRINT")) {
    fprintf(stderr, "fuzz: %s\n", QJsonDocument(value).toJson(QJsonDocument::Compact).constData());
  }
}
inline void print(const QString& value) {
  if (qEnvironmentVariableIsSet("HAL_C2_FUZZ_PRINT")) {
    fprintf(stderr, "fuzz: %s\n", QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact).constData());
  }
}

// Delivers what is posted, deferred deletes included, without waiting for
// more: what an input left queued runs before the next one, so a crash shows
// on the input that caused it.
inline void settle() {
  QCoreApplication::sendPostedEvents();
  QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
  QCoreApplication::processEvents();
}

}  // namespace halc2::fuzz

// How gtest prints a QString in a failed assertion, as text.
inline void PrintTo(const QString& value, std::ostream* out) { *out << '"' << value.toStdString() << '"'; }
