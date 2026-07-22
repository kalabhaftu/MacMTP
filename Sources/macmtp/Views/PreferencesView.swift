import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates: Bool = true
    @AppStorage("autoDownloadUpdates") private var autoDownloadUpdates: Bool = false
    @AppStorage("autoDetectDevice") private var autoDetectDevice: Bool = true
    @AppStorage("sendCrashReports") private var sendCrashReports: Bool = false
    @AppStorage("swapPanels") private var swapPanels: Bool = false
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    @State private var reportingFeedback: String?
    @State private var isSendingTestReport = false

    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("General").font(.headline)) {
                    Toggle("Auto-detect and connect MTP device on launch", isOn: $autoDetectDevice)
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
                    Toggle("Send anonymous crash and error reports", isOn: $sendCrashReports)
                        .onChange(of: sendCrashReports) { _, enabled in
                            ErrorLogger.setReportingEnabled(enabled)
                            reportingFeedback = nil
                        }

                    HStack {
                        Button("Send Test Report") {
                            isSendingTestReport = true
                            reportingFeedback = nil
                            Task {
                                let result = await ErrorLogger.captureTestReport()
                                reportingFeedback = result.message
                                isSendingTestReport = false
                            }
                        }
                        .disabled(!sendCrashReports || ErrorLogger.status != .ready || isSendingTestReport)

                        if isSendingTestReport {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let reportingFeedback {
                            Text(reportingFeedback)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(reportingStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            if sendCrashReports {
                ErrorLogger.startIfEnabled()
            }
        }
    }

    private var reportingStatusText: String {
        switch ErrorLogger.status {
        case .disabled:
            "Reporting is off. macMTP sends nothing."
        case .invalidConfiguration:
            "Reporting is enabled, but its configuration is invalid."
        case .unavailable:
            "Reporting is enabled, but the reporting service did not start."
        case .ready:
            "Reporting is ready. File paths and device identifiers are not attached."
        }
    }
}
