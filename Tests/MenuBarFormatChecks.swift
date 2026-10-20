import AppKit

@main struct MenuBarFormatChecks {
    static func main() {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let five = QuotaWindow(usedPercent: 22, windowDurationMins: 300, resetsAt: now.timeIntervalSince1970 + 9000)
        let week = QuotaWindow(usedPercent: 39, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970 + 194400)
        let quota = Quota(primary: five, secondary: week)
        func render(_ format: String, _ value: Quota? = nil, remaining: Bool = true) -> String {
            MenuBarFormat.render(format, quota: value ?? quota, showRemaining: remaining, now: now, language: .english)
        }
        precondition(render("{auto}%") == "78%")
        precondition(render("{5h}% | {1w}%") == "78% | 61%")
        precondition(render("{auto}% | {auto_time}") == "78% | 2h 30m")
        precondition(render("{1w_time}") == "2d 6h")
        precondition(render("5h {5h}%ㅣ1w {1w}%") == "5h 78%ㅣ1w 61%")
        precondition(render("{1}% | {2}% | {3}%") == "78% | 61% | —%")
        precondition(render("{auto}%", remaining: false) == "22%")
        precondition(render("{5h}% | {1w}%", remaining: false) == "22% | 39%")
        precondition(render("{1}% | {2_time}", remaining: false) == "22% | 2d 6h")
        for base in ["auto", "5h", "1w", "argon", "1", "20"] {
            for suffix in ["used", "remaining"] {
                precondition(!MenuBarFormat.isValid("{\(base)_\(suffix)}%"),
                             "Forced usage tokens are removed, not kept as hidden compatibility")
            }
        }
        precondition(render("{5h_used}%") == "78%", "Removed formats follow the existing invalid-format fallback")
        precondition(render("").isEmpty && render("custom text") == "custom text")
        precondition(MenuBarFormat.render("{auto}%", quota: nil) == "…%")
        let weekly = Quota(primary: nil, secondary: week)
        precondition(render("{auto}% | {auto_time}", weekly) == "61% | 2d 6h")
        precondition(render("{5h}%", weekly) == "—%", "Explicit 5h must never silently relabel weekly")
        precondition(render("{auto}%", Quota(primary: week, secondary: five)) == "78%")
        precondition(render("{auto}%", quota.effectiveQuota(account: CodexAccount(email: nil, planType: "pro"))) == "61%")
        let monthly = Quota(primary: QuotaWindow(usedPercent: 10, windowDurationMins: 43200, resetsAt: nil), secondary: nil)
        precondition(render("{auto}% | {auto_time}", monthly) == "90% | —")
        precondition(render("{auto}%", Quota(primary: nil, secondary: nil)) == "—%")
        for reset in [now.timeIntervalSince1970 - 100, now.timeIntervalSince1970] {
            let expired = Quota(primary: QuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: reset), secondary: nil)
            precondition(render("{auto_time}", expired) == "0m")
        }
        precondition(MenuBarFormat.render("{auto_time}", quota: quota, now: now, language: .korean) == "2시간 30분")
        let weeklyHelp = MenuBarFormat.helpText(provider: .codex, quota: weekly)
        precondition(weeklyHelp.contains("{1w}%") && weeklyHelp.contains("{1w_time}") && !weeklyHelp.contains("{5h}"),
                     "Help must reflect the actual plan, not invent a five-hour limit")
        let monthlyHelp = MenuBarFormat.helpText(provider: .grok, quota: monthly)
        precondition(monthlyHelp.contains("{1}%") && !monthlyHelp.contains("{5h}") && !monthlyHelp.contains("{1w}"))
        precondition(!monthlyHelp.contains("{auto_time}"), "Do not recommend reset tokens without a reset timestamp")
        precondition(MenuBarFormat.presets(quota: nil) == ["{auto}%"])
        precondition(MenuBarFormat.presets(quota: monthly) == ["{auto}%"])
        precondition(!MenuBarFormat.presets(quota: weekly).contains("{5h}% | {1w}%"))
        precondition(MenuBarFormat.presets(quota: quota).contains("{5h}% | {1w}%"))
        for value in ["{typo}", "{5h", "5h}", "{{5h}}", "{0}", "{21}", "{01}", "{5h_reset}",
                      "abc\ndef", "tab\t", String(repeating: "x", count: 81)] {
            precondition(!MenuBarFormat.isValid(value), "Must reject malformed or unsupported format")
        }
        precondition(MenuBarFormat.isValid(String(repeating: "x", count: 80)))
        precondition(render("{typo}") == "78%", "Corrupt persisted formats must fall back safely")
        let invalid = Quota(primary: QuotaWindow(usedPercent: .nan, windowDurationMins: 300, resetsAt: .infinity), secondary: nil)
        precondition(render("{auto}% | {auto_time}", invalid) == "—% | —")

        let argon = QuotaWindow(usedPercent: 75, windowDurationMins: 10080,
            resetsAt: now.timeIntervalSince1970 + 3600, customLabel: "Argon 주간")
        let gemini = Quota(primary: five, secondary: week, additional: [argon])
        precondition(render("{argon}% | {argon_time}", gemini) == "25% | 1h 0m")
        precondition(render("{argon}%", gemini, remaining: false) == "75%")
        precondition(render("{3}% | {3_time}", gemini) == "25% | 1h 0m", "Legacy numbered tokens must stay compatible")
        let reordered = Quota(primary: argon, secondary: five, additional: [week])
        precondition(render("{argon}% | {argon_time}", reordered) == "25% | 1h 0m",
                     "Argon must be selected by name, not position")
        let dailyArgon = QuotaWindow(usedPercent: 10, windowDurationMins: 1440, resetsAt: nil, customLabel: "Argon daily")
        precondition(render("{argon}%", Quota(primary: dailyArgon, secondary: argon)) == "25%",
                     "Prefer the weekly Argon bucket when several periods exist")
        precondition(render("{argon}%", Quota(primary: dailyArgon, secondary: nil)) == "90%")
        precondition(render("{argon}%") == "—%", "Do not substitute another weekly limit for missing Argon")
        let similarName = Quota(primary: QuotaWindow(usedPercent: 5, windowDurationMins: 10080,
            resetsAt: nil, customLabel: "Argonish"), secondary: nil)
        precondition(render("{argon}%", similarName) == "—%", "Require a full model name, not a substring")
        let sections = MenuBarFormat.helpSections(quota: gemini)
        precondition(sections[0].entries.map(\.token) == ["{auto}%", "{5h}%", "{1w}%", "{argon}%"])
        precondition(sections[1].entries.contains { $0.token == "{argon_time}" })
        precondition(sections.count == 2 && sections.map(\.title) == [L10n.text("기본 토큰"), L10n.text("초기화 시간")],
                     "Only basic percentages and reset times belong in the help")
        let accessibleHelp = MenuBarFormat.helpText(provider: .gemini, quota: gemini)
        precondition(!accessibleHelp.contains("_used") && !accessibleHelp.contains("_remaining"),
                     "Do not advertise removed tokens in accessible help either")
        precondition(sections.flatMap(\.entries).allSatisfy { !$0.detail.contains("·") },
                     "Token descriptions must use plain limit labels without dot separators")
        precondition(sections[0].entries[0].detail == L10n.text("%@ 사용량", five.label))
        precondition(MenuBarFormat.presets(quota: gemini).contains("{5h}% | {1w}% | {argon}%"))
        precondition(MenuBarFormat.helpSections(quota: nil).flatMap(\.entries).map(\.token) == ["{auto}%"])

        let suite = "PlusCodex.MenuBarFormatChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProviderSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }
        for provider in AIProvider.allCases { precondition(settings.menuBarFormat(provider) == "{auto}%") }
        precondition(settings.setMenuBarFormat("{1w}% | {1w_time}", for: .gemini))
        precondition(changes == 1 && settings.menuBarFormat(.codex) == "{auto}%")
        precondition(!settings.setMenuBarFormat("{bad}", for: .gemini) && changes == 1)
        precondition(!settings.setMenuBarFormat("{auto_used}%", for: .gemini) && changes == 1)
        precondition(!settings.setMenuBarFormat("{auto_remaining}%", for: .gemini) && changes == 1)
        precondition(ProviderSettings(defaults: defaults).menuBarFormat(.gemini) == "{1w}% | {1w_time}")
        precondition(settings.setMenuBarFormat("", for: .grok) && settings.menuBarFormat(.grok).isEmpty)
        defaults.set("{bad}", forKey: "provider.claude.menuBarFormat")
        precondition(settings.menuBarFormat(.claude) == "{auto}%")
        defaults.set("{auto_remaining}%", forKey: "provider.claude.menuBarFormat")
        precondition(settings.menuBarFormat(.claude) == "{auto}%", "Stored removed tokens must not keep operating")

        let view = MenuBarFormatSettingsView(frame: NSRect(x: 0, y: 0, width: 437,
            height: MenuBarFormatSettingsView.preferredHeight), settings: settings)
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        var copied: [String] = []
        let help = MenuBarTokenHelpView(quota: gemini, copy: { copied.append($0); return true })
        let helpViews = descendants(help.view)
        let copyRows = helpViews.compactMap { $0 as? NSButton }
        precondition(copyRows.count == sections.flatMap(\.entries).count)
        let argonRow = copyRows.first { $0.identifier?.rawValue == "menuBarToken-copy-{argon}%" }!
        precondition(argonRow.sendAction(argonRow.action, to: argonRow.target))
        precondition(copied == ["{argon}%"] && argonRow.accessibilityValue() as? String == L10n.text("복사됨"))
        let timeRow = copyRows.first { $0.identifier?.rawValue == "menuBarToken-copy-{argon_time}" }!
        precondition(timeRow.sendAction(timeRow.action, to: timeRow.target))
        precondition(copied == ["{argon}%", "{argon_time}"])
        precondition(argonRow.hitTest(NSPoint(x: argonRow.frame.midX, y: argonRow.frame.midY)) === argonRow,
                     "The token, explanation and copy icon must share one click target")
        let scroll = help.view as! NSScrollView
        precondition(scroll.frame.size == NSSize(width: 280, height: 210)
                     && scroll.documentView!.frame.height > scroll.frame.height,
                     "A long reference must scroll instead of overflowing the screen")
        precondition(copyRows.allSatisfy { (24...40).contains($0.frame.height) },
                     "Keep rows compact while allowing long translations to wrap")
        for row in copyRows {
            let labels = row.subviews.compactMap { $0 as? NSTextField }
            precondition(labels.allSatisfy { $0.lineBreakMode == .byWordWrapping },
                         "Narrow descriptions must wrap instead of truncating")
        }
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        var contentHoverEvents: [Bool] = []
        help.onHoverChanged = { contentHoverEvents.append($0) }
        let hoverContent = scroll as! MenuBarTokenHelpScrollView
        hoverContent.updateTrackingAreas()
        hoverContent.updateTrackingAreas()
        precondition(hoverContent.trackingAreas.filter { $0.options.contains(.activeAlways) }.count == 1,
                     "Updating tracking areas must not duplicate hover callbacks")
        hoverContent.mouseEntered(with: entered)
        hoverContent.mouseExited(with: exited)
        precondition(contentHoverEvents == [true, false], "The popover must report pointer entry/exit for copy access")
        func highlightedRows() -> [NSButton] {
            copyRows.filter { ($0.layer?.backgroundColor?.alpha ?? 0) > 0 }
        }
        let firstRow = copyRows[0]
        let secondRow = copyRows[1]
        let pointer = NSPoint(x: firstRow.frame.midX, y: firstRow.frame.midY)
        hoverContent.updateRowHover(atDocumentPoint: pointer)
        precondition(highlightedRows().count == 1 && highlightedRows().first === firstRow)
        hoverContent.updateRowHover(atDocumentPoint: NSPoint(x: secondRow.frame.midX, y: secondRow.frame.midY))
        precondition(highlightedRows().count == 1 && highlightedRows().first === secondRow,
                     "Entering another row must clear the old highlight without a mouseExited event")
        // Simulate scroll offsets with a stationary pointer in the clip view.
        for offset: CGFloat in [28, 56, 112, 224, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            precondition(highlightedRows().isEmpty,
                         "A bounds-change notification must clear stale hover even without mouse movement")
            let position = NSPoint(x: pointer.x, y: pointer.y + scroll.contentView.bounds.minY)
            hoverContent.updateRowHover(atDocumentPoint: position)
            let expected = copyRows.first {
                $0.frame.contains(position) && scroll.documentView!.visibleRect.contains(position)
            }
            precondition(highlightedRows().count == (expected == nil ? 0 : 1))
            if let expected { precondition(highlightedRows().first === expected) }
        }
        hoverContent.updateRowHover(atDocumentPoint: NSPoint(x: 0, y: pointer.y))
        precondition(highlightedRows().isEmpty, "Section padding must not leave a row highlighted")
        hoverContent.updateRowHover(atDocumentPoint: NSPoint(x: argonRow.frame.midX, y: argonRow.frame.midY + 10000))
        precondition(highlightedRows().isEmpty, "Offscreen rows must not become hovered")
        hoverContent.updateRowHover(atDocumentPoint: pointer)
        hoverContent.mouseExited(with: exited)
        precondition(highlightedRows().isEmpty, "Leaving the popover must clear all row highlights")
        let hoverButton = MenuBarTokenHelpButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var buttonHoverEvents: [Bool] = []
        hoverButton.onHoverChanged = { buttonHoverEvents.append($0) }
        hoverButton.updateTrackingAreas()
        hoverButton.updateTrackingAreas()
        precondition(hoverButton.trackingAreas.filter { $0.options.contains(.activeAlways) }.count == 1)
        hoverButton.mouseEntered(with: entered)
        hoverButton.mouseExited(with: exited)
        precondition(buttonHoverEvents == [true, false], "Help must trigger from hover without a click")
        for item in helpViews where !(item is NSClipView) && !(item is NSScroller) {
            if let parent = item.superview, parent !== scroll, item !== scroll.documentView {
                precondition(parent.bounds.contains(item.frame), "Token help layout outside parent")
            }
        }
        let all = descendants(view)
        func visibleFields() -> [NSTextField] {
            all.compactMap { $0 as? NSTextField }.filter {
                $0.isEditable && $0.identifier?.rawValue.hasPrefix("menuBarFormat-") == true && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        precondition(visibleFields().map { $0.identifier!.rawValue } == ["menuBarFormat-codex"])
        precondition(view.frame.height == 144, "One enabled provider must occupy one compact row plus title")
        precondition(!all.compactMap({ $0 as? NSTextField }).contains {
            $0.stringValue.contains("이름 옆 ?") || $0.stringValue.contains("Hover over ?")
        }, "The small subtitle must be removed")
        settings.setEnabled(true, for: .gemini)
        view.synchronize()
        precondition(visibleFields().count == 2 && view.frame.height == 252)
        precondition(settings.menuBarFormat(.gemini) == "{1w}% | {1w_time}")
        let geminiField = visibleFields().first { $0.identifier?.rawValue == "menuBarFormat-gemini" }!
        precondition(geminiField.superview!.frame.minY == 0,
                     "Disabled middle providers must not leave gaps")
        settings.setEnabled(false, for: .codex)
        view.synchronize()
        precondition(visibleFields().map { $0.identifier!.rawValue } == ["menuBarFormat-gemini"])
        settings.setEnabled(false, for: .gemini)
        view.synchronize()
        precondition(view.isHidden && view.frame.height == 0 && visibleFields().isEmpty)
        settings.setEnabled(true, for: .gemini)
        view.synchronize()
        precondition(!view.isHidden && visibleFields().first?.stringValue == "{1w}% | {1w_time}",
                     "Re-enabling a provider must restore its saved format")
        view.synchronize(enabledProviders: [])
        precondition(view.isHidden, "The editor must follow actual toggle states, including unavailable providers")
        for provider in AIProvider.allCases { settings.setEnabled(true, for: provider) }
        view.synchronize()
        precondition(visibleFields().count == 4 && view.frame.height == MenuBarFormatSettingsView.preferredHeight)
        let helpButtons = all.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("menuBarFormat-help-") == true }
        precondition(helpButtons.count == 4 && helpButtons.allSatisfy {
            $0 is MenuBarTokenHelpButton && $0.toolTip == nil && $0.accessibilityHelp()?.isEmpty == false
        }, "Use hover help, not a second native tooltip; retain the accessible description")
        precondition(all.filter { $0.identifier?.rawValue.hasPrefix("menuBarFormat-icon-") == true }.count == 4)
        for provider in AIProvider.allCases {
            let icon = all.first { $0.identifier?.rawValue == "menuBarFormat-icon-\(provider.rawValue)" }!
            let name = all.first { $0.identifier?.rawValue == "menuBarFormat-name-\(provider.rawValue)" } as! NSTextField
            let help = helpButtons.first { $0.identifier?.rawValue == "menuBarFormat-help-\(provider.rawValue)" }!
            precondition(icon.frame.midY == help.frame.midY && name.frame.midY == icon.frame.midY + 1,
                         "Keep symbols centered and optically lift the name by 1pt")
            precondition(icon.frame.size == NSSize(width: 22, height: 22) && icon.frame.midX == 25,
                         "Enlarge the provider icon without shifting its center")
            precondition(help.image?.size == NSSize(width: 12, height: 12)
                         && help.frame.size == NSSize(width: 16, height: 16) && help.imageScaling == .scaleNone,
                         "Shrink only the help glyph, preserving its existing click target")
            precondition(name.frame.height == name.intrinsicContentSize.height,
                         "The name must use its natural font height, not an oversized fixed frame")
            precondition(icon.frame.maxX < name.frame.minX && name.frame.maxX < help.frame.minX)
            let input = all.first { $0.identifier?.rawValue == "menuBarFormat-\(provider.rawValue)" }!
            let presets = all.first { $0.identifier?.rawValue == "menuBarFormat-presets-\(provider.rawValue)" }!
            precondition(icon.frame.minY - input.frame.maxY == 10,
                         "Leave a 10pt gap between the larger icon and the input")
            precondition(input.frame.minY == presets.frame.minY,
                         "Move the preset picker together with the input")
        }
        let field = all.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "menuBarFormat-codex" }!
        field.stringValue = "{5h}% | {5h_time}"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        precondition(settings.menuBarFormat(.codex) == field.stringValue)
        field.stringValue = "{oops}"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        precondition(settings.menuBarFormat(.codex) == "{5h}% | {5h_time}")
        precondition(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L10n.text("지원 토큰·괄호·80자 제한을 확인하세요. 저장되지 않았습니다.") })
        let reset = all.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "menuBarFormat-reset-codex" }!
        _ = reset.sendAction(reset.action, to: reset.target)
        precondition(field.stringValue == "{auto}%" && settings.menuBarFormat(.codex) == "{auto}%")
        let picker = all.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "menuBarFormat-presets-codex" }!
        view.updateQuota(quota, provider: .codex)
        picker.selectItem(at: 3)
        _ = picker.sendAction(picker.action, to: picker.target)
        precondition(settings.menuBarFormat(.codex) == "{auto}% | {auto_time}")
        view.updateQuota(weekly, provider: .codex)
        let codexHelp = helpButtons.first { $0.identifier?.rawValue == "menuBarFormat-help-codex" }!
        precondition(codexHelp.accessibilityHelp()?.contains("{1w}%") == true
                     && codexHelp.accessibilityHelp()?.contains("{5h}") == false && codexHelp.toolTip == nil)
        precondition(picker.itemTitles == [L10n.text("빠른 선택")] + MenuBarFormat.presets(quota: weekly))
        precondition(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix(L10n.text("미리보기: %@", "61%")) })
        for item in all {
            if let parent = item.superview { precondition(parent.bounds.contains(item.frame), "Editor layout outside parent") }
        }
        let editWindow = SettingsTextEditingWindow(contentRect: view.frame,
            styleMask: .borderless, backing: .buffered, defer: false)
        editWindow.contentView = view
        let initialFormat = settings.menuBarFormat(.codex)
        field.selectText(nil)
        let nativeEditor = field.currentEditor() as! NSTextView
        precondition(nativeEditor.allowsUndo && nativeEditor.isFieldEditor)
        let undoManager = nativeEditor.undoManager!
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        nativeEditor.setSelectedRange(NSRange(location: (nativeEditor.string as NSString).length, length: 0))
        nativeEditor.breakUndoCoalescing()
        undoManager.beginUndoGrouping()
        nativeEditor.insertText(" test", replacementRange: nativeEditor.selectedRange())
        undoManager.endUndoGrouping()
        nativeEditor.breakUndoCoalescing()
        precondition(settings.menuBarFormat(.codex) == initialFormat + " test")
        func undoKey(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: editWindow.windowNumber, context: nil, characters: "z",
                charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        }
        precondition(editWindow.performKeyEquivalent(with: undoKey(.command)))
        precondition(nativeEditor.string == initialFormat,
                     "Undo editor mismatch: expected \(initialFormat), actual \(nativeEditor.string)")
        precondition(settings.menuBarFormat(.codex) == initialFormat,
                     "Undo saved format mismatch: expected \(initialFormat), actual \(settings.menuBarFormat(.codex))")
        precondition(editWindow.performKeyEquivalent(with: undoKey([.command, .shift])))
        precondition(nativeEditor.string == initialFormat + " test"
                     && settings.menuBarFormat(.codex) == initialFormat + " test",
                     "Redo must update the saved format through the normal edit delegate")
        let otherFormat = settings.menuBarFormat(.gemini)
        geminiField.selectText(nil)
        let otherEditor = geminiField.currentEditor() as! NSTextView
        precondition(otherEditor.undoManager?.canUndo == false,
                     "A new input field must not inherit another field's typing history")
        precondition(editWindow.performKeyEquivalent(with: undoKey(.command)))
        precondition(otherEditor.string == otherFormat && settings.menuBarFormat(.gemini) == otherFormat)
        precondition(settings.menuBarFormat(.codex) == initialFormat + " test")
        field.selectText(nil)
        precondition((field.currentEditor() as! NSTextView).undoManager?.canUndo == false,
                     "Re-entering an input starts a fresh native editing session")
        editWindow.makeFirstResponder(nil)
        print("PASS: enabled providers only, compacted rows, removed subtitle, empty section, preserved formats and toggle-state visibility")
        print("PASS: named Argon tokens, reordered/additional limits, legacy compatibility, grouped token help, copy actions and bounded scrolling")
        print("PASS: compact 280x210 hover help, adaptive 24pt rows, wrapped descriptions, pointer tracking and no duplicate native tooltip")
        print("PASS: exclusive row highlight, stationary-pointer scrolling, bounds-change cleanup, padding/offscreen and pointer exit")
        print("PASS: real menu-format field editor undo/redo and saved-format synchronization")
        print("PASS: undo history cannot leak across provider fields or editing sessions")
        print("PASS: auto fallback, independent formats, custom tokens, countdowns, missing/invalid values, validation, persistence, live editing, presets, reset and preview layout")
    }
}
