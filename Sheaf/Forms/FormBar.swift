import SheafKit
import SwiftUI

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
