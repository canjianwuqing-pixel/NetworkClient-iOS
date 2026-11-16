import Foundation

struct PurchasePlan: Identifiable, Sendable, Equatable {
    let id: Int
    let name: String
    let content: String
    let sort: Int
    let cycles: [PurchasePlanCycle]
    let features: [PurchasePlanFeature]
}

struct PurchasePlanCycle: Identifiable, Sendable, Equatable {
    let period: PurchasePlanPeriod
    let priceCents: Int64

    var id: PurchasePlanPeriod { period }
}

enum PurchasePlanPeriod: String, CaseIterable, Hashable, Sendable {
    case month = "month_price"
    case quarter = "quarter_price"
    case halfYear = "half_year_price"
    case year = "year_price"
    case twoYear = "two_year_price"
    case threeYear = "three_year_price"
    case oneTime = "onetime_price"

    var localizationKey: String {
        switch self {
        case .month: "purchase.period.month"
        case .quarter: "purchase.period.quarter"
        case .halfYear: "purchase.period.half_year"
        case .year: "purchase.period.year"
        case .twoYear: "purchase.period.two_year"
        case .threeYear: "purchase.period.three_year"
        case .oneTime: "purchase.period.one_time"
        }
    }
}

struct PurchasePlanFeature: Sendable, Equatable {
    let text: String
    let isSupported: Bool
}

actor V2BoardAPIClient {
    static let loginPath = NetworkEndpoints.path("loginPath")
    static let registrationConfigPath = NetworkEndpoints.path("registrationConfigPath")
    static let registerPath = NetworkEndpoints.path("registerPath")
    static let sendEmailVerificationPath = NetworkEndpoints.path("sendEmailVerificationPath")
    static let forgotPasswordPath = NetworkEndpoints.path("forgotPasswordPath")
    static let subscriptionInfoPath = NetworkEndpoints.path("subscriptionInfoPath")
    static let userInfoPath = NetworkEndpoints.path("userInfoPath")
    static let planListPath = NetworkEndpoints.path("planListPath")
    static let guestPlanListPath = NetworkEndpoints.path("guestPlanListPath")
    static let noticeListPath = NetworkEndpoints.path("noticeListPath")
    static let couponCheckPath = NetworkEndpoints.path("couponCheckPath")
    static let orderListPath = NetworkEndpoints.path("orderListPath")
    static let orderSavePath = NetworkEndpoints.path("orderSavePath")
    static let orderDetailPath = NetworkEndpoints.path("orderDetailPath")
    static let orderCheckPath = NetworkEndpoints.path("orderCheckPath")
    static let orderPaymentMethodsPath = NetworkEndpoints.path("orderPaymentMethodsPath")
    static let orderCheckoutPath = NetworkEndpoints.path("orderCheckoutPath")
    static let orderCancelPath = NetworkEndpoints.path("orderCancelPath")
    static let inviteFetchPath = NetworkEndpoints.path("inviteFetchPath")
    static let inviteSavePath = NetworkEndpoints.path("inviteSavePath")
    static let trafficLogPath = NetworkEndpoints.path("trafficLogPath")
    static let changePasswordPath = NetworkEndpoints.path("changePasswordPath")
    static let accountDeleteRequestPath = NetworkEndpoints.path("accountDeleteRequestPath")

    private let transport: any NetworkTransport
    private let recoveryRouter: APIRecoveryRouter

    init(
        recoveryRouter: APIRecoveryRouter = .shared,
        transport: any NetworkTransport = URLSessionNetworkTransport(profile: .api)
    ) {
        self.recoveryRouter = recoveryRouter
        self.transport = transport
    }

    func login(
        config: AppConfig,
        email: String,
        password: String
    ) async throws -> UserSession {
        let deadline = recoveryRouter.operationDeadline(OperationBudget.login)
        return try await OperationDeadline.$current.withValue(deadline) {
            try await self.loginWithinDeadline(config: config, email: email, password: password)
        }
    }

    private func loginWithinDeadline(
        config: AppConfig, email: String, password: String
    ) async throws -> UserSession {
        let normalizedEmail = email.trimmed
        let credential = try await loginAgainstHost(
            config: config,
            email: normalizedEmail,
            password: password
        )
        let subscription = try await fetchSubscriptionInfo(
            config: config,
            fallbackEmail: normalizedEmail,
            credential: credential.value
        )
        let userInfo = try await fetchUserInfo(
            config: config,
            authData: credential.value.authData
        )

        return UserSession(
            email: userInfo.value.email?.trimmed.nilIfEmpty
                ?? subscription.value.email,
            authData: credential.value.authData,
            accountToken: credential.value.accountToken ?? subscription.value.accountToken,
            subscriptionURL: subscription.value.subscriptionURL,
            uploadBytes: subscription.value.uploadBytes,
            downloadBytes: subscription.value.downloadBytes,
            transferEnableBytes: subscription.value.transferEnableBytes,
            expiredAt: subscription.value.expiredAt,
            planID: subscription.value.planID,
            planName: subscription.value.planID.map({ $0 > 0 }) == true
                ? subscription.value.serverPlanName ?? ""
                : "",
            balanceCents: userInfo.value.balanceCents,
            verifiedAt: Date()
        )
    }

    func verifyStoredSession(config: AppConfig, session storedSession: UserSession) async throws -> UserSession {
        let userInfo = try await fetchUserInfo(
            config: config,
            authData: storedSession.authData
        )
        return storedSession.applyingUserInfo(
            email: userInfo.value.email,
            balanceCents: userInfo.value.balanceCents
        )
    }

    func refreshHomeAccount(
        config: AppConfig,
        session storedSession: UserSession
    ) async throws -> HomeAccountRefreshResult {
        let credential = LoginCredential(
            authData: storedSession.authData,
            accountToken: storedSession.accountToken
        )
        let subscription = try await fetchSubscriptionInfo(
            config: config,
            fallbackEmail: storedSession.email,
            credential: credential
        )

        let activePlanID = subscription.value.planID.flatMap { $0 > 0 ? $0 : nil }
        var resolvedPlanName = activePlanID == nil ? nil : subscription.value.serverPlanName
        if activePlanID != nil, resolvedPlanName == nil {
            resolvedPlanName = Self.normalizedPlanName(storedSession.planName)
        }
        if let planID = activePlanID, resolvedPlanName == nil {
            do {
                resolvedPlanName = try await fetchCurrentPlanName(
                    config: config,
                            authData: storedSession.authData,
                    planID: planID
                )
            } catch let error as NetworkClientError {
                if case .authenticationExpired = error { throw error }
                SafeLog.warning(
                    "[Home] plan name refresh failed category=\(error.logCategory) cached_name_retained=true"
                )
            }
        }

        var refreshedEmail = subscription.value.email
        var refreshedBalance = storedSession.balanceCents
        var verifiedAt = storedSession.verifiedAt
        do {
            let userInfo = try await fetchUserInfo(
                config: config,
                    authData: storedSession.authData
            )
            refreshedEmail = userInfo.value.email?.trimmed.nilIfEmpty ?? refreshedEmail
            refreshedBalance = userInfo.value.balanceCents
            verifiedAt = Date()
        } catch let error as NetworkClientError {
            if case .authenticationExpired = error { throw error }
            SafeLog.warning(
                "[Home] user info refresh failed category=\(error.logCategory) cached_balance_retained=true"
            )
        }

        let refreshedSession = UserSession(
            email: refreshedEmail,
            authData: storedSession.authData,
            accountToken: subscription.value.accountToken ?? storedSession.accountToken,
            subscriptionURL: subscription.value.subscriptionURL.trimmed.nilIfEmpty
                ?? storedSession.subscriptionURL,
            uploadBytes: subscription.value.uploadBytes,
            downloadBytes: subscription.value.downloadBytes,
            transferEnableBytes: subscription.value.transferEnableBytes,
            expiredAt: subscription.value.expiredAt,
            planID: subscription.value.planID,
            planName: resolvedPlanName ?? "",
            balanceCents: refreshedBalance,
            verifiedAt: verifiedAt
        )
        SafeLog.info(
            "[Home] account refreshed authorization_present=true plan_present=\(activePlanID != nil)"
        )
        return HomeAccountRefreshResult(
            session: refreshedSession,
            resolvedPlanName: resolvedPlanName
        )
    }

    func fetchCurrentSubscriptionInfo(
        config: AppConfig,
        session storedSession: UserSession
    ) async throws -> CurrentSubscriptionInfo {
        let subscription = try await fetchSubscriptionInfo(
            config: config,
            fallbackEmail: storedSession.email,
            credential: LoginCredential(
                authData: storedSession.authData,
                accountToken: storedSession.accountToken
            )
        )
        return CurrentSubscriptionInfo(
            subscriptionURL: subscription.value.subscriptionURL.trimmed.nilIfEmpty
        )
    }

    func fetchHomeNotices(config: AppConfig, session userSession: UserSession) async throws -> [HomeNotice] {
        try await sendRetryableJSON(
            config: config,
            method: "GET",
            relativePath: Self.noticeListPath,
            stage: "noticeList",
            context: .authenticated,
            authData: userSession.authData
        ) { root, _, hostIndex in
            let notices = try Self.parseHomeNotices(root: root.value)
            SafeLog.info(
                "[Home] notices refreshed hostIndex=\(hostIndex) noticeCount=\(notices.count)"
            )
            return notices
        }
    }

    static func parseHomeNotices(root: [String: Any]) throws -> [HomeNotice] {
        guard let values = root["data"] as? [Any],
              values.allSatisfy({ $0 is [String: Any] }) else {
            SafeLog.warning(
                "[Home] notice response rejected reason=data_not_array type=\(jsonShape(root["data"]))"
            )
            throw NetworkClientError.serviceUnavailable(
                "服务暂时不可用，请稍后重试",
                retryable: true
            )
        }
        let notices = values.compactMap { value -> HomeNotice? in
            guard let item = value as? [String: Any] else { return nil }
            guard let id = Self.int(item["id"]) else {
                return nil
            }
            return HomeNotice(
                id: id,
                title: Self.string(item["title"])?.trimmed ?? "",
                content: Self.string(item["content"]) ?? "",
                imageURL: Self.string(item["img_url"])?.trimmed.nilIfEmpty,
                tags: Self.noticeTags(item["tags"]),
                createdAt: Self.int64(item["created_at"]) ?? 0
            )
        }
        .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
        guard values.isEmpty || !notices.isEmpty else {
            SafeLog.warning("[Home] notice response rejected reason=no_valid_items itemCount=\(values.count)")
            throw NetworkClientError.serviceUnavailable(
                "服务暂时不可用，请稍后重试",
                retryable: true
            )
        }
        return notices
    }

    private static func jsonShape(_ value: Any?) -> String {
        switch value {
        case nil: "missing"
        case is [Any]: "array"
        case is [String: Any]: "object"
        case is String: "string"
        case is NSNumber: "number"
        case is NSNull: "null"
        default: "other"
        }
    }

    func fetchPlans(config: AppConfig, session userSession: UserSession) async throws -> [PurchasePlan] {
        let plan = APIRecoveryPlan.forAPI(config)
        return try await recoveryRouter.safeRetry(plan: plan) { route in
            var lastError = NetworkClientError.transport("网络连接失败，请稍后重试")
            for (pathIndex, relativePath) in [Self.planListPath, Self.guestPlanListPath].enumerated() {
                do {
                    let root = try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "GET",
                        relativePath: relativePath,
                        stage: "planList",
                        context: .authenticated,
                        authData: userSession.authData,
                        routeTransport: route.transport
                    )
                    guard let data = root["data"] as? [Any] else {
                        throw NetworkClientError.serviceUnavailable(
                            "服务暂时不可用，请稍后重试",
                            retryable: true
                        )
                    }

                    let plans = data
                        .compactMap { $0 as? [String: Any] }
                        .filter { (Self.int($0["show"]) ?? 1) != 0 }
                        .compactMap(Self.purchasePlan)
                        .sorted { lhs, rhs in
                            lhs.sort == rhs.sort ? lhs.id < rhs.id : lhs.sort < rhs.sort
                        }
                    SafeLog.info(
                        "[Purchase] plans refreshed hostIndex=\(route.targetIndex) "
                            + "endpointIndex=\(pathIndex + 1) planCount=\(plans.count)"
                    )
                    return plans
                } catch let error as NetworkClientError {
                    if case .authenticationExpired = error { throw error }
                    if !error.retryable { throw error }
                    lastError = error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = .transport("网络连接失败，请稍后重试")
                }
            }
            throw lastError
        }
    }

    func checkCoupon(
        config: AppConfig,
        session userSession: UserSession,
        code: String,
        planID: Int
    ) async throws -> PurchaseCoupon {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "plan_id": planID])
        return try await sendRetryableJSON(
            config: config,
            method: "POST",
            relativePath: Self.couponCheckPath,
            stage: "couponCheck",
            context: .authenticated,
            responsePolicy: .couponCheck,
            body: body,
            authData: userSession.authData
        ) { root, _, _ in
            guard let data = root["data"] as? [String: Any] else {
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试",
                    retryable: true
                )
            }
            return PurchaseCoupon(
                id: Self.int(data["id"]),
                name: Self.string(data["name"])?.trimmed.nilIfEmpty
                    ?? Self.string(data["code"])?.trimmed
                    ?? code
            )
        }
    }

    func createOrder(
        config: AppConfig,
        session userSession: UserSession,
        planID: Int,
        period: PurchasePlanPeriod,
        couponCode: String?
    ) async throws -> String {
        var body: [String: Any] = ["plan_id": planID, "period": period.rawValue]
        if let couponCode = couponCode?.trimmed.nilIfEmpty { body["coupon_code"] = couponCode }
        let root = try await sendSingleAttemptWrite(
            config: config,
            session: userSession,
            relativePath: Self.orderSavePath,
            stage: "orderSave",
            bodyObject: body,
            responsePolicy: .orderCreation,
            unknownError: .orderCreationResultUnknown
        )
        guard let tradeNo = Self.string(root["data"])?.trimmed.nilIfEmpty else {
            throw PurchaseCommerceError.orderCreationResultUnknown
        }
        return tradeNo
    }

    func fetchOrders(
        config: AppConfig,
        session userSession: UserSession,
        requireComplete: Bool = false
    ) async throws -> [PurchaseOrderRecord] {
        let root = try await sendAuthenticatedRead(
            config: config,
            session: userSession,
            relativePath: Self.orderListPath,
            stage: "orderList"
        )
        guard let items = Self.orderListItems(root["data"]) else {
            throw PurchaseCommerceError.invalidResponse
        }
        let orders = items.compactMap(Self.purchaseOrderRecord)
        if requireComplete {
            // Never infer uniqueness from a partially decoded/paginated list.
            guard orders.count == items.count else {
                throw PurchaseCommerceError.invalidResponse
            }
            for page in [root, root["data"] as? [String: Any] ?? [:], root["meta"] as? [String: Any] ?? [:]] {
                let next = page["next_page_url"] ?? (page["links"] as? [String: Any])?["next"]
                guard page["total"] == nil || Self.int(page["total"]) == orders.count,
                      page["current_page"] == nil || Self.int(page["current_page"]) == 1,
                      page["last_page"] == nil || Self.int(page["last_page"]) == 1,
                      next == nil || next is NSNull else {
                    throw PurchaseCommerceError.invalidResponse
                }
            }
        }
        return orders
    }

    func fetchOrderDetail(
        config: AppConfig,
        session userSession: UserSession,
        tradeNo: String
    ) async throws -> PurchaseOrderDetail {
        let root = try await sendAuthenticatedRead(
            config: config,
            session: userSession,
            relativePath: try Self.path(Self.orderDetailPath, tradeNo: tradeNo),
            stage: "orderDetail"
        )
        guard let data = root["data"] as? [String: Any] else {
            throw PurchaseCommerceError.invalidResponse
        }
        return try Self.purchaseOrderDetail(data, fallbackTradeNo: tradeNo)
    }

    func fetchPaymentMethods(
        config: AppConfig,
        session userSession: UserSession
    ) async throws -> [PurchasePaymentMethod] {
        let root = try await sendAuthenticatedRead(
            config: config,
            session: userSession,
            relativePath: Self.orderPaymentMethodsPath,
            stage: "paymentMethods"
        )
        guard let data = root["data"] as? [Any] else {
            throw PurchaseCommerceError.invalidResponse
        }
        return data.compactMap { item in
            guard let object = item as? [String: Any],
                  let id = Self.int(object["id"]), id > 0 else { return nil }
            return PurchasePaymentMethod(
                id: id,
                name: Self.string(object["name"])?.trimmed ?? "",
                payment: Self.string(object["payment"])?.trimmed ?? "",
                iconURL: Self.safeHTTPURL(Self.string(object["icon"])),
                handlingFeeFixedCents: max(0, Self.int64(object["handling_fee_fixed"]) ?? 0),
                handlingFeePercent: max(0, Self.double(object["handling_fee_percent"]) ?? 0)
            )
        }
    }

    func checkoutOrder(
        config: AppConfig,
        session userSession: UserSession,
        tradeNo: String,
        methodID: Int?
    ) async throws -> PurchaseCheckoutResult {
        var body: [String: Any] = ["trade_no": tradeNo]
        if let methodID { body["method"] = methodID }
        let root = try await sendSingleAttemptWrite(
            config: config,
            session: userSession,
            relativePath: Self.orderCheckoutPath,
            stage: "orderCheckout",
            bodyObject: body,
            unknownError: .checkoutResultUnknown
        )
        guard let type = Self.int(root["type"]), [-1, 0, 1, 2].contains(type) else {
            throw PurchaseCommerceError.checkoutResultUnknown
        }
        if type == 0 || type == 1 {
            guard let payload = root["data"] as? String, !payload.trimmed.isEmpty else {
                throw PurchaseCommerceError.checkoutResultUnknown
            }
        }
        return PurchaseCheckoutResult(type: type, data: Self.string(root["data"]))
    }

    func checkOrderStatus(
        config: AppConfig,
        session userSession: UserSession,
        tradeNo: String
    ) async throws -> Int {
        let root = try await sendAuthenticatedRead(
            config: config,
            session: userSession,
            relativePath: try Self.path(Self.orderCheckPath, tradeNo: tradeNo),
            stage: "orderCheck"
        )
        guard let status = Self.int(root["data"]) else { throw PurchaseCommerceError.invalidResponse }
        return status
    }

    func cancelOrder(
        config: AppConfig,
        session userSession: UserSession,
        tradeNo: String
    ) async throws {
        let root = try await sendSingleAttemptWrite(
            config: config,
            session: userSession,
            relativePath: Self.orderCancelPath,
            stage: "orderCancel",
            bodyObject: ["trade_no": tradeNo],
            unknownError: .cancellationResultUnknown
        )
        guard root["data"] as? Bool == true else { throw PurchaseCommerceError.cancellationResultUnknown }
    }

    func fetchInviteInfo(
        config: AppConfig,
        session userSession: UserSession
    ) async throws -> ProfileInviteInfo {
        let root = try await sendAuthenticatedRead(
            config: config,
            session: userSession,
            relativePath: Self.inviteFetchPath,
            stage: "inviteFetch",
            responsePolicy: .invitation
        )
        guard let data = root["data"] as? [String: Any] else {
            throw NetworkClientError.responseInvalid("服务暂时不可用，请稍后重试")
        }
        let codes = (data["codes"] as? [Any] ?? [])
            .compactMap(Self.profileInviteCode)
            .sorted {
                if $0.createdAtUnix != $1.createdAtUnix {
                    return ($0.createdAtUnix ?? 0) > ($1.createdAtUnix ?? 0)
                }
                return $0.id > $1.id
            }
        let stat = (data["stat"] as? [Any] ?? []).map { Self.int64($0) ?? 0 }
        return ProfileInviteInfo(
            codes: codes,
            registeredCount: Int(clamping: Self.inviteStat(stat, index: 0)),
            validCommissionCents: Self.inviteStat(stat, index: 1),
            pendingCommissionCents: Self.inviteStat(stat, index: 2),
            commissionRate: Int(clamping: Self.inviteStat(stat, index: 3)),
            availableCommissionCents: Self.inviteStat(stat, index: 4)
        )
    }

    func fetchTrafficLog(
        config: AppConfig,
        session userSession: UserSession
    ) async throws -> [ProfileTrafficLogRecord] {
        let root = try await sendAuthenticatedRead(
            config: config,
            session: userSession,
            relativePath: Self.trafficLogPath,
            stage: "trafficLog"
        )
        guard let items = root["data"] as? [Any] else {
            throw NetworkClientError.responseInvalid("服务暂时不可用，请稍后重试")
        }
        return items.compactMap(Self.profileTrafficLogRecord)
    }

    func changePassword(
        config: AppConfig,
        session userSession: UserSession,
        oldPassword: String,
        newPassword: String
    ) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "old_password": oldPassword,
                "new_password": newPassword
            ]
        )
        let plan = APIRecoveryPlan.forAPI(config)
        do {
            let result: JSONRoot = try await recoveryRouter.singleAttemptWrite(
                plan: plan,
                probe: { route in
                    try await self.probe(config: config, route: route)
                },
                submit: { route in
                    try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "POST",
                        relativePath: Self.changePasswordPath,
                        stage: "changePassword",
                        context: .authenticated,
                        responsePolicy: .changePassword,
                        body: body,
                        authData: userSession.authData,
                        requestSafety: .nonIdempotentWrite,
                        requestKind: .apiWrite,
                        routeTransport: route.transport
                    )
                }
            )
            guard result.value["data"] as? Bool == true else {
                throw NetworkClientError.writeResultUnknown
            }
        } catch is NonIdempotentTransportFailure {
            SafeLog.warning(
                "[Profile] change password result unknown retry=false failover=false"
            )
            throw NetworkClientError.writeResultUnknown
        }
    }

    func requestAccountDeletion(
        config: AppConfig,
        session userSession: UserSession
    ) async throws {
        let body = try JSONSerialization.data(withJSONObject: [String: Any]())
        let plan = APIRecoveryPlan.forAPI(config)
        do {
            let result: JSONRoot = try await recoveryRouter.singleAttemptWrite(
                plan: plan,
                probe: { route in
                    try await self.probe(config: config, route: route)
                },
                submit: { route in
                    try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "POST",
                        relativePath: Self.accountDeleteRequestPath,
                        stage: "accountDeleteRequest",
                        context: .authenticated,
                        body: body,
                        authData: userSession.authData,
                        requestSafety: .nonIdempotentWrite,
                        requestKind: .apiWrite,
                        routeTransport: route.transport
                    )
                }
            )
            guard result.value["data"] as? Bool == true else {
                throw NetworkClientError.backendBusinessError("")
            }
        } catch is NonIdempotentTransportFailure {
            SafeLog.warning(
                "[Profile] account deletion request result unknown retry=false failover=false"
            )
            throw NetworkClientError.writeResultUnknown
        }
    }

    func createInviteCode(
        config: AppConfig,
        session userSession: UserSession
    ) async throws {
        let plan = APIRecoveryPlan.forAPI(config)
        do {
            let result: JSONRoot = try await recoveryRouter.singleAttemptWrite(
                plan: plan,
                probe: { route in
                    try await self.probe(config: config, route: route)
                },
                submit: { route in
                    try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "GET",
                        relativePath: Self.inviteSavePath,
                        stage: "inviteCreate",
                        context: .authenticated,
                        responsePolicy: .invitation,
                        authData: userSession.authData,
                        requestSafety: .nonIdempotentWrite,
                        requestKind: .apiWrite,
                        routeTransport: route.transport
                    )
                }
            )
            guard let generated = result.value["data"] as? Bool else {
                throw NetworkClientError.writeResultUnknown
            }
            guard generated else {
                throw NetworkClientError.validation("profile.invites.generate_failed")
            }
        } catch let error as NetworkClientError {
            if case let .backendBusinessError(message) = error, message.isEmpty {
                // V2Board can explicitly return HTTP 200 + {"data":false}
                // without a message. That is a definite rejection, not an
                // unknown write result.
                throw NetworkClientError.validation("profile.invites.generate_failed")
            }
            throw error
        } catch is NonIdempotentTransportFailure {
            SafeLog.warning("[Invite] create result unknown retry=false failover=false")
            throw NetworkClientError.writeResultUnknown
        }
    }

    func fetchRegistrationConfig(config: AppConfig) async throws -> V2BoardRegistrationConfig {
        return try await sendRetryableJSON(
            config: config,
            method: "GET",
            relativePath: Self.registrationConfigPath,
            stage: "registrationConfig",
            context: .login
        ) { root, _, hostIndex in
            guard let data = root["data"] as? [String: Any] else {
                SafeLog.warning(
                    "[Register] config rejected hostIndex=\(hostIndex) reason=response_shape"
                )
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试",
                    retryable: true
                )
            }

            let whitelist = Self.parseEmailWhitelist(data["email_whitelist_suffix"])
            let registrationConfig = V2BoardRegistrationConfig(
                requiresEmailVerification: Self.boolFlag(data["is_email_verify"]),
                requiresInvitation: Self.boolFlag(data["is_invite_force"]),
                requiresRecaptcha: Self.boolFlag(data["is_recaptcha"]),
                emailWhitelistEnabled: whitelist.enabled,
                emailWhitelistSuffixes: whitelist.suffixes,
                termsOfServiceURL: AboutSupportExternalLinkValidator.httpsURL(
                    data["tos_url"] as? String
                )
            )
            SafeLog.info(
                "[Register] config loaded hostIndex=\(hostIndex) "
                    + "emailVerify=\(registrationConfig.requiresEmailVerification) "
                    + "inviteForce=\(registrationConfig.requiresInvitation) "
                    + "emailWhitelist=\(registrationConfig.emailWhitelistEnabled) "
                    + "emailSuffixCount=\(registrationConfig.emailWhitelistSuffixes.count) "
                    + "recaptcha=\(registrationConfig.requiresRecaptcha)"
            )
            return registrationConfig
        }
    }

    func sendRegistrationEmailCode(config: AppConfig, email: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmed,
            "isforget": 0
        ])
        try await sendUnauthenticatedBooleanMutation(
            config: config,
            relativePath: Self.sendEmailVerificationPath,
            stage: "registrationEmailVerify",
            body: payload,
            responsePolicy: .authBusiness(.emailVerification)
        )
    }

    func register(
        config: AppConfig,
        email: String,
        emailCode: String?,
        password: String,
        inviteCode: String?
    ) async throws {
        var fields: [String: Any] = [
            "email": email.trimmed,
            "password": password
        ]
        if let emailCode = emailCode?.trimmed.nilIfEmpty {
            fields["email_code"] = emailCode
        }
        if let inviteCode = inviteCode?.trimmed.nilIfEmpty {
            fields["invite_code"] = inviteCode
        }

        let payload = try JSONSerialization.data(withJSONObject: fields)
        let root = try await sendUnauthenticatedJSONMutation(
            config: config,
            relativePath: Self.registerPath,
            stage: "registration",
            body: payload,
            responsePolicy: .authBusiness(.register)
        )
        guard root["data"] as? [String: Any] != nil else {
            SafeLog.warning("[Register] response rejected reason=response_shape")
            throw NetworkClientError.writeResultUnknown
        }
    }

    func sendPasswordResetEmailCode(config: AppConfig, email: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmed,
            "isforget": 1
        ])
        try await sendUnauthenticatedBooleanMutation(
            config: config,
            relativePath: Self.sendEmailVerificationPath,
            stage: "sendEmailVerify",
            body: payload,
            responsePolicy: .authBusiness(.emailVerification)
        )
    }

    func resetPassword(
        config: AppConfig,
        email: String,
        emailCode: String,
        password: String
    ) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmed,
            "email_code": emailCode.trimmed,
            "password": password
        ])
        try await sendUnauthenticatedBooleanMutation(
            config: config,
            relativePath: Self.forgotPasswordPath,
            stage: "forgotPassword",
            body: payload,
            responsePolicy: .authBusiness(.forget)
        )
    }

    private func sendUnauthenticatedBooleanMutation(
        config: AppConfig,
        relativePath: String,
        stage: String,
        body: Data,
        responsePolicy: V2BoardAPIResponsePolicy = .standard
    ) async throws {
        let root = try await sendUnauthenticatedJSONMutation(
            config: config,
            relativePath: relativePath,
            stage: stage,
            body: body,
            responsePolicy: responsePolicy
        )
        guard root["data"] as? Bool == true else {
            SafeLog.warning(
                "[Auth] response rejected stage=\(stage) reason=response_shape"
            )
            throw NetworkClientError.writeResultUnknown
        }
    }

    private func sendUnauthenticatedJSONMutation(
        config: AppConfig,
        relativePath: String,
        stage: String,
        body: Data,
        responsePolicy: V2BoardAPIResponsePolicy = .standard
    ) async throws -> [String: Any] {
        let plan = APIRecoveryPlan.forAPI(config)
        do {
            let result: JSONRoot = try await recoveryRouter.singleAttemptWrite(
                plan: plan,
                probe: { route in
                    try await self.probe(config: config, route: route)
                },
                submit: { route in
                    let root = try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "POST",
                        relativePath: relativePath,
                        stage: stage,
                        context: .login,
                        responsePolicy: responsePolicy,
                        body: body,
                        requestSafety: .nonIdempotentWrite,
                        requestKind: .apiWrite,
                        routeTransport: route.transport
                    )
                    return root
                }
            )
            return result.value
        } catch is NonIdempotentTransportFailure {
            SafeLog.warning("[Auth] write result unknown stage=\(stage) retry=false failover=false")
            throw NetworkClientError.writeResultUnknown
        }
    }

    private func probe(config: AppConfig, route: APIRecoveryRoute) async throws {
        let root = try await sendJSON(
            config: config,
            host: route.target,
            hostIndex: route.targetIndex,
            method: "GET",
            relativePath: Self.registrationConfigPath,
            stage: "routeProbe",
            context: .login,
            requestKind: .writeRouteProbe,
            routeTransport: route.transport
        )
        guard root["data"] as? [String: Any] != nil else {
            throw NetworkClientError.serviceUnavailable(
                "服务暂时不可用，请稍后重试",
                retryable: true
            )
        }
    }

    private func sendRetryableJSON<Result: Sendable>(
        config: AppConfig,
        method: String,
        relativePath: String,
        stage: String,
        context: V2BoardRequestContext,
        responsePolicy: V2BoardAPIResponsePolicy = .standard,
        body: Data? = nil,
        authData: String? = nil,
        requestKind: NetworkRequestKind = .apiRead,
        transform: @escaping @Sendable (JSONRoot, String, Int) throws -> Result
    ) async throws -> Result {
        let plan = APIRecoveryPlan.forAPI(config)
        return try await recoveryRouter.safeRetry(plan: plan) { route in
            let root = try await self.sendJSON(
                config: config,
                host: route.target,
                hostIndex: route.targetIndex,
                method: method,
                relativePath: relativePath,
                stage: stage,
                context: context,
                responsePolicy: responsePolicy,
                body: body,
                authData: authData,
                requestKind: requestKind,
                routeTransport: route.transport
            )
            return try transform(root, route.target, route.targetIndex)
        }
    }

    private func loginAgainstHost(
        config: AppConfig,
        email: String,
        password: String
    ) async throws -> HostValue<LoginCredential> {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])
        let plan = APIRecoveryPlan.forAPI(config)
        do {
            return try await recoveryRouter.singleAttemptWrite(
                plan: plan,
                probe: { route in try await self.probe(config: config, route: route) },
                submit: { route in
                    let root = try await self.sendJSON(
                        config: config, host: route.target, hostIndex: route.targetIndex,
                        method: "POST", relativePath: Self.loginPath,
                        stage: "authentication", context: .login,
                        responsePolicy: .authBusiness(.login), body: payload,
                        requestSafety: .nonIdempotentWrite, requestKind: .apiLogin,
                        routeTransport: route.transport
                    )
                    guard let data = root["data"] as? [String: Any],
                          let authData = Self.string(data["auth_data"])?.trimmed.nilIfEmpty else {
                        SafeLog.warning(
                            "[Login] response rejected stage=authentication "
                                + "hostIndex=\(route.targetIndex) reason=response_shape"
                        )
                        throw NetworkClientError.writeResultUnknown
                    }
                    SafeLog.info(
                        "[Login] authentication accepted hostIndex=\(route.targetIndex) "
                            + "authorization_present=true auth_data=<redacted> "
                            + "token_present=\(Self.string(data["token"]) != nil)"
                    )
                    return HostValue(
                        host: route.target,
                        value: LoginCredential(
                            authData: authData,
                            accountToken: Self.string(data["token"])
                        )
                    )
                }
            )
        } catch is NonIdempotentTransportFailure {
            SafeLog.warning("[Login] result unknown retry=false failover=false")
            throw NetworkClientError.writeResultUnknown
        }
    }
    private func fetchSubscriptionInfo(
        config: AppConfig,
        fallbackEmail: String,
        credential: LoginCredential
    ) async throws -> HostValue<SubscriptionSnapshot> {
        let plan = APIRecoveryPlan.forAPI(config)
        return try await recoveryRouter.safeRetry(plan: plan) { route in
            let root = try await self.sendJSON(
                config: config,
                host: route.target,
                hostIndex: route.targetIndex,
                method: "GET",
                relativePath: Self.subscriptionInfoPath,
                stage: "getSubscribe",
                context: .authenticated,
                authData: credential.authData,
                routeTransport: route.transport
            )
            guard let data = root["data"] as? [String: Any] else {
                SafeLog.warning("[Login] response rejected stage=getSubscribe reason=response_shape")
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试",
                    retryable: true
                )
            }
            let plan = data["plan"] as? [String: Any]
            let serverPlanName = Self.normalizedPlanName(Self.string(data["plan_name"]))
                ?? Self.normalizedPlanName(Self.string(plan?["name"]))
                ?? Self.normalizedPlanName(Self.string(data["planName"]))
            SafeLog.info(
                "[Login] getSubscribe verified hostIndex=\(route.targetIndex) authorization_present=true"
            )
            return HostValue(
                host: route.target,
                value: SubscriptionSnapshot(
                    email: Self.string(data["email"]) ?? fallbackEmail,
                    accountToken: Self.string(data["token"]),
                    subscriptionURL: Self.string(data["subscribe_url"])?.trimmed ?? "",
                    uploadBytes: Self.int64(data["u"]) ?? 0,
                    downloadBytes: Self.int64(data["d"]) ?? 0,
                    transferEnableBytes: Self.int64(data["transfer_enable"]) ?? 0,
                    expiredAt: Self.int64(data["expired_at"]) ?? 0,
                    planID: Self.int(data["plan_id"]),
                    serverPlanName: serverPlanName
                )
            )
        }
    }

    private func fetchCurrentPlanName(
        config: AppConfig,
        authData: String,
        planID: Int
    ) async throws -> String? {
        let plan = APIRecoveryPlan.forAPI(config)
        return try await recoveryRouter.safeRetry(plan: plan) { route in
            var lastError = NetworkClientError.transport("网络连接失败，请稍后重试")
            for (pathIndex, relativePath) in [Self.planListPath, Self.guestPlanListPath].enumerated() {
                do {
                    let root = try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "GET",
                        relativePath: relativePath,
                        stage: "planList",
                        context: .authenticated,
                        authData: authData,
                        routeTransport: route.transport
                    )
                    guard let data = root["data"] as? [[String: Any]] else {
                        throw NetworkClientError.serviceUnavailable(
                            "服务暂时不可用，请稍后重试",
                            retryable: true
                        )
                    }
                    let name = data.first { item in
                        Self.int(item["id"]) == planID && Self.int(item["show"]) != 0
                    }
                    .flatMap { Self.normalizedPlanName(Self.string($0["name"])) }
                    SafeLog.info(
                        "[Home] plan list refreshed hostIndex=\(route.targetIndex) "
                            + "endpointIndex=\(pathIndex + 1) current_plan_found=\(name != nil)"
                    )
                    return name
                } catch let error as NetworkClientError {
                    if case .authenticationExpired = error { throw error }
                    if !error.retryable { throw error }
                    lastError = error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = .transport("网络连接失败，请稍后重试")
                }
            }
            throw lastError
        }
    }

    private func fetchUserInfo(
        config: AppConfig,
        authData: String
    ) async throws -> HostValue<UserInfoSnapshot> {
        let plan = APIRecoveryPlan.forAPI(config)
        return try await recoveryRouter.safeRetry(plan: plan) { route in
            let root = try await self.sendJSON(
                config: config,
                host: route.target,
                hostIndex: route.targetIndex,
                method: "GET",
                relativePath: Self.userInfoPath,
                stage: "userInfo",
                context: .authenticated,
                authData: authData,
                routeTransport: route.transport
            )
            guard let data = root["data"] as? [String: Any] else {
                SafeLog.warning("[Login] response rejected stage=userInfo reason=response_shape")
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试",
                    retryable: true
                )
            }
            SafeLog.info(
                "[Login] userInfo verified hostIndex=\(route.targetIndex) authorization_present=true"
            )
            return HostValue(
                host: route.target,
                value: UserInfoSnapshot(
                    email: Self.string(data["email"]),
                    balanceCents: Self.int64(data["balance"])
                )
            )
        }
    }

    private func sendAuthenticatedRead(
        config: AppConfig,
        session userSession: UserSession,
        relativePath: String,
        stage: String,
        responsePolicy: V2BoardAPIResponsePolicy = .standard
    ) async throws -> [String: Any] {
        let root: JSONRoot = try await sendRetryableJSON(
            config: config,
            method: "GET",
            relativePath: relativePath,
            stage: stage,
            context: .authenticated,
            responsePolicy: responsePolicy,
            authData: userSession.authData
        ) { root, _, _ in root }
        return root.value
    }

    private func sendSingleAttemptWrite(
        config: AppConfig,
        session userSession: UserSession,
        relativePath: String,
        stage: String,
        bodyObject: [String: Any],
        responsePolicy: V2BoardAPIResponsePolicy = .standard,
        unknownError: PurchaseCommerceError
    ) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: bodyObject)
        let plan = APIRecoveryPlan.forAPI(config)
        do {
            let result: JSONRoot = try await recoveryRouter.singleAttemptWrite(
                plan: plan,
                probe: { route in
                    try await self.probe(config: config, route: route)
                },
                submit: { route in
                    let root = try await self.sendJSON(
                        config: config,
                        host: route.target,
                        hostIndex: route.targetIndex,
                        method: "POST",
                        relativePath: relativePath,
                        stage: stage,
                        context: .authenticated,
                        responsePolicy: responsePolicy,
                        body: body,
                        authData: userSession.authData,
                        requestSafety: .nonIdempotentWrite,
                        requestKind: .apiWrite,
                        routeTransport: route.transport
                    )
                    return root
                }
            )
            return result.value
        } catch is NonIdempotentTransportFailure {
            SafeLog.warning("[Purchase] write result unknown stage=\(stage) retry=false failover=false")
            throw unknownError
        } catch NetworkClientError.writeResultUnknown {
            throw unknownError
        }
    }

    private func sendJSON(
        config: AppConfig,
        host: String,
        hostIndex: Int,
        method: String,
        relativePath: String,
        stage: String,
        context: V2BoardRequestContext,
        responsePolicy: V2BoardAPIResponsePolicy = .standard,
        body: Data? = nil,
        authData: String? = nil,
        requestSafety: RequestSafety = .retryable,
        requestKind: NetworkRequestKind = .apiRead,
        routeTransport: (any NetworkTransport)? = nil
    ) async throws -> JSONRoot {
        try OperationDeadline.checkCurrent()
        let url = try AppConfig.apiURL(baseURL: host, relativePath: relativePath)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = OperationDeadline.requestTimeout(for: requestKind)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.safeUserAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let authData, !authData.isEmpty {
            request.setValue(authData, forHTTPHeaderField: "Authorization")
        }

        SafeLog.info(
            "[Login] request started stage=\(stage) hostIndex=\(hostIndex) "
                + "authorization_present=\(authData != nil)"
        )

        let responseData: Data
        let response: URLResponse
        let preparedRequest = request
        let selectedTransport = routeTransport ?? transport
        do {
            (responseData, response) = try await OperationDeadline.request(kind: requestKind) {
                try await selectedTransport.data(for: preparedRequest, kind: requestKind)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            SafeLog.warning("[Login] transport failed stage=\(stage) hostIndex=\(hostIndex)")
            if requestSafety == .nonIdempotentWrite {
                if Self.isSafePreflightFailure(error) {
                    // DNS/connect/TLS failed before an HTTP write could be sent.
                    // This is still a single attempt: the Router never replays it.
                    throw NetworkClientError.fromTransport(error)
                }
                throw NonIdempotentTransportFailure(
                    safeToTryNextHost: false
                )
            }
            throw NetworkClientError.fromTransport(error)
        } catch NetworkClientError.timedOut {
            try Task.checkCancellation()
            if requestSafety == .nonIdempotentWrite {
                throw NonIdempotentTransportFailure(safeToTryNextHost: false)
            }
            throw NetworkClientError.timedOut
        } catch {
            SafeLog.warning("[Login] transport failed stage=\(stage) hostIndex=\(hostIndex)")
            if requestSafety == .nonIdempotentWrite {
                throw NonIdempotentTransportFailure(safeToTryNextHost: false)
            }
            throw NetworkClientError.transport("网络连接失败，请稍后重试")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            SafeLog.warning("[Login] response rejected stage=\(stage) reason=non_http")
            if requestSafety == .nonIdempotentWrite { throw NetworkClientError.writeResultUnknown }
            throw NetworkClientError.serviceUnavailable(
                "服务暂时不可用，请稍后重试",
                retryable: true
            )
        }
        if requestSafety == .nonIdempotentWrite, (300...399).contains(httpResponse.statusCode) {
            // The original server has already received the write. Even a JSON
            // redirect body cannot establish an explicit business rejection.
            throw NetworkClientError.writeResultUnknown
        }
        SafeLog.info(
            "[Login] response received stage=\(stage) hostIndex=\(hostIndex) "
                + "http=\(httpResponse.statusCode)"
        )

        do {
            return JSONRoot(try V2BoardAPIErrorParser.decodeResponse(
                data: responseData,
                statusCode: httpResponse.statusCode,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                context: context,
                responsePolicy: responsePolicy
            ))
        } catch let error as NetworkClientError {
            if requestSafety == .nonIdempotentWrite {
                switch error {
                case .backendBusinessError, .authenticationExpired, .validation,
                     .invitationRejected,
                     .rateLimited, .orderCreationRejected, .changePasswordRejected,
                     .authBusinessRejected:
                    throw error
                default:
                    // Authenticated 401 and all 429 are classified by the
                    // parser before decoding. An unauthenticated HTTP 401 also
                    // explicitly rejects the write, even with an unusable body.
                    if httpResponse.statusCode == 401 {
                        throw NetworkClientError.backendBusinessError("")
                    }
                    // An ambiguous response after submission is never replayed.
                    throw NetworkClientError.writeResultUnknown
                }
            }
            throw error
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            text
        case let number as NSNumber:
            number.stringValue
        default:
            nil
        }
    }

    private static func path(_ base: String, tradeNo: String) throws -> String {
        var components = URLComponents()
        components.path = base
        components.queryItems = [URLQueryItem(name: "trade_no", value: tradeNo)]
        guard let value = components.string else { throw PurchaseCommerceError.invalidResponse }
        return value
    }

    private static func purchaseOrderDetail(
        _ data: [String: Any],
        fallbackTradeNo: String
    ) throws -> PurchaseOrderDetail {
        let plan = data["plan"] as? [String: Any]
        let period = string(data["period"])?.trimmed ?? ""
        guard let status = int(data["status"]), !period.isEmpty else {
            throw PurchaseCommerceError.invalidResponse
        }
        return PurchaseOrderDetail(
            tradeNo: string(data["trade_no"])?.trimmed.nilIfEmpty ?? fallbackTradeNo,
            status: status,
            checkoutType: int(data["type"]),
            planID: int(data["plan_id"]) ?? int(plan?["id"]) ?? 0,
            planName: string(plan?["name"])?.trimmed ?? "",
            period: period,
            planPriceCents: max(0, int64(plan?[period]) ?? 0),
            totalAmountCents: max(0, int64(data["total_amount"]) ?? 0),
            discountAmountCents: max(0, int64(data["discount_amount"]) ?? 0),
            surplusAmountCents: max(0, int64(data["surplus_amount"]) ?? 0),
            balanceAmountCents: max(0, int64(data["balance_amount"]) ?? 0),
            refundAmountCents: max(0, int64(data["refund_amount"]) ?? 0),
            handlingAmountCents: max(0, int64(data["handling_amount"]) ?? 0)
        )
    }

    private static func orderListItems(_ value: Any?) -> [Any]? {
        if let items = value as? [Any] { return items }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["data", "orders", "list"] {
            if let items = object[key] as? [Any] { return items }
        }
        return nil
    }

    private static func purchaseOrderRecord(_ item: Any) -> PurchaseOrderRecord? {
        guard let data = item as? [String: Any],
              let tradeNo = (string(data["trade_no"]) ?? string(data["tradeNo"]))?.trimmed.nilIfEmpty,
              let status = int(data["status"]) else {
            return nil
        }
        let plan = data["plan"] as? [String: Any]
        let period = string(data["period"])?.trimmed ?? ""
        return PurchaseOrderRecord(
            tradeNo: tradeNo,
            status: status,
            planID: int(data["plan_id"]) ?? int(plan?["id"]) ?? 0,
            planName: string(plan?["name"])?.trimmed.nilIfEmpty
                ?? string(data["plan_name"])?.trimmed.nilIfEmpty
                ?? string(data["planName"])?.trimmed.nilIfEmpty
                ?? "",
            period: period,
            planPriceCents: int64(plan?[period]),
            totalAmountCents: int64(data["total_amount"]),
            discountAmountCents: int64(data["discount_amount"]),
            surplusAmountCents: int64(data["surplus_amount"]),
            balanceAmountCents: int64(data["balance_amount"]),
            refundAmountCents: int64(data["refund_amount"]),
            handlingAmountCents: int64(data["handling_amount"]),
            paymentMethodName: paymentMethodName(data),
            createdAtUnix: firstUnixTime(
                data,
                keys: ["created_at", "createdAt", "create_time", "created_time"]
            ),
            paidAtUnix: firstUnixTime(
                data,
                keys: ["paid_at", "paidAt", "pay_time", "paid_time"]
            ),
            expiresAtUnix: firstUnixTime(
                data,
                keys: [
                    "expired_at", "expire_at", "expires_at", "expired_time",
                    "expire_time", "timeout_at", "order_expired_at"
                ]
            )
        )
    }

    private static func paymentMethodName(_ data: [String: Any]) -> String? {
        for key in ["payment", "payment_method", "method"] {
            if let object = data[key] as? [String: Any] {
                for field in ["name", "payment", "title"] {
                    if let value = string(object[field])?.trimmed.nilIfEmpty { return value }
                }
            } else if let value = string(data[key])?.trimmed.nilIfEmpty {
                return value
            }
        }
        return string(data["payment_name"])?.trimmed.nilIfEmpty
            ?? string(data["payment_method_name"])?.trimmed.nilIfEmpty
    }

    private static func firstUnixTime(
        _ data: [String: Any],
        keys: [String]
    ) -> Int64? {
        for key in keys {
            if let value = int64(data[key]), value > 0 { return value }
        }
        return nil
    }

    private static func profileInviteCode(_ item: Any) -> ProfileInviteCode? {
        guard let data = item as? [String: Any],
              let code = string(data["code"])?.trimmed.nilIfEmpty else {
            return nil
        }
        return ProfileInviteCode(
            id: int(data["id"]) ?? 0,
            code: code,
            status: int(data["status"]) ?? 0,
            pageViews: int(data["pv"]) ?? 0,
            createdAtUnix: firstUnixTime(
                data,
                keys: ["created_at", "createdAt", "create_time", "created_time"]
            )
        )
    }

    private static func inviteStat(_ stat: [Int64], index: Int) -> Int64 {
        guard stat.indices.contains(index) else { return 0 }
        return stat[index]
    }

    private static func profileTrafficLogRecord(_ item: Any) -> ProfileTrafficLogRecord? {
        guard let data = item as? [String: Any],
              let uploadBytes = int64(data["u"]),
              let downloadBytes = int64(data["d"]),
              let recordAtUnix = int64(data["record_at"]),
              recordAtUnix > 0 else {
            return nil
        }
        return ProfileTrafficLogRecord(
            uploadBytes: max(0, uploadBytes),
            downloadBytes: max(0, downloadBytes),
            recordAtUnix: recordAtUnix,
            serverRate: max(0, double(data["server_rate"]) ?? 0)
        )
    }

    private static func safeHTTPURL(_ value: String?) -> URL? {
        guard let text = value?.trimmed.nilIfEmpty,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private static func normalizedPlanName(_ value: String?) -> String? {
        guard let name = value?.trimmed.nilIfEmpty, name != "未订阅套餐" else { return nil }
        return name
    }

    private static func purchasePlan(_ item: [String: Any]) -> PurchasePlan? {
        guard let id = int(item["id"]), id > 0 else { return nil }

        let cycles = PurchasePlanPeriod.allCases.compactMap { period -> PurchasePlanCycle? in
            guard let priceCents = int64(item[period.rawValue]), priceCents > 0 else { return nil }
            return PurchasePlanCycle(period: period, priceCents: priceCents)
        }
        guard !cycles.isEmpty else { return nil }

        let content = purchasePlanContent(item)
        return PurchasePlan(
            id: id,
            name: string(item["name"])?.trimmed ?? "",
            content: content,
            sort: int(item["sort"]) ?? 0,
            cycles: cycles,
            features: PurchasePlanFeatureParser.parse(content)
        )
    }

    private static func purchasePlanContent(_ item: [String: Any]) -> String {
        for key in ["content", "description", "desc"] {
            if let value = string(item[key])?.trimmed.nilIfEmpty {
                return value
            }
        }
        for key in ["features", "feature"] {
            guard let value = item[key], JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: data, encoding: .utf8) else { continue }
            return text
        }
        return ""
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        int64(value).flatMap(Int.init)
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func boolFlag(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool:
            flag
        case let number as NSNumber:
            number.intValue != 0
        case let text as String:
            ["1", "true", "yes", "on"].contains(text.trimmed.lowercased())
        default:
            false
        }
    }

    private static func noticeTags(_ value: Any?) -> [String] {
        let rawTags: [String]
        if let values = value as? [Any] {
            rawTags = values.compactMap(string)
        } else if let tag = string(value) {
            rawTags = [tag]
        } else {
            rawTags = []
        }
        return rawTags
            .map(\.trimmed)
            .filter { !$0.isEmpty }
    }

    private static func parseEmailWhitelist(_ value: Any?) -> (enabled: Bool, suffixes: [String]) {
        let enabled: Bool
        let rawSuffixes: [String]

        switch value {
        case let values as [Any]:
            enabled = true
            rawSuffixes = values.compactMap(string)
        case let text as String:
            let normalized = text.trimmed
            enabled = !normalized.isEmpty && normalized != "0"
            rawSuffixes = enabled
                ? normalized.components(separatedBy: CharacterSet(charactersIn: ",;|\n"))
                : []
        case let flag as Bool:
            enabled = flag
            rawSuffixes = []
        case let number as NSNumber:
            enabled = number.intValue != 0
            rawSuffixes = []
        default:
            enabled = false
            rawSuffixes = []
        }

        var seen = Set<String>()
        let suffixes = rawSuffixes.compactMap { rawValue -> String? in
            let domain = rawValue.trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                .lowercased()
            guard domain.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#,
                options: .regularExpression
            ) != nil else {
                return nil
            }
            let suffix = "@" + domain
            guard seen.insert(suffix).inserted else { return nil }
            return suffix
        }
        return (enabled, suffixes)
    }

    private static func isSafePreflightFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .badURL,
             .unsupportedURL,
             .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            true
        default:
            false
        }
    }
}

private enum PurchasePlanFeatureParser {
    static func parse(_ content: String) -> [PurchasePlanFeature] {
        let trimmed = content.trimmed
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) {
            return unique(parseJSON(value))
        }
        return unique(parsePlainText(trimmed))
    }

    private static func parseJSON(_ value: Any) -> [PurchasePlanFeature] {
        switch value {
        case let values as [Any]:
            return values.flatMap(parseJSON)
        case let object as [String: Any]:
            if let feature = namedFeature(object) { return [feature] }
            return object.flatMap { key, value -> [PurchasePlanFeature] in
                if ["support", "description", "desc"].contains(key.lowercased()) { return [] }
                if let supported = value as? Bool {
                    return [PurchasePlanFeature(text: key, isSupported: supported)]
                }
                if let text = scalarText(value)?.trimmed.nilIfEmpty {
                    return [PurchasePlanFeature(text: "\(key)：\(text)", isSupported: true)]
                }
                return parseJSON(value)
            }
        case let text as String:
            return parsePlainText(text)
        default:
            return []
        }
    }

    private static func namedFeature(_ object: [String: Any]) -> PurchasePlanFeature? {
        func value(for keys: [String]) -> String? {
            for key in keys {
                guard let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
                      let text = scalarText(match.value)?.trimmed.nilIfEmpty else { continue }
                return text
            }
            return nil
        }

        let name = value(for: ["name", "title", "label", "feature", "text", "content"])
        let detail = value(for: ["value"])
        guard name != nil || detail != nil else { return nil }
        let text: String
        switch (name, detail) {
        case let (name?, detail?): text = "\(name)：\(detail)"
        case let (name?, nil): text = name
        case let (nil, detail?): text = detail
        case (nil, nil): return nil
        }
        let support = object.first { $0.key.caseInsensitiveCompare("support") == .orderedSame }?.value
        return PurchasePlanFeature(text: text, isSupported: (support as? Bool) ?? true)
    }

    private static func parsePlainText(_ content: String) -> [PurchasePlanFeature] {
        var normalized = content.replacingOccurrences(
            of: #"<\s*(br|/p|/div|/li)\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        normalized = normalized
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        return normalized
            .components(separatedBy: CharacterSet(charactersIn: "\r\n；;"))
            .compactMap { raw -> PurchasePlanFeature? in
                let text = clean(raw)
                guard !text.isEmpty else { return nil }
                return PurchasePlanFeature(
                    text: text,
                    isSupported: !text.hasPrefix("不支持") && !text.hasPrefix("不含")
                )
            }
    }

    private static func clean(_ value: String) -> String {
        var text = value.trimmed.trimmingCharacters(
            in: CharacterSet(charactersIn: "[],{}\"' -*•·，,")
        ).trimmed
        guard !text.isEmpty,
              !["true", "false"].contains(text.lowercased()),
              text.range(of: #"^\"?support\"?\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            return ""
        }
        text = text.replacingOccurrences(
            of: #"^\"?(feature|features|text|content|name|title|label)\"?\s*[:：]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return text.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"' -*•·，,"))
    }

    private static func unique(_ features: [PurchasePlanFeature]) -> [PurchasePlanFeature] {
        var seen = Set<String>()
        return features.compactMap { feature in
            let text = clean(feature.text)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return nil }
            return PurchasePlanFeature(text: text, isSupported: feature.isSupported)
        }
    }

    private static func scalarText(_ value: Any) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

private enum RequestSafety: Equatable {
    case retryable
    case nonIdempotentWrite
}

private struct NonIdempotentTransportFailure: Error {
    let safeToTryNextHost: Bool
}

private struct LoginCredential: Sendable {
    let authData: String
    let accountToken: String?
}

private struct SubscriptionSnapshot: Sendable {
    let email: String
    let accountToken: String?
    let subscriptionURL: String
    let uploadBytes: Int64
    let downloadBytes: Int64
    let transferEnableBytes: Int64
    let expiredAt: Int64
    let planID: Int?
    let serverPlanName: String?
}

private struct UserInfoSnapshot: Sendable {
    let email: String?
    let balanceCents: Int64?
}

private struct HostValue<Value: Sendable>: Sendable {
    let host: String
    let value: Value
}

private struct JSONRoot: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }

    subscript(key: String) -> Any? {
        value[key]
    }
}
