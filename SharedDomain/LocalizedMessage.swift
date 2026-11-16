import Foundation

enum LocalizedMessage: Equatable, Sendable {
    case localized(String)
    case verbatim(String)

    static let empty = LocalizedMessage.verbatim("")
}

enum L10nKey {
    static let commonOperationFailed = "error.operation_failed"
    static let commonAccountRequired = "error.account_required"
    static let commonConfigurationRequired = "error.configuration_required"
    static let offlineRequestUnavailable = "error.offline_request_unavailable"
    static let offlineFixtureFailed = "error.offline_fixture_failed"

    static let configSourceNotLoaded = "config.source.not_loaded"
    static let configSourceTest = "config.source.test"
    static let configSourceOffline = "config.source.offline"
    static let configurationUnavailableTitle = "configuration.unavailable.title"
    static let configurationUnavailableMessage = "configuration.unavailable.message"
    static let configurationUnavailableRetry = "configuration.unavailable.retry"
    static let configurationUnavailableDisconnectVPN = "configuration.unavailable.disconnect_vpn"
    static let configurationUnavailableDisconnectFailed = "configuration.unavailable.disconnect_failed"
    static let mainSectionHome = "main_section.home"
    static let mainSectionPurchase = "main_section.purchase"
    static let mainSectionProfile = "main_section.profile"
    static let destinationNodes = "destination.nodes"
    static let proxyModeDialogApply = "proxy_mode.dialog.apply"
    static let proxyModeDialogCancel = "proxy_mode.dialog.cancel"
    static let proxyModeDialogClose = "proxy_mode.dialog.close"
    static let proxyModeDialogGlobalDescription = "proxy_mode.dialog.global_description"
    static let proxyModeDialogRuleDescription = "proxy_mode.dialog.rule_description"
    static let proxyModeDialogTitle = "proxy_mode.dialog.title"
    static let proxyModeDialogTunDescription = "proxy_mode.dialog.tun_description"
    static let proxyModeDialogTunTitle = "proxy_mode.dialog.tun_title"
    static let proxyModeRule = "proxy_mode.rule"
    static let proxyModeGlobal = "proxy_mode.global"

    static let homeNoticeEmpty = "home.notice.empty"
    static let homeNoticeFallbackTitle = "home.notice.fallback_title"
    static let homeNoticeImportant = "home.notice.important"
    static let homeTrafficRemaining = "home.traffic.remaining"
    static let homeTrafficPlan = "home.traffic.plan"
    static let homeTrafficTotal = "home.traffic.total"
    static let homeTrafficExpiration = "home.traffic.expiration"
    static let homeTrafficNoPlan = "home.traffic.no_plan"
    static let homeTrafficLongTerm = "home.traffic.long_term"
    static let homeConnectionDisconnected = "home.connection.disconnected"
    static let homeConnectionConnecting = "home.connection.connecting"
    static let homeConnectionConnected = "home.connection.connected"
    static let homeConnectionUnavailableHint = "home.connection.unavailable_hint"
    static let homeConnectionNodeUnavailable = "home.connection.error.node_unavailable"
    static let homeConnectionStartFailed = "home.connection.error.start_failed"
    static let homeConnectionClearFailed = "home.connection.error.clear_failed"
    static let homeConnectionCoreExited = "home.connection.error.core_exited"
    static let homeConnectionModeSwitchFailed = "home.connection.error.mode_switch_failed"
    static let homeConnectionNodeSwitchFailed = "home.connection.error.node_switch_failed"
    static let homeConnectionRefreshFailed = "home.connection.error.refresh_failed"
    static let homeNodeSelect = "home.node.select"
    static let vpnPreflightNoNodeTitle = "vpn.preflight.no_node.title"
    static let vpnPreflightNoNodeMessage = "vpn.preflight.no_node.message"
    static let vpnPreflightSelectedNodeMissingTitle = "vpn.preflight.selected_node_missing.title"
    static let vpnPreflightSelectedNodeMissingMessage = "vpn.preflight.selected_node_missing.message"
    static let vpnPreflightInvalidConfigurationTitle = "vpn.preflight.invalid_configuration.title"
    static let vpnPreflightInvalidConfigurationMessage = "vpn.preflight.invalid_configuration.message"
    static let vpnPreflightSelectNodeAction = "vpn.preflight.action.select_node"
    static let vpnPreflightChooseAnotherNodeAction = "vpn.preflight.action.choose_another_node"
    static let vpnPreflightReplaceNodeAction = "vpn.preflight.action.replace_node"
    static let vpnConnectUnableTitle = "vpn.connect.unable.title"
    static let vpnConnectUnableMessage = "vpn.connect.unable.message"
    static let commonClose = "common.action.close"

    static let preferenceLanguageSystem = "preference.language.system"
    static let preferenceLanguageSimplifiedChinese = "preference.language.simplified_chinese"
    static let preferenceLanguageEnglish = "preference.language.english"
    static let preferenceAppearanceSystem = "preference.appearance.system"
    static let preferenceAppearanceLight = "preference.appearance.light"
    static let preferenceAppearanceDark = "preference.appearance.dark"

    static let loginStatusLoadingConfiguration = "login.status.loading_configuration"
    static let loginStatusRefreshingConfiguration = "login.status.refreshing_configuration"
    static let loginStatusConfigurationReady = "login.status.configuration_ready"
    static let loginStatusSubmitting = "login.status.submitting"
    static let loginStatusVerifyingSession = "login.status.verifying_session"
    static let loginStatusCancelled = "login.status.cancelled"

    static let forgotStatusLoadingConfiguration = "forgot.status.loading_configuration"
    static let forgotStatusSendingCode = "forgot.status.sending_code"
    static let forgotStatusCodeSent = "forgot.status.code_sent"
    static let forgotStatusResetSucceeded = "forgot.status.reset_succeeded"
    static let forgotValidationEmailRequired = "forgot.validation.email_required"
    static let forgotValidationEmailInvalid = "forgot.validation.email_invalid"
    static let forgotValidationEmailCodeRequired = "forgot.validation.email_code_required"
    static let forgotValidationNewPasswordRequired = "forgot.validation.new_password_required"
    static let forgotValidationConfirmPasswordRequired = "forgot.validation.confirm_password_required"
    static let forgotValidationPasswordMismatch = "forgot.validation.password_mismatch"

    static let registerStatusLoadingConfiguration = "register.status.loading_configuration"
    static let registerStatusRegistrationConfigUnavailable = "register.status.registration_config_unavailable"
    static let registerStatusSendingCode = "register.status.sending_code"
    static let registerStatusCodeSent = "register.status.code_sent"
    static let registerStatusSubmitting = "register.status.submitting"
    static let registerStatusSucceeded = "register.status.succeeded"
    static let registerStatusRecaptchaUnsupported = "register.status.recaptcha_unsupported"
    static let registerValidationEmailRequired = "register.validation.email_required"
    static let registerValidationEmailInvalid = "register.validation.email_invalid"
    static let registerValidationEmailSuffixNotAllowed = "register.validation.email_suffix_not_allowed"
    static let registerValidationEmailCodeRequired = "register.validation.email_code_required"
    static let registerValidationPasswordRequired = "register.validation.password_required"
    static let registerValidationConfirmPasswordRequired = "register.validation.confirm_password_required"
    static let registerValidationPasswordMismatch = "register.validation.password_mismatch"
    static let registerValidationInviteRequired = "register.validation.invite_required"

    static let purchaseCancellationUnknown = "purchase.payment.unknown_cancellation"
    static let purchaseInvalidResponse = "purchase.payment.invalid_response"

    static let tunnelMissingNode = "tunnel.error.missing_node"
    static let tunnelCoreNotIntegrated = "tunnel.error.core_not_integrated"
    static let tunnelInvalidTransition = "tunnel.error.invalid_transition"
    static let tunnelUnsupportedProtocol = "tunnel.error.unsupported_protocol"
    static let tunnelSignatureNotVerified = "tunnel.error.signature_not_verified"
    static let tunnelCapabilityUnverified = "tunnel.capability.unverified"
    static let tunnelCapabilityUnsupported = "tunnel.capability.unsupported"

    static let errorConfigurationUnavailable = "error.configuration_unavailable"
    static let errorNetworkUnavailable = "error.network_unavailable"
    static let errorServiceUnavailable = "error.service_unavailable"
    static let errorSecureStorage = "error.secure_storage"
    static let errorAuthenticationExpired = "error.authentication_expired"
    static let errorBusinessRejected = "error.business_rejected"
    static let errorRateLimited = "error.rate_limited"
    static let errorDNS = "error.dns"
    static let errorTLS = "error.tls"
    static let errorTimeout = "error.timeout"
    static let errorWriteResultUnknown = "error.write_result_unknown"
    static let loginStatusInitializing = "login.status.initializing"
    static let loginStatusReady = "login.status.ready"
    static let loginStatusConfigFailed = "login.status.config_failed"
    static let loginStatusServerUnavailable = "login.status.server_unavailable"
    static let loginStatusLoggingIn = "login.status.logging_in"
    static let loginActionRetry = "login.action.retry"
}

enum AppLocalization {
    static func string(
        _ key: String,
        locale: Locale,
        arguments: [CVarArg] = [],
        bundle: Bundle = .main
    ) -> String {
        let languageCode = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        let localizedBundle = bundle.path(forResource: languageCode, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? bundle
        let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }
}
