import SwiftUI

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var offBelow: Double?
    var unit = "locations"
    let format: (Double) -> String

    @State private var editing = false
    @State private var input = ""
    @State private var draft: Double?

    private var displayedValue: Double { draft ?? value }
    private var label: String {
        if let offBelow, displayedValue < offBelow { return "Off" }
        return format(displayedValue)
    }
    private var enteredValue: Double? {
        guard let number = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              number.isFinite, range.contains(number) else { return nil }
        return number.rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button {
                    input = String(Int(value.rounded()))
                    editing = true
                } label: {
                    Text(label)
                        .monospacedDigit()
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(title)")
                .accessibilityValue(label)
            }
            Slider(value: Binding(
                get: { min(range.upperBound, max(range.lowerBound, displayedValue)) },
                set: { draft = $0; value = $0 }
            ), in: range, step: 1) { changing in
                if !changing { draft = nil }
            }
            .accessibilityLabel(title)
            .accessibilityValue(label)
        }
        .padding(.vertical, 2)
        .alert(title, isPresented: $editing) {
            TextField("Value in \(unit)", text: $input)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let enteredValue { value = enteredValue; draft = nil }
            }
            .disabled(enteredValue == nil)
        } message: {
            Text("Enter \(Int(range.lowerBound))–\(Int(range.upperBound)) \(unit)." + (offBelow == nil ? "" : " Use 0 for Off."))
        }
    }
}

enum SettingFormat {
    static func meters(_ value: Double) -> String {
        "\(Int(value)) m"
    }

    static func seconds(_ value: Double) -> String {
        let seconds = Int(value)
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    static func count(_ value: Double) -> String {
        "\(Int(value))"
    }
}
