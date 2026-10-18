import SwiftUI
import UIKit

@MainActor
struct LocalWebAccessView: View {
    @ObservedObject var server: LocalWebServer
    @State private var copiedValue: String?

    var body: some View {
        Form {
            Section {
                Text("Use a browser on the same Wi-Fi network to view charts, accounts, and transactions, or add income and expenses. Your ledger stays on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if server.isRunning {
                    Label("PC Access is running", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(PocketLedgerTheme.positive)
                } else {
                    Label("PC Access is stopped", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if server.isRunning {
                Section("Connect from your PC") {
                    Text("Install and verify the certificate in the next section first. Then open this secure address and enter the one-time code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let secureURL = server.secureURL {
                        LabeledContent("Secure address") {
                            Text(secureURL.absoluteString)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                                .font(.footnote.monospaced())
                        }
                        Button("Copy secure address", systemImage: "doc.on.doc") {
                            copy(secureURL.absoluteString)
                        }
                    } else {
                        LabeledContent("Secure address", value: "Starting…")
                    }

                    if let code = server.pairingCode {
                        LabeledContent("One-time pairing code") {
                            Text(code)
                                .font(.title2.monospaced().weight(.semibold))
                                .tracking(3)
                                .accessibilityLabel("Pairing code \(code)")
                        }
                        if let expiry = server.pairingExpiresAt {
                            Text("Expires \(expiry, style: .relative). It can only be used once.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("The pairing code expired or was used. Stop and start PC Access to get a new one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("If your iPhone changes Wi-Fi networks or its local address changes, stop and start PC Access again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Trust this iPhone on Windows") {
                    Text("The browser connection is encrypted. Windows must trust this iPhone’s local certificate first. On the PC, open the download address, then install the downloaded certificate for Current User under Trusted Root Certification Authorities. Verify its SHA-256 fingerprint below before installing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let certificateURL = server.certificateURL {
                        LabeledContent("Certificate download") {
                            Text(certificateURL.absoluteString)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                                .font(.footnote.monospaced())
                        }
                        Button("Copy certificate address", systemImage: "doc.on.doc") {
                            copy(certificateURL.absoluteString)
                        }
                    } else {
                        LabeledContent("Certificate download", value: "Starting…")
                    }
                    if let fingerprint = server.certificateFingerprint {
                        LabeledContent("SHA-256 fingerprint") {
                            Text(fingerprint)
                                .textSelection(.enabled)
                                .font(.caption2.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Text("Open PowerShell in Downloads and run Get-FileHash .\\PocketLedger-Local-CA.cer -Algorithm SHA256. Ignore the colons when comparing. Only install it if the fingerprints match.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("The certificate download uses HTTP and contains only the public certificate. Ledger data is served over HTTPS after pairing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Stop PC Access", systemImage: "stop.fill", role: .destructive) {
                        server.stop()
                    }
                }
            } else {
                Section {
                    Button("Start PC Access", systemImage: "play.fill") {
                        server.start()
                    }
                    .fontWeight(.semibold)
                    if let error = server.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(PocketLedgerTheme.warning)
                    }
                } footer: {
                    Text("Keep Pocket Ledger open on this iPhone. PC Access stops when the app goes into the background or locks. Allow Local Network access when iOS asks.")
                }
            }

            if let copiedValue {
                Section {
                    Label("Copied to clipboard", systemImage: "checkmark")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.positive)
                }
                .accessibilityLabel("Copied to clipboard")
                .task(id: copiedValue) {
                    try? await Task.sleep(for: .seconds(2))
                    self.copiedValue = nil
                }
            }
        }
        .pocketListSurface()
        .navigationTitle("PC Access")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        copiedValue = value
    }
}
