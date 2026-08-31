import SwiftUI

struct TransferToastView: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            icon
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private var icon: some View {
        if message.contains("Preparing") {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if message.contains("could not") {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if message.contains("not supported") {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
        }
    }
}
