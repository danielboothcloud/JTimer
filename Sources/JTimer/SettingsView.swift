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

    // Custom JQL templates
    @State private var customTemplates: [JQLTemplate] = []
    @State private var showingAddTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateQuery = ""

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

                    // Custom JQL Templates Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Custom JQL Templates")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(action: {
                                showingAddTemplate.toggle()
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Add custom template")
                        }

                        if customTemplates.isEmpty {
                            Text("No custom templates yet")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(8)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(customTemplates) { template in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(template.name)
                                                .font(.caption)
                                            Text(template.query)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Button(action: {
                                            deleteTemplate(template)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Delete template")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        if showingAddTemplate {
                            Divider()

                            VStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Name")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    TextField("My Custom Query", text: $newTemplateName)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("JQL Query")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    TextField("assignee = currentUser()", text: $newTemplateQuery)
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack(spacing: 8) {
                                    Button("Cancel") {
                                        showingAddTemplate = false
                                        newTemplateName = ""
                                        newTemplateQuery = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)

                                    Spacer()

                                    Button("Save") {
                                        addCustomTemplate()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .font(.caption)
                                    .disabled(newTemplateName.isEmpty || newTemplateQuery.isEmpty)
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
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
        customTemplates = settings.customJQLTemplates

        if let existingToken = KeychainManager().getToken() {
            jiraToken = existingToken
        }
    }

    private func addCustomTemplate() {
        let newTemplate = JQLTemplate(
            name: newTemplateName,
            query: newTemplateQuery,
            isCustom: true
        )

        customTemplates.append(newTemplate)

        var settings = AppSettings()
        settings.customJQLTemplates = customTemplates

        showingAddTemplate = false
        newTemplateName = ""
        newTemplateQuery = ""
    }

    private func deleteTemplate(_ template: JQLTemplate) {
        customTemplates.removeAll { $0.id == template.id }

        var settings = AppSettings()
        settings.customJQLTemplates = customTemplates
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