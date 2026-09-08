import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 16) {
                    BrandMark(size: 84)
                    VStack(spacing: 5) {
                        Text("neTV")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                        Text("Your television, beautifully connected.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                }

                VStack(spacing: 18) {
                    #if os(macOS)
                    TextField("Server", text: $model.server)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    #else
                    TextField("Server", text: $model.server)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    #endif

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await model.signIn(username: username, password: password) }
                    } label: {
                        HStack {
                            if model.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(model.isLoading ? "Connecting..." : "Start Watching")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(username.isEmpty || password.isEmpty || model.isLoading)
                }
                .padding(26)
                .glassCard(radius: 24)
            }
            .frame(maxWidth: 520)
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }
}
