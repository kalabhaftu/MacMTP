import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates: Bool = true
    @AppStorage("autoDownloadUpdates") private var autoDownloadUpdates: Bool = false
    @AppStorage("autoDetectDevice") private var autoDetectDevice: Bool = true
    @AppStorage("sendCrashReports") private var sendCrashReports: Bool = true

    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("General").font(.headline)) {
                    Toggle("Auto-detect and connect MTP device on launch", isOn: $autoDetectDevice)
                }
                .padding(.bottom, 10)

                Section(header: Text("MTP Engine").font(.headline)) {
                    Picker("Engine Type", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "mtpEngine") ?? "Kalam" },
                        set: { UserDefaults.standard.set($0, forKey: "mtpEngine") }
                    )) {
                        Text("Kalam (Modern, Fast, >4GB support)").tag("Kalam")
                        Text("Legacy (Fallback for older devices)").tag("Legacy")
                    }
                    .pickerStyle(RadioGroupPickerStyle())

                }
                .padding(.bottom, 10)

                Section(header: Text("File Explorer").font(.headline)) {
                    Toggle("Show hidden files on Local Mac", isOn: $showHiddenFilesLocal)
                    Toggle("Show hidden files on Android Device", isOn: $showHiddenFilesMTP)
                }
                .padding(.bottom, 10)

                Section(header: Text("Updates").font(.headline)) {
                    Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    Toggle("Automatically download new updates", isOn: $autoDownloadUpdates)
                        .disabled(!autoCheckUpdates)
                }
                .padding(.bottom, 10)

                Section(header: Text("Privacy").font(.headline)) {
                    Toggle("Send anonymous crash reports and usage logs", isOn: $sendCrashReports)
                    Text("We genuinely don't collect your data. This only sends error logs if enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .frame(width: 480)
    }
}
