import UIKit
import WebKit

/// Keeps browser navigation out of the website keyboard's accessory area.
/// Uses the public UIResponder override; no WebKit view-class lookup or swizzling.
@MainActor final class BrowserWebView: WKWebView {
    override var inputAccessoryView: UIView? { nil }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        removeKeyboardShortcuts()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        removeKeyboardShortcuts()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeKeyboardShortcuts()
    }

    private func removeKeyboardShortcuts() {
        // These public groups control the extra shortcut buttons on iPad.
        // iPhone's form toolbar is handled by inputAccessoryView above.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }
}
