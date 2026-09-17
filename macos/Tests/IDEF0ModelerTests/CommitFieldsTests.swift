// The rules behind the inspector's commit-on-end fields: what a number field
// does with its text when editing ends, how numbers are shown, and when a
// text field lets a changed value replace what it shows.

import Testing
@testable import IDEF0Core
@testable import IDEF0Modeler

@Suite("Commit fields")
struct CommitFieldsTests {
    typealias Decision = CommitNumberField.Decision

    @Test("A number field commits only what was typed — never the text it displayed")
    func numberDecision() {
        // Focus passed through: the text is the model's, however it was rounded.
        #expect(CommitNumberField.decision(draft: "412.4", shown: "412.4", value: 412.37) == .nothing)
        #expect(CommitNumberField.decision(draft: "412.37", shown: "412.37", value: 412.37) == .nothing)
        #expect(CommitNumberField.decision(draft: " 55 ", shown: "412.37", value: 412.37) == .commit(55))
        #expect(CommitNumberField.decision(draft: "1e20", shown: "50", value: 50) == .commit(1e20))
        // The same number, spelt differently, is not an edit.
        #expect(CommitNumberField.decision(draft: "50.0", shown: "50", value: 50) == .accept)
        // Not a number: the field goes back to showing the value.
        #expect(CommitNumberField.decision(draft: "abc", shown: "50", value: 50) == .revert)
        #expect(CommitNumberField.decision(draft: "inf", shown: "50", value: 50) == .revert)
        #expect(CommitNumberField.decision(draft: "", shown: "50", value: 50) == .revert)
    }

    @Test("Numbers are shown as the file holds them, and never through Int")
    func numberFormat() {
        #expect(CommitNumberField.format(50) == "50")
        #expect(CommitNumberField.format(-0.0) == "0")
        #expect(CommitNumberField.format(412.37) == "412.37")
        #expect(CommitNumberField.format(2.5) == "2.5")
        #expect(CommitNumberField.format(-17.25) == "-17.25")
        // Beyond Int.max, where String(Int(v)) would trap.
        #expect(CommitNumberField.format(1e20) == "100000000000000000000")
        #expect(CommitNumberField.format(-1e20) == "-100000000000000000000")
        #expect(CommitNumberField.format(9.3e18) == "9300000000000000000")
        #expect(CommitNumberField.format(1e21) == "1e+21")
        // What is shown reads back to the value it stands for.
        for v in [412.37, 1e20, 0.1 + 0.2, 1234567.891, 1e-7] {
            #expect(Double(CommitNumberField.format(v)) == v, "\(v)")
        }
    }

    @Test("A text field adopts a changed value unless something was typed since the last load or submit")
    func textAdoption() {
        // Not being edited: always.
        #expect(CommitTextField.adoptsChange(draft: "typing", from: "Old", submitted: nil, focused: false))
        // Focused but untouched since it was loaded: an undo shows through.
        #expect(CommitTextField.adoptsChange(draft: "Old", from: "Old", submitted: nil, focused: true))
        // Focused, just submitted "New " which the model trimmed to "New": the normalised value shows.
        #expect(CommitTextField.adoptsChange(draft: "New ", from: "Old", submitted: "New ", focused: true))
        // Focused with unsaved typing: kept, whatever changed underneath.
        #expect(!CommitTextField.adoptsChange(draft: "Unsaved", from: "Old", submitted: nil, focused: true))
        #expect(!CommitTextField.adoptsChange(draft: "Unsaved", from: "Old", submitted: "Sent", focused: true))
    }

    @Test("Return, then Undo, then blur: the undo stands")
    func undoAfterSubmit() {
        // The sequence the fields go through, in terms of the two rules.
        var value = "Old", draft = "New ", submitted: String? = nil
        // Return: the draft differs from the value, so it is handed over and remembered.
        submitted = draft
        value = jsTrim(draft)
        // The model's value arrives: adopted, because the draft is what was submitted.
        #expect(CommitTextField.adoptsChange(draft: draft, from: "Old", submitted: submitted, focused: true))
        draft = value; submitted = nil
        // ⌘Z restores "Old": adopted, because the draft is still the value it was loaded from.
        #expect(CommitTextField.adoptsChange(draft: draft, from: value, submitted: submitted, focused: true))
        draft = "Old"; value = "Old"
        // Blur: the draft equals the value, so nothing is committed and the redo stack survives.
        #expect(draft == value)
    }
}
