package expo.modules.halc2terminal

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class HalC2TerminalModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("HalC2TerminalSurface")

    // Bumped when native hardware-keyboard handling changes; surfaced in the JS debug
    // logs so a stale native binary is distinguishable from a broken key pipeline.
    Constants(
      "hardwareKeyRevision" to 2,
    )

    View(HalC2TerminalView::class) {
      Prop("terminalKey") { view: HalC2TerminalView, terminalKey: String ->
        view.terminalKey = terminalKey
      }

      Prop("initialBuffer") { view: HalC2TerminalView, initialBuffer: String ->
        view.initialBuffer = initialBuffer
      }

      Prop("fontSize") { view: HalC2TerminalView, fontSize: Double ->
        view.fontSize = fontSize.toFloat()
      }

      Prop("focusRequest") { view: HalC2TerminalView, focusRequest: Double ->
        view.focusRequest = focusRequest
      }

      Prop("autoFocus") { view: HalC2TerminalView, autoFocus: Boolean ->
        view.autoFocus = autoFocus
      }

      Prop("appearanceScheme") { view: HalC2TerminalView, appearanceScheme: String ->
        view.appearanceScheme = appearanceScheme
      }

      Prop("themeConfig") { view: HalC2TerminalView, themeConfig: String ->
        view.themeConfig = themeConfig
      }

      Prop("backgroundColor") { view: HalC2TerminalView, backgroundColor: String ->
        view.backgroundColorHex = backgroundColor
      }

      Prop("foregroundColor") { view: HalC2TerminalView, foregroundColor: String ->
        view.foregroundColorHex = foregroundColor
      }

      Prop("mutedForegroundColor") { view: HalC2TerminalView, mutedForegroundColor: String ->
        view.mutedForegroundColorHex = mutedForegroundColor
      }

      Prop("captureRequest") { view: HalC2TerminalView, request: Double ->
        view.captureRequest = request
      }
      Events("onInput", "onResize", "onCapture")

      OnViewDestroys { view: HalC2TerminalView ->
        view.cleanup()
      }
    }
  }
}
