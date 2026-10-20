import AppKit

private final class IsolatedClipboardEditor: NSTextView {
    let clipboard = NSPasteboard.withUniqueName()
    var copyCount = 0
    var pasteCount = 0

    override func copy(_ sender: Any?) {
        copyCount += 1
        clipboard.clearContents()
        let selection = (string as NSString).substring(with: selectedRange())
        precondition(clipboard.setString(selection, forType: .string))
    }

    override func paste(_ sender: Any?) {
        pasteCount += 1
        guard let value = clipboard.string(forType: .string) else { preconditionFailure("Missing test clipboard text") }
        insertText(value, replacementRange: selectedRange())
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }
}

@main struct SettingsTextEditingChecks {
    static func main() {
        _ = NSApplication.shared
        let window = SettingsTextEditingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: .borderless, backing: .buffered, defer: false)
        let editor = IsolatedClipboardEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        editor.isFieldEditor = true
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        window.contentView = editor
        precondition(window.makeFirstResponder(editor))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        precondition((window.fieldEditor(true, for: field) as? NSTextView)?.allowsUndo == true,
                     "Native settings field editors must record undo history")
        func key(_ character: String, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
        }
        editor.string = "{5h}% | {1w}%"
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        precondition(window.performKeyEquivalent(with: key("c")))
        precondition(editor.clipboard.string(forType: .string) == "{5h}%" && editor.copyCount == 1)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        precondition(window.performKeyEquivalent(with: key("v")))
        precondition(editor.string == "{5h}% | {1w}%{5h}%" && editor.pasteCount == 1)
        precondition(window.performKeyEquivalent(with: key("a")))
        precondition(editor.selectedRange().length == (editor.string as NSString).length)
        precondition(window.performKeyEquivalent(with: key("x")) && editor.string.isEmpty)
        precondition(window.performKeyEquivalent(with: key("v")))
        precondition(editor.string == "{5h}% | {1w}%{5h}%")
        let count = editor.pasteCount
        _ = window.performKeyEquivalent(with: key("v", flags: [.command, .option]))
        _ = window.performKeyEquivalent(with: key("v", flags: [.command, .shift]))
        _ = window.performKeyEquivalent(with: key("v", flags: []))
        precondition(editor.pasteCount == count, "Unrelated modifier combinations must not be consumed")

        let manager = editor.undoManager!
        manager.removeAllActions()
        manager.groupsByEvent = false
        editor.string = "{auto}%"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        func edit(_ action: () -> Void) {
            editor.breakUndoCoalescing()
            manager.beginUndoGrouping()
            action()
            manager.endUndoGrouping()
            editor.breakUndoCoalescing()
        }
        edit { editor.insertText(" | {auto_time}", replacementRange: editor.selectedRange()) }
        precondition(editor.string == "{auto}% | {auto_time}" && manager.canUndo)
        precondition(window.performKeyEquivalent(with: key("z")) && editor.string == "{auto}%")
        precondition(window.performKeyEquivalent(with: key("z", flags: [.command, .shift]))
                     && editor.string == "{auto}% | {auto_time}")

        editor.clipboard.clearContents()
        precondition(editor.clipboard.setString("{1w}%", forType: .string))
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        edit { precondition(window.performKeyEquivalent(with: key("v"))) }
        precondition(editor.string == "{1w}%")
        precondition(window.performKeyEquivalent(with: key("z")) && editor.string == "{auto}% | {auto_time}")
        precondition(window.performKeyEquivalent(with: key("z", flags: [.command, .shift])) && editor.string == "{1w}%")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        edit { precondition(window.performKeyEquivalent(with: key("x"))) }
        precondition(editor.string.isEmpty)
        precondition(window.performKeyEquivalent(with: key("z")) && editor.string == "{1w}%")
        precondition(window.performKeyEquivalent(with: key("z", flags: [.command, .shift])) && editor.string.isEmpty)

        precondition(window.performKeyEquivalent(with: key("z")) && editor.string == "{1w}%")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        edit { editor.insertText(" new", replacementRange: editor.selectedRange()) }
        precondition(!manager.canRedo, "New typing after undo must discard the redo branch")
        precondition(window.performKeyEquivalent(with: key("z", flags: [.command, .shift])) && editor.string == "{1w}% new")
        manager.removeAllActions()
        precondition(window.performKeyEquivalent(with: key("z")) && editor.string == "{1w}% new")
        precondition(window.performKeyEquivalent(with: key("z", flags: [.command, .shift])) && editor.string == "{1w}% new")
        editor.clipboard.releaseGlobally()
        window.makeFirstResponder(nil)
        print("PASS: settings field-editor copy, paste, cut, select-all and modifier isolation using a private pasteboard")
        print("PASS: native undo history, undo/redo typing/paste/cut, redo invalidation after new input and empty-history no-op")
    }
}
