import OSLog
import SwiftUI

enum AppDocument: String, Identifiable {
    case privacy
    case support

    var id: Self { self }
    var title: String { self == .privacy ? "Privacy Policy" : "Support" }
    var resourceName: String { self == .privacy ? "PrivacyPolicy" : "Support" }
    var webURL: URL {
        URL(string: "https://demo.tulane.casa/static/app/\(rawValue).txt")!
    }
}

struct AppInformationLinks: View {
    @State private var document: AppDocument?

    var body: some View {
        HStack(spacing: 20) {
            Button("Privacy Policy") { document = .privacy }
            Button("Support") { document = .support }
        }
        #if !os(tvOS)
        .buttonStyle(.borderless)
        #endif
        .sheet(item: $document) {
            AppInformationView(document: $0)
        }
    }
}

private struct AppInformationView: View {
    @Environment(\.dismiss) private var dismiss
    let document: AppDocument
    @State private var text: String?
    @State private var errorMessage: String?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.netv",
        category: "AppInformation"
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let text {
                        #if os(tvOS)
                        ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { paragraph in
                            Text(paragraph.element)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .focusable()
                        }
                        #else
                        Text(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        #endif
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                    }
                    #if os(tvOS)
                    Text("Online: \(document.webURL.absoluteString)")
                        .font(.footnote)
                        .focusable()
                    #else
                    Link("View Online", destination: document.webURL)
                    #endif
                }
                .padding(24)
            }
            .navigationTitle(document.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 680, minHeight: 460, idealHeight: 620)
        #elseif os(tvOS)
        .onExitCommand { dismiss() }
        #endif
        .task(id: document) {
            text = nil
            errorMessage = nil
            guard let url = Bundle.main.url(forResource: document.resourceName, withExtension: "txt") else {
                logger.error("Missing bundled document: \(document.resourceName, privacy: .public)")
                errorMessage = "This document is missing from the app. Please use the online version."
                return
            }
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                logger.error("Unable to read document: \(error.localizedDescription, privacy: .public)")
                errorMessage = "This document could not be opened. Please use the online version."
            }
        }
    }
}
