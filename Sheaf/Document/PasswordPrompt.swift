import SwiftUI

/// Shown in place of the pages while a document is locked.
struct PasswordPrompt: View {
    let document: SheafDocument
    @State private var password = ""
    @State private var wasRejected = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Text("This document is password protected.")
                .font(.headline)
            Text(wasRejected ? "That password is not correct. Try again." : "Enter the password to open it.")
                .foregroundStyle(wasRejected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($isFieldFocused)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFieldFocused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        if !document.unlock(with: password) {
            wasRejected = true
            password = ""
            isFieldFocused = true
        }
    }
}
