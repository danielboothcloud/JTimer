import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var jiraAPI: JiraAPI
    @Environment(\.dismiss) private var dismiss

    @State private var jiraDomain = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var isValidating = false
    @State private var validationMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)

                Spacer()
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 12) {
                    // Jira Connection Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Jira Connection")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Domain")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("yourcompany", text: $jiraDomain)
                                    .textFieldStyle(.roundedBorder)
                                Text("For yourcompany.atlassian.net")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Email")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("you@example.com", text: $jiraEmail)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Token")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                SecureField("", text: $jiraToken)
                                    .textFieldStyle(.roundedBorder)
                                Link("Get token at id.atlassian.com", destination: URL(string: "https://id.atlassian.com")!)
                                    .font(.caption2)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                    }

                    // Connection Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 8) {
                            HStack {
                                if jiraAPI.isAuthenticated {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                    Text("Connected")
                                        .font(.caption)
                                        .foregroundColor(.green)

                                    if let user = jiraAPI.currentUser {
                                        Spacer()
                                        Text(user.displayName)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                } else {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    Text("Not Connected")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }

                            if let error = jiraAPI.lastError {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if !validationMessage.isEmpty {
                                Text(validationMessage)
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                    }

                    // Help Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Setup")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Go to id.atlassian.com")
                            Text("2. Security → Create API token")
                            Text("3. Paste token above")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(jiraDomain.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty || isValidating)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
        .background(VisualEffectView())
        .onAppear {
            loadCurrentSettings()
        }
    }

    private func loadCurrentSettings() {
        let settings = AppSettings()
        jiraDomain = settings.jiraDomain
        jiraEmail = settings.jiraEmail

        if let existingToken = KeychainManager().getToken() {
            jiraToken = existingToken
        }
    }

    private func saveSettings() {
        guard !jiraDomain.isEmpty, !jiraEmail.isEmpty, !jiraToken.isEmpty else {
            return
        }

        isValidating = true
        validationMessage = "Validating connection..."

        jiraAPI.configure(domain: jiraDomain, email: jiraEmail, token: jiraToken)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isValidating = false
            if jiraAPI.isAuthenticated {
                validationMessage = "Connection successful!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    dismiss()
                }
            } else {
                validationMessage = "Connection failed. Please check your credentials."
            }
        }
    }
}