import SheafKit
import SwiftUI

/// File > Set Password: protect the document, change its password, or remove it.
struct PasswordSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var verification = ""
    @State private var restricts = false
    @State private var ownerPassword = ""
    @State private var allowsPrinting = true
    @State private var allowsCopying = true
    @State private var allowsChanges = false
    @State private var failure: String?

    private var isProtected: Bool { viewer.sheafDocument?.editor?.base.isEncrypted == true }

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $password)
                SecureField("Verify", text: $verification)
            } header: {
                Text(isProtected ? "Change the password needed to open this document." : "Require a password to open this document.")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                if !verification.isEmpty, password != verification {
                    Text("The passwords do not match.")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                Toggle("Limit What Others Can Do", isOn: $restricts)
                if restricts {
                    SecureField("Owner Password", text: $ownerPassword)
                    Toggle("Allow Printing", isOn: $allowsPrinting)
                    Toggle("Allow Copying Text and Pictures", isOn: $allowsCopying)
                    Toggle("Allow Changes and Comments", isOn: $allowsChanges)
                }
            } footer: {
                Text(restricts
                    ? "Apps that follow the rules ask for the owner password before going past these limits. With no password to open, anyone can still read the document."
                    : "The document is encrypted with AES 256-bit. There is no way to recover a forgotten password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            if isProtected {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove Password", role: .destructive, action: remove)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isProtected ? "Change Password" : "Set Password", action: protect)
                    .disabled(!isValid)
            }
        }
        .alert("The password could not be set.", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
    }

    private var isValid: Bool {
        guard password == verification else { return false }
        // Either a password to open, or limits kept by an owner password.
        return restricts ? !ownerPassword.isEmpty && ownerPassword != password : !password.isEmpty
    }

    private func protect() {
        guard let document = viewer.sheafDocument, let editor = document.editor else { return }
        var permissions = Permissions.all
        if restricts {
            permissions = [.extractForAccessibility]
            if allowsPrinting { permissions.formUnion([.print, .printHighQuality]) }
            if allowsCopying { permissions.insert(.copy) }
            if allowsChanges { permissions.formUnion([.modify, .annotate, .fillForms, .assemble]) }
        }
        let owner = restricts ? ownerPassword : nil
        do {
            let data = try editor.rewritten(protection: .password(user: password, owner: owner, permissions: permissions))
            // Sheaf keeps working with the document as its owner.
            let opens = owner ?? password
            guard document.replaceContents(isProtected ? String(localized: "Change Password") : String(localized: "Set Password"), with: data, password: opens) else {
                failure = String(localized: "The protected document could not be read back.")
                return
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove() {
        guard let document = viewer.sheafDocument, let editor = document.editor else { return }
        do {
            let data = try editor.rewritten(protection: .none)
            document.replaceContents(String(localized: "Remove Password"), with: data, password: nil)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
