import SwiftUI

enum AuthMode { case login, register, reset }

enum AuthLayoutMetrics {
    static let titleToFirstFieldSpacing: CGFloat = 32
}

enum AuthScrollPolicy {
    private static let overflowTolerance: CGFloat = 1

    static func allowsScrolling(
        contentHeight: CGFloat,
        availableHeight: CGFloat
    ) -> Bool {
        contentHeight > availableHeight + overflowTolerance
    }
}

enum AuthVerificationCodePolicy {
    static func normalizedCode(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(6))
    }

    static func shouldAdvanceToNewPassword(previous: String, current: String) -> Bool {
        previous.count < 6 && current.count == 6
    }
}

@MainActor
final class AuthSubmissionCoordinator: ObservableObject {
    @Published private(set) var isRunning = false

    func perform(
        authorize: @escaping @MainActor () async -> Bool,
        submit: @escaping @MainActor () async -> Void
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        guard await authorize(), !Task.isCancelled else { return }
        await submit()
    }
}

struct AuthView: View {
    let mode: AuthMode
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @EnvironmentObject private var usageTermsConsent: UsageTermsConsentCoordinator
    @Environment(\.locale) private var locale
    @StateObject private var submissionCoordinator = AuthSubmissionCoordinator()
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var code = ""
    @State private var invite = ""
    @State private var remember = true
    @State private var revealsPassword = false
    @State private var nextCodeAt = Date.distantPast
    @State private var contentHeight: CGFloat = 0
    @State private var passwordFocusRequested = false
    @State private var showsConsentDocument = false
    private var configurationPresentation: LoginConfigurationPresentation {
        model.configurationStatus.loginPresentation
    }
    private var authFeedbackIsSuccess: Bool {
        relevantAuthFeedback == .localized(L10nKey.registerStatusCodeSent)
            || relevantAuthFeedback == .localized(L10nKey.forgotStatusCodeSent)
            || relevantAuthFeedback == .localized(L10nKey.registerStatusSucceeded)
            || relevantAuthFeedback == .localized(L10nKey.forgotStatusResetSucceeded)
    }
    private var relevantAuthFeedback: LocalizedMessage? {
        switch (mode, model.authFeedbackKind) {
        case (.login, .login), (.register, .register),
             (.register, .registerCode), (.register, .registrationConfig),
             (.reset, .reset), (.reset, .resetCode):
            model.authMessage
        default: nil
        }
    }
    private var submitProgressKey: String? {
        switch model.authTask {
        case .login: mode == .login ? "login.action.submitting" : nil
        case .register: mode == .register ? "register.action.submitting" : nil
        case .reset: mode == .reset ? "forgot.action.resetting" : nil
        case .registerCode, .resetCode, .registrationConfig, .none: nil
        }
    }
    private var registrationConfigIsLoading: Bool {
        mode == .register && model.authTask == .registrationConfig
    }
    private var titleKey: String {
        switch mode {
        case .login: "login.action.submit"
        case .register: "register.title"
        case .reset: "forgot.title"
        }
    }
    private var submitKey: String {
        switch mode {
        case .login: "login.action.submit"
        case .register: "register.action.submit"
        case .reset: "forgot.action.reset"
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let usesCompactAuthLayout = mode != .login
            let allowsScrolling = AuthScrollPolicy.allowsScrolling(
                contentHeight: contentHeight,
                availableHeight: geometry.size.height
            )
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if mode == .login {
                            BrandHeader().padding(.bottom, 28)
                        } else {
                            Text(LocalizedStringKey(titleKey))
                                .font(.system(size: 20, weight: .bold))
                                .padding(.bottom, AuthLayoutMetrics.titleToFirstFieldSpacing)
                        }
                        BrandAuthField(titleKey: mode == .register ? "register.email.title" : mode == .reset ? "forgot.email.title" : "login.email.title", icon: "envelope", text: $email, secure: false)
                        if mode == .login {
                            NavigationLink("忘记密码") { AuthView(mode: .reset) }
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(brand.theme.emphasis)
                                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 12).padding(.bottom, 8)
                        } else if mode == .reset || mode == .register {
                            verificationCodeRow.padding(.top, 18)
                            Spacer().frame(height: mode == .register ? 12 : 18)
                        }
                        BrandAuthField(
                            titleKey: mode == .reset ? "forgot.new_password.title" : mode == .register ? "register.password.title" : "login.password.title",
                            icon: "lock",
                            text: $password,
                            secure: !revealsPassword,
                            password: true,
                            reveals: $revealsPassword,
                            fieldIdentifier: mode == .reset ? "auth.newPassword" : nil,
                            focusRequest: $passwordFocusRequested
                        )
                        if mode == .login {
                            HStack(spacing: 8) {
                                Button { remember.toggle() } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: remember ? "checkmark.square.fill" : "square").foregroundStyle(brand.theme.emphasis)
                                        Text("自动登录").font(.system(size: 12)).foregroundStyle(brand.theme.secondary)
                                    }
                                }.buttonStyle(.plain)
                                Spacer(minLength: 8)
                                NavigationLink("注册账户") { AuthView(mode: .register) }.font(.system(size: 12, weight: .semibold)).foregroundStyle(brand.theme.emphasis)
                            }.padding(.top, 14)
                        } else {
                            BrandAuthField(
                                titleKey: mode == .reset ? "forgot.confirm_password.title" : "register.confirm_password.title",
                                icon: "lock",
                                text: $confirmation,
                                secure: true,
                                fieldIdentifier: mode == .reset ? "auth.confirmNewPassword" : nil
                            )
                            .padding(.top, usesCompactAuthLayout ? 12 : 18)
                            if mode == .register {
                                BrandAuthField(titleKey: model.registration?.requiresInvitation == true ? "register.invite.title.required" : "register.invite.title.optional", icon: "gift", text: $invite, secure: false).padding(.top, 12)
                            }
                        }
                        if mode == .login || mode == .register {
                            consentRow.padding(.top, 14)
                        }
                        Button { submit() } label: {
                            HStack(spacing: 8) {
                                if submitProgressKey != nil {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(brand.theme.secondary)
                                        .accessibilityHidden(true)
                                        .accessibilityIdentifier("auth.submit.progress")
                                }
                                Text(LocalizedStringKey(submitProgressKey ?? submitKey))
                            }
                            .frame(maxWidth: .infinity)
                        }.buttonStyle(BrandButtonStyle()).padding(.top, usesCompactAuthLayout ? 18 : 24)
                            .disabled(
                                (model.offline && !allowsOfflineConsentAuthFixture)
                                    || model.busy
                                    || submissionCoordinator.isRunning
                                    || model.config == nil
                                    || (mode == .register
                                        && !allowsOfflineConsentAuthFixture
                                        && (model.registration == nil
                                            || model.registration?.requiresRecaptcha == true))
                            )
                            .accessibilityIdentifier("auth.submit")
                        if mode == .login {
                            if model.authTask != .login {
                                Group {
                                    if configurationPresentation == .configurationUnavailable {
                                        Text(LocalizedStringKey(L10nKey.loginStatusConfigFailed))
                                    } else if let feedback = relevantAuthFeedback {
                                        LocalizedMessageText(message: feedback)
                                    } else {
                                        Text(LocalizedStringKey(configurationPresentation.localizedKey))
                                    }
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(relevantAuthFeedback != nil || configurationPresentation.needsRetry
                                    ? brand.theme.error : brand.theme.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 14)
                                .accessibilityIdentifier("auth.status")
                            }
                            if configurationPresentation.needsRetry {
                                Button(LocalizedStringKey(L10nKey.loginActionRetry)) {
                                    Task { await model.retryAuthenticationConnectivity() }
                                }.font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(brand.theme.emphasis)
                                    .disabled(model.busy || model.offline)
                                    .padding(.top, 8)
                                    .accessibilityIdentifier("auth.retry")
                            }
                        } else if registrationConfigIsLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(brand.theme.emphasis)
                                    .accessibilityHidden(true)
                                Text(LocalizedStringKey(L10nKey.registerStatusLoadingConfiguration))
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(brand.theme.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                            .accessibilityIdentifier("auth.registrationConfig.loading")
                        } else if let feedback = relevantAuthFeedback {
                            LocalizedMessageText(message: feedback)
                                .font(.system(size: 12))
                                .foregroundStyle(authFeedbackIsSuccess ? brand.theme.secondary : brand.theme.error)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 14)
                                .accessibilityIdentifier("auth.feedback")
                        } else if configurationPresentation == .configurationUnavailable {
                            Text(LocalizedStringKey(L10nKey.errorConfigurationUnavailable))
                                .font(.system(size: 12))
                                .foregroundStyle(brand.theme.error)
                                .multilineTextAlignment(.center)
                                .padding(.top, 14)
                                .accessibilityIdentifier("auth.feedback")
                        }
                        if mode == .register, let rules = model.registration, rules.requiresRecaptcha {
                            Text("服务端要求网页验证码，请前往官网完成注册。").font(.system(size: 12)).foregroundStyle(brand.theme.error).padding(.top, 10)
                        }
                        if mode != .login,
                           configurationPresentation == .configurationUnavailable
                            || (mode == .register && model.registration == nil && relevantAuthFeedback != nil) {
                            Button(LocalizedStringKey(L10nKey.loginActionRetry)) {
                                Task { await model.retryAuthenticationConnectivity(registrationNeeded: mode == .register) }
                            }.font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(brand.theme.emphasis)
                                .disabled(model.busy || model.offline)
                                .padding(.top, 10)
                                .accessibilityIdentifier("auth.retry")
                        }
                    }.padding(usesCompactAuthLayout ? 22 : 28).surfaceCard().frame(maxWidth: 354)
                    if let config = brand.snapshot.config {
                        HStack(spacing: 24) {
                            if let url = config.homePageURL { Link(destination: url) { Label(LocalizedStringKey("login.website"), systemImage: "globe") } }
                            CustomerServiceNavigationLink(config: config) { Label(LocalizedStringKey("login.support"), systemImage: "headphones") }
                            if let text = config.telegramGroup, let url = URL(string: text) { Link(destination: url) { Label(LocalizedStringKey("login.community"), systemImage: "paperplane") } }
                        }.font(.system(size: 12)).foregroundStyle(brand.theme.secondary).padding(.top, usesCompactAuthLayout ? 14 : 22)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, usesCompactAuthLayout ? 14 : 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollDisabled(!allowsScrolling)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }.background(brand.theme.background).foregroundStyle(brand.theme.text)
        .navigationBarTitleDisplayMode(.inline).toolbar(mode == .login ? .hidden : .visible, for: .navigationBar)
        .navigationDestination(isPresented: $showsConsentDocument) {
            UsageTermsPrivacyView()
        }
        .task {
            if mode != .login { model.clearAuthenticationFeedback() }
            if mode == .register { await model.loadRegistration() }
        }
        .onDisappear {
            password = ""; confirmation = ""; code = ""
            passwordFocusRequested = false
            if mode != .login { model.clearAuthenticationFeedback() }
        }
        .onChange(of: code) { previous, value in
            guard mode == .register || mode == .reset else { return }
            let normalized = AuthVerificationCodePolicy.normalizedCode(value)
            if normalized != value {
                code = normalized
                return
            }
            if AuthVerificationCodePolicy.shouldAdvanceToNewPassword(
                previous: previous,
                current: normalized
            ) {
                passwordFocusRequested = true
            }
        }
    }

    private var verificationCodeRow: some View {
        HStack(spacing: 8) {
            BrandAuthField(
                titleKey: mode == .reset ? "forgot.email_code.title" : "register.email_code.title",
                icon: "envelope",
                text: $code,
                secure: false,
                keyboardType: .numberPad,
                textContentType: .oneTimeCode,
                fieldIdentifier: "auth.code"
            )
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let seconds = max(0, Int(ceil(nextCodeAt.timeIntervalSince(timeline.date))))
                let codeActionKey = mode == .reset ? "forgot.action.send_code" : "register.action.send_code"
                let retryKey = mode == .reset ? "forgot.action.retry_after %lld" : "register.action.retry_after %lld"
                let isSending = (mode == .reset && model.authTask == .resetCode)
                    || (mode == .register && model.authTask == .registerCode)
                let sendingKey = mode == .reset
                    ? "forgot.action.sending_code" : "register.action.sending_code"
                Button {
                    Task {
                        await model.sendCode(email: email, reset: mode == .reset)
                        let successKey = mode == .reset ? L10nKey.forgotStatusCodeSent : L10nKey.registerStatusCodeSent
                        if model.authMessage == .localized(successKey) {
                            nextCodeAt = Date().addingTimeInterval(60)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(brand.theme.emphasis)
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("auth.sendCode.progress")
                        }
                        Text(isSending
                            ? AppLocalization.string(sendingKey, locale: locale)
                            : seconds > 0
                                ? AppLocalization.string(
                                    retryKey,
                                    locale: locale,
                                    arguments: [Int64(seconds)]
                                )
                                : AppLocalization.string(codeActionKey, locale: locale))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(brand.theme.emphasis)
                .frame(width: 104, height: 50)
                .background(brand.theme.tint)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.plain)
                .disabled(seconds > 0 || model.busy || model.offline)
                .accessibilityIdentifier("auth.sendCode")
            }
            .frame(width: 104)
        }
    }

    private var consentRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                usageTermsConsent.setAccepted(
                    !usageTermsConsent.hasAcceptedCurrentVersion
                )
            } label: {
                Image(systemName: usageTermsConsent.hasAcceptedCurrentVersion
                    ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(brand.theme.emphasis)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LocalizedStringKey("consent.checkbox.toggle"))
            .accessibilityAddTraits(
                usageTermsConsent.hasAcceptedCurrentVersion ? .isSelected : []
            )
            .accessibilityIdentifier("auth.consent.checkbox")

            Button {
                showsConsentDocument = true
            } label: {
                (
                    Text(LocalizedStringKey("consent.checkbox.prefix"))
                        .foregroundColor(brand.theme.secondary)
                    + Text(LocalizedStringKey("consent.document.link_title"))
                        .foregroundColor(brand.theme.emphasis)
                )
                    .font(.footnote.weight(.regular))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LocalizedStringKey("consent.checkbox.statement"))
            .accessibilityIdentifier("auth.consent.document.link")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allowsOfflineConsentAuthFixture: Bool {
        #if DEBUG
        UnifiedConsentUITestFixture.allowsOfflineAuth
        #else
        false
        #endif
    }

    private func submit() {
        Task {
            await submissionCoordinator.perform(
                authorize: {
                    if mode == .reset { return true }
                    return await usageTermsConsent.authorize(
                        presenter: modalPresenter
                    )
                },
                submit: {
                    #if DEBUG
                    if UnifiedConsentUITestFixture.suppressesAuthSubmission {
                        return
                    }
                    #endif
                    switch mode {
                    case .login:
                        await model.login(
                            email: email,
                            password: password,
                            remember: remember
                        )
                    case .register:
                        await model.submitRegistration(
                            email: email,
                            password: password,
                            confirmation: confirmation,
                            code: code,
                            invite: invite
                        )
                    case .reset:
                        await model.resetPassword(
                            email: email,
                            password: password,
                            confirmation: confirmation,
                            code: code
                        )
                    }
                    if model.session != nil
                        || model.authMessage == .localized(L10nKey.registerStatusSucceeded)
                        || model.authMessage == .localized(L10nKey.forgotStatusResetSucceeded) {
                        password = ""; confirmation = ""; code = ""
                    }
                }
            )
        }
    }
}

private struct UsageTermsPrivacyView: View {
    @EnvironmentObject private var brand: BrandProvider

    private let sections: [(title: String, body: String, identifier: String)] = [
        ("consent.section.terms.title", "consent.section.terms.body", "terms"),
        ("consent.section.privacy.title", "consent.section.privacy.body", "privacy"),
        ("consent.section.vpn.title", "consent.section.vpn.body", "vpn"),
        ("consent.section.account.title", "consent.section.account.body", "account"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.identifier) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(section.title))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(brand.theme.text)
                        Text(LocalizedStringKey(section.body))
                            .font(.body)
                            .foregroundStyle(brand.theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .surfaceCard()
                    .accessibilityIdentifier(
                        "consent.document.section.\(section.identifier)"
                    )
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(brand.theme.background)
        .navigationTitle(LocalizedStringKey("consent.document.title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("consent.document")
    }
}
struct BrandAuthField: View {
    @EnvironmentObject var brand: BrandProvider
    let titleKey: String
    let icon: String
    @Binding var text: String
    let secure: Bool
    var password = false
    var reveals: Binding<Bool> = .constant(false)
    var keyboardType: UIKeyboardType? = nil
    var textContentType: UITextContentType? = nil
    var fieldIdentifier: String? = nil
    var focusRequest: Binding<Bool> = .constant(false)
    @FocusState private var focused: Bool
    private var resolvedKeyboardType: UIKeyboardType {
        keyboardType ?? (icon == "envelope" ? .emailAddress : icon == "number" ? .numberPad : .default)
    }
    private var resolvedTextContentType: UITextContentType? {
        textContentType ?? (password ? .password : icon == "envelope" ? .username : icon == "number" ? .oneTimeCode : nil)
    }
    private var resolvedFieldIdentifier: String {
        fieldIdentifier ?? (password || secure ? "auth.password" : icon == "envelope" ? "auth.email" : "auth.\(icon)")
    }
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(brand.theme.tertiary)
                .frame(width: 40)
                .accessibilityIdentifier("\(resolvedFieldIdentifier).icon")
            Group {
                if secure { SecureField(LocalizedStringKey(titleKey), text: $text, prompt: Text(LocalizedStringKey(titleKey)).font(.system(size: 15, weight: .semibold)).foregroundStyle(brand.theme.tertiary)).textContentType(.password) }
                else { TextField(LocalizedStringKey(titleKey), text: $text, prompt: Text(LocalizedStringKey(titleKey)).font(.system(size: 15, weight: .semibold)).foregroundStyle(brand.theme.tertiary)).keyboardType(resolvedKeyboardType).textContentType(resolvedTextContentType) }
            }.focused($focused).font(.system(size: 15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(resolvedFieldIdentifier)
            if password { Button { reveals.wrappedValue.toggle() } label: { Image(systemName: reveals.wrappedValue ? "eye.slash" : "eye").foregroundStyle(brand.theme.tertiary) }.frame(width: 34).accessibilityLabel(Text(LocalizedStringKey(reveals.wrappedValue ? "login.password.hide" : "login.password.show"))) }
        }
        .padding(.trailing, 10).frame(height: 50).background(brand.theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? brand.theme.accent : brand.theme.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if focused || !text.isEmpty {
                    Text(LocalizedStringKey(titleKey)).font(.system(size: 12, weight: .semibold)).foregroundStyle(brand.theme.emphasis)
                        .padding(.horizontal, 4).background(brand.theme.field).padding(.leading, 36).offset(y: -7).allowsHitTesting(false)
                }
            }
            .onChange(of: focusRequest.wrappedValue) { _, requested in
                guard requested else { return }
                focused = true
                focusRequest.wrappedValue = false
            }
    }
}
