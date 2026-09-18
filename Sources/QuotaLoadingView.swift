import AppKit
import QuartzCore

/// Reuses the menu background and logo sweep; captions appear only for update checks.
final class QuotaLoadingView: NSView {
    override var isFlipped: Bool { true }
    private let logoSize: CGFloat
    private let checkingForUpdates: Bool
    private let offline: Bool
    private let provider: AIProvider
    private var artworkLayer: CALayer?
    /// Deterministic layout state for headless assertions.
    private(set) var logoPoint: CGPoint = .zero
    private(set) var captionHidden = true

    init(frame: NSRect, logoSize: CGFloat = 28, checkingForUpdates: Bool = false, offline: Bool = false, provider: AIProvider = .codex) {
        self.provider = provider
        self.logoSize = logoSize
        self.checkingForUpdates = checkingForUpdates
        self.offline = offline
        super.init(frame: frame)
        captionHidden = !(checkingForUpdates || offline)
        logoPoint = CGPoint(x: frame.midX, y: frame.midY - (captionHidden ? 0 : 32))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(offline ? "네트워크 연결 없음" : checkingForUpdates ? "업데이트 확인 중. 최신 버전인지 확인하고 있어요." : "사용량을 불러오는 중")
        if !captionHidden {
            for (text, size, weight, color, y) in [
                (offline ? "네트워크 연결 없음" : "업데이트 확인 중", CGFloat(17), NSFont.Weight.semibold, NSColor.labelColor, frame.midY + 12),
                (offline ? "연결되면 다시 확인할게요." : "최신 버전인지 확인하고 있어요.", CGFloat(11), NSFont.Weight.regular, NSColor.secondaryLabelColor, frame.midY + min(42, frame.height / 2 - 26))
            ] {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: size, weight: weight)
                label.textColor = color
                label.alignment = .center
                label.frame = NSRect(x: 12, y: y, width: frame.width - 24, height: 24)
                addSubview(label)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Do not remove NSTextField's backing layers when rebuilding the logo.
        artworkLayer?.removeFromSuperlayer()
        let artwork = CALayer()
        artwork.frame = bounds
        layer.insertSublayer(artwork, at: 0)
        artworkLayer = artwork

        let host = CALayer()
        host.frame = NSRect(x: (bounds.width - logoSize) / 2, y: (bounds.height - logoSize) / 2 - (captionHidden ? 0 : 32),
                            width: logoSize, height: logoSize)
        artwork.addSublayer(host)
        logoPoint = CGPoint(x: host.frame.midX, y: host.frame.midY)

        if offline {
            let icon = CodexStatusIcon.image(size: 96, offline: true, provider: provider)
            var rect = CGRect(x: 0, y: 0, width: 96, height: 96)
            host.contents = icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            CATransaction.commit()
            return
        }

        guard let logo = loadLogo() else {
            // Resource fallback: a small moving light so the state never looks frozen.
            NSLog("PlusCodex loading logo missing")
            addSweepBar(to: artwork, midY: logoPoint.y)
            CATransaction.commit()
            return
        }

        // Grey outline of the logo, always visible beneath the light sweep.
        let base = CALayer()
        base.frame = host.bounds
        base.contents = loadLogo(tint: .labelColor)
        base.opacity = 0.35
        host.addSublayer(base)

        // White light revealed only inside the logo shape via the mask.
        let sweep = CAGradientLayer()
        sweep.frame = host.bounds
        sweep.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        sweep.locations = [0, 0.5, 1]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.mask = {
            let mask = CALayer()
            mask.frame = sweep.bounds
            mask.contents = logo
            return mask
        }()
        host.addSublayer(sweep)

        sweep.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !sweep.isHidden {
            sweep.add(self.sweepAnimation(), forKey: "loading")
        }
        CATransaction.commit()
    }

    private func addSweepBar(to layer: CALayer, midY: CGFloat) {
        let bar = CAGradientLayer()
        bar.frame = NSRect(x: bounds.midX - 60, y: midY - 2, width: 120, height: 4)
        bar.cornerRadius = 2
        bar.colors = [NSColor.labelColor.withAlphaComponent(0.12).cgColor,
                      NSColor.labelColor.cgColor,
                      NSColor.labelColor.withAlphaComponent(0.12).cgColor]
        bar.locations = [0, 0.5, 1]
        bar.startPoint = CGPoint(x: 0, y: 0.5)
        bar.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(bar)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            bar.add(self.sweepAnimation(duration: 1.6), forKey: "loading")
        }
    }

    private func sweepAnimation(duration: CFTimeInterval = 1.2) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.6, -0.35, -0.1]
        animation.toValue = [1.1, 1.35, 1.6]
        animation.duration = duration
        animation.repeatCount = .infinity
        return animation
    }

    private func loadLogo(tint: NSColor = .white) -> CGImage? {
        guard let url = Bundle.main.url(forResource: provider.resource, withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return nil }
        // The menu header tints with labelColor; the sweep mask always stays white.
        let tinted = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            source.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        var rect = CGRect(x: 0, y: 0, width: 96, height: 96)
        return tinted.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
