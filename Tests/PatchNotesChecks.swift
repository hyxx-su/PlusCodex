import AppKit

@main struct PatchNotesChecks {
    static func main() throws {
        _ = NSApplication.shared
        let standard = UserDefaults.standard
        let arguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let originalAppearance = NSApp.appearance
        var koreanArguments = arguments
        koreanArguments["appLanguage"] = "ko"
        standard.setVolatileDomain(koreanArguments, forName: UserDefaults.argumentDomain)
        defer {
            standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            NSApp.appearance = originalAppearance
        }

        let notes = PatchNote.bundled()
        precondition(notes.count >= 20 && notes.first?.version == "v1.1.9" && notes.last?.version == "v1.0.0")
        precondition(Set(notes.map(\.version)).count == notes.count)
        precondition(notes.allSatisfy { !$0.body.isEmpty && ISO8601DateFormatter().date(from: $0.publishedAt) != nil })
        precondition(notes.allSatisfy { note in
            AppLanguage.allCases.allSatisfy { language in
                note.summary?[language.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }, "Every release must have a concise summary in both UI languages")
        precondition(notes.allSatisfy {
            $0.url.absoluteString == "https://github.com/hyxx-su/PlusCodex/releases/tag/" + $0.version
        })
        precondition(PatchNote.bundled(in: Bundle(for: NSView.self)).isEmpty,
                     "A missing release resource must not crash settings")
        let empty = PatchNotesView(frame: NSRect(x: 0, y: 0, width: 469, height: 600),
                                   notes: [], currentVersion: "v2.3.4")
        empty.layoutSubtreeIfNeeded()
        precondition(descendants(empty).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "패치노트를 불러올 수 없습니다." && !$0.isHidden })
        precondition(descendants(empty).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "패치노트 (현재 버전: v2.3.4)" }, "Never duplicate the version prefix")
        let legacy = try JSONDecoder().decode(PatchNote.self, from: Data(#"{"version":"v1.0.0","publishedAt":"2026-09-16T00:00:00Z","url":"https://github.com/hyxx-su/PlusCodex/releases/tag/v1.0.0","body":"Original release notes"}"#.utf8))
        precondition(legacy.summary == nil, "Older release resources remain decodable without summaries")
        let legacyPage = PatchNotesView(frame: NSRect(x: 0, y: 0, width: 469, height: 600), notes: [legacy], bannerImage: nil)
        legacyPage.layoutSubtreeIfNeeded()
        let legacyCaption = descendants(legacyPage).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "patch-note-summary-v1.0.0" }!
        let legacyDate = ISO8601DateFormatter().date(from: legacy.publishedAt)!
        precondition(legacyCaption.stringValue == legacyDate.formatted(.dateTime.year().month().day().locale(L10n.locale)))
        let legacyCard = descendants(legacyPage).first { $0.identifier?.rawValue == "patch-note-v1.0.0" }!
        precondition(legacyCard.frame.height == 78 && banners(in: legacyPage).isEmpty,
                     "Missing banner resources must preserve a usable text-only card")

        let suite = "PlusCodex.patch-notes.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = LoginLaunchController(defaults: defaults, readStatus: { .notRegistered },
                                           register: {}, unregister: {})
        let controller = AISettingsWindow(settings: ProviderSettings(defaults: defaults),
            notificationSettings: NotificationSettings(defaults: defaults),
            wakeSettings: CodexWakeSettings(defaults: defaults), login: login,
            language: LanguageSettings(defaults: defaults),
            claudeAvailability: { .availableOrUnknown }, grokAvailability: { .readyToCheck })
        let root = controller.window!.contentView!
        let page = descendants(root).compactMap { $0 as? PatchNotesView }.first!
        let navigation = root.subviews.compactMap { $0 as? NSButton }
            .first { $0.tag == 3 && $0.accessibilityLabel() == "패치노트" && !$0.isHidden }!
        navigation.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(page.superview?.isHidden == false)
        let pages = root.subviews.filter { $0.frame.width == 469 }
        precondition(pages.count == 4 && pages.filter { !$0.isHidden }.count == 1)
        let scroll = page.subviews.compactMap { $0 as? NSScrollView }.first!
        let document = scroll.documentView!
        let cards = document.subviews.filter {
            $0.identifier?.rawValue.hasPrefix("patch-note-v") == true
        }.sorted { $0.frame.minY < $1.frame.minY }
        precondition(cards.count == notes.count)
        let images = banners(in: page)
        precondition(images.count == notes.count)
        let sharedBanner = images.first!.image!
        precondition(sharedBanner.size == NSSize(width: 1672, height: 941))
        precondition(images.allSatisfy { $0.image === sharedBanner }, "All releases must share the same banner image")
        let bannerHeight = ceil(437 * sharedBanner.size.height / sharedBanner.size.width)
        let collapsedCardHeight = bannerHeight + 78
        precondition(cards.allSatisfy { $0.frame.width == 437 && $0.frame.height == collapsedCardHeight })
        precondition(images.allSatisfy {
            $0.frame == NSRect(x: 0, y: 0, width: 437, height: bannerHeight)
                && $0.imageScaling == .scaleProportionallyUpOrDown && $0.toolTip == nil
        }, "Banners must use the full card width without distortion")
        precondition(cards[0].frame.minY == 91 && bodies(in: page).isEmpty)
        precondition(scroll.contentView.isFlipped && scroll.verticalScrollElasticity == .none)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -80))
        precondition(scroll.contentView.bounds.origin.y == 0, "Overscroll must not add space above the title")
        var proposed = scroll.contentView.bounds
        proposed.origin.y = -80
        precondition(scroll.contentView.constrainBoundsRect(proposed).origin.y == 0)
        proposed.origin.y = document.bounds.height + 500
        precondition(scroll.contentView.constrainBoundsRect(proposed).origin.y
            == max(0, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height + 500))
        precondition(scroll.contentView.bounds.maxY == document.bounds.maxY)
        scroll.contentView.scroll(to: .zero)
        let pageTitle = descendants(page).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "patch-notes-page-title" }!
        let notificationScroll = descendants(pages[2]).compactMap { $0 as? NSScrollView }.first!
        notificationScroll.contentView.scroll(to: .zero)
        let notificationTitle = descendants(notificationScroll.documentView!).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "알림" && $0.font?.pointSize == 18 }!
        precondition(pageTitle.convert(pageTitle.bounds, to: root).maxY
            == notificationTitle.convert(notificationTitle.bounds, to: root).maxY,
            "The page title must have the same top edge as Notifications")
        let resized = PatchNotesView(frame: NSRect(x: 0, y: 0, width: 469, height: 600),
                                    notes: [notes[0]], bannerImage: sharedBanner)
        resized.setFrameSize(NSSize(width: 400, height: 500))
        resized.layoutSubtreeIfNeeded()
        let resizedBanner = banners(in: resized).first!
        precondition(resizedBanner.frame.width == 368)
        precondition(resizedBanner.frame.height == ceil(368 * sharedBanner.size.height / sharedBanner.size.width))
        precondition(descendants(root).allSatisfy { $0.toolTip == nil })
        let collapsedHeight = document.frame.height
        let toggle = cards[0].subviews.compactMap { $0 as? NSButton }.first!
        let secondToggle = cards[1].subviews.compactMap { $0 as? NSButton }.first!
        precondition(cards.allSatisfy { card in
            card.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.title.isEmpty }
        }, "Disclosure headers must not draw NSButton's default title")
        let headerPoint = toggle.convert(NSPoint(x: 35, y: bannerHeight + 25), to: cards[0].superview)
        precondition(cards[0].hitTest(headerPoint) === toggle,
                     "Version text must belong to the whole disclosure hit target")
        let bannerPoint = images[0].convert(NSPoint(x: 200, y: 120), to: cards[0].superview)
        precondition(cards[0].hitTest(bannerPoint) === toggle, "Clicking the banner must also expand the release")

        for _ in 0..<100 {
            toggle.performClick(nil)
            root.layoutSubtreeIfNeeded()
            precondition(bodies(in: page).count == 1 && cards[0].frame.height > collapsedCardHeight)
            precondition(cards[1].frame.minY == cards[0].frame.maxY + 12)
            precondition(bodies(in: page).allSatisfy { $0.superview!.bounds.contains($0.frame) })
            toggle.performClick(nil)
            root.layoutSubtreeIfNeeded()
            precondition(bodies(in: page).isEmpty && cards[0].frame.height == collapsedCardHeight)
            precondition(document.frame.height == collapsedHeight, "Collapse must restore document height")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        toggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.origin.y == 180, "Expansion must not jump to the document top")
        secondToggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(bodies(in: page).count == 2, "Each version can expand independently")
        toggle.performClick(nil)
        precondition(bodies(in: page).count == 1)
        secondToggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(document.frame.height == collapsedHeight)
        scroll.contentView.scroll(to: .zero)
        for card in cards {
            let disclosure = card.subviews.compactMap { $0 as? NSButton }.first!
            disclosure.performClick(nil)
            root.layoutSubtreeIfNeeded()
            let body = bodies(in: card).first!
            let requiredSize = body.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                width: body.frame.width, height: .greatestFiniteMagnitude))
            precondition(body.frame.height >= requiredSize.height,
                         "The full release body must fit: \(card.identifier!.rawValue), \(body.frame.height) < \(requiredSize.height)")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
            disclosure.performClick(nil)
            root.layoutSubtreeIfNeeded()
            precondition(scroll.contentView.bounds.maxY <= document.bounds.maxY,
                         "Collapsing near the bottom must not leave blank scroll space")
        }
        scroll.contentView.scroll(to: .zero)

        for language in AppLanguage.allCases {
            var localized = arguments
            localized["appLanguage"] = language.rawValue
            standard.setVolatileDomain(localized, forName: UserDefaults.argumentDomain)
            controller.reloadLocalization()
            let section = descendants(page).compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "patch-notes-section-title" }!
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
            precondition(section.stringValue == L10n.text("패치노트 (현재 버전: %@)", "v" + version))
            let measured = (section.stringValue as NSString).size(withAttributes: [.font: section.font!])
            precondition(measured.width <= section.frame.width, "Section title must fit in both UI languages")
            for (note, card) in zip(notes, cards) {
                let fields = descendants(card).compactMap { $0 as? NSTextField }
                let title = fields.first { $0.identifier?.rawValue == "patch-note-title-\(note.version)" }!
                let summary = fields.first { $0.identifier?.rawValue == "patch-note-summary-\(note.version)" }!
                precondition(title.stringValue == L10n.text("PlusCodex %@ 패치노트", note.version))
                precondition((title.stringValue as NSString).size(withAttributes: [.font: title.font!]).width <= title.frame.width)
                precondition(summary.stringValue == note.summary?[language.rawValue])
                precondition(summary.maximumNumberOfLines == 2 && card.frame.height == collapsedCardHeight)
                let banner = banners(in: card).first!
                precondition(title.frame.minY == banner.frame.maxY + 13)
                precondition(summary.frame.minY == banner.frame.maxY + 37)
                // Measure without the two-line cap so truncated summaries cannot pass unnoticed.
                let uncapped = NSTextField(wrappingLabelWithString: summary.stringValue)
                uncapped.font = summary.font
                uncapped.maximumNumberOfLines = 0
                let required = uncapped.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                    width: summary.frame.width, height: .greatestFiniteMagnitude))
                precondition(required.height <= summary.frame.height,
                             "Summary must fit in two lines: \(language.rawValue) \(note.version), \(required.height)")
                let header = card.subviews.compactMap { $0 as? NSButton }.first!
                let summaryPoint = summary.convert(NSPoint(x: 20, y: 10), to: card.superview)
                precondition(card.hitTest(summaryPoint) === header, "The summary also toggles the disclosure")
                precondition(header.accessibilityLabel() == title.stringValue)
                precondition(header.accessibilityHelp()?.contains(summary.stringValue) == true)
            }
            let search = descendants(root).compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == L10n.text("설정 검색") }!
            search.stringValue = L10n.text("업데이트 내역")
            precondition(NSApp.sendAction(search.action!, to: search.target, from: search))
            let result = root.subviews.compactMap { $0 as? NSButton }
                .first { $0.tag == 3 && !$0.isHidden && $0.accessibilityLabel() == L10n.text("업데이트 내역") }!
            result.performClick(nil)
            precondition(page.superview?.isHidden == false)
            search.stringValue = ""
            _ = NSApp.sendAction(search.action!, to: search.target, from: search)
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: theme)
                controller.window!.appearance = NSAppearance(named: theme)
                root.layoutSubtreeIfNeeded()
                if CommandLine.arguments.contains("--render-patch-notes") {
                    try snapshot(root, path: "build/patch-notes-\(language.rawValue)-collapsed-\(theme.rawValue).png")
                }
                toggle.performClick(nil)
                root.layoutSubtreeIfNeeded()
                if CommandLine.arguments.contains("--render-patch-notes") {
                    try snapshot(root, path: "build/patch-notes-\(language.rawValue)-expanded-\(theme.rawValue).png")
                }
                precondition(descendants(root).allSatisfy { $0.toolTip == nil })
                toggle.performClick(nil)
                root.layoutSubtreeIfNeeded()
            }
        }
        print("PASS: 20 shared full-width banners with original aspect ratio, text-only fallback, localized titles/summaries, notification-aligned top spacing, bounded scrolling, independent disclosure, 100 expand/collapse cycles and theme previews")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private static func bodies(in view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }
            .filter { $0.identifier?.rawValue.hasPrefix("patch-note-body-") == true }
    }

    private static func banners(in view: NSView) -> [NSImageView] {
        descendants(view).compactMap { $0 as? NSImageView }
            .filter { $0.identifier?.rawValue.hasPrefix("patch-note-banner-") == true }
    }

    private static func snapshot(_ view: NSView, path: String) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
