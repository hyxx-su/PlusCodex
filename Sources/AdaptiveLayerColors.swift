import AppKit
import ObjectiveC

extension NSColor {
    // Applying alpha directly to a semantic color can resolve it against the
    // current appearance. Keep that operation inside the dynamic provider.
    func adaptiveAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved: NSColor = .clear
            appearance.performAsCurrentDrawingAppearance {
                resolved = self.withAlphaComponent(alpha)
            }
            return resolved
        }
    }
}

/// CALayer stores resolved colors, so keep the semantic NSColor alongside it
/// and resolve again when the owning view changes appearance.
private final class AdaptiveLayerColors {
    weak var view: NSView?
    var background: NSColor?
    var border: NSColor?
    var observation: NSKeyValueObservation?

    init(view: NSView) {
        self.view = view
        observation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.update()
        }
    }

    func update() {
        guard let view else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let background { view.layer?.backgroundColor = background.cgColor }
            if let border { view.layer?.borderColor = border.cgColor }
            CATransaction.commit()
            view.needsDisplay = true
        }
    }
}

private var adaptiveLayerColorsKey: UInt8 = 0

extension NSView {
    private var adaptiveLayerColors: AdaptiveLayerColors {
        if let colors = objc_getAssociatedObject(self, &adaptiveLayerColorsKey) as? AdaptiveLayerColors {
            return colors
        }
        let colors = AdaptiveLayerColors(view: self)
        objc_setAssociatedObject(self, &adaptiveLayerColorsKey, colors, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return colors
    }

    func setAdaptiveBackgroundColor(_ color: NSColor) {
        adaptiveLayerColors.background = color
        adaptiveLayerColors.update()
    }

    func setAdaptiveBorderColor(_ color: NSColor) {
        adaptiveLayerColors.border = color
        adaptiveLayerColors.update()
    }
}
