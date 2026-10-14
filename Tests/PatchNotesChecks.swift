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
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        precondition(notes.count >= 21 && notes.first?.version == "v" + currentVersion
            && notes.last?.version == "v1.0.0")
        precondition(Set(notes.map(\.version)).count == notes.count)
        precondition(notes.allSatisfy { !$0.body.isEmpty && ISO8601DateFormatter().date(from: $0.publishedAt) != nil })
        precondition(notes.allSatisfy { note in
            AppLanguage.allCases.allSatisfy { language in
                note.summary?[language.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }, "Every release must have a concise summary in both UI languages")
        precondition(notes.allSatisfy { note in
            AppLanguage.allCases.allSatisfy { language in
                let lines = note.summary![language.rawValue]!.components(separatedBy: "\n")
                let highlights = note.highlights?[language.rawValue] ?? []
                return lines.count == 2 && lines.allSatisfy { $0.hasPrefix("• ") }
                    && !highlights.isEmpty && highlights.allSatisfy { !$0.isEmpty && !$0.contains("\n") }
                    && note.displayBody(for: language) == highlights.map { "- " + $0 }.joined(separator: "\n")
            }
        }, "All releases need two short summary bullets and localized detail items")
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
        precondition(legacy.highlights == nil && legacy.displayBody(for: .korean) == legacy.body,
                     "Older release resources keep their original body as a fallback")
        let legacyPage = PatchNotesView(frame: NSRect(x: 0, y: 0, width: 469, height: 600), notes: [legacy], bannerImage: nil)
        legacyPage.layoutSubtreeIfNeeded()
        let legacyCaption = descendants(legacyPage).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "patch-note-summary-v1.0.0" }!
        let legacyDate = ISO8601DateFormatter().date(from: legacy.publishedAt)!
        let legacyDateLabel = descendants(legacyPage).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "patch-note-date-v1.0.0" }!
        precondition(legacyCaption.stringValue.isEmpty)
        precondition(legacyDateLabel.stringValue == legacyDate.formatted(.dateTime.year().month().day().locale(L10n.locale)))
        let legacyCard = descendants(legacyPage).first { $0.identifier?.rawValue == "patch-note-v1.0.0" }!
        precondition(legacyCard.frame.height == 112 && banners(in: legacyPage).isEmpty,
                     "Missing banner resources must preserve a usable text-only card")
        precondition(legacyCaption.frame.minX == 16 && legacyDateLabel.frame.minX == 16)
        let invalidDate = try JSONDecoder().decode(PatchNote.self, from: Data(#"{"version":"v0.0.0","publishedAt":"invalid","url":"https://example.com","body":"Test"}"#.utf8))
        let invalidPage = PatchNotesView(frame: NSRect(x: 0, y: 0, width: 469, height: 600), notes: [invalidDate], bannerImage: nil)
        invalidPage.layoutSubtreeIfNeeded()
        precondition(descendants(invalidPage).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "patch-note-date-v0.0.0" }!.stringValue.isEmpty,
            "Invalid dates must not be replaced with today's date")

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
        let collapsedCardHeight: CGFloat = 112
        precondition(cards.allSatisfy { $0.frame.width == 437 && $0.frame.height == collapsedCardHeight })
        precondition(images.allSatisfy {
            $0.frame.width == 88 && $0.frame.height == $0.frame.width
                && $0.frame.minX == 12 && $0.frame.midY == collapsedCardHeight / 2
                && $0.imageScaling == .scaleProportionallyUpOrDown && $0.toolTip == nil
                && $0.layer?.cornerRadius == 8 && $0.layer?.masksToBounds == true
        }, "Square thumbnails must stay left-aligned and vertically centered")
        for (note, image) in zip(notes, images) {
            let overlay = image.subviews.first {
                $0.identifier?.rawValue == "patch-note-version-overlay-\(note.version)"
            }!
            let label = overlay.subviews.compactMap { $0 as? NSTextField }.first!
            precondition(label.stringValue == note.version && label.textColor == .white)
            precondition(label.alignment == .center && label.maximumNumberOfLines == 1)
            precondition(image.bounds.contains(overlay.frame) && overlay.bounds.contains(label.frame))
            precondition(overlay.frame.height == 22 && overlay.frame.width == image.bounds.width)
            precondition(overlay.frame.minY == (image.isFlipped ? image.bounds.height - 22 : 0))
            precondition(!overlay.frame.contains(NSPoint(x: image.bounds.midX, y: image.bounds.midY)),
                         "The version strip must not cover the central logo")
            let color = NSColor(cgColor: overlay.layer!.backgroundColor!)!.usingColorSpace(.deviceRGB)!
            precondition(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
            precondition(abs(color.alphaComponent - 0.6) < 0.001,
                         "The black strip must be translucent, not opaque")
            precondition((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width <= label.frame.width)
            let header = image.superview as! NSButton
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: header.superview!.superview)
            precondition(header.superview!.hitTest(point) === header,
                         "Clicking the overlaid version must still expand the card")
        }
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
        precondition(resizedBanner.frame.width == 88 && resizedBanner.frame.height == 88)
        precondition(resizedBanner.superview!.bounds.contains(resizedBanner.frame))
        let resizedFields = descendants(resized).compactMap { $0 as? NSTextField }
            .filter { $0.identifier?.rawValue.hasPrefix("patch-note-") == true }
        precondition(resizedFields.allSatisfy { $0.superview!.bounds.contains($0.frame) })
        precondition(descendants(root).allSatisfy { $0.toolTip == nil })
        let collapsedHeight = document.frame.height
        let toggle = cards[0].subviews.compactMap { $0 as? NSButton }.first!
        let secondToggle = cards[1].subviews.compactMap { $0 as? NSButton }.first!
        precondition(cards.allSatisfy { card in
            card.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.title.isEmpty }
        }, "Disclosure headers must not draw NSButton's default title")
        let headerPoint = toggle.convert(NSPoint(x: 180, y: 25), to: cards[0].superview)
        precondition(cards[0].hitTest(headerPoint) === toggle,
                     "Version text must belong to the whole disclosure hit target")
        let bannerPoint = images[0].convert(NSPoint(x: images[0].bounds.midX, y: images[0].bounds.midY), to: cards[0].superview)
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
        toggle.performClick(nil)
        var englishArguments = koreanArguments
        englishArguments["appLanguage"] = "en"
        standard.setVolatileDomain(englishArguments, forName: UserDefaults.argumentDomain)
        controller.reloadLocalization()
        root.layoutSubtreeIfNeeded()
        precondition(bodies(in: cards[0]).first!.stringValue
            == notes[0].highlights!["en"]!.map { "• " + $0 }.joined(separator: "\n"),
            "Already expanded details must switch to English immediately")
        standard.setVolatileDomain(koreanArguments, forName: UserDefaults.argumentDomain)
        controller.reloadLocalization()
        root.layoutSubtreeIfNeeded()
        precondition(bodies(in: cards[0]).first!.stringValue
            == notes[0].highlights!["ko"]!.map { "• " + $0 }.joined(separator: "\n"),
            "Switching back must replace English details with Korean")
        toggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        toggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.origin.y == 180, "Expansion must not jump to the document top")
        secondToggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(bodies(in: page).count == 1 && bodies(in: cards[0]).isEmpty,
                     "Opening another version must close the previous version")
        precondition(bodies(in: cards[1]).count == 1)
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
            precondition(body.frame.height == ceil(requiredSize.height), "Do not reserve an extra blank line")
            precondition(card.bounds.maxY - body.frame.maxY == 16, "Keep a consistent 16pt bottom inset")
            precondition(!body.stringValue.hasSuffix("\n"), "The last bullet must not create an empty paragraph")
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
                let date = fields.first { $0.identifier?.rawValue == "patch-note-date-\(note.version)" }!
                precondition(title.stringValue == L10n.text("PlusCodex %@ 패치노트", note.version))
                precondition((title.stringValue as NSString).size(withAttributes: [.font: title.font!]).width <= title.frame.width)
                precondition(summary.stringValue == note.summary?[language.rawValue])
                precondition(summary.maximumNumberOfLines == 2 && card.frame.height == collapsedCardHeight)
                let banner = banners(in: card).first!
                precondition(title.frame.minX == banner.frame.maxX + 14 && title.frame.minY == 13)
                precondition(summary.frame.minX == title.frame.minX && summary.frame.minY == 38)
                precondition(date.frame.minX == title.frame.minX && date.frame.minY > summary.frame.maxY)
                precondition(summary.cell?.truncatesLastVisibleLine == true,
                             "Long summaries must use an explicit two-line ellipsis, not overlap the date")
                let uncapped = NSTextField(wrappingLabelWithString: summary.stringValue)
                uncapped.font = summary.font
                let required = uncapped.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                    width: summary.frame.width, height: .greatestFiniteMagnitude))
                precondition(required.height <= summary.frame.height,
                             "Both bullet items must fit: \(language.rawValue) \(note.version)")
                let published = ISO8601DateFormatter().date(from: note.publishedAt)!
                precondition(date.stringValue == published.formatted(.dateTime.year().month().day().locale(L10n.locale)))
                precondition(date.textColor == .tertiaryLabelColor)
                precondition((date.stringValue as NSString).size(withAttributes: [.font: date.font!]).width <= date.frame.width)
                let header = card.subviews.compactMap { $0 as? NSButton }.first!
                let summaryPoint = summary.convert(NSPoint(x: 20, y: 10), to: card.superview)
                precondition(card.hitTest(summaryPoint) === header, "The summary also toggles the disclosure")
                precondition(header.accessibilityLabel() == title.stringValue)
                precondition(header.accessibilityHelp()?.contains(summary.stringValue) == true)
                precondition(header.accessibilityHelp()?.contains(date.stringValue) == true)
                let datePoint = date.convert(NSPoint(x: 20, y: 8), to: card.superview)
                precondition(card.hitTest(datePoint) === header, "The date also toggles the disclosure")
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
                for (note, card) in zip(notes, cards) {
                    let disclosure = card.subviews.compactMap { $0 as? NSButton }.first!
                    disclosure.performClick(nil)
                    root.layoutSubtreeIfNeeded()
                    precondition(bodies(in: page).count == 1)
                    let body = bodies(in: card).first!
                    precondition(body.stringValue == note.highlights![language.rawValue]!
                        .map { "• " + $0 }.joined(separator: "\n"),
                        "Details must contain only the selected language's bullet items")
                    let measured = body.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                        width: body.frame.width, height: .greatestFiniteMagnitude))
                    precondition(body.frame.height == ceil(measured.height))
                    precondition(card.bounds.maxY - body.frame.maxY == 16)
                    let lastParagraph = body.attributedStringValue.attribute(.paragraphStyle,
                        at: body.attributedStringValue.length - 1, effectiveRange: nil) as! NSParagraphStyle
                    precondition(lastParagraph.paragraphSpacing == 0,
                                 "Final bullet must not add unused paragraph spacing")
                    disclosure.performClick(nil)
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
        checkAnimatedDisclosure(notes: Array(notes.prefix(3)), image: sharedBanner)
        print("PASS: version overlays, single-open accordion, animated transitions and rapid clicks, localized bullet notes, bounded spacing/scrolling, 100 disclosure cycles and theme previews")
    }

    private static func checkAnimatedDisclosure(notes: [PatchNote], image: NSImage) {
        let page = PatchNotesView(frame: NSRect(x: 0, y: 0, width: 469, height: 600),
                                 notes: notes, bannerImage: image)
        let window = NSWindow(contentRect: page.bounds, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PlusCodex patch-note animation test"
        window.contentView = page
        window.orderFront(nil)
        defer { window.close() }
        page.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        pumpRunLoop(for: 0.05)
        let cards = descendants(page).filter {
            $0.identifier?.rawValue.hasPrefix("patch-note-v") == true && $0.subviews.contains { $0 is NSButton }
        }
            .sorted { $0.frame.minY < $1.frame.minY }
        let toggles = cards.map { $0.subviews.compactMap { $0 as? NSButton }.first! }
        toggles[0].performClick(nil)
        pumpRunLoop(for: 0.12)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let height = cards[0].layer?.presentation()?.bounds.height ?? cards[0].bounds.height
            let body = bodies(in: cards[0]).first!
            let measured = body.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                width: cards[0].bounds.width - 32, height: .greatestFiniteMagnitude))
            let finalHeight = 112 + 32 + ceil(measured.height)
            precondition(height > 112 && height < finalHeight,
                         "The visible card must interpolate its height rather than jump")
        }
        pumpRunLoop(for: 0.25)
        precondition(bodies(in: page).count == 1 && bodies(in: cards[0]).first!.alphaValue == 1)
        let standard = UserDefaults.standard
        let originalArguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for language in AppLanguage.allCases {
            var arguments = originalArguments
            arguments["appLanguage"] = language.rawValue
            standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            page.reloadLocalization()
            page.layoutSubtreeIfNeeded()
            let selectedBody = bodies(in: cards[0]).first!
            let originalText = NSAttributedString(attributedString: selectedBody.attributedStringValue)
            let originalFrame = selectedBody.frame
            for _ in 0..<3 {
                selectedBody.selectText(nil)
                pumpRunLoop(for: 0.05)
                let editor = window.firstResponder as! NSTextView
                precondition(editor.isSelectable && !editor.isEditable)
                precondition(selectedBody.frame == originalFrame)
                checkSelectionAttributes(original: originalText, selected: editor.attributedString())
                if CommandLine.arguments.contains("--render-patch-notes") {
                    try! snapshot(page, path: "build/patch-notes-\(language.rawValue)-selected.png")
                }
                window.makeFirstResponder(nil)
                checkSelectionAttributes(original: originalText, selected: selectedBody.attributedStringValue)
            }
        }
        toggles[1].performClick(nil)
        pumpRunLoop(for: 0.37)
        precondition(bodies(in: cards[0]).isEmpty && bodies(in: cards[1]).count == 1)
        for index in 0..<24 {
            toggles[index % toggles.count].performClick(nil)
            pumpRunLoop(for: 0.01)
        }
        pumpRunLoop(for: 0.4)
        precondition(bodies(in: page).count == 1 && bodies(in: cards[2]).count == 1,
                     "Rapid retargeting must retain only the latest opened release")
        precondition(cards[0].frame.height == 112 && cards[1].frame.height == 112)
        toggles[2].performClick(nil)
        pumpRunLoop(for: 0.4)
        precondition(bodies(in: page).isEmpty && cards.allSatisfy { $0.frame.height == 112 })
    }

    private static func checkSelectionAttributes(original: NSAttributedString, selected: NSAttributedString) {
        precondition(original.string == selected.string)
        original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attributes, range, _ in
            let actual = selected.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as! NSFont
            let actualFont = actual[.font] as! NSFont
            let paragraph = attributes[.paragraphStyle] as! NSParagraphStyle
            let actualParagraph = actual[.paragraphStyle] as! NSParagraphStyle
            precondition(font.pointSize == actualFont.pointSize && font.fontName == actualFont.fontName,
                         "Clicking/selecting must not enlarge or replace the body font")
            precondition(paragraph.lineSpacing == actualParagraph.lineSpacing
                && paragraph.paragraphSpacing == actualParagraph.paragraphSpacing,
                "Clicking/selecting must preserve bullet spacing")
        }
    }

    private static func pumpRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
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
