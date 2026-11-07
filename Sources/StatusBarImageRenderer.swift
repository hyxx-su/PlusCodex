import AppKit

/// Owns only the current menu-bar presentation's bitmap frames. Task state and
/// animation timing stay in the provider controllers.
final class StatusBarImageRenderer {
    private let provider: AIProvider
    private var title = NSAttributedString(string: "")
    private var unavailable = false
    private var hasColorGlyph = false
    private var preparationUnavailable = false
    private var appearanceKey: String?
    private var scale = 0
    private var canvas: NSSize?
    private var iconOrigin = NSPoint.zero
    private var titleOrigin = NSPoint.zero
    private var frames: [Int: NSImage] = [:]
    private(set) var bitmapBytes = 0
    var cachedFrameCount: Int { frames.count }

    init(provider: AIProvider) { self.provider = provider }

    func configure(title: NSAttributedString, unavailable: Bool) {
        guard !self.title.isEqual(to: title) || self.unavailable != unavailable else { return }
        self.title = title
        self.unavailable = unavailable
        hasColorGlyph = title.string.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.value == 0xFE0F
        }
        reset()
    }

    func reset() {
        frames.removeAll()
        canvas = nil
        appearanceKey = nil
        bitmapBytes = 0
        preparationUnavailable = false
    }

    func display(on button: NSStatusBarButton, frame: Int?) {
        // Color emoji cannot be represented faithfully by a monochrome template.
        guard let frame, !unavailable, title.length > 0, !hasColorGlyph else {
            reset()
            showNative(on: button, frame: frame)
            return
        }
        let appearance = button.effectiveAppearance
        let key = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastAqua, .darkAqua, .aqua])?.rawValue ?? appearance.name.rawValue
        let currentScale = max(1, Int(ceil(button.window?.backingScaleFactor ?? 2)))
        if appearanceKey != key || scale != currentScale {
            reset()
            appearanceKey = key
            scale = currentScale
        }
        appearance.performAsCurrentDrawingAppearance {
            guard !preparationUnavailable else { showNative(on: button, frame: frame); return }
            if canvas == nil { prepareGeometry(on: button) }
            let index = ((frame % CodexStatusIcon.spinFrameCount) + CodexStatusIcon.spinFrameCount)
                % CodexStatusIcon.spinFrameCount
            guard let image = frames[index] ?? makeFrame(index) else {
                preparationUnavailable = true
                showNative(on: button, frame: frame)
                return
            }
            if button.attributedTitle.length != 0 { button.attributedTitle = NSAttributedString(string: "") }
            if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
            if button.image !== image { button.image = image }
        }
    }

    private func showNative(on button: NSStatusBarButton, frame: Int?) {
        let image = frame != nil && !unavailable
            ? CodexStatusIcon.spinningImage(size: 18, frame: frame!, provider: provider)
            : CodexStatusIcon.image(size: 18, offline: unavailable, provider: provider)
        if button.image !== image { button.image = image }
        let position: NSControl.ImagePosition = title.length == 0 ? .imageOnly : .imageLeading
        if button.imagePosition != position { button.imagePosition = position }
        if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
    }

    private func prepareGeometry(on button: NSStatusBarButton) {
        showNative(on: button, frame: 0)
        guard let cell = button.cell else { return }
        let originalBounds = button.bounds
        let originalIcon = cell.imageRect(forBounds: originalBounds)
        let originalTitle = cell.titleRect(forBounds: originalBounds)
        // Measure AppKit's native padding rather than baking in an OS-specific
        // gap. Both temporary assignments complete before the next screen draw.
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.image = NSImage(size: originalBounds.size)
        let padding = button.bounds.width - originalBounds.width
        let width = originalBounds.width - padding
        let height = originalBounds.height
        let scales = Set([1, scale])
        let estimatedBytes = width * height * 4 * CGFloat(scales.reduce(0) { $0 + $1 * $1 })
            * CGFloat(CodexStatusIcon.spinFrameCount)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              estimatedBytes <= 8 * 1024 * 1024 else { return }
        canvas = NSSize(width: ceil(width), height: ceil(height))
        iconOrigin = NSPoint(x: originalIcon.minX - padding / 2,
                             y: button.isFlipped ? height - originalIcon.maxY : originalIcon.minY)
        titleOrigin = NSPoint(x: originalTitle.minX - padding / 2, y: (height - title.size().height) / 2)
    }

    private func makeFrame(_ frame: Int) -> NSImage? {
        guard let canvas,
              let icon = CodexStatusIcon.spinningImage(size: 18, frame: frame, provider: provider) else { return nil }
        let image = NSImage(size: canvas)
        let monochromeTitle = NSMutableAttributedString(attributedString: title)
        monochromeTitle.addAttribute(.foregroundColor, value: NSColor.black,
                                     range: NSRange(location: 0, length: title.length))
        var bytes = 0
        for factor in Set([1, scale]).sorted() {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvas.width) * factor, pixelsHigh: Int(canvas.height) * factor,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let transform = NSAffineTransform()
            transform.scale(by: CGFloat(factor))
            transform.concat()
            icon.draw(in: NSRect(origin: iconOrigin, size: NSSize(width: 18, height: 18)))
            monochromeTitle.draw(at: titleOrigin)
            NSGraphicsContext.restoreGraphicsState()
            bytes += rep.bytesPerRow * rep.pixelsHigh
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        guard bitmapBytes + bytes <= 8 * 1024 * 1024 else { return nil }
        frames[frame] = image
        bitmapBytes += bytes
        return image
    }
}
