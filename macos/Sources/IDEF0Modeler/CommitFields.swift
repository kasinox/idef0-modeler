// Inspector fields that commit when editing ends, not on every keystroke.
//
// A plain TextField writes its binding per character, which would make every
// character an undo step. These keep a draft and hand it over once — on
// Return, when focus leaves, or when the field goes away — and each is keyed
// to what it edits, so changing the selection mid-edit cannot write one box's
// name onto another.
//
// The draft is a way to batch keystrokes, not to override the model: a value
// that changes underneath a focused field — an undo, an edit on the canvas —
// shows through unless something has been typed since the draft was loaded or
// submitted, and text that was never typed is never committed back.

import IDEF0Core
import SwiftUI

struct CommitTextField: View {
    let label: String
    let value: String
    var prompt: String?
    var multiline = false
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var loaded = false
    /// The draft last handed to `onCommit`, until the value it produced
    /// arrives. The model may normalise it (a name is trimmed), so the draft
    /// cannot be compared with the value to tell "just submitted" apart from
    /// "typed since".
    @State private var submitted: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft, prompt: prompt.map { Text($0) }, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 2...6 : 1...1)
            .focused($focused)
            .onAppear {
                if !loaded { draft = value; loaded = true }
            }
            // Keyed on the UTF-8 bytes, not `value` itself: SwiftUI only calls
            // this closure when the watched value actually changes, and it
            // decides that with `==` — canonical equivalence for a String, so
            // an outside edit that only renormalizes Unicode text (an undo
            // restoring NFD text a fix had changed to NFC, say) would compare
            // equal to the old value and never reach `adoptsChange` at all,
            // leaving the field showing stale text.
            .onChange(of: Array(value.utf8)) { old, new in
                let oldValue = String(decoding: old, as: UTF8.self)
                let newValue = String(decoding: new, as: UTF8.self)
                if Self.adoptsChange(draft: draft, from: oldValue, submitted: submitted, focused: focused) { draft = newValue }
                submitted = nil
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    /// Whether a changed value replaces the draft: always while the field is
    /// not being edited, and otherwise only when nothing has been typed since
    /// the draft was loaded (it still reads `old`) or submitted. So after
    /// Return and then Undo the field shows the restored text and a later
    /// blur commits nothing, while unsaved typing survives an outside change.
    static func adoptsChange(draft: String, from old: String, submitted: String?, focused: Bool) -> Bool {
        !focused || draft == old || draft == submitted
    }

    /// Byte-exact, not `!=`: a draft that only differs from the model's value
    /// by Unicode normalization is still an edit worth committing (F71), and
    /// `!=`'s canonical equivalence would silently drop it.
    private func commit() {
        guard loaded, !draft.utf8.elementsEqual(value.utf8) else { return }
        submitted = draft
        onCommit(draft)
    }
}

struct CommitNumberField: View {
    let label: String
    let value: Double
    let onCommit: (Double) -> Void

    @State private var draft = ""
    /// The text that stands for `value` in the field: what was last loaded
    /// from the model, or typed and found to name the same number. Text equal
    /// to it was not edited, so it is never parsed and committed back — a
    /// focus passing through a field must not rewrite stored geometry.
    @State private var shown = ""
    @State private var submitted: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { load(value) }
            .onChange(of: value) { _, new in
                if !focused || draft == shown || draft == submitted { load(new) }
                submitted = nil
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private func load(_ v: Double) {
        draft = Self.format(v)
        shown = draft
    }

    private func commit() {
        switch Self.decision(draft: draft, shown: shown, value: value) {
        case .nothing: break
        case .revert: draft = shown
        case .commit(let v): submitted = draft; onCommit(v)
        case .accept: load(value)
        }
    }

    enum Decision: Equatable {
        /// The text is what the field showed: nothing was typed.
        case nothing
        /// Not a finite number: the field shows the value again.
        case revert
        /// A different finite number: hand it over.
        case commit(Double)
        /// The same number written differently ("50.0" for 50): nothing to
        /// commit; the field shows it the usual way.
        case accept
    }

    /// What ending an edit does with the draft, given the text the model
    /// last put in the field and the value it holds.
    static func decision(draft: String, shown: String, value: Double) -> Decision {
        let t = draft.trimmingCharacters(in: .whitespaces)
        if t == shown { return .nothing }
        guard let v = Double(t), v.isFinite else { return .revert }
        return v == value ? .accept : .commit(v)
    }

    /// The number as JavaScript prints it — the shortest text that reads back
    /// to the same value, whole numbers without a decimal point — so the field
    /// shows what the file holds, and never converts to `Int`, which traps
    /// beyond ±9.2e18 while a stored coordinate may be any finite number.
    static func format(_ v: Double) -> String { jsNumberString(v) }
}
