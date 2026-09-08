import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Server", value: model.server)
                LabeledContent("Status") {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Guide") {
                LabeledContent("Channels", value: "\(model.channels.count)")
                Button {
                    Task { await model.loadGuide() }
                } label: {
                    Label("Refresh Guide", systemImage: "arrow.clockwise")
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await model.signOut() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
