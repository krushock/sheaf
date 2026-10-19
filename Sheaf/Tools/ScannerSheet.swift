import AppKit
import ImageCaptureCore
import Quartz
import SwiftUI

/// Insert > Pages from Scanner: the system's own scanner panel, the one Preview uses.
struct ScannerSheet: View {
    let viewer: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanned = 0
    @State private var hasScanner = false

    var body: some View {
        VStack(spacing: 0) {
            ScannerPanel(hasScanner: $hasScanner) { data in
                // Each scan goes in after the one before it.
                viewer.insertItems([data], at: viewer.insertionIndex + scanned)
                scanned += 1
            }
            .overlay(alignment: .trailing) {
                if !hasScanner {
                    ContentUnavailableView(
                        "No Scanner Selected", systemImage: "scanner",
                        description: Text("Scanners connected to this Mac or shared on the network appear on the left.")
                    )
                    .frame(width: 660)
                    .frame(maxHeight: .infinity)
                    .background(.background)
                }
            }
            Divider()
            HStack {
                Text(scanned == 0
                    ? String(localized: "Choose a scanner on the left. Each scan is added to the document.")
                    : String(localized: "\(scanned) pages added."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 600)
    }
}

/// Image Capture's device list beside its scanner controls.
private struct ScannerPanel: NSViewRepresentable {
    @Binding var hasScanner: Bool
    let onScan: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan) { hasScanner = $0 }
    }

    func makeNSView(context: Context) -> NSSplitView {
        let browser = IKDeviceBrowserView()
        browser.displaysLocalScanners = true
        browser.displaysNetworkScanners = true
        browser.displaysLocalCameras = false
        browser.displaysNetworkCameras = false
        browser.mode = .table
        browser.delegate = context.coordinator

        let scanner = IKScannerDeviceView()
        scanner.delegate = context.coordinator
        scanner.mode = .advanced
        scanner.hasDisplayModeSimple = true
        scanner.hasDisplayModeAdvanced = true
        // Scans come back as files in a folder of the app's own, and are read from there.
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = context.coordinator.folder
        scanner.displaysDownloadsDirectoryControl = false
        scanner.displaysPostProcessApplicationControl = false
        scanner.documentName = String(localized: "Scan")
        context.coordinator.scanner = scanner

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(browser)
        split.addArrangedSubview(scanner)
        browser.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return split
    }

    func updateNSView(_ view: NSSplitView, context: Context) {
        context.coordinator.onScan = onScan
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency IKDeviceBrowserViewDelegate, @preconcurrency IKScannerDeviceViewDelegate {
        var onScan: (Data) -> Void
        let onSelection: (Bool) -> Void
        weak var scanner: IKScannerDeviceView?
        let folder: URL

        init(onScan: @escaping (Data) -> Void, onSelection: @escaping (Bool) -> Void) {
            self.onScan = onScan
            self.onSelection = onSelection
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("Scans-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            // The scanned pages are in the document by now, or were not wanted.
            try? FileManager.default.removeItem(at: folder)
        }

        func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView!, selectionDidChange device: ICDevice!) {
            scanner?.scannerDevice = device as? ICScannerDevice
            onSelection(device is ICScannerDevice)
        }

        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, fileData data: Data!, error: (any Error)!) {
            if let error {
                NSApp.presentError(error)
                return
            }
            if let scan = data ?? url.flatMap({ try? Data(contentsOf: $0) }) { onScan(scan) }
            if let url { try? FileManager.default.removeItem(at: url) }
        }

        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didEncounterError error: (any Error)!) {
            if let error { NSApp.presentError(error) }
        }
    }
}
