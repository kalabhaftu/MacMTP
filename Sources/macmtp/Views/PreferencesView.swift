import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 420, height: 280)
    }

    private var generalTab: some View {
        Form {
            Toggle("Start macMTP at login", isOn: .constant(false))
            Toggle("Minimize to menu bar", isOn: .constant(false))
            Toggle("Auto-connect MTP device on launch", isOn: .constant(true))
            Picker("Conflict resolution default:", selection: .constant(0)) {
                Text("Ask for each").tag(0)
                Text("Overwrite all").tag(1)
                Text("Skip all").tag(2)
            }
        }
        .padding()
    }
}
