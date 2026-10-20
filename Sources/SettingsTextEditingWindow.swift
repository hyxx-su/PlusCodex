import AppKit

/// Menu-bar apps do not have the standard Edit menu to route field-editor shortcuts.
final class SettingsTextEditingWindow: NSWindow {
    private weak var undoField: NSTextField?

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let textView = editor as? NSTextView {
            // AppKit reuses one editor and window undo manager for all fields.
            // Old typing actions must never be replayed against a different value.
            if createFlag, let field = object as? NSTextField,
               undoField !== field || firstResponder !== textView {
                undoManager?.removeAllActions()
                undoField = field
            }
            if !textView.allowsUndo { textView.allowsUndo = true }
        }
        return editor
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.type == .keyDown,
              let editor = firstResponder as? NSTextView, editor.isFieldEditor else {
            return super.performKeyEquivalent(with: event)
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z", editor.isEditable,
           modifiers == .command || modifiers == [.command, .shift] {
            let redoing = modifiers.contains(.shift)
            // Use only the active input's native history; no-history is a safe no-op.
            guard let manager = editor.undoManager,
                  redoing ? manager.canRedo : manager.canUndo else { return true }
            editor.breakUndoCoalescing()
            if redoing { manager.redo() } else { manager.undo() }
            // Direct UndoManager changes do not notify NSTextField's edit delegate.
            // Keep its existing validation, preview and persistence flow in sync.
            editor.didChangeText()
            return true
        }
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        let action: Selector
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where editor.isSelectable: action = #selector(NSText.copy(_:))
        case "v" where editor.isEditable: action = #selector(NSText.paste(_:))
        case "x" where editor.isEditable: action = #selector(NSText.cut(_:))
        case "a" where editor.isSelectable: action = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return editor.tryToPerform(action, with: self)
    }
}
