import HerdrKit
import SwiftUI

struct MobileRenameSheet: View {
    let title: String
    let prompt: String
    let actions: MobileActionCoordinator
    let operation: @MainActor (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(
        title: String,
        prompt: String,
        initialValue: String,
        actions: MobileActionCoordinator,
        operation: @escaping @MainActor (String) async throws -> Void
    ) {
        self.title = title
        self.prompt = prompt
        self.actions = actions
        self.operation = operation
        _value = State(initialValue: initialValue)
    }

    private var trimmed: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(prompt, text: $value)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Rename"), action: submit)
                        .disabled(trimmed.isEmpty || actions.isWorking)
                }
            }
        }
    }

    private func submit() {
        let value = trimmed
        dismiss()
        actions.run { try await operation(value) }
    }
}
