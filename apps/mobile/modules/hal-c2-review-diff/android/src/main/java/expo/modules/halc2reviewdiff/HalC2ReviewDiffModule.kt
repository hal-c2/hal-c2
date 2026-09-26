package expo.modules.halc2reviewdiff

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class HalC2ReviewDiffModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("HalC2ReviewDiffSurface")

    View(HalC2ReviewDiffView::class) {
      Prop("tokensResetKey") { view: HalC2ReviewDiffView, tokensResetKey: String ->
        view.setTokensResetKey(tokensResetKey)
      }
      Prop("contentResetKey") { view: HalC2ReviewDiffView, contentResetKey: String ->
        view.setContentResetKey(contentResetKey)
      }
      Prop("collapsedFileIdsJson") { view: HalC2ReviewDiffView, collapsedFileIdsJson: String ->
        view.setCollapsedFileIdsJson(collapsedFileIdsJson)
      }
      Prop("viewedFileIdsJson") { view: HalC2ReviewDiffView, viewedFileIdsJson: String ->
        view.setViewedFileIdsJson(viewedFileIdsJson)
      }
      Prop("selectedRowIdsJson") { view: HalC2ReviewDiffView, selectedRowIdsJson: String ->
        view.setSelectedRowIdsJson(selectedRowIdsJson)
      }
      Prop("collapsedCommentIdsJson") { view: HalC2ReviewDiffView, collapsedCommentIdsJson: String ->
        view.setCollapsedCommentIdsJson(collapsedCommentIdsJson)
      }
      Prop("appearanceScheme") { view: HalC2ReviewDiffView, appearanceScheme: String ->
        view.setAppearanceScheme(appearanceScheme)
      }
      Prop("themeJson") { view: HalC2ReviewDiffView, themeJson: String ->
        view.setThemeJson(themeJson)
      }
      Prop("styleJson") { view: HalC2ReviewDiffView, styleJson: String ->
        view.setStyleJson(styleJson)
      }
      Prop("rowHeight") { view: HalC2ReviewDiffView, rowHeight: Double ->
        view.setRowHeight(rowHeight.toFloat())
      }
      Prop("contentWidth") { view: HalC2ReviewDiffView, contentWidth: Double ->
        view.setContentWidth(contentWidth.toFloat())
      }
      Prop("initialRowIndex") { view: HalC2ReviewDiffView, initialRowIndex: Double ->
        view.setInitialRowIndex(initialRowIndex)
      }

      Events(
        "onDebug",
        "onVisibleFileChange",
        "onToggleFile",
        "onToggleViewedFile",
        "onPressLine",
        "onToggleComment",
      )

      AsyncFunction("scrollToFile") { view: HalC2ReviewDiffView, fileId: String, animated: Boolean ->
        view.scrollToFile(fileId, animated)
      }
      AsyncFunction("scrollToTop") { view: HalC2ReviewDiffView, animated: Boolean ->
        view.scrollToTop(animated)
      }
      AsyncFunction("setRowsJson") { view: HalC2ReviewDiffView, rowsJson: String ->
        view.setRowsJson(rowsJson)
      }
      AsyncFunction("setTokensJson") { view: HalC2ReviewDiffView, tokensJson: String ->
        view.setTokensJson(tokensJson)
      }
      AsyncFunction("setTokensPatchJson") { view: HalC2ReviewDiffView, tokensPatchJson: String ->
        view.setTokensPatchJson(tokensPatchJson)
      }

      OnViewDestroys { view: HalC2ReviewDiffView ->
        view.cleanup()
      }
    }
  }
}
