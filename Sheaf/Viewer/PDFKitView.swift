import PDFKit
import SwiftUI

/// Places the viewer's `PDFView` in the SwiftUI hierarchy.
struct PDFKitView: NSViewRepresentable {
    let viewer: ViewerModel

    func makeNSView(context: Context) -> PDFView {
        viewer.pdfView
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    // Take whatever space is offered. Left to itself, the view asks for the width of its
    // pages and pushes the sidebar and inspector off the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 600))
    }
}
