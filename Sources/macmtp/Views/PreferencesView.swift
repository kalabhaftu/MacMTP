import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates: Bool = true
    @AppStorage("autoDownloadUpdates") private var autoDownloadUpdates: Bool = false
    @AppStorage("autoDetectDevice") private var autoDetectDevice: Bool = true
    @AppStorage("sendCrashReports") private var sendCrashReports: Bool = true
    @AppStorage("swapPanels") private var swapPanels: Bool = false
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0

    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("General").font(.headline)) {
                    Toggle("Auto-detect and connect MTP device on launch", isOn: $autoDetectDevice)
                }
                .padding(.bottom, 10)

                Section(header: Text("MTP Engine").font(.headline)) {
                    Picker("", selection: Binding(
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
                    Toggle("Swap Local and MTP panels (MTP on Left)", isOn: $swapPanels)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Font Size Scale: \(appFontScale, specifier: "%.1f")x")
                            Spacer()
                            Button("Reset") {
                                appFontScale = 1.0
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        }
                        Slider(value: $appFontScale, in: 0.7...2.0, step: 0.1)
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 10)

                Section(header: Text("Updates").font(.headline)) {
                    Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    Toggle("Automatically download new updates", isOn: $autoDownloadUpdates)
                        .disabled(!autoCheckUpdates)
                    Button("Check for Updates…") {
                        UpdaterService.shared.checkForUpdates(silent: false)
                    }
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
