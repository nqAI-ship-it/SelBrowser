import UIKit

/// Liquid Glass is confined to browser navigation, never injected into website content.
@MainActor enum BrowserGlass {
    static func containerEffect() -> UIVisualEffect? {
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            let effect = UIGlassContainerEffect()
            effect.spacing = 10
            return effect
        }
        return nil
    }

    static func buttonConfiguration(prominent: Bool = false) -> UIButton.Configuration {
        if #available(iOS 26.0, *) {
            return prominent ? .prominentGlass() : .glass()
        }
        return prominent ? .filled() : .tinted()
    }

    static func animate(_ changes: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled { changes() }
        else { UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) }
    }
}

final class BrowserGlassView: UIVisualEffectView {
    private let interactive: Bool
    init(interactive: Bool = false) {
        self.interactive = interactive
        super.init(effect: nil)
        if #available(iOS 26.0, *) { cornerConfiguration = .capsule() }
        else { layer.cornerRadius = 28; layer.cornerCurve = .continuous; clipsToBounds = true }
        refreshMaterial()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshMaterial), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshMaterial() {
        if UIAccessibility.isReduceTransparencyEnabled {
            effect = nil
            backgroundColor = .secondarySystemBackground
        } else if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = interactive
            effect = glass
            backgroundColor = .clear
        } else {
            effect = UIBlurEffect(style: .systemChromeMaterial)
            backgroundColor = .clear
        }
    }
}
