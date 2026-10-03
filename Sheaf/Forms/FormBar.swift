import SheafKit
import SwiftUI

/// The row of form tools shown under the toolbar while building a form.
struct FormBar: View {
    @Bindable var viewer: ViewerModel

    var body: some View {
        // An overlay on a bar of fixed height, for the same reason as the markup bar.
        Rectangle()
            .fill(.bar)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { tools }
            .overlay(alignment: .trailing) {
                Button("Done") { viewer.isFormEditing = false }
                    .padding(.trailing, 12)
            }
            .clipped()
    }

    private var tools: some View {
        HStack(spacing: 4) {
            Button {
                viewer.formTool = nil
            } label: {
                Label("Select", systemImage: "cursorarrow").frame(width: 26, height: 22)
            }
            .background(viewer.formTool == nil ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .help("Select, move and resize fields")

            Divider().frame(height: 18).padding(.horizontal, 4)

            ForEach(FormTool.allCases) { tool in
                Button {
                    viewer.formTool = viewer.formTool == tool ? nil : tool
                } label: {
                    Label(tool.title, systemImage: tool.systemImage).frame(width: 26, height: 22)
                }
                .background(viewer.formTool == tool ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                .help(tool.title)
            }

            Divider().frame(height: 18).padding(.horizontal, 4)

            Button {
                viewer.detectFields()
            } label: {
                Label("Detect Fields", systemImage: "wand.and.stars").frame(width: 26, height: 22)
            }
            .help("Make fields from the boxes and lines drawn on this page")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .fixedSize()
    }
}

/// The calendar shown for a date field.
struct DateFieldPicker: View {
    @State var date: Date
    let hasValue: Bool
    /// Called with the chosen date, or `nil` to empty the field.
    let onPick: (Date?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if hasValue {
                    Button("Clear") { onPick(nil) }
                }
                Button("Today") { date = .now }
                Spacer()
                Button("Set Date") { onPick(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
