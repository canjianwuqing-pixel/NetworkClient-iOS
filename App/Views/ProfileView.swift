import SwiftUI
import UIKit
import WebKit

enum ProfileSignOutPresentation {
    static func request() -> GlobalModalRequest {
        GlobalModalRequest.destructive(
            title: .localized("profile.sign_out.message"),
            primaryTitle: .localized("退出登录"),
            secondaryTitle: .localized("取消")
        )
    }

    static func shouldSignOut(for choice: GlobalModalChoice) -> Bool {
        choice == .primary
    }
}

enum AccountDeletionRequestPresentation {
    static func confirmationRequest() -> GlobalModalRequest {
        .destructive(
            title: .localized("profile.account_deletion.title"),
            message: .localized("profile.account_deletion.confirm.message"),
            primaryTitle: .localized("profile.account_deletion.submit"),
            secondaryTitle: .localized("profile.action.cancel")
        )
    }

    static func successRequest() -> GlobalModalRequest {
        .result(
            style: .success,
            title: .localized("profile.account_deletion.success.title"),
            message: .localized("profile.account_deletion.success.message"),
            primaryTitle: .localized("profile.account_deletion.success.acknowledge")
        )
    }

    static func shouldSubmit(for choice: GlobalModalChoice) -> Bool {
        choice == .primary
    }
}

enum ProfileSignOutOutcome: Equatable {
    case ignored
    case alreadyRunning
    case cancelled
    case vpnDisconnectFailed
    case signOutRequested
}

@MainActor
enum ProfileSignOutFlow {
    static func complete(
        choice: GlobalModalChoice,
        isVPNConfirmedDisconnected: () -> Bool,
        disconnectVPN: () async throws -> Void,
        confirmVPNDisconnected: () async throws -> Bool,
        signOut: () async -> Void,
        reportVPNDisconnectFailure: () -> Void
    ) async -> ProfileSignOutOutcome {
        guard ProfileSignOutPresentation.shouldSignOut(for: choice) else {
            return .ignored
        }

        do {
            try Task.checkCancellation()
            if !isVPNConfirmedDisconnected() {
                try await disconnectVPN()
                try Task.checkCancellation()
                guard try await confirmVPNDisconnected() else {
                    reportVPNDisconnectFailure()
                    return .vpnDisconnectFailed
                }
            }
            try Task.checkCancellation()
            await signOut()
            return .signOutRequested
        } catch is CancellationError {
            return .cancelled
        } catch {
            reportVPNDisconnectFailure()
            return .vpnDisconnectFailed
        }
    }

    static func waitForConfirmedDisconnect(
        isConfirmed: () -> Bool,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> Bool {
        if isConfirmed() { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            if isConfirmed() { return true }
        }
        return isConfirmed()
    }
}

@MainActor
final class ProfileSignOutCoordinator: ObservableObject {
    @Published private(set) var isRunning = false

    func run(
        present: () async -> GlobalModalChoice,
        isVPNConfirmedDisconnected: () -> Bool,
        disconnectVPN: () async throws -> Void,
        confirmVPNDisconnected: () async throws -> Bool,
        signOut: () async -> Void,
        reportVPNDisconnectFailure: () -> Void
    ) async -> ProfileSignOutOutcome {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        let choice = await present()
        return await ProfileSignOutFlow.complete(
            choice: choice,
            isVPNConfirmedDisconnected: isVPNConfirmedDisconnected,
            disconnectVPN: disconnectVPN,
            confirmVPNDisconnected: confirmVPNDisconnected,
            signOut: signOut,
            reportVPNDisconnectFailure: reportVPNDisconnectFailure
        )
    }
}

enum ProfileVersionPresentation {
    static var marketingVersion: String {
        let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return value?.trimmed.nilIfEmpty ?? "--"
    }

    static func text(version: String, locale: Locale) -> String {
        AppLocalization.string(
            "profile.version.label %@",
            locale: locale,
            arguments: [version]
        )
    }

    static func currentText(locale: Locale) -> String {
        text(version: marketingVersion, locale: locale)
    }
}

enum ProfileUpdatePresentation {
    static func upToDateRequest() -> GlobalModalRequest {
        .information(
            title: .localized("profile.version.check"),
            message: .localized("profile.version.latest")
        )
    }

    static func failureRequest() -> GlobalModalRequest {
        .information(
            title: .localized("profile.version.check"),
            message: .localized("profile.version.check_failed")
        )
    }

    static func unavailableUpdateLinkRequest() -> GlobalModalRequest {
        .information(
            title: .localized("profile.version.check"),
            message: .localized("profile.version.update_link_unavailable")
        )
    }

    static func updateRequest(
        release: AppUpdateRelease,
        locale: Locale
    ) -> GlobalModalRequest {
        let versionLine = AppLocalization.string(
            "profile.version.latest_version %@",
            locale: locale,
            arguments: [release.version]
        )
        let message = release.body.isEmpty
            ? versionLine
            : versionLine + "\n\n" + release.body
        return GlobalModalRequest(
            kind: .confirmation,
            title: .localized("profile.version.new_version"),
            message: .verbatim(message),
            primary: GlobalModalButton(
                title: .localized("profile.version.update_now"),
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: .localized("profile.version.later"),
                role: .cancel,
                identifier: "global.modal.secondary"
            ),
            allowsBackdropDismiss: true
        )
    }

    static func validatedUpdateTarget(
        for release: AppUpdateRelease,
        environment: AppUpdateURLPolicy.Environment = .current
    ) -> URL? {
        AppUpdateURLPolicy.updateTargetURL(
            release.updateURL?.absoluteString,
            environment: environment
        )
    }
}

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: MinimalVPNController
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @Environment(\.locale) private var locale
    @StateObject private var signOutCoordinator = ProfileSignOutCoordinator()
    @State private var updateCheckTask: Task<Void, Never>?
    var body: some View {
        BrandScreen {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        BrandLogo(size: 52, radius: 16)
                        VStack(alignment: .leading, spacing: 7) {
                            if let email = model.session?.email { Text(verbatim: email).font(.system(size: 17, weight: .bold)).lineLimit(1).truncationMode(.middle) }
                            else { Text(LocalizedStringKey("profile.summary.signed_out")).font(.system(size: 17, weight: .bold)) }
                            Text(AppLocalization.string(
                                "profile.summary.balance %@",
                                locale: locale,
                                arguments: [model.session?.balanceCents.map { CommerceView.price($0, locale: locale) } ?? "--"]
                            )).font(.system(size: 12)).foregroundStyle(brand.theme.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(14).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading).surfaceCard()
                    ProfileMenuCard {
                        ForEach(Array(ProfileMenuStructure.items.enumerated()), id: \.element.id) { index, item in
                            if item == .checkUpdate {
                                Button(action: startUpdateCheck) {
                                    ProfileMenuRow(
                                        icon: item.icon,
                                        titleKey: item.titleKey,
                                        tint: item.tint,
                                        showsProgress: model.isCheckingForUpdates
                                    )
                                }
                                .disabled(model.isCheckingForUpdates || updateCheckTask != nil)
                                .accessibilityIdentifier(item.accessibilityIdentifier)
                            } else {
                                NavigationLink { destination(for: item) } label: {
                                    ProfileMenuRow(
                                        icon: item.icon,
                                        titleKey: item.titleKey,
                                        tint: item.tint
                                    )
                                }
                                .accessibilityIdentifier(item.accessibilityIdentifier)
                            }
                            if index < ProfileMenuStructure.items.count - 1 {
                                ProfileMenuSeparator()
                            }
                        }
                        if model.session != nil {
                            ProfileMenuSeparator()
                            Button {
                                Task { @MainActor in
                                    _ = await signOutCoordinator.run(
                                        present: {
                                            await modalPresenter.present(
                                                ProfileSignOutPresentation.request()
                                            )
                                        },
                                        isVPNConfirmedDisconnected: {
                                            vpn.state == .disconnected && vpn.operation == .idle
                                        },
                                        disconnectVPN: {
                                            try await vpn.disconnect()
                                        },
                                        confirmVPNDisconnected: {
                                            try await ProfileSignOutFlow.waitForConfirmedDisconnect {
                                                vpn.state == .disconnected && vpn.operation == .idle
                                            }
                                        },
                                        signOut: {
                                            await model.signOut()
                                        },
                                        reportVPNDisconnectFailure: {
                                            model.message = .localized(
                                                "profile.sign_out.vpn_disconnect_failed"
                                            )
                                            SafeLog.warning(
                                                "[Login] sign-out blocked reason=vpn_disconnect_unconfirmed"
                                            )
                                        }
                                    )
                                }
                            } label: {
                                ProfileMenuRow(
                                    icon: "ProfileSignOutIcon",
                                    titleKey: "退出登录",
                                    tint: "error",
                                    showsChevron: true
                                )
                            }
                            .disabled(model.busy || signOutCoordinator.isRunning)
                            .accessibilityIdentifier("profile.signout")
                            .buttonStyle(.plain)
                        }
                    }
                        Spacer(minLength: 16)
                        Text(ProfileVersionPresentation.currentText(locale: locale))
                            .font(.footnote)
                            .foregroundStyle(brand.theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("profile.marketing-version")
                            .padding(.bottom, 4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onDisappear {
            updateCheckTask?.cancel()
            updateCheckTask = nil
            model.cancelAppUpdateCheck()
        }
    }
    @ViewBuilder
    private func destination(for item: ProfileMenuItem) -> some View {
        switch item {
        case .orders:
            if model.session == nil { AccountRequiredView() } else { OrdersView() }
        case .invitations: InvitationsView()
        case .traffic: TrafficSummaryView()
        case .changePassword: ChangePasswordView()
        case .settings: SettingsView()
        case .checkUpdate: EmptyView()
        case .aboutSupport: AboutSupportView()
        case .deleteAccount:
            if model.session == nil { AccountRequiredView() } else { AccountDeletionRequestView() }
        }
    }
    private func startUpdateCheck() {
        guard updateCheckTask == nil, !model.isCheckingForUpdates else { return }
        updateCheckTask = Task { @MainActor in
            defer { updateCheckTask = nil }
            do {
                let outcome = try await model.checkForUpdates(
                    currentVersion: ProfileVersionPresentation.marketingVersion
                )
                try Task.checkCancellation()
                switch outcome {
                case .upToDate:
                    _ = await modalPresenter.present(
                        ProfileUpdatePresentation.upToDateRequest()
                    )
                case let .updateAvailable(release):
                    let choice = await modalPresenter.present(
                        ProfileUpdatePresentation.updateRequest(
                            release: release,
                            locale: locale
                        )
                    )
                    try Task.checkCancellation()
                    if choice == .primary {
                        guard let target = ProfileUpdatePresentation.validatedUpdateTarget(
                            for: release
                        ) else {
                            _ = await modalPresenter.present(
                                ProfileUpdatePresentation.unavailableUpdateLinkRequest()
                            )
                            return
                        }
                        if await UIApplication.shared.open(target) {
                            model.recordAppUpdatePageOpened()
                        } else {
                            _ = await modalPresenter.present(
                                ProfileUpdatePresentation.unavailableUpdateLinkRequest()
                            )
                        }
                    }
                }
            } catch is CancellationError {
                // A dismissed owner or changed brand is intentionally silent.
            } catch {
                guard !Task.isCancelled else { return }
                _ = await modalPresenter.present(ProfileUpdatePresentation.failureRequest())
            }
        }
    }
}

enum ProfileMenuAppearance {
    static let customIconSize: CGFloat = 21
    static let systemIconSize: CGFloat = 15
    static let iconContainerWidth: CGFloat = 34
    static let titleFontSize: CGFloat = 14
    static let detailFontSize: CGFloat = 12
    static let detailTrailingPadding: CGFloat = 8
    static let chevronSize: CGFloat = 12
    static let progressSize: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let minimumRowHeight: CGFloat = 56
    static let dividerLeadingInset: CGFloat = 50
    static let dividerTrailingInset: CGFloat = 16
}

struct ProfileMenuRow: View {
    @EnvironmentObject private var brand: BrandProvider

    let icon: String
    let titleKey: String
    let tint: String
    var detailKey: String?
    var showsChevron = true
    var showsProgress = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if icon.hasPrefix("Profile") {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: ProfileMenuAppearance.customIconSize,
                            height: ProfileMenuAppearance.customIconSize
                        )
                } else {
                    Image(systemName: icon)
                        .font(.system(
                            size: ProfileMenuAppearance.systemIconSize,
                            weight: .semibold
                        ))
                }
            }
            .foregroundStyle(brand.theme.color(tint))
            .frame(width: ProfileMenuAppearance.iconContainerWidth, alignment: .leading)

            Text(LocalizedStringKey(titleKey))
                .font(.system(size: ProfileMenuAppearance.titleFontSize, weight: .medium))
                .foregroundStyle(tint == "error" ? brand.theme.error : brand.theme.text)

            Spacer()

            if let detailKey {
                Text(LocalizedStringKey(detailKey))
                    .font(.system(size: ProfileMenuAppearance.detailFontSize))
                    .foregroundStyle(brand.theme.tertiary)
                    .padding(.trailing, ProfileMenuAppearance.detailTrailingPadding)
            }
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        width: ProfileMenuAppearance.progressSize,
                        height: ProfileMenuAppearance.progressSize
                    )
                    .accessibilityIdentifier("profile.update.progress")
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(
                        size: ProfileMenuAppearance.chevronSize,
                        weight: .semibold
                    ))
                    .foregroundStyle(brand.theme.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ProfileMenuAppearance.horizontalPadding)
        .padding(.vertical, ProfileMenuAppearance.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: ProfileMenuAppearance.minimumRowHeight)
        .contentShape(Rectangle())
    }
}

struct ProfileMenuSeparator: View {
    @EnvironmentObject private var brand: BrandProvider

    var body: some View {
        Rectangle()
            .fill(brand.theme.divider)
            .frame(height: 1)
            .padding(.leading, ProfileMenuAppearance.dividerLeadingInset)
            .padding(.trailing, ProfileMenuAppearance.dividerTrailingInset)
    }
}

struct ProfileMenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .surfaceCard()
    }
}

enum ProfileMenuItem: String, CaseIterable, Identifiable {
    case orders, invitations, traffic, changePassword, settings, checkUpdate, aboutSupport
    case deleteAccount

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .orders: "profile.menu.orders"
        case .invitations: "profile.menu.invite_friends"
        case .traffic: "profile.menu.traffic_details"
        case .changePassword: "profile.menu.change_password"
        case .settings: "profile.menu.general_settings"
        case .checkUpdate: "profile.version.check"
        case .aboutSupport: "profile.menu.about_support"
        case .deleteAccount: "profile.account_deletion.title"
        }
    }
    var icon: String {
        switch self {
        case .orders: "ProfileOrderIcon"
        case .invitations: "ProfileInviteIcon"
        case .traffic: "chart.bar.xaxis"
        case .changePassword: "ProfilePasswordIcon"
        case .settings: "slider.horizontal.3"
        case .checkUpdate: "arrow.clockwise"
        case .aboutSupport: "ProfileVersionIcon"
        case .deleteAccount: "person.crop.circle.badge.minus"
        }
    }
    var tint: String {
        switch self {
        case .orders: "support"
        case .invitations: "warning"
        case .traffic, .settings, .checkUpdate, .aboutSupport: "emphasis"
        case .changePassword: "success"
        case .deleteAccount: "error"
        }
    }
    var accessibilityIdentifier: String { "profile.\(rawValue)" }
}

enum ProfileMenuStructure {
    static let items = ProfileMenuItem.allCases
    static let finalOrder = items.map(\.rawValue) + ["signout"]
}

struct AccountDeletionRequestView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @State private var submissionTask: Task<Void, Never>?

    private var isSubmitting: Bool {
        if case .submitting = model.accountDeletionRequestState { return true }
        return false
    }

    var body: some View {
        BrandScreen {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        explanationRow(
                            icon: "person.crop.circle.badge.minus",
                            key: "profile.account_deletion.description.request"
                        )
                        explanationRow(
                            icon: "clock",
                            key: "profile.account_deletion.description.processing"
                        )
                        explanationRow(
                            icon: "exclamationmark.triangle",
                            key: "profile.account_deletion.description.irreversible"
                        )
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard()

                    if case let .failed(message) = model.accountDeletionRequestState {
                        LocalizedMessageText(message: message)
                            .font(.footnote)
                            .foregroundStyle(brand.theme.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("account-deletion.error")
                    }

                    Button(action: startSubmission) {
                        HStack(spacing: 8) {
                            if isSubmitting { ProgressView().controlSize(.small) }
                            Text(LocalizedStringKey(isSubmitting
                                ? "profile.account_deletion.submitting"
                                : "profile.account_deletion.submit"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(isSubmitting || submissionTask != nil)
                    .accessibilityIdentifier("account-deletion.submit")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle(LocalizedStringKey("profile.account_deletion.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: ProfileMenuItem.deleteAccount.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(brand.theme.error)
                        .accessibilityIdentifier("account-deletion.title.icon")
                    Text(LocalizedStringKey(ProfileMenuItem.deleteAccount.titleKey))
                        .font(.headline)
                }
            }
        }
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            model.clearAccountDeletionRequestFeedback()
        }
    }

    private func explanationRow(icon: String, key: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(brand.theme.error)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(key))
                .font(.subheadline)
                .foregroundStyle(brand.theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startSubmission() {
        guard submissionTask == nil, !isSubmitting else { return }
        submissionTask = Task { @MainActor in
            defer { submissionTask = nil }
            let choice = await modalPresenter.present(
                AccountDeletionRequestPresentation.confirmationRequest()
            )
            guard !Task.isCancelled,
                  AccountDeletionRequestPresentation.shouldSubmit(for: choice),
                  await model.requestAccountDeletion(),
                  !Task.isCancelled else { return }
            _ = await modalPresenter.present(
                AccountDeletionRequestPresentation.successRequest()
            )
        }
    }
}

enum ChangePasswordSuccessPresentation {
    static func request() -> GlobalModalRequest {
        GlobalModalRequest.result(
            style: .success,
            title: .localized("profile.change_password.success"),
            primaryTitle: .localized("确定")
        )
    }

    static func shouldInvalidateSession(for choice: GlobalModalChoice) -> Bool {
        choice == .primary
    }
}

enum ChangePasswordCompletionOutcome: Equatable {
    case ignored
    case stale
    case completed(storageCleared: Bool, vpnDisconnectFailed: Bool)
}

@MainActor
enum ChangePasswordCompletionFlow {
    static func complete(
        choice: GlobalModalChoice,
        vpnIsActive: Bool,
        invalidateSession: () async -> PasswordChangeSessionInvalidationOutcome,
        disconnectVPN: () async throws -> Void,
        reportVPNDisconnectFailure: () -> Void
    ) async -> ChangePasswordCompletionOutcome {
        guard ChangePasswordSuccessPresentation.shouldInvalidateSession(for: choice) else {
            return .ignored
        }
        guard case let .invalidated(storageCleared) = await invalidateSession() else {
            return .stale
        }
        guard vpnIsActive else {
            return .completed(storageCleared: storageCleared, vpnDisconnectFailed: false)
        }
        do {
            try await disconnectVPN()
            return .completed(storageCleared: storageCleared, vpnDisconnectFailed: false)
        } catch {
            reportVPNDisconnectFailure()
            return .completed(storageCleared: storageCleared, vpnDisconnectFailed: true)
        }
    }
}

enum ChangePasswordAppearance {
    static let titleIconSize: CGFloat = 19
    static let contentMaxWidth = LoginAppearance.contentMaxWidth
    static let contentHorizontalPadding: CGFloat = 20
    static let contentVerticalPadding: CGFloat = 18
    static let fieldSpacing: CGFloat = 12
    static let buttonTopSpacing: CGFloat = 18

    static let fieldHeight = LoginAppearance.fieldHeight
    static let fieldCornerRadius = LoginAppearance.fieldCornerRadius
    static let fieldIconSize = LoginAppearance.fieldIconSize
    static let fieldBorderWidth = LoginAppearance.fieldBorderWidth
    static let visibilityIconSize = LoginAppearance.passwordVisibilityIconSize
    static let visibilityButtonSize = LoginAppearance.passwordVisibilityButtonSize
}

struct ChangePasswordView: View {
    private enum Field: Hashable { case current, new, confirmation }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @EnvironmentObject private var vpn: MinimalVPNController
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var revealCurrent = false
    @State private var revealNew = false
    @State private var revealConfirmation = false
    @FocusState private var focusedField: Field?

    private var isSubmitting: Bool {
        if case .submitting = model.changePasswordState { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: ChangePasswordAppearance.fieldSpacing) {
                    passwordField(
                        "profile.change_password.current_password",
                        text: $currentPassword,
                        revealed: $revealCurrent,
                        field: .current,
                        contentType: .password
                    )
                    passwordField(
                        "profile.change_password.new_password",
                        text: $newPassword,
                        revealed: $revealNew,
                        field: .new,
                        contentType: .newPassword
                    )
                    passwordField(
                        "profile.change_password.confirm_new_password",
                        text: $confirmation,
                        revealed: $revealConfirmation,
                        field: .confirmation,
                        contentType: .newPassword
                    )
                }

                if case let .failed(message) = model.changePasswordState {
                    LocalizedMessageText(message: message)
                        .font(.system(size: 12))
                        .foregroundStyle(brand.theme.error)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                        .accessibilityIdentifier("change-password.error")
                }

                Button {
                    focusedField = nil
                    Task {
                        let changed = await model.changePassword(
                            currentPassword: currentPassword,
                            newPassword: newPassword,
                            confirmation: confirmation
                        )
                        guard changed else { return }
                        let choice = await modalPresenter.present(
                            ChangePasswordSuccessPresentation.request()
                        )
                        _ = await ChangePasswordCompletionFlow.complete(
                            choice: choice,
                            vpnIsActive: vpn.state != .disconnected,
                            invalidateSession: {
                                await model.invalidateSessionAfterPasswordChange()
                            },
                            disconnectVPN: {
                                try await vpn.disconnect()
                            },
                            reportVPNDisconnectFailure: {
                                model.reportPasswordChangeVPNDisconnectFailure()
                            }
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().controlSize(.small) }
                        Text(LocalizedStringKey(isSubmitting
                            ? "profile.change_password.submitting"
                            : "profile.change_password.submit"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
                .padding(.top, ChangePasswordAppearance.buttonTopSpacing)
                .disabled(isSubmitting)
                .accessibilityIdentifier("change-password.submit")
            }
            .padding(.horizontal, ChangePasswordAppearance.contentHorizontalPadding)
            .padding(.vertical, ChangePasswordAppearance.contentVerticalPadding)
            .frame(maxWidth: ChangePasswordAppearance.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(brand.theme.background)
        .navigationTitle(LocalizedStringKey("profile.menu.change_password"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(ProfileMenuItem.changePassword.icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: ChangePasswordAppearance.titleIconSize,
                            height: ChangePasswordAppearance.titleIconSize
                        )
                        .foregroundStyle(brand.theme.color(ProfileMenuItem.changePassword.tint))
                        .accessibilityIdentifier("change-password.title.icon")
                    Text(LocalizedStringKey(ProfileMenuItem.changePassword.titleKey))
                        .font(.headline)
                }
            }
        }
        .onChange(of: currentPassword) { _, _ in model.clearChangePasswordFeedback() }
        .onChange(of: newPassword) { _, _ in model.clearChangePasswordFeedback() }
        .onChange(of: confirmation) { _, _ in model.clearChangePasswordFeedback() }
        .onDisappear {
            currentPassword = ""
            newPassword = ""
            confirmation = ""
            model.clearChangePasswordFeedback()
        }
    }

    private func passwordField(
        _ titleKey: String,
        text: Binding<String>,
        revealed: Binding<Bool>,
        field: Field,
        contentType: UITextContentType
    ) -> some View {
        let identifier = fieldIdentifier(field)
        return HStack(spacing: 0) {
            Image(systemName: "lock")
                .font(.system(size: ChangePasswordAppearance.fieldIconSize))
                .foregroundStyle(brand.theme.tertiary)
                .frame(width: 40)
                .accessibilityIdentifier("\(identifier).icon")
            Group {
                if revealed.wrappedValue {
                    TextField(
                        LocalizedStringKey(titleKey),
                        text: text,
                        prompt: fieldPrompt(titleKey)
                    )
                } else {
                    SecureField(
                        LocalizedStringKey(titleKey),
                        text: text,
                        prompt: fieldPrompt(titleKey)
                    )
                }
            }
            .font(.system(size: 15))
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: field)
            .accessibilityIdentifier(identifier)
            .submitLabel(field == .confirmation ? .done : .next)
            .onSubmit {
                switch field {
                case .current: focusedField = .new
                case .new: focusedField = .confirmation
                case .confirmation: focusedField = nil
                }
            }
            Button { revealed.wrappedValue.toggle() } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: ChangePasswordAppearance.visibilityIconSize))
                    .foregroundStyle(brand.theme.tertiary)
            }
            .frame(width: ChangePasswordAppearance.visibilityButtonSize)
            .buttonStyle(.plain)
            .accessibilityLabel(LocalizedStringKey(revealed.wrappedValue
                ? "login.password.hide" : "login.password.show"))
            .accessibilityIdentifier("\(identifier).visibility")
        }
        .padding(.trailing, 10)
        .frame(height: ChangePasswordAppearance.fieldHeight)
        .background(brand.theme.field)
        .clipShape(RoundedRectangle(cornerRadius: ChangePasswordAppearance.fieldCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ChangePasswordAppearance.fieldCornerRadius)
                .stroke(
                    focusedField == field ? brand.theme.accent : brand.theme.border,
                    lineWidth: ChangePasswordAppearance.fieldBorderWidth
                )
        }
        .overlay(alignment: .topLeading) {
            if focusedField == field || !text.wrappedValue.isEmpty {
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(brand.theme.emphasis)
                    .padding(.horizontal, 4)
                    .background(brand.theme.field)
                    .padding(.leading, 36)
                    .offset(y: -7)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fieldPrompt(_ titleKey: String) -> Text {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(brand.theme.tertiary)
    }

    private func fieldIdentifier(_ field: Field) -> String {
        switch field {
        case .current: "change-password.current"
        case .new: "change-password.new"
        case .confirmation: "change-password.confirmation"
        }
    }
}

enum InvitationsAppearance {
    static let pageSpacing: CGFloat = 10
    static let titleIconSize: CGFloat = 19
    static let actionIconSize: CGFloat = 17
    static let minimumTapSize: CGFloat = 44
}

struct InvitationsView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var copiedCodeID: Int?

    private var isRefreshingInvitations: Bool {
        RetainedContentLoadingPresentation.showsRefreshIndicator(
            isLoading: model.invitationsLoadState.isLoading,
            hasContent: model.invitations != nil
        ) && !model.invitationActionInProgress
    }

    var body: some View {
        Group {
            if model.session == nil { AccountRequiredView() }
            else {
                invitationsContent
            }
        }
        .navigationTitle(LocalizedStringKey("profile.menu.invite_friends"))
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(ProfileMenuItem.invitations.icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: InvitationsAppearance.titleIconSize,
                            height: InvitationsAppearance.titleIconSize
                        )
                        .foregroundStyle(brand.theme.color(ProfileMenuItem.invitations.tint))
                    Text(LocalizedStringKey("profile.menu.invite_friends"))
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                RefreshToolbarButton(
                    isRefreshing: isRefreshingInvitations,
                    isDisabled: model.busy
                        || model.invitationActionInProgress
                        || model.invitationsLoadState.isLoading,
                    labelKey: "profile.invites.refresh",
                    identifier: "profile.invites.refresh"
                ) {
                    Task { await model.loadInvitations() }
                }
            }
        }
        .task { await model.loadInvitationsIfNeeded() }
        .onChange(of: model.busy) { _, busy in
            guard !busy else { return }
            Task { await model.loadInvitationsIfNeeded() }
        }
    }

    private var invitationsContent: some View {
        VStack(spacing: InvitationsAppearance.pageSpacing) {
            if let info = model.invitations {
                statisticsCard(info)
                invitationCodesCard(info)
            } else {
                initialState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(brand.theme.background)
    }

    private func statisticsCard(_ info: ProfileInviteInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey("profile.invites.statistics"))
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 11) {
                    statistic(
                        "profile.invites.invited_count",
                        value: "\(info.registeredCount)"
                    )
                    statistic(
                        "profile.invites.total_commission",
                        value: CommerceView.price(info.validCommissionCents, locale: locale)
                    )
                    statistic(
                        "profile.invites.available_commission",
                        value: CommerceView.price(info.availableCommissionCents, locale: locale),
                        emphasized: true
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 11) {
                    statistic(
                        "profile.invites.commission_rate",
                        value: "\(info.commissionRate)%",
                        emphasized: true
                    )
                    statistic(
                        "profile.invites.pending_commission",
                        value: CommerceView.price(info.pendingCommissionCents, locale: locale)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .surfaceCard()
    }

    private func statistic(
        _ titleKey: String,
        value: String,
        emphasized: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .font(.footnote)
                .foregroundStyle(brand.theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(verbatim: value)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(emphasized ? brand.theme.emphasis : brand.theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    private var invitationCodesHeader: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey("profile.invites.codes"))
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button {
                Task { await model.generateInviteCode() }
            } label: {
                HStack(spacing: 6) {
                    if model.invitationActionInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.system(size: InvitationsAppearance.actionIconSize))
                    }
                    Text(LocalizedStringKey(
                        model.invitationActionInProgress
                            ? "profile.invites.generating"
                            : "profile.invites.generate"
                    ))
                    .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(brand.theme.emphasis)
                .frame(minHeight: InvitationsAppearance.minimumTapSize)
            }
            .buttonStyle(.plain)
            .disabled(model.invitationActionInProgress || model.busy)
            .accessibilityIdentifier("profile.invites.generate")
        }
        .frame(minHeight: InvitationsAppearance.minimumTapSize)
    }

    private func invitationCodesCard(_ info: ProfileInviteInfo) -> some View {
        VStack(spacing: 0) {
            invitationCodesHeader
                .padding(.horizontal, 14)
            if let feedback = model.invitationFeedback {
                LocalizedMessageText(message: feedback)
                    .font(.footnote)
                    .foregroundStyle(brand.theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let failure = model.invitationsLoadState.failureMessage {
                compactFailure(failure)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Rectangle()
                .fill(brand.theme.divider)
                .frame(height: 1)
                .padding(.horizontal, 14)
            invitationCodesRegion(info)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .surfaceCard()
    }

    private func invitationCodesRegion(_ info: ProfileInviteInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if info.codes.isEmpty {
                    Text(LocalizedStringKey("profile.invites.no_codes"))
                        .font(.subheadline)
                        .foregroundStyle(brand.theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 58)
                } else {
                    ForEach(Array(info.codes.enumerated()), id: \.element.id) { index, code in
                        invitationCodeRow(code)
                        if index < info.codes.count - 1 {
                            Rectangle()
                                .fill(brand.theme.divider)
                                .frame(height: 1)
                                .padding(.leading, 14)
                        }
                    }
                    if info.codes.allSatisfy({ inviteURL(for: $0) == nil }) {
                        Text(LocalizedStringKey("profile.invites.link_unavailable"))
                            .font(.footnote)
                            .foregroundStyle(brand.theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("profile.invites.codes.scroll")
    }

    private func invitationCodeRow(_ code: ProfileInviteCode) -> some View {
        let url = inviteURL(for: code)
        return HStack(spacing: 4) {
            Text(verbatim: code.code)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            copyButton(code: code, url: url)
            shareButton(code: code, url: url)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 52)
    }

    private func copyButton(code: ProfileInviteCode, url: URL?) -> some View {
        Button {
            guard let url else { return }
            UIPasteboard.general.string = url.absoluteString
            copiedCodeID = code.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if copiedCodeID == code.id { copiedCodeID = nil }
            }
        } label: {
            Image(systemName: copiedCodeID == code.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: InvitationsAppearance.actionIconSize))
                .frame(
                    width: InvitationsAppearance.minimumTapSize,
                    height: InvitationsAppearance.minimumTapSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(brand.theme.emphasis)
        .disabled(url == nil)
        .accessibilityLabel(LocalizedStringKey(
            copiedCodeID == code.id ? "profile.invites.copied" : "profile.invites.copy_link"
        ))
        .accessibilityIdentifier("profile.invites.copy.\(code.id)")
    }

    @ViewBuilder
    private func shareButton(code: ProfileInviteCode, url: URL?) -> some View {
        if let url {
            ShareLink(item: url) { shareIcon }
                .buttonStyle(.plain)
                .foregroundStyle(brand.theme.emphasis)
                .accessibilityLabel(LocalizedStringKey("profile.invites.share_link"))
                .accessibilityIdentifier("profile.invites.share.\(code.id)")
        } else {
            Button {} label: { shareIcon }
                .buttonStyle(.plain)
                .foregroundStyle(brand.theme.emphasis)
                .disabled(true)
                .accessibilityLabel(LocalizedStringKey("profile.invites.share_link"))
                .accessibilityIdentifier("profile.invites.share.\(code.id)")
        }
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: InvitationsAppearance.actionIconSize))
            .frame(
                width: InvitationsAppearance.minimumTapSize,
                height: InvitationsAppearance.minimumTapSize
            )
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var initialState: some View {
        if model.invitationsLoadState.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text(LocalizedStringKey("profile.invites.loading"))
                    .font(.subheadline)
                    .foregroundStyle(brand.theme.secondary)
            }
        } else if let failure = model.invitationsLoadState.failureMessage {
            compactFailure(failure)
                .padding(14)
                .surfaceCard()
        } else {
            Text(LocalizedStringKey("profile.invites.not_loaded"))
                .font(.subheadline)
                .foregroundStyle(brand.theme.secondary)
        }
    }

    private func compactFailure(_ failure: LocalizedMessage) -> some View {
        HStack(spacing: 10) {
            LocalizedMessageText(message: failure)
                .font(.footnote)
                .foregroundStyle(brand.theme.error)
            Spacer(minLength: 8)
            Button(LocalizedStringKey("profile.invites.retry")) {
                Task { await model.loadInvitations() }
            }
            .font(.footnote.weight(.semibold))
            .disabled(model.busy)
        }
    }

    private func inviteURL(for code: ProfileInviteCode) -> URL? {
        ProfileInviteLinkBuilder.url(inviteLink: model.config?.inviteLink, code: code.code)
    }
}

@MainActor
final class CustomerServicePerformanceTrace {
    private let operationID = UUID().uuidString.prefix(8)
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var identitySummary = "pending"
    private var redirectCount = 0

    init(event: String = "navigation") {
        record(stage: "T0", event: event)
    }

    func resolved(_ identity: CustomerServiceIdentity?) {
        identitySummary = identity?.safeSummary ?? "unavailable"
        record(stage: "T1", event: "resolver-complete")
    }

    func record(stage: String, event: String, detail: String? = nil) {
        #if DEBUG
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let suffix = detail.map { " \($0)" } ?? ""
        SafeLog.info(
            "[SupportPerformance] op=\(operationID) identity=\(identitySummary) "
                + "stage=\(stage) event=\(event) elapsedMS=\(elapsedMS)\(suffix)"
        )
        #endif
    }

    func recordRedirect() {
        redirectCount += 1
        record(stage: "redirect", event: "server-redirect", detail: "count=\(redirectCount)")
    }
}

private struct CustomerServiceNavigationSession {
    let service: EffectiveCustomerService
    let identity: CustomerServiceIdentity?
    let trace: CustomerServicePerformanceTrace
}

struct CustomerServiceNavigationLink<Label: View>: View {
    @EnvironmentObject private var model: AppModel
    let config: AppConfig?
    @ViewBuilder let label: () -> Label
    @State private var session: CustomerServiceNavigationSession?
    @State private var isPresented = false

    var body: some View {
        Button {
            let trace = CustomerServicePerformanceTrace(event: "support-tap")
            let service = CustomerServiceResolver.resolve(config)
            let identity = CustomerServiceResolver.identity(
                for: service,
                brandScope: config?.appName ?? "",
                accountScope: CustomerServiceResolver.accountScope(for: model.session)
            )
            trace.resolved(identity)
            session = CustomerServiceNavigationSession(
                service: service,
                identity: identity,
                trace: trace
            )
            isPresented = true
        } label: {
            label()
        }
        .navigationDestination(isPresented: $isPresented) {
            if let session {
                CustomerServiceView(
                    service: session.service,
                    identity: session.identity,
                    trace: session.trace
                )
            }
        }
    }
}

@MainActor
enum CustomerServicePersistentStoreRetention {
    static let maximumStoreCount = 8

    static func updatedHistory(_ history: [UUID], using identifier: UUID) -> [UUID] {
        var ordered: [UUID] = []
        for candidate in history where candidate != identifier && !ordered.contains(candidate) {
            ordered.append(candidate)
        }
        ordered.append(identifier)
        return ordered
    }

    static func expirationCandidates(
        in history: [UUID],
        limit: Int = maximumStoreCount
    ) -> [UUID] {
        guard limit > 0, history.count > limit else { return [] }
        return Array(history.prefix(history.count - limit))
    }
}

@MainActor
final class CustomerServicePersistentStoreRegistry {
    static let shared = CustomerServicePersistentStoreRegistry()

    private let defaults: UserDefaults
    private let storageKey = "customer-service.website-data-stores.v1"
    private var removalInFlight: Set<UUID> = []
    private var activeIdentifier: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordUse(of identifier: UUID) {
        activeIdentifier = identifier
        let history = CustomerServicePersistentStoreRetention.updatedHistory(
            storedIdentifiers(),
            using: identifier
        )
        store(history)
        removeExpiredStoresIfNeeded()
    }

    private func removeExpiredStoresIfNeeded() {
        let candidates = CustomerServicePersistentStoreRetention.expirationCandidates(
            in: storedIdentifiers()
        )
        for identifier in candidates
        where identifier != activeIdentifier && !removalInFlight.contains(identifier) {
            removalInFlight.insert(identifier)
            WKWebsiteDataStore.remove(forIdentifier: identifier) { [weak self] error in
                guard let self else { return }
                self.removalInFlight.remove(identifier)
                guard error == nil else {
                    #if DEBUG
                    SafeLog.info("[SupportPerformance] event=data-store-cleanup-deferred")
                    #endif
                    return
                }
                var history = self.storedIdentifiers()
                history.removeAll { $0 == identifier }
                self.store(history)
                self.removeExpiredStoresIfNeeded()
            }
        }
    }

    private func storedIdentifiers() -> [UUID] {
        (defaults.stringArray(forKey: storageKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func store(_ identifiers: [UUID]) {
        defaults.set(identifiers.map(\.uuidString), forKey: storageKey)
    }
}

@MainActor
final class CustomerServiceWebViewPool: NSObject {
    struct Lease {
        let webView: WKWebView
        let reused: Bool
        let shouldLoad: Bool
    }

    static let shared = CustomerServiceWebViewPool()

    private struct Entry {
        let identity: CustomerServiceIdentity
        let webView: WKWebView
    }
    private var entry: Entry?

    static func configuration(for identity: CustomerServiceIdentity) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: identity.dataStoreIdentifier
        )
        return configuration
    }

    init(observesMemoryWarnings: Bool = true) {
        super.init()
        if observesMemoryWarnings {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }
    }

    func acquire(
        identity: CustomerServiceIdentity,
        create: () -> WKWebView
    ) -> Lease {
        if let entry, entry.identity == identity {
            // The previous SwiftUI host has already released this view after
            // navigation pop. Detach defensively before attaching to a new host.
            entry.webView.removeFromSuperview()
            return Lease(webView: entry.webView, reused: true, shouldLoad: false)
        }

        let webView = create()
        entry = Entry(identity: identity, webView: webView)
        CustomerServicePersistentStoreRegistry.shared.recordUse(
            of: identity.dataStoreIdentifier
        )
        return Lease(webView: webView, reused: false, shouldLoad: true)
    }

    func invalidate(
        identity: CustomerServiceIdentity,
        matching webView: WKWebView? = nil
    ) {
        guard let entry, entry.identity == identity else { return }
        if let webView, entry.webView !== webView { return }
        self.entry = nil
    }

    func removeAll() {
        entry = nil
    }

    @objc private func handleMemoryWarning() {
        removeAll()
    }
}

struct CustomerServiceView: View {
    let service: EffectiveCustomerService
    let identity: CustomerServiceIdentity?
    @State private var trace: CustomerServicePerformanceTrace
    @State private var loadFailed = false
    @State private var loadGeneration = UUID()

    init(
        service: EffectiveCustomerService,
        identity: CustomerServiceIdentity?,
        trace: CustomerServicePerformanceTrace
    ) {
        self.service = service
        self.identity = identity
        _trace = State(initialValue: trace)
    }

    var body: some View {
        Group {
            switch service {
            case .url, .html:
                if loadFailed, let identity {
                    ContentUnavailableView {
                        Label(LocalizedStringKey("support.load_failed"), systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button(LocalizedStringKey("support.action.retry")) {
                            CustomerServiceWebViewPool.shared.invalidate(identity: identity)
                            let retryTrace = CustomerServicePerformanceTrace(event: "explicit-retry")
                            retryTrace.resolved(identity)
                            trace = retryTrace
                            loadFailed = false
                            loadGeneration = UUID()
                        }
                    }
                } else if let identity {
                    ServiceWebView(
                        service: service,
                        identity: identity,
                        trace: trace,
                        loadFailed: $loadFailed
                    )
                    .id(loadGeneration)
                } else {
                    unavailableView
                }
            case .disabled:
                ContentUnavailableView(LocalizedStringKey("support.status.closed"), systemImage: "bubble.left.and.bubble.right")
            case .unavailable:
                unavailableView
            }
        }.navigationTitle("在线客服").toolbar(.visible, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            LocalizedStringKey("support.status.invalid"),
            systemImage: "bubble.left.and.exclamationmark.bubble.right",
            description: Text("请刷新客户端配置，或通过官网联系支持。")
        )
    }
}

struct ServiceWebView: UIViewRepresentable {
    let service: EffectiveCustomerService
    let identity: CustomerServiceIdentity
    let trace: CustomerServicePerformanceTrace
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            service: service,
            identity: identity,
            trace: trace,
            loadFailed: $loadFailed
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let lease = CustomerServiceWebViewPool.shared.acquire(identity: identity) {
            WKWebView(
                frame: .zero,
                configuration: CustomerServiceWebViewPool.configuration(for: identity)
            )
        }
        let webView = lease.webView
        webView.navigationDelegate = context.coordinator
        trace.record(
            stage: "T2",
            event: lease.reused ? "webview-reused" : "webview-created",
            detail: "reuse=\(lease.reused)"
        )

        guard lease.shouldLoad else {
            trace.record(stage: "T3", event: "load-skipped", detail: "reuse=true")
            return webView
        }

        trace.record(stage: "T3", event: "load-issued", detail: "reuse=false")
        switch service {
        case let .url(url, _): webView.load(URLRequest(url: url))
        case let .html(content): webView.loadHTMLString(CustomerServiceResolver.htmlDocument(content), baseURL: nil)
        default: break
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let service: EffectiveCustomerService
        let identity: CustomerServiceIdentity
        let trace: CustomerServicePerformanceTrace
        let loadFailed: Binding<Bool>

        init(
            service: EffectiveCustomerService,
            identity: CustomerServiceIdentity,
            trace: CustomerServicePerformanceTrace,
            loadFailed: Binding<Bool>
        ) {
            self.service = service
            self.identity = identity
            self.trace = trace
            self.loadFailed = loadFailed
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            trace.record(stage: "T4", event: "provisional-start")
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            trace.recordRedirect()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            trace.record(stage: "T6", event: "navigation-commit")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            trace.record(stage: "T7", event: "navigation-finished", detail: "uiReady=unknown")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error, webView: webView, stage: "provisional-failed")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error, webView: webView, stage: "navigation-failed")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame else { return .allow }
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            trace.record(
                stage: "T5",
                event: "navigation-response",
                detail: status.map { "status=\($0)" }
            )
            guard let status, status >= 400 else { return .allow }
            CustomerServiceWebViewPool.shared.invalidate(identity: identity, matching: webView)
            loadFailed.wrappedValue = true
            return .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.request.url?.absoluteString == "about:blank" { return .allow }
            switch CustomerServiceResolver.navigation(navigationAction.request.url, service: service, userActivated: navigationAction.navigationType == .linkActivated) {
            case .allow: return .allow
            case .reject: return .cancel
            case .external:
                if let url = navigationAction.request.url { await UIApplication.shared.open(url) }
                return .cancel
            }
        }

        private func handleFailure(_ error: Error, webView: WKWebView, stage: String) {
            let code = (error as NSError).code
            guard code != NSURLErrorCancelled else { return }
            trace.record(stage: "failure", event: stage, detail: "code=\(code)")
            CustomerServiceWebViewPool.shared.invalidate(identity: identity, matching: webView)
            loadFailed.wrappedValue = true
        }
    }
}

enum TrafficDetailsAppearance {
    static let pageSpacing: CGFloat = 10
    static let titleIconSize: CGFloat = 19 * 0.75
    static let actionIconSize: CGFloat = 17
    static let minimumTapSize: CGFloat = 44
    static let tableHorizontalPadding: CGFloat = 12
    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 42
    static let dateColumnFraction: CGFloat = 0.30
}

struct TrafficSummaryView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale

    private var isRefreshingTraffic: Bool {
        RetainedContentLoadingPresentation.showsRefreshIndicator(
            isLoading: model.trafficLoadState.isLoading,
            hasContent: !model.dailyTraffic.isEmpty
        )
    }

    var body: some View {
        Group {
            if model.session == nil {
                AccountRequiredView()
            } else {
                trafficContent
            }
        }
        .navigationTitle(LocalizedStringKey("profile.menu.traffic_details"))
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: ProfileMenuItem.traffic.icon)
                        .font(.system(
                            size: TrafficDetailsAppearance.titleIconSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(brand.theme.color(ProfileMenuItem.traffic.tint))
                    Text(LocalizedStringKey("profile.menu.traffic_details"))
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                RefreshToolbarButton(
                    isRefreshing: isRefreshingTraffic,
                    isDisabled: model.trafficLoadState.isLoading,
                    labelKey: "profile.traffic.refresh",
                    identifier: "profile.traffic.refresh"
                ) {
                    Task { await model.refreshTraffic() }
                }
            }
        }
        .task { await model.loadTrafficIfNeeded() }
    }

    private var trafficContent: some View {
        VStack(spacing: TrafficDetailsAppearance.pageSpacing) {
            tableCard
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(brand.theme.background)
    }

    private var tableCard: some View {
        VStack(spacing: 0) {
            tableHeader
            Rectangle()
                .fill(brand.theme.divider)
                .frame(height: 1)
            if !model.dailyTraffic.isEmpty {
                if let failure = model.trafficLoadState.failureMessage {
                    compactFailure(failure)
                }
                recordsList
            } else {
                initialState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .surfaceCard()
        .accessibilityIdentifier("profile.traffic.table")
    }

    private var tableHeader: some View {
        trafficRow(
            date: AppLocalization.string("profile.traffic.date", locale: locale),
            upload: AppLocalization.string("profile.traffic.upload", locale: locale),
            download: AppLocalization.string("profile.traffic.download", locale: locale),
            total: AppLocalization.string("profile.traffic.total", locale: locale),
            isHeader: true
        )
        .frame(height: TrafficDetailsAppearance.headerHeight)
        .accessibilityIdentifier("profile.traffic.table.header")
    }

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.dailyTraffic.enumerated()), id: \.element.id) { index, traffic in
                    trafficRow(
                        date: TrafficDateFormatter.day(
                            unixSeconds: traffic.recordAtUnix,
                            locale: locale
                        ),
                        upload: TrafficFormatter.adaptive(
                            traffic.uploadBytes,
                            locale: locale
                        ).combined,
                        download: TrafficFormatter.adaptive(
                            traffic.downloadBytes,
                            locale: locale
                        ).combined,
                        total: TrafficFormatter.adaptive(
                            traffic.totalBytes,
                            locale: locale
                        ).combined,
                        isHeader: false
                    )
                    .frame(height: TrafficDetailsAppearance.rowHeight)
                    .accessibilityIdentifier("profile.traffic.row.\(traffic.id)")
                    if index < model.dailyTraffic.count - 1 {
                        Rectangle()
                            .fill(brand.theme.divider)
                            .frame(height: 1)
                            .padding(.horizontal, TrafficDetailsAppearance.tableHorizontalPadding)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("profile.traffic.records.scroll")
    }

    @ViewBuilder
    private var initialState: some View {
        switch model.trafficLoadState {
        case .loading, .idle:
            VStack(spacing: 10) {
                ProgressView()
                Text(LocalizedStringKey("profile.traffic.loading"))
                    .font(.subheadline)
                    .foregroundStyle(brand.theme.secondary)
            }
            .accessibilityIdentifier("profile.traffic.loading")
        case .empty, .loaded:
            ContentUnavailableView(
                LocalizedStringKey("profile.traffic.empty"),
                systemImage: "chart.bar.xaxis"
            )
            .accessibilityIdentifier("profile.traffic.empty")
        case let .failed(message), let .stale(message):
            VStack(spacing: 12) {
                LocalizedMessageText(message: message)
                    .font(.subheadline)
                    .foregroundStyle(brand.theme.secondary)
                    .multilineTextAlignment(.center)
                retryButton
            }
            .padding(20)
            .accessibilityIdentifier("profile.traffic.error")
        }
    }

    private func compactFailure(_ message: LocalizedMessage) -> some View {
        HStack(spacing: 10) {
            LocalizedMessageText(message: message)
                .font(.footnote)
                .foregroundStyle(brand.theme.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            retryButton
        }
        .padding(.horizontal, TrafficDetailsAppearance.tableHorizontalPadding)
        .padding(.vertical, 6)
        .background(brand.theme.field)
    }

    private var retryButton: some View {
        Button {
            Task { await model.refreshTraffic() }
        } label: {
            Text(LocalizedStringKey("profile.traffic.retry"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(brand.theme.emphasis)
                .frame(minWidth: TrafficDetailsAppearance.minimumTapSize, minHeight: 36)
        }
        .buttonStyle(.plain)
        .disabled(model.trafficLoadState.isLoading)
        .accessibilityIdentifier("profile.traffic.retry")
    }

    private func trafficRow(
        date: String,
        upload: String,
        download: String,
        total: String,
        isHeader: Bool
    ) -> some View {
        GeometryReader { geometry in
            let available = geometry.size.width
            let dateWidth = available * TrafficDetailsAppearance.dateColumnFraction
            let valueWidth = (available - dateWidth) / 3
            HStack(spacing: 0) {
                cell(date, width: dateWidth, alignment: .leading, isHeader: isHeader)
                cell(upload, width: valueWidth, alignment: .trailing, isHeader: isHeader)
                cell(download, width: valueWidth, alignment: .trailing, isHeader: isHeader)
                cell(total, width: valueWidth, alignment: .trailing, isHeader: isHeader)
            }
        }
        .padding(.horizontal, TrafficDetailsAppearance.tableHorizontalPadding)
    }

    private func cell(
        _ value: String,
        width: CGFloat,
        alignment: Alignment,
        isHeader: Bool
    ) -> some View {
        Text(verbatim: value)
            .font(isHeader ? .caption.weight(.semibold) : .footnote.monospacedDigit())
            .foregroundStyle(isHeader ? brand.theme.secondary : brand.theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: width, alignment: alignment)
            .frame(maxHeight: .infinity, alignment: alignment)
    }
}
