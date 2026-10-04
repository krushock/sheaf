import AppKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// What a document can be written as from the Export panel.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, jpeg, png, tiff, heic

    var id: Self { self }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .heic: .heic
        }
    }

    /// Whether the format trades size against quality.
    var hasQuality: Bool { self == .jpeg || self == .heic }
}

/// What to do to a PDF as it is saved under a new name or exported: the choices
/// Preview gives in its save dialog, as far as Sheaf's engine makes them.
nonisolated struct PDFSaveOptions: Sendable, Equatable {
    var makesArchival = false
    var optimizesPictures = false
    var usesJPEG = false
    /// A password to open with, an owner password and what others may do, or `nil` to leave protection as it is.
    var protection: Protection?

    struct Protection: Sendable, Equatable {
        var userPassword: String
        var ownerPassword: String?
        var permissions: Permissions
    }

    /// Whether the document is written just as it is.
    var isPlain: Bool { self == PDFSaveOptions() }
}

nonisolated extension Toolbox {
    /// The document as the options make it, and the password that opens the result.
    static func save(_ source: Source, with options: PDFSaveOptions) throws -> (data: Data, password: String?) {
        var current = source
        if options.optimizesPictures || options.usesJPEG {
            // "For screen" is 150 pixels to the inch at the size a picture is shown; nothing else is thrown away.
            let compression = CompressionOptions(
                maximumImageResolution: options.optimizesPictures ? 150 : nil, imageQuality: options.usesJPEG ? 0.75 : nil, removesExtras: false
            )
            current.data = try compress(current, options: compression)
        }
        if options.makesArchival {
            // The archival form takes passwords out; it may not have any.
            return (try archival(current).data, nil)
        }
        if let protection = options.protection {
            let data = try protect(current, userPassword: protection.userPassword, ownerPassword: protection.ownerPassword, permissions: protection.permissions)
            // Sheaf keeps working with the document as its owner.
            return (data, protection.ownerPassword ?? protection.userPassword)
        }
        return (current.data, current.password)
    }
}

/// The choices shown under the name and place in the Save As and Export panels.
@Observable
final class SaveOptionsModel {
    /// Offered in the Export panel only; saving under a new name always writes a PDF.
    let showsFormat: Bool
    var format = ExportFormat.pdf {
        didSet { if format != oldValue { onFormatChange?(format) } }
    }
    @ObservationIgnored var onFormatChange: ((ExportFormat) -> Void)?

    var makesArchival = false
    var optimizesPictures = false
    var usesJPEG = false

    // Permissions
    var password = ""
    var verification = ""
    var restricts = false
    var ownerPassword = ""
    var allowsPrinting = true
    var allowsCopying = true
    var allowsChanges = false

    // Pictures
    var resolution = 150.0
    var quality = 0.8

    init(showsFormat: Bool) {
        self.showsFormat = showsFormat
    }

    /// Whether what is typed for permissions can be used. Nothing typed is fine too.
    var permissionsAreValid: Bool {
        guard password == verification else { return false }
        return !restricts || (!ownerPassword.isEmpty && ownerPassword != password)
    }

    var protectsDocument: Bool { permissionsAreValid && (!password.isEmpty || restricts) }

    var pdfOptions: PDFSaveOptions {
        var options = PDFSaveOptions(makesArchival: makesArchival, optimizesPictures: optimizesPictures, usesJPEG: usesJPEG)
        if protectsDocument, !makesArchival {
            var permissions = Permissions.all
            if restricts {
                permissions = [.extractForAccessibility]
                if allowsPrinting { permissions.formUnion([.print, .printHighQuality]) }
                if allowsCopying { permissions.insert(.copy) }
                if allowsChanges { permissions.formUnion([.modify, .annotate, .fillForms, .assemble]) }
            }
            options.protection = PDFSaveOptions.Protection(userPassword: password, ownerPassword: restricts ? ownerPassword : nil, permissions: permissions)
        }
        return options
    }
}

/// The accessory of the Save As and Export panels, laid out like the one in Preview.
struct SaveOptionsView: View {
    @Bindable var model: SaveOptionsModel
    @State private var showsPermissions = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            if model.showsFormat {
                GridRow {
                    Text("Format:").gridColumnAlignment(.trailing)
                    Picker("Format", selection: $model.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 250, alignment: .leading)
                }
            }
            if model.format == .pdf {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Create PDF/A", isOn: $model.makesArchival)
                            .help("A form of PDF for keeping documents for decades: fonts inside the file, a color profile, no passwords")
                        Toggle("Optimize images for screen", isOn: $model.optimizesPictures)
                            .help("Pictures finer than 150 pixels per inch are scaled down to that")
                        Toggle("Save images as JPEG", isOn: $model.usesJPEG)
                            .help("Photographs are stored as JPEG, which is smaller and not exact")
                        HStack(spacing: 8) {
                            Button("Permissions…") { showsPermissions = true }
                                .disabled(model.makesArchival)
                                .popover(isPresented: $showsPermissions, arrowEdge: .trailing) { PermissionsForm(model: model) }
                            if model.makesArchival {
                                Text("PDF/A cannot have a password.").foregroundStyle(.secondary)
                            } else if model.protectsDocument {
                                Label(model.password.isEmpty ? "Limits set" : "Password set", systemImage: "lock.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                if model.format.hasQuality {
                    GridRow {
                        Text("Quality:")
                        Slider(value: $model.quality, in: 0.1...1) {
                            Text("Quality")
                        } minimumValueLabel: {
                            Text("Least").font(.caption).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("Best").font(.caption).foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                }
                GridRow {
                    Text("Resolution:")
                    HStack(spacing: 6) {
                        TextField("Resolution", value: $model.resolution, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("pixels/inch")
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("The picture is of the page being read.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // One size for every format, so the panel does not have to make room as the format changes.
        .frame(width: 440, height: model.showsFormat ? 170 : 136, alignment: .top)
    }
}

/// A password to open the saved copy with, and what others may do with it.
private struct PermissionsForm: View {
    @Bindable var model: SaveOptionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $model.password)
                SecureField("Verify", text: $model.verification)
            } header: {
                Text("Require a password to open the document.")
            } footer: {
                if !model.verification.isEmpty, model.password != model.verification {
                    Text("The passwords do not match.")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                Toggle("Limit What Others Can Do", isOn: $model.restricts)
                if model.restricts {
                    SecureField("Owner Password", text: $model.ownerPassword)
                    Toggle("Allow Printing", isOn: $model.allowsPrinting)
                    Toggle("Allow Copying Text and Pictures", isOn: $model.allowsCopying)
                    Toggle("Allow Changes and Comments", isOn: $model.allowsChanges)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.permissionsAreValid)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension SaveOptionsModel {
    /// The view to put under the name and place in a save panel.
    func accessoryView() -> NSView {
        let host = NSHostingView(rootView: SaveOptionsView(model: self))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        return host
    }
}
