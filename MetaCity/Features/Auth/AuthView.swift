import SwiftUI

struct AuthView: View {
    @ObservedObject var viewModel: AuthViewModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case email, password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                header

                SecondaryButton(
                    title: "Continue with Google",
                    systemImage: "g.circle.fill",
                    isFullWidth: true,
                    isLoading: viewModel.isGoogleSignInLoading,
                    isEnabled: viewModel.canUseGoogleSignIn
                ) {
                    Task { await viewModel.continueWithGoogle() }
                }

                orDivider

                VStack(spacing: Spacing.md) {
                    TextField("Email", text: $viewModel.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .appTextFieldStyle(icon: "envelope", isFocused: focusedField == .email)
                        .accessibilityLabel("Email address")

                    SecureField("Password", text: $viewModel.password)
                        .textContentType(viewModel.mode == .login ? .password : .newPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await viewModel.submit() } }
                        .appTextFieldStyle(icon: "lock", isFocused: focusedField == .password)
                        .accessibilityLabel("Password")
                }

                PrimaryButton(
                    title: viewModel.mode.submitTitle,
                    isLoading: viewModel.isLoading,
                    isEnabled: viewModel.canSubmit
                ) {
                    Task { await viewModel.submit() }
                }

                Button {
                    viewModel.toggleMode()
                } label: {
                    Text(viewModel.mode.toggleTitle)
                        .font(.metacitySubheadline)
                        .foregroundStyle(Color.metacityTextSecondary)
                        .frame(minHeight: 44)
                }

                demoHint
            }
            .padding(Spacing.xl)
            .animation(Motion.standard, value: viewModel.mode)
        }
        .background(Color.metacityBackground)
        .errorAlert($viewModel.presentedError)
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.metacityPrimary)
                .padding(.top, Spacing.xxl)
                .accessibilityHidden(true)
            Text("MetaCity")
                .font(.metacityLargeTitle)
                .foregroundStyle(Color.metacityTextPrimary)
            Text(viewModel.mode == .login ? "Welcome back" : "Create your account")
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var orDivider: some View {
        HStack(spacing: Spacing.sm) {
            Rectangle().fill(Color.metacitySeparator).frame(height: 1)
            Text("or")
                .font(.metacityCaption)
                .foregroundStyle(Color.metacityTextTertiary)
            Rectangle().fill(Color.metacitySeparator).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private var demoHint: some View {
        VStack(spacing: 2) {
            if viewModel.isUsingMockAuth {
                Text("Demo account: demo@metacity.app / password123")
                Text("\"Continue with Google\" signs in as a mocked identity — no real OAuth wired up yet")
            }
        }
        .font(.metacityCaption)
        .foregroundStyle(Color.metacityTextTertiary)
        .multilineTextAlignment(.center)
        .padding(.top, Spacing.xs)
    }
}

#Preview {
    let authRepository = MockAuthRepository()
    AuthView(
        viewModel: AuthViewModel(
            authRepository: authRepository,
            loginUseCase: LoginUseCase(authRepository: authRepository),
            session: SessionStore(authRepository: authRepository)
        )
    )
}
