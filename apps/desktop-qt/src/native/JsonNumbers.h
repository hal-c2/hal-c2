#pragma once

#include <QJsonValue>
#include <QtGlobal>

#include <cmath>
#include <limits>
#include <optional>

// Numbers off the wire are doubles, and a double outside the target integer's
// range is undefined to cast. An MC (or a corrupt cache) can send 1e300, so
// every integer read of one goes through here.
namespace jsonnumbers {

// The whole number a value holds, or nothing: a value that is no number, has a
// fractional part, or lies outside qint64 reads the same as a missing one.
inline std::optional<qint64> integerOf(const QJsonValue& value) {
  constexpr qint64 none = std::numeric_limits<qint64>::min();
  const qint64 number = value.toInteger(none);
  if (number == none) return std::nullopt;
  return number;
}

// A double cut to the nearest value T holds (NaN reads as 0), for display
// numbers and UI input where a fraction truncates rather than disqualifies.
template <typename T = qint64>
inline T saturate(double value) {
  if (std::isnan(value)) return 0;
  if (value <= double(std::numeric_limits<T>::min())) return std::numeric_limits<T>::min();
  if (value >= double(std::numeric_limits<T>::max())) return std::numeric_limits<T>::max();
  return T(value);
}

}  // namespace jsonnumbers
