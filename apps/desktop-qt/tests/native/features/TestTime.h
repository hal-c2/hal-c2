#pragma once

// How long a test waits for a signal or a condition. The deadline is a bound on
// a wait that ends when the thing happens, so it stretches with
// HAL_C2_TEST_TIME_SCALE (a number, default 1) for a process that runs slowed,
// as under Valgrind (`mise prop:valgrind` sets 20). Tests wait through this
// header's helpers, not QTRY_* or QTest::qWaitFor with their own 5 s.

#include <QByteArray>
#include <QTest>

#include <cmath>
#include <functional>

namespace halc2::test {

// The multiplier, read once.
inline double timeScale() {
  static const double scale = [] {
    bool ok = false;
    const double value = qEnvironmentVariable("HAL_C2_TEST_TIME_SCALE").toDouble(&ok);
    return ok && value >= 1 ? value : 1.0;
  }();
  return scale;
}

// `ms` milliseconds, stretched.
inline int scaled(int ms) { return static_cast<int>(std::lround(ms * timeScale())); }

// What a wait takes before it gives up, in milliseconds.
inline int wait() { return scaled(5000); }

// QTest::qWaitFor with that deadline.
template <typename Predicate>
bool waitFor(Predicate predicate) { return QTest::qWaitFor(predicate, wait()); }

} // namespace halc2::test

// QTRY_VERIFY and QTRY_COMPARE with that deadline.
#define HAL_C2_TRY_VERIFY(expr) QTRY_VERIFY_WITH_TIMEOUT((expr), halc2::test::wait())
#define HAL_C2_TRY_COMPARE(expr, expected) QTRY_COMPARE_WITH_TIMEOUT((expr), (expected), halc2::test::wait())
