// The Windows WindowsSnapShot runs on. Built only on Windows
// (cmake/NativeShell.cmake), so no test on Linux compiles or runs this file.

#include <QAbstractNativeEventFilter>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QPainter>
#include <QPointer>
#include <QRasterWindow>
#include <QThread>
#include <QVariantAnimation>

#include <atomic>
#include <future>
#include <memory>
#include <thread>

#include "WindowsSnapShot.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <dwmapi.h>

namespace {

constexpr int kHotKeyId = 0x5353;
constexpr int kProbeHotKeyId = 0x5354;
constexpr int kStillFlashMs = 120;
constexpr int kFlashMs = 200;
constexpr int kFlightMs = 330;

// The foreground window's program, as upstream's getProcessImagePath.
QString programOf(HWND window) {
  DWORD processId = 0;
  GetWindowThreadProcessId(window, &processId);
  if (!processId) return {};
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
  if (!process) return {};
  wchar_t path[32768];
  DWORD size = ARRAYSIZE(path);
  const bool found = QueryFullProcessImageNameW(process, 0, path, &size);
  CloseHandle(process);
  return found ? QString::fromWCharArray(path, int(size)) : QString();
}

QImage grabScreen(const QRect& bounds) {
  HDC screen = GetDC(nullptr);
  if (!screen) return {};
  HDC memory = CreateCompatibleDC(screen);
  HBITMAP bitmap = memory ? CreateCompatibleBitmap(screen, bounds.width(), bounds.height()) : nullptr;
  QImage image;
  if (bitmap) {
    HGDIOBJ before = SelectObject(memory, bitmap);
    const bool copied = BitBlt(memory, 0, 0, bounds.width(), bounds.height(), screen, bounds.x(), bounds.y(), SRCCOPY | CAPTUREBLT);
    SelectObject(memory, before);
    if (copied) image = QImage::fromHBITMAP(bitmap).convertToFormat(QImage::Format_RGB32);
    DeleteObject(bitmap);
  }
  if (memory) DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  return image;
}

// What the keyboard hook watches. A low-level hook has no argument of its own,
// and one pair is watched at a time.
struct Pair {
  std::atomic<DWORD> left{0};
  std::atomic<DWORD> right{0};
  std::atomic<bool> active{false};
  std::atomic<WindowsSystem*> owner{nullptr};
};
Pair g_pair;

LRESULT CALLBACK pairHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION) {
    const DWORD key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data)->vkCode;
    const DWORD left = g_pair.left;
    const DWORD right = g_pair.right;
    if (key == left || key == right) {
      if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
        // Asked of Windows, not remembered: a release the hook missed must not
        // leave a key held forever. Key repeats find `active` set.
        if (!g_pair.active && (GetAsyncKeyState(key == left ? right : left) & 0x8000)) {
          g_pair.active = true;
          if (WindowsSystem* owner = g_pair.owner) {
            QMetaObject::invokeMethod(owner, [owner] { emit owner->pressed(); }, Qt::QueuedConnection);
          }
        }
      } else {
        g_pair.active = false;
      }
    }
  }
  return CallNextHookEx(nullptr, code, message, data);
}

// A flash, or the captured image flying from the window into HAL-C2: on top,
// taking neither focus nor clicks, and placed in physical pixels as Windows
// reported the bounds. Paints only while its animation runs, and goes away.
class CueWindow : public QRasterWindow {
public:
  explicit CueWindow(const QImage& image) : m_image(image) {
    setFlags(Qt::Tool | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint | Qt::WindowDoesNotAcceptFocus | Qt::WindowTransparentForInput);
  }

  void place(const QRect& bounds) {
    SetWindowPos(HWND(winId()), HWND_TOPMOST, bounds.x(), bounds.y(), bounds.width(), bounds.height(), SWP_NOACTIVATE);
  }

  // WindowsCaptureFeedback: no system fade or scale on top of the cue's own.
  void showAt(const QRect& bounds) {
    create();
    BOOL off = TRUE;
    DwmSetWindowAttribute(HWND(winId()), DWMWA_TRANSITIONS_FORCEDISABLED, &off, sizeof(off));
    place(bounds);
    ShowWindow(HWND(winId()), SW_SHOWNOACTIVATE);
  }

  void setWhite(qreal white) {
    m_white = white;
    requestUpdate();
  }

protected:
  void paintEvent(QPaintEvent*) override {
    QPainter painter(this);
    if (!m_image.isNull()) painter.drawImage(QRect(QPoint(0, 0), size()), m_image);
    if (m_white > 0) {
      painter.setOpacity(m_white);
      painter.fillRect(QRect(QPoint(0, 0), size()), Qt::white);
    }
  }

private:
  QImage m_image;
  qreal m_white = 0;
};

class NativeWindowsSystem : public WindowsSystem, public QAbstractNativeEventFilter {
public:
  explicit NativeWindowsSystem(QObject* parent) : WindowsSystem(parent) { QCoreApplication::instance()->installNativeEventFilter(this); }

  ~NativeWindowsSystem() override {
    QCoreApplication::instance()->removeNativeEventFilter(this);
    releaseHotKey();
    stopWatching();
    // The thread reports to this object; let the blit it is in finish.
    if (m_grab) m_grab->wait();
  }

  std::optional<Window> foreground() override {
    HWND window = GetForegroundWindow();
    if (!window) return std::nullopt;
    RECT rect;
    if (!GetWindowRect(window, &rect)) return std::nullopt;
    wchar_t title[1024];
    const int length = GetWindowTextW(window, title, ARRAYSIZE(title));
    return Window{quintptr(window), QString::fromWCharArray(title, length), QRect(QPoint(rect.left, rect.top), QSize(rect.right - rect.left, rect.bottom - rect.top)),
                  programOf(window)};
  }

  void grab(const QRect& bounds) override {
    m_cancelled = false;
    auto image = std::make_shared<QImage>();
    m_grab = QThread::create([bounds, image] { *image = grabScreen(bounds); });
    connect(m_grab, &QThread::finished, this, [this, image] {
      m_grab->deleteLater();
      m_grab = nullptr;
      if (m_cancelled) return;
      if (image->isNull()) emit grabFailed(QStringLiteral("The screen could not be read."));
      else emit grabbed(*image);
    });
    m_grab->start();
  }
  bool grabbing() const override { return m_grab != nullptr; }
  void cancelGrab() override { m_cancelled = true; }

  bool holdHotKey(uint modifiers, uint key) override {
    releaseHotKey();
    m_holding = RegisterHotKey(nullptr, kHotKeyId, modifiers, key);
    return m_holding;
  }
  void releaseHotKey() override {
    if (m_holding) UnregisterHotKey(nullptr, kHotKeyId);
    m_holding = false;
  }
  bool canHoldHotKey(uint modifiers, uint key) override {
    if (!RegisterHotKey(nullptr, kProbeHotKeyId, modifiers, key)) return false;
    UnregisterHotKey(nullptr, kProbeHotKeyId);
    return true;
  }

  // The hook runs on a thread of its own that does nothing but pump messages:
  // Windows drops a low-level hook whose thread is slow to answer, and every
  // key the user types anywhere would otherwise wait on the UI thread.
  bool watchPair(uint left, uint right) override {
    stopWatching();
    g_pair.left = left;
    g_pair.right = right;
    g_pair.active = false;
    g_pair.owner = this;
    std::promise<DWORD> started;
    auto answer = started.get_future();
    m_watcher = std::thread([this, &started] {
      MSG message;
      // Gives the thread its message queue before anyone posts to it.
      PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
      HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, pairHook, GetModuleHandleW(nullptr), 0);
      started.set_value(hook ? GetCurrentThreadId() : 0);
      if (!hook) return;
      BOOL got;
      while ((got = GetMessageW(&message, nullptr, 0, 0)) > 0) {
      }
      UnhookWindowsHookEx(hook);
      if (got < 0) QMetaObject::invokeMethod(this, [this] { emit watchLost(); }, Qt::QueuedConnection);
    });
    m_watcherThread = answer.get();
    if (!m_watcherThread) stopWatching();
    return m_watcherThread != 0;
  }
  void stopWatching() override {
    if (!m_watcher.joinable()) return;
    if (m_watcherThread) PostThreadMessageW(m_watcherThread, WM_QUIT, 0, 0);
    m_watcher.join();
    m_watcherThread = 0;
    g_pair.owner = nullptr;
  }
  bool canWatchPair(uint, uint) override {
    HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, pairHook, GetModuleHandleW(nullptr), 0);
    if (!hook) return false;
    UnhookWindowsHookEx(hook);
    return true;
  }

  bool animationsEnabled() const override {
    BOOL on = TRUE;
    return !SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &on, 0) || on;
  }

  void flash(const QRect& bounds, bool animated) override {
    auto* cue = new CueWindow({});
    cue->setWhite(1);
    cue->showAt(bounds);
    run(cue, animated ? kFlashMs : kStillFlashMs, [cue, animated](qreal t) {
      if (animated) cue->setWhite(1 - t);
    });
  }

  void fly(const QImage& image, const QRect& bounds, bool flash) override {
    const QRect to = destination(bounds);
    auto* cue = new CueWindow(image);
    if (flash) cue->setWhite(1);
    cue->showAt(bounds);
    // The flash fades in place, then the flight.
    const qreal lead = flash ? qreal(kFlashMs) / (kFlashMs + kFlightMs) : 0;
    run(cue, (flash ? kFlashMs : 0) + kFlightMs, [cue, bounds, to, lead](qreal t) {
      if (t < lead) {
        cue->setWhite(1 - t / lead);
        return;
      }
      cue->setWhite(0);
      const qreal p = (t - lead) / (1 - lead);
      const qreal eased = 1 - (1 - p) * (1 - p);
      const auto mix = [eased](int from, int until) { return from + qRound((until - from) * eased); };
      cue->place(QRect(mix(bounds.x(), to.x()), mix(bounds.y(), to.y()), qMax(1, mix(bounds.width(), to.width())), qMax(1, mix(bounds.height(), to.height()))));
    });
  }

  bool cueShowing() const override { return m_cues > 0; }

  bool nativeEventFilter(const QByteArray& type, void* message, qintptr*) override {
    if (type != "windows_generic_MSG") return false;
    const auto* msg = static_cast<const MSG*>(message);
    if (msg->message != WM_HOTKEY || msg->wParam != kHotKeyId) return false;
    emit pressed();
    return true;
  }

private:
  void run(CueWindow* cue, int ms, std::function<void(qreal)> step) {
    ++m_cues;
    auto* animation = new QVariantAnimation(this);
    animation->setDuration(ms);
    animation->setStartValue(0.0);
    animation->setEndValue(1.0);
    connect(animation, &QVariantAnimation::valueChanged, cue, [step = std::move(step)](const QVariant& value) { step(value.toReal()); });
    connect(animation, &QVariantAnimation::finished, this, [this, cue] {
      --m_cues;
      cue->hide();
      delete cue;
    });
    animation->start(QAbstractAnimation::DeleteWhenStopped);
  }

  // Where a flight lands: a small rectangle inside HAL-C2's window, or the
  // middle of the captured window when HAL-C2 has none showing.
  QRect destination(const QRect& bounds) const {
    QRect target(bounds.center(), QSize(1, 1));
    for (QWindow* window : QGuiApplication::topLevelWindows()) {
      RECT rect;
      if (!dynamic_cast<CueWindow*>(window) && window->isVisible() && !IsIconic(HWND(window->winId())) && GetWindowRect(HWND(window->winId()), &rect)) {
        target = QRect(QPoint(rect.left, rect.top), QSize(rect.right - rect.left, rect.bottom - rect.top));
        break;
      }
    }
    const QSize size = bounds.size().scaled(QSize(120, 80), Qt::KeepAspectRatio);
    return QRect(QPoint(target.center().x() - size.width() / 2, target.bottom() - size.height() - 48), size);
  }

  QThread* m_grab = nullptr;
  bool m_cancelled = false;
  bool m_holding = false;
  std::thread m_watcher;
  DWORD m_watcherThread = 0;
  int m_cues = 0;
};

}  // namespace

WindowsSystem* createNativeWindowsSystem(QObject* parent) {
  return new NativeWindowsSystem(parent);
}
