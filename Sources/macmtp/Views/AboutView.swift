import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            
            Text("macMTP")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version \(AppVersion.current)")
                .font(.body)
                .foregroundColor(.secondary)
            
            Text("A fast, native macOS Android file transfer utility built with Swift and Go.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/kalabhaftu/MacMTP")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("GitHub Repository")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: "https://github.com/kalabhaftu/MacMTP/issues")!) {
                    HStack {
                        Image(systemName: "exclamationmark.bubble")
                        Text("Report an Issue")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            
            Text("Native SwiftUI app with a bundled Kalam/go-mtpx MTP bridge.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(width: 320, height: 260)
        .padding()
    }
}
