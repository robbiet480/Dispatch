import DispatchKit
import SwiftUI

/// Data → Advanced → Webhook (plan 24): deliver each completed report as
/// JSON to a user-configured URL. Config is device-local (never synced).
struct WebhookSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(WebhookManager.self) private var webhookManager

    @State private var testResult: String?
    @State private var isSendingTest = false
    @State private var showSendAllDialog = false
    @State private var isSendingBulk = false
    @State private var showBulkFailedAlert = false

    private var theme: Theme { themeStore.theme }

    var body: some View {
        @Bindable var manager = webhookManager
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    Toggle("Send Report Webhooks", isOn: $manager.isEnabled)
                        .tint(.white.opacity(0.4))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("webhook-toggle")

                    TextField("https://example.com/webhook", text: $manager.urlString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("webhook-url")

                    if case .rejected(let reason) = manager.urlValidation,
                       !manager.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("webhook-url-error")
                    }

                    SecureField("Secret (optional)", text: $manager.secret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("webhook-secret")

                    Toggle("Encrypt Payload", isOn: $manager.encryptPayload)
                        .tint(.white.opacity(0.4))
                        .foregroundStyle(.white)
                        .disabled(manager.secret.isEmpty)
                        .accessibilityIdentifier("webhook-encrypt")
                } header: {
                    sectionHeader("WEBHOOK")
                } footer: {
                    Text(configFooter)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    Button {
                        sendTest()
                    } label: {
                        if isSendingTest {
                            HStack {
                                settingsLabel("Send Test")
                                Spacer()
                                ProgressView().tint(.white)
                            }
                        } else {
                            settingsLabel("Send Test")
                        }
                    }
                    .disabled(isSendingTest)
                    .accessibilityIdentifier("webhook-test")

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .accessibilityIdentifier("webhook-test-result")
                    }

                    Button {
                        showSendAllDialog = true
                    } label: {
                        if isSendingBulk {
                            HStack {
                                settingsLabel("Send All Reports…")
                                Spacer()
                                ProgressView().tint(.white)
                            }
                        } else {
                            settingsLabel("Send All Reports…")
                        }
                    }
                    .disabled(isSendingBulk || !manager.isEnabled)
                    .accessibilityIdentifier("webhook-send-all")

                    HStack {
                        Text("Last delivery")
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text(manager.lastDeliveryStatus ?? "None yet")
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityIdentifier("webhook-status")
                } header: {
                    sectionHeader("DELIVERY")
                } footer: {
                    Text(privacyFooter)
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("webhook-privacy-note")
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Webhook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Send All mode choice, made at tap time; the message states the
        // count before anything is sent.
        .confirmationDialog("Send All Reports", isPresented: $showSendAllDialog, titleVisibility: .visible) {
            Button("Send \(webhookManager.reportCount) Reports Individually") {
                webhookManager.sendAllIndividually()
            }
            Button("Send as One Bulk Payload") {
                sendBulk()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends all \(webhookManager.reportCount) reports to your webhook — individually as report.created events (with normal retries), or as a single report.bulk payload (one POST, no retry queue).")
        }
        // The bulk payload does NOT enter the retry queue — one retry offer.
        .alert("Bulk Send Failed", isPresented: $showBulkFailedAlert) {
            Button("Retry") { sendBulk() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The bulk payload wasn't delivered. Check the URL and try again.")
        }
    }

    private var configFooter: String {
        "POSTs each completed report as JSON. HTTPS anywhere; plain HTTP only for servers on your local network. "
            + "With a secret set, requests carry an X-Dispatch-Signature HMAC header; Encrypt Payload additionally "
            + "wraps the JSON in AES-256-GCM (key derived from the secret)."
    }

    private var privacyFooter: String {
        "The full report — including your location and health readings — is sent to the URL above. "
            + "That server is yours to secure; Dispatch has no visibility into what it does with the data. "
            + "This configuration stays on this device and never syncs."
    }

    private func sendTest() {
        isSendingTest = true
        testResult = nil
        Task {
            testResult = await webhookManager.sendTest()
            isSendingTest = false
        }
    }

    private func sendBulk() {
        isSendingBulk = true
        Task {
            let delivered = await webhookManager.sendAllAsSinglePayload()
            isSendingBulk = false
            if !delivered {
                showBulkFailedAlert = true
            }
        }
    }

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.white)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
