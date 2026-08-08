import SwiftUI

struct NewFolderDialogRequest: Identifiable {
    let id = UUID()
    let parentPath: String
    let isLocal: Bool
}

struct RenameDialogRequest: Identifiable {
    let id = UUID()
    let file: FileNode
    let isLocal: Bool
    let initialName: String
}

struct FileOperationDialog: View {
    let title: String
    let actionTitle: String
    let prompt: String
    let initialText: String
    @Binding var text: String
    @Binding var isSubmitting: Bool
    @Binding var errorMessage: String?
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            Text(prompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    guard !isSubmitting else { return }
                    onSubmit()
                }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            text = initialText
            isTextFieldFocused = true
        }
    }
}

