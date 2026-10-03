import AppKit
import SwiftUI

/// The system search field, for places outside a toolbar.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = UnfocusedSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// A search field that does not grab the keyboard focus when its window first appears.
private final class UnfocusedSearchField: NSSearchField {
    private var isReady = false

    override var acceptsFirstResponder: Bool { isReady && super.acceptsFirstResponder }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The window picks its first responder as it appears; opt in right after that.
        DispatchQueue.main.async { [weak self] in self?.isReady = true }
    }
}
