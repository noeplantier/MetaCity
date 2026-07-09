import XCTest
@testable import MetaCity

@MainActor
final class AuthViewModelTests: XCTestCase {
    func test_submitLogin_withValidCredentials_signsIntoSession() async {
        let repository = MockAuthRepository()
        let session = SessionStore(authRepository: repository)
        let viewModel = AuthViewModel(
            authRepository: repository,
            loginUseCase: LoginUseCase(authRepository: repository),
            session: session
        )
        viewModel.email = "demo@metacity.app"
        viewModel.password = "password123"

        await viewModel.submit()

        XCTAssertNotNil(session.currentUser)
        XCTAssertEqual(session.currentUser?.email, "demo@metacity.app")
        XCTAssertNil(viewModel.presentedError)
    }

    func test_submitLogin_withWrongPassword_presentsErrorAndDoesNotSignIn() async {
        let repository = MockAuthRepository()
        let session = SessionStore(authRepository: repository)
        let viewModel = AuthViewModel(
            authRepository: repository,
            loginUseCase: LoginUseCase(authRepository: repository),
            session: session
        )
        viewModel.email = "demo@metacity.app"
        viewModel.password = "totally-wrong"

        await viewModel.submit()

        XCTAssertNil(session.currentUser)
        XCTAssertNotNil(viewModel.presentedError)
    }

    func test_continueWithGoogle_signsIntoSessionWithoutRequiringFormFields() async {
        let repository = MockAuthRepository()
        let session = SessionStore(authRepository: repository)
        let viewModel = AuthViewModel(
            authRepository: repository,
            loginUseCase: LoginUseCase(authRepository: repository),
            session: session
        )

        await viewModel.continueWithGoogle()

        XCTAssertNotNil(session.currentUser)
        XCTAssertNil(viewModel.presentedError)
        XCTAssertFalse(viewModel.isGoogleSignInLoading)
    }

    func test_canSubmit_isFalseUntilBothFieldsAreFilled() {
        let repository = MockAuthRepository()
        let session = SessionStore(authRepository: repository)
        let viewModel = AuthViewModel(
            authRepository: repository,
            loginUseCase: LoginUseCase(authRepository: repository),
            session: session
        )

        XCTAssertFalse(viewModel.canSubmit)
        viewModel.email = "demo@metacity.app"
        XCTAssertFalse(viewModel.canSubmit)
        viewModel.password = "password123"
        XCTAssertTrue(viewModel.canSubmit)
    }
}
