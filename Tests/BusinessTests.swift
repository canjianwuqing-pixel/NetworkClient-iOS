import XCTest
import Security
import Yams
import Network
import WebKit
import UIKit
@testable import NetworkClient

final class BusinessTests: XCTestCase {
    func testNodesLoadingPresentationSeparatesInitialLoadFromRefresh() {
        XCTAssertEqual(
            NodesLoadingPresentation.phase(hasNodes: false, loadState: .loading),
            .initial
        )
        XCTAssertEqual(
            NodesLoadingPresentation.phase(hasNodes: true, loadState: .loading),
            .refreshing
        )
    }

    func testNodesLoadingPresentationIsInactiveOutsideLoadingState() {
        for hasNodes in [false, true] {
            XCTAssertEqual(
                NodesLoadingPresentation.phase(hasNodes: hasNodes, loadState: .idle),
                .none
            )
            XCTAssertEqual(
                NodesLoadingPresentation.phase(hasNodes: hasNodes, loadState: .loaded),
                .none
            )
        }
    }

    func testHomeVPNPresentationUsesStateTitlesOutsideDisconnecting() {
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .disconnected,
                operation: .idle,
                disconnectActionPending: false
            ),
            "vpn.state.disconnected"
        )
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .connecting,
                operation: .connecting,
                disconnectActionPending: false
            ),
            "vpn.state.connecting"
        )
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .connected,
                operation: .idle,
                disconnectActionPending: false
            ),
            "vpn.state.connected"
        )
    }

    func testHomeVPNPresentationPrioritizesDisconnectingOverTransientState() {
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .connected,
                operation: .disconnecting,
                disconnectActionPending: false
            ),
            "vpn.state.disconnecting"
        )
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .connecting,
                operation: .disconnecting,
                disconnectActionPending: false
            ),
            "vpn.state.disconnecting"
        )
    }

    func testHomeVPNPowerButtonPreservesExistingAvailabilityAndDisablesDisconnecting() {
        XCTAssertFalse(HomeVPNPresentation.isPowerButtonDisabled(
            state: .disconnected,
            operation: .idle,
            disconnectActionPending: false
        ))
        XCTAssertFalse(HomeVPNPresentation.isPowerButtonDisabled(
            state: .connected,
            operation: .idle,
            disconnectActionPending: false
        ))
        XCTAssertFalse(HomeVPNPresentation.isPowerButtonDisabled(
            state: .connecting,
            operation: .connecting,
            disconnectActionPending: false
        ))
        XCTAssertTrue(HomeVPNPresentation.isPowerButtonDisabled(
            state: .disconnected,
            operation: .connecting,
            disconnectActionPending: false
        ))
        XCTAssertTrue(HomeVPNPresentation.isPowerButtonDisabled(
            state: .connected,
            operation: .disconnecting,
            disconnectActionPending: false
        ))
        XCTAssertTrue(HomeVPNPresentation.isPowerButtonDisabled(
            state: .connecting,
            operation: .disconnecting,
            disconnectActionPending: false
        ))
    }

    func testHomeVPNDisconnectLatchSynchronouslyRejectsRapidTaps() {
        var disconnectActionPending = false
        var acceptedActionCount = 0

        for _ in 0..<5 {
            if HomeVPNPresentation.beginPowerAction(
                state: .connected,
                operation: .idle,
                disconnectActionPending: &disconnectActionPending
            ) {
                acceptedActionCount += 1
            }
        }

        XCTAssertTrue(disconnectActionPending)
        XCTAssertEqual(acceptedActionCount, 1)
    }

    func testHomeVPNDisconnectLatchImmediatelyDrivesStoppingPresentation() {
        var disconnectActionPending = false
        XCTAssertTrue(HomeVPNPresentation.beginPowerAction(
            state: .connected,
            operation: .idle,
            disconnectActionPending: &disconnectActionPending
        ))

        XCTAssertTrue(HomeVPNPresentation.isPowerButtonDisabled(
            state: .connected,
            operation: .idle,
            disconnectActionPending: disconnectActionPending
        ))
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .connected,
                operation: .idle,
                disconnectActionPending: disconnectActionPending
            ),
            "vpn.state.disconnecting"
        )
    }

    func testHomeVPNDisconnectOperationTakesOverAndStillRejectsActions() {
        var disconnectActionPending = true
        XCTAssertFalse(HomeVPNPresentation.beginPowerAction(
            state: .connecting,
            operation: .disconnecting,
            disconnectActionPending: &disconnectActionPending
        ))
        XCTAssertTrue(HomeVPNPresentation.isPowerButtonDisabled(
            state: .connecting,
            operation: .disconnecting,
            disconnectActionPending: disconnectActionPending
        ))
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .connecting,
                operation: .disconnecting,
                disconnectActionPending: disconnectActionPending
            ),
            "vpn.state.disconnecting"
        )
    }

    func testHomeVPNDisconnectLatchReleasesForCompletionFailureAndCancellation() {
        enum ExpectedFailure: Error { case failed }

        func runAction(throwing error: Error?) -> Bool {
            var disconnectActionPending = false
            guard HomeVPNPresentation.beginPowerAction(
                state: .connected,
                operation: .idle,
                disconnectActionPending: &disconnectActionPending
            ) else { return disconnectActionPending }
            let latchedDisconnectAction = disconnectActionPending
            do {
                defer {
                    HomeVPNPresentation.endPowerAction(
                        latchedDisconnectAction: latchedDisconnectAction,
                        disconnectActionPending: &disconnectActionPending
                    )
                }
                if let error { throw error }
            } catch {}
            return disconnectActionPending
        }

        XCTAssertFalse(runAction(throwing: nil))
        XCTAssertFalse(runAction(throwing: ExpectedFailure.failed))
        XCTAssertFalse(runAction(throwing: CancellationError()))
    }

    func testHomeVPNDisconnectCompletionRestoresNormalPresentationAndConnectingCancel() {
        var disconnectActionPending = true
        HomeVPNPresentation.endPowerAction(
            latchedDisconnectAction: true,
            disconnectActionPending: &disconnectActionPending
        )

        XCTAssertFalse(disconnectActionPending)
        XCTAssertFalse(HomeVPNPresentation.isPowerButtonDisabled(
            state: .disconnected,
            operation: .idle,
            disconnectActionPending: disconnectActionPending
        ))
        XCTAssertEqual(
            HomeVPNPresentation.statusTitleKey(
                state: .disconnected,
                operation: .idle,
                disconnectActionPending: disconnectActionPending
            ),
            "vpn.state.disconnected"
        )

        XCTAssertTrue(HomeVPNPresentation.beginPowerAction(
            state: .connecting,
            operation: .connecting,
            disconnectActionPending: &disconnectActionPending
        ))
        XCTAssertFalse(disconnectActionPending)
    }

    func testAuthScrollPolicyDisablesScrollingWhenContentFits() {
        XCTAssertFalse(AuthScrollPolicy.allowsScrolling(
            contentHeight: 760,
            availableHeight: 760
        ))
        XCTAssertFalse(AuthScrollPolicy.allowsScrolling(
            contentHeight: 760.5,
            availableHeight: 760
        ))
    }

    func testCompactAuthTitleSpacingIsThirtyTwoPoints() {
        XCTAssertEqual(AuthLayoutMetrics.titleToFirstFieldSpacing, 32)
    }

    func testAuthScrollPolicyAllowsOnlyRealOverflow() {
        XCTAssertTrue(AuthScrollPolicy.allowsScrolling(
            contentHeight: 762,
            availableHeight: 760
        ))
        XCTAssertTrue(AuthScrollPolicy.allowsScrolling(
            contentHeight: 640,
            availableHeight: 390
        ))
    }

    func testAuthVerificationCodeNormalizesToSixDigits() {
        XCTAssertEqual(
            AuthVerificationCodePolicy.normalizedCode("12a3 4567"),
            "123456"
        )
        XCTAssertEqual(
            AuthVerificationCodePolicy.normalizedCode("１２３456"),
            "１２３456"
        )
    }

    func testAuthVerificationCodeAdvancesOnlyWhenSixthDigitArrives() {
        XCTAssertTrue(AuthVerificationCodePolicy.shouldAdvanceToNewPassword(
            previous: "12345",
            current: "123456"
        ))
        XCTAssertFalse(AuthVerificationCodePolicy.shouldAdvanceToNewPassword(
            previous: "123456",
            current: "123456"
        ))
        XCTAssertFalse(AuthVerificationCodePolicy.shouldAdvanceToNewPassword(
            previous: "1234",
            current: "12345"
        ))
    }

    func testNodeLatencyDisplayMatchesMacOSAndPreservesActualValue() throws {
        for (ratio, expected) in [
            (0.0, 100), (-1.0, 100), (0.05, 100), (0.1, 10),
            (0.4, 40), (1.0, 100), (10.0, 1_000), (11.0, 100),
            (Double.nan, 100), (Double.infinity, 100)
        ] {
            let reading = try XCTUnwrap(NodeLatencyReading(
                actualMilliseconds: 100, displayRatio: ratio
            ))
            XCTAssertEqual(reading.actualMilliseconds, 100)
            XCTAssertEqual(reading.displayMilliseconds, expected)
        }
        XCTAssertEqual(NodeLatencyReading(
            actualMilliseconds: 101, displayRatio: 0.5
        )?.displayMilliseconds, 51)
        XCTAssertEqual(NodeLatencyReading(
            actualMilliseconds: Int.max, displayRatio: 10
        )?.displayMilliseconds, Int.max)
        XCTAssertNil(NodeLatencyReading(actualMilliseconds: -1, displayRatio: 1))
    }
    func testRegistrationValidationRequiresMatchingPasswords() {
        XCTAssertThrowsError(try AuthValidation.validate(email: "person@example.invalid", password: "a", confirmation: "b"))
    }
    func testRegistrationHonorsWhitelistAndCode() {
        let rules = V2BoardRegistrationConfig(requiresEmailVerification: true, requiresInvitation: true,
            requiresRecaptcha: false, emailWhitelistEnabled: true, emailWhitelistSuffixes: ["example.invalid"])
        XCTAssertThrowsError(try AuthValidation.validate(email: "person@other.invalid", password: "a", registration: rules, emailCode: "123", inviteCode: "inv"))
        XCTAssertThrowsError(try AuthValidation.validate(email: "person@example.invalid", password: "a", registration: rules))
        XCTAssertNoThrow(try AuthValidation.validate(email: "person@example.invalid", password: "a", registration: rules, emailCode: "123", inviteCode: "inv"))
    }
    func testRequestURLKeepsExistingFlagAndRemovesDuplicates() throws {
        let url = try SubscriptionFetcher.requestURL(from: "https://example.invalid/sub?token=fake&flag=meta&flag=other")
        let flags = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "flag" }
        XCTAssertEqual(flags?.count, 1); XCTAssertEqual(flags?.first?.value, "meta")
    }
    func testRequestURLDefaultsToMetaAndRejectsFile() throws {
        XCTAssertTrue(try SubscriptionFetcher.requestURL(from: "https://example.invalid/sub").absoluteString.contains("flag=meta"))
        XCTAssertThrowsError(try SubscriptionFetcher.requestURL(from: "file:///secret"))
    }
    func testErrorParserHidesServerDebugDetails() {
        let data = Data(#"{"message":"bad","trace":"secret"}"#.utf8)
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(data: data, statusCode: 500, contentType: "application/json", context: .login)) { error in
            guard let value = error as? NetworkClientError else { return XCTFail("Unexpected error") }
            XCTAssertFalse(value.localizedDescription.contains("secret"))
        }
    }
    func testAuthenticatedExpiredResponse() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(data: Data(#"{"message":"Unauthenticated"}"#.utf8), statusCode: 401, contentType: "application/json", context: .authenticated)) { error in
            guard case NetworkClientError.authenticationExpired = error else { return XCTFail("Expected expiration") }
        }
    }
    func testHTTPBusinessAndInfrastructureErrorsAreDistinct() {
        let cases: [(Int, String, V2BoardRequestContext, String, Bool)] = [
            (400, #"{"message":"Invalid input"}"#, .login, "backend_business", false),
            (401, #"{"message":"Incorrect credentials"}"#, .login, "backend_business", false),
            (403, #"{"message":"Permission denied"}"#, .authenticated, "backend_business", false),
            (422, #"{"message":"Incorrect code","data":false}"#, .login, "backend_business", false),
            (429, #"{"message":"Too many requests"}"#, .login, "rate_limited", false),
            (500, #"{"message":"Internal error"}"#, .login, "service_unavailable", true),
            (500, #"{"message":"Order rejected","data":false}"#, .authenticated, "backend_business", false)
        ]
        for (status, body, context, category, retryable) in cases {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: Data(body.utf8), statusCode: status,
                contentType: "application/json", context: context
            )) { error in
                guard let value = error as? NetworkClientError else { return XCTFail("Unexpected error") }
                XCTAssertEqual(value.logCategory, category, "HTTP \(status): \(body)")
                XCTAssertEqual(value.retryable, retryable)
                XCTAssertFalse(String(describing: value.userFacingMessage).contains("Internal error"))
            }
        }
    }

    func testCouponCheckPolicyAcceptsSafeMessageOnly500ButStandardPolicyDoesNot() {
        let body = Data(#"{"message":"This coupon has expired"}"#.utf8)

        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: body,
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .couponCheck
        )) { error in
            guard case let NetworkClientError.backendBusinessError(message) = error else {
                return XCTFail("Expected coupon business rejection")
            }
            XCTAssertEqual(message, "This coupon has expired")
        }

        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: body,
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated
        )) { error in
            guard let value = error as? NetworkClientError else {
                return XCTFail("Unexpected error")
            }
            XCTAssertEqual(value.logCategory, "service_unavailable")
        }
    }

    func testCouponCheckPolicyStillRejectsUnsafeServerDetails() {
        let body = Data(#"{"message":"This coupon has expired","trace":"secret"}"#.utf8)

        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: body,
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .couponCheck
        )) { error in
            guard let value = error as? NetworkClientError else {
                return XCTFail("Unexpected error")
            }
            XCTAssertEqual(value.logCategory, "service_unavailable")
        }
    }

    func testChangePasswordPolicyPresentsSafeMessageOnly500WithoutChangingStandardPolicy() {
        for expected in ["The old password is wrong", "Save failed", "旧密码有误", "保存失败"] {
            let body = Data(#"{"message":"\#(expected)"}"#.utf8)

            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: body,
                statusCode: 500,
                contentType: "application/json",
                context: .authenticated,
                responsePolicy: .changePassword
            )) { error in
                guard case let NetworkClientError.changePasswordRejected(message) = error else {
                    return XCTFail("Expected change-password business rejection")
                }
                XCTAssertEqual(message, expected)
                XCTAssertEqual(
                    (error as? NetworkClientError)?.userFacingMessage,
                    .verbatim(expected)
                )
            }

            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: body,
                statusCode: 500,
                contentType: "application/json",
                context: .authenticated
            )) { error in
                XCTAssertEqual((error as? NetworkClientError)?.logCategory, "service_unavailable")
            }
        }
    }

    func testChangePasswordPolicyRejectsUnsafeNonJSONAndPreserves401() {
        for (contentType, body) in [
            ("application/json", #"{"message":"Save failed","trace":"secret"}"#),
            ("application/json", #"{"message":"Save failed","data":{"debug":{"exception":"secret"}}}"#),
            ("application/json", #"{"data":{"message":"Save failed","details":{"file":"/internal/server.php"}}}"#),
            ("text/html", "<html>Save failed</html>"),
            ("application/json", "not-json")
        ] {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: Data(body.utf8),
                statusCode: 500,
                contentType: contentType,
                context: .authenticated,
                responsePolicy: .changePassword
            )) { error in
                XCTAssertEqual((error as? NetworkClientError)?.logCategory, "service_unavailable")
            }
        }

        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Unauthenticated"}"#.utf8),
            statusCode: 401,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .changePassword
        )) { error in
            XCTAssertEqual((error as? NetworkClientError)?.logCategory, "authentication_expired")
        }
    }

    func testOrderCreationPolicyPresentsSafeBackendMessageWithoutChangingStandardPolicy() {
        let known = Data(#"{"message":"You have an unpaid or pending order, please try again later or cancel it"}"#.utf8)
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: known,
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .orderCreation
        )) { error in
            guard case let NetworkClientError.orderCreationRejected(message) = error else {
                return XCTFail("Expected a definite order creation rejection")
            }
            XCTAssertEqual(message, "You have an unpaid or pending order, please try again later or cancel it")
        }

        let unknown = Data(#"{"message":"Synthetic rejection"}"#.utf8)
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: unknown, statusCode: 500, contentType: "application/json",
            context: .authenticated
        )) { error in
            XCTAssertEqual((error as? NetworkClientError)?.logCategory, "service_unavailable")
        }
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: unknown, statusCode: 500, contentType: "application/json",
            context: .authenticated, responsePolicy: .orderCreation
        )) { error in
            guard case let NetworkClientError.orderCreationRejected(message) = error else {
                return XCTFail("Expected the order-save backend message")
            }
            XCTAssertEqual(message, "Synthetic rejection")
        }
    }

    func testAuthBusinessPoliciesPresentSafeMessageOnly500WithoutChangingStandardPolicy() {
        let body = Data(#"{"message":"邮箱验证码有误"}"#.utf8)

        for endpoint in V2BoardAuthEndpoint.allCases {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: body,
                statusCode: 500,
                contentType: "application/json",
                context: .login,
                responsePolicy: .authBusiness(endpoint)
            )) { error in
                guard case let NetworkClientError.authBusinessRejected(actualEndpoint, message) = error else {
                    return XCTFail("Expected a definite Auth business rejection")
                }
                XCTAssertEqual(actualEndpoint, endpoint)
                XCTAssertEqual(message, "邮箱验证码有误")
                XCTAssertEqual((error as? NetworkClientError)?.userFacingMessage, .verbatim("邮箱验证码有误"))
                XCTAssertFalse((error as? NetworkClientError)?.retryable ?? true)
            }
        }

        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: body,
            statusCode: 500,
            contentType: "application/json",
            context: .login
        )) { error in
            XCTAssertEqual((error as? NetworkClientError)?.logCategory, "service_unavailable")
        }
    }

    func testAuthBusinessPolicyRejectsUnsafeOrNonJSONServerDetails() {
        for (contentType, body) in [
            ("application/json", #"{"message":"邮箱验证码有误","trace":"secret"}"#),
            ("application/json", #"{"data":{"message":"邮箱验证码有误","trace":"secret"}}"#),
            ("text/html", "<html>邮箱验证码有误</html>"),
            ("application/json", "not-json")
        ] {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: Data(body.utf8),
                statusCode: 500,
                contentType: contentType,
                context: .login,
                responsePolicy: .authBusiness(.forget)
            )) { error in
                XCTAssertEqual((error as? NetworkClientError)?.logCategory, "service_unavailable")
            }
        }
    }

    func testAuthBusinessPolicyPreserves401AndPresentsSafeRateLimitMessage() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Unauthenticated"}"#.utf8),
            statusCode: 401,
            contentType: "application/json",
            context: .login,
            responsePolicy: .authBusiness(.login)
        )) { error in
            XCTAssertEqual((error as? NetworkClientError)?.logCategory, "backend_business")
        }

        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Too many requests"}"#.utf8),
            statusCode: 429,
            contentType: "application/json",
            context: .login,
            responsePolicy: .authBusiness(.emailVerification)
        )) { error in
            guard case let NetworkClientError.authBusinessRejected(endpoint, message) = error else {
                return XCTFail("Expected endpoint-specific rate-limit feedback")
            }
            XCTAssertEqual(endpoint, .emailVerification)
            XCTAssertEqual(message, "Too many requests")
            XCTAssertEqual((error as? NetworkClientError)?.userFacingMessage, .verbatim("Too many requests"))
        }
    }

    func testV2BoardAuthBusinessMessageMatrixStaysVerbatimAndEndpointScoped() {
        let cases: [(V2BoardAuthEndpoint, String)] = [
            (.login, "邮箱或密码错误"),
            (.login, "该账户已被停止使用"),
            (.login, "密码错误次数过多，请 5 分钟后再试"),
            (.register, "邮箱验证码有误"),
            (.register, "邮箱已在系统中存在"),
            (.register, "邀请码无效"),
            (.register, "必须使用邀请码才可以注册"),
            (.register, "本站已关闭注册"),
            (.register, "邮箱后缀不处于白名单中"),
            (.register, "不支持 Gmail 别名邮箱"),
            (.register, "注册频繁，请等待 5 分钟后再次尝试"),
            (.register, "注册失败"),
            (.forget, "邮箱验证码有误"),
            (.forget, "该邮箱不存在系统中"),
            (.forget, "重置失败，请稍后再试"),
            (.forget, "重置失败"),
            (.emailVerification, "验证码已发送，请过一会儿再请求"),
            (.emailVerification, "邮箱格式错误"),
            (.emailVerification, "该邮箱不存在系统中"),
            (.emailVerification, "该邮箱已存在"),
            (.emailVerification, "邮箱后缀不处于白名单中"),
            (.emailVerification, "不支持 Gmail 别名邮箱"),
            (.emailVerification, "Too many requests, please try again later.")
        ]

        for (endpoint, expected) in cases {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: try JSONSerialization.data(withJSONObject: ["message": expected]),
                statusCode: 500,
                contentType: "application/json",
                context: .login,
                responsePolicy: .authBusiness(endpoint)
            )) { error in
                guard case let NetworkClientError.authBusinessRejected(actualEndpoint, message) = error else {
                    return XCTFail("Expected \(endpoint) business rejection for \(expected)")
                }
                XCTAssertEqual(actualEndpoint, endpoint)
                XCTAssertEqual(message, expected)
                XCTAssertEqual((error as? NetworkClientError)?.userFacingMessage, .verbatim(expected))
            }
        }
    }

    func testAuthenticated401ExpiresButLogin401DoesNot() {
        let body = Data(#"{"message":"Wrong password"}"#.utf8)
        for context in [V2BoardRequestContext.login, .authenticated] {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: body, statusCode: 401, contentType: "application/json", context: context
            )) { error in
                guard let value = error as? NetworkClientError else { return XCTFail("Unexpected error") }
                XCTAssertEqual(value.logCategory, context == .login ? "backend_business" : "authentication_expired")
                XCTAssertFalse(value.retryable)
            }
        }
    }

    func testMalformedJSONAndHTMLDoNotExposeResponseOrBecomeBusinessErrors() {
        for (status, type, body) in [
            (200, "application/json", "not-json"),
            (500, "text/html", "<html>internal trace and secrets</html>"),
            (500, "application/json", #"{"message":"temporary failure"}"#)
        ] {
            XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
                data: Data(body.utf8), statusCode: status,
                contentType: type, context: .login
            )) { error in
                guard let value = error as? NetworkClientError else { return XCTFail("Unexpected error") }
                XCTAssertTrue(value.retryable)
                XCTAssertNotEqual(value.logCategory, "backend_business")
                XCTAssertFalse(String(describing: value.userFacingMessage).contains("secrets"))
            }
        }
    }

    func testTransportCategoriesAndUncertainWriteFeedback() {
        let cases: [(URLError.Code, String)] = [
            (.dnsLookupFailed, "dns"), (.secureConnectionFailed, "tls"),
            (.timedOut, "timeout"), (.notConnectedToInternet, "offline")
        ]
        for (code, category) in cases {
            let error = NetworkClientError.fromTransport(URLError(code))
            XCTAssertEqual(error.logCategory, category)
            XCTAssertTrue(error.retryable)
        }
        XCTAssertFalse(NetworkClientError.writeResultUnknown.retryable)
        XCTAssertEqual(NetworkClientError.writeResultUnknown.userFacingMessage,
                       .localized(L10nKey.errorWriteResultUnknown))
    }

    @MainActor
    func testAuthenticationValidationStaysOnFormWithoutGlobalAlert() async {
        let model = AppModel(offline: false)
        await model.login(email: "not-an-email", password: "example", remember: true)
        XCTAssertEqual(model.authMessage, .localized(L10nKey.registerValidationEmailInvalid))
        XCTAssertNil(model.message)

        await model.sendCode(email: "not-an-email", reset: false)
        XCTAssertEqual(model.authMessage, .localized(L10nKey.registerValidationEmailInvalid))
        XCTAssertNil(model.message)

        await model.submitRegistration(email: "person@example.invalid", password: "example",
                                       confirmation: "example", code: "code", invite: "")
        XCTAssertEqual(model.authMessage, .localized(L10nKey.registerStatusRegistrationConfigUnavailable))
        XCTAssertNil(model.message)

        await model.resetPassword(email: "person@example.invalid", password: "example",
                                  confirmation: "example", code: "")
        XCTAssertEqual(model.authMessage, .localized(L10nKey.forgotValidationEmailCodeRequired))
        XCTAssertNil(model.message)
    }

    @MainActor
    func testPasswordResetMismatchStaysInlineAndDoesNotCallAPI() async {
        let fixture = AuthForgetFixture(outcome: .success)

        await fixture.model.resetPassword(
            email: "person@example.invalid",
            password: "new-password",
            confirmation: "different-password",
            code: "123456"
        )

        XCTAssertEqual(
            fixture.model.authMessage,
            .localized(L10nKey.forgotValidationPasswordMismatch)
        )
        XCTAssertNil(fixture.model.message)
        let writeCount = await fixture.writeCount
        XCTAssertEqual(writeCount, 0)
    }

    @MainActor
    func testPasswordResetDisplaysSafeBackendBusinessMessagesInline() async {
        for message in ["邮箱验证码有误", "该邮箱不存在系统中", "重置失败，请稍后再试"] {
            let fixture = AuthForgetFixture(outcome: .business(message))

            await fixture.model.resetPassword(
                email: "person@example.invalid",
                password: "new-password",
                confirmation: "new-password",
                code: "123456"
            )

            XCTAssertEqual(fixture.model.authMessage, .verbatim(message))
            XCTAssertNil(fixture.model.message)
            let writeCount = await fixture.writeCount
            XCTAssertEqual(writeCount, 1)
        }
    }

    @MainActor
    func testLoginDisplaysV2BoardBusinessMessagesInline() async {
        for message in [
            "邮箱或密码错误",
            "该账户已被停止使用",
            "密码错误次数过多，请 5 分钟后再试"
        ] {
            let fixture = AuthForgetFixture(outcome: .business(message))

            await fixture.model.login(
                email: "person@example.invalid",
                password: "example-password",
                remember: true
            )

            XCTAssertEqual(fixture.model.authMessage, .verbatim(message))
            XCTAssertNil(fixture.model.message)
            let writeCount = await fixture.loginWriteCount
            XCTAssertEqual(writeCount, 1)
        }
    }

    @MainActor
    func testRegistrationDisplaysV2BoardBusinessMessagesInline() async {
        for message in [
            "邮箱验证码有误",
            "邮箱已在系统中存在",
            "邀请码无效",
            "本站已关闭注册",
            "注册失败"
        ] {
            let fixture = AuthForgetFixture(outcome: .business(message))
            await fixture.model.loadRegistration()

            await fixture.model.submitRegistration(
                email: "person@example.invalid",
                password: "example-password",
                confirmation: "example-password",
                code: "123456",
                invite: ""
            )

            XCTAssertEqual(fixture.model.authMessage, .verbatim(message))
            XCTAssertNil(fixture.model.message)
            let writeCount = await fixture.writeCount
            XCTAssertEqual(writeCount, 1)
        }
    }

    @MainActor
    func testSendEmailVerificationBusinessMessageStaysInline() async {
        let message = "验证码已发送，请过一会儿再请求"
        let reset = AuthForgetFixture(outcome: .business(message))

        await reset.model.sendCode(email: "person@example.invalid", reset: true)

        XCTAssertEqual(reset.model.authMessage, .verbatim(message))
        XCTAssertNil(reset.model.message)
        let resetWrites = await reset.writeCount
        XCTAssertEqual(resetWrites, 1)

        let registration = AuthForgetFixture(outcome: .business(message))
        await registration.model.loadRegistration()
        await registration.model.sendCode(email: "person@example.invalid", reset: false)
        XCTAssertEqual(registration.model.authMessage, .verbatim(message))
        let registrationWrites = await registration.writeCount
        XCTAssertEqual(registrationWrites, 1)
    }

    @MainActor
    func testPasswordResetKeepsUncertainWriteAndNetworkCategoriesDistinct() async {
        for (outcome, expected) in [
            (AuthForgetFixtureOutcome.timedOut, LocalizedMessage.localized(L10nKey.errorWriteResultUnknown)),
            (.connectionLost, .localized(L10nKey.errorWriteResultUnknown)),
            (.dnsFailure, .localized(L10nKey.errorDNS)),
            (.tlsFailure, .localized(L10nKey.errorTLS)),
            (.offline, .localized(L10nKey.errorNetworkUnavailable))
        ] {
            let fixture = AuthForgetFixture(outcome: outcome)

            await fixture.model.resetPassword(
                email: "person@example.invalid",
                password: "new-password",
                confirmation: "new-password",
                code: "123456"
            )

            XCTAssertEqual(fixture.model.authMessage, expected)
            let writeCount = await fixture.writeCount
            XCTAssertEqual(writeCount, 1)
        }
    }

    @MainActor
    func testPasswordResetCancellationIsSilentAndSuccessIsUnchanged() async {
        let cancelled = AuthForgetFixture(outcome: .cancelled)
        await cancelled.model.resetPassword(
            email: "person@example.invalid",
            password: "new-password",
            confirmation: "new-password",
            code: "123456"
        )
        XCTAssertNil(cancelled.model.authMessage)
        XCTAssertNil(cancelled.model.message)

        let succeeded = AuthForgetFixture(outcome: .success)
        await succeeded.model.resetPassword(
            email: "person@example.invalid",
            password: "new-password",
            confirmation: "new-password",
            code: "123456"
        )
        XCTAssertEqual(
            succeeded.model.authMessage,
            .localized(L10nKey.forgotStatusResetSucceeded)
        )
        let writeCount = await succeeded.writeCount
        XCTAssertEqual(writeCount, 1)
    }

    @MainActor
    func testReadPagesKeepFailureDistinctFromEmptyWithoutGlobalAlert() async {
        let model = AppModel(offline: false)
        await model.loadCommerce()
        if case .failed = model.ordersLoadState {} else { XCTFail("Orders should be failed, not empty") }
        await model.loadInvitations()
        if case .failed = model.invitationsLoadState {} else { XCTFail("Invitations should be failed") }
        await model.loadPaymentMethods()
        if case .failed = model.paymentMethodsLoadState {} else { XCTFail("Payment methods should be failed") }
        XCTAssertNil(model.message)
    }

    func testSubscriptionFailureCategoriesRemainLocalizedAndDoNotExposeURL() {
        XCTAssertEqual(SubscriptionFetchError.downloadFailed.userFacingKey, "nodes.error.download_failed")
        XCTAssertEqual(SubscriptionFetchError.invalidHTTPResponse(statusCode: 403).userFacingKey,
                       "nodes.error.download_failed")
        XCTAssertEqual(SubscriptionParserError.noValidNodes.userFacingKey, "nodes.error.no_supported_nodes")
        XCTAssertEqual(SubscriptionParserError.invalidYAML.userFacingKey, "nodes.error.invalid_format")
    }
    func testWriteIsNeverReplayedAfterSubmissionFailure() async throws {
        let counter = AttemptCounter()
        let router = APIRecoveryRouter()
        do {
            let _: String = try await router.singleAttemptWrite(plan: APIRecoveryPlan(targets: ["one", "two"], builtInProxy: []), probe: { _ in }, submit: { _ in
                await counter.increment(); throw NetworkClientError.transport("result unknown")
            })
            XCTFail("Expected failed write")
        } catch {}
        let attempts = await counter.value
        XCTAssertEqual(attempts, 1)
    }
    func testReadFailoverOnlyForRetryableErrors() async throws {
        let counter = AttemptCounter()
        let result: String = try await APIRecoveryRouter().safeRetry(plan: APIRecoveryPlan(targets: ["one", "two"], builtInProxy: [])) { route in
            await counter.increment()
            if route.target == "one" { throw NetworkClientError.transport("offline") }
            return route.target
        }
        XCTAssertEqual(result, "two")
        let attempts = await counter.value; XCTAssertEqual(attempts, 2)
    }
    func testBusinessErrorStopsReadFailover() async {
        let counter = AttemptCounter()
        do {
            let _: String = try await APIRecoveryRouter().safeRetry(plan: APIRecoveryPlan(targets: ["one", "two"], builtInProxy: [])) { _ in
                await counter.increment(); throw NetworkClientError.backendBusinessError("拒绝")
            }
            XCTFail("Expected business error")
        } catch {}
        let attempts = await counter.value; XCTAssertEqual(attempts, 1)
    }
    func testCustomerServiceRejectsScriptNavigation() {
        XCTAssertEqual(CustomerServiceResolver.navigation(URL(string: "javascript:alert(1)"), service: .unavailable, userActivated: true), .reject)
        XCTAssertNil(CustomerServiceResolver.httpsURL("https://user:pass@example.invalid"))
    }
    func testCustomerServiceIdentityReusesOnlyExactServiceAndBrand() throws {
        let service = EffectiveCustomerService.url(
            try XCTUnwrap(URL(string: "https://support.example.invalid/chat/brand?token=one#entry")),
            .customerService
        )
        let first = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand A", accountScope: .guest
        ))
        let same = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand A", accountScope: .guest
        ))
        let otherBrand = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand B", accountScope: .guest
        ))

        XCTAssertEqual(first, same)
        XCTAssertEqual(first.dataStoreIdentifier, same.dataStoreIdentifier)
        XCTAssertNotEqual(first, otherBrand)
        XCTAssertNotEqual(first.dataStoreIdentifier, otherBrand.dataStoreIdentifier)
    }
    func testCustomerServiceIdentitySeparatesURLModeHTMLAndContentChanges() throws {
        let url = try XCTUnwrap(URL(string: "https://support.example.invalid/chat/brand"))
        let urlIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(url, .customerService), brandScope: "Brand", accountScope: .guest
        ))
        let changedURLIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(url.appendingPathComponent("next"), .customerService),
            brandScope: "Brand", accountScope: .guest
        ))
        let legacyURLIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(url, .legacy), brandScope: "Brand", accountScope: .guest
        ))
        let htmlIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .html("<p>Support</p>"), brandScope: "Brand", accountScope: .guest
        ))
        let changedHTMLIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .html("<p>Changed support</p>"), brandScope: "Brand", accountScope: .guest
        ))

        XCTAssertNotEqual(urlIdentity, changedURLIdentity)
        XCTAssertNotEqual(urlIdentity, legacyURLIdentity)
        XCTAssertNotEqual(urlIdentity, htmlIdentity)
        XCTAssertNotEqual(htmlIdentity, changedHTMLIdentity)
    }
    func testCustomerServiceIdentityTreatsQueryAndTokenChangesAsDifferent() throws {
        let first = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(
                try XCTUnwrap(URL(string: "https://support.example.invalid/chat?token=first&route=one")),
                .customerService
            ),
            brandScope: "Brand",
            accountScope: .guest
        ))
        let second = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(
                try XCTUnwrap(URL(string: "https://support.example.invalid/chat?token=second&route=one")),
                .customerService
            ),
            brandScope: "Brand",
            accountScope: .guest
        ))

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.safeSummary.contains("first"))
        XCTAssertFalse(first.safeSummary.contains("token"))
        XCTAssertTrue(first.safeSummary.range(of: #"^url-[0-9a-f]{12}$"#, options: .regularExpression) != nil)
    }
    func testCustomerServiceIdentityScopesGuestAndAuthenticatedAccounts() throws {
        let service = EffectiveCustomerService.url(
            try XCTUnwrap(URL(string: "https://support.example.invalid/chat/brand")),
            .customerService
        )
        let accountA = customerServiceSession(email: " Account-A@Example.Invalid ")
        let normalizedAccountA = customerServiceSession(email: "account-a@example.invalid")
        let accountB = customerServiceSession(email: "account-b@example.invalid")
        let scopeA = CustomerServiceResolver.accountScope(for: accountA)
        let normalizedScopeA = CustomerServiceResolver.accountScope(for: normalizedAccountA)
        let scopeB = CustomerServiceResolver.accountScope(for: accountB)
        let guestScope = CustomerServiceResolver.accountScope(for: nil)

        XCTAssertEqual(scopeA, normalizedScopeA)
        XCTAssertNotEqual(scopeA, scopeB)
        XCTAssertNotEqual(scopeA, guestScope)

        let identityA = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: scopeA
        ))
        let repeatedIdentityA = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: normalizedScopeA
        ))
        let identityB = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: scopeB
        ))
        let guestIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: guestScope
        ))

        XCTAssertEqual(identityA, repeatedIdentityA)
        XCTAssertEqual(identityA.dataStoreIdentifier, repeatedIdentityA.dataStoreIdentifier)
        XCTAssertNotEqual(identityA, identityB)
        XCTAssertNotEqual(identityA.dataStoreIdentifier, identityB.dataStoreIdentifier)
        XCTAssertNotEqual(identityA, guestIdentity)
        XCTAssertNotEqual(identityA.dataStoreIdentifier, guestIdentity.dataStoreIdentifier)
        XCTAssertFalse(identityA.safeSummary.contains("account-a"))
        XCTAssertFalse(identityA.safeSummary.contains("example.invalid"))
        XCTAssertFalse(identityA.safeSummary.contains(
            PendingPaymentStore.accountIdentifier(for: accountA)
        ))
    }
    @MainActor
    func testCustomerServicePoolReusesWithoutReloadAndRetryCreatesFreshView() throws {
        let identity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(
                try XCTUnwrap(URL(string: "https://support.example.invalid/chat")),
                .customerService
            ),
            brandScope: "Brand",
            accountScope: .guest
        ))
        let pool = CustomerServiceWebViewPool(observesMemoryWarnings: false)
        let first = pool.acquire(identity: identity) { WKWebView() }
        let second = pool.acquire(identity: identity) { WKWebView() }

        XCTAssertFalse(first.reused)
        XCTAssertTrue(first.shouldLoad)
        XCTAssertTrue(second.reused)
        XCTAssertFalse(second.shouldLoad)
        XCTAssertTrue(first.webView === second.webView)

        pool.invalidate(identity: identity)
        let retried = pool.acquire(identity: identity) { WKWebView() }
        XCTAssertFalse(retried.reused)
        XCTAssertTrue(retried.shouldLoad)
        XCTAssertFalse(retried.webView === first.webView)

        pool.removeAll()
        let recreatedAfterMemoryRelease = pool.acquire(identity: identity) { WKWebView() }
        XCTAssertFalse(recreatedAfterMemoryRelease.reused)
        XCTAssertTrue(recreatedAfterMemoryRelease.shouldLoad)
        XCTAssertFalse(recreatedAfterMemoryRelease.webView === retried.webView)
    }
    @MainActor
    func testCustomerServicePoolDropsOldWebViewWhenRemoteConfigChanges() throws {
        let firstIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(
                try XCTUnwrap(URL(string: "https://support.example.invalid/chat/first")),
                .customerService
            ),
            brandScope: "Brand",
            accountScope: .guest
        ))
        let changedIdentity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .url(
                try XCTUnwrap(URL(string: "https://support.example.invalid/chat/second")),
                .customerService
            ),
            brandScope: "Brand",
            accountScope: .guest
        ))
        let pool = CustomerServiceWebViewPool(observesMemoryWarnings: false)
        let first = pool.acquire(identity: firstIdentity) { WKWebView() }
        let changed = pool.acquire(identity: changedIdentity) { WKWebView() }

        XCTAssertFalse(changed.reused)
        XCTAssertTrue(changed.shouldLoad)
        XCTAssertFalse(changed.webView === first.webView)
    }
    @MainActor
    func testCustomerServiceUsesIdentityScopedPersistentWebsiteDataStore() throws {
        let identity = try XCTUnwrap(CustomerServiceResolver.identity(
            for: .html("<p>Support</p>"), brandScope: "Brand", accountScope: .guest
        ))
        let configuration = CustomerServiceWebViewPool.configuration(for: identity)

        XCTAssertTrue(configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(configuration.websiteDataStore.identifier as UUID?, identity.dataStoreIdentifier)
    }
    @MainActor
    func testCustomerServicePoolNeverReusesAcrossAccountsAndKeepsStableStores() throws {
        let service = EffectiveCustomerService.url(
            try XCTUnwrap(URL(string: "https://support.example.invalid/chat/brand")),
            .customerService
        )
        let scopeA = CustomerServiceResolver.accountScope(
            for: customerServiceSession(email: "a@example.invalid")
        )
        let scopeB = CustomerServiceResolver.accountScope(
            for: customerServiceSession(email: "b@example.invalid")
        )
        let identityA = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: scopeA
        ))
        let identityB = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: scopeB
        ))
        let repeatedIdentityA = try XCTUnwrap(CustomerServiceResolver.identity(
            for: service, brandScope: "Brand", accountScope: scopeA
        ))
        let pool = CustomerServiceWebViewPool(observesMemoryWarnings: false)

        let firstA = pool.acquire(identity: identityA) { WKWebView() }
        let firstB = pool.acquire(identity: identityB) { WKWebView() }

        XCTAssertFalse(firstA.reused)
        XCTAssertFalse(firstB.reused)
        XCTAssertFalse(firstB.webView === firstA.webView)

        // A late delegate callback must not evict B's current cache entry.
        pool.invalidate(identity: identityA, matching: firstA.webView)
        let repeatedB = pool.acquire(identity: identityB) { WKWebView() }
        XCTAssertTrue(repeatedB.reused)
        XCTAssertTrue(repeatedB.webView === firstB.webView)

        let returnedA = pool.acquire(identity: repeatedIdentityA) { WKWebView() }
        XCTAssertFalse(returnedA.reused)
        XCTAssertFalse(returnedA.webView === firstB.webView)
        XCTAssertEqual(identityA.dataStoreIdentifier, repeatedIdentityA.dataStoreIdentifier)
        XCTAssertNotEqual(identityA.dataStoreIdentifier, identityB.dataStoreIdentifier)
    }
    @MainActor
    func testCustomerServicePersistentStoreRetentionIsBoundedAndProtectsCurrentStore() {
        let identifiers = (0..<10).map { _ in UUID() }
        let current = identifiers[2]
        let updated = CustomerServicePersistentStoreRetention.updatedHistory(
            identifiers,
            using: current
        )
        let expired = CustomerServicePersistentStoreRetention.expirationCandidates(
            in: updated
        )

        XCTAssertEqual(updated.last, current)
        XCTAssertEqual(updated.count, 10)
        XCTAssertEqual(expired.count, 2)
        XCTAssertFalse(expired.contains(current))
        XCTAssertEqual(
            Array(updated.dropFirst(expired.count)).count,
            CustomerServicePersistentStoreRetention.maximumStoreCount
        )
    }
    func testTrafficAndOverflowAreSafe() {
        XCTAssertEqual(TrafficFormatter.gigabytes(-1).value, "0.00")
        XCTAssertEqual(TrafficFormatter.gigabytes(1_073_741_824).value, "1.00")
    }
    func testLogsRedactCredentialsAndURLs() {
        let value = UserLogSanitizer.sanitize("password=verysecret https://example.invalid/sub?token=fake")
        XCTAssertFalse(value.contains("verysecret")); XCTAssertFalse(value.contains("token=fake"))
    }

    private func customerServiceSession(email: String) -> UserSession {
        UserSession(
            email: email,
            authData: "fixture-auth-data",
            accountToken: nil,
            subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 0,
            downloadBytes: 0,
            transferEnableBytes: 0,
            expiredAt: 0,
            planID: nil,
            planName: "",
            balanceCents: nil,
            verifiedAt: Date()
        )
    }
}

@MainActor
final class ChangePasswordTests: XCTestCase {
    func testChangePasswordUIReusesAuthFieldMetricsAndPrimaryButtonStyle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Views/ProfileView.swift"))
        let start = try XCTUnwrap(source.range(of: "struct ChangePasswordView: View")?.lowerBound)
        let end = try XCTUnwrap(
            source.range(of: "enum InvitationsAppearance", range: start..<source.endIndex)?.lowerBound
        )
        let view = String(source[start..<end])

        XCTAssertTrue(view.contains("Image(ProfileMenuItem.changePassword.icon)"))
        XCTAssertTrue(view.contains("ProfileMenuItem.changePassword.tint"))
        XCTAssertTrue(view.contains("Image(systemName: \"lock\")"))
        XCTAssertTrue(view.contains("ChangePasswordAppearance.fieldHeight"))
        XCTAssertTrue(view.contains("ChangePasswordAppearance.fieldCornerRadius"))
        XCTAssertTrue(view.contains("ChangePasswordAppearance.visibilityButtonSize"))
        XCTAssertTrue(view.contains(".buttonStyle(BrandButtonStyle())"))
        XCTAssertTrue(view.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertTrue(view.contains(".scrollDismissesKeyboard(.interactively)"))
        XCTAssertFalse(view.contains("Form {"))
        XCTAssertFalse(view.contains("Section {"))

        XCTAssertEqual(ChangePasswordAppearance.titleIconSize, 19)
        XCTAssertEqual(ChangePasswordAppearance.contentMaxWidth, LoginAppearance.contentMaxWidth)
        XCTAssertEqual(ChangePasswordAppearance.contentHorizontalPadding, 20)
        XCTAssertEqual(ChangePasswordAppearance.fieldHeight, LoginAppearance.fieldHeight)
        XCTAssertEqual(ChangePasswordAppearance.fieldCornerRadius, LoginAppearance.fieldCornerRadius)
        XCTAssertEqual(ChangePasswordAppearance.fieldIconSize, LoginAppearance.fieldIconSize)
        XCTAssertEqual(
            ChangePasswordAppearance.visibilityButtonSize,
            LoginAppearance.passwordVisibilityButtonSize
        )
    }

    func testSuccessPublishesSucceededAndSubmitsExactlyOnce() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let config = try XCTUnwrap(fixture.model.config)
        XCTAssertEqual(AppConfig.orderedAPIBaseURLs(from: config), ["https://api.cloudflare.com"])

        let changed = await fixture.model.changePassword(
            currentPassword: "old-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(fixture.model.changePasswordState, .succeeded)
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 1, "state=\(fixture.model.changePasswordState)")
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.auth])
        XCTAssertEqual(entries.map(\.level), [.success])
    }

    func testValidationMismatchDoesNotSendRequest() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let changed = await fixture.model.changePassword(
            currentPassword: "old-password",
            newPassword: "new-password",
            confirmation: "different-password"
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(
            fixture.model.changePasswordState,
            .failed(.localized("profile.change_password.validation.mismatch"))
        )
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 0)
    }

    func testAPIFailurePublishesInlineFailureAndDoesNotReplay() async throws {
        let fixture = try ChangePasswordFixture(result: .failure)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let changed = await fixture.model.changePassword(
            currentPassword: "wrong-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )

        XCTAssertFalse(changed)
        if case .failed = fixture.model.changePasswordState {} else {
            XCTFail("Expected inline change-password failure")
        }
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 1, "state=\(fixture.model.changePasswordState)")
        XCTAssertNil(fixture.model.message)
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.auth])
        XCTAssertEqual(entries.map(\.level), [.warning])
    }

    func testMessageOnly500OldPasswordRejectionStaysInlineAndIsNotReplayed() async throws {
        let fixture = try ChangePasswordFixture(result: .oldPasswordRejected)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let changed = await fixture.model.changePassword(
            currentPassword: "wrong-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(
            fixture.model.changePasswordState,
            .failed(.verbatim("旧密码有误"))
        )
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 1)
        XCTAssertNil(fixture.model.message)
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.auth])
        XCTAssertEqual(entries.map(\.level), [.warning])
    }

    func testMessageOnly500SaveFailureStaysInlineAndIsNotReplayed() async throws {
        let fixture = try ChangePasswordFixture(result: .saveFailed)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let changed = await fixture.model.changePassword(
            currentPassword: "old-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(
            fixture.model.changePasswordState,
            .failed(.verbatim("保存失败"))
        )
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 1)
        XCTAssertNil(fixture.model.message)
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.auth])
        XCTAssertEqual(entries.map(\.level), [.warning])
    }

    func testUnsafeChangePassword500RemainsUnknownAndIsNotReplayed() async throws {
        let fixture = try ChangePasswordFixture(result: .unsafeFailure)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let changed = await fixture.model.changePassword(
            currentPassword: "old-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(
            fixture.model.changePasswordState,
            .failed(.localized(L10nKey.errorWriteResultUnknown))
        )
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 1)
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.auth])
        XCTAssertEqual(entries.map(\.level), [.error])
    }

    func testChangePassword401KeepsAuthenticationExpiredSemantics() async throws {
        let fixture = try ChangePasswordFixture(result: .authenticationExpired)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let changed = await fixture.model.changePassword(
            currentPassword: "old-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(
            fixture.model.changePasswordState,
            .failed(.localized(L10nKey.errorAuthenticationExpired))
        )
        let postCount = await fixture.state.postCount()
        XCTAssertEqual(postCount, 1)
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.auth])
        XCTAssertEqual(entries.map(\.level), [.error])
    }

    func testPasswordChangeSuccessInvalidatesLocalSessionAndRotatesGeneration() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let originalGeneration = fixture.model.commerceRecoveryGeneration

        let outcome = await fixture.model.invalidateSessionAfterPasswordChange()

        XCTAssertEqual(outcome, .invalidated(storageCleared: true))
        XCTAssertNil(fixture.model.session)
        XCTAssertEqual(CustomerServiceResolver.accountScope(for: fixture.model.session), .guest)
        XCTAssertNotEqual(fixture.model.commerceRecoveryGeneration, originalGeneration)
        XCTAssertEqual(fixture.model.changePasswordState, .idle)
        XCTAssertTrue(fixture.model.plans.isEmpty)
        XCTAssertTrue(fixture.model.orders.isEmpty)
        XCTAssertTrue(fixture.model.nodes.nodes.isEmpty)
        XCTAssertTrue(fixture.model.notices.isEmpty)
    }

    func testPasswordChangeInvalidationWithoutSessionIsStale() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }

        let outcome = await fixture.model.invalidateSessionAfterPasswordChange()

        XCTAssertEqual(outcome, .stale)
        XCTAssertNil(fixture.model.session)
    }

    func testPasswordChangeStorageFailureStillReturnsToUnauthenticatedRootState() async throws {
        let keychain = SignOutFailingSessionKeychain()
        let fixture = try ChangePasswordFixture(keychain: keychain)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        keychain.beginFailingDeletes()

        let outcome = await fixture.model.invalidateSessionAfterPasswordChange()

        XCTAssertEqual(outcome, .invalidated(storageCleared: false))
        XCTAssertNil(fixture.model.session)
        XCTAssertEqual(fixture.model.changePasswordState, .idle)
    }

    func testPasswordChangeVPNDisconnectFailureRemainsVisibleAfterAuthenticationInvalidation() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let outcome = await fixture.model.invalidateSessionAfterPasswordChange()
        fixture.model.reportPasswordChangeVPNDisconnectFailure()

        XCTAssertEqual(outcome, .invalidated(storageCleared: true))
        XCTAssertNil(fixture.model.session)
        XCTAssertEqual(
            fixture.model.message,
            .localized("profile.change_password.vpn_disconnect_failed")
        )
        let entries = await fixture.userLogs(atLeast: 1)
        XCTAssertEqual(entries.map(\.module), [.proxy])
        XCTAssertEqual(entries.map(\.level), [.error])
    }

    func testLateSuccessFromAccountADoesNotPolluteAccountB() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let gate = PasswordResponseGate()
        await fixture.state.holdNextWrite(gate)
        let request = Task {
            await fixture.model.changePassword(
                currentPassword: "old-password",
                newPassword: "new-password",
                confirmation: "new-password"
            )
        }
        await fulfillment(of: [gate.entered])

        await fixture.establish(account: "B")
        await gate.resume()

        let result = await request.value
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.model.changePasswordState, .idle)
        XCTAssertEqual(fixture.model.session?.email, "B@example.invalid")
        XCTAssertNil(fixture.model.message)
    }

    func testLateSuccessFromOldGenerationDoesNotPolluteSameAccountRelogin() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let gate = PasswordResponseGate()
        await fixture.state.holdNextWrite(gate)
        let request = Task {
            await fixture.model.changePassword(
                currentPassword: "old-password",
                newPassword: "new-password",
                confirmation: "new-password"
            )
        }
        await fulfillment(of: [gate.entered])

        await fixture.establish(account: "A")
        await gate.resume()

        let result = await request.value
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.model.changePasswordState, .idle)
        XCTAssertNil(fixture.model.message)
    }

    func testSubmittingStateRejectsDuplicateTap() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let gate = PasswordResponseGate()
        await fixture.state.holdNextWrite(gate)
        let first = Task {
            await fixture.model.changePassword(
                currentPassword: "old-password",
                newPassword: "new-password",
                confirmation: "new-password"
            )
        }
        await fulfillment(of: [gate.entered])

        let duplicate = await fixture.model.changePassword(
            currentPassword: "old-password",
            newPassword: "new-password",
            confirmation: "new-password"
        )
        await gate.resume()

        XCTAssertFalse(duplicate)
        let firstResult = await first.value
        let postCount = await fixture.state.postCount()
        XCTAssertTrue(firstResult)
        XCTAssertEqual(postCount, 1)
    }

    func testCancellationRestoresCurrentAccountFormToIdle() async throws {
        let fixture = try ChangePasswordFixture()
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let gate = PasswordResponseGate()
        await fixture.state.holdNextWrite(gate)
        let request = Task {
            await fixture.model.changePassword(
                currentPassword: "old-password",
                newPassword: "new-password",
                confirmation: "new-password"
            )
        }
        await fulfillment(of: [gate.entered])

        request.cancel()
        await gate.resume()

        let result = await request.value
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.model.changePasswordState, .idle)
        try? await Task.sleep(for: .milliseconds(50))
        let entries = await fixture.userLogs(atLeast: 0)
        XCTAssertTrue(entries.isEmpty)
    }
}

@MainActor
final class AccountDeletionRequestTests: XCTestCase {
    func testAuthenticatedPostUsesEmptyJSONObjectAndKeepsSessionOnSuccess() async throws {
        let fixture = try AccountDeletionFixture(result: .success)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let originalSession = try XCTUnwrap(fixture.model.session)
        let originalGeneration = fixture.model.commerceRecoveryGeneration

        let submitted = await fixture.model.requestAccountDeletion()

        XCTAssertTrue(submitted)
        XCTAssertEqual(fixture.model.accountDeletionRequestState, .idle)
        XCTAssertEqual(fixture.model.session, originalSession)
        XCTAssertEqual(fixture.model.commerceRecoveryGeneration, originalGeneration)
        let requests = await fixture.state.requestSnapshots()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/api/v1/user/account/delete-request")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.authorization, originalSession.authData)
        XCTAssertNotEqual(request.contentLength, "0")
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(body, Data("{}".utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertTrue(object.isEmpty)
        XCTAssertEqual(request.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(V2BoardAPIClient.accountDeleteRequestPath, "/user/account/delete-request")
    }

    func testDataFalseIsDefiniteFailureAndDoesNotClearSession() async throws {
        let fixture = try AccountDeletionFixture(result: .rejected)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let originalSession = fixture.model.session
        let originalGeneration = fixture.model.commerceRecoveryGeneration

        let submitted = await fixture.model.requestAccountDeletion()

        XCTAssertFalse(submitted)
        XCTAssertEqual(
            fixture.model.accountDeletionRequestState,
            .failed(.localized(L10nKey.errorBusinessRejected))
        )
        XCTAssertEqual(fixture.model.session, originalSession)
        XCTAssertEqual(fixture.model.commerceRecoveryGeneration, originalGeneration)
        let requestCount = await fixture.state.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testTransportFailureIsUnknownAndNeverReplayed() async throws {
        let fixture = try AccountDeletionFixture(result: .transportFailure)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")

        let submitted = await fixture.model.requestAccountDeletion()

        XCTAssertFalse(submitted)
        XCTAssertEqual(
            fixture.model.accountDeletionRequestState,
            .failed(.localized(L10nKey.errorWriteResultUnknown))
        )
        let requestCount = await fixture.state.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNotNil(fixture.model.session)
    }

    func testSubmittingStateRejectsConcurrentRequest() async throws {
        let fixture = try AccountDeletionFixture(result: .success)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let gate = AccountDeletionResponseGate()
        await fixture.state.holdNextWrite(gate)
        let first = Task { await fixture.model.requestAccountDeletion() }
        await fulfillment(of: [gate.entered])

        let duplicate = await fixture.model.requestAccountDeletion()
        await gate.resume()

        XCTAssertFalse(duplicate)
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        let requestCount = await fixture.state.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testLateSuccessCannotMutateNewAccountState() async throws {
        let fixture = try AccountDeletionFixture(result: .success)
        defer { fixture.cleanUp() }
        await fixture.establish(account: "A")
        let gate = AccountDeletionResponseGate()
        await fixture.state.holdNextWrite(gate)
        let request = Task { await fixture.model.requestAccountDeletion() }
        await fulfillment(of: [gate.entered])

        await fixture.establish(account: "B")
        await gate.resume()

        let requestResult = await request.value
        XCTAssertFalse(requestResult)
        XCTAssertEqual(fixture.model.accountDeletionRequestState, .idle)
        XCTAssertEqual(fixture.model.session?.email, "B@example.invalid")
    }
}

final class LocalFilesystemNamespaceTests: XCTestCase {
    func testDefaultCacheAndLogNamespacesUseGenericNetworkClientDirectory() {
        let applicationSupport = URL(
            fileURLWithPath: "/synthetic/Library/Application Support",
            isDirectory: true
        )
        let cache = RemoteConfigService.defaultCacheDirectoryURL(
            applicationSupportDirectory: applicationSupport
        )
        XCTAssertEqual(Array(cache.pathComponents.suffix(2)), ["NetworkClient", "Config"])
        XCTAssertFalse(cache.pathComponents.contains("LegacyNetworkClient"))

        let library = URL(fileURLWithPath: "/synthetic/Library", isDirectory: true)
        let logs = UserSystemLogger.defaultDirectoryURL(libraryDirectory: library)
        XCTAssertEqual(Array(logs.pathComponents.suffix(2)), ["Logs", "NetworkClient"])
        XCTAssertFalse(logs.pathComponents.contains("LegacyNetworkClient"))
    }
}

final class UserDiagnosticLogTests: XCTestCase {
    func testAppendSnapshotAndClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        await logger.logAndWaitForTesting(.info, module: .app, message: "Client ready")
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let beforeClear = await logger.currentEntries().map(\.message)
        XCTAssertEqual(beforeClear, ["Client ready"])
        try await logger.clear()
        let afterClear = await logger.currentEntries()
        XCTAssertTrue(afterClear.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testClearFailurePreservesVisibleAndPersistedEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(
            directoryURL: root,
            fileRemover: { _ in throw SyntheticUserLogFileError.blocked }
        )
        await logger.logAndWaitForTesting(.info, module: .app, message: "still present")
        let stream = await logger.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initialSnapshot = await iterator.next()
        XCTAssertEqual(initialSnapshot?.map(\.message), ["still present"])

        do {
            try await logger.clear()
            XCTFail("A deletion failure must be reported")
        } catch let error as UserSystemLogger.ClearError {
            XCTAssertEqual(error, .deletionFailed)
        }

        let failureSnapshot = await iterator.next()
        let currentEntries = await logger.currentEntries()
        XCTAssertEqual(failureSnapshot?.map(\.message), ["still present"])
        XCTAssertEqual(currentEntries.map(\.message), ["still present"])
        let reloaded = UserSystemLogger(directoryURL: root)
        let persistedEntries = await reloaded.currentEntries()
        XCTAssertEqual(persistedEntries.map(\.message), ["still present"])
    }

    func testPartialClearFailureReloadsExactlyWhatRemainsOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dates = try [10, 11, 12].map { day in
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 11, day: day, hour: 12
            )))
        }
        let logger = UserSystemLogger(
            directoryURL: root,
            nowProvider: { dates[2] },
            fileRemover: { url in
                if url.lastPathComponent.contains("2026-11-11") {
                    throw SyntheticUserLogFileError.blocked
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        for (index, date) in dates.enumerated() {
            await logger.logAndWaitForTesting(
                .info,
                module: .app,
                message: "day-\(index)",
                timestamp: date
            )
        }

        do {
            try await logger.clear()
            XCTFail("A partial deletion failure must be reported")
        } catch let error as UserSystemLogger.ClearError {
            XCTAssertEqual(error, .deletionFailed)
        }

        let currentEntries = await logger.currentEntries()
        XCTAssertEqual(currentEntries.map(\.message), ["day-1"])
        let reloaded = UserSystemLogger(directoryURL: root, nowProvider: { dates[2] })
        let persistedEntries = await reloaded.currentEntries()
        XCTAssertEqual(persistedEntries.map(\.message), ["day-1"])
    }

    func testSanitizerCoversTokensQuotedValuesIPv6AndProxyURIs() {
        let sensitiveValues = [
            "access_token=abc123",
            "refresh_token=abc123",
            #"{"access_token":"abc123"}"#,
            #"{"refresh_token":"abc123"}"#,
            #"password="abc def ghi" suffix"#,
            "token='abc def ghi' suffix",
            "Authorization: Bearer abc123",
            #"Authorization="Bearer abc def" suffix"#,
            #"Cookie="session abc123""#
        ]
        for value in sensitiveValues {
            let sanitized = UserLogSanitizer.sanitize(value)
            XCTAssertFalse(sanitized.contains("abc123"), "value=\(value)")
            XCTAssertFalse(sanitized.contains("abc def ghi"), "value=\(value)")
        }
        XCTAssertTrue(
            UserLogSanitizer.sanitize(#"password="abc def ghi" suffix"#)
                .hasSuffix("suffix")
        )

        for address in [
            "2001:db8::1", "fe80::1", "::1",
            "2408:8000:1000:2000:3000:4000:5000:6000",
            "[2001:db8::1]:443"
        ] {
            let sanitized = UserLogSanitizer.sanitize("peer=\(address)")
            XCTAssertFalse(sanitized.contains(address), "address=\(address)")
            XCTAssertTrue(sanitized.contains("[ip]"), "address=\(address)")
        }

        for scheme in [
            "http", "https", "vless", "trojan", "hysteria2", "hy2", "tuic",
            "vmess", "ss", "ssr", "socks", "socks4", "socks4a", "socks5", "crisp"
        ] {
            let uri = "\(scheme)://user:secret@[2001:db8::1]:443/path?token=abc#fragment"
            let sanitized = UserLogSanitizer.sanitize("node=\(uri)")
            XCTAssertFalse(sanitized.contains("secret"), "scheme=\(scheme)")
            XCTAssertFalse(sanitized.contains("2001:db8::1"), "scheme=\(scheme)")
            XCTAssertFalse(sanitized.contains("token=abc"), "scheme=\(scheme)")
            XCTAssertTrue(sanitized.contains("[url]"), "scheme=\(scheme)")
        }

        XCTAssertEqual(
            UserLogSanitizer.sanitize("time=21:24:56 version=0.2.1 普通中文文案 12345"),
            "time=21:24:56 version=0.2.1 普通中文文案 12345"
        )
        let email = UserLogSanitizer.sanitize("user@example.com")
        XCTAssertNotEqual(email, "user@example.com")
        XCTAssertTrue(email.hasSuffix("@example.com"))
    }

    func testNewSanitizerRulesApplyBeforeStorageAndAgainDuringExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        await logger.logAndWaitForTesting(
            .warning,
            module: .auth,
            message: #"access_token="secret value" vless://uuid@host.invalid:443?token=abc 2001:db8::1"#
        )

        let entries = await logger.currentEntries()
        let stored = try XCTUnwrap(entries.first?.message)
        let exported = await logger.exportText()
        for value in ["secret value", "vless://", "host.invalid", "token=abc", "2001:db8::1"] {
            XCTAssertFalse(stored.contains(value))
            XCTAssertFalse(exported.contains(value))
        }
    }

    func testDuplicateSuppressionStillUsesLevelModuleAndSanitizedMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        let base = Date()

        await logger.logAndWaitForTesting(.info, module: .app, message: "same", timestamp: base)
        await logger.logAndWaitForTesting(.info, module: .app, message: "same", timestamp: base.addingTimeInterval(1))
        await logger.logAndWaitForTesting(.warning, module: .app, message: "same", timestamp: base.addingTimeInterval(2))
        await logger.logAndWaitForTesting(.warning, module: .auth, message: "same", timestamp: base.addingTimeInterval(3))
        await logger.logAndWaitForTesting(.warning, module: .auth, message: "different", timestamp: base.addingTimeInterval(4))
        await logger.logAndWaitForTesting(.info, module: .app, message: "token=alpha request", timestamp: base.addingTimeInterval(5))
        await logger.logAndWaitForTesting(.info, module: .app, message: "token=beta request", timestamp: base.addingTimeInterval(6))
        await logger.logAndWaitForTesting(.info, module: .app, message: "token=gamma request", timestamp: base.addingTimeInterval(16))

        let entries = await logger.currentEntries()
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries.filter { $0.message == "same" }.count, 3)
        XCTAssertEqual(entries.filter { $0.message == "secret [REDACTED] request" }.count, 2)
    }

    func testExportSanitizesSecretsAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        await logger.logAndWaitForTesting(
            .error,
            module: .auth,
            message: "password=verysecret user@example.invalid https://private.example.invalid/path?token=fake"
        )
        let export = await logger.exportText()
        XCTAssertFalse(export.contains("verysecret"))
        XCTAssertFalse(export.contains("user@example.invalid"))
        XCTAssertFalse(export.contains("private.example.invalid"))
        XCTAssertFalse(export.contains("token=fake"))
    }

    func testRetentionRemovesExpiredEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let writer = UserSystemLogger(directoryURL: root, nowProvider: { now })
        await writer.logAndWaitForTesting(
            .info,
            module: .app,
            message: "expired",
            timestamp: now.addingTimeInterval(-UserSystemLogger.retentionInterval - 1)
        )
        let logger = UserSystemLogger(directoryURL: root, nowProvider: { now })
        await logger.logAndWaitForTesting(.info, module: .app, message: "current", timestamp: now)
        let messages = await logger.currentEntries().map(\.message)
        XCTAssertEqual(messages, ["current"])
    }

    func testVisibleEntriesAndDiskPolicyAreBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        for index in 0..<(UserSystemLogger.maxVisibleEntries + 5) {
            await logger.logAndWaitForTesting(
                .info,
                module: .app,
                message: "Event \(index)"
            )
        }
        let count = await logger.currentEntries().count
        XCTAssertEqual(count, UserSystemLogger.maxVisibleEntries)
        XCTAssertEqual(UserSystemLogger.maxFileBytes, 5 * 1_024 * 1_024)
        XCTAssertEqual(UserSystemLogger.maxTotalBytes, 50 * 1_024 * 1_024)
    }

    func testDebugAndTraceCannotEnterUserDiagnosticLog() {
        XCTAssertNil(UserLogLevel(rawValue: "debug"))
        XCTAssertNil(UserLogLevel(rawValue: "trace"))
    }
}

private enum SyntheticUserLogFileError: Error {
    case blocked
}

final class DiagnosticsLogPresentationTests: XCTestCase {
    func testSectionsUseLocalCalendarAndKeepNewestDatesAndEntriesFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let newerDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 13, hour: 0, minute: 15
        )))
        let previousEvening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 12, hour: 23, minute: 50
        )))
        let previousMorning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 12, hour: 8, minute: 30
        )))
        let entries = [
            UserLogEntry(timestamp: previousMorning, level: .info, module: .app, message: "a"),
            UserLogEntry(timestamp: newerDay, level: .error, module: .auth, message: "b"),
            UserLogEntry(timestamp: previousEvening, level: .warning, module: .recovery, message: "c")
        ]

        let sections = DiagnosticsLogPresentation.sections(
            from: entries,
            calendar: calendar
        )

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: sections[0].day),
            DateComponents(year: 2026, month: 11, day: 13)
        )
        XCTAssertEqual(sections[0].entries.map(\.message), ["b"])
        XCTAssertEqual(sections[1].entries.map(\.message), ["c", "a"])
    }

    func testSectionGroupingUsesRequestedTimezoneAtMidnightBoundary() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let beforeLocalMidnight = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 11, day: 12, hour: 15, minute: 30
        )))
        let afterLocalMidnight = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 11, day: 12, hour: 16, minute: 30
        )))
        let entries = [
            UserLogEntry(timestamp: beforeLocalMidnight, level: .info, module: .app, message: "before"),
            UserLogEntry(timestamp: afterLocalMidnight, level: .info, module: .app, message: "after")
        ]

        let sections = DiagnosticsLogPresentation.sections(from: entries, calendar: shanghai)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.flatMap(\.entries).map(\.message), ["after", "before"])
    }

    func testDiagnosticsTitleMetricsAndExistingLevelsRemainStable() {
        XCTAssertEqual(DiagnosticsLogPresentation.titleIconSize, 15.75)
        XCTAssertEqual(DiagnosticsLogPresentation.titleSpacing, 7)
        XCTAssertEqual(DiagnosticsLogPresentation.rowContentSpacing, 3.2)
        XCTAssertEqual(DiagnosticsLogPresentation.rowVerticalPadding, 1.6)
        XCTAssertEqual(DiagnosticsLogPresentation.rowVerticalInset, 8.8)
        XCTAssertEqual(DiagnosticsLogPresentation.rowHorizontalInset, 20)
        XCTAssertEqual(DiagnosticsLogPresentation.levelHorizontalPadding, 6)
        XCTAssertEqual(DiagnosticsLogPresentation.levelVerticalPadding, 1.6)
        XCTAssertEqual(
            [UserLogLevel.info, .success, .warning, .error].map(\.rawValue),
            ["info", "success", "warning", "error"]
        )
    }

    #if DEBUG
    func testLongListFixtureRequiresAllExplicitUITestArguments() {
        XCTAssertTrue(DiagnosticsLogPresentation.usesLongListFixture(arguments: [
            "--offline", "--ui-sample", "--ui-diagnostics-long-list"
        ]))
        XCTAssertFalse(DiagnosticsLogPresentation.usesLongListFixture(arguments: [
            "--offline", "--ui-sample"
        ]))
        XCTAssertFalse(DiagnosticsLogPresentation.usesLongListFixture(arguments: [
            "--ui-diagnostics-long-list"
        ]))
    }

    func testLongListFixtureIsStableBoundedAndCoversDatesAndLevels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let entries = DiagnosticsLogPresentation.longListFixture(calendar: calendar)
        let sections = DiagnosticsLogPresentation.sections(from: entries, calendar: calendar)

        XCTAssertEqual(entries.count, 40)
        XCTAssertEqual(Set(entries.map(\.id)).count, 40)
        XCTAssertEqual(Set(entries.map(\.level)), Set([.info, .success, .warning, .error]))
        XCTAssertGreaterThanOrEqual(sections.count, 2)
        XCTAssertTrue(zip(entries, entries.dropFirst()).allSatisfy { $0.timestamp > $1.timestamp })
        XCTAssertTrue(entries.contains { $0.message.count > 80 })
    }
    #endif

    @MainActor
    func testBounceCoordinatorChangesOnlyConfiguredScrollViewAndRestoresValues() {
        let first = UIScrollView()
        let second = UIScrollView()
        first.bounces = true
        second.bounces = true
        let coordinator = DiagnosticsScrollBounceCoordinator()

        coordinator.configure(first)
        XCTAssertFalse(first.bounces)
        XCTAssertTrue(second.bounces)

        coordinator.configure(second)
        XCTAssertTrue(first.bounces)
        XCTAssertFalse(second.bounces)

        coordinator.restore()
        XCTAssertTrue(first.bounces)
        XCTAssertTrue(second.bounces)
    }

    func testDiagnosticsBounceConfigurationDoesNotUseGlobalAppearance() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("scrollView.bounces = false"))
        XCTAssertFalse(source.contains("UIScrollView.appearance()"))
        XCTAssertTrue(source.contains("UserSystemLogger.shared.clear()"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))
    }
}

final class ProfileSettingsStructureTests: XCTestCase {
    func testProfileFinalOrderAndAnnouncementRemoval() {
        XCTAssertEqual(ProfileMenuStructure.finalOrder, [
            "orders", "invitations", "traffic", "changePassword",
            "settings", "checkUpdate", "aboutSupport", "deleteAccount", "signout"
        ])
        XCTAssertFalse(ProfileMenuStructure.finalOrder.contains("announcements"))
    }

    func testSettingsContainOnlyLanguageAndAppearance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/SettingsView.swift"
        ))
        let start = try XCTUnwrap(source.range(of: "struct SettingsView: View")?.lowerBound)
        let end = try XCTUnwrap(
            source.range(of: "enum SettingsAppearance", range: start..<source.endIndex)?.lowerBound
        )
        let settingsView = String(source[start..<end])

        XCTAssertEqual(settingsView.components(separatedBy: "identifier: \"settings.language\"").count - 1, 1)
        XCTAssertEqual(settingsView.components(separatedBy: "identifier: \"settings.appearance\"").count - 1, 1)
        XCTAssertEqual(settingsView.components(separatedBy: "settingsRow(").count - 1, 3)
    }

    func testSettingsSelectionRequestsUseImmediateGlobalModalChoices() {
        let language = SettingsSelectionPresentation.languageRequest(
            currentLanguage: "en"
        )
        XCTAssertEqual(language.kind, .selection)
        XCTAssertEqual(language.selectionBehavior, .immediate)
        XCTAssertEqual(language.title, .localized("语言"))
        XCTAssertEqual(language.selectionOptions.map(\.id), ["zh-Hans", "en"])
        XCTAssertEqual(language.initialSelectionID, "en")
        XCTAssertNil(language.secondary)
        XCTAssertTrue(language.allowsBackdropDismiss)

        let appearance = SettingsSelectionPresentation.appearanceRequest(
            currentAppearance: "dark"
        )
        XCTAssertEqual(appearance.kind, .selection)
        XCTAssertEqual(appearance.selectionBehavior, .immediate)
        XCTAssertEqual(appearance.title, .localized("外观"))
        XCTAssertEqual(appearance.selectionOptions.map(\.id), [
            "system", "light", "dark"
        ])
        XCTAssertEqual(appearance.initialSelectionID, "dark")
        XCTAssertNil(appearance.secondary)
        XCTAssertTrue(appearance.allowsBackdropDismiss)
        XCTAssertEqual(SettingsAppearance.titleIconSize, 19 * 0.75)
    }

    func testSettingsSelectionRejectsUnknownChoicesAndMapsVisibleValues() {
        XCTAssertEqual(
            SettingsSelectionPresentation.language(for: .selection("en")),
            "en"
        )
        XCTAssertNil(SettingsSelectionPresentation.language(for: .selection("fr")))
        XCTAssertEqual(
            SettingsSelectionPresentation.appearance(for: .selection("light")),
            "light"
        )
        XCTAssertNil(SettingsSelectionPresentation.appearance(for: .dismissed))
        XCTAssertEqual(
            SettingsSelectionPresentation.languageTitleKey(for: "en"),
            "English"
        )
        XCTAssertEqual(
            SettingsSelectionPresentation.appearanceTitleKey(for: "dark"),
            "深色"
        )
    }

    func testSettingsViewUsesRowsInsteadOfSystemPickersAndHasUnifiedTitle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/SettingsView.swift"
        ))
        let end = try XCTUnwrap(source.range(of: "enum SettingsAppearance")?.lowerBound)
        let settingsView = String(source[..<end])

        XCTAssertFalse(settingsView.contains("Picker("))
        XCTAssertFalse(settingsView.contains("settings.section.general"))
        XCTAssertTrue(settingsView.contains("ProfileMenuItem.settings.icon"))
        XCTAssertTrue(settingsView.contains("ProfileMenuItem.settings.titleKey"))
        XCTAssertTrue(settingsView.contains("settings.language"))
        XCTAssertTrue(settingsView.contains("settings.appearance"))
    }

    func testAboutSupportItemsAlwaysRemainVisibleInFixedOrder() {
        let expected = [
            "privacyPolicy", "terms", "website", "diagnostics", "telegram"
        ]
        XCTAssertEqual(AboutSupportItem.allCases.map(\.rawValue), expected)
        XCTAssertEqual(AboutSupportItem.visibleItems().map(\.rawValue), expected)
        XCTAssertEqual(
            AboutSupportItem.visibleItems(config: supportConfig()).map(\.rawValue),
            expected
        )

        let registration = V2BoardRegistrationConfig(
            requiresEmailVerification: false,
            requiresInvitation: false,
            requiresRecaptcha: false,
            emailWhitelistEnabled: false,
            emailWhitelistSuffixes: [],
            termsOfServiceURL: URL(string: "https://legal.example.invalid/terms")
        )
        let visible = AboutSupportItem.visibleItems(
            config: supportConfig(
                privacy: "https://legal.example.invalid/privacy",
                homePage: "https://www.example.invalid",
                telegram: "https://t.me/example"
            ),
            registration: registration
        )
        XCTAssertEqual(visible.map(\.rawValue), expected)

        let malformed = AboutSupportItem.visibleItems(config: supportConfig(
            privacy: "http://legal.example.invalid/privacy",
            homePage: "not a URL",
            telegram: "https://user:password@example.invalid/group"
        ))
        XCTAssertEqual(malformed.map(\.rawValue), expected)
    }

    func testAboutSupportIconsAndColorsUseProfileMenuVisualSystem() {
        let expected: [(AboutSupportItem, String, String)] = [
            (.privacyPolicy, "hand.raised", "success"),
            (.terms, "doc.text", "support"),
            (.website, "globe", "website"),
            (.diagnostics, "doc.text.magnifyingglass", "emphasis"),
            (.telegram, "paperplane", "support"),
        ]
        for (item, icon, tint) in expected {
            XCTAssertEqual(item.systemImage, icon)
            XCTAssertEqual(item.tint, tint)
        }
    }

    func testAboutDiagnosticsAndDiagnosticsTitleShareBrandEmphasis() throws {
        XCTAssertEqual(AboutSupportItem.diagnostics.systemImage, "doc.text.magnifyingglass")
        XCTAssertEqual(AboutSupportItem.diagnostics.tint, "emphasis")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/SettingsView.swift"
        ))
        let start = try XCTUnwrap(
            source.range(of: "struct DiagnosticsLogView: View")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(of: "extension UserLogLevel", range: start..<source.endIndex)?.lowerBound
        )
        let view = String(source[start..<end])
        XCTAssertTrue(view.contains(".foregroundStyle(brand.theme.emphasis)"))
        XCTAssertTrue(view.contains(".accessibilityIdentifier(\"diagnostics.title.icon\")"))
    }

    func testProfileMenuAppearanceKeepsExistingRowGeometry() {
        XCTAssertEqual(ProfileMenuAppearance.customIconSize, 21)
        XCTAssertEqual(ProfileMenuAppearance.systemIconSize, 15)
        XCTAssertEqual(ProfileMenuAppearance.iconContainerWidth, 34)
        XCTAssertEqual(ProfileMenuAppearance.titleFontSize, 14)
        XCTAssertEqual(ProfileMenuAppearance.chevronSize, 12)
        XCTAssertEqual(ProfileMenuAppearance.horizontalPadding, 16)
        XCTAssertEqual(ProfileMenuAppearance.verticalPadding, 12)
        XCTAssertEqual(ProfileMenuAppearance.minimumRowHeight, 56)
        XCTAssertEqual(ProfileMenuAppearance.dividerLeadingInset, 50)
        XCTAssertEqual(ProfileMenuAppearance.dividerTrailingInset, 16)
    }

    func testAboutSupportExternalLinksUseNarrowHTTPSPolicyIndependently() {
        for value in [
            nil, "", "http://example.invalid/path", "javascript:alert(1)",
            "https:///missing-host", "https://user@example.invalid/path",
            "https://user:password@example.invalid/path"
        ] {
            XCTAssertNil(SettingsLinks.externalURL(value))
        }
        XCTAssertEqual(
            SettingsLinks.externalURL(" https://example.invalid/path?q=1 ")?.absoluteString,
            "https://example.invalid/path?q=1"
        )
    }

    func testAboutSupportConfiguredActionsRemainURLValidated() {
        let valid = supportConfig(
            privacy: "https://legal.example.invalid/privacy",
            homePage: "https://www.example.invalid",
            telegram: "https://community.example.invalid/group"
        )
        let registration = V2BoardRegistrationConfig(
            requiresEmailVerification: false,
            requiresInvitation: false,
            requiresRecaptcha: false,
            emailWhitelistEnabled: false,
            emailWhitelistSuffixes: [],
            termsOfServiceURL: URL(string: "https://legal.example.invalid/terms")
        )
        XCTAssertEqual(
            AboutSupportPresentation.configuredURL(for: .privacyPolicy, config: valid)?.path,
            "/privacy"
        )
        XCTAssertEqual(
            AboutSupportPresentation.configuredURL(
                for: .terms,
                config: valid,
                registration: registration
            )?.path,
            "/terms"
        )
        XCTAssertEqual(
            AboutSupportPresentation.configuredURL(for: .website, config: valid)?.host,
            "www.example.invalid"
        )
        XCTAssertEqual(
            AboutSupportPresentation.configuredURL(for: .telegram, config: valid)?.host,
            "community.example.invalid"
        )

        let invalid = supportConfig(
            privacy: "http://legal.example.invalid/privacy",
            homePage: "not a URL",
            telegram: "https://user@example.invalid/group"
        )
        for item in [
            AboutSupportItem.privacyPolicy, .website, .telegram, .diagnostics
        ] {
            XCTAssertNil(AboutSupportPresentation.configuredURL(for: item, config: invalid))
        }
    }

    func testAboutSupportUnavailableFeedbackIsLocalizedAndDoesNotExposeConfiguration() throws {
        let expected: [(AboutSupportItem, String, String)] = [
            (.privacyPolicy, "about.privacy_policy", "about.privacy_policy.unavailable"),
            (.terms, "about.terms", "about.terms.unavailable"),
            (.website, "profile.menu.website", "about.website.unavailable"),
            (.telegram, "profile.menu.telegram", "about.telegram.unavailable"),
        ]
        for (item, title, message) in expected {
            let request = try XCTUnwrap(AboutSupportPresentation.unavailableRequest(for: item))
            XCTAssertEqual(request.kind, .information)
            XCTAssertEqual(request.title, .localized(title))
            XCTAssertEqual(request.message, .localized(message))
            let description = String(describing: request)
            XCTAssertFalse(description.contains("https://"))
            XCTAssertFalse(description.contains("HTTP"))
            XCTAssertFalse(description.contains("decoder"))
        }
        XCTAssertNil(AboutSupportPresentation.unavailableRequest(for: .diagnostics))
    }

    func testProfileMarketingVersionUsesLocalizedNonBuildPresentation() throws {
        XCTAssertEqual(
            ProfileVersionPresentation.text(
                version: "9.8.7",
                locale: Locale(identifier: "zh-Hans")
            ),
            "版本：9.8.7"
        )
        XCTAssertEqual(
            ProfileVersionPresentation.text(
                version: "9.8.7",
                locale: Locale(identifier: "en")
            ),
            "Version: 9.8.7"
        )
        let bundleVersion = (
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )?.trimmed.nilIfEmpty ?? "--"
        XCTAssertEqual(ProfileVersionPresentation.marketingVersion, bundleVersion)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/ProfileView.swift"
        ))
        let start = try XCTUnwrap(source.range(of: "enum ProfileVersionPresentation")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "struct ProfileView")?.lowerBound)
        let presentation = String(source[start..<end])
        XCTAssertTrue(presentation.contains("CFBundleShortVersionString"))
        XCTAssertFalse(presentation.contains("CFBundleVersion"))
        XCTAssertNil(presentation.range(
            of: #"\"[0-9]+\.[0-9]+\.[0-9]+\""#,
            options: .regularExpression
        ))
    }

    func testProfileMarketingVersionUsesFlexibleBottomLayout() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/ProfileView.swift"
        ))
        let start = try XCTUnwrap(source.range(of: "struct ProfileView: View")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "enum ProfileMenuItem")?.lowerBound)
        let view = String(source[start..<end])

        XCTAssertTrue(view.contains("GeometryReader { geometry in"))
        XCTAssertTrue(view.contains("Spacer(minLength: 16)"))
        XCTAssertTrue(view.contains(".padding(.bottom, 24)"))
        XCTAssertTrue(view.contains(".frame(minHeight: geometry.size.height, alignment: .top)"))
        XCTAssertTrue(view.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertFalse(view.contains("padding(.top, 150)"))
        XCTAssertFalse(view.contains("position("))
        XCTAssertFalse(view.contains("offset(y:"))
    }

    func testProfileSignOutIsTheLastRowInTheUnifiedMenuCard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/ProfileView.swift"
        ))
        let start = try XCTUnwrap(source.range(of: "struct ProfileView: View")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "enum ProfileMenuAppearance")?.lowerBound)
        let view = String(source[start..<end])

        XCTAssertEqual(ProfileMenuStructure.items.count, 8)
        XCTAssertEqual(
            CGFloat(ProfileMenuStructure.items.count + 1)
                * ProfileMenuAppearance.minimumRowHeight
                + CGFloat(ProfileMenuStructure.items.count),
            512
        )
        XCTAssertEqual(view.components(separatedBy: "ProfileMenuCard {").count - 1, 1)
        XCTAssertTrue(view.contains(
            "ProfileMenuSeparator()\n                            Button {"
        ))
        XCTAssertTrue(view.contains("icon: \"ProfileSignOutIcon\""))
        XCTAssertTrue(view.contains("tint: \"error\""))
        XCTAssertTrue(view.contains("showsChevron: true"))
        XCTAssertTrue(view.contains("Spacer(minLength: 16)"))
        XCTAssertFalse(view.contains(".surfaceCard().padding(.top, 8)"))

        let appearanceStart = try XCTUnwrap(
            source.range(of: "enum ProfileMenuAppearance")?.lowerBound
        )
        let itemStart = try XCTUnwrap(
            source.range(of: "enum ProfileMenuItem")?.lowerBound
        )
        let sharedVisuals = String(source[appearanceStart..<itemStart])
        XCTAssertTrue(sharedVisuals.contains("static let chevronSize: CGFloat = 12"))
        XCTAssertTrue(sharedVisuals.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(sharedVisuals.contains("weight: .semibold"))
        XCTAssertTrue(sharedVisuals.contains("brand.theme.tertiary"))
    }

    func testAboutSupportViewUsesProfileIconAndRetainsBasedOnSizeScrolling() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/SettingsView.swift"
        ))
        let start = try XCTUnwrap(source.range(of: "struct AboutSupportView")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "enum DiagnosticsLogClearPresentation")?.lowerBound)
        let view = String(source[start..<end])
        XCTAssertTrue(view.contains("ProfileMenuItem.aboutSupport.icon"))
        XCTAssertTrue(view.contains("ProfileMenuItem.aboutSupport.titleKey"))
        XCTAssertTrue(view.contains(".frame(width: 15.75, height: 15.75)"))
        XCTAssertTrue(view.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertTrue(view.contains("ProfileMenuCard"))
        XCTAssertTrue(view.contains("ProfileMenuRow"))
        XCTAssertTrue(view.contains("ProfileMenuSeparator"))
        XCTAssertTrue(view.contains("tint: item.tint"))
        XCTAssertFalse(view.contains("showsChevron: false"))
        XCTAssertTrue(view.contains(".padding(.horizontal, 12)"))
        XCTAssertTrue(view.contains(".padding(.top, 12)"))
        XCTAssertFalse(view.contains("List {"))
        XCTAssertFalse(view.contains("Label(LocalizedStringKey"))
        XCTAssertFalse(view.contains(".task { await model.loadAboutSupportConfigurationIfNeeded()"))
    }

    func testProfileAndAboutDirectlyShareMenuRowCardAndSeparator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let profileSource = try String(contentsOf: root.appendingPathComponent(
            "App/Views/ProfileView.swift"
        ))
        let profileStart = try XCTUnwrap(
            profileSource.range(of: "struct ProfileView: View")?.lowerBound
        )
        let profileEnd = try XCTUnwrap(
            profileSource.range(of: "enum ProfileMenuAppearance")?.lowerBound
        )
        let profileView = String(profileSource[profileStart..<profileEnd])
        XCTAssertTrue(profileView.contains("ProfileMenuCard"))
        XCTAssertTrue(profileView.contains("ProfileMenuRow"))
        XCTAssertTrue(profileView.contains("ProfileMenuSeparator"))

        let appearanceStart = try XCTUnwrap(
            profileSource.range(of: "enum ProfileMenuAppearance")?.lowerBound
        )
        let itemStart = try XCTUnwrap(
            profileSource.range(of: "enum ProfileMenuItem")?.lowerBound
        )
        let sharedVisuals = String(profileSource[appearanceStart..<itemStart])
        XCTAssertTrue(sharedVisuals.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(sharedVisuals.contains("weight: .semibold"))
        XCTAssertTrue(sharedVisuals.contains("brand.theme.tertiary"))
        XCTAssertTrue(sharedVisuals.contains(".surfaceCard()"))

        let settingsSource = try String(contentsOf: root.appendingPathComponent(
            "App/Views/SettingsView.swift"
        ))
        let aboutStart = try XCTUnwrap(
            settingsSource.range(of: "struct AboutSupportView")?.lowerBound
        )
        let aboutEnd = try XCTUnwrap(
            settingsSource.range(of: "enum DiagnosticsLogClearPresentation")?.lowerBound
        )
        let aboutView = String(settingsSource[aboutStart..<aboutEnd])
        XCTAssertTrue(aboutView.contains("ProfileMenuCard"))
        XCTAssertTrue(aboutView.contains("ProfileMenuRow"))
        XCTAssertTrue(aboutView.contains("ProfileMenuSeparator"))
        XCTAssertTrue(aboutView.contains("NavigationLink { DiagnosticsLogView() }"))
        XCTAssertTrue(aboutView.contains("startLinkAction(for: item)"))
    }

    @MainActor
    func testAboutSupportTermsLookupIsSingleFlightAndCached() async throws {
        let transport = RecordingNetworkTransport { request, _ in
            (Data(#"{"data":{"tos_url":"https://legal.example.invalid/terms"}}"#.utf8),
             HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
             )!)
        }
        let fixture = aboutSupportModel(transport: transport)
        defer { UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite) }
        try await establish(
            supportSession("a"),
            in: fixture.model,
            store: fixture.store
        )

        async let first = fixture.model.aboutSupportTermsURL()
        async let second = fixture.model.aboutSupportTermsURL()
        let urls = try await [first, second]
        let cached = try await fixture.model.aboutSupportTermsURL()

        XCTAssertTrue(urls.allSatisfy {
            $0?.absoluteString == "https://legal.example.invalid/terms"
        })
        XCTAssertEqual(cached?.absoluteString, "https://legal.example.invalid/terms")
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.allSatisfy {
            $0.method == "GET" && $0.kind == .apiRead
        })
    }

    @MainActor
    func testAboutSupportTermsLookupCachesDefiniteMissingURL() async throws {
        let transport = RecordingNetworkTransport { request, _ in
            (Data(#"{"data":{}}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let fixture = aboutSupportModel(transport: transport)
        defer { UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite) }
        try await establish(supportSession("a"), in: fixture.model, store: fixture.store)

        let first = try await fixture.model.aboutSupportTermsURL()
        let second = try await fixture.model.aboutSupportTermsURL()
        let calls = await transport.calls
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor
    func testAboutSupportTermsLookupFailureDoesNotCreateCachedResult() async throws {
        let transport = RecordingNetworkTransport { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let fixture = aboutSupportModel(transport: transport)
        defer { UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite) }
        try await establish(supportSession("a"), in: fixture.model, store: fixture.store)

        do {
            _ = try await fixture.model.aboutSupportTermsURL()
            XCTFail("A failed guest-config lookup must not produce a Terms URL")
        } catch {
            XCTAssertNil(fixture.model.registration)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor
    func testAboutSupportGuestConfigLateResultCannotCrossSessionGeneration() async throws {
        let gate = SessionPersistencePauseGate()
        let transport = RecordingNetworkTransport { request, _ in
            await gate.pause()
            return (Data(#"{"data":{"tos_url":"https://legal.example.invalid/terms"}}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!)
        }
        let fixture = aboutSupportModel(transport: transport)
        defer { UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite) }
        try await establish(
            supportSession("a"),
            in: fixture.model,
            store: fixture.store
        )

        let old = Task { try await fixture.model.aboutSupportTermsURL() }
        await fulfillment(of: [gate.entered], timeout: 2)
        await fixture.model.signOut()
        try await establish(
            supportSession("b"),
            in: fixture.model,
            store: fixture.store
        )
        await gate.resume()
        do {
            _ = try await old.value
            XCTFail("An older account generation must not commit a Terms URL")
        } catch is CancellationError {
        }

        XCTAssertNil(fixture.model.registration)
        XCTAssertEqual(fixture.model.session?.email, "b@example.invalid")
    }

    @MainActor
    private func aboutSupportModel(
        transport: RecordingNetworkTransport
    ) -> (model: AppModel, store: SessionStore, suite: String) {
        let suite = "NetworkClient.about-support.\(UUID().uuidString)"
        let router = APIRecoveryRouter(
            recoveryInitiallySuspendedForFormalVPN: false,
            writeTransportFactory: { transport }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        let store = SessionStore(
            keychain: MemorySessionKeychain(),
            defaultsSuiteName: suite
        )
        let model = AppModel(
            offline: false,
            businessDataAPI: BootstrapBusinessAPI(),
            nodeRepository: BootstrapNodeRepository(),
            apiHealthMonitor: APIHealthMonitor(transport: transport, observeNetwork: false),
            sessionStore: store,
            initialConfig: supportConfig(),
            recoveryRouter: router,
            apiClient: api
        )
        return (model, store, suite)
    }

    @MainActor
    private func establish(
        _ session: UserSession,
        in model: AppModel,
        store: SessionStore
    ) async throws {
        let generation = UUID()
        let replaced = try await store.replace(
            session,
            generation: generation,
            replacing: nil
        )
        XCTAssertTrue(replaced)
        await model.establishAuthenticatedSession(
            session,
            source: .login,
            generation: generation
        )
        XCTAssertEqual(model.session?.email, session.email)
    }

    private func supportSession(_ owner: String) -> UserSession {
        UserSession(
            email: "\(owner)@example.invalid",
            authData: "synthetic-\(owner)",
            accountToken: nil,
            subscriptionURL: "https://subscription.example.invalid/\(owner)",
            uploadBytes: 0,
            downloadBytes: 0,
            transferEnableBytes: 1,
            expiredAt: 0,
            planID: nil,
            planName: "Fixture",
            balanceCents: 0,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func supportConfig(
        privacy: String? = nil,
        homePage: String? = nil,
        telegram: String? = nil
    ) -> AppConfig {
        AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: homePage,
            privacyPolicyURL: privacy,
            telegramGroup: telegram, supportAPI: nil, updateURL: nil,
            userAgent: "Tests", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: ["https://127.0.0.1"], activeAPIBaseURL: nil,
            builtInProxy: []
        )
    }
}

private actor AppUpdateCheckingStub: AppUpdateChecking {
    enum Behavior: Sendable {
        case release(AppUpdateRelease)
        case failure(AppUpdateError)
        case delayed(AppUpdateRelease, Duration)
    }

    private let behavior: Behavior
    private var calls = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func fetchRelease(from manifestURL: URL) async throws -> AppUpdateRelease {
        calls += 1
        switch behavior {
        case let .release(release):
            return release
        case let .failure(error):
            throw error
        case let .delayed(release, duration):
            try await Task.sleep(for: duration)
            return release
        }
    }

    func callCount() -> Int { calls }
}

private final class AppUpdateURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    static let registry = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var fixture: Fixture?
        private var requests: [URLRequest] = []

        func configure(_ value: Fixture?) {
            lock.withLock {
                fixture = value
                requests = []
            }
        }

        func snapshot() -> (Fixture?, [URLRequest]) {
            lock.withLock { (fixture, requests) }
        }

        func record(_ request: URLRequest) {
            lock.withLock { requests.append(request) }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.registry.record(request)
        guard let fixture = Self.registry.snapshot().0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AppUpdateTests: XCTestCase {
    func testManifestParsesIOSAndIgnoresForceAndOtherPlatforms() throws {
        let data = Data(#"""
        {
          "force_update": 1,
          "platforms": {
            "windows": {"unexpected": true},
            "macos": {"version": {"nested": true}},
            "android": [1, 2, 3],
            "ios": {
              "version": " 0.2.0 ",
              "body": " Notes ",
              "download_url": "https://apps.apple.com/app/example/id123456789"
            }
          }
        }
        """#.utf8)
        let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
        let release = try manifest.validatedIOSRelease()
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.body, "Notes")
        XCTAssertEqual(
            release.updateURL?.absoluteString,
            "https://apps.apple.com/app/example/id123456789"
        )
    }

    func testManifestRequiresIOSAndNumericVersionButAllowsEmptyBody() throws {
        let missing = try JSONDecoder().decode(
            AppUpdateManifest.self,
            from: Data(#"{"platforms":{}}"#.utf8)
        )
        XCTAssertThrowsError(try missing.validatedIOSRelease())

        let invalid = try JSONDecoder().decode(
            AppUpdateManifest.self,
            from: Data(#"{"platforms":{"ios":{"version":"v1.2","body":""}}}"#.utf8)
        )
        XCTAssertThrowsError(try invalid.validatedIOSRelease())

        let empty = try JSONDecoder().decode(
            AppUpdateManifest.self,
            from: Data(#"{"platforms":{"ios":{"version":"1.2","body":"  "}}}"#.utf8)
        )
        XCTAssertEqual(try empty.validatedIOSRelease().body, "")
    }

    func testManifestRejectsOversizedOrUnsafeVisibleFields() throws {
        let body = String(repeating: "a", count: AppUpdateManifestLimits.maximumBodyCharacters + 1)
        let json = #"{"platforms":{"ios":{"version":"1.0","body":"\#(body)"}}}"#
        let oversized = try JSONDecoder().decode(AppUpdateManifest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try oversized.validatedIOSRelease())

        let control = try JSONDecoder().decode(
            AppUpdateManifest.self,
            from: Data(#"{"platforms":{"ios":{"version":"1.0","body":"bad\u0000value"}}}"#.utf8)
        )
        XCTAssertThrowsError(try control.validatedIOSRelease())
    }

    func testNumericVersionComparisonUsesNumericComponentsAndTrailingZeroEquivalence() throws {
        func version(_ value: String) throws -> AppNumericVersion {
            try XCTUnwrap(AppNumericVersion(value))
        }
        XCTAssertEqual(try version("0.2.0"), try version("0.2"))
        XCTAssertGreaterThan(try version("0.2.1"), try version("0.2.0"))
        XCTAssertGreaterThan(try version("0.10.0"), try version("0.9.9"))
        XCTAssertEqual(try version("1.0"), try version("1.0.0"))
        XCTAssertGreaterThan(try version("1.0.1"), try version("1.0"))
        XCTAssertGreaterThan(try version("2.0.0"), try version("1.99.99"))
        XCTAssertNil(AppNumericVersion("1..0"))
        XCTAssertNil(AppNumericVersion("1.0-beta"))
    }

    func testUpdateAndAppStoreURLPoliciesAreNarrow() {
        XCTAssertNil(AppUpdateURLPolicy.manifestURL("http://example.invalid/update.json"))
        XCTAssertNil(AppUpdateURLPolicy.manifestURL("https://user@example.invalid/update.json"))
        XCTAssertNil(AppUpdateURLPolicy.manifestURL("https://user:pass@example.invalid/update.json"))
        XCTAssertNotNil(AppUpdateURLPolicy.manifestURL("https://example.invalid/update.json"))

        XCTAssertNil(AppUpdateURLPolicy.appStoreProductURL(nil))
        XCTAssertNil(AppUpdateURLPolicy.appStoreProductURL("https://example.invalid/app/id123"))
        XCTAssertNil(AppUpdateURLPolicy.appStoreProductURL("https://apps.apple.com/app/example"))
        XCTAssertNil(AppUpdateURLPolicy.appStoreProductURL("https://apps.apple.com/..."))
        XCTAssertNil(AppUpdateURLPolicy.appStoreProductURL("https://apps.apple.com/app/example/id١٢٣"))
        XCTAssertNil(AppUpdateURLPolicy.appStoreProductURL("https://apps.apple.com.evil.invalid/app/id123"))
        XCTAssertNotNil(AppUpdateURLPolicy.appStoreProductURL(
            "https://apps.apple.com/us/app/example/id123456789?l=en"
        ))

        XCTAssertNotNil(AppUpdateURLPolicy.updateTargetURL(
            "https://updates.example.invalid/release-notes",
            environment: .debug
        ))
        XCTAssertNil(AppUpdateURLPolicy.updateTargetURL(
            "http://updates.example.invalid/release-notes",
            environment: .debug
        ))
        XCTAssertNil(AppUpdateURLPolicy.updateTargetURL(
            "https://user@updates.example.invalid/release-notes",
            environment: .debug
        ))
        XCTAssertNotNil(AppUpdateURLPolicy.updateTargetURL(
            "https://apps.apple.com/us/app/example/id123456789",
            environment: .release
        ))
        XCTAssertNil(AppUpdateURLPolicy.updateTargetURL(
            "https://updates.example.invalid/release-notes",
            environment: .release
        ))
    }

    func testUpdateServiceAcceptsOnlyJSONMediaTypes() {
        XCTAssertTrue(AppUpdateService.isJSONContentType("application/json"))
        XCTAssertTrue(AppUpdateService.isJSONContentType("application/problem+json; charset=utf-8"))
        XCTAssertFalse(AppUpdateService.isJSONContentType("text/json"))
        XCTAssertFalse(AppUpdateService.isJSONContentType("text/html"))
        XCTAssertFalse(AppUpdateService.isJSONContentType(nil))
    }

    func testUpdateServicePerformsFreshCookielessGETAndParsesValidatedJSON() async throws {
        AppUpdateURLProtocolStub.registry.configure(.init(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            data: Data(#"{"platforms":{"ios":{"version":"0.2.1","body":"Notes","download_url":"https://updates.example.invalid/release-notes"}}}"#.utf8)
        ))
        defer { AppUpdateURLProtocolStub.registry.configure(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateURLProtocolStub.self]
        let service = AppUpdateService(configuration: configuration)

        let release = try await service.fetchRelease(
            from: XCTUnwrap(URL(string: "https://updates.example.invalid/update.json"))
        )

        XCTAssertEqual(release.version, "0.2.1")
        XCTAssertEqual(release.body, "Notes")
        XCTAssertEqual(
            release.updateURL?.absoluteString,
            "https://updates.example.invalid/release-notes"
        )
        let requests = AppUpdateURLProtocolStub.registry.snapshot().1
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests.first?.timeoutInterval, 8)
    }

    func testUpdateServiceRejectsHTMLHTTPFailureAndOversizedJSON() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateURLProtocolStub.self]
        let service = AppUpdateService(configuration: configuration)
        let url = try XCTUnwrap(URL(string: "https://updates.example.invalid/update.json"))
        let fixtures: [AppUpdateURLProtocolStub.Fixture] = [
            .init(statusCode: 200, headers: ["Content-Type": "text/html"], data: Data("<html/>".utf8)),
            .init(statusCode: 500, headers: ["Content-Type": "application/json"], data: Data(#"{"message":"internal"}"#.utf8)),
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                data: Data(repeating: 0x20, count: AppUpdateManifestLimits.maximumResponseBytes + 1)
            )
        ]

        for fixture in fixtures {
            AppUpdateURLProtocolStub.registry.configure(fixture)
            do {
                _ = try await service.fetchRelease(from: url)
                XCTFail("Unsafe update response must be rejected")
            } catch let error as AppUpdateError {
                XCTAssertEqual(error, .invalidResponse)
            } catch {
                XCTFail("Unexpected error: \(type(of: error))")
            }
        }
        AppUpdateURLProtocolStub.registry.configure(nil)
    }

    func testUpdatePresentationAlwaysOffersUpdateAndLaterWithoutExposingTarget() throws {
        let release = AppUpdateRelease(
            version: "1.2.3",
            body: "Release notes",
            updateURL: URL(string: "https://apps.apple.com/app/example/id123456789")
        )
        let request = ProfileUpdatePresentation.updateRequest(
            release: release,
            locale: Locale(identifier: "zh-Hans")
        )
        XCTAssertEqual(request.kind, .confirmation)
        XCTAssertEqual(request.title, .localized("profile.version.new_version"))
        XCTAssertEqual(request.message, .verbatim("最新版本：1.2.3\n\nRelease notes"))
        XCTAssertEqual(request.primary.title, .localized("profile.version.update_now"))
        XCTAssertEqual(request.secondary?.title, .localized("profile.version.later"))
        XCTAssertTrue(request.allowsBackdropDismiss)

        let withoutTarget = ProfileUpdatePresentation.updateRequest(
            release: AppUpdateRelease(version: "1.2.3", body: "", updateURL: nil),
            locale: Locale(identifier: "en")
        )
        XCTAssertEqual(withoutTarget.kind, .confirmation)
        XCTAssertEqual(withoutTarget.primary.title, .localized("profile.version.update_now"))
        XCTAssertEqual(withoutTarget.secondary?.title, .localized("profile.version.later"))
        XCTAssertEqual(withoutTarget.secondary?.role, .cancel)
        XCTAssertTrue(withoutTarget.allowsBackdropDismiss)
    }

    func testUpdateTargetIsRevalidatedForEnvironmentAndFailureIsSafe() throws {
        let generic = AppUpdateRelease(
            version: "1.2.3",
            body: "",
            updateURL: URL(string: "https://updates.example.invalid/release-notes")
        )
        XCTAssertNotNil(ProfileUpdatePresentation.validatedUpdateTarget(
            for: generic,
            environment: .debug
        ))
        XCTAssertNil(ProfileUpdatePresentation.validatedUpdateTarget(
            for: generic,
            environment: .release
        ))

        let invalid = AppUpdateRelease(version: "1.2.3", body: "", updateURL: nil)
        XCTAssertNil(ProfileUpdatePresentation.validatedUpdateTarget(
            for: invalid,
            environment: .debug
        ))
        let failure = ProfileUpdatePresentation.unavailableUpdateLinkRequest()
        XCTAssertEqual(failure.kind, .information)
        XCTAssertEqual(failure.title, .localized("profile.version.check"))
        XCTAssertEqual(
            failure.message,
            .localized("profile.version.update_link_unavailable")
        )
        XCTAssertFalse(String(describing: failure).contains("updates.example.invalid"))
    }

    @MainActor
    func testAppModelComparesRemoteVersionAndUsesOneSingleFlightRequest() async throws {
        let release = AppUpdateRelease(version: "0.2.1", body: "", updateURL: nil)
        let service = AppUpdateCheckingStub(.delayed(release, .milliseconds(80)))
        let model = AppModel(
            offline: false,
            initialConfig: updateConfig(),
            appUpdateService: service
        )

        async let first = model.checkForUpdates(currentVersion: "0.2.0")
        async let second = model.checkForUpdates(currentVersion: "0.2.0")
        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes, [.updateAvailable(release), .updateAvailable(release)])
        let calls = await service.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.appUpdateCheckState, .idle)
    }

    @MainActor
    func testAppModelTreatsEqualOrOlderRemoteAsUpToDate() async throws {
        for remote in ["0.2", "0.1.99"] {
            let service = AppUpdateCheckingStub(.release(
                AppUpdateRelease(version: remote, body: "", updateURL: nil)
            ))
            let model = AppModel(
                offline: false,
                initialConfig: updateConfig(),
                appUpdateService: service
            )
            let outcome = try await model.checkForUpdates(currentVersion: "0.2.0")
            XCTAssertEqual(outcome, .upToDate)
        }
    }

    @MainActor
    func testAppModelCancellationIsSilentAndInvalidConfigurationDoesNotRequest() async throws {
        let release = AppUpdateRelease(version: "1.0", body: "", updateURL: nil)
        let service = AppUpdateCheckingStub(.delayed(release, .seconds(2)))
        let model = AppModel(
            offline: false,
            initialConfig: updateConfig(),
            appUpdateService: service
        )
        let task = Task { try await model.checkForUpdates(currentVersion: "0.2.0") }
        try await Task.sleep(for: .milliseconds(40))
        model.cancelAppUpdateCheck()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not produce a result")
        } catch is CancellationError {
        }
        XCTAssertEqual(model.appUpdateCheckState, .idle)

        let invalidService = AppUpdateCheckingStub(.failure(.invalidResponse))
        let invalidModel = AppModel(
            offline: false,
            initialConfig: updateConfig(updateURL: "http://example.invalid/update.json"),
            appUpdateService: invalidService
        )
        do {
            _ = try await invalidModel.checkForUpdates(currentVersion: "0.2.0")
            XCTFail("An insecure update URL must be rejected")
        } catch {
        }
        let invalidCalls = await invalidService.callCount()
        XCTAssertEqual(invalidCalls, 0)
    }

    @MainActor
    func testUpdateUserLogsUseUpdateCategoryAndRecoverableFailureSeverity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        let release = AppUpdateRelease(version: "0.2.1", body: "", updateURL: nil)
        let model = AppModel(
            offline: false,
            initialConfig: updateConfig(),
            appUpdateService: AppUpdateCheckingStub(.release(release)),
            userSystemLogger: logger
        )

        _ = try await model.checkForUpdates(currentVersion: "0.2.0")
        model.recordAppUpdatePageOpened()
        let successEntries = await waitForUserLogs(logger, atLeast: 3)
        XCTAssertEqual(successEntries.count, 3)
        XCTAssertTrue(successEntries.allSatisfy { $0.module == .update })
        XCTAssertTrue(successEntries.allSatisfy { $0.level == .info })
        XCTAssertFalse(successEntries.map(\.message).joined().contains("https://"))

        let failureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: failureRoot) }
        let failureLogger = UserSystemLogger(directoryURL: failureRoot)
        let failureModel = AppModel(
            offline: false,
            initialConfig: updateConfig(),
            appUpdateService: AppUpdateCheckingStub(.failure(.invalidResponse)),
            userSystemLogger: failureLogger
        )
        do {
            _ = try await failureModel.checkForUpdates(currentVersion: "0.2.0")
            XCTFail("Expected update check failure")
        } catch {}
        let failureEntries = await waitForUserLogs(failureLogger, atLeast: 2)
        XCTAssertEqual(failureEntries.map(\.module), [.update, .update])
        XCTAssertEqual(failureEntries.map(\.level), [.warning, .info])
        XCTAssertFalse(failureEntries.map(\.message).joined().contains("updates.example.invalid"))
    }

    @MainActor
    func testCancelledUpdateCheckDoesNotProduceWarningOrErrorUserLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = UserSystemLogger(directoryURL: root)
        let release = AppUpdateRelease(version: "1.0", body: "", updateURL: nil)
        let model = AppModel(
            offline: false,
            initialConfig: updateConfig(),
            appUpdateService: AppUpdateCheckingStub(.delayed(release, .seconds(2))),
            userSystemLogger: logger
        )
        let task = Task { try await model.checkForUpdates(currentVersion: "0.2.0") }
        try await Task.sleep(for: .milliseconds(40))
        model.cancelAppUpdateCheck()
        do {
            _ = try await task.value
            XCTFail("Cancellation must remain silent")
        } catch is CancellationError {}

        let entries = await waitForUserLogs(logger, atLeast: 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.module, .update)
        XCTAssertEqual(entries.first?.level, .info)
    }

    func testUpdateFeatureHasNoAutomaticStartupCallOrForceUpdateDecision() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(contentsOf: root.appendingPathComponent("App/AppModel.swift"))
        let profileSource = try String(contentsOf: root.appendingPathComponent("App/Views/ProfileView.swift"))
        let manifestSource = try String(contentsOf: root.appendingPathComponent("SharedDomain/AppUpdateModels.swift"))
        let start = try XCTUnwrap(modelSource.range(of: "func start() async")?.lowerBound)
        let end = try XCTUnwrap(modelSource.range(of: "private func runRecoveryAcceptanceIfRequested")?.lowerBound)
        XCTAssertFalse(String(modelSource[start..<end]).contains("checkForUpdates"))
        XCTAssertTrue(profileSource.contains("Button(action: startUpdateCheck)"))
        XCTAssertFalse(manifestSource.contains("force_update"))
        XCTAssertFalse(manifestSource.contains("forceUpdate"))
    }

    private func updateConfig(
        updateURL: String = "https://updates.example.invalid/manifest.json"
    ) -> AppConfig {
        AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil,
            homePage: nil, telegramGroup: nil, supportAPI: nil,
            updateURL: updateURL, userAgent: "Tests", latencyDisplayRatio: 1,
            inviteLink: nil, apiBaseURLs: ["https://api.example.invalid"],
            activeAPIBaseURL: nil, builtInProxy: []
        )
    }

    @MainActor
    private func waitForUserLogs(
        _ logger: UserSystemLogger,
        atLeast expectedCount: Int
    ) async -> [UserLogEntry] {
        for _ in 0..<100 {
            let entries = await logger.currentEntries()
            if entries.count >= expectedCount { return entries }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await logger.currentEntries()
    }
}

private enum ChangePasswordFixtureResult {
    case success
    case failure
    case oldPasswordRejected
    case saveFailed
    case unsafeFailure
    case authenticationExpired
}

private actor PasswordResponseGate {
    let entered = XCTestExpectation(description: "change-password request suspended")
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ChangePasswordTransportState {
    private let result: ChangePasswordFixtureResult
    private var writes = 0
    private var nextGate: PasswordResponseGate?

    init(result: ChangePasswordFixtureResult) { self.result = result }

    func holdNextWrite(_ gate: PasswordResponseGate) { nextGate = gate }
    func postCount() -> Int { writes }

    func response(for request: URLRequest) async -> (status: Int, body: String) {
        if request.url?.path.hasSuffix(V2BoardAPIClient.registrationConfigPath) == true {
            return (200, #"{"data":{}}"#)
        }
        guard request.url?.path.hasSuffix(V2BoardAPIClient.changePasswordPath) == true else {
            XCTFail("Unexpected change-password fixture path")
            return (500, "{}")
        }
        writes += 1
        if let gate = nextGate {
            nextGate = nil
            await gate.wait()
        }
        switch result {
        case .success: return (200, #"{"data":true}"#)
        case .failure: return (422, #"{"message":"Synthetic current password rejected"}"#)
        case .oldPasswordRejected: return (500, #"{"message":"旧密码有误"}"#)
        case .saveFailed: return (500, #"{"message":"保存失败"}"#)
        case .unsafeFailure: return (500, #"{"message":"保存失败","trace":"secret"}"#)
        case .authenticationExpired: return (401, #"{"message":"Unauthenticated"}"#)
        }
    }
}

private struct ChangePasswordTransport: ManagedNetworkTransport {
    let state: ChangePasswordTransportState
    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        let response = await state.response(for: request)
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: response.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
    func finishTasksAndInvalidate() {}
}

@MainActor
private final class ChangePasswordFixture {
    let model: AppModel
    let state: ChangePasswordTransportState
    let userLogger: UserSystemLogger
    private let suite = "NetworkClient.change-password.\(UUID().uuidString)"
    private let logRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    init(
        result: ChangePasswordFixtureResult = .success,
        keychain: any SessionKeychainAccess = MemorySessionKeychain()
    ) throws {
        state = ChangePasswordTransportState(result: result)
        let transport = ChangePasswordTransport(state: state)
        let router = APIRecoveryRouter(
            recoveryInitiallySuspendedForFormalVPN: false,
            writeTransportFactory: { transport }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        let sessions = SessionStore(
            keychain: keychain,
            defaultsSuiteName: suite
        )
        let config = AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "Tests", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: ["https://api.cloudflare.com"], activeAPIBaseURL: nil,
            builtInProxy: []
        )
        userLogger = UserSystemLogger(directoryURL: logRoot)
        model = AppModel(
            offline: true,
            sessionStore: sessions,
            initialConfig: config,
            recoveryRouter: router,
            apiClient: api,
            userSystemLogger: userLogger
        )
    }

    func establish(account: String) async {
        let session = UserSession(
            email: "\(account)@example.invalid",
            authData: "synthetic-\(account)-\(UUID().uuidString)",
            accountToken: nil,
            subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 100,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil,
            verifiedAt: Date()
        )
        await model.establishAuthenticatedSession(session, source: .login)
    }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: logRoot)
    }

    func userLogs(atLeast expectedCount: Int) async -> [UserLogEntry] {
        for _ in 0..<100 {
            let entries = await userLogger.currentEntries()
            if entries.count >= expectedCount { return entries }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await userLogger.currentEntries()
    }
}

private enum AccountDeletionFixtureResult {
    case success
    case rejected
    case transportFailure
}

private actor AccountDeletionResponseGate {
    let entered = XCTestExpectation(description: "account deletion request suspended")
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct AccountDeletionRequestSnapshot: Sendable {
    let path: String
    let method: String?
    let authorization: String?
    let contentLength: String?
    let body: Data?
    let contentType: String?
}

private actor AccountDeletionTransportState {
    private let result: AccountDeletionFixtureResult
    private var snapshots: [AccountDeletionRequestSnapshot] = []
    private var nextGate: AccountDeletionResponseGate?

    init(result: AccountDeletionFixtureResult) { self.result = result }

    func holdNextWrite(_ gate: AccountDeletionResponseGate) { nextGate = gate }
    func requestCount() -> Int { snapshots.count }
    func requestSnapshots() -> [AccountDeletionRequestSnapshot] { snapshots }

    func response(for request: URLRequest) async throws -> (status: Int, body: String) {
        if request.url?.path.hasSuffix(V2BoardAPIClient.registrationConfigPath) == true {
            return (200, #"{"data":{}}"#)
        }
        guard request.url?.path.hasSuffix(V2BoardAPIClient.accountDeleteRequestPath) == true else {
            throw URLError(.badURL)
        }
        snapshots.append(AccountDeletionRequestSnapshot(
            path: request.url?.path ?? "",
            method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentLength: request.value(forHTTPHeaderField: "Content-Length"),
            body: request.httpBody,
            contentType: request.value(forHTTPHeaderField: "Content-Type")
        ))
        if let gate = nextGate {
            nextGate = nil
            await gate.wait()
        }
        switch result {
        case .success: return (200, #"{"data":true}"#)
        case .rejected: return (200, #"{"data":false}"#)
        case .transportFailure: throw URLError(.networkConnectionLost)
        }
    }
}

private struct AccountDeletionTransport: ManagedNetworkTransport {
    let state: AccountDeletionTransportState

    func data(
        for request: URLRequest,
        kind: NetworkRequestKind
    ) async throws -> (Data, URLResponse) {
        let response = try await state.response(for: request)
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    func finishTasksAndInvalidate() {}
}

@MainActor
private final class AccountDeletionFixture {
    let model: AppModel
    let state: AccountDeletionTransportState
    private let suite = "NetworkClient.account-deletion.\(UUID().uuidString)"

    init(result: AccountDeletionFixtureResult) throws {
        state = AccountDeletionTransportState(result: result)
        let transport = AccountDeletionTransport(state: state)
        let router = APIRecoveryRouter(
            recoveryInitiallySuspendedForFormalVPN: false,
            writeTransportFactory: { transport }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        let sessions = SessionStore(
            keychain: MemorySessionKeychain(),
            defaultsSuiteName: suite
        )
        let config = AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "Tests", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: ["https://api.cloudflare.com"], activeAPIBaseURL: nil,
            builtInProxy: []
        )
        model = AppModel(
            offline: true,
            sessionStore: sessions,
            initialConfig: config,
            recoveryRouter: router,
            apiClient: api
        )
    }

    func establish(account: String) async {
        let session = UserSession(
            email: "\(account)@example.invalid",
            authData: "synthetic-\(account)",
            accountToken: nil,
            subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 100,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil,
            verifiedAt: Date()
        )
        await model.establishAuthenticatedSession(session, source: .login)
    }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

final class LocalizationTests: XCTestCase {
    func testAboutWebsiteUsesExplicitEnglishAndChineseLocalization() throws {
        let english = try localizedStrings(language: "en")
        let chinese = try localizedStrings(language: "zh-Hans")

        XCTAssertEqual(english["profile.menu.website"], "Official Website")
        XCTAssertEqual(chinese["profile.menu.website"], "官方网站")
    }

    func testAccountDeletionRequestHasCompleteEnglishAndChineseCopy() throws {
        let english = try localizedStrings(language: "en")
        let chinese = try localizedStrings(language: "zh-Hans")

        XCTAssertEqual(english["profile.account_deletion.title"], "Delete Account")
        XCTAssertEqual(chinese["profile.account_deletion.title"], "删除账户")
        XCTAssertEqual(english["profile.account_deletion.submit"], "Submit Request")
        XCTAssertEqual(chinese["profile.account_deletion.submit"], "提交申请")
        XCTAssertEqual(english["profile.account_deletion.success.title"], "Request Submitted")
        XCTAssertEqual(chinese["profile.account_deletion.success.title"], "申请已提交")
        XCTAssertEqual(
            english["profile.account_deletion.success.message"],
            "Your account deletion request has been submitted. We will complete the process within 7 days."
        )
        XCTAssertEqual(
            chinese["profile.account_deletion.success.message"],
            "您的账户删除申请已提交，我们将在 7 日内完成处理。"
        )
    }

    func testCatalogContainsCompleteEnglishAndChineseTranslations() throws {
        let english = try localizedStrings(language: "en")
        let chinese = try localizedStrings(language: "zh-Hans")
        XCTAssertGreaterThan(english.count, 500)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))

        for key in english.keys {
            XCTAssertFalse(try XCTUnwrap(english[key]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key):en")
            XCTAssertFalse(try XCTUnwrap(chinese[key]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key):zh-Hans")
        }
    }

    func testCatalogFormatPlaceholdersMatchAcrossLanguages() throws {
        let english = try localizedStrings(language: "en")
        let chinese = try localizedStrings(language: "zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for key in english.keys {
            XCTAssertEqual(
                formatPlaceholders(in: try XCTUnwrap(english[key])),
                formatPlaceholders(in: try XCTUnwrap(chinese[key])),
                key
            )
        }
    }

    @MainActor
    func testLanguageSelectionPersistsWithoutChangingBusinessState() throws {
        let suite = "NetworkClient.localization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.language = "en"
        XCTAssertEqual(AppSettings(defaults: defaults).language, "en")
        settings.language = "zh-Hans"
        XCTAssertEqual(AppSettings(defaults: defaults).language, "zh-Hans")
    }

    @MainActor
    func testAppearanceSelectionPersistsWithExistingKeysAndSemantics() throws {
        let suite = "NetworkClient.appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.appearance = "dark"
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, "dark")
        XCTAssertEqual(settings.colorScheme, .dark)

        settings.appearance = "light"
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, "light")
        XCTAssertEqual(settings.colorScheme, .light)

        settings.appearance = "system"
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, "system")
        XCTAssertNil(settings.colorScheme)
    }

    func testRuntimeFormattingUsesSelectedLocaleAndMatchingArguments() {
        XCTAssertEqual(
            AppLocalization.string("vpn.unavailable.protection_notice", locale: Locale(identifier: "en")),
            "VPN is not available · Traffic is not protected"
        )
        XCTAssertEqual(
            AppLocalization.string("vpn.unavailable.protection_notice", locale: Locale(identifier: "zh-Hans")),
            "VPN 尚不可用 · 当前流量未受保护"
        )
        XCTAssertTrue(
            AppLocalization.string(
                "settings.diagnostics.summary %lld",
                locale: Locale(identifier: "en"),
                arguments: [Int64(3)]
            ).contains("Nodes: 3")
        )
    }

    func testStep261PowerStateCopyUsesProductThreeStateLanguage() throws {
        let english = try localizedStrings(language: "en")
        let chinese = try localizedStrings(language: "zh-Hans")
        XCTAssertEqual(english["vpn.state.disconnected"], "Disconnected")
        XCTAssertEqual(english["vpn.state.connecting"], "Connecting")
        XCTAssertEqual(english["vpn.state.connected"], "Connected")
        XCTAssertEqual(chinese["vpn.state.disconnected"], "未连接")
        XCTAssertEqual(chinese["vpn.state.connecting"], "连接中")
        XCTAssertEqual(chinese["vpn.state.connected"], "已连接")
        XCTAssertFalse(chinese["vpn.state.connecting"]?.contains("系统 VPN") == true)
    }


    func testMockStatesUseLocalizedKeysAndNeverClaimProtection() {
        XCTAssertEqual(
            TunnelDiagnostic(code: .coreNotIntegrated, message: "internal diagnostic").userFacingKey,
            L10nKey.tunnelCoreNotIntegrated
        )
        let capability = PendingProtocolCapabilities().capability(for: RuntimeProxyRecord(
            nodeID: "node", originalName: "Node", coreName: "Node",
            originalProxy: ["type": .string("vless")], runtimeProxy: nil, issue: nil
        ))
        XCTAssertEqual(capability.diagnosticKey, L10nKey.tunnelCapabilityUnverified)
    }

    func testClientValidationReturnsLocalizedMessageKeys() {
        XCTAssertThrowsError(try AuthValidation.validate(email: "invalid", password: "password")) { error in
            guard let error = error as? NetworkClientError else { return XCTFail("Unexpected error") }
            XCTAssertEqual(error.userFacingMessage, .localized(L10nKey.registerValidationEmailInvalid))
        }
    }

    private func localizedStrings(language: String) throws -> [String: String] {
        for bundle in candidateAppBundles() {
            guard let path = bundle.path(
                forResource: "Localizable", ofType: "strings", inDirectory: nil,
                forLocalization: language
            ), let values = NSDictionary(contentsOfFile: path) as? [String: String] else {
                continue
            }
            return values
        }
        throw NSError(
            domain: "LocalizationTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The installed test host is missing \(language) Localizable.strings"]
        )
    }

    private func candidateAppBundles() -> [Bundle] {
        var bundles = [Bundle.main, Bundle(for: LocalizationTests.self)]
        var location = Bundle(for: LocalizationTests.self).bundleURL
        while location.path != "/" {
            if location.pathExtension == "app", let appBundle = Bundle(url: location) {
                bundles.append(appBundle)
                break
            }
            location.deleteLastPathComponent()
        }
        var seen = Set<String>()
        return bundles.filter { seen.insert($0.bundlePath).inserted }
    }

    private func formatPlaceholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|lld|ld|d|u|f|\.\d+f)"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted()
    }
}

actor AttemptCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor RecordingNetworkTransport: ManagedNetworkTransport {
    struct Call: Sendable {
        let host: String?
        let method: String?
        let kind: NetworkRequestKind
        let timeout: TimeInterval
        let body: Data?
    }

    private(set) var calls: [Call] = []
    private let response: @Sendable (URLRequest, NetworkRequestKind) async throws -> (Data, URLResponse)

    init(response: @escaping @Sendable (URLRequest, NetworkRequestKind) async throws -> (Data, URLResponse)) {
        self.response = response
    }

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        calls.append(Call(
            host: request.url?.host,
            method: request.httpMethod,
            kind: kind,
            timeout: request.timeoutInterval,
            body: request.httpBody
        ))
        return try await response(request, kind)
    }

    nonisolated func finishTasksAndInvalidate() {}
}

private enum AuthForgetFixtureOutcome: Sendable {
    case success
    case business(String)
    case held(CommerceResponseGate)
    case timedOut
    case connectionLost
    case dnsFailure
    case tlsFailure
    case offline
    case cancelled
}

@MainActor
private struct AuthForgetFixture {
    let model: AppModel
    let transport: RecordingNetworkTransport

    init(outcome: AuthForgetFixtureOutcome) {
        let transport = RecordingNetworkTransport { request, kind in
            if kind == .writeRouteProbe {
                return (
                    Data(#"{"data":{}}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }

            if kind == .apiRead,
               request.url?.path.hasSuffix(V2BoardAPIClient.registrationConfigPath) == true {
                return (
                    Data(#"{"data":{"is_email_verify":1,"is_invite_force":0,"is_recaptcha":0}}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }

            switch outcome {
            case .success:
                return (
                    Data(#"{"data":true}"#.utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            case let .business(message):
                return (
                    try JSONSerialization.data(withJSONObject: ["message": message]),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            case let .held(gate):
                let response = await gate.receive()
                return (
                    Data(response.body.utf8),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: response.status,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            case .timedOut:
                throw URLError(.timedOut)
            case .connectionLost:
                throw URLError(.networkConnectionLost)
            case .dnsFailure:
                throw URLError(.dnsLookupFailed)
            case .tlsFailure:
                throw URLError(.secureConnectionFailed)
            case .offline:
                throw URLError(.notConnectedToInternet)
            case .cancelled:
                throw URLError(.cancelled)
            }
        }
        let router = APIRecoveryRouter(
            recoveryInitiallySuspendedForFormalVPN: false,
            writeTransportFactory: { transport }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        let config = AppConfig(
            appName: "Fixture",
            loginTitle: nil,
            appLogo: nil,
            homePage: nil,
            telegramGroup: nil,
            supportAPI: nil,
            updateURL: nil,
            userAgent: "NetworkClientTests/1",
            latencyDisplayRatio: 1,
            inviteLink: nil,
            apiBaseURLs: ["https://api.cloudflare.com"],
            activeAPIBaseURL: nil,
            builtInProxy: []
        )

        self.transport = transport
        model = AppModel(
            offline: false,
            apiHealthMonitor: APIHealthMonitor(
                transport: transport,
                observeNetwork: false
            ),
            initialConfig: config,
            recoveryRouter: router,
            apiClient: api
        )
    }

    var writeCount: Int {
        get async {
            await transport.calls.filter { $0.kind == .apiWrite }.count
        }
    }

    var loginWriteCount: Int {
        get async {
            await transport.calls.filter { $0.kind == .apiLogin }.count
        }
    }
}

final class NetworkTransportTests: XCTestCase {
    private func config(_ hosts: [String]) -> AppConfig {
        AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "NetworkClient-Offline-Test", latencyDisplayRatio: 1,
            inviteLink: nil, apiBaseURLs: hosts, activeAPIBaseURL: nil,
            builtInProxy: []
        )
    }

    func testInjectedAPIReadUsesTransportAndPreservesFailover() async throws {
        let transport = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .apiRead)
            if request.url?.host == "127.0.0.1" { throw URLError(.cannotConnectToHost) }
            return (Data(#"{"data":{"is_email_verify":1,"tos_url":" https://legal.example.invalid/terms "}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!)
        }
        let api = V2BoardAPIClient(recoveryRouter: APIRecoveryRouter(), transport: transport)
        let result = try await api.fetchRegistrationConfig(config: config([
            "https://127.0.0.1", "https://127.0.0.2"
        ]))
        XCTAssertTrue(result.requiresEmailVerification)
        XCTAssertEqual(result.termsOfServiceURL?.absoluteString, "https://legal.example.invalid/terms")
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.host), ["127.0.0.1", "127.0.0.2"])
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 25 && $0.method == "GET" })
    }

    func testRegistrationConfigOmitsMissingOrUnsafeTermsURL() async throws {
        for payload in [
            #"{"data":{}}"#,
            #"{"data":{"tos_url":null}}"#,
            #"{"data":{"tos_url":"http://legal.example.invalid/terms"}}"#,
            #"{"data":{"tos_url":"https://user:password@legal.example.invalid/terms"}}"#,
            #"{"data":{"tos_url":"not a URL"}}"#
        ] {
            let transport = RecordingNetworkTransport { request, _ in
                (Data(payload.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!)
            }
            let api = V2BoardAPIClient(
                recoveryRouter: APIRecoveryRouter(),
                transport: transport
            )
            let result = try await api.fetchRegistrationConfig(config: config([
                "https://127.0.0.1"
            ]))
            XCTAssertNil(result.termsOfServiceURL, "payload=\(payload)")
        }
    }

    func testBusinessRejectionDoesNotSwitchHost() async {
        let transport = RecordingNetworkTransport { request, _ in
            (Data(#"{"message":"Invalid input","data":false}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!)
        }
        let api = V2BoardAPIClient(recoveryRouter: APIRecoveryRouter(), transport: transport)
        do {
            _ = try await api.fetchRegistrationConfig(config: config([
                "https://127.0.0.1", "https://127.0.0.2"
            ]))
            XCTFail("Expected business rejection")
        } catch {}
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testInjectedNonIdempotentWriteSubmitsOnceAfterProbe() async {
        let transport = RecordingNetworkTransport { request, kind in
            if kind == .apiWrite { throw URLError(.timedOut) }
            return (Data(#"{"data":{}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!)
        }
        let router = APIRecoveryRouter(writeTransportFactory: { transport })
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        do {
            try await api.sendRegistrationEmailCode(
                config: config(["https://127.0.0.1", "https://127.0.0.2"]),
                email: "fixture@example.invalid"
            )
            XCTFail("Expected uncertain write failure")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "write_result_unknown")
        } catch { XCTFail("Unexpected error: \(type(of: error))") }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.kind == .apiWrite }.count, 1)
        XCTAssertEqual(calls.map(\.kind), [.writeRouteProbe, .apiWrite])
        XCTAssertEqual(calls.map(\.host), ["127.0.0.1", "127.0.0.1"])
    }

    func testWriteHTTP500IsUnknownAndNeverReplayed() async {
        let transport = RecordingNetworkTransport { request, kind in
            let body = kind == .apiWrite
                ? #"{"message":"temporary server failure","trace":"synthetic"}"#
                : #"{"data":{"is_email_verify":1}}"#
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: kind == .apiWrite ? 500 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let api = V2BoardAPIClient(
            recoveryRouter: APIRecoveryRouter(writeTransportFactory: { transport }),
            transport: transport
        )
        do {
            try await api.sendPasswordResetEmailCode(
                config: config(["https://127.0.0.1", "https://127.0.0.2"]),
                email: "fixture@example.invalid"
            )
            XCTFail("Expected unknown result")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "write_result_unknown")
        } catch { XCTFail("Unexpected error") }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.kind == .apiWrite }.count, 1)
    }

    func testAuthSafeMessageHTTP500IsDefiniteAndNeverReplayed() async {
        let message = "该邮箱不存在系统中"
        let transport = RecordingNetworkTransport { request, kind in
            let body = kind == .apiWrite
                ? try JSONSerialization.data(withJSONObject: ["message": message])
                : Data(#"{"data":{"is_email_verify":1}}"#.utf8)
            return (body, HTTPURLResponse(
                url: request.url!, statusCode: kind == .apiWrite ? 500 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let api = V2BoardAPIClient(
            recoveryRouter: APIRecoveryRouter(writeTransportFactory: { transport }),
            transport: transport
        )
        do {
            try await api.sendPasswordResetEmailCode(
                config: config(["https://127.0.0.1", "https://127.0.0.2"]),
                email: "fixture@example.invalid"
            )
            XCTFail("Expected definite Auth rejection")
        } catch let error as NetworkClientError {
            guard case let .authBusinessRejected(endpoint, actualMessage) = error else {
                return XCTFail("Unexpected Auth error: \(error)")
            }
            XCTAssertEqual(endpoint, .emailVerification)
            XCTAssertEqual(actualMessage, message)
            XCTAssertEqual(error.userFacingMessage, .verbatim(message))
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.kind == .apiWrite }.count, 1)
        XCTAssertEqual(calls.map(\.host), ["127.0.0.1", "127.0.0.1"])
    }

    func testLoginPOSTIsSubmittedOnlyOnceWhenResultIsUnknown() async {
        let transport = RecordingNetworkTransport { request, kind in
            if kind == .apiLogin { throw URLError(.timedOut) }
            return (
                Data(#"{"data":{"is_email_verify":1}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!
            )
        }
        let api = V2BoardAPIClient(
            recoveryRouter: APIRecoveryRouter(writeTransportFactory: { transport }),
            transport: transport
        )
        do {
            _ = try await api.login(
                config: config(["https://127.0.0.1", "https://127.0.0.2"]),
                email: "fixture@example.invalid", password: "synthetic-password"
            )
            XCTFail("Expected unknown login result")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "write_result_unknown")
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.kind == .apiLogin }.count, 1)
        XCTAssertEqual(calls.map(\.kind), [.writeRouteProbe, .apiLogin])
        XCTAssertEqual(calls.map(\.host), ["127.0.0.1", "127.0.0.1"])
    }

    func testWriteExplicitBusinessRejectionIsNotMisclassifiedOrReplayed() async {
        let transport = RecordingNetworkTransport { request, kind in
            let body = kind == .apiWrite
                ? #"{"message":"Invalid verification code","data":false}"#
                : #"{"data":{"is_email_verify":1}}"#
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: kind == .apiWrite ? 422 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let api = V2BoardAPIClient(
            recoveryRouter: APIRecoveryRouter(writeTransportFactory: { transport }),
            transport: transport
        )
        do {
            try await api.sendRegistrationEmailCode(
                config: config(["https://127.0.0.1", "https://127.0.0.2"]),
                email: "fixture@example.invalid"
            )
            XCTFail("Expected rejection")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "auth_email_verification_rejected")
            XCTAssertEqual(error.userFacingMessage, .verbatim("Invalid verification code"))
            XCTAssertFalse(error.retryable)
        } catch { XCTFail("Unexpected error") }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.kind == .apiWrite }.count, 1)
    }

    func testAPICancellationDoesNotFailOver() async {
        let transport = RecordingNetworkTransport { _, _ in throw URLError(.cancelled) }
        let api = V2BoardAPIClient(recoveryRouter: APIRecoveryRouter(), transport: transport)
        do {
            _ = try await api.fetchRegistrationConfig(config: config([
                "https://127.0.0.1", "https://127.0.0.2"
            ]))
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }
}

final class SessionPersistenceTests: XCTestCase {
    func testExistingSessionEnablesAutoLoginWhenPreferenceWasNotStoredByOlderBuild() async throws {
        let suite = "NetworkClient.compatibility.missing-preference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: "login.autoLoginEnabled"))

        let keychain = MemorySessionKeychain()
        let session = UserSession(
            email: "existing@example.invalid",
            authData: "isolated-existing-fixture",
            accountToken: nil,
            subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 1,
            downloadBytes: 2,
            transferEnableBytes: 100,
            expiredAt: 0,
            planID: nil,
            planName: "",
            balanceCents: nil,
            verifiedAt: Date()
        )
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(
            keychain.add(
                data,
                service: SessionStore.currentKeychainService,
                account: "v2board.authenticated-session"
            ),
            errSecSuccess
        )
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)

        let restored = try await store.read()

        XCTAssertEqual(restored, session)
        XCTAssertEqual(defaults.object(forKey: "login.autoLoginEnabled") as? Bool, true)
        let preserved = keychain.read(
            service: SessionStore.currentKeychainService,
            account: "v2board.authenticated-session"
        )
        XCTAssertEqual(preserved.status, errSecSuccess)
        XCTAssertEqual(preserved.data, data)
    }

    func testExistingInstalledSessionStillReadsWithoutNamespaceMigration() async throws {
        try await verifyExistingSession(service: SessionStore.currentKeychainService)
    }

    func testFreshInstallWithoutGenericSessionRemainsSignedOut() async throws {
        let suite = "NetworkClient.fresh-install.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MemorySessionKeychain()
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)

        let restored = try await store.read()
        XCTAssertNil(restored)
        XCTAssertEqual(
            keychain.read(
                service: SessionStore.currentKeychainService,
                account: "v2board.authenticated-session"
            ).status,
            errSecItemNotFound
        )
        XCTAssertFalse(defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
    }

    func testOldBrandedSessionIsNotReadAfterNamespaceFinalization() async throws {
        let suite = "NetworkClient.namespace-finalization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "login.autoLoginEnabled")
        let keychain = MemorySessionKeychain()
        let session = UserSession(
            email: "old@example.invalid", authData: "isolated-old-fixture",
            accountToken: nil, subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 1, downloadBytes: 2, transferEnableBytes: 100,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder().encode(session)
        let account = "v2board.authenticated-session"
        let oldServices = [
            "org.example.legacy.networkclient.auth-session.v1",
            "org.example.legacy.networkclient.unused"
        ]
        for service in oldServices {
            XCTAssertEqual(keychain.add(data, service: service, account: account), errSecSuccess)
        }

        let restored = try await SessionStore(
            keychain: keychain,
            defaultsSuiteName: suite
        ).read()

        XCTAssertNil(restored)
        XCTAssertEqual(
            keychain.read(service: SessionStore.currentKeychainService, account: account).status,
            errSecItemNotFound
        )
        for service in oldServices {
            let retained = keychain.read(service: service, account: account)
            XCTAssertEqual(retained.status, errSecSuccess)
            XCTAssertEqual(retained.data, data)
        }
    }

    func testFullVPNInstallationDoesNotReadOldMockSession() async throws {
        let suite = "NetworkClient.identity-isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "login.autoLoginEnabled")
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let productionService = "com.networkclient.ios.auth-session.v1"
        let vpnTestService = bundleID + ".auth-session.v1"
        let account = "v2board.authenticated-session"
        XCTAssertEqual(SessionStore.currentKeychainService, productionService)
        XCTAssertNotEqual(productionService, vpnTestService)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appendingPathComponent("NetworkClient-iOS.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        for id in [
            "E9B2E96ABC5F6856F2BE79CF", "5A8C91857F674E16E2724F47",
            "A0B210000000000000000001", "A0B210000000000000000002",
            "A0B210000000000000000003", "A0B210000000000000000004"
        ] {
            XCTAssertFalse(
                try projectConfigurationBlock(id, in: project)
                    .contains("NETWORKCLIENT_VPN_TEST"),
                "formal NetworkClient configuration \(id) must not enable VPNTest semantics"
            )
        }
        for id in [
            "31C496D7538F1758AEDA3E7C", "1D55C4D049A7162A51086688",
            "A0B240000000000000000001", "A0B240000000000000000002",
            "A0B240000000000000000003", "A0B240000000000000000004"
        ] {
            XCTAssertTrue(
                try projectConfigurationBlock(id, in: project)
                    .contains("NETWORKCLIENT_VPN_TEST"),
                "NetworkClientVPNTest configuration \(id) must retain isolated semantics"
            )
        }
        let sessionStoreSource = try String(
            contentsOf: root.appendingPathComponent("iOSAdapters/SessionStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sessionStoreSource.contains(
            "static let currentKeychainService = (Bundle.main.bundleIdentifier ?? \"NetworkClientVPNTest\") + \".auth-session.v1\""
        ))
        XCTAssertFalse(sessionStoreSource.contains("legacyKeychainService"))
        XCTAssertFalse(sessionStoreSource.contains("legacy-unused"))

        let keychain = MemorySessionKeychain()
        let session = UserSession(
            email: "existing@example.invalid", authData: "isolated-existing-fixture",
            accountToken: nil, subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 0,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil, verifiedAt: Date()
        )
        let oldData = try JSONEncoder().encode(session)
        XCTAssertEqual(keychain.add(
            oldData, service: vpnTestService, account: account
        ), errSecSuccess)
        XCTAssertEqual(keychain.add(
            oldData, service: SessionStore.currentKeychainService, account: "unrelated-account"
        ), errSecSuccess)
        let restored = try await SessionStore(keychain: keychain, defaultsSuiteName: suite).read()
        XCTAssertNil(restored, "VPN identity must ignore the old mock session")

        let vpnSession = UserSession(
            email: "vpn@example.invalid", authData: "isolated-vpn-fixture",
            accountToken: nil, subscriptionURL: "https://example.invalid/vpn-sub",
            uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 0,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil, verifiedAt: Date()
        )
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)
        let firstGeneration = UUID()
        let firstReplaced = try await store.replace(
            vpnSession,
            generation: firstGeneration,
            replacing: nil
        )
        XCTAssertTrue(firstReplaced)
        let currentItem = keychain.read(service: SessionStore.currentKeychainService, account: account)
        XCTAssertEqual(try JSONDecoder().decode(UserSession.self, from: XCTUnwrap(currentItem.data)), vpnSession)
        let vpnRestored = try await SessionStore(keychain: keychain, defaultsSuiteName: suite).read()
        XCTAssertEqual(vpnRestored, vpnSession)

        let firstCleared = try await store.clearForSignOut(ifCurrent: firstGeneration)
        XCTAssertTrue(firstCleared)
        XCTAssertFalse(defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
        XCTAssertFalse(defaults.bool(forKey: vpnTestService + ".session.explicitly-signed-out"))
        let signedOut = try await SessionStore(keychain: keychain, defaultsSuiteName: suite).read()
        XCTAssertNil(signedOut)
        let secondGeneration = UUID()
        let secondReplaced = try await store.replace(
            vpnSession,
            generation: secondGeneration,
            replacing: nil
        )
        XCTAssertTrue(secondReplaced)
        let signedInAgain = try await SessionStore(keychain: keychain, defaultsSuiteName: suite).read()
        XCTAssertEqual(signedInAgain, vpnSession)
        XCTAssertFalse(defaults.bool(forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"))
        XCTAssertEqual(keychain.read(service: vpnTestService, account: account).data, oldData)
    }
    private func projectConfigurationBlock(_ id: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "\t\t\(id) /*")?.lowerBound)
        let end = try XCTUnwrap(
            source.range(of: "\n\t\t};", range: start..<source.endIndex)?.upperBound
        )
        return String(source[start..<end])
    }
    private func verifyExistingSession(service: String) async throws {
        let suite = "NetworkClient.compatibility.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "login.autoLoginEnabled")
        let keychain = MemorySessionKeychain()
        let session = UserSession(email: "existing@example.invalid", authData: "isolated-existing-fixture", accountToken: nil,
            subscriptionURL: "https://example.invalid/sub", uploadBytes: 1, downloadBytes: 2, transferEnableBytes: 100,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil, verifiedAt: Date())
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(keychain.add(data, service: service, account: "v2board.authenticated-session"), errSecSuccess)
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)
        let restored = try await store.read()
        XCTAssertEqual(restored, session)
        XCTAssertTrue(defaults.bool(forKey: "login.autoLoginEnabled"))
        let persisted = keychain.read(service: SessionStore.currentKeychainService, account: "v2board.authenticated-session")
        XCTAssertEqual(persisted.status, errSecSuccess)
        XCTAssertEqual(try JSONDecoder().decode(UserSession.self, from: XCTUnwrap(persisted.data)), session)
    }
    func testKeychainSessionUsesIndependentNamespaceAndSignOutMarker() async throws {
        let suite = "NetworkClient.tests.\(UUID().uuidString)"
        let keychain = MemorySessionKeychain()
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let session = UserSession(email: "fixture@example.invalid", authData: "fixture-not-a-token", accountToken: nil,
            subscriptionURL: "https://example.invalid/sub", uploadBytes: 1, downloadBytes: 2, transferEnableBytes: 100,
            expiredAt: 0, planID: nil, planName: "", balanceCents: nil, verifiedAt: Date())
        try await store.setAutoLoginEnabled(true)
        let generation = UUID()
        let replaced = try await store.replace(session, generation: generation, replacing: nil)
        XCTAssertTrue(replaced)
        let restored = try await store.read()
        XCTAssertEqual(restored, session)
        XCTAssertTrue(SessionStore.currentKeychainService.contains("ios"))
        XCTAssertFalse(SessionStore.currentKeychainService.contains("macos"))
        let clearedCurrent = try await store.clearForSignOut(ifCurrent: generation)
        XCTAssertTrue(clearedCurrent)
        let cleared = try await store.read(); XCTAssertNil(cleared)
    }
}

final class SessionPersistenceIsolationTests: XCTestCase {
    func testStaleSaveResumingAfterNewAccountCannotOverwritePersistedSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = session("A")
        let b = session("B")
        let aGeneration = UUID()
        let bGeneration = UUID()
        let replacedA = try await fixture.store.replace(a, generation: aGeneration, replacing: nil)
        XCTAssertTrue(replacedA)

        let gate = SessionPersistencePauseGate()
        let store = fixture.store
        let stale = Task {
            await gate.pause()
            return try await store.save(
                a.applyingUserInfo(email: nil, balanceCents: 999),
                ifCurrent: aGeneration
            )
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replacedB = try await fixture.store.replace(
            b,
            generation: bGeneration,
            replacing: aGeneration
        )
        XCTAssertTrue(replacedB)
        await gate.resume()

        let staleApplied = try await stale.value
        let persisted = try await fixture.store.read()
        XCTAssertFalse(staleApplied)
        XCTAssertEqual(persisted, b)
    }

    func testStaleClearResumingAfterNewAccountCannotRemovePersistedSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = session("A")
        let b = session("B")
        let aGeneration = UUID()
        let bGeneration = UUID()
        let replacedA = try await fixture.store.replace(a, generation: aGeneration, replacing: nil)
        XCTAssertTrue(replacedA)

        let gate = SessionPersistencePauseGate()
        let store = fixture.store
        let stale = Task {
            await gate.pause()
            return try await store.clearForSignOut(ifCurrent: aGeneration)
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replacedB = try await fixture.store.replace(
            b,
            generation: bGeneration,
            replacing: aGeneration
        )
        XCTAssertTrue(replacedB)
        await gate.resume()

        let staleApplied = try await stale.value
        let persisted = try await fixture.store.read()
        XCTAssertFalse(staleApplied)
        XCTAssertEqual(persisted, b)
    }

    func testSameAccountNewGenerationRejectsOldSaveAndClear() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let first = session("A")
        let second = first.applyingUserInfo(email: nil, balanceCents: 200)
        let firstGeneration = UUID()
        let secondGeneration = UUID()
        let firstReplaced = try await fixture.store.replace(
            first,
            generation: firstGeneration,
            replacing: nil
        )
        XCTAssertTrue(firstReplaced)
        let secondReplaced = try await fixture.store.replace(
            second,
            generation: secondGeneration,
            replacing: firstGeneration
        )
        XCTAssertTrue(secondReplaced)

        let oldSaved = try await fixture.store.save(first, ifCurrent: firstGeneration)
        let oldCleared = try await fixture.store.clearForSignOut(ifCurrent: firstGeneration)
        let persisted = try await fixture.store.read()
        XCTAssertFalse(oldSaved)
        XCTAssertFalse(oldCleared)
        XCTAssertEqual(persisted, second)
    }

    func testCurrentGenerationClearRemovesPersistedSessionAndClearsSuccessfulSignOutMarker() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let b = session("B")
        let generation = UUID()
        let replaced = try await fixture.store.replace(b, generation: generation, replacing: nil)
        XCTAssertTrue(replaced)

        let cleared = try await fixture.store.clearForSignOut(ifCurrent: generation)
        let persisted = try await fixture.store.read()
        XCTAssertTrue(cleared)
        XCTAssertNil(persisted)
        XCTAssertEqual(
            fixture.keychain.read(
                service: SessionStore.currentKeychainService,
                account: "v2board.authenticated-session"
            ).status,
            errSecItemNotFound
        )
        XCTAssertFalse(fixture.defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
    }

    func testCredentialInvalidationRejectsStaleGeneration() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let generation = UUID()
        let replaced = try await fixture.store.replace(
            session("A"), generation: generation, replacing: nil
        )
        XCTAssertTrue(replaced)

        let result = await fixture.store.invalidateAfterCredentialChange(
            ifCurrent: UUID()
        )

        XCTAssertEqual(result, .stale)
        let persisted = try await fixture.store.read()
        XCTAssertEqual(persisted, session("A"))
    }

    func testCredentialInvalidationClearsUnneededTombstoneWhenStorageDeletionSucceeds() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let generation = UUID()
        let replaced = try await fixture.store.replace(
            session("A"), generation: generation, replacing: nil
        )
        XCTAssertTrue(replaced)

        let result = await fixture.store.invalidateAfterCredentialChange(
            ifCurrent: generation
        )

        XCTAssertEqual(result, .invalidated(storageCleared: true))
        let persisted = try await fixture.store.read()
        XCTAssertNil(persisted)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
    }

    func testCredentialInvalidationTombstonesRetainedKeychainAndAllowsNewLogin() async throws {
        let suite = "NetworkClient.credential-invalidation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = SignOutFailingSessionKeychain()
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)
        try await store.setAutoLoginEnabled(true)
        let oldSession = session("A")
        let oldGeneration = UUID()
        let oldReplaced = try await store.replace(
            oldSession, generation: oldGeneration, replacing: nil
        )
        XCTAssertTrue(oldReplaced)
        keychain.beginFailingDeletes()

        let result = await store.invalidateAfterCredentialChange(
            ifCurrent: oldGeneration
        )

        XCTAssertEqual(result, .invalidated(storageCleared: false))
        XCTAssertTrue(defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
        let currentRead = try await store.read()
        XCTAssertNil(currentRead)
        let relaunchedStore = SessionStore(
            keychain: keychain,
            defaultsSuiteName: suite
        )
        let relaunchedRead = try await relaunchedStore.read()
        XCTAssertNil(relaunchedRead, "A relaunch must not restore the revoked server session")

        let newSession = session("B")
        let newGeneration = UUID()
        let newReplaced = try await store.replace(
            newSession, generation: newGeneration, replacing: nil
        )
        XCTAssertTrue(newReplaced)
        let signedInAgain = try await store.read()
        XCTAssertEqual(signedInAgain, newSession)
        XCTAssertFalse(defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
        let relaunchedAfterNewLogin = SessionStore(
            keychain: keychain,
            defaultsSuiteName: suite
        )
        let restoredNewSession = try await relaunchedAfterNewLogin.read()
        XCTAssertEqual(
            restoredNewSession,
            newSession,
            "A valid new login must remain restorable after relaunch"
        )
    }

    private func makeFixture() async throws -> SessionPersistenceIsolationFixture {
        let suite = "NetworkClient.session-persistence-isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keychain = MemorySessionKeychain()
        let store = SessionStore(keychain: keychain, defaultsSuiteName: suite)
        try await store.setAutoLoginEnabled(true)
        return SessionPersistenceIsolationFixture(
            store: store,
            keychain: keychain,
            defaults: defaults,
            suite: suite
        )
    }

    private func session(_ account: String) -> UserSession {
        UserSession(
            email: "\(account)@example.invalid",
            authData: "synthetic-\(account)",
            accountToken: nil,
            subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 1,
            downloadBytes: 2,
            transferEnableBytes: 100,
            expiredAt: 0,
            planID: 1,
            planName: "Fixture",
            balanceCents: 100,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private struct SessionPersistenceIsolationFixture {
    let store: SessionStore
    let keychain: MemorySessionKeychain
    let defaults: UserDefaults
    let suite: String
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private actor SessionPersistencePauseGate {
    let entered = XCTestExpectation(description: "stale persistence operation paused")
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

final class MemorySessionKeychain: SessionKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private func key(_ service: String, _ account: String) -> String { service + ":" + account }
    func read(service: String, account: String) -> SessionKeychainReadResult {
        lock.withLock {
            let data = items[key(service, account)]
            return SessionKeychainReadResult(status: data == nil ? errSecItemNotFound : errSecSuccess, data: data)
        }
    }
    func update(_ data: Data, service: String, account: String) -> OSStatus {
        lock.withLock {
            let id = key(service, account)
            guard items[id] != nil else { return errSecItemNotFound }
            items[id] = data; return errSecSuccess
        }
    }
    func add(_ data: Data, service: String, account: String) -> OSStatus {
        lock.withLock { items[key(service, account)] = data; return errSecSuccess }
    }
    func delete(service: String, account: String) -> OSStatus {
        lock.withLock { items.removeValue(forKey: key(service, account)); return errSecSuccess }
    }
    func invalidate(service: String, account: String) -> OSStatus { update(Data(), service: service, account: account) }
}

private final class SignOutFailingSessionKeychain: SessionKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let storage = MemorySessionKeychain()
    private var failsDeletes = false

    func beginFailingDeletes() {
        lock.withLock { failsDeletes = true }
    }

    func read(service: String, account: String) -> SessionKeychainReadResult {
        storage.read(service: service, account: account)
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        storage.update(data, service: service, account: account)
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        storage.add(data, service: service, account: account)
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            failsDeletes
                ? errSecAuthFailed
                : storage.delete(service: service, account: account)
        }
    }

    func invalidate(service: String, account: String) -> OSStatus {
        lock.withLock {
            failsDeletes
                ? errSecAuthFailed
                : storage.invalidate(service: service, account: account)
        }
    }
}

@MainActor
final class AuthenticatedBootstrapTests: XCTestCase {
    func testColdStartConnectJoinsAuthenticatedSubscriptionRefreshWithoutDuplicateDownload() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.nodes.setSuspendRefresh(true)
        let bootstrap = Task {
            await context.model.establishAuthenticatedSession(session(), source: .restored)
        }
        for _ in 0..<1_000 {
            if await context.nodes.refreshCount() == 1 { break }
            await Task.yield()
        }
        let startedRefreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(startedRefreshCount, 1)
        XCTAssertEqual(context.model.nodesLoadState, .loading)
        let request = Task { try await context.model.tunnelRequest(mode: .global) }
        await context.nodes.resumeRefresh()
        let ready = try await request.value
        await bootstrap.value
        XCTAssertEqual(ready.nodeID, context.model.nodes.selectedNodeID)
        let completedRefreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(completedRefreshCount, 1)
    }

    func testPowerAndForegroundDoNotRefreshSubscriptionOrEraseMeasuredLatency() async throws {
        let prober = RecordingNodeHTTPProber()
        let context = try await makeContext(nodeProber: prober, nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(id)
        let measured = context.model.nodeLatencies[id]
        XCTAssertNotNil(measured)

        // A normal foreground visit, even after the old ten-minute node TTL,
        // refreshes business data without downloading a new subscription.
        context.model.setNodeRefreshDateForTesting(.distantPast)
        await context.model.refreshAuthenticatedDataIfNeeded()
        let request = try await context.model.tunnelRequest(mode: .global)
        XCTAssertEqual(request.nodeID, id)
        XCTAssertEqual(context.model.nodeLatencies[id], measured)
        let downloads = await context.nodes.refreshCount()
        XCTAssertEqual(downloads, 1)
    }

    func testConfigurationMappingDoesNotRepeatSubscriptionDownload() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let before = await context.fetcher.fetchCount()
        let request = try await context.model.tunnelRequest(mode: .global)
        let configuration = try await context.model.selectedMihomoTunnelConfiguration(for: request)
        XCTAssertEqual(configuration.configurationRevision, request.configurationRevision)
        let after = await context.fetcher.fetchCount()
        XCTAssertEqual(after, before)
    }

    func testCancelBatchKeepsCompletedReadingsAndDropsLateResult() async throws {
        let prober = RecordingNodeHTTPProber(pauseCallNumber: 2)
        let context = try await makeContext(
            nodeProber: prober, nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let ids = context.model.nodes.nodes.map(\.id)
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<1_000 {
            if await prober.calls().count == 2 { break }
            await Task.yield()
        }
        let startedCalls = await prober.calls().count
        XCTAssertEqual(startedCalls, 2)
        context.model.cancelAllNodeLatencies()
        XCTAssertEqual(context.model.nodeLatencies[ids[0]], .measured(NodeLatencyReading(
            actualMilliseconds: 42, displayRatio: 1
        )!))
        XCTAssertNil(context.model.nodeLatencies[ids[1]])
        await prober.resumeFirst()
        await batch.value
        XCTAssertNil(context.model.nodeLatencies[ids[1]])
        XCTAssertFalse(context.model.testingAllNodes)
    }

    func testCancellingRetestRestoresPreviousReading() async throws {
        let prober = RecordingNodeHTTPProber(pauseCallNumber: 2)
        let context = try await makeContext(nodeProber: prober, nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(id)
        let previous = context.model.nodeLatencies[id]
        let retest = Task { await context.model.testNodeLatency(id) }
        for _ in 0..<1_000 {
            if await prober.calls().count == 2 { break }
            await Task.yield()
        }
        let startedCalls = await prober.calls().count
        XCTAssertEqual(startedCalls, 2)
        context.model.cancelAllNodeLatencies()
        XCTAssertEqual(context.model.nodeLatencies[id], previous)
        await prober.resumeFirst()
        await retest.value
        XCTAssertEqual(context.model.nodeLatencies[id], previous)
    }

    func testAccountChangeClearsLatencyBeforeNewSubscriptionCompletes() async throws {
        let context = try await makeContext(nodeProber: RecordingNodeHTTPProber(), nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let oldID = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(oldID)
        XCTAssertNotNil(context.model.nodeLatencies[oldID])
        await context.nodes.setSuspendRefresh(true)
        let newSession = Task {
            await context.model.establishAuthenticatedSession(
                session(email: "different@example.invalid"), source: .login
            )
        }
        for _ in 0..<1_000 {
            if context.model.session?.email == "different@example.invalid" { break }
            await Task.yield()
        }
        XCTAssertNil(context.model.nodeLatencies[oldID])
        XCTAssertNil(context.model.nodes.selectedNodeID)
        await context.nodes.resumeRefresh()
        await newSession.value
        XCTAssertNotEqual(context.model.nodes.selectedNodeID, oldID)
    }

    func testOnlyPhysicalNetworkChangeInvalidatesLatency() async throws {
        let context = try await makeContext(nodeProber: RecordingNodeHTTPProber(), nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let wifi = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.wifi])
        let sameLinkDifferentRoute = APIHealthNetworkPath(
            status: .satisfied, usedInterfaceTypes: [.wifi], isExpensive: true
        )
        let cellular = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.cellular])
        context.model.observeLatencyNetworkPath(wifi)
        await context.model.testNodeLatency(id)
        let measured = context.model.nodeLatencies[id]
        context.model.observeLatencyNetworkPath(wifi)
        context.model.observeLatencyNetworkPath(sameLinkDifferentRoute)
        let sameLinkDifferentAvailableInterface = APIHealthNetworkPath(
            status: .satisfied, usedInterfaceTypes: [.wifi],
            usedInterfaceIdentifiers: ["wifi:en0:4"]
        )
        context.model.observeLatencyNetworkPath(sameLinkDifferentAvailableInterface)
        XCTAssertEqual(context.model.nodeLatencies[id], measured)
        // The tunnel's path notification can precede the VPN-state callback.
        let tunnelOnly = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.other])
        context.model.observeLatencyNetworkPath(tunnelOnly)
        context.model.observeLatencyNetworkPath(APIHealthNetworkPath(status: .unsatisfied))
        XCTAssertEqual(context.model.nodeLatencies[id], measured)
        context.model.observeLatencyNetworkPath(tunnelOnly)
        XCTAssertEqual(context.model.nodeLatencies[id], measured)
        context.model.observeLatencyNetworkPath(cellular)
        XCTAssertNil(context.model.nodeLatencies[id])
        let downloads = await context.nodes.refreshCount()
        XCTAssertEqual(downloads, 1)
    }

    func testDisplayOnlyNodeFailsClosedOnRefreshErrorAndRecoversOnRetry() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        await context.nodes.dropParsedSubscriptionKeepingSnapshot()
        await context.nodes.setMode(.parseFailure)
        do {
            _ = try await context.model.tunnelRequest(mode: .global)
            XCTFail("A display-only node must not start VPN or download implicitly")
        } catch let error as VPNConnectionPreflightError {
            XCTAssertEqual(error, .selectedNodeMissing)
        }
        let countBeforeManual = await context.nodes.refreshCount()
        XCTAssertEqual(countBeforeManual, 1)
        await context.model.refreshNodes()
        XCTAssertNotNil(context.model.nodesLoadState.failureMessage)
        await context.nodes.setMode(.loaded)
        await context.model.refreshNodes()
        let retried = try await context.model.tunnelRequest(mode: .global)
        XCTAssertEqual(retried.nodeID, context.model.nodes.selectedNodeID)
        let refreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(refreshCount, 3)
    }

    func testRemovedNodeCannotConnectFromDisplayedPreviousSelection() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        await context.nodes.dropParsedSubscriptionKeepingSnapshot()
        await context.nodes.setMode(.empty)
        do {
            _ = try await context.model.tunnelRequest(mode: .global)
            XCTFail("Removed node must not be authorized by its old visible card")
        } catch let error as VPNConnectionPreflightError {
            XCTAssertEqual(error, .selectedNodeMissing)
        }
        let countBeforeManual = await context.nodes.refreshCount()
        XCTAssertEqual(countBeforeManual, 1)
        await context.model.refreshNodes()
        XCTAssertNil(context.model.nodes.selectedNodeID)
        let refreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(refreshCount, 2)
    }

    func testCancelledNodePreparationNeverProducesATunnelRequest() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.nodes.setSuspendRefresh(true)
        let bootstrap = Task {
            await context.model.establishAuthenticatedSession(session(), source: .restored)
        }
        for _ in 0..<1_000 {
            if await context.nodes.refreshCount() == 1 { break }
            await Task.yield()
        }
        let request = Task { try await context.model.tunnelRequest(mode: .global) }
        request.cancel()
        await context.nodes.resumeRefresh()
        do {
            _ = try await request.value
            XCTFail("A cancelled preparation must not hand a cancelled request to the controller")
        } catch is CancellationError { }
        await bootstrap.value
        let refreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testExplicitLoginSessionAutomaticallyInitializesFourDataSets() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }

        await context.model.establishAuthenticatedSession(
            session(email: "login@example.invalid"),
            source: .login
        )

        XCTAssertEqual(context.model.accountLoadState, .loaded)
        XCTAssertEqual(context.model.plansLoadState, .loaded)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertEqual(context.model.noticesLoadState, .loaded)
        XCTAssertEqual(context.model.plans.map(\.id), [1])
        XCTAssertEqual(context.model.nodes.nodes.count, 1)
        XCTAssertEqual(context.model.notices.map(\.id), [1])
        let counts = await context.business.counts()
        let nodeRefreshes = await context.nodes.refreshCount()
        XCTAssertEqual(counts, .init(account: 1, plans: 1, notices: 1))
        XCTAssertEqual(nodeRefreshes, 1)
    }

    func testValidRestoredSessionAutomaticallyInitializesFourDataSets() async throws {
        let suite = "NetworkClient.bootstrap.restore.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let store = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        let saved = session(email: "restored@example.invalid")
        try await store.setAutoLoginEnabled(true)
        let savedReplaced = try await store.replace(saved, generation: UUID(), replacing: nil)
        XCTAssertTrue(savedReplaced)
        let business = BootstrapBusinessAPI()
        let nodes = BootstrapNodeRepository()
        let verifier = BootstrapSessionVerifier()
        let probeTransport = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .apiProbe)
            return (Data(#"{"data":{"is_email_verify":1}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!)
        }
        let healthMonitor = APIHealthMonitor(transport: probeTransport, observeNetwork: false)
        let model = AppModel(
            offline: false,
            businessDataAPI: business,
            sessionVerifier: verifier,
            nodeRepository: nodes,
            apiHealthMonitor: healthMonitor,
            sessionStore: store,
            initialConfig: config(apiBaseURLs: ["https://127.0.0.1"])
        )

        await model.start()
        await healthMonitor.waitForCurrentProbe()
        await model.setAPIHealthForeground(true)
        await healthMonitor.waitForCurrentProbe()

        XCTAssertEqual(model.session?.email, saved.email)
        let verificationCalls = await verifier.callCount()
        let counts = await business.counts()
        let nodeRefreshes = await nodes.refreshCount()
        XCTAssertEqual(verificationCalls, 1)
        XCTAssertEqual(counts, .init(account: 1, plans: 1, notices: 1))
        XCTAssertEqual(nodeRefreshes, 1)
        let probes = await probeTransport.calls
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual([model.accountLoadState, model.plansLoadState, model.nodesLoadState, model.noticesLoadState], [.loaded, .loaded, .loaded, .loaded])
    }

    func testStoredSessionWaitsForConfigurationAndResumesAfterRetry() async throws {
        let suite = "NetworkClient.bootstrap.config-unavailable.\(UUID().uuidString)"
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            removeDefaults(suite)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let store = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        let saved = session(email: "deferred@example.invalid")
        try await store.setAutoLoginEnabled(true)
        let didStoreSession = try await store.replace(saved, generation: UUID(), replacing: nil)
        XCTAssertTrue(didStoreSession)

        let transport = RecoveringConfigTransport()
        let business = BootstrapBusinessAPI()
        let nodes = BootstrapNodeRepository()
        let verifier = BootstrapSessionVerifier()
        let service = RemoteConfigService(
            cacheRoot: cacheRoot,
            installationID: "deferred-session-test",
            networkTransport: transport
        )
        let model = AppModel(
            offline: false,
            businessDataAPI: business,
            sessionVerifier: verifier,
            nodeRepository: nodes,
            apiHealthMonitor: offlineHealthMonitor(),
            remoteConfigService: service,
            sessionStore: store
        )

        await model.start()

        XCTAssertNil(model.config)
        XCTAssertNil(model.session)
        XCTAssertEqual(model.configurationStatus.source, .unavailable)
        let storedAfterStart = try await store.read()
        let verificationCallsAfterStart = await verifier.callCount()
        let businessCallsAfterStart = await business.counts()
        let nodeRefreshesAfterStart = await nodes.refreshCount()
        XCTAssertEqual(storedAfterStart?.email, saved.email)
        XCTAssertEqual(verificationCallsAfterStart, 0)
        XCTAssertEqual(businessCallsAfterStart, .init(account: 0, plans: 0, notices: 0))
        XCTAssertEqual(nodeRefreshesAfterStart, 0)
        do {
            _ = try await model.tunnelRequest(mode: .rule)
            XCTFail("A new VPN request must be blocked without configuration")
        } catch let error as NetworkClientError {
            guard case .configUnavailable = error else {
                return XCTFail("Expected the configuration gate")
            }
        }

        await model.reloadConfiguration()
        XCTAssertNil(model.config)
        XCTAssertNil(model.session)
        XCTAssertEqual(model.configurationStatus.source, .unavailable)
        let storedAfterFailedRetry = try await store.read()
        let verificationCallsAfterFailedRetry = await verifier.callCount()
        let businessCallsAfterFailedRetry = await business.counts()
        let nodeRefreshesAfterFailedRetry = await nodes.refreshCount()
        XCTAssertEqual(storedAfterFailedRetry?.email, saved.email)
        XCTAssertEqual(verificationCallsAfterFailedRetry, 0)
        XCTAssertEqual(businessCallsAfterFailedRetry, .init(account: 0, plans: 0, notices: 0))
        XCTAssertEqual(nodeRefreshesAfterFailedRetry, 0)

        await transport.succeed(with: config(apiBaseURLs: ["https://api.fixture.invalid"]))
        await model.reloadConfiguration()

        XCTAssertEqual(model.configurationStatus.source, .remote)
        XCTAssertEqual(model.session?.email, saved.email)
        let verificationCallsAfterRecovery = await verifier.callCount()
        let businessCallsAfterRecovery = await business.counts()
        let nodeRefreshesAfterRecovery = await nodes.refreshCount()
        XCTAssertEqual(verificationCallsAfterRecovery, 1)
        XCTAssertEqual(businessCallsAfterRecovery, .init(account: 1, plans: 1, notices: 1))
        XCTAssertEqual(nodeRefreshesAfterRecovery, 1)
    }

    func testPlanFailureDoesNotBlockOtherAuthenticatedData() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.business.setPlanMode(.failure)

        await context.model.establishAuthenticatedSession(session(), source: .login)

        XCTAssertEqual(context.model.accountLoadState, .loaded)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertEqual(context.model.noticesLoadState, .loaded)
        guard case .failed = context.model.plansLoadState else {
            return XCTFail("套餐错误应独立呈现")
        }
    }

    func testPlanSuccessEmptyFailureAndCachedStaleStates() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        XCTAssertEqual(context.model.plansLoadState, .loaded)

        await context.business.setPlanMode(.failure)
        await context.model.refreshPlans()
        XCTAssertEqual(context.model.plans.map(\.id), [1])
        guard case .stale = context.model.plansLoadState else {
            return XCTFail("刷新失败时应保留已验证套餐缓存")
        }

        let emptyContext = try await makeContext()
        defer { removeDefaults(emptyContext.suite) }
        await emptyContext.business.setPlanMode(.empty)
        await emptyContext.model.establishAuthenticatedSession(session(email: "empty@example.invalid"), source: .login)
        XCTAssertTrue(emptyContext.model.plans.isEmpty)
        XCTAssertEqual(emptyContext.model.plansLoadState, .empty)
    }

    func testNodeAutomaticLoadEmptyParseFailureAndManualRefresh() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.nodes.setMode(.empty)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        XCTAssertEqual(context.model.nodesLoadState, .empty)

        await context.nodes.setMode(.loaded)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertEqual(context.model.nodes.nodes.count, 1)

        await context.nodes.setMode(.parseFailure)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.nodes.count, 1)
        XCTAssertEqual(context.model.nodesLoadState, .stale(.localized("nodes.error.invalid_format")))
        let refreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(refreshCount, 3)
    }

    func testProductionNodeRefreshStagesBeforeCommitAndKeepsLastValidSnapshot() async throws {
        let suite = "NetworkClient.NodeRefresh.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let fetcher = StagedSubscriptionFetcher()
        let repository = NodeRepository(
            subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: fetcher,
            selectionStore: NodeSelectionStore(suiteName: suite)
        )
        let account = session()
        let initial = try await repository.prepareRefresh(config: config(), session: account)
        let beforeCommit = await repository.snapshot()
        XCTAssertTrue(beforeCommit.nodes.isEmpty)
        let committed = try await repository.commitRefresh(initial)
        XCTAssertEqual(committed.nodes.count, 1)
        let firstID = try XCTUnwrap(committed.nodes.first?.id)
        _ = try await repository.selectNode(id: firstID, session: account)

        await fetcher.setYAML("proxies: []")
        do {
            _ = try await repository.prepareRefresh(config: config(), session: account)
            XCTFail("An empty replacement must not erase a verified subscription")
        } catch SubscriptionParserError.noValidNodes {}
        let afterEmptyReplacement = await repository.snapshot()
        XCTAssertEqual(afterEmptyReplacement.selectedNodeID, firstID)

        await fetcher.setYAML("""
        proxies:
          - name: Fixture Node
            type: ss
            server: 198.51.100.20
            port: 443
            cipher: aes-128-gcm
            password: changed-fixture
        """)
        let changed = try await repository.prepareRefresh(config: config(), session: account)
        XCTAssertEqual(changed.snapshot.selectedNodeID, firstID)
        let beforeChangedCommit = await repository.snapshot()
        XCTAssertEqual(beforeChangedCommit.nodes.first?.server, "198.51.100.10")
        _ = try await repository.commitRefresh(changed)
        let afterChangedCommit = await repository.snapshot()
        XCTAssertEqual(afterChangedCommit.nodes.first?.server, "198.51.100.20")

        let stale = try await repository.prepareRefresh(config: config(), session: account)
        _ = try await repository.prepareRefresh(config: config(), session: account)
        do {
            _ = try await repository.commitRefresh(stale)
            XCTFail("An older preparation must not replace a newer generation")
        } catch is CancellationError {}
    }

    func testSelectionDuringStagedRefreshInvalidatesOlderCommit() async throws {
        let suite = "NetworkClient.NodeSelectionRace.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let fetcher = StagedSubscriptionFetcher()
        await fetcher.setYAML("""
        proxies:
          - name: First Fixture
            type: ss
            server: 198.51.100.10
            port: 443
            cipher: aes-128-gcm
            password: first-fixture
          - name: Second Fixture
            type: ss
            server: 198.51.100.20
            port: 443
            cipher: aes-128-gcm
            password: second-fixture
        """)
        let repository = NodeRepository(
            subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: fetcher,
            selectionStore: NodeSelectionStore(suiteName: suite)
        )
        let account = session()
        let initial = try await repository.refresh(config: config(), session: account)
        let first = try XCTUnwrap(initial.nodes.first?.id)
        let second = try XCTUnwrap(initial.nodes.last?.id)
        _ = try await repository.selectNode(id: first, session: account)
        let staged = try await repository.prepareRefresh(config: config(), session: account)
        _ = try await repository.selectNode(id: second, session: account)
        do {
            _ = try await repository.commitRefresh(staged)
            XCTFail("A newer node choice must supersede the prepared refresh")
        } catch is CancellationError {}
        let finalSelection = await repository.snapshot().selectedNodeID
        XCTAssertEqual(finalSelection, second)
    }



    // Retain the original mixed-test ID for its subscription/configuration
    // assertions; no running-tunnel acknowledgement is part of Step 1.
    func testRunningTunnelReceivesChangedSelectedNodeBeforeSubscriptionCommit() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let first = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let priorRevision = try XCTUnwrap(context.model.selectedTunnelRevision)
        await context.model.testNodeLatency(first)
        XCTAssertNotNil(context.model.nodeLatencies[first])
        await context.fetcher.setYAML(Self.refreshFixture(password: "changed-fixture"))
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.selectedNodeID, first)
        XCTAssertNotEqual(context.model.selectedTunnelRevision, priorRevision)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        let selected = try await context.model.candidateMihomoTunnelConfiguration(nodeID: first, mode: .rule)
        XCTAssertEqual(selected.configurationRevision, context.model.selectedTunnelRevision)
        let probe = NodeProbeCandidate(nodeID: selected.nodeID,
            revision: try XCTUnwrap(selected.configurationRevision), coreName: try XCTUnwrap(selected.coreName),
            yaml: try MihomoNodeProbeConfiguration.yaml(from: selected.yaml))
        let pool = try MihomoStableCandidatePoolBuilder.build(selected: selected, candidates: [probe])
        let pooled = selected.withCandidatePool(yaml: pool.yaml, candidates: pool.candidates, revision: pool.revision)
        XCTAssertNotNil(pooled.candidatePoolRevision)
        XCTAssertEqual(pooled.candidatePool?.first?.revision, context.model.selectedTunnelRevision)
        XCTAssertNil(context.model.nodeLatencies[first])
    }

    func testProductionTunnelConfigurationIncludesAllMapperValidCandidatesWithoutProbeGate() async throws {
        let context = try await makeRefreshContext(extraNode: true)
        defer { removeDefaults(context.suite) }
        let request = try await context.model.tunnelRequest(mode: .rule)
        let configuration = try await context.model.selectedMihomoTunnelConfiguration(for: request)
        XCTAssertEqual(configuration.candidatePool?.count, 2)
        XCTAssertEqual(configuration.candidatePool?.first?.nodeID, request.nodeID)
        XCTAssertEqual(Set(configuration.candidatePool?.map(\.nodeID) ?? []).count, 2)
        XCTAssertNotNil(configuration.candidatePoolRevision)
    }

    func testProductionCandidatePoolSkipsInvalidMappedNodeAndKeepsSelected() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture") + """

          - name: Unsupported Fixture
            type: ss
            server: 198.51.100.30
            port: 443
            cipher: unsupported-cipher
            password: synthetic-invalid
        """)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.nodes.count, 2)
        let request = try await context.model.tunnelRequest(mode: .rule)
        let configuration = try await context.model.selectedMihomoTunnelConfiguration(for: request)
        XCTAssertEqual(configuration.candidatePool?.count, 1)
        XCTAssertEqual(configuration.candidatePool?.first?.nodeID, request.nodeID)
    }

    @MainActor
    func testUnchangedSubscriptionDoesNotReloadRunningTunnel() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let revision = context.model.selectedTunnelRevision
        let selectedID = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(selectedID)
        let previousLatency = context.model.nodeLatencies[selectedID]
        XCTAssertNotNil(previousLatency)
        let priorDownloads = await context.fetcher.fetchCount()
        await context.model.refreshNodes()
        let finalDownloads = await context.fetcher.fetchCount()
        XCTAssertEqual(finalDownloads, priorDownloads + 1)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertEqual(context.model.selectedTunnelRevision, revision)
        XCTAssertNil(context.model.nodeLatencies[selectedID])
    }

    @MainActor
    func testUniqueNameOnlyChangeMigratesSelectionWithoutDisconnecting() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let oldID = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture")
            .replacingOccurrences(of: "Stable Fixture", with: "Renamed Fixture"))
        await context.model.refreshNodes()
        let newID = try XCTUnwrap(context.model.nodes.selectedNodeID)
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(context.model.nodes.selectedNode?.displayName, "Renamed Fixture")
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
    }

    @MainActor
    func testAmbiguousNameOnlyChangeDoesNotGuessSelection() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let oldID = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.fetcher.setYAML("""
        proxies:
          - name: First Rename
            type: ss
            server: 1.1.1.1
            port: 443
            cipher: aes-128-gcm
            password: initial-fixture
          - name: Second Rename
            type: ss
            server: 1.1.1.1
            port: 443
            cipher: aes-128-gcm
            password: initial-fixture
        """)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.selectedNodeID, oldID)
        XCTAssertNil(context.model.nodes.selectedNode)
        XCTAssertNil(context.model.selectedTunnelRevision)
    }

    @MainActor
    func testRemovedSelectedNodeSafelyDisconnectsBeforeNewListCommits() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let oldID = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.fetcher.setYAML(Self.refreshFixture(password: "replacement-fixture")
            .replacingOccurrences(of: "Stable Fixture", with: "Different Fixture"))
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.selectedNodeID, oldID)
        XCTAssertNil(context.model.nodes.selectedNode)
        XCTAssertNil(context.model.selectedTunnelRevision)
        XCTAssertFalse(context.model.nodes.nodes.isEmpty)
    }

    func testNoticeResponseCompatibilitySafeHTMLEmptyAndParseFailure() throws {
        let notices = try V2BoardAPIClient.parseHomeNotices(root: [
            "data": [[
                "id": "9",
                "title": " Maintenance ",
                "content": "<style>hidden{}</style><p>Hello &amp; welcome</p><script>alert(1)</script>",
                "img_url": "https://example.invalid/image.png",
                "tags": ["重要", "弹窗"],
                "created_at": "42"
            ]]
        ])
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].id, 9)
        XCTAssertEqual(notices[0].title, "Maintenance")
        XCTAssertEqual(notices[0].plainContent, "Hello & welcome")
        XCTAssertFalse(notices[0].plainContent.contains("alert"))
        XCTAssertTrue(notices[0].isImportant)
        XCTAssertTrue(try V2BoardAPIClient.parseHomeNotices(root: ["data": []]).isEmpty)
        XCTAssertThrowsError(try V2BoardAPIClient.parseHomeNotices(root: ["data": ["unexpected": true]]))
        XCTAssertThrowsError(try V2BoardAPIClient.parseHomeNotices(root: ["data": [["unexpected": true]]]))
    }

    func testNoticeSourceIsSharedAndFailureRetainsCurrentAccountCache() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let sharedNotices = context.model.notices
        XCTAssertEqual(sharedNotices, context.model.notices)

        await context.business.setNoticeMode(.failure)
        await context.model.refreshNotices()
        XCTAssertEqual(context.model.notices, sharedNotices)
        guard case .stale = context.model.noticesLoadState else {
            return XCTFail("公告刷新失败时应保留当前账号缓存")
        }
    }

    func testConcurrentInitializationIsDeduplicatedAndTTLPreventsPageReload() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.business.setDelayNanoseconds(40_000_000)
        await context.nodes.setDelayNanoseconds(40_000_000)

        let establish = Task {
            await context.model.establishAuthenticatedSession(session(), source: .login)
        }
        try await Task.sleep(for: .milliseconds(5))
        async let first: Void = context.model.initializeAuthenticatedData(force: true)
        async let second: Void = context.model.refreshAuthenticatedDataIfNeeded()
        _ = await (first, second)
        await establish.value

        let countsAfterConcurrentLoad = await context.business.counts()
        let nodesAfterConcurrentLoad = await context.nodes.refreshCount()
        XCTAssertEqual(countsAfterConcurrentLoad, .init(account: 1, plans: 1, notices: 1))
        XCTAssertEqual(nodesAfterConcurrentLoad, 1)
        XCTAssertEqual(context.model.noticesLoadRevision, 1)

        await context.model.refreshAuthenticatedDataIfNeeded()
        let countsAfterTTLCheck = await context.business.counts()
        let nodesAfterTTLCheck = await context.nodes.refreshCount()
        XCTAssertEqual(countsAfterTTLCheck, .init(account: 1, plans: 1, notices: 1))
        XCTAssertEqual(nodesAfterTTLCheck, 1)
        XCTAssertEqual(context.model.noticesLoadRevision, 1)
    }

    func testOldAccountRequestsCannotOverwriteNewAccount() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.business.setDelayNanoseconds(80_000_000)
        await context.nodes.setDelayNanoseconds(80_000_000)
        let old = Task {
            await context.model.establishAuthenticatedSession(
                session(email: "old@example.invalid", authData: "old-fixture-auth"),
                source: .login
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        let current = session(email: "current@example.invalid", authData: "current-fixture-auth")
        await context.model.establishAuthenticatedSession(current, source: .login)
        await old.value

        XCTAssertEqual(context.model.session?.email, current.email)
        XCTAssertTrue(context.model.plans.allSatisfy { $0.name.contains("current") })
        XCTAssertTrue(context.model.nodes.nodes.allSatisfy { $0.displayName.contains("current") })
        XCTAssertTrue(context.model.notices.allSatisfy { $0.title.contains("current") })
    }

    func testSignOutCancelsInflightDataAndClearsPrivateState() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.business.setDelayNanoseconds(80_000_000)
        await context.nodes.setDelayNanoseconds(80_000_000)
        let loading = Task {
            await context.model.establishAuthenticatedSession(session(), source: .login)
        }
        try await Task.sleep(for: .milliseconds(5))

        await context.model.signOut()
        await loading.value

        XCTAssertNil(context.model.session)
        XCTAssertTrue(context.model.plans.isEmpty)
        XCTAssertTrue(context.model.nodes.nodes.isEmpty)
        XCTAssertTrue(context.model.notices.isEmpty)
        XCTAssertEqual(context.model.accountLoadState, .idle)
        XCTAssertEqual(context.model.plansLoadState, .idle)
        XCTAssertEqual(context.model.nodesLoadState, .idle)
        XCTAssertEqual(context.model.noticesLoadState, .idle)
    }

    func testSignOutStorageFailurePublishesExistingGlobalMessage() async throws {
        let keychain = SignOutFailingSessionKeychain()
        let context = try await makeContext(sessionKeychain: keychain)
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        keychain.beginFailingDeletes()

        await context.model.signOut()

        XCTAssertEqual(context.model.message, .localized(L10nKey.errorSecureStorage))
        XCTAssertNotNil(context.model.session)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: context.suite))
        XCTAssertTrue(defaults.bool(
            forKey: SessionStore.currentKeychainService + ".session.explicitly-signed-out"
        ))
        let relaunched = SessionStore(
            keychain: keychain,
            defaultsSuiteName: context.suite
        )
        let restoredAfterRelaunch = try await relaunched.read()
        XCTAssertNil(
            restoredAfterRelaunch,
            "A failed Keychain deletion must remain tombstoned after relaunch"
        )
    }

    func testProfileSignOutVPNFailurePreservesSessionPersistenceAndGeneration() async throws {
        let keychain = MemorySessionKeychain()
        let context = try await makeContext(sessionKeychain: keychain)
        defer { removeDefaults(context.suite) }
        let authenticatedSession = session()
        await context.model.establishAuthenticatedSession(authenticatedSession, source: .login)
        let generation = context.model.commerceRecoveryGeneration
        let persistedBefore = keychain.read(
            service: SessionStore.currentKeychainService,
            account: "v2board.authenticated-session"
        )

        let outcome = await ProfileSignOutFlow.complete(
            choice: .primary,
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: { throw URLError(.cannotConnectToHost) },
            confirmVPNDisconnected: { false },
            signOut: { await context.model.signOut() },
            reportVPNDisconnectFailure: {
                context.model.message = .localized("profile.sign_out.vpn_disconnect_failed")
            }
        )

        let persistedAfter = keychain.read(
            service: SessionStore.currentKeychainService,
            account: "v2board.authenticated-session"
        )
        XCTAssertEqual(outcome, .vpnDisconnectFailed)
        XCTAssertEqual(context.model.session?.email, authenticatedSession.email)
        XCTAssertEqual(context.model.commerceRecoveryGeneration, generation)
        XCTAssertEqual(persistedAfter.status, persistedBefore.status)
        XCTAssertEqual(persistedAfter.data, persistedBefore.data)
        XCTAssertEqual(
            context.model.message,
            .localized("profile.sign_out.vpn_disconnect_failed")
        )
    }

    func testCancellationSignOutStopsSubscriptionRecoveryAndKeepsSignedOutState() async throws {
        let suite = "NetworkClient.logout-recovery.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let entered = RecoveryOperationGate()
        let release = RecoveryOperationGate()
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let recovered = RecordingNetworkTransport { _, _ in
            await entered.open()
            await release.wait()
            throw URLError(.networkConnectionLost)
        }
        let runtime = CancellationRecoveryRuntime(transport: recovered)
        let repository = NodeRepository(
            subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: SubscriptionFetcher(
                transport: direct, recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
            ),
            selectionStore: NodeSelectionStore(suiteName: suite)
        )
        let ss = "ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
            + "@198.51.100.20:443"
        let model = AppModel(
            offline: false, businessDataAPI: BootstrapBusinessAPI(),
            sessionVerifier: BootstrapSessionVerifier(), nodeRepository: repository,
            apiHealthMonitor: offlineHealthMonitor(),
            sessionStore: SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite),
            initialConfig: config(builtInProxy: [
                ss, ss.replacingOccurrences(of: "198.51.100.20", with: "198.51.100.21")
            ])
        )
        let loading = Task { await model.establishAuthenticatedSession(session(), source: .login) }
        await entered.wait()
        await model.signOut()
        await release.open()
        await loading.value

        let calls = await recovered.calls
        let counts = await runtime.counts
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(counts.starts, 1, "Logout must not start candidate B")
        XCTAssertEqual(counts.stops, 1)
        XCTAssertNil(model.session)
        XCTAssertTrue(model.nodes.nodes.isEmpty)
        XCTAssertEqual(model.nodesLoadState, .idle)
        XCTAssertEqual(model.accountLoadState, .idle)
        XCTAssertEqual(model.plansLoadState, .idle)
        XCTAssertEqual(model.noticesLoadState, .idle)
    }

    func testNewLocalizationKeysExistInEnglishAndSimplifiedChinese() throws {
        let keys = [
            "home.notice.failed", "home.notice.loading", "home.notice.retry",
            "purchase.action.retry", "purchase.status.empty", "purchase.status.failed", "purchase.status.loading",
            "nodes.action.retry", "nodes.status.empty", "nodes.status.failed", "nodes.status.loading",
            "nodes.status.updated", "nodes.latency.test_all", "nodes.latency.cancel_all",
            "nodes.latency.testing", "nodes.latency.failed_short", "nodes.latency.unavailable",
            "nodes.latency.disconnect_notice"
        ]
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"), locale)
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: key, table: nil), key, "\(locale): \(key)")
            }
        }
    }

    func testSingleNodeHTTPProbeUsesNonTunnelConfigAndReportsRealDelay() async throws {
        let prober = RecordingNodeHTTPProber()
        let context = try await makeContext(nodeProber: prober, nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.nodes.first?.id)
        await context.model.testNodeLatency(id)
        XCTAssertEqual(context.model.nodeLatencies[id], .measured(NodeLatencyReading(
            actualMilliseconds: 42, displayRatio: 1
        )!))
        let calls = await prober.calls()
        XCTAssertEqual(calls.count, 1)
        let root = try XCTUnwrap(Yams.load(yaml: calls[0].yaml) as? [String: Any])
        let tun = try XCTUnwrap(root["tun"] as? [String: Any])
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, false)
        XCTAssertEqual(dns["enable"] as? Bool, false)
        let proxies = try XCTUnwrap(root["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 1)
        XCTAssertEqual(proxies.first?["name"] as? String, calls[0].coreName)
        XCTAssertEqual(context.model.nodeLatencies[id], .measured(NodeLatencyReading(
            actualMilliseconds: 42, displayRatio: 1
        )!))
    }



    @MainActor
    func testFailedManualRefreshKeepsVerifiedNodeAvailableForReconnection() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let selected = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.fetcher.setYAML("proxies: []")
        await context.model.refreshNodes()
        guard case .stale = context.model.nodesLoadState else {
            return XCTFail("A failed replacement must retain the verified snapshot")
        }
        let request = try await context.model.tunnelRequest(mode: .rule)
        XCTAssertEqual(request.nodeID, selected)
        XCTAssertEqual(context.model.nodes.selectedNodeID, selected)
    }







    func testAllNodeHTTPProbesContinueAfterTimeout() async throws {
        let prober = RecordingNodeHTTPProber(timeoutFirst: true)
        let context = try await makeContext(
            nodeProber: prober, nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        await context.model.testAllNodeLatencies()
        let nodes = context.model.nodes.nodes
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(context.model.nodeLatencies[nodes[0].id], .timedOut)
        XCTAssertEqual(context.model.nodeLatencies[nodes[1].id], .measured(NodeLatencyReading(
            actualMilliseconds: 42, displayRatio: 1
        )!))
        XCTAssertFalse(context.model.testingAllNodes)
        XCTAssertEqual(context.model.nodeLatencyProgress, NodeLatencyProgress(completed: 2, total: 2))
        let calls = await prober.calls()
        XCTAssertEqual(calls.count, 2)
        await context.model.refreshNodes()
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
    }

    func testSelectingAnotherNodeKeepsExistingLatenciesWithoutRefreshingOrProbing() async throws {
        let prober = RecordingNodeHTTPProber()
        let context = try await makeContext(
            nodeProber: prober, nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let initialRefreshCount = await context.nodes.refreshCount()
        XCTAssertEqual(initialRefreshCount, 1)

        await context.model.testAllNodeLatencies()
        let previousLatencies = context.model.nodeLatencies
        let previousProbeCount = await prober.calls().count
        let nextID = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        XCTAssertEqual(previousLatencies.count, 2)

        await context.model.selectNode(nextID)
        XCTAssertEqual(context.model.nodes.selectedNodeID, nextID)
        XCTAssertEqual(context.model.nodeLatencies, previousLatencies)
        let refreshCountAfterSelection = await context.nodes.refreshCount()
        let probeCountAfterSelection = await prober.calls().count
        XCTAssertEqual(refreshCountAfterSelection, 1)
        XCTAssertEqual(probeCountAfterSelection, previousProbeCount)

        await context.model.refreshNodes()
        let refreshCountAfterManualRefresh = await context.nodes.refreshCount()
        XCTAssertEqual(refreshCountAfterManualRefresh, 2)
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
    }

    func testDisconnectedNodeSelectionKeepsGlobalBusyPresentationHidden() async throws {
        let context = try await makeContext(nodeCount: 2)
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let firstID = context.model.nodes.selectedNodeID
        let nextID = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        await context.nodes.setSuspendSelection(true)

        let selection = Task { await context.model.selectNode(nextID) }
        for _ in 0..<1_000 {
            if await context.nodes.selectionStarted() { break }
            await Task.yield()
        }
        let started = await context.nodes.selectionStarted()
        XCTAssertTrue(started)
        XCTAssertTrue(context.model.busy)
        XCTAssertFalse(context.model.showsGlobalBusyIndicator)
        XCTAssertEqual(context.model.nodes.selectedNodeID, firstID)

        await context.nodes.resumeSelection()
        await selection.value
        XCTAssertEqual(context.model.nodes.selectedNodeID, nextID)
        XCTAssertFalse(context.model.busy)
        XCTAssertFalse(context.model.showsGlobalBusyIndicator)
    }

    func testFailedManualNodeRefreshPreservesLastVerifiedListAndLatencies() async throws {
        let prober = RecordingNodeHTTPProber()
        let context = try await makeContext(
            nodeProber: prober, nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        await context.model.testAllNodeLatencies()
        let oldNodes = context.model.nodes
        let oldLatencies = context.model.nodeLatencies
        XCTAssertFalse(oldLatencies.isEmpty)
        await context.nodes.setMode(.parseFailure)

        await context.model.refreshNodes()

        XCTAssertEqual(context.model.nodes, oldNodes)
        XCTAssertEqual(context.model.nodeLatencies, oldLatencies)
        XCTAssertNotNil(context.model.nodesLoadState.failureMessage)
    }

    func testManualRefreshDuringInitialReadFetchesFreshSubscription() async throws {
        let context = try await makeContext()
        defer { removeDefaults(context.suite) }
        await context.nodes.setSuspendRefresh(true)
        let initial = Task {
            await context.model.establishAuthenticatedSession(session(), source: .login)
        }
        for _ in 0..<2_000 {
            if await context.nodes.refreshCount() == 1 { break }
            await Task.yield()
        }
        let started = await context.nodes.refreshCount()
        guard started == 1 else {
            await context.nodes.resumeRefresh()
            await initial.value
            return XCTFail("The initial authenticated subscription read did not start")
        }
        let manual = Task { await context.model.refreshNodes() }
        await context.nodes.resumeRefresh()
        await manual.value
        await initial.value
        let downloads = await context.nodes.refreshCount()
        XCTAssertEqual(downloads, 2)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
    }

    func testCancellingAllNodeHTTPProbesStopsBeforeNextNode() async throws {
        let prober = RecordingNodeHTTPProber(pauseFirst: true)
        let context = try await makeContext(
            nodeProber: prober, nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<1_000 {
            if await prober.calls().count == 1 { break }
            await Task.yield()
        }
        let started = await prober.calls()
        XCTAssertEqual(started.count, 1)
        context.model.cancelAllNodeLatencies()
        await prober.resumeFirst()
        await batch.value
        let calls = await prober.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        XCTAssertFalse(context.model.testingAllNodes)
    }

    func testSuccessfulManualRefreshDiscardsLateBatchLatencyResult() async throws {
        let prober = RecordingNodeHTTPProber(pauseFirst: true)
        let context = try await makeContext(
            nodeProber: prober, nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)

        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<1_000 {
            if await prober.calls().count == 1 { break }
            await Task.yield()
        }
        let startedCalls = await prober.calls()
        XCTAssertEqual(startedCalls.count, 1)

        await context.model.refreshNodes()
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        await prober.resumeFirst()
        await batch.value
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        XCTAssertFalse(context.model.testingAllNodes)
    }

    func testBoundedNodeProbePoolRunsAtMostTenAndAssociatesOutOfOrderResults() async {
        let candidates = (0..<16).map { index in
            NodeProbeCandidate(nodeID: "id-\(index)", revision: "revision",
                               coreName: "core-\(index)", yaml: "")
        }
        let tracker = ProbePoolTracker()
        let results = ProbePoolResults()
        await NodeProbePool.run(candidates, stagger: { 0 }, probe: { name in
            await tracker.probe(name)
        }, onResult: { result in await results.append(result) })
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.started, 16)
        XCTAssertEqual(snapshot.maximum, 10)
        let delivered = await results.values()
        XCTAssertEqual(delivered.count, 16)
        XCTAssertEqual(Set(delivered.map(\.nodeID)), Set(candidates.map(\.nodeID)))
        XCTAssertNotEqual(delivered.first?.nodeID, "id-0")
        XCTAssertEqual(delivered.first(where: { $0.nodeID == "id-9" })?.outcome, .timedOut)
        XCTAssertEqual(delivered.last?.nodeID, "id-0")
    }

    func testConnectedCoreProbePoolCanBeSerializedForBoundedTeardown() async {
        let candidates = (0..<3).map { index in
            NodeProbeCandidate(nodeID: "id-\(index)", revision: "revision",
                               coreName: "core-\(index)", yaml: "")
        }
        let tracker = ProbePoolTracker()
        await NodeProbePool.run(candidates, maximumConcurrent: 1,
                                stagger: { 0 }, probe: { name in
            await tracker.probe(name)
        }, onResult: { _ in })
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.started, 3)
        XCTAssertEqual(snapshot.maximum, 1)
    }

    func testNodeProbePoolCancellationDoesNotStartQueuedNodesOrDeliverStaleResults() async {
        let candidates = (0..<20).map { index in
            NodeProbeCandidate(nodeID: "id-\(index)", revision: "revision",
                               coreName: "core-\(index)", yaml: "")
        }
        let tracker = ProbePoolTracker()
        let results = ProbePoolResults()
        let task = Task {
            await NodeProbePool.run(candidates, stagger: { 0 }, probe: { name in
                await tracker.slowProbe(name)
            }, onResult: { result in await results.append(result) })
        }
        for _ in 0..<1_000 {
            if await tracker.snapshot().started == 10 { break }
            await Task.yield()
        }
        task.cancel()
        _ = await task.value
        let started = await tracker.snapshot().started
        let delivered = await results.values()
        XCTAssertLessThanOrEqual(started, 10)
        XCTAssertTrue(delivered.isEmpty)
    }

    private struct Context {
        let model: AppModel
        let business: BootstrapBusinessAPI
        let nodes: BootstrapNodeRepository
        let suite: String
    }

    private struct RefreshContext {
        let model: AppModel
        let repository: NodeRepository
        let fetcher: StagedSubscriptionFetcher
        let suite: String
    }

    private static func refreshFixture(password: String) -> String {
        """
        proxies:
          - name: Stable Fixture
            type: ss
            server: 1.1.1.1
            port: 443
            cipher: aes-128-gcm
            password: \(password)
        """
    }













    private func makeRefreshContext(
        extraNode: Bool = false, thirdNode: Bool = false,
        nodeProber: (any NodeHTTPProbing)? = nil,
        connectedNodeProber: (any ConnectedNodeProbing)? = nil
    ) async throws -> RefreshContext {
        let suite = "NetworkClient.running-refresh.\(UUID().uuidString)"
        let sessions = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        try await sessions.setAutoLoginEnabled(true)
        let fetcher = StagedSubscriptionFetcher()
        let fixture = Self.refreshFixture(password: "initial-fixture")
            + (extraNode ? """

              - name: Other Fixture
                type: ss
                server: 1.0.0.1
                port: 443
                cipher: aes-128-gcm
                password: other-fixture
            """ : "") + (thirdNode ? """

              - name: Third Fixture
                type: ss
                server: 8.8.8.8
                port: 443
                cipher: aes-128-gcm
                password: third-fixture
            """ : "")
        await fetcher.setYAML(fixture)
        let repository = NodeRepository(
            subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: fetcher,
            selectionStore: NodeSelectionStore(suiteName: suite)
        )
        let model = AppModel(
            offline: false,
            businessDataAPI: BootstrapBusinessAPI(),
            sessionVerifier: BootstrapSessionVerifier(),
            nodeRepository: repository,
            apiHealthMonitor: offlineHealthMonitor(),
            sessionStore: sessions,
            initialConfig: config(),
            nodeProber: nodeProber ?? RecordingNodeHTTPProber(),
            connectedNodeProber: connectedNodeProber
        )
        await model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(model.nodes.nodes.first?.id)
        await model.selectNode(id)
        return RefreshContext(model: model, repository: repository, fetcher: fetcher, suite: suite)
    }

    private func makeContext(
        nodeProber: (any NodeHTTPProbing)? = nil,
        connectedNodeProber: (any ConnectedNodeProbing)? = nil,
        nodeServer: String = "example.invalid",
        nodeCount: Int = 1,
        sessionKeychain: (any SessionKeychainAccess)? = nil
    ) async throws -> Context {
        let suite = "NetworkClient.bootstrap.\(UUID().uuidString)"
        let store = SessionStore(
            keychain: sessionKeychain ?? MemorySessionKeychain(),
            defaultsSuiteName: suite
        )
        try await store.setAutoLoginEnabled(true)
        let business = BootstrapBusinessAPI()
        let nodes = BootstrapNodeRepository(server: nodeServer, nodeCount: nodeCount)
        let model = AppModel(
            offline: false,
            businessDataAPI: business,
            sessionVerifier: BootstrapSessionVerifier(),
            nodeRepository: nodes,
            apiHealthMonitor: offlineHealthMonitor(),
            sessionStore: store,
            initialConfig: config(),
            nodeProber: nodeProber,
            connectedNodeProber: connectedNodeProber
        )
        return Context(model: model, business: business, nodes: nodes, suite: suite)
    }

    private func offlineHealthMonitor() -> APIHealthMonitor {
        APIHealthMonitor(
            transport: RecordingNetworkTransport { _, _ in throw URLError(.notConnectedToInternet) },
            observeNetwork: false
        )
    }

    private func config(
        apiBaseURLs: [String] = ["https://example.invalid"], builtInProxy: [String] = []
    ) -> AppConfig {
        AppConfig(
            appName: "Fixture",
            loginTitle: nil,
            appLogo: nil,
            homePage: nil,
            telegramGroup: nil,
            supportAPI: nil,
            updateURL: nil,
            userAgent: "NetworkClientTests/1",
            latencyDisplayRatio: 1,
            inviteLink: nil,
            apiBaseURLs: apiBaseURLs,
            activeAPIBaseURL: apiBaseURLs.first,
            builtInProxy: builtInProxy
        )
    }

    private func session(
        email: String = "account@example.invalid",
        authData: String = "isolated-fixture-auth"
    ) -> UserSession {
        UserSession(
            email: email,
            authData: authData,
            accountToken: nil,
            subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 10,
            downloadBytes: 20,
            transferEnableBytes: 1_000,
            expiredAt: 0,
            planID: 1,
            planName: "Fixture Plan",
            balanceCents: 100,
            verifiedAt: Date()
        )
    }

    private func removeDefaults(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

extension AuthenticatedBootstrapTests {
    func testConnectPreflightRejectsNoSelectedNode() async throws {
        let context = try await makeContext(nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.nodes.configurePreflight(autoSelect: false)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        do {
            _ = try await context.model.tunnelRequest(mode: .rule)
            XCTFail("Connect must require an explicit node selection")
        } catch let error as VPNConnectionPreflightError {
            XCTAssertEqual(error, .noNodeSelected)
        }
    }

    func testConnectPreflightRejectsSelectedNodeMissingFromCurrentCatalog() async throws {
        let context = try await makeContext(nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.nodes.configurePreflight(catalogContainsSelectedNode: false)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        XCTAssertNotNil(context.model.nodes.selectedNodeID)
        XCTAssertNil(context.model.nodes.selectedNode)
        do {
            _ = try await context.model.tunnelRequest(mode: .rule)
            XCTFail("A stale selected ID must not reach configuration mapping")
        } catch let error as VPNConnectionPreflightError {
            XCTAssertEqual(error, .selectedNodeMissing)
        }
    }

    func testConnectPreflightAllowsUnavailableNodeWhenConfigurationIsValid() async throws {
        let context = try await makeContext(nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.nodes.configurePreflight(nodeAvailable: false)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        XCTAssertEqual(context.model.nodes.selectedNode?.available, false)
        let request = try await context.model.tunnelRequest(mode: .rule)
        let configuration = try await context.model.selectedMihomoTunnelConfiguration(for: request)
        XCTAssertEqual(configuration.nodeID, request.nodeID)
    }

    func testConnectPreflightRejectsInvalidTunnelConfiguration() async throws {
        let context = try await makeContext(nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.nodes.configurePreflight(configurationValid: false)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        do {
            _ = try await context.model.minimalVPNConfiguration(mode: .rule)
            XCTFail("An invalid runtime proxy must fail before Provider startup")
        } catch let error as VPNConnectionPreflightError {
            XCTAssertEqual(error, .nodeConfigurationInvalid)
        }
    }

    func testConnectPreflightAllowsPresentValidNode() async throws {
        let context = try await makeContext(nodeServer: "1.1.1.1")
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let request = try await context.model.tunnelRequest(mode: .global)
        let configuration = try await context.model.selectedMihomoTunnelConfiguration(for: request)
        XCTAssertEqual(configuration.nodeID, request.nodeID)
        XCTAssertEqual(configuration.configurationRevision, request.configurationRevision)
    }
}

private actor RecordingNodeHTTPProber: NodeHTTPProbing {
    struct Call: Sendable {
        let yaml: String
        let coreName: String
    }

    private let timeoutFirst: Bool
    private let pauseFirst: Bool
    private let pauseCallNumber: Int?
    private var recorded: [Call] = []
    private var firstGate: CheckedContinuation<Void, Never>?

    init(timeoutFirst: Bool = false, pauseFirst: Bool = false, pauseCallNumber: Int? = nil) {
        self.timeoutFirst = timeoutFirst
        self.pauseFirst = pauseFirst
        self.pauseCallNumber = pauseCallNumber
    }

    func probeNode(yaml: String, coreName: String) async throws -> Int {
        recorded.append(Call(yaml: yaml, coreName: coreName))
        if (pauseFirst && recorded.count == 1) || recorded.count == pauseCallNumber {
            await withCheckedContinuation { firstGate = $0 }
            try Task.checkCancellation()
        }
        if timeoutFirst && recorded.count == 1 { throw MihomoNodeProbeError.timeout }
        return 42
    }

    func calls() -> [Call] { recorded }
    func resumeFirst() { firstGate?.resume(); firstGate = nil }
}

@MainActor
private final class RecordingConnectedNodeProber: ConnectedNodeProbing {
    struct Call: Equatable {
        let coreNames: [String]
        let candidatePoolRevision: String?
    }

    var nodeProbeState: MinimalVPNController.State
    var nodeProbeCandidatePoolRevision: String?
    var statuses: [NetworkClient.MihomoTunnelNodeProbeStatus]
    private(set) var calls: [Call] = []

    init(
        state: MinimalVPNController.State,
        candidatePoolRevision: String? = String(repeating: "a", count: 64),
        statuses: [NetworkClient.MihomoTunnelNodeProbeStatus] = []
    ) {
        nodeProbeState = state
        nodeProbeCandidatePoolRevision = candidatePoolRevision
        self.statuses = statuses
    }

    func probeNodes(
        coreNames: [String], candidatePoolRevision: String?
    ) async throws -> [NetworkClient.MihomoTunnelNodeProbeResult] {
        calls.append(.init(
            coreNames: coreNames,
            candidatePoolRevision: candidatePoolRevision
        ))
        let callIndex = calls.count - 1
        return coreNames.enumerated().map { index, coreName in
            let statusIndex = callIndex + index
            let status = statusIndex < statuses.count ? statuses[statusIndex] : .measured
            return NetworkClient.MihomoTunnelNodeProbeResult(
                coreName: coreName, status: status,
                delayMilliseconds: status == .measured ? 70 + statusIndex : nil
            )
        }
    }
}

@MainActor
private final class ControllableConnectedNodeProber: ConnectedNodeProbing {
    typealias ProbeResult = NetworkClient.MihomoTunnelNodeProbeResult
    typealias ProbeStatus = NetworkClient.MihomoTunnelNodeProbeStatus

    var nodeProbeState: MinimalVPNController.State = .connected
    var nodeProbeCandidatePoolRevision: String? = String(repeating: "a", count: 64)
    private(set) var calls: [String] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var waiters: [String: CheckedContinuation<[ProbeResult], Error>] = [:]

    func probeNodes(
        coreNames: [String], candidatePoolRevision: String?
    ) async throws -> [ProbeResult] {
        guard coreNames.count == 1, let coreName = coreNames.first else {
            throw URLError(.badURL)
        }
        calls.append(coreName)
        active += 1
        maximumActive = max(maximumActive, active)
        return try await withCheckedThrowingContinuation { continuation in
            waiters[coreName] = continuation
        }
    }

    var pendingCoreNames: [String] { Array(waiters.keys) }

    func complete(
        _ coreName: String, status: ProbeStatus = .measured, delay: Int? = 42
    ) {
        guard let continuation = waiters.removeValue(forKey: coreName) else {
            XCTFail("No pending Provider probe for \(coreName)")
            return
        }
        active -= 1
        continuation.resume(returning: [ProbeResult(
            coreName: coreName,
            status: status,
            delayMilliseconds: status == .measured ? delay : nil
        )])
    }
}

private actor ControllableAppNodeProber: NodeHTTPProbing {
    struct Snapshot: Sendable {
        let started: Int
        let active: Int
        let maximumActive: Int
        let pendingCoreNames: [String]
    }

    private var calls: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var waiters: [String: CheckedContinuation<NodeProbeOutcome, Never>] = [:]

    func probeNode(yaml: String, coreName: String) async throws -> Int { 42 }

    func probeBatch(
        _ items: [NodeProbeCandidate],
        onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool,
        onResult: @escaping @Sendable (NodeProbeResult) async -> Void
    ) async throws {
        _ = await NodeProbePool.run(
            items,
            probe: { coreName in await self.waitForCompletion(coreName) },
            onStart: onStart,
            onResult: onResult
        )
        try Task.checkCancellation()
    }

    private func waitForCompletion(_ coreName: String) async -> NodeProbeOutcome {
        calls.append(coreName)
        active += 1
        maximumActive = max(maximumActive, active)
        return await withCheckedContinuation { continuation in
            waiters[coreName] = continuation
        }
    }

    func snapshot() -> Snapshot {
        .init(
            started: calls.count,
            active: active,
            maximumActive: maximumActive,
            pendingCoreNames: Array(waiters.keys)
        )
    }

    @discardableResult
    func complete(_ coreName: String, outcome: NodeProbeOutcome = .measured(42)) -> Bool {
        guard let continuation = waiters.removeValue(forKey: coreName) else { return false }
        active -= 1
        continuation.resume(returning: outcome)
        return true
    }
}

extension AuthenticatedBootstrapTests {
    func testStep261DisconnectedSingleLatencyKeepsAppOnlyRuntime() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = RecordingConnectedNodeProber(state: .disconnected)
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1"
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)

        await context.model.testNodeLatency(id)

        let appCalls = await appProber.calls()
        XCTAssertEqual(appCalls.count, 1)
        XCTAssertTrue(providerProber.calls.isEmpty)
        XCTAssertEqual(context.model.nodeLatencies[id], .measured(.init(
            actualMilliseconds: 42, displayRatio: 1
        )!))
    }

    func testStep261ConnectedSingleLatencyUsesProviderWithoutAppCore() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = RecordingConnectedNodeProber(state: .connected)
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1"
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)

        await context.model.testNodeLatency(id)

        let appCalls = await appProber.calls()
        XCTAssertTrue(appCalls.isEmpty)
        XCTAssertEqual(providerProber.calls.count, 1)
        XCTAssertEqual(providerProber.calls[0].coreNames.count, 1)
        XCTAssertEqual(context.model.nodeLatencies[id], .measured(.init(
            actualMilliseconds: 70, displayRatio: 1
        )!))
    }

    func testStep261ConnectedBatchContinuesAfterPerNodeFailure() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = RecordingConnectedNodeProber(
            state: .connected, statuses: [.measured, .failed]
        )
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1", nodeCount: 2
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)

        await context.model.testAllNodeLatencies()

        let appCalls = await appProber.calls()
        XCTAssertTrue(appCalls.isEmpty)
        XCTAssertEqual(providerProber.calls.count, 2)
        XCTAssertTrue(providerProber.calls.allSatisfy { $0.coreNames.count == 1 })
        let states = context.model.nodes.nodes.compactMap {
            context.model.nodeLatencies[$0.id]
        }
        XCTAssertEqual(states.filter { if case .measured = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(states.filter { $0 == .failed }.count, 1)
        XCTAssertEqual(context.model.nodeLatencyProgress, .init(completed: 2, total: 2))
    }

    func testStep263AConnectedPublishesEachNodeBeforeSlowerPeersComplete() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1", nodeCount: 3
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<2_000 {
            if providerProber.calls.count == 3 { break }
            await Task.yield()
        }
        XCTAssertEqual(providerProber.calls.count, 3)
        let appCalls = await appProber.calls()
        XCTAssertTrue(appCalls.isEmpty)
        XCTAssertEqual(context.model.testingNodeIDs, Set(nodes.map(\.id)))

        providerProber.complete(nodes[0].coreName, delay: 100)
        for _ in 0..<2_000 {
            if context.model.nodeLatencyProgress.completed == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(context.model.nodeLatencies[nodes[0].id], .measured(.init(
            actualMilliseconds: 100, displayRatio: 1
        )!))
        XCTAssertTrue(context.model.testingNodeIDs.contains(nodes[1].id))
        XCTAssertTrue(context.model.testingNodeIDs.contains(nodes[2].id))

        providerProber.complete(nodes[1].coreName, delay: 300)
        for _ in 0..<2_000 {
            if context.model.nodeLatencyProgress.completed == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(context.model.nodeLatencies[nodes[1].id], .measured(.init(
            actualMilliseconds: 300, displayRatio: 1
        )!))
        XCTAssertTrue(context.model.testingNodeIDs.contains(nodes[2].id))

        providerProber.complete(nodes[2].coreName, delay: 800)
        await batch.value
        XCTAssertEqual(context.model.nodeLatencies[nodes[2].id], .measured(.init(
            actualMilliseconds: 800, displayRatio: 1
        )!))
        XCTAssertEqual(context.model.nodeLatencyProgress, .init(completed: 3, total: 3))
    }

    func testStep263AConnectedPublishesInCompletionOrderNotInputOrder() async throws {
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            connectedNodeProber: providerProber, nodeServer: "1.1.1.1", nodeCount: 3
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<2_000 {
            if providerProber.calls.count == 3 { break }
            await Task.yield()
        }

        for (node, delay, completed) in [
            (nodes[2], 30, 1), (nodes[0], 50, 2), (nodes[1], 70, 3),
        ] {
            providerProber.complete(node.coreName, delay: delay)
            for _ in 0..<2_000 {
                if context.model.nodeLatencyProgress.completed == completed { break }
                await Task.yield()
            }
            XCTAssertEqual(context.model.nodeLatencies[node.id], .measured(.init(
                actualMilliseconds: delay, displayRatio: 1
            )!))
        }
        await batch.value
        XCTAssertEqual(context.model.nodeLatencyProgress.completed, 3)
    }

    func testFinalLatencyConnectedPublishesFiveThroughEightAndImmediatelyStartsElevenThroughFourteen() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1", nodeCount: 14
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }

        for _ in 0..<4_000 {
            if providerProber.calls.count == 10,
               context.model.testingNodeIDs.count == 10 { break }
            await Task.yield()
        }
        XCTAssertEqual(providerProber.calls.count, 10)
        XCTAssertEqual(providerProber.active, 10)
        XCTAssertEqual(context.model.testingNodeIDs, Set(nodes.prefix(10).map(\.id)))
        XCTAssertFalse(context.model.testingNodeIDs.contains(nodes[10].id),
                       "Pending node 11 must not show a spinner before it starts")

        for (completedIndex, replacementIndex, completedCount) in [
            (4, 10, 1), (5, 11, 2), (6, 12, 3), (7, 13, 4),
        ] {
            let completed = nodes[completedIndex]
            let replacement = nodes[replacementIndex]
            providerProber.complete(completed.coreName, delay: 100 + completedIndex)
            for _ in 0..<4_000 {
                if context.model.nodeLatencyProgress.completed == completedCount,
                   providerProber.calls.count == 10 + completedCount,
                   context.model.testingNodeIDs.contains(replacement.id) { break }
                await Task.yield()
            }
            XCTAssertEqual(context.model.nodeLatencies[completed.id], .measured(.init(
                actualMilliseconds: 100 + completedIndex, displayRatio: 1
            )!))
            XCTAssertFalse(context.model.testingNodeIDs.contains(completed.id))
            XCTAssertTrue(context.model.testingNodeIDs.contains(replacement.id))
            XCTAssertEqual(providerProber.active, 10)
            XCTAssertEqual(providerProber.calls.count, 10 + completedCount)
            XCTAssertTrue(context.model.testingNodeIDs.contains(nodes[0].id),
                          "A slow first node must not delay another row's UI result")
        }

        while context.model.nodeLatencyProgress.completed < nodes.count {
            let before = context.model.nodeLatencyProgress.completed
            let coreName = try XCTUnwrap(providerProber.pendingCoreNames.first)
            providerProber.complete(coreName, delay: 200 + before)
            for _ in 0..<4_000 {
                if context.model.nodeLatencyProgress.completed > before { break }
                await Task.yield()
            }
        }
        await batch.value
        XCTAssertEqual(providerProber.maximumActive, 10)
        XCTAssertTrue(context.model.testingNodeIDs.isEmpty)
        let appCalls = await appProber.calls()
        XCTAssertTrue(appCalls.isEmpty)
    }

    func testFinalLatencyConnectedStartsProviderWithoutRemappingTunnelYAMLForEveryNode() async throws {
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1", nodeCount: 14
        )
        defer { removeDefaults(context.suite) }
        // The running Provider is the authority for its already validated pool.
        // This deliberately makes a fresh App-side Tunnel mapping fail; latency
        // must still reach the Provider through the loaded node/core identity.
        await context.nodes.configurePreflight(mapperSupported: false)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }

        for _ in 0..<4_000 {
            if providerProber.calls.count == 10 { break }
            await Task.yield()
        }
        XCTAssertEqual(providerProber.calls.count, 10)
        XCTAssertEqual(providerProber.active, 10)
        XCTAssertEqual(context.model.testingNodeIDs, Set(nodes.prefix(10).map(\.id)))

        while context.model.nodeLatencyProgress.completed < nodes.count {
            let before = context.model.nodeLatencyProgress.completed
            let coreName = try XCTUnwrap(providerProber.pendingCoreNames.first)
            providerProber.complete(coreName, delay: 80 + before)
            for _ in 0..<4_000 {
                if context.model.nodeLatencyProgress.completed > before { break }
                await Task.yield()
            }
        }
        await batch.value
        XCTAssertEqual(providerProber.calls.count, 14)
        XCTAssertEqual(providerProber.maximumActive, 10)
        XCTAssertEqual(context.model.nodeLatencies.count, 14)
    }

    func testFinalLatencyDisconnectedUsesSameRollingTenImmediatePublishAndReplacement() async throws {
        let appProber = ControllableAppNodeProber()
        let context = try await makeContext(
            nodeProber: appProber, nodeServer: "1.1.1.1", nodeCount: 14
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }

        for _ in 0..<4_000 {
            let snapshot = await appProber.snapshot()
            if snapshot.started == 10, context.model.testingNodeIDs.count == 10 { break }
            await Task.yield()
        }
        var snapshot = await appProber.snapshot()
        XCTAssertEqual(snapshot.started, 10)
        XCTAssertEqual(snapshot.active, 10)
        XCTAssertEqual(snapshot.maximumActive, 10)
        XCTAssertEqual(context.model.testingNodeIDs, Set(nodes.prefix(10).map(\.id)))
        XCTAssertFalse(context.model.testingNodeIDs.contains(nodes[10].id))

        let completedFive = await appProber.complete(
            nodes[4].coreName, outcome: .measured(155)
        )
        XCTAssertTrue(completedFive)
        for _ in 0..<4_000 {
            snapshot = await appProber.snapshot()
            if context.model.nodeLatencyProgress.completed == 1,
               snapshot.started == 11,
               context.model.testingNodeIDs.contains(nodes[10].id) { break }
            await Task.yield()
        }
        XCTAssertEqual(context.model.nodeLatencies[nodes[4].id], .measured(.init(
            actualMilliseconds: 155, displayRatio: 1
        )!))
        XCTAssertFalse(context.model.testingNodeIDs.contains(nodes[4].id))
        XCTAssertTrue(context.model.testingNodeIDs.contains(nodes[10].id))
        XCTAssertEqual(snapshot.active, 10)

        while context.model.nodeLatencyProgress.completed < nodes.count {
            let before = context.model.nodeLatencyProgress.completed
            snapshot = await appProber.snapshot()
            let coreName = try XCTUnwrap(snapshot.pendingCoreNames.first)
            let completed = await appProber.complete(coreName)
            XCTAssertTrue(completed)
            for _ in 0..<4_000 {
                if context.model.nodeLatencyProgress.completed > before { break }
                await Task.yield()
            }
        }
        await batch.value
        snapshot = await appProber.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 10)
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertTrue(context.model.testingNodeIDs.isEmpty)
    }

    func testFinalLatencyRetestKeepsOldValueUntilThatNodeCompletes() async throws {
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            connectedNodeProber: providerProber, nodeServer: "1.1.1.1"
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let node = try XCTUnwrap(context.model.nodes.nodes.first)

        let first = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<2_000 {
            if providerProber.calls.count == 1 { break }
            await Task.yield()
        }
        providerProber.complete(node.coreName, delay: 111)
        await first.value
        let old = NodeLatencyState.measured(try XCTUnwrap(NodeLatencyReading(
            actualMilliseconds: 111, displayRatio: 1
        )))
        XCTAssertEqual(context.model.nodeLatencies[node.id], old)

        let second = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<2_000 {
            if providerProber.calls.count == 2,
               context.model.testingNodeIDs.contains(node.id) { break }
            await Task.yield()
        }
        XCTAssertTrue(context.model.testingNodeIDs.contains(node.id))
        XCTAssertEqual(context.model.nodeLatencies[node.id], old,
                       "A retest must retain the previous reading until replacement")
        providerProber.complete(node.coreName, delay: 222)
        await second.value
        XCTAssertEqual(context.model.nodeLatencies[node.id], .measured(try XCTUnwrap(NodeLatencyReading(
            actualMilliseconds: 222, displayRatio: 1
        ))))
        XCTAssertFalse(context.model.testingNodeIDs.contains(node.id))
    }

    func testFinalLatencyFiftyNineNodesUseRollingTenProviderRequests() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1", nodeCount: 59
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<4_000 {
            if providerProber.calls.count == 10 { break }
            await Task.yield()
        }
        XCTAssertEqual(providerProber.calls.count, 10)
        XCTAssertEqual(providerProber.active, 10)

        for completed in 1...59 {
            let coreName = try XCTUnwrap(providerProber.pendingCoreNames.first)
            providerProber.complete(coreName, delay: completed)
            let expectedCalls = min(59, completed + 10)
            for _ in 0..<4_000 {
                if context.model.nodeLatencyProgress.completed == completed,
                   providerProber.calls.count == expectedCalls { break }
                await Task.yield()
            }
            XCTAssertEqual(context.model.nodeLatencyProgress.completed, completed)
            XCTAssertEqual(providerProber.calls.count, expectedCalls)
            XCTAssertLessThanOrEqual(providerProber.active, 10)
        }
        await batch.value
        XCTAssertEqual(providerProber.calls.count, 59)
        XCTAssertEqual(providerProber.maximumActive, 10, "MAX_OBSERVED_IN_FLIGHT=10")
        XCTAssertEqual(providerProber.active, 0)
        XCTAssertEqual(context.model.nodeLatencies.count, 59)
        XCTAssertTrue(context.model.nodeLatencies.values.allSatisfy {
            if case .measured = $0 { true } else { false }
        })
        let appCalls = await appProber.calls()
        XCTAssertTrue(appCalls.isEmpty)
    }

    func testStep263ASingleFailureDoesNotBlockOtherConnectedResults() async throws {
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeContext(
            connectedNodeProber: providerProber, nodeServer: "1.1.1.1", nodeCount: 3
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<2_000 {
            if providerProber.calls.count == 3 { break }
            await Task.yield()
        }

        providerProber.complete(nodes[0].coreName, delay: 40)
        for _ in 0..<2_000 {
            if context.model.nodeLatencyProgress.completed == 1 { break }
            await Task.yield()
        }
        providerProber.complete(nodes[2].coreName, delay: 60)
        for _ in 0..<2_000 {
            if context.model.nodeLatencyProgress.completed == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(context.model.nodeLatencies[nodes[0].id], .measured(.init(
            actualMilliseconds: 40, displayRatio: 1
        )!))
        XCTAssertEqual(context.model.nodeLatencies[nodes[2].id], .measured(.init(
            actualMilliseconds: 60, displayRatio: 1
        )!))
        XCTAssertTrue(context.model.testingNodeIDs.contains(nodes[1].id))

        providerProber.complete(nodes[1].coreName, status: .failed)
        await batch.value
        XCTAssertEqual(context.model.nodeLatencies[nodes[1].id], .failed)
        XCTAssertEqual(context.model.nodeLatencyProgress.completed, 3)
    }

    func testStep263AConnectedBatchDropsEveryResultAfterCatalogRevisionChanges() async throws {
        let providerProber = ControllableConnectedNodeProber()
        let context = try await makeRefreshContext(
            extraNode: true, connectedNodeProber: providerProber
        )
        defer { removeDefaults(context.suite) }
        let nodes = context.model.nodes.nodes
        let batch = Task { await context.model.testAllNodeLatencies() }
        for _ in 0..<2_000 {
            if providerProber.calls.count == 2 { break }
            await Task.yield()
        }
        await context.fetcher.setYAML(
            Self.refreshFixture(password: "changed-fixture")
                + Self.stage2AOtherFixture
        )
        _ = try await context.repository.refresh(config: config(), session: session())
        for coreName in providerProber.pendingCoreNames {
            providerProber.complete(coreName, delay: 25)
        }
        await batch.value
        XCTAssertTrue(nodes.allSatisfy {
            if case .measured = context.model.nodeLatencies[$0.id] { return false }
            return true
        })
    }

    func testStep261ConnectingLatencyStartsNeitherProbeRuntime() async throws {
        let appProber = RecordingNodeHTTPProber()
        let providerProber = RecordingConnectedNodeProber(state: .connecting)
        let context = try await makeContext(
            nodeProber: appProber, connectedNodeProber: providerProber,
            nodeServer: "1.1.1.1"
        )
        defer { removeDefaults(context.suite) }
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)

        await context.model.testNodeLatency(id)

        let appCalls = await appProber.calls()
        XCTAssertTrue(appCalls.isEmpty)
        XCTAssertTrue(providerProber.calls.isEmpty)
        XCTAssertEqual(context.model.nodeLatencies[id], .unavailable)
    }

    func testStep261ConnectedLateResultCannotEnterChangedCatalog() async throws {
        let providerProber = RecordingConnectedNodeProber(state: .connected)
        let context = try await makeRefreshContext(
            connectedNodeProber: providerProber
        )
        defer { removeDefaults(context.suite) }
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { phase in
            if phase == "single-result" { await gate.pause() }
        }
        let task = Task { await context.model.testNodeLatency(id) }
        await gate.waitForEntry()
        await context.fetcher.setYAML(Self.refreshFixture(password: "changed-fixture"))
        _ = try await context.repository.refresh(config: config(), session: session())
        gate.release()
        await task.value

        if case .measured = context.model.nodeLatencies[id] {
            XCTFail("A connected Provider result cannot enter the changed catalog")
        }
    }
}

private actor ProbePoolTracker {
    private var current = 0
    private var maximum = 0
    private var started = 0

    func probe(_ name: String) async -> NodeProbeOutcome {
        started += 1
        current += 1
        maximum = max(maximum, current)
        let delay: Duration = name == "core-0" ? .milliseconds(250)
            : name == "core-9" ? .milliseconds(5) : .milliseconds(20)
        try? await Task.sleep(for: delay)
        current -= 1
        return name == "core-9" ? .timedOut : .measured(42)
    }

    func slowProbe(_ name: String) async -> NodeProbeOutcome {
        started += 1
        current += 1
        maximum = max(maximum, current)
        try? await Task.sleep(for: .seconds(2))
        current -= 1
        return .measured(42)
    }

    func snapshot() -> (started: Int, maximum: Int) { (started, maximum) }
}

private actor ProbePoolResults {
    private var results: [NodeProbeResult] = []
    func append(_ result: NodeProbeResult) { results.append(result) }
    func values() -> [NodeProbeResult] { results }
}



private struct BootstrapCallCounts: Equatable, Sendable {
    let account: Int
    let plans: Int
    let notices: Int
}

private actor BootstrapSessionVerifier: StoredSessionVerifying {
    private var calls = 0

    func verifyStoredSession(config: AppConfig, session: UserSession) async throws -> UserSession {
        calls += 1
        return session
    }

    func callCount() -> Int { calls }
}

private actor RecoveringConfigTransport: NetworkTransport {
    private var config: AppConfig?

    func succeed(with config: AppConfig) {
        self.config = config
    }

    func data(
        for request: URLRequest,
        kind: NetworkRequestKind
    ) async throws -> (Data, URLResponse) {
        guard kind == .remoteConfiguration, let config else {
            throw URLError(.notConnectedToInternet)
        }
        return (
            try JSONEncoder().encode(config),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private actor BootstrapBusinessAPI: AuthenticatedBusinessDataProviding {
    enum PlanMode: Sendable { case loaded, empty, failure }
    enum NoticeMode: Sendable { case loaded, empty, failure }

    private var accountCalls = 0
    private var planCalls = 0
    private var noticeCalls = 0
    private var planMode = PlanMode.loaded
    private var noticeMode = NoticeMode.loaded
    private var delayNanoseconds: UInt64 = 0
    private var accountResult: UserSession?
    private var heldPlans: (auth: String, gate: CommerceResponseGate)?

    func setAccountResult(_ session: UserSession) { accountResult = session }
    func holdPlans(auth: String) -> CommerceResponseGate {
        let gate = CommerceResponseGate()
        heldPlans = (auth, gate)
        return gate
    }

    func setPlanMode(_ mode: PlanMode) { planMode = mode }
    func setNoticeMode(_ mode: NoticeMode) { noticeMode = mode }
    func setDelayNanoseconds(_ value: UInt64) { delayNanoseconds = value }
    func counts() -> BootstrapCallCounts {
        .init(account: accountCalls, plans: planCalls, notices: noticeCalls)
    }

    func refreshHomeAccount(config: AppConfig, session: UserSession) async throws -> HomeAccountRefreshResult {
        accountCalls += 1
        await delayIfNeeded()
        return HomeAccountRefreshResult(session: accountResult ?? session, resolvedPlanName: session.planName)
    }

    func fetchPlans(config: AppConfig, session: UserSession) async throws -> [PurchasePlan] {
        planCalls += 1
        if let held = heldPlans, held.auth == session.authData {
            heldPlans = nil
            _ = await held.gate.receive()
        }
        await delayIfNeeded()
        switch planMode {
        case .empty:
            return []
        case .failure:
            throw NetworkClientError.transport("fixture network failure")
        case .loaded:
            let accountName = session.email.split(separator: "@").first.map(String.init) ?? "account"
            return [PurchasePlan(
                id: 1,
                name: "\(accountName) plan",
                content: "",
                sort: 1,
                cycles: [.init(period: .month, priceCents: 100)],
                features: []
            )]
        }
    }

    func fetchHomeNotices(config: AppConfig, session: UserSession) async throws -> [HomeNotice] {
        noticeCalls += 1
        await delayIfNeeded()
        switch noticeMode {
        case .empty:
            return []
        case .failure:
            throw NetworkClientError.transport("fixture network failure")
        case .loaded:
            let accountName = session.email.split(separator: "@").first.map(String.init) ?? "account"
            return [HomeNotice(
                id: 1,
                title: "\(accountName) notice",
                content: "<p>Fixture notice</p>",
                imageURL: nil,
                tags: [],
                createdAt: 1
            )]
        }
    }

    private func delayIfNeeded() async {
        guard delayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
}

private actor BootstrapNodeRepository: NodeRepositoryProtocol {
    enum Mode: Sendable { case loaded, empty, parseFailure }

    private var mode = Mode.loaded
    private var calls = 0
    private var delayNanoseconds: UInt64 = 0
    private var current = NodeRepositorySnapshot.empty
    private var currentParsedSubscription: ParsedSubscription?
    private var suspendRefresh = false
    private var refreshGate: CheckedContinuation<Void, Never>?
    private var suspendSelection = false
    private var selectionHasStarted = false
    private var selectionGate: CheckedContinuation<Void, Never>?
    private var preflightAutoSelect = true
    private var preflightCatalogContainsSelectedNode = true
    private var preflightNodeAvailable = true
    private var preflightConfigurationValid = true
    private var preflightMapperSupported = true
    private let server: String
    private let nodeCount: Int

    init(server: String = "example.invalid", nodeCount: Int = 1) {
        self.server = server
        self.nodeCount = nodeCount
    }

    func setMode(_ value: Mode) { mode = value }
    func configurePreflight(
        autoSelect: Bool = true,
        catalogContainsSelectedNode: Bool = true,
        nodeAvailable: Bool = true,
        configurationValid: Bool = true,
        mapperSupported: Bool = true
    ) {
        preflightAutoSelect = autoSelect
        preflightCatalogContainsSelectedNode = catalogContainsSelectedNode
        preflightNodeAvailable = nodeAvailable
        preflightConfigurationValid = configurationValid
        preflightMapperSupported = mapperSupported
    }
    func setDelayNanoseconds(_ value: UInt64) { delayNanoseconds = value }
    func setSuspendRefresh(_ value: Bool) { suspendRefresh = value }
    func resumeRefresh() {
        suspendRefresh = false
        refreshGate?.resume()
        refreshGate = nil
    }
    func setSuspendSelection(_ value: Bool) { suspendSelection = value }
    func selectionStarted() -> Bool { selectionHasStarted }
    func resumeSelection() {
        suspendSelection = false
        selectionGate?.resume()
        selectionGate = nil
    }
    func dropParsedSubscriptionKeepingSnapshot() { currentParsedSubscription = nil }
    func refreshCount() -> Int { calls }
    func snapshot() -> NodeRepositorySnapshot { current }
    func parsedSubscription() -> ParsedSubscription? { currentParsedSubscription }

    func refresh(config: AppConfig, session: UserSession) async throws -> NodeRepositorySnapshot {
        calls += 1
        if suspendRefresh {
            await withCheckedContinuation { refreshGate = $0 }
        }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        switch mode {
        case .empty:
            current = .empty
            currentParsedSubscription = .empty
        case .parseFailure:
            throw SubscriptionParserError.invalidYAML
        case .loaded:
            let accountName = session.email.split(separator: "@").first.map(String.init) ?? "account"
            let allNodes = (0..<nodeCount).map { index in
                let suffix = nodeCount == 1 ? "" : "-\(index)"
                let name = "\(accountName) node\(suffix)"
                return ProxyNode(
                    id: "node-\(accountName)\(suffix)",
                    fingerprint: "fixture-\(accountName)\(suffix)",
                    originalName: name, displayName: name, coreName: name,
                    protocolType: "ss", server: server, port: 443,
                    countryCode: nil, available: preflightNodeAvailable
                )
            }
            let selectedID = preflightAutoSelect ? allNodes.first?.id : nil
            let nodes = preflightCatalogContainsSelectedNode ? allNodes : []
            current = NodeRepositorySnapshot(nodes: nodes, selectedNodeID: selectedID)
            currentParsedSubscription = ParsedSubscription(
                nodes: nodes,
                runtimeProxyRecords: Dictionary(uniqueKeysWithValues: nodes.map { node in
                    let proxy: [String: YAMLValue] = [
                        "name": .string(node.originalName), "type": .string("ss"),
                        "server": .string(server), "port": .integer(443),
                        "cipher": .string(preflightMapperSupported
                            ? "aes-128-gcm" : "synthetic-unsupported"),
                        "password": .string("fixture-only")
                    ]
                    return (node.id, RuntimeProxyRecord(
                        nodeID: node.id, originalName: node.originalName,
                        coreName: node.coreName, originalProxy: proxy,
                        runtimeProxy: preflightConfigurationValid ? proxy : nil,
                        issue: preflightConfigurationValid ? nil : .unresolvedReference(field: "fixture")
                    ))
                })
            )
        }
        return current
    }

    func selectNode(id: String, session: UserSession) async throws -> NodeRepositorySnapshot {
        guard current.nodes.contains(where: { $0.id == id }) else {
            throw NodeRepositoryError.nodeNotFound
        }
        selectionHasStarted = true
        if suspendSelection {
            await withCheckedContinuation { selectionGate = $0 }
        }
        current = NodeRepositorySnapshot(nodes: current.nodes, selectedNodeID: id)
        return current
    }

    func clear() {
        current = .empty
        currentParsedSubscription = nil
    }
}

private struct StagedSubscriptionInfo: CurrentSubscriptionInfoProviding {
    func fetchCurrentSubscriptionInfo(config: AppConfig, session: UserSession) async throws -> CurrentSubscriptionInfo {
        CurrentSubscriptionInfo(subscriptionURL: "https://example.invalid/fixture")
    }
}

private actor StagedSubscriptionFetcher: SubscriptionFetching {
    private var downloads = 0
    private var fails = false
    private var yaml = """
    proxies:
      - name: Fixture Node
        type: ss
        server: 198.51.100.10
        port: 443
        cipher: aes-128-gcm
        password: initial-fixture
    """

    func setYAML(_ value: String) { yaml = value }
    func setFailure(_ value: Bool) { fails = value }
    func fetchCount() -> Int { downloads }
    func fetchSubscription(from rawURL: String, userAgent: String, builtInProxy: [String]) async throws -> String {
        downloads += 1
        if fails { throw SubscriptionFetchError.missingSubscriptionURL }
        return yaml
    }
}

@MainActor
final class NodeCoordinatorTests: XCTestCase {
    func testRepositorySelectionCommitsWithoutSuspension() async throws {
        let context = try await makeRepositorySelectionContext()
        let selected = try await context.repository.selectNode(id: context.second, session: context.account)
        XCTAssertEqual(selected.selectedNodeID, context.second)
        XCTAssertEqual(selected.nodes, context.initial.nodes)
        let snapshot = await context.repository.snapshot()
        let saved = await context.store.loadSelectedNodeID(accountScope: context.scope)
        XCTAssertEqual(snapshot, selected)
        XCTAssertEqual(saved, context.second)
    }

    func testRepositorySelectionDiscardsCompletionAfterClear() async throws {
        let context = try await makeRepositorySelectionContext()
        let selection = await pauseRepositorySelection(context)
        await context.repository.clear()
        await context.store.resumeSave()
        await assertStaleSelection(selection)
        let snapshot = await context.repository.snapshot()
        let parsed = await context.repository.parsedSubscription()
        XCTAssertEqual(snapshot, .empty)
        XCTAssertNil(parsed)
    }

    func testRepositorySelectionDiscardsOldAccountCompletion() async throws {
        let context = try await makeRepositorySelectionContext()
        let selection = await pauseRepositorySelection(context)
        await context.repository.clear()
        let otherAccount = repositorySelectionAccount(email: "other@example.invalid")
        let otherScope = try XCTUnwrap(otherAccount.nodeSelectionAccountScope)
        await context.fetcher.setYAML(repositorySelectionFixture(prefix: "Other account"))
        let refreshed = try await context.repository.refresh(config: context.config, session: otherAccount)
        let otherNode = try XCTUnwrap(refreshed.nodes.first?.id)
        let otherSelection = try await context.repository.selectNode(id: otherNode, session: otherAccount)
        await context.store.resumeSave()
        await assertStaleSelection(selection)
        let snapshot = await context.repository.snapshot()
        let parsed = await context.repository.parsedSubscription()
        let saved = await context.store.loadSelectedNodeID(accountScope: otherScope)
        XCTAssertEqual(snapshot, otherSelection)
        XCTAssertEqual(parsed?.nodes, otherSelection.nodes)
        XCTAssertEqual(saved, otherNode)
    }

    func testRepositorySelectionDiscardsCompletionAfterRefresh() async throws {
        let context = try await makeRepositorySelectionContext()
        let selection = await pauseRepositorySelection(context)
        await context.fetcher.setYAML(repositorySelectionFixture(prefix: "Refreshed"))
        let refreshed = try await context.repository.refresh(config: context.config, session: context.account)
        await context.store.resumeSave()
        await assertStaleSelection(selection)
        let snapshot = await context.repository.snapshot()
        let parsed = await context.repository.parsedSubscription()
        XCTAssertEqual(snapshot, refreshed)
        XCTAssertEqual(parsed?.nodes, refreshed.nodes)
    }

    func testRepositorySelectionDiscardsCompletionAfterRefreshGenerationStarts() async throws {
        let context = try await makeRepositorySelectionContext()
        let selection = await pauseRepositorySelection(context)
        await context.fetcher.setYAML(repositorySelectionFixture(prefix: "Staged"))
        let prepared = try await context.repository.prepareRefresh(config: context.config, session: context.account)
        let beforeCompletion = await context.repository.snapshot()
        XCTAssertEqual(beforeCompletion, context.initial)
        await context.store.resumeSave()
        await assertStaleSelection(selection)
        let afterCompletion = await context.repository.snapshot()
        XCTAssertEqual(afterCompletion, context.initial)
        let committed = try await context.repository.commitRefresh(prepared)
        XCTAssertEqual(committed, prepared.snapshot)
    }

    func testRepositorySelectionCommitsAfterSuspensionWithSameAccountAndGeneration() async throws {
        let context = try await makeRepositorySelectionContext()
        let selection = await pauseRepositorySelection(context)
        let suspended = await context.repository.snapshot()
        XCTAssertEqual(suspended, context.initial)
        await context.store.resumeSave()
        let selected = try await selection.value
        let snapshot = await context.repository.snapshot()
        let saved = await context.store.loadSelectedNodeID(accountScope: context.scope)
        XCTAssertEqual(selected.selectedNodeID, context.second)
        XCTAssertEqual(selected.nodes, context.initial.nodes)
        XCTAssertEqual(snapshot, selected)
        XCTAssertEqual(saved, context.second)
    }

    func testRepositorySelectionDiscardsOlderCompletionAfterNewerChoice() async throws {
        let context = try await makeRepositorySelectionContext()
        let selection = await pauseRepositorySelection(context)
        let newer = try await context.repository.selectNode(id: context.third, session: context.account)
        await context.store.resumeSave()
        await assertStaleSelection(selection)
        let snapshot = await context.repository.snapshot()
        let saved = await context.store.loadSelectedNodeID(accountScope: context.scope)
        XCTAssertEqual(snapshot, newer)
        XCTAssertEqual(snapshot.selectedNodeID, context.third)
        XCTAssertEqual(saved, context.third)
    }

    private struct RepositorySelectionContext {
        let repository: NodeRepository
        let store: PausingNodeSelectionStore
        let fetcher: StagedSubscriptionFetcher
        let config: AppConfig
        let account: UserSession
        let scope: NodeSelectionAccountScope
        let initial: NodeRepositorySnapshot
        let second: String
        let third: String
    }

    private func makeRepositorySelectionContext() async throws -> RepositorySelectionContext {
        let config = AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "NetworkClientTests/1", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: ["https://example.invalid"],
            activeAPIBaseURL: "https://example.invalid", builtInProxy: []
        )
        let account = repositorySelectionAccount(email: "account@example.invalid")
        let scope = try XCTUnwrap(account.nodeSelectionAccountScope)
        let store = PausingNodeSelectionStore()
        let fetcher = StagedSubscriptionFetcher()
        await fetcher.setYAML(repositorySelectionFixture(prefix: "Initial"))
        let repository = NodeRepository(
            subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: fetcher, selectionStore: store
        )
        let refreshed = try await repository.refresh(config: config, session: account)
        let first = try XCTUnwrap(refreshed.nodes.first?.id)
        let second = try XCTUnwrap(refreshed.nodes.dropFirst().first?.id)
        let third = try XCTUnwrap(refreshed.nodes.dropFirst(2).first?.id)
        let initial = try await repository.selectNode(id: first, session: account)
        return RepositorySelectionContext(repository: repository, store: store, fetcher: fetcher,
            config: config, account: account, scope: scope, initial: initial, second: second, third: third)
    }

    private func repositorySelectionAccount(email: String) -> UserSession {
        UserSession(email: email, authData: "isolated-fixture-auth", accountToken: nil,
            subscriptionURL: "https://example.invalid/sub", uploadBytes: 0, downloadBytes: 0,
            transferEnableBytes: 0, expiredAt: 0, planID: nil, planName: "", balanceCents: nil,
            verifiedAt: Date())
    }

    private func repositorySelectionFixture(prefix: String) -> String {
        "proxies:\n" + (1...3).map { index in
            """
              - {name: \(prefix) \(index), type: ss, server: 198.51.100.\(index), port: 443,
                 cipher: aes-128-gcm, password: synthetic-\(prefix)-\(index)}

            """
        }.joined()
    }

    private func pauseRepositorySelection(
        _ context: RepositorySelectionContext
    ) async -> Task<NodeRepositorySnapshot, Error> {
        let paused = XCTestExpectation(description: "Selection save suspended before completion")
        await context.store.pauseNextSave(notifying: paused)
        let selection = Task {
            try await context.repository.selectNode(id: context.second, session: context.account)
        }
        let result = await XCTWaiter.fulfillment(of: [paused], timeout: 5)
        XCTAssertEqual(result, .completed)
        if result != .completed { await context.store.resumeSave() }
        return selection
    }

    private func assertStaleSelection(_ selection: Task<NodeRepositorySnapshot, Error>) async {
        switch await selection.result {
        case .success: XCTFail("A superseded selection must not report a committed snapshot")
        case let .failure(error): XCTAssertTrue(error is CancellationError)
        }
    }


    func testLatencyCancellationRestoresOnlyUnfinishedReadings() {
        let coordinator = NodeLatencyCoordinator()
        let prior = NodeLatencyState.measured(NodeLatencyReading(
            actualMilliseconds: 47, displayRatio: 2
        )!)
        coordinator.replaceReadings(["one": prior])
        let generation = coordinator.begin()
        XCTAssertNotNil(generation)
        coordinator.replaceReadings(["one": .testing, "two": .testing,
                                     "three": .measured(NodeLatencyReading(
                                        actualMilliseconds: 20, displayRatio: 1
                                     )!)])
        XCTAssertTrue(coordinator.cancelActive())
        XCTAssertEqual(coordinator.readings["one"], prior)
        XCTAssertNil(coordinator.readings["two"])
        XCTAssertNotNil(coordinator.readings["three"])
        XCTAssertNotEqual(coordinator.generation, generation)
        coordinator.finish(generation: generation!)
        XCTAssertFalse(coordinator.active)
    }
}

private actor PausingNodeSelectionStore: NodeSelectionStoreProtocol {
    private var saved: [NodeSelectionAccountScope: String] = [:]
    private var pauseNotification: XCTestExpectation?
    private var pausedSave: CheckedContinuation<Void, Never>?

    func loadSelectedNodeID(accountScope: NodeSelectionAccountScope) -> String? { saved[accountScope] }

    func pauseNextSave(notifying expectation: XCTestExpectation) { pauseNotification = expectation }

    func saveSelectedNodeID(_ selectedNodeID: String, accountScope: NodeSelectionAccountScope) async {
        // Production storage writes synchronously on its actor. Delay only
        // completion so newer writes retain the same persistence ordering.
        saved[accountScope] = selectedNodeID
        guard let notification = pauseNotification else { return }
        pauseNotification = nil
        await withCheckedContinuation { continuation in
            pausedSave = continuation
            notification.fulfill()
        }
    }

    func resumeSave() {
        pauseNotification = nil
        let continuation = pausedSave
        pausedSave = nil
        continuation?.resume()
    }
}


@MainActor
final class CommerceAccountIsolationTests: XCTestCase {
    func testCreateOrderLateSuccessAfterLogout() async throws { try await assertLateLogout(.create) }
    func testCreateOrderLateSuccessAfterAccountSwitch() async throws { try await assertStaleResult(.create) }
    func testCheckoutLateSuccessAfterLogout() async throws { try await assertLateLogout(.checkout) }
    func testCheckoutLateSuccessAfterAccountSwitch() async throws { try await assertStaleResult(.checkout) }
    func testCheckOrderLateSuccessAfterLogout() async throws { try await assertLateLogout(.check) }
    func testCheckOrderLateSuccessAfterAccountSwitch() async throws { try await assertStaleResult(.check) }

    // This exact method also runs against the original production sources.
    func testOld401AfterSwitchDoesNotInvalidateNewSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        let b = fixture.session("B")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.methods, auth: a.authData)
        let old = Task {
            await fixture.model.perform {
                _ = try await fixture.api.fetchPaymentMethods(config: fixture.config, session: a)
            }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(fixture.model.busy)
        await fixture.model.signOut()
        XCTAssertNil(fixture.model.session, "Logout must work while a request is suspended")
        let bGeneration = UUID()
        let bReplaced = try await fixture.sessions.replace(
            b,
            generation: bGeneration,
            replacing: nil
        )
        XCTAssertTrue(bReplaced)
        await fixture.model.establishAuthenticatedSession(
            b,
            source: .login,
            generation: bGeneration
        )
        let before = CommerceVisibleState(fixture.model)
        await gate.resume(.unauthorized)
        _ = await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let saved = try await fixture.sessions.read()
        XCTAssertEqual(saved, b)
        let requests = await fixture.state.count(.methods, auth: a.authData)
        let starts = await fixture.runtime.starts
        XCTAssertEqual(requests, 1, "401 must not fail over or retry")
        XCTAssertEqual(starts, 0, "401 must not enter BuiltInProxy")
    }

    func testCurrent401StillInvalidatesSessionAndBusinessState() async throws {
        for operation in [CommerceHeldOperation.create, .checkout, .check] {
            let fixture = try await makeFixture()
            defer { fixture.cleanUp() }
            let b = try await fixture.switchToSeededB()
            XCTAssertFalse(fixture.model.orders.isEmpty)
            XCTAssertFalse(fixture.model.nodes.nodes.isEmpty)
            XCTAssertNotNil(fixture.model.checkout)
            let priorRequests = await fixture.state.count(operation, auth: b.authData)
            let gate = await fixture.state.hold(operation, auth: b.authData)
            let current = Task { await operation.invoke(fixture.model) }
            await fulfillment(of: [gate.entered], timeout: 2)
            await gate.resume(.unauthorized)
            await current.value
            XCTAssertNil(fixture.model.session)
            XCTAssertTrue(fixture.model.orders.isEmpty)
            XCTAssertTrue(fixture.model.nodes.nodes.isEmpty)
            XCTAssertTrue(fixture.model.plans.isEmpty)
            XCTAssertNil(fixture.model.checkout)
            XCTAssertEqual(fixture.model.authMessage, .localized(L10nKey.errorAuthenticationExpired))
            XCTAssertFalse(fixture.model.busy)
            let saved = try await fixture.sessions.read()
            let requests = await fixture.state.count(operation, auth: b.authData)
            let starts = await fixture.runtime.starts
            XCTAssertNil(saved)
            XCTAssertEqual(requests, priorRequests + 1)
            XCTAssertEqual(starts, 0)
        }
    }

    func testOldBusinessErrorDoesNotOverwriteNewAccountMessage() async throws {
        try await assertStaleResult(.checkout, response: .init(status: 400,
            body: #"{"message":"Synthetic A business error","data":false}"#))
    }
    func testOld429DoesNotOverwriteNewAccountMessage() async throws {
        try await assertStaleResult(.checkout, response: .init(status: 429,
            body: #"{"message":"Synthetic A rate limit"}"#))
    }
    func testOldInvalidResponseDoesNotOverwriteNewAccountMessage() async throws {
        try await assertStaleResult(.invite, response: .init(body: #"{"data":null}"#))
    }
    func testOldCommerce401DoesNotInvalidateNewAccount() async throws {
        for operation in [CommerceHeldOperation.create, .checkout, .check] {
            try await assertStaleResult(operation, response: .unauthorized)
        }
    }
    func testOldUnknownWriteResponseDoesNotOverwriteNewAccountMessage() async throws {
        try await assertStaleResult(.create, response: .init(body: "{}"))
    }

    func testCreateOrderFollowupReadCannotOverwriteNewAccount() async throws {
        try await assertLateFollowupRead(.create)
    }
    func testCheckOrderFollowupReadCannotOverwriteNewAccount() async throws {
        try await assertLateFollowupRead(.check)
    }
    func testOldOrderList401DoesNotInvalidateNewAccount() async throws {
        try await assertStaleResult(.orders, response: .unauthorized)
    }
    func testOldPaymentMethods401DoesNotInvalidateNewAccount() async throws {
        try await assertStaleResult(.methods, response: .unauthorized)
    }
    func testOldInvite401DoesNotInvalidateNewAccount() async throws {
        try await assertStaleResult(.invite, response: .unauthorized)
    }

    func testOldBusyCompletionCannotReleaseNewAccountBusyState() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        let b = fixture.session("B")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let aGate = await fixture.state.hold(.create, auth: a.authData)
        let old = Task { await CommerceHeldOperation.create.invoke(fixture.model) }
        await fulfillment(of: [aGate.entered], timeout: 2)
        await fixture.model.signOut()
        await fixture.model.establishAuthenticatedSession(b, source: .login)
        let bGate = await fixture.state.hold(.checkout, auth: b.authData)
        let current = Task { await CommerceHeldOperation.checkout.invoke(fixture.model) }
        await fulfillment(of: [bGate.entered], timeout: 2)
        XCTAssertTrue(fixture.model.busy)
        await aGate.resume(.success(.create, account: "A"))
        await old.value
        XCTAssertTrue(fixture.model.busy, "A completion must not clear B's busy state")
        XCTAssertTrue(fixture.model.showsGlobalBusyIndicator)
        await bGate.resume(.success(.checkout, account: "B"))
        await current.value
        XCTAssertFalse(fixture.model.busy)
        XCTAssertEqual(fixture.model.checkout?.result, PurchaseCheckoutResult(
            type: 1, data: "https://payments.example.invalid/B"))
    }

    func testNewGenerationWithSameAccountAndCredentialDiscardsOldResult() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.create, auth: a.authData)
        let old = Task { await CommerceHeldOperation.create.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await fixture.model.establishAuthenticatedSession(a, source: .restored)
        fixture.model.message = .verbatim("new generation")
        let before = CommerceVisibleState(fixture.model)
        await gate.resume(.success(.create, account: "A"))
        await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let pending = await fixture.payments.payment(for: a)
        XCTAssertNil(pending)
    }

    func testAuthReplacementWithoutGenerationChangeDiscardsOldResult() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.create, auth: a.authData)
        let old = Task { await CommerceHeldOperation.create.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replacement = fixture.session("A", auth: "synthetic-A-replacement")
        await fixture.business.setAccountResult(replacement)
        await fixture.model.refreshAccount()
        XCTAssertEqual(fixture.model.session?.authData, replacement.authData)
        await gate.resume(.success(.create, account: "A"))
        await old.value
        XCTAssertTrue(fixture.model.orders.isEmpty)
        XCTAssertNil(fixture.model.message)
        XCTAssertFalse(fixture.model.busy)
        let pending = await fixture.payments.payment(for: replacement)
        XCTAssertNil(pending)
    }

    func testMetadataRefreshDoesNotDiscardCurrentAccountResult() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.create, auth: a.authData)
        let operation = Task { await CommerceHeldOperation.create.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await fixture.business.setAccountResult(a.applyingUserInfo(email: nil, balanceCents: 999))
        await fixture.model.refreshAccount()
        await gate.resume(.success(.create, account: "A"))
        await operation.value
        XCTAssertEqual(fixture.model.session?.balanceCents, 999)
        XCTAssertEqual(fixture.model.orders.map(\.tradeNo), ["A-order"])
        XCTAssertNil(fixture.model.message)
        let pending = await fixture.payments.payment(for: a)
        XCTAssertEqual(pending?.tradeNo, "A-created")
    }

    func testCommerceReadsDiscardSuccessAnd401AfterCredentialReplacement() async throws {
        for operation in [CommerceHeldOperation.orders, .methods, .invite] {
            for unauthorized in [false, true] {
                let fixture = try await makeFixture()
                defer { fixture.cleanUp() }
                let a = fixture.session("A")
                await fixture.model.establishAuthenticatedSession(a, source: .login)
                let gate = await fixture.state.hold(operation, auth: a.authData)
                let old = Task { await operation.invoke(fixture.model) }
                await fulfillment(of: [gate.entered], timeout: 2)
                let replacement = fixture.session("A", auth: "synthetic-A-replacement")
                await fixture.business.setAccountResult(replacement)
                await fixture.model.refreshAccount()
                XCTAssertEqual(fixture.model.session?.authData, replacement.authData)
                let before = CommerceVisibleState(fixture.model)
                await gate.resume(unauthorized ? .unauthorized : .success(operation, account: "A"))
                await old.value
                // The suspended operation still owns busy in this generation,
                // but cannot publish data, load state, or 401 feedback.
                XCTAssertEqual(fixture.model.session, before.session)
                XCTAssertEqual(fixture.model.orders, before.orders)
                XCTAssertEqual(fixture.model.paymentMethods, before.methods)
                XCTAssertEqual(fixture.model.invitations, before.invitations)
                XCTAssertEqual(fixture.model.authMessage, before.authMessage)
                XCTAssertEqual(CommerceVisibleState(fixture.model).loadStates, before.loadStates)
                XCTAssertFalse(fixture.model.busy)
            }
        }
    }

    func testOldCommercePlanRefreshCannotStartNewAccountOrderRead() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.business.holdPlans(auth: a.authData)
        let old = Task { await fixture.model.loadCommerce() }
        await fulfillment(of: [gate.entered], timeout: 2)
        _ = try await fixture.switchToSeededB()
        let before = CommerceVisibleState(fixture.model)
        let calls = await fixture.state.calls
        await gate.resume(.init(body: "{}"))
        await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let after = await fixture.state.calls
        XCTAssertEqual(after, calls, "A's plan refresh must not initiate B's order request")
    }

    func testCurrentCommerceActivatingStatusPreservesPendingPaymentAndCheckSemantics() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        await CommerceHeldOperation.create.invoke(fixture.model)
        let pending = await fixture.payments.payment(for: a)
        XCTAssertEqual(pending?.tradeNo, "A-created")
        await fixture.model.beginCheckout(trade: "A-created", method: 1)
        XCTAssertEqual(fixture.model.checkout?.data, "https://payments.example.invalid/A")
        await fixture.model.checkOrder("A-created")
        let retained = await fixture.payments.payment(for: a)
        XCTAssertNotNil(retained)
        XCTAssertEqual(fixture.model.orders.map(\.tradeNo), ["A-order"])
        XCTAssertEqual(fixture.model.message, .localized(AppModel.orderStatusKey(1)))
    }

    func testCurrentBusinessErrorStillReachesUser() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.checkout, auth: a.authData)
        let operation = Task { await CommerceHeldOperation.checkout.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await gate.resume(.init(status: 400,
            body: #"{"message":"Synthetic current business error","data":false}"#))
        await operation.value
        XCTAssertNotNil(fixture.model.message)
        XCTAssertEqual(fixture.model.session, a)
        XCTAssertFalse(fixture.model.busy)
    }

    func testSessionReplacementAndLogoutClearPublishedAccountMessage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        let b = fixture.session("B")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        fixture.model.message = .verbatim("A account feedback")

        await fixture.model.establishAuthenticatedSession(b, source: .login)
        XCTAssertNil(fixture.model.message)

        fixture.model.message = .verbatim("B account feedback")
        await fixture.model.signOut()
        XCTAssertNil(fixture.model.message)
    }

    func testBuiltInProxyLate200AfterSwitchCannotPublishIntoNewAccount() async throws {
        try await assertRecoveryResultAfterSwitch(
            .success(.methods, account: "A"),
            expectedAuthenticated: true
        )
    }

    func testBuiltInProxyStale401AfterSwitchCannotLogoutNewAccount() async throws {
        try await assertRecoveryResultAfterSwitch(.unauthorized, expectedAuthenticated: true)
    }

    func testHostRetryAfterSwitchKeepsOriginalCapturedCredentials() async throws {
        let fixture = try await Step3RetryFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        let b = fixture.session("B")
        try await fixture.establishPersisted(a)
        let old = Task { await fixture.model.loadPaymentMethods() }
        await fulfillment(of: [fixture.state.firstAttempt.entered], timeout: 2)
        try await fixture.switchAccount(to: b)
        let before = CommerceVisibleState(fixture.model)
        await fixture.state.firstAttempt.resume()
        await old.value

        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let calls = await fixture.state.calls
        XCTAssertEqual(calls.map(\.host), ["first.api.invalid", "second.api.invalid"])
        XCTAssertEqual(Set(calls.compactMap(\.auth)), [a.authData])
        XCTAssertFalse(calls.contains { $0.auth == b.authData })
    }

    func testPaymentLateFailureAfterSwitchCannotPublishIntoNewAccount() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.checkout, auth: a.authData)
        let old = Task { await fixture.model.beginCheckout(trade: "shared-trade", method: 1) }
        await fulfillment(of: [gate.entered], timeout: 2)
        _ = try await fixture.switchToSeededB()
        let before = CommerceVisibleState(fixture.model)

        await gate.resume(.init(
            status: 400,
            body: #"{"message":"Synthetic payment rejection","data":false}"#
        ))
        await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
    }

    func testCheckoutOutcomeIsBoundToItsTrade() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let account = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(account, source: .login)

        guard let checkout = await fixture.model.beginCheckout(
            trade: "trade-A",
            method: 1
        ) else { return XCTFail("Expected an owned checkout") }

        XCTAssertEqual(checkout.tradeNo, "trade-A")
        XCTAssertTrue(fixture.model.isCurrentCheckout(checkout, tradeNo: "trade-A"))
        XCTAssertEqual(fixture.model.currentCheckout(for: "trade-A"), checkout)
        XCTAssertNil(fixture.model.currentCheckout(for: "trade-B"))
        XCTAssertFalse(fixture.model.isCurrentCheckout(checkout, tradeNo: "trade-B"))
    }

    func testNewCheckoutOperationInvalidatesPriorOutcomeForSameTrade() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let account = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(account, source: .login)

        guard let first = await fixture.model.beginCheckout(
            trade: "shared-trade",
            method: 1
        ), let second = await fixture.model.beginCheckout(
            trade: "shared-trade",
            method: 2
        ) else { return XCTFail("Expected two definite checkout outcomes") }

        XCTAssertNotEqual(first.operationID, second.operationID)
        XCTAssertFalse(fixture.model.isCurrentCheckout(first, tradeNo: "shared-trade"))
        XCTAssertTrue(fixture.model.isCurrentCheckout(second, tradeNo: "shared-trade"))
        XCTAssertEqual(fixture.model.currentCheckout(for: "shared-trade"), second)
    }

    func testLateCheckoutFromAccountACannotBeConsumedByAccountB() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.checkout, auth: a.authData)
        let old = Task {
            await fixture.model.beginCheckout(trade: "A-trade", method: 1)
        }
        await fulfillment(of: [gate.entered], timeout: 2)

        let b = try await fixture.switchToSeededB()
        let bCheckout = try XCTUnwrap(fixture.model.currentCheckout(for: "B-order"))
        await gate.resume(.success(.checkout, account: "A"))
        let oldOutcome = await old.value

        XCTAssertNil(oldOutcome)
        XCTAssertEqual(fixture.model.session, b)
        XCTAssertEqual(fixture.model.currentCheckout(for: "B-order"), bCheckout)
        XCTAssertNil(fixture.model.currentCheckout(for: "A-trade"))
    }

    func testSameAccountNewSessionCannotConsumeOldCheckout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let original = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(original, source: .login)
        guard let old = await fixture.model.beginCheckout(
            trade: "shared-trade",
            method: 1
        ) else { return XCTFail("Expected the original checkout") }

        let replacement = fixture.session("A", auth: "synthetic-A-new-session")
        await fixture.model.establishAuthenticatedSession(replacement, source: .login)

        XCTAssertEqual(fixture.model.checkout?.operationID, old.operationID)
        XCTAssertFalse(fixture.model.isCurrentCheckout(old, tradeNo: "shared-trade"))
        XCTAssertNil(fixture.model.currentCheckout(for: "shared-trade"))
        guard let current = await fixture.model.beginCheckout(
            trade: "shared-trade",
            method: 2
        ) else { return XCTFail("Expected the replacement-session checkout") }
        XCTAssertTrue(fixture.model.isCurrentCheckout(current, tradeNo: "shared-trade"))
        XCTAssertNotEqual(current.operationID, old.operationID)
    }

    func testPaymentStatusSingleFlightSeparatesCredentialReplacement() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let original = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(original, source: .login)
        let generation = fixture.model.commerceRecoveryGeneration
        let oldGate = await fixture.state.hold(.check, auth: original.authData)
        let old = Task {
            await fixture.model.checkPaymentStatus(trade: "shared-trade")
        }
        await fulfillment(of: [oldGate.entered], timeout: 2)

        let replacement = fixture.session("A", auth: "synthetic-A-replacement")
        await fixture.business.setAccountResult(replacement)
        await fixture.model.refreshAccount()
        XCTAssertEqual(fixture.model.commerceRecoveryGeneration, generation)
        XCTAssertEqual(fixture.model.session?.authData, replacement.authData)

        let newGate = await fixture.state.hold(.check, auth: replacement.authData)
        let current = Task {
            await fixture.model.checkPaymentStatus(trade: "shared-trade")
        }
        await fulfillment(of: [newGate.entered], timeout: 2)
        await newGate.resume(.init(body: #"{"data":1}"#))
        await oldGate.resume(.init(body: #"{"data":3}"#))

        let currentResult = await current.value
        let oldResult = await old.value
        let originalChecks = await fixture.state.count(.check, auth: original.authData)
        let replacementChecks = await fixture.state.count(.check, auth: replacement.authData)
        XCTAssertEqual(currentResult, .status(.activating))
        XCTAssertEqual(oldResult, .cancelled)
        XCTAssertEqual(originalChecks, 1)
        XCTAssertEqual(replacementChecks, 1)
    }

    func testSubmittedCreateIsNotReplayedAfterAccountSwitch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.create, auth: a.authData)
        let old = Task { await CommerceHeldOperation.create.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        _ = try await fixture.switchToSeededB()
        await gate.resume(.success(.create, account: "A"))
        await old.value

        let createCount = await fixture.state.count(.create, auth: a.authData)
        XCTAssertEqual(createCount, 1)
    }

    func testSingleSceneActivationCheckIssuesOneCurrentSessionStatusRead() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)

        await fixture.model.checkOrder("shared-trade")

        let checkCount = await fixture.state.count(.check, auth: a.authData)
        XCTAssertEqual(checkCount, 1)
    }

    func testOrderAndInvitationReadsKeepRootBusyOverlayHidden() async throws {
        for operation in [CommerceHeldOperation.orders, .invite] {
            let fixture = try await makeFixture()
            let account = fixture.session("A")
            await fixture.model.establishAuthenticatedSession(account, source: .login)
            let gate = await fixture.state.hold(operation, auth: account.authData)
            let task = Task { await operation.invoke(fixture.model) }

            await fulfillment(of: [gate.entered], timeout: 2)
            XCTAssertTrue(fixture.model.busy)
            XCTAssertFalse(fixture.model.showsGlobalBusyIndicator)

            await gate.resume(.success(operation, account: "A"))
            await task.value
            XCTAssertFalse(fixture.model.busy)
            XCTAssertFalse(fixture.model.showsGlobalBusyIndicator)
            fixture.cleanUp()
        }
    }

    func testPurchaseModalFromAccountACannotCreateWithAccountBSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let cycle = PurchasePlanCycle(period: .month, priceCents: 100)
        let plan = PurchasePlan(
            id: 1, name: "A Plan", content: "", sort: 1,
            cycles: [cycle], features: []
        )
        let context = CommerceOperationContext(model: fixture.model)
        let presenter = GlobalModalPresenter()
        let flow = Task {
            let choice = await presenter.present(PurchaseOrderModalPresentation.request(
                plan: plan,
                cycle: cycle,
                locale: Locale(identifier: "en")
            ))
            guard let submission = PurchaseOrderModalPresentation.submission(for: choice) else {
                return
            }
            _ = await context.performIfCurrent(in: fixture.model) {
                await fixture.model.createOrder(
                    plan: plan,
                    cycle: cycle,
                    couponCode: submission.couponCode
                )
            }
        }
        await waitForModal(presenter)
        let b = try await fixture.switchToSeededB()
        let before = await fixture.state.count(.create, auth: b.authData)
        XCTAssertTrue(presenter.resolve(
            .purchaseOrder(couponCode: nil),
            requestID: presenter.activeRequest?.id
        ))
        await flow.value

        let aCreates = await fixture.state.count(.create, auth: a.authData)
        let bCreates = await fixture.state.count(.create, auth: b.authData)
        XCTAssertEqual(aCreates, 0)
        XCTAssertEqual(bCreates, before)
    }

    func testPaymentMethodsCompletionFromAccountADoesNotPresentForAccountB() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let tradeNo = "A-trade"
        let context = CommerceOperationContext(model: fixture.model, tradeNo: tradeNo)
        let presenter = GlobalModalPresenter()
        let gate = await fixture.state.hold(.methods, auth: a.authData)
        let flow = Task {
            await fixture.model.loadPaymentMethods()
            guard context.isCurrent(in: fixture.model, tradeNo: tradeNo) else { return }
            _ = await presenter.present(PaymentMethodModalPresentation.request(
                detail: self.paymentDetail(tradeNo: tradeNo),
                methods: fixture.model.paymentMethods,
                locale: Locale(identifier: "en")
            ))
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        let b = try await fixture.switchToSeededB()
        let checkoutBefore = await fixture.state.count(.checkout, auth: b.authData)
        await gate.resume(.success(.methods, account: "A"))
        await flow.value

        XCTAssertNil(presenter.activeRequest)
        let bCheckouts = await fixture.state.count(.checkout, auth: b.authData)
        XCTAssertEqual(bCheckouts, checkoutBefore)
    }

    func testCancelModalFromAccountACannotCancelWithAccountBSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let tradeNo = "A-trade"
        let context = CommerceOperationContext(model: fixture.model, tradeNo: tradeNo)
        let presenter = GlobalModalPresenter()
        let flow = Task {
            let choice = await presenter.present(.orderCancellation())
            guard PurchaseOrderCancellationPresentation.shouldCancel(
                choice: choice,
                status: .pending
            ) else { return }
            _ = await context.performIfCurrent(
                in: fixture.model,
                tradeNo: tradeNo
            ) {
                await fixture.model.cancelPendingOrder(trade: tradeNo)
            }
        }
        await waitForModal(presenter)
        let b = try await fixture.switchToSeededB()
        let before = await fixture.state.count(.cancel, auth: b.authData)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        await flow.value

        let aCancels = await fixture.state.count(.cancel, auth: a.authData)
        let bCancels = await fixture.state.count(.cancel, auth: b.authData)
        XCTAssertEqual(aCancels, 0)
        XCTAssertEqual(bCancels, before)
    }

    func testCommerceContextRejectsSameAccountNewSessionAndWrongTradeBeforeAPI() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let accountContext = CommerceOperationContext(model: fixture.model)
        let tradeContext = CommerceOperationContext(model: fixture.model, tradeNo: "A-trade")

        let wrongTrade = await tradeContext.performIfCurrent(
            in: fixture.model,
            tradeNo: "B-trade"
        ) {
            await fixture.model.beginCheckout(trade: "B-trade", method: 1)
        }
        XCTAssertNil(wrongTrade)
        let oldCheckouts = await fixture.state.count(.checkout, auth: a.authData)
        XCTAssertEqual(oldCheckouts, 0)

        let replacement = fixture.session("A", auth: "synthetic-A-new-session")
        await fixture.model.establishAuthenticatedSession(replacement, source: .login)
        let staleAccount: Void? = await accountContext.performIfCurrent(in: fixture.model) {
            await CommerceHeldOperation.create.invoke(fixture.model)
        }
        XCTAssertNil(staleAccount)
        let replacementCreates = await fixture.state.count(.create, auth: replacement.authData)
        XCTAssertEqual(replacementCreates, 0)
    }

    private func waitForModal(_ presenter: GlobalModalPresenter) async {
        for _ in 0..<100 where presenter.activeRequest == nil { await Task.yield() }
        XCTAssertNotNil(presenter.activeRequest)
    }

    private func paymentDetail(tradeNo: String) -> PurchaseOrderDetail {
        PurchaseOrderDetail(
            tradeNo: tradeNo,
            status: 0,
            checkoutType: nil,
            planID: 1,
            planName: "A Plan",
            period: "month_price",
            planPriceCents: 100,
            totalAmountCents: 100,
            discountAmountCents: 0,
            surplusAmountCents: 0,
            balanceAmountCents: 0,
            refundAmountCents: 0,
            handlingAmountCents: 0
        )
    }

    private func assertRecoveryResultAfterSwitch(
        _ response: CommerceFixtureResponse,
        expectedAuthenticated: Bool
    ) async throws {
        let fixture = try await Step3RecoveryFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        let b = fixture.session("B")
        try await fixture.establishPersisted(a)
        let old = Task { await fixture.model.loadPaymentMethods() }
        await fulfillment(of: [fixture.state.recoveryResponse.entered], timeout: 2)
        try await fixture.switchAccount(to: b)
        fixture.model.message = .verbatim("B current message")
        let before = CommerceVisibleState(fixture.model)

        await fixture.state.recoveryResponse.resume(response)
        await old.value

        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        XCTAssertEqual(fixture.model.session == b, expectedAuthenticated)
        let persisted = try await fixture.sessions.read()
        XCTAssertEqual(persisted, b)
        let calls = await fixture.state.calls
        XCTAssertTrue(calls.contains { $0.recovery })
        XCTAssertEqual(Set(calls.compactMap(\.auth)), [a.authData])
        XCTAssertFalse(calls.contains { $0.auth == b.authData })
    }

    private func assertLateLogout(_ operation: CommerceHeldOperation) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let prior = operation == .check ? fixture.payment(for: a) : nil
        if let prior { try await fixture.payments.save(prior) }
        let gate = await fixture.state.hold(operation, auth: a.authData)
        let old = Task { await operation.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await fixture.model.signOut()
        XCTAssertNil(fixture.model.session)
        fixture.model.message = .verbatim("logged out")
        let before = CommerceVisibleState(fixture.model)
        await gate.resume(.success(operation, account: "A"))
        await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let pending = await fixture.payments.payment(for: a)
        let followups = await fixture.state.count(.orders, auth: a.authData)
        XCTAssertEqual(pending, prior)
        XCTAssertEqual(followups, 0, "A stale completion must not start a follow-up read")
    }

    private func assertStaleResult(
        _ operation: CommerceHeldOperation, response: CommerceFixtureResponse? = nil
    ) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(operation, auth: a.authData)
        let old = Task { await operation.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let b = try await fixture.switchToSeededB()
        let before = CommerceVisibleState(fixture.model)
        let requestsBefore = await fixture.state.calls
        let pendingBefore = await fixture.payments.payment(for: b)
        await gate.resume(response ?? .success(operation, account: "A"))
        await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let pendingAfter = await fixture.payments.payment(for: b)
        let requestsAfter = await fixture.state.calls
        XCTAssertEqual(pendingAfter, pendingBefore, "A must not write or clear B's pending payment")
        XCTAssertEqual(requestsAfter, requestsBefore, "Stale completion must not retry or refresh orders")
        let saved = try await fixture.sessions.read()
        XCTAssertEqual(saved, b)
    }

    private func assertLateFollowupRead(_ operation: CommerceHeldOperation) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let a = fixture.session("A")
        await fixture.model.establishAuthenticatedSession(a, source: .login)
        let gate = await fixture.state.hold(.orders, auth: a.authData, after: 0)
        let old = Task { await operation.invoke(fixture.model) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let b = try await fixture.switchToSeededB()
        let before = CommerceVisibleState(fixture.model)
        let pending = await fixture.payments.payment(for: b)
        await gate.resume(.success(.orders, account: "A"))
        await old.value
        XCTAssertEqual(CommerceVisibleState(fixture.model), before)
        let after = await fixture.payments.payment(for: b)
        XCTAssertEqual(after, pending)
    }

    private func makeFixture() async throws -> CommerceIsolationFixture {
        let suite = "NetworkClient.commerce-isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let sessions = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        try await sessions.setAutoLoginEnabled(true)
        let state = CommerceTransportState()
        let transport = CommerceFixtureTransport(state: state)
        let runtime = CommerceUnusedRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, writeTransportFactory: { transport })
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        let payments = PendingPaymentStore(defaults: defaults)
        let business = BootstrapBusinessAPI()
        let config = AppConfig(appName: "Fixture", loginTitle: nil, appLogo: nil,
            homePage: nil, telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "NetworkClientTests/1", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: ["https://first.api.invalid", "https://second.api.invalid"],
            activeAPIBaseURL: "https://first.api.invalid",
            builtInProxy: ["ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
                + "@198.51.100.20:443"])
        let model = AppModel(offline: false, businessDataAPI: business,
            nodeRepository: BootstrapNodeRepository(),
            apiHealthMonitor: APIHealthMonitor(transport: transport, observeNetwork: false),
            sessionStore: sessions, initialConfig: config, recoveryRouter: router,
            apiClient: api, pendingPaymentStore: payments)
        return CommerceIsolationFixture(model: model, api: api, state: state,
            runtime: runtime, config: config, payments: payments,
            sessions: sessions, business: business, suite: suite)
    }
}

@MainActor
private struct CommerceIsolationFixture {
    let model: AppModel
    let api: V2BoardAPIClient
    let state: CommerceTransportState
    let runtime: CommerceUnusedRecoveryRuntime
    let config: AppConfig
    let payments: PendingPaymentStore
    let sessions: SessionStore
    let business: BootstrapBusinessAPI
    let suite: String

    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    func session(_ account: String, auth: String? = nil) -> UserSession {
        UserSession(email: "\(account)@example.invalid", authData: auth ?? "synthetic-\(account)",
            accountToken: "synthetic-account-\(account)", subscriptionURL: "https://example.invalid/sub",
            uploadBytes: 1, downloadBytes: 2, transferEnableBytes: 100, expiredAt: 0,
            planID: 1, planName: "Fixture", balanceCents: 100, verifiedAt: Date(timeIntervalSince1970: 1))
    }
    func payment(for session: UserSession) -> PurchasePendingPayment {
        PurchasePendingPayment(tradeNo: "shared-trade",
            accountIdentifier: PendingPaymentStore.accountIdentifier(for: session),
            planID: 1, period: "month_price", createdAt: Date(timeIntervalSince1970: 1),
            paymentStartedAt: nil)
    }
    func switchToSeededB() async throws -> UserSession {
        await model.signOut()
        XCTAssertNil(model.session)
        let b = session("B")
        let generation = UUID()
        let replaced = try await sessions.replace(b, generation: generation, replacing: nil)
        XCTAssertTrue(replaced)
        await model.establishAuthenticatedSession(b, source: .login, generation: generation)
        await model.loadCommerce()
        await model.loadPaymentMethods()
        await model.beginCheckout(trade: "B-order", method: 1)
        await model.loadInvitations()
        try await payments.save(payment(for: b))
        model.message = .verbatim("B message")
        model.authMessage = .verbatim("B auth feedback")
        return b
    }
}

@MainActor
private struct CommerceVisibleState: Equatable {
    let session: UserSession?
    let orders: [PurchaseOrderRecord]
    let checkout: AppModel.OwnedPurchaseCheckout?
    let methods: [PurchasePaymentMethod]
    let invitations: ProfileInviteInfo?
    let message: LocalizedMessage?
    let authMessage: LocalizedMessage?
    let busy: Bool
    let indicator: Bool
    let nodeIDs: [String]
    let plans: [PurchasePlan]
    let notices: [HomeNotice]
    let loadStates: [BusinessDataLoadState]

    init(_ model: AppModel) {
        session = model.session; orders = model.orders; checkout = model.checkout
        methods = model.paymentMethods; invitations = model.invitations
        message = model.message; authMessage = model.authMessage
        busy = model.busy; indicator = model.showsGlobalBusyIndicator
        nodeIDs = model.nodes.nodes.map(\.id); plans = model.plans; notices = model.notices
        loadStates = [model.ordersLoadState, model.paymentMethodsLoadState,
                      model.invitationsLoadState, model.nodesLoadState, model.accountLoadState]
    }
}

private enum CommerceHeldOperation: CaseIterable, Sendable {
    case create, checkout, check, cancel, orders, methods, invite
    var path: String {
        switch self {
        case .create: V2BoardAPIClient.orderSavePath
        case .checkout: V2BoardAPIClient.orderCheckoutPath
        case .check: V2BoardAPIClient.orderCheckPath
        case .cancel: V2BoardAPIClient.orderCancelPath
        case .orders: V2BoardAPIClient.orderListPath
        case .methods: V2BoardAPIClient.orderPaymentMethodsPath
        case .invite: V2BoardAPIClient.inviteFetchPath
        }
    }
    @MainActor func invoke(_ model: AppModel) async {
        switch self {
        case .create:
            let cycle = PurchasePlanCycle(period: .month, priceCents: 100)
            await model.createOrder(plan: PurchasePlan(id: 1, name: "Fixture",
                content: "", sort: 1, cycles: [cycle], features: []), cycle: cycle)
        case .checkout: _ = await model.beginCheckout(trade: "shared-trade", method: 1)
        case .check: await model.checkOrder("shared-trade")
        case .cancel: _ = await model.cancelPendingOrder(trade: "shared-trade")
        case .orders: await model.loadCommerce()
        case .methods: await model.loadPaymentMethods()
        case .invite: await model.loadInvitations()
        }
    }
}

private struct CommerceFixtureResponse: Sendable {
    let status: Int
    let body: String
    init(status: Int = 200, body: String) { self.status = status; self.body = body }
    static let unauthorized = Self(status: 401, body: #"{"message":"Synthetic unauthenticated"}"#)
    static func success(_ operation: CommerceHeldOperation, account: String) -> Self {
        switch operation {
        case .create: Self(body: #"{"data":"\#(account)-created"}"#)
        case .checkout: Self(body: #"{"type":1,"data":"https://payments.example.invalid/\#(account)"}"#)
        case .check: Self(body: #"{"data":1}"#)
        case .cancel: Self(body: #"{"data":true}"#)
        case .orders: Self(body: #"{"data":[{"trade_no":"\#(account)-order","status":0,"plan_id":1,"period":"month_price"}]}"#)
        case .methods: Self(body: #"{"data":[{"id":1,"name":"\#(account) method","payment":"fixture"}]}"#)
        case .invite: Self(body: #"{"data":{"codes":[{"id":1,"code":"\#(account)-code"}],"stat":[]}}"#)
        }
    }
}

private actor CommerceResponseGate {
    let entered = XCTestExpectation(description: "authenticated request suspended")
    private var result: CommerceFixtureResponse?
    private var continuation: CheckedContinuation<CommerceFixtureResponse, Never>?
    func receive() async -> CommerceFixtureResponse {
        entered.fulfill()
        return await withCheckedContinuation {
            if let result { $0.resume(returning: result) }
            else { continuation = $0 }
        }
    }
    func resume(_ result: CommerceFixtureResponse) {
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor CommerceAsyncSuspensionGate {
    let entered: XCTestExpectation
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(description: String) {
        entered = XCTestExpectation(description: description)
    }

    func wait() async {
        entered.fulfill()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CommerceTransportState {
    struct Call: Equatable, Sendable { let path: String; let auth: String? }
    private(set) var calls: [Call] = []
    private var holds: [String: CommerceResponseGate] = [:]
    private var holdSkips: [String: Int] = [:]
    func hold(_ operation: CommerceHeldOperation, auth: String, after: Int = 0) -> CommerceResponseGate {
        let gate = CommerceResponseGate()
        holds[auth + operation.path] = gate
        holdSkips[auth + operation.path] = after
        return gate
    }
    func count(_ operation: CommerceHeldOperation, auth: String) -> Int {
        calls.filter { $0.path.hasSuffix(operation.path) && $0.auth == auth }.count
    }
    func response(for request: URLRequest) async -> CommerceFixtureResponse {
        let path = request.url!.path
        let auth = request.value(forHTTPHeaderField: "Authorization")
        calls.append(Call(path: path, auth: auth))
        if let operation = CommerceHeldOperation.allCases.first(where: { path.hasSuffix($0.path) }) {
            let key = (auth ?? "") + operation.path
            if let gate = holds[key] {
                if (holdSkips[key] ?? 0) > 0 { holdSkips[key, default: 0] -= 1 }
                else {
                    holds.removeValue(forKey: key)
                    return await gate.receive()
                }
            }
            return .success(operation, account: auth == "synthetic-B" ? "B" : "A")
        }
        if path.hasSuffix(V2BoardAPIClient.registrationConfigPath) { return .init(body: #"{"data":{}}"#) }
        XCTFail("Unexpected fake request path")
        return .init(status: 500, body: "{}")
    }
}

private struct CommerceFixtureTransport: ManagedNetworkTransport {
    let state: CommerceTransportState
    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        let response = await state.response(for: request)
        return (Data(response.body.utf8), HTTPURLResponse(url: request.url!,
            statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!)
    }
    func finishTasksAndInvalidate() {}
}

private actor CommerceUnusedRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private(set) var starts = 0
    func start(endpoint: BuiltInProxyEndpoint) throws -> BuiltInProxyRecoveryRuntimeInfo {
        starts += 1
        throw RecoveryRuntimeError.unavailable
    }
    func makeRecoveryTransport() -> any NetworkTransport {
        RecordingNetworkTransport { _, _ in throw URLError(.notConnectedToInternet) }
    }
    func stopRecovery() {}
}

private actor Step3RecoveryState {
    struct Call: Sendable, Equatable {
        let host: String
        let auth: String?
        let recovery: Bool
    }

    let recoveryResponse = CommerceResponseGate()
    private(set) var calls: [Call] = []

    func response(
        for request: URLRequest,
        recovery: Bool
    ) async throws -> (Data, URLResponse) {
        calls.append(Call(
            host: request.url?.host ?? "",
            auth: request.value(forHTTPHeaderField: "Authorization"),
            recovery: recovery
        ))
        guard recovery else { throw URLError(.cannotConnectToHost) }
        let response = await recoveryResponse.receive()
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private struct Step3RecoveryTransport: ManagedNetworkTransport {
    let state: Step3RecoveryState
    let recovery: Bool
    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        try await state.response(for: request, recovery: recovery)
    }
    func finishTasksAndInvalidate() {}
}

private actor Step3RecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    let state: Step3RecoveryState
    private(set) var starts = 0

    init(state: Step3RecoveryState) { self.state = state }

    func start(endpoint: BuiltInProxyEndpoint) throws -> BuiltInProxyRecoveryRuntimeInfo {
        starts += 1
        return BuiltInProxyRecoveryRuntimeInfo(
            protocolName: endpoint.protocolName,
            mixedPort: 1
        )
    }

    func makeRecoveryTransport() throws -> any NetworkTransport {
        Step3RecoveryTransport(state: state, recovery: true)
    }

    func stopRecovery() throws {}
}

@MainActor
private final class Step3RecoveryFixture {
    let suite = "NetworkClient.step3-recovery.\(UUID().uuidString)"
    let state: Step3RecoveryState
    let sessions: SessionStore
    let model: AppModel

    init() async throws {
        state = Step3RecoveryState()
        let direct = Step3RecoveryTransport(state: state, recovery: false)
        let runtime = Step3RecoveryRuntime(state: state)
        let router = APIRecoveryRouter(
            recoveryRuntime: runtime,
            recoveryInitiallySuspendedForFormalVPN: false,
            writeTransportFactory: { direct }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: direct)
        sessions = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        try await sessions.setAutoLoginEnabled(true)
        let config = step3CommerceConfig(includeBuiltInProxy: true)
        model = AppModel(
            offline: false,
            businessDataAPI: BootstrapBusinessAPI(),
            nodeRepository: BootstrapNodeRepository(),
            apiHealthMonitor: APIHealthMonitor(transport: direct, observeNetwork: false),
            sessionStore: sessions,
            initialConfig: config,
            recoveryRouter: router,
            apiClient: api,
            pendingPaymentStore: PendingPaymentStore(defaults: UserDefaults(suiteName: suite)!)
        )
    }

    func session(_ account: String) -> UserSession { step3Session(account) }

    func establishPersisted(_ session: UserSession) async throws {
        let generation = UUID()
        let replaced = try await sessions.replace(
            session,
            generation: generation,
            replacing: nil
        )
        XCTAssertTrue(replaced)
        await model.establishAuthenticatedSession(session, source: .login, generation: generation)
    }

    func switchAccount(to session: UserSession) async throws {
        await model.signOut()
        XCTAssertNil(model.session)
        try await establishPersisted(session)
    }

    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private actor Step3RetryState {
    struct Call: Sendable, Equatable { let host: String; let auth: String? }
    let firstAttempt = SessionPersistencePauseGate()
    private(set) var calls: [Call] = []

    func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        calls.append(Call(
            host: host,
            auth: request.value(forHTTPHeaderField: "Authorization")
        ))
        if host == "first.api.invalid" {
            await firstAttempt.pause()
            throw URLError(.cannotConnectToHost)
        }
        let body = #"{"data":[{"id":1,"name":"Synthetic A method","payment":"fixture"}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private struct Step3RetryTransport: ManagedNetworkTransport {
    let state: Step3RetryState
    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        try await state.response(for: request)
    }
    func finishTasksAndInvalidate() {}
}

@MainActor
private final class Step3RetryFixture {
    let suite = "NetworkClient.step3-retry.\(UUID().uuidString)"
    let state: Step3RetryState
    let sessions: SessionStore
    let model: AppModel

    init() async throws {
        state = Step3RetryState()
        let transport = Step3RetryTransport(state: state)
        let router = APIRecoveryRouter(
            recoveryInitiallySuspendedForFormalVPN: false,
            writeTransportFactory: { transport }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        sessions = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        try await sessions.setAutoLoginEnabled(true)
        let config = step3CommerceConfig(includeBuiltInProxy: false)
        model = AppModel(
            offline: false,
            businessDataAPI: BootstrapBusinessAPI(),
            nodeRepository: BootstrapNodeRepository(),
            apiHealthMonitor: APIHealthMonitor(transport: transport, observeNetwork: false),
            sessionStore: sessions,
            initialConfig: config,
            recoveryRouter: router,
            apiClient: api,
            pendingPaymentStore: PendingPaymentStore(defaults: UserDefaults(suiteName: suite)!)
        )
    }

    func session(_ account: String) -> UserSession { step3Session(account) }

    func establishPersisted(_ session: UserSession) async throws {
        let generation = UUID()
        let replaced = try await sessions.replace(
            session,
            generation: generation,
            replacing: nil
        )
        XCTAssertTrue(replaced)
        await model.establishAuthenticatedSession(session, source: .login, generation: generation)
    }

    func switchAccount(to session: UserSession) async throws {
        await model.signOut()
        XCTAssertNil(model.session)
        try await establishPersisted(session)
    }

    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private func step3CommerceConfig(includeBuiltInProxy: Bool) -> AppConfig {
    AppConfig(
        appName: "Fixture",
        loginTitle: nil,
        appLogo: nil,
        homePage: nil,
        telegramGroup: nil,
        supportAPI: nil,
        updateURL: nil,
        userAgent: "NetworkClientTests/1",
        latencyDisplayRatio: 1,
        inviteLink: nil,
        apiBaseURLs: ["https://first.api.invalid", "https://second.api.invalid"],
        activeAPIBaseURL: "https://first.api.invalid",
        builtInProxy: includeBuiltInProxy
            ? ["ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
                + "@198.51.100.20:443"]
            : []
    )
}

private func step3Session(_ account: String) -> UserSession {
    UserSession(
        email: "\(account)@example.invalid",
        authData: "synthetic-\(account)",
        accountToken: nil,
        subscriptionURL: "https://example.invalid/sub",
        uploadBytes: 1,
        downloadBytes: 2,
        transferEnableBytes: 100,
        expiredAt: 0,
        planID: 1,
        planName: "Fixture",
        balanceCents: 100,
        verifiedAt: Date(timeIntervalSince1970: 1)
    )
}

// MARK: Operation budget regression controls

/// Virtual time advances synchronously; only explicit sleepers suspend. No
/// budget test sleeps for real seconds or starts a real network connection.
final class BudgetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Duration = .zero
    private var waiters: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled = Set<UUID>()
    private var notifications: [(Duration, XCTestExpectation)] = []
    private let autoBackoff: Bool

    init(autoBackoff: Bool = false) { self.autoBackoff = autoBackoff }
    var now: Duration { lock.withLock { instant } }
    var sleeperCount: Int { lock.withLock { waiters.count } }

    // BEGIN injected clock adapter
    var clock: OperationClock {
        OperationClock(now: { self.now }, sleepUntil: { try await self.sleep(until: $0) })
    }
    // END injected clock adapter

    func notifySleep(at instant: Duration, _ expectation: XCTestExpectation) {
        lock.withLock { notifications.append((instant, expectation)) }
    }
    func advance(_ duration: Duration) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            instant += duration
            let ids = waiters.filter { $0.value.0 <= instant }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
    func sleep(until target: Duration) async throws {
        if autoBackoff, target > now, target - now <= .milliseconds(400) {
            advance(target - now)
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled || cancelled.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else if target <= instant {
                        continuation.resume()
                    } else {
                        waiters[id] = (target, continuation)
                        let matches = notifications.filter { $0.0 == target }
                        notifications.removeAll { $0.0 == target }
                        matches.forEach { $0.1.fulfill() }
                    }
                }
            }
        }, onCancel: {
            self.lock.withLock {
                if let waiter = self.waiters.removeValue(forKey: id) {
                    waiter.1.resume(throwing: CancellationError())
                } else { self.cancelled.insert(id) }
            }
        })
    }
}

func budgetTestConfig() -> AppConfig {
    AppConfig(appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
        telegramGroup: nil, supportAPI: nil, updateURL: nil, userAgent: "NetworkClientTests/1",
        latencyDisplayRatio: 1, inviteLink: nil,
        apiBaseURLs: ["https://127.0.0.1", "https://127.0.0.2", "https://127.0.0.3"],
        activeAPIBaseURL: "https://127.0.0.1", builtInProxy: [])
}

func budgetTestSession() -> UserSession {
    UserSession(email: "fixture@example.invalid", authData: "synthetic-only",
        accountToken: nil, subscriptionURL: "https://subscription.example.invalid/synthetic",
        uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 100, expiredAt: 0,
        planID: 1, planName: "Fixture", balanceCents: 0, verifiedAt: Date(timeIntervalSince1970: 1))
}

func budgetTestAPI(clock: BudgetTestClock, transport: RecordingNetworkTransport) -> V2BoardAPIClient {
    let router = APIRecoveryRouter(clock: clock.clock, writeTransportFactory: { transport })
    return V2BoardAPIClient(recoveryRouter: router, transport: transport)
}

/// These exact test methods also run against unchanged pre-fix production files.
final class OperationBudgetNegativeControlTests: XCTestCase {
    func testThreeHostReadStopsAtTotalBudget() async throws {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, _ in
            clock.advance(.seconds(request.timeoutInterval))
            throw URLError(.timedOut)
        }
        let api = budgetTestAPI(clock: clock, transport: transport)
        do {
            _ = try await api.fetchPaymentMethods(config: budgetTestConfig(), session: budgetTestSession())
            XCTFail("Expected timeout")
        } catch NetworkClientError.timedOut {}
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2, "Must not start Host C after the shared deadline")
        XCTAssertLessThanOrEqual(clock.now, .seconds(30))
    }

    func testThreeHostWriteProbeHasShortTimeouts() async throws {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, _ in
            clock.advance(.seconds(request.timeoutInterval))
            throw URLError(.timedOut)
        }
        let api = budgetTestAPI(clock: clock, transport: transport)
        do {
            _ = try await api.checkoutOrder(config: budgetTestConfig(), session: budgetTestSession(),
                tradeNo: "synthetic-trade", methodID: 1)
            XCTFail("Expected pre-submit timeout")
        } catch NetworkClientError.timedOut {}
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.method == "GET" && $0.timeout <= 4 })
        XCTAssertLessThanOrEqual(clock.now, .seconds(12))
    }
}

// MARK: Write redirect and uncertain-result regression controls

/// These three controls also run unchanged against the pre-fix production tree.
@MainActor
final class WriteSafetyRegressionControls: XCTestCase {
    func testDirect307And308NeverReachRedirectTarget() async throws {
        let server = try RedirectLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let transport = URLSessionNetworkTransport(profile: .api)
        defer { transport.finishTasksAndInvalidate() }
        for code in [307, 308] {
            let path = "/original/\(code)"
            var request = URLRequest(url: server.url(path))
            request.httpMethod = "POST"
            request.httpBody = Data("synthetic-body".utf8)
            let (_, response) = try await transport.data(for: request, kind: .apiWrite)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, code)
            XCTAssertEqual(server.requests(at: path).count, 1)
            XCTAssertEqual(server.requests(at: "/redirected/\(code)").count, 0)
        }
    }

    func testUnknownCreateAllowsANewPOSTOnTheNextCompletedUserAction() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configure(create: .timeout, newOrders: 0)
        await fixture.buy()
        await fixture.buy()
        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 2)
    }

    func testUnknownCheckoutCannotSendSecondPOST() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configure(checkout: .timeout)
        await fixture.model.beginCheckout(trade: "trade", method: 1)
        await fixture.model.beginCheckout(trade: "trade", method: 1)
        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checkout, 1)
    }
}

/// Real loopback TCP/HTTP, not a delegate invocation mock. It runs in the test
/// process, binds an ephemeral port, and never contacts a production endpoint.
private final class RedirectLoopbackServer: @unchecked Sendable {
    struct Request: Sendable { let method: String; let body: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NetworkClientTests.redirect-server")
    private let lock = NSLock()
    private var received: [String: [Request]] = [:]

    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
    func requests(at path: String) -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return received[path] ?? []
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: buffer) }
                return
            }
            let headers = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
            let lines = headers.components(separatedBy: "\r\n")
            let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard buffer.count >= boundary.upperBound + length else {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: buffer) }
                return
            }
            let first = lines[0].split(separator: " ")
            guard first.count >= 2 else { connection.cancel(); return }
            let path = String(first[1])
            let request = Request(method: String(first[0]),
                body: String(decoding: buffer[boundary.upperBound..<(boundary.upperBound + length)], as: UTF8.self))
            self.lock.lock()
            self.received[path, default: []].append(request)
            self.lock.unlock()
            let code = path.hasPrefix("/original/") ? Int(path.split(separator: "/").last!) ?? 200 : 200
            let body = Data(#"{"data":false}"#.utf8)
            let location = code == 200 ? "" : "Location: /redirected/\(code)\r\n"
            let head = "HTTP/1.1 \(code) Test\r\n\(location)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private enum WriteFixtureOutcome: Sendable {
    case success, dataFalse, timeout, loss, dns, cancelled, nonHTTP, malformed, incompleteCheckout
    case html(Int)
    case malformedStatus(Int)
    case jsonWithoutMessage(Int)
    case mislabelledBusinessRejection(Int, String)
    case redirect(Int)
    case rejection(Int)
    case messageOnlyRejection(Int)
    case messageOnlyBusinessRejection(Int, String)
    case debugBusinessRejection(Int, String)
}

private enum CouponFixtureOutcome: Sendable {
    case success
    case business(String)
    case unauthorized
    case cancelled
}

private actor WriteOutcomeState {
    private var create: WriteFixtureOutcome = .success
    private var checkout: WriteFixtureOutcome = .success
    private var inviteCreate: WriteFixtureOutcome = .success
    private var coupon: CouponFixtureOutcome = .success
    private var couponHold: CommerceResponseGate?
    private var newOrderCount = 1
    private var queryFails = false
    private var orderDetailFails = false
    private var paymentMethodsFail = false
    private var checkStatus = 0
    private var omitted: Set<String> = []
    private var mismatch: String?
    private(set) var checkedTrades: [String] = []
    private var rows: [String: [[String: Any]]] = [:]
    private var creates: [String: Int] = [:]
    private var checkouts: [String: Int] = [:]
    private var cancels: [String: Int] = [:]
    private var orderQueries: [String: Int] = [:]
    private var checkQueries: [String: Int] = [:]
    private var orderDetailQueries: [String: Int] = [:]
    private var paymentMethodQueries: [String: Int] = [:]
    private var couponQueries: [String: Int] = [:]
    private var createCouponCodes: [String: [String?]] = [:]
    private var inviteCreates: [String: Int] = [:]
    private var inviteFetches: [String: Int] = [:]
    private var inviteCodesEmpty = false
    private var inviteCreateHold: CommerceResponseGate?
    private var hold: CommerceResponseGate?
    private var heldAuth: String?

    func configure(create: WriteFixtureOutcome? = nil, checkout: WriteFixtureOutcome? = nil,
                   newOrders: Int? = nil, queryFails: Bool? = nil, status: Int? = nil,
                   omitted: Set<String>? = nil, mismatch: String? = nil) {
        if let create { self.create = create }
        if let checkout { self.checkout = checkout }
        if let newOrders { newOrderCount = newOrders }
        if let queryFails { self.queryFails = queryFails }
        if let status { checkStatus = status }
        if let omitted { self.omitted = omitted }
        if let mismatch { self.mismatch = mismatch }
    }
    func configureCoupon(_ outcome: CouponFixtureOutcome) {
        coupon = outcome
    }
    func holdCoupon() -> CommerceResponseGate {
        let gate = CommerceResponseGate()
        couponHold = gate
        return gate
    }
    func couponCount(auth: String) -> Int {
        couponQueries[auth, default: 0]
    }
    func configureInviteCreate(_ outcome: WriteFixtureOutcome) {
        inviteCreate = outcome
    }
    func configureInviteCodesEmpty(_ empty: Bool) {
        inviteCodesEmpty = empty
    }
    func holdInviteCreate() -> CommerceResponseGate {
        let gate = CommerceResponseGate()
        inviteCreateHold = gate
        return gate
    }
    func inviteCounts(auth: String) -> (create: Int, fetch: Int) {
        (inviteCreates[auth, default: 0], inviteFetches[auth, default: 0])
    }
    func configurePaymentPreparation(
        orderDetailFails: Bool? = nil,
        paymentMethodsFail: Bool? = nil
    ) {
        if let orderDetailFails { self.orderDetailFails = orderDetailFails }
        if let paymentMethodsFail { self.paymentMethodsFail = paymentMethodsFail }
    }
    func counts(auth: String) -> (
        create: Int,
        checkout: Int,
        cancel: Int,
        orders: Int,
        checks: Int
    ) {
        (
            creates[auth, default: 0],
            checkouts[auth, default: 0],
            cancels[auth, default: 0],
            orderQueries[auth, default: 0],
            checkQueries[auth, default: 0]
        )
    }
    func submittedCouponCodes(auth: String) -> [String?] {
        createCouponCodes[auth, default: []]
    }
    func paymentPreparationCounts(auth: String) -> (details: Int, methods: Int) {
        (
            orderDetailQueries[auth, default: 0],
            paymentMethodQueries[auth, default: 0]
        )
    }
    func holdReconcile(auth: String) -> CommerceResponseGate {
        let gate = CommerceResponseGate()
        hold = gate; heldAuth = auth
        return gate
    }
    func seedOldOrder(auth: String) { rows[auth] = [order(trade: "pre-existing")] }
    private func order(trade: String) -> [String: Any] {
        var result: [String: Any] = ["trade_no": trade, "status": 0, "plan_id": 1,
            "period": "month_price", "total_amount": 100, "discount_amount": 0,
            "surplus_amount": 0, "balance_amount": 0, "refund_amount": 0, "handling_amount": 0,
            "created_at": Int(Date().timeIntervalSince1970), "plan": ["id": 1, "month_price": 100]]
        switch mismatch {
        case "plan_id": result["plan_id"] = 2
        case "period": result["period"] = "year_price"
        case "plan": result["plan"] = ["id": 1, "month_price": 99]
        case "total_amount": result["total_amount"] = 99
        case "status": result["status"] = 3
        case "created_at": result["created_at"] = 1
        case "paid_at": result["paid_at"] = Int(Date().timeIntervalSince1970)
        case let field?: result[field] = 1
        case nil: break
        }
        for field in omitted { result.removeValue(forKey: field) }
        return result
    }
    func response(_ request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? "anonymous"
        func json(_ value: Any, status: Int = 200) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        func result(_ outcome: WriteFixtureOutcome, success: [String: Any]) throws -> (Data, URLResponse) {
            switch outcome {
            case .success: return try json(success)
            case .dataFalse: return try json(["data": false])
            case .incompleteCheckout: return try json(["type": 1])
            case .timeout: throw URLError(.timedOut)
            case .loss: throw URLError(.networkConnectionLost)
            case .dns: throw URLError(.cannotFindHost)
            case .cancelled: throw URLError(.cancelled)
            case .nonHTTP: return (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
            case .malformed: return (Data("invalid-json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            case let .malformedStatus(code):
                return (
                    Data("invalid-json".utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: code, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            case let .jsonWithoutMessage(code):
                return try json(["proxy": "synthetic"], status: code)
            case let .html(code):
                return (
                    Data("<html><body>internal details</body></html>".utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: code, httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                )
            case let .mislabelledBusinessRejection(code, message):
                return (
                    try JSONSerialization.data(withJSONObject: ["message": message]),
                    HTTPURLResponse(
                        url: request.url!, statusCode: code, httpVersion: nil,
                        headerFields: ["Content-Type": "text/html; charset=UTF-8"]
                    )!
                )
            case let .redirect(code): return try json(["data": false], status: code)
            case let .rejection(code): return try json(["data": false, "message": "Synthetic rejection"], status: code)
            case let .messageOnlyRejection(code):
                return try json(["message": "Synthetic rejection"], status: code)
            case let .messageOnlyBusinessRejection(code, message):
                return try json(["message": message], status: code)
            case let .debugBusinessRejection(code, message):
                return try json([
                    "message": message,
                    "exception": "Synthetic\\Exception",
                    "file": "/srv/app/InviteController.php",
                    "line": 18,
                    "trace": [["file": "/srv/app/InviteController.php", "line": 18]]
                ], status: code)
            }
        }
        if path.hasSuffix(V2BoardAPIClient.orderSavePath) {
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            createCouponCodes[auth, default: []].append(body?["coupon_code"] as? String)
            creates[auth, default: 0] += 1
            switch create {
            case .dns, .cancelled, .rejection, .messageOnlyRejection,
                 .messageOnlyBusinessRejection: break
            default:
                for index in 0..<newOrderCount { rows[auth, default: []].append(order(trade: "\(auth)-created-\(creates[auth]!)-\(index)")) }
            }
            return try result(create, success: ["data": "\(auth)-created-\(creates[auth]!)-0"])
        }
        if path.hasSuffix(V2BoardAPIClient.couponCheckPath) {
            couponQueries[auth, default: 0] += 1
            if let gate = couponHold {
                couponHold = nil
                let response = await gate.receive()
                return (
                    Data(response.body.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: response.status,
                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }
            switch coupon {
            case .success:
                return try json(["data": ["id": 9, "name": "Fixture Coupon"]])
            case let .business(message):
                return try json(["message": message], status: 500)
            case .unauthorized:
                return try json(["message": "Unauthenticated"], status: 401)
            case .cancelled:
                throw URLError(.cancelled)
            }
        }
        if path.hasSuffix(V2BoardAPIClient.inviteSavePath) {
            inviteCreates[auth, default: 0] += 1
            if let gate = inviteCreateHold {
                inviteCreateHold = nil
                let response = await gate.receive()
                return (
                    Data(response.body.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: response.status,
                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }
            return try result(inviteCreate, success: ["data": true])
        }
        if path.hasSuffix(V2BoardAPIClient.inviteFetchPath) {
            inviteFetches[auth, default: 0] += 1
            let generated = inviteCreates[auth, default: 0]
            let codes: [[String: Any]] = inviteCodesEmpty ? [] : [
                ["id": 2, "code": "newer-\(auth)-\(generated)", "status": 0,
                 "pv": 3, "created_at": 200],
                ["id": 1, "code": "older-\(auth)", "status": 0,
                 "pv": 1, "created_at": 100]
            ]
            return try json(["data": [
                "codes": codes,
                "stat": [5, 1200, 300, 10, 900]
            ]])
        }
        if path.hasSuffix(V2BoardAPIClient.orderCheckoutPath) {
            checkouts[auth, default: 0] += 1
            return try result(checkout, success: ["type": 1, "data": "https://payments.example.invalid/fixture"])
        }
        if path.hasSuffix(V2BoardAPIClient.orderCancelPath) {
            cancels[auth, default: 0] += 1
            let trade = (request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })?["trade_no"] as? String
            if let trade, var orders = rows[auth] {
                for index in orders.indices where orders[index]["trade_no"] as? String == trade {
                    orders[index]["status"] = 2
                }
                rows[auth] = orders
            }
            return try json(["data": true])
        }
        if path.hasSuffix(V2BoardAPIClient.orderDetailPath) {
            orderDetailQueries[auth, default: 0] += 1
            if orderDetailFails { throw URLError(.notConnectedToInternet) }
            let trade = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "trade_no" })?.value ?? "missing"
            var detail = rows[auth]?.first(where: {
                $0["trade_no"] as? String == trade
            }) ?? order(trade: trade)
            detail["discount_amount"] = 10
            detail["surplus_amount"] = 20
            detail["balance_amount"] = 30
            detail["refund_amount"] = 40
            detail["handling_amount"] = 5
            detail["plan"] = ["id": 1, "name": "Fixture Plan", "month_price": 200]
            return try json(["data": detail])
        }
        if path.hasSuffix(V2BoardAPIClient.orderPaymentMethodsPath) {
            paymentMethodQueries[auth, default: 0] += 1
            if paymentMethodsFail { throw URLError(.notConnectedToInternet) }
            return try json(["data": [[
                "id": 1, "name": "Fixture Pay", "payment": "EPay",
                "handling_fee_fixed": 10, "handling_fee_percent": 1.5
            ]]])
        }
        if path.hasSuffix(V2BoardAPIClient.orderListPath) || path.hasSuffix(V2BoardAPIClient.orderCheckPath) {
            let isCheck = path.hasSuffix(V2BoardAPIClient.orderCheckPath)
            if isCheck {
                checkQueries[auth, default: 0] += 1
                checkedTrades.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "trade_no" })?.value ?? "missing")
            }
            else { orderQueries[auth, default: 0] += 1 }
            if let gate = hold, heldAuth == auth, creates[auth, default: 0] + checkouts[auth, default: 0] > 0 {
                hold = nil
                let response = await gate.receive()
                return (Data(response.body.utf8), HTTPURLResponse(url: request.url!, statusCode: response.status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            if queryFails, creates[auth, default: 0] + checkouts[auth, default: 0] > 0 { throw URLError(.notConnectedToInternet) }
            if isCheck { return try json(["data": checkStatus]) }
            return try json(["data": rows[auth] ?? []])
        }
        if path.hasSuffix(V2BoardAPIClient.registrationConfigPath) { return try json(["data": [:]]) }
        XCTFail("Unexpected fixture request")
        throw URLError(.badURL)
    }
}

private struct WriteOutcomeTransport: ManagedNetworkTransport {
    let state: WriteOutcomeState
    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        try await state.response(request, kind: kind)
    }
    func finishTasksAndInvalidate() {}
}

@MainActor
private final class WriteOutcomeFixture {
    let suite = "NetworkClient.write-outcome.\(UUID().uuidString)"
    let state = WriteOutcomeState()
    let runtime = CommerceUnusedRecoveryRuntime()
    let business = BootstrapBusinessAPI()
    let config = AppConfig(appName: "Fixture", loginTitle: nil, appLogo: nil,
        homePage: nil, telegramGroup: nil, supportAPI: nil, updateURL: nil,
        userAgent: "NetworkClientTests/1", latencyDisplayRatio: 1, inviteLink: nil,
        apiBaseURLs: ["https://first.api.invalid", "https://second.api.invalid"],
        activeAPIBaseURL: "https://first.api.invalid",
        builtInProxy: ["ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString() + "@198.51.100.20:443"])
    let a = WriteOutcomeFixture.session("A")
    let b = WriteOutcomeFixture.session("B")
    let cycle = PurchasePlanCycle(period: .month, priceCents: 100)
    var plan: PurchasePlan { PurchasePlan(id: 1, name: "Fixture", content: "", sort: 1, cycles: [cycle], features: []) }
    private(set) var model: AppModel!
    private(set) var payments: PendingPaymentStore!
    private(set) var sessions: SessionStore!
    private(set) var api: V2BoardAPIClient!
    private(set) var router: APIRecoveryRouter!

    init() async throws {
        let transport = WriteOutcomeTransport(state: state)
        router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, writeTransportFactory: { transport })
        api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        sessions = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        try await sessions.setAutoLoginEnabled(true)
        payments = PendingPaymentStore(defaults: UserDefaults(suiteName: suite)!)
        model = newModel()
        await model.establishAuthenticatedSession(a, source: .login)
    }
    func newModel(freshStore: Bool = false) -> AppModel {
        AppModel(offline: false, businessDataAPI: business,
            nodeRepository: BootstrapNodeRepository(),
            apiHealthMonitor: APIHealthMonitor(transport: WriteOutcomeTransport(state: state), observeNetwork: false),
            sessionStore: sessions, initialConfig: config, recoveryRouter: router,
            apiClient: api, pendingPaymentStore: freshStore ? PendingPaymentStore(defaults: UserDefaults(suiteName: suite)!) : payments)
    }
    func buy(
        on model: AppModel? = nil,
        couponCode: String? = nil
    ) async -> PurchaseOrderCreationOutcome {
        await (model ?? self.model).createOrder(
            plan: plan,
            cycle: cycle,
            couponCode: couponCode
        )
    }
    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    static func session(_ owner: String, auth: String? = nil) -> UserSession {
        UserSession(email: "\(owner)@example.invalid", authData: auth ?? "synthetic-\(owner)",
            accountToken: nil, subscriptionURL: "", uploadBytes: 0, downloadBytes: 0,
            transferEnableBytes: 100, expiredAt: 0, planID: 1, planName: "Fixture",
            balanceCents: 0, verifiedAt: Date())
    }
}

final class ProfileInviteLinkBuilderTests: XCTestCase {
    func testInviteLinkAppendsCodeDirectlyWithoutInventingSeparator() throws {
        let url = try XCTUnwrap(ProfileInviteLinkBuilder.url(
            inviteLink: "https://example.invalid/#/register?code=",
            code: "ABC123"
        ))
        XCTAssertEqual(url.absoluteString, "https://example.invalid/#/register?code=ABC123")
    }

    func testInviteLinkDoesNotInsertQueryOrSlashForBarePrefix() throws {
        let url = try XCTUnwrap(ProfileInviteLinkBuilder.url(
            inviteLink: "https://example.invalid/register",
            code: "ABC123"
        ))
        XCTAssertEqual(url.absoluteString, "https://example.invalid/registerABC123")
    }

    func testInviteCodeUsesOnlyRFC3986UnreservedCharactersWithoutEscaping() throws {
        let url = try XCTUnwrap(ProfileInviteLinkBuilder.url(
            inviteLink: "https://example.invalid/invite/",
            code: "AZaz09-._~"
        ))
        XCTAssertEqual(url.absoluteString, "https://example.invalid/invite/AZaz09-._~")
    }

    func testInviteCodePercentEncodesReservedAndUnicodeCharacters() throws {
        let url = try XCTUnwrap(ProfileInviteLinkBuilder.url(
            inviteLink: "https://example.invalid/invite/",
            code: "A+B/C?&=#中"
        ))
        XCTAssertEqual(
            url.absoluteString,
            "https://example.invalid/invite/A%2BB%2FC%3F%26%3D%23%E4%B8%AD"
        )
    }

    func testMissingEmptyAndInvalidInviteLinksFailClosed() {
        for value in [nil, "", "   ", "not a URL", "ftp://example.invalid/invite/"] as [String?] {
            XCTAssertNil(ProfileInviteLinkBuilder.url(inviteLink: value, code: "ABC"))
        }
    }

    func testEmptyInviteCodeCannotProduceLink() {
        XCTAssertNil(ProfileInviteLinkBuilder.url(
            inviteLink: "https://example.invalid/invite/",
            code: "  "
        ))
    }
}

@MainActor
final class LoadingPresentationPhaseOneTests: XCTestCase {
    func testNodeRefreshAndBatchLatencyBlockSelectionWithoutDisabledAppearance() throws {
        let nodesSource = try source("App/Views/NodesView.swift")
        let row = try region(
            nodesSource,
            from: "private func nodeRow(_ node: ProxyNode)",
            to: "private func select(_ nodeID: String)"
        )
        XCTAssertTrue(row.contains(
            ".allowsHitTesting(!model.testingAllNodes && !model.nodesLoadState.isLoading)"
        ))
        XCTAssertFalse(row.contains(
            "|| model.testingAllNodes || model.nodesLoadState.isLoading"
        ))
        XCTAssertTrue(row.contains(
            ".disabled((model.busy && model.showsGlobalBusyIndicator)"
        ))
        XCTAssertTrue(row.contains("|| model.nodeSwitchInFlight)"))
    }

    func testRetainedContentLoadingPresentationSeparatesInitialLoadAndRefresh() {
        XCTAssertTrue(RetainedContentLoadingPresentation.showsInitialLoading(
            isLoading: true,
            hasContent: false
        ))
        XCTAssertFalse(RetainedContentLoadingPresentation.showsRefreshIndicator(
            isLoading: true,
            hasContent: false
        ))
        XCTAssertFalse(RetainedContentLoadingPresentation.showsInitialLoading(
            isLoading: true,
            hasContent: true
        ))
        XCTAssertTrue(RetainedContentLoadingPresentation.showsRefreshIndicator(
            isLoading: true,
            hasContent: true
        ))
        XCTAssertFalse(RetainedContentLoadingPresentation.showsInitialLoading(
            isLoading: false,
            hasContent: false
        ))
        XCTAssertFalse(RetainedContentLoadingPresentation.showsRefreshIndicator(
            isLoading: false,
            hasContent: true
        ))
    }

    func testSharedRefreshToolbarMetricsRemainStableAndAccessible() {
        XCTAssertEqual(RefreshToolbarAppearance.symbolSize, 17)
        XCTAssertGreaterThanOrEqual(RefreshToolbarAppearance.minimumTapSize, 44)
    }

    func testRootBusyOverlayAndDefaultPresentationRemainAvailable() throws {
        let appModel = try source("App/AppModel.swift")
        let root = try source("App/Views/RootView.swift")
        XCTAssertTrue(appModel.contains("showBusyIndicator: Bool = true"))
        XCTAssertTrue(root.contains("model.busy && model.showsGlobalBusyIndicator"))
        XCTAssertTrue(root.contains("root.globalBusy"))
    }

    func testConfigurationUnavailableKeepsExistingVPNDisconnectAccessible() {
        XCTAssertFalse(ConfigurationUnavailableVPNPresentation.showsDisconnect(
            for: .disconnected
        ))
        XCTAssertTrue(ConfigurationUnavailableVPNPresentation.showsDisconnect(
            for: .connecting
        ))
        XCTAssertTrue(ConfigurationUnavailableVPNPresentation.showsDisconnect(
            for: .connected
        ))
    }

    func testTargetOperationsExplicitlySuppressOnlyTheGlobalBusyPresentation() throws {
        let source = try source("App/AppModel.swift")
        let authentication = try region(
            source,
            from: "private func performAuthentication(",
            to: "func clearAuthenticationFeedback()"
        )
        XCTAssertTrue(authentication.contains("showBusyIndicator: false"))

        let commerce = try region(
            source,
            from: "func loadCommerce() async",
            to: "func loadPaymentMethods() async"
        )
        XCTAssertTrue(commerce.contains("showBusyIndicator: false"))

        let invitations = try region(
            source,
            from: "func loadInvitations() async",
            to: "func generateInviteCode() async"
        )
        XCTAssertTrue(invitations.contains("showBusyIndicator: false"))
    }

    func testAuthViewUsesLocalSubmitCodeAndConfigurationProgress() throws {
        let source = try source("App/Views/AuthView.swift")
        for value in [
            "auth.submit.progress",
            "auth.sendCode.progress",
            "auth.registrationConfig.loading",
            "login.action.submitting",
            "register.action.submitting",
            "forgot.action.resetting",
            "register.action.sending_code",
            "forgot.action.sending_code",
        ] {
            XCTAssertTrue(source.contains(value), value)
        }
        XCTAssertFalse(source.contains("L10nKey.loginStatusLoggingIn"))
    }

    func testAuthLoginAndRegistrationShareUnifiedConsentWithoutGatingReset() throws {
        let source = try source("App/Views/AuthView.swift")
        for value in [
            "auth.consent.checkbox",
            "auth.consent.document.link",
            "UsageTermsPrivacyView()",
            "mode == .login || mode == .register",
            "mode == .reset",
            "usageTermsConsent.authorize",
            "submissionCoordinator.perform",
        ] {
            XCTAssertTrue(source.contains(value), value)
        }
        for section in ["terms", "privacy", "vpn", "account"] {
            XCTAssertTrue(source.contains("consent.section.\(section).title"))
            XCTAssertTrue(source.contains("consent.section.\(section).body"))
        }
        XCTAssertTrue(source.contains("consent.document.section.\\(section.identifier)"))
    }

    func testUnifiedConsentLocalizationIsCompleteInChineseAndEnglish() throws {
        let keys = [
            "consent.checkbox.prefix",
            "consent.checkbox.statement",
            "consent.document.link_title",
            "consent.modal.title",
            "consent.modal.message",
            "consent.action.decline",
            "consent.action.agree",
            "consent.document.title",
            "consent.section.terms.title",
            "consent.section.terms.body",
            "consent.section.privacy.title",
            "consent.section.privacy.body",
            "consent.section.vpn.title",
            "consent.section.vpn.body",
            "consent.section.account.title",
            "consent.section.account.body",
        ]
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(
                    bundle.localizedString(forKey: key, value: key, table: nil),
                    key,
                    "\(locale): \(key)"
                )
            }
        }
    }

    func testOrdersInvitationAndTrafficUseOneSharedRefreshPresentation() throws {
        let commerce = try source("App/Views/CommerceView.swift")
        let profile = try source("App/Views/ProfileView.swift")
        XCTAssertTrue(commerce.contains("RefreshToolbarButton("))
        XCTAssertTrue(commerce.contains("identifier: \"profile.orders.refresh\""))
        XCTAssertTrue(commerce.contains("if model.orders.isEmpty,"))
        XCTAssertEqual(profile.components(separatedBy: "RefreshToolbarButton(").count - 1, 2)
        XCTAssertTrue(profile.contains("identifier: \"profile.invites.refresh\""))
        XCTAssertTrue(profile.contains("identifier: \"profile.traffic.refresh\""))
    }

    func testRefreshingAccessibilityTextIsLocalized() throws {
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertNotEqual(
                bundle.localizedString(
                    forKey: "common.status.refreshing",
                    value: "common.status.refreshing",
                    table: nil
                ),
                "common.status.refreshing"
            )
        }
    }

    func testLoginBusyStateDoesNotRequestRootOverlay() async {
        let gate = CommerceResponseGate()
        let fixture = AuthForgetFixture(outcome: .held(gate))
        let login = Task {
            await fixture.model.login(
                email: "person@example.invalid",
                password: "synthetic-password",
                remember: true
            )
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(fixture.model.busy)
        XCTAssertFalse(fixture.model.showsGlobalBusyIndicator)
        await gate.resume(.init(status: 400, body: #"{"message":"Synthetic rejection"}"#))
        await login.value
        XCTAssertFalse(fixture.model.busy)
    }

    func testPerformDefaultStillRequestsRootOverlay() async {
        let gate = CommerceResponseGate()
        let model = AppModel(offline: false)
        let operation = Task {
            await model.perform {
                _ = await gate.receive()
            }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.showsGlobalBusyIndicator)
        await gate.resume(.init(body: #"{"data":true}"#))
        _ = await operation.value
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.showsGlobalBusyIndicator)
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath))
    }

    private func region(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)?.lowerBound)
        return String(source[lower..<upper])
    }
}

final class CommerceTouchTargetTests: XCTestCase {
    func testInlineCommerceActionsUseTheSharedAccessibleMinimum() {
        XCTAssertGreaterThanOrEqual(CommerceActionAppearance.minimumTapSize, 44)
    }

    func testEverySmallPurchaseActionUsesTheSharedHitTarget() throws {
        let source = try commerceSource()
        XCTAssertEqual(
            source.components(separatedBy: ".commerceInlineActionLabel()").count - 1,
            7
        )
        for identifier in [
            "purchase.plans.refresh",
            "purchase.orders.open",
            "purchase.plans.retry",
            "purchase.pending.continue",
            "purchase.pending.retry",
        ] {
            XCTAssertTrue(source.contains(identifier), identifier)
        }
        XCTAssertTrue(source.contains("purchase.plan.\\(plan.id).disclosure"))
    }

    func testAccessibilityFixturesAreDebugOnlyAndRequireExplicitOfflineSampleMode() throws {
        let source = try commerceSource()
        let fixtureStart = try XCTUnwrap(source.range(of: "#if DEBUG\nprivate enum CommerceUITestFixture"))
        let fixtureEnd = try XCTUnwrap(source.range(
            of: "#endif",
            range: fixtureStart.upperBound..<source.endIndex
        ))
        let fixture = String(source[fixtureStart.lowerBound..<fixtureEnd.upperBound])
        XCTAssertTrue(fixture.contains("arguments.contains(\"--offline\")"))
        XCTAssertTrue(fixture.contains("arguments.contains(\"--ui-sample\")"))
        XCTAssertTrue(fixture.contains("--ui-purchase-initial-error"))
        XCTAssertTrue(fixture.contains("--ui-purchase-stale-error"))
        XCTAssertTrue(fixture.contains("--ui-purchase-pending-ready"))
        XCTAssertTrue(fixture.contains("--ui-purchase-pending-error"))
    }

    private func commerceSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("App/Views/CommerceView.swift"))
    }
}

final class InvitationCompactLayoutTests: XCTestCase {
    func testCompactLayoutUsesRequiredIconAndTouchSizes() {
        XCTAssertEqual(InvitationsAppearance.titleIconSize, 19)
        XCTAssertEqual(InvitationsAppearance.actionIconSize, 17)
        XCTAssertGreaterThanOrEqual(InvitationsAppearance.minimumTapSize, 44)
    }

    func testNavigationTitleReusesProfileInviteIconAndRefreshSymbol() throws {
        let source = try invitationsSource()
        XCTAssertTrue(source.contains("Image(ProfileMenuItem.invitations.icon)"))
        XCTAssertTrue(source.contains("ProfileMenuItem.invitations.tint"))
        XCTAssertTrue(source.contains("profile.menu.invite_friends"))
        XCTAssertTrue(source.contains("RefreshToolbarButton("))
        XCTAssertTrue(source.contains("labelKey: \"profile.invites.refresh\""))
        XCTAssertTrue(source.contains("identifier: \"profile.invites.refresh\""))
    }

    func testStatisticsCardKeepsAllFiveValuesInTwoColumns() throws {
        let source = try invitationsSource()
        for key in [
            "profile.invites.invited_count",
            "profile.invites.total_commission",
            "profile.invites.available_commission",
            "profile.invites.commission_rate",
            "profile.invites.pending_commission"
        ] {
            XCTAssertTrue(source.contains(key), key)
        }

        let card = try substring(
            source,
            from: "private func statisticsCard",
            to: "private func statistic("
        )
        XCTAssertTrue(card.contains("HStack(alignment: .top"))
        XCTAssertEqual(card.components(separatedBy: "VStack(alignment: .leading").count - 1, 3)
        XCTAssertEqual(card.components(separatedBy: "VStack(alignment: .leading, spacing: 11)").count - 1, 2)
        XCTAssertTrue(card.contains(".padding(.vertical, 13)"))

        let statistic = try substring(
            source,
            from: "private func statistic(",
            to: "private var invitationCodesHeader"
        )
        XCTAssertTrue(statistic.contains("VStack(alignment: .leading, spacing: 4)"))
        XCTAssertTrue(statistic.contains(".font(.footnote)"))
        XCTAssertTrue(statistic.contains(".font(.body.weight(.medium))"))
        XCTAssertFalse(statistic.contains(".font(.caption)"))
        XCTAssertFalse(statistic.contains(".font(.subheadline.weight(.medium))"))
    }

    func testGenerateAndCodeRowsUseCompactSymbols() throws {
        let source = try invitationsSource()
        XCTAssertTrue(source.contains("Image(systemName: \"plus.circle\")"))
        XCTAssertTrue(source.contains("\"doc.on.doc\""))
        XCTAssertTrue(source.contains("Image(systemName: \"square.and.arrow.up\")"))
        XCTAssertTrue(source.contains(".frame(minHeight: 52)"))
        XCTAssertFalse(source.contains("Text(LocalizedStringKey(\"profile.invites.copy_link\")"))
        XCTAssertFalse(source.contains("Text(LocalizedStringKey(\"profile.invites.share_link\")"))
    }

    func testOnlyInvitationCodesRegionIsScrollable() throws {
        let source = try invitationsSource()
        XCTAssertEqual(source.components(separatedBy: "ScrollView {").count - 1, 1)
        XCTAssertFalse(source.contains("List {"))
        XCTAssertTrue(source.contains("invitationCodesCard(info)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(source.contains(".scrollBounceBehavior(.basedOnSize)"))

        let card = try substring(
            source,
            from: "private func invitationCodesCard",
            to: "private func invitationCodesRegion"
        )
        XCTAssertTrue(card.contains("invitationCodesHeader"))
        XCTAssertTrue(card.contains("invitationCodesRegion(info)"))
        XCTAssertTrue(card.contains(".surfaceCard()"))

        let region = try substring(
            source,
            from: "private func invitationCodesRegion",
            to: "private func invitationCodeRow"
        )
        XCTAssertFalse(region.contains(".surfaceCard()"))
    }

    private func invitationsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Views/ProfileView.swift"))
        return try substring(
            source,
            from: "struct InvitationsView: View",
            to: "@MainActor\nfinal class CustomerServicePerformanceTrace"
        )
    }

    private func substring(_ source: String, from start: String, to end: String) throws -> String {
        let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound, start)
        let endIndex = try XCTUnwrap(
            source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound,
            end
        )
        return String(source[startIndex..<endIndex])
    }
}

final class InvitationAPIErrorPolicyTests: XCTestCase {
    func testInvitationMessageOnly500ReturnsVerbatimBusinessRejection() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"已达到创建数量上限"}"#.utf8),
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case let NetworkClientError.invitationRejected(message) = error else {
                return XCTFail("Expected invitation business rejection, got \(error)")
            }
            XCTAssertEqual(message, "已达到创建数量上限")
            XCTAssertEqual((error as? NetworkClientError)?.userFacingMessage, .verbatim(message))
        }
    }

    func testInvitationEnglishLimitMessageIsVerbatimBusinessRejection() {
        let message = "The maximum number of creations has been reached"
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"The maximum number of creations has been reached"}"#.utf8),
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case let NetworkClientError.invitationRejected(actual) = error else {
                return XCTFail("Expected invitation business rejection, got \(error)")
            }
            XCTAssertEqual(actual, message)
        }
    }

    func testInvitationProxy502WithMislabeledJSONKeepsSafeBusinessMessage() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"已达到创建数量上限"}"#.utf8),
            statusCode: 502,
            contentType: "text/html; charset=UTF-8",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case let NetworkClientError.invitationRejected(message) = error else {
                return XCTFail("Expected invitation business rejection, got \(error)")
            }
            XCTAssertEqual(message, "已达到创建数量上限")
        }
    }

    func testStandardProxy502WithMislabeledJSONRemainsConservative() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"已达到创建数量上限"}"#.utf8),
            statusCode: 502,
            contentType: "text/html; charset=UTF-8",
            context: .authenticated
        )) { error in
            guard case NetworkClientError.serviceUnavailable = error else {
                return XCTFail("Standard policy must keep enforcing JSON Content-Type")
            }
        }
    }

    func testInvitationGenericBadGatewayMessageIsNotBusinessFeedback() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Bad Gateway"}"#.utf8),
            statusCode: 502,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case NetworkClientError.serviceUnavailable = error else {
                return XCTFail("Generic gateway status text must stay infrastructure failure")
            }
        }
    }

    func testInvitation502WithoutSafeBusinessMessageRemainsInfrastructureFailure() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"proxy":"synthetic"}"#.utf8),
            statusCode: 502,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case NetworkClientError.serviceUnavailable = error else {
                return XCTFail("A JSON object without a safe message must not become a rejection")
            }
        }
    }

    func testStandardMessageOnly500RemainsConservative() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Synthetic business text"}"#.utf8),
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated
        )) { error in
            guard case NetworkClientError.serviceUnavailable = error else {
                return XCTFail("Standard policy must stay conservative")
            }
        }
    }

    func testInvitationDebugPayloadUsesOnlySafeTopLevelMessage() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"已达到创建数量上限","exception":"Synthetic\\Exception","file":"/srv/app/InviteController.php","line":18,"trace":[{"file":"/srv/app/InviteController.php"}]}"#.utf8),
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case let NetworkClientError.invitationRejected(message) = error else {
                return XCTFail("Expected safe invitation message, got \(error)")
            }
            XCTAssertEqual(message, "已达到创建数量上限")
            XCTAssertFalse(error.localizedDescription.contains("InviteController.php"))
            XCTAssertFalse(error.localizedDescription.contains("Synthetic"))
        }
    }

    func testInvitationDebugPayloadWithUnsafeTopLevelMessageIsRejected() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Failure in /srv/app/InviteController.php","exception":"Synthetic\\Exception","trace":[]}"#.utf8),
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case NetworkClientError.serviceUnavailable = error else {
                return XCTFail("Unsafe message must not be passed through")
            }
        }
    }

    func testStandardDebugPayloadRemainsConservative() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Safe-looking rejection","exception":"Synthetic\\Exception","trace":[]}"#.utf8),
            statusCode: 500,
            contentType: "application/json",
            context: .authenticated
        )) { error in
            guard case NetworkClientError.serviceUnavailable = error else {
                return XCTFail("Standard policy must not extract debug payload messages")
            }
        }
    }

    func testInvitation401KeepsAuthenticationExpiredSemantics() {
        XCTAssertThrowsError(try V2BoardAPIErrorParser.decodeResponse(
            data: Data(#"{"message":"Unauthenticated"}"#.utf8),
            statusCode: 401,
            contentType: "application/json",
            context: .authenticated,
            responsePolicy: .invitation
        )) { error in
            guard case NetworkClientError.authenticationExpired = error else {
                return XCTFail("Authenticated 401 must expire authentication")
            }
        }
    }
}

@MainActor
final class InvitationPhaseOneTests: XCTestCase {
    func testInviteFetchMapsFiveStatisticsAndOrdersCodes() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        let info = try await fixture.api.fetchInviteInfo(
            config: fixture.config,
            session: fixture.a
        )

        XCTAssertEqual(info.registeredCount, 5)
        XCTAssertEqual(info.validCommissionCents, 1_200)
        XCTAssertEqual(info.pendingCommissionCents, 300)
        XCTAssertEqual(info.commissionRate, 10)
        XCTAssertEqual(info.availableCommissionCents, 900)
        XCTAssertEqual(info.codes.map(\.id), [2, 1])
    }

    func testFirstEntryLoadRunsOnlyOnceForSameLoadedState() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        await fixture.model.loadInvitationsIfNeeded()
        await fixture.model.loadInvitationsIfNeeded()

        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(fixture.model.invitationsLoadState, .loaded)
    }

    func testManualRefreshRemainsAvailableAfterAutomaticLoad() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        await fixture.model.loadInvitationsIfNeeded()
        await fixture.model.loadInvitations()

        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.fetch, 2)
    }

    func testEmptyCodeListKeepsStatisticsAndUsesEmptyState() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCodesEmpty(true)

        await fixture.model.loadInvitationsIfNeeded()

        XCTAssertEqual(fixture.model.invitationsLoadState, .empty)
        XCTAssertEqual(fixture.model.invitations?.registeredCount, 5)
        XCTAssertEqual(fixture.model.invitations?.codes, [])
    }

    func testGenerateInviteCodeUsesOneWriteThenRefreshesCodes() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.model.loadInvitationsIfNeeded()

        let generated = await fixture.model.generateInviteCode()

        XCTAssertTrue(generated)
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 2)
        XCTAssertEqual(fixture.model.invitations?.codes.first?.code, "newer-synthetic-A-1")
        XCTAssertEqual(fixture.model.invitationFeedback, .localized("profile.invites.generated"))
        XCTAssertNil(fixture.model.message)
    }

    func testGenerateInviteCodeIsSingleFlight() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let gate = await fixture.state.holdInviteCreate()

        let first = Task { await fixture.model.generateInviteCode() }
        await fulfillment(of: [gate.entered], timeout: 2)
        let duplicate = await fixture.model.generateInviteCode()
        await gate.resume(.init(body: #"{"data":true}"#))
        let firstResult = await first.value

        XCTAssertFalse(duplicate)
        XCTAssertTrue(firstResult)
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
    }

    func testGenerateInviteCodeKeepsRootBusyOverlayHidden() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let gate = await fixture.state.holdInviteCreate()

        let generation = Task { await fixture.model.generateInviteCode() }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(fixture.model.busy)
        XCTAssertTrue(fixture.model.invitationActionInProgress)
        XCTAssertFalse(fixture.model.showsGlobalBusyIndicator)

        await gate.resume(.init(body: #"{"data":true}"#))
        let generated = await generation.value
        XCTAssertTrue(generated)
        XCTAssertFalse(fixture.model.busy)
        XCTAssertFalse(fixture.model.invitationActionInProgress)
        XCTAssertFalse(fixture.model.showsGlobalBusyIndicator)
    }

    func testInviteBusinessRejectionStaysInlineAndIsNotRetried() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(
            .messageOnlyBusinessRejection(500, "已达到创建数量上限")
        )

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(fixture.model.invitationFeedback, .verbatim("已达到创建数量上限"))
        XCTAssertNil(fixture.model.message)
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteEnglishLimitRejectionStaysExplicitAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let message = "The maximum number of creations has been reached"
        await fixture.state.configureInviteCreate(
            .messageOnlyBusinessRejection(500, message)
        )

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(fixture.model.invitationFeedback, .verbatim(message))
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteProxy502WithMislabeledJSONStaysExplicitAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(
            .mislabelledBusinessRejection(502, "已达到创建数量上限")
        )

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(fixture.model.invitationFeedback, .verbatim("已达到创建数量上限"))
        XCTAssertNotEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteGenericBadGateway502RemainsUnknownAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(
            .mislabelledBusinessRejection(502, "Bad Gateway")
        )

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteHTML502RemainsUnknownAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.html(502))

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteInvalidJSON502RemainsUnknownAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.malformedStatus(502))

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteJSON502WithoutMessageRemainsUnknownAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.jsonWithoutMessage(502))

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteDebugPayloadExtractsOnlySafeBusinessMessage() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(
            .debugBusinessRejection(500, "已达到创建数量上限")
        )

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(fixture.model.invitationFeedback, .verbatim("已达到创建数量上限"))
        XCTAssertFalse(String(describing: fixture.model.invitationFeedback).contains("InviteController.php"))
        XCTAssertFalse(String(describing: fixture.model.invitationFeedback).contains("Synthetic"))
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteDataFalseIsDefiniteLocalizedFailureAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.dataFalse)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized("profile.invites.generate_failed")
        )
        XCTAssertNotEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteGenerationCancellationIsSilent() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.cancelled)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertNil(fixture.model.invitationFeedback)
        XCTAssertNil(fixture.model.message)
        XCTAssertFalse(fixture.model.invitationActionInProgress)
    }

    func testInviteGenerationDNSFailureKeepsNetworkFeedbackAndOneAttempt() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.dns)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(fixture.model.invitationFeedback, .localized(L10nKey.errorDNS))
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteGenerationTimeoutRemainsUnknownAndIsNotReplayed() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.timeout)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteGenerationConnectionLossRemainsUnknownAndIsNotReplayed() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.loss)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteGenerationNonHTTPResponseRemainsUnknown() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.nonHTTP)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteHTML500DoesNotLeakBodyAndRemainsUnknown() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.html(500))

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        XCTAssertFalse(String(describing: fixture.model.invitationFeedback).contains("internal details"))
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteInvalidJSONDoesNotLeakAndRemainsUnknown() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(.malformed)

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        XCTAssertEqual(
            fixture.model.invitationFeedback,
            .localized(L10nKey.errorWriteResultUnknown)
        )
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInviteExpiredSessionKeepsAuthenticationSemanticsAndDoesNotRefresh() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureInviteCreate(
            .messageOnlyBusinessRejection(403, "未登录或登陆已过期")
        )

        let generated = await fixture.model.generateInviteCode()

        XCTAssertFalse(generated)
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
        XCTAssertNil(fixture.model.session)
    }

    func testAccountChangeClearsInviteDataAndActionFeedback() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let generated = await fixture.model.generateInviteCode()
        XCTAssertTrue(generated)
        XCTAssertNotNil(fixture.model.invitations)
        XCTAssertNotNil(fixture.model.invitationFeedback)

        await fixture.model.establishAuthenticatedSession(fixture.b, source: .login)

        XCTAssertNil(fixture.model.invitations)
        XCTAssertEqual(fixture.model.invitationsLoadState, .idle)
        XCTAssertNil(fixture.model.invitationFeedback)
        XCTAssertFalse(fixture.model.invitationActionInProgress)
    }

    func testGenerationChangeInvalidatesLateInviteCreationCompletion() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let gate = await fixture.state.holdInviteCreate()
        let generationTask = Task { await fixture.model.generateInviteCode() }
        await fulfillment(of: [gate.entered], timeout: 2)

        await fixture.model.establishAuthenticatedSession(fixture.a, source: .login)
        await gate.resume(.init(body: #"{"data":true}"#))
        let result = await generationTask.value

        XCTAssertFalse(result)
        XCTAssertFalse(fixture.model.invitationActionInProgress)
        XCTAssertNil(fixture.model.invitationFeedback)
        let counts = await fixture.state.inviteCounts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testInvitationUIUsesFullLinkActionsAndNoDetailsEndpoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Views/ProfileView.swift"))
        XCTAssertTrue(source.contains("ProfileInviteLinkBuilder.url"))
        XCTAssertTrue(source.contains("ShareLink(item: url)"))
        XCTAssertTrue(source.contains("UIPasteboard.general.string = url.absoluteString"))
        XCTAssertTrue(source.contains("loadInvitationsIfNeeded"))
        XCTAssertTrue(source.contains(".disabled(url == nil)"))
        XCTAssertFalse(source.contains("invite/details"))
    }

    func testInvitationLocalizationKeysExistInBothLanguages() throws {
        let keys = [
            "profile.invites.statistics", "profile.invites.invited_count",
            "profile.invites.total_commission", "profile.invites.pending_commission",
            "profile.invites.commission_rate", "profile.invites.available_commission",
            "profile.invites.generate", "profile.invites.generating",
            "profile.invites.generate_failed", "profile.invites.generated",
            "profile.invites.loading", "profile.invites.load_failed",
            "profile.invites.not_loaded", "profile.invites.no_codes",
            "profile.invites.codes", "profile.invites.refresh", "profile.invites.retry",
            "profile.invites.copy_link", "profile.invites.share_link",
            "profile.invites.copied", "profile.invites.copy_failed",
            "profile.invites.link_unavailable"
        ]
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"), locale)
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            for key in keys {
                XCTAssertNotEqual(
                    bundle.localizedString(forKey: key, value: key, table: nil),
                    key,
                    "\(locale): \(key)"
                )
            }
        }
    }
}

private actor TrafficResponseGate {
    let entered = XCTestExpectation(description: "traffic request suspended")
    private var records: [ProfileTrafficLogRecord]?
    private var continuation: CheckedContinuation<[ProfileTrafficLogRecord], Never>?

    func receive() async -> [ProfileTrafficLogRecord] {
        entered.fulfill()
        return await withCheckedContinuation {
            if let records { $0.resume(returning: records) }
            else { continuation = $0 }
        }
    }

    func resume(_ records: [ProfileTrafficLogRecord]) {
        self.records = records
        continuation?.resume(returning: records)
        continuation = nil
    }
}

private enum TrafficFixtureOutcome: Sendable {
    case records([ProfileTrafficLogRecord])
    case failure(NetworkClientError)
    case cancelled
    case held(TrafficResponseGate)
}

private actor TrafficLogAPIStub: TrafficLogProviding {
    private var outcomes: [String: TrafficFixtureOutcome] = [:]
    private var calls: [String: Int] = [:]

    func set(_ outcome: TrafficFixtureOutcome, auth: String) {
        outcomes[auth] = outcome
    }

    func callCount(auth: String) -> Int { calls[auth, default: 0] }

    func fetchTrafficLog(
        config: AppConfig,
        session: UserSession
    ) async throws -> [ProfileTrafficLogRecord] {
        calls[session.authData, default: 0] += 1
        switch outcomes[session.authData] ?? .records([]) {
        case let .records(records): return records
        case let .failure(error): throw error
        case .cancelled: throw CancellationError()
        case let .held(gate): return await gate.receive()
        }
    }
}

@MainActor
private final class TrafficPhaseOneFixture {
    let suite = "NetworkClient.traffic-phase-one.\(UUID().uuidString)"
    let api = TrafficLogAPIStub()
    let sessions: SessionStore
    let model: AppModel
    let accountA = TrafficPhaseOneFixture.session("A")
    let accountB = TrafficPhaseOneFixture.session("B")

    init() async {
        sessions = SessionStore(
            keychain: MemorySessionKeychain(),
            defaultsSuiteName: suite
        )
        model = AppModel(
            offline: false,
            businessDataAPI: BootstrapBusinessAPI(),
            trafficLogAPI: api,
            nodeRepository: BootstrapNodeRepository(),
            apiHealthMonitor: APIHealthMonitor(observeNetwork: false),
            sessionStore: sessions,
            initialConfig: Self.config
        )
        await model.establishAuthenticatedSession(accountA, source: .login)
    }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    static let config = AppConfig(
        appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
        telegramGroup: nil, supportAPI: nil, updateURL: nil,
        userAgent: "NetworkClientTests/1", latencyDisplayRatio: 1, inviteLink: nil,
        apiBaseURLs: ["https://api.cloudflare.com"],
        activeAPIBaseURL: "https://api.cloudflare.com",
        builtInProxy: []
    )

    static func session(_ name: String) -> UserSession {
        UserSession(
            email: "\(name)@example.invalid",
            authData: "synthetic-traffic-\(name)",
            accountToken: nil,
            subscriptionURL: "",
            uploadBytes: 0,
            downloadBytes: 0,
            transferEnableBytes: 0,
            expiredAt: 0,
            planID: nil,
            planName: "",
            balanceCents: nil,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private struct TrafficAPIFixtureTransport: ManagedNetworkTransport {
    let status: Int
    let body: String

    init(
        status: Int = 200,
        body: String = #"{"data":[{"u":1024,"d":2048,"record_at":1735689600,"server_rate":3.5}]}"#
    ) {
        self.status = status
        self.body = body
    }

    func data(
        for request: URLRequest,
        kind: NetworkRequestKind
    ) async throws -> (Data, URLResponse) {
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    func finishTasksAndInvalidate() {}
}

final class TrafficDetailsPhaseOneTests: XCTestCase {
    func testTrafficTitleIconIsSeventyFivePercentOfOriginalSize() {
        XCTAssertEqual(TrafficDetailsAppearance.titleIconSize, 14.25)
        XCTAssertEqual(TrafficDetailsAppearance.actionIconSize, 17)
        XCTAssertGreaterThanOrEqual(TrafficDetailsAppearance.minimumTapSize, 44)
    }

    func testLongTrafficFixtureRequiresExplicitLaunchArgument() {
        XCTAssertNil(TrafficInterfaceFixture.longList(arguments: []))
        XCTAssertNil(TrafficInterfaceFixture.longList(arguments: ["--ui-sample"]))
        XCTAssertNil(TrafficInterfaceFixture.longList(arguments: ["--offline"]))
    }

    func testLongTrafficFixtureHasFortyStableDescendingDaysAndMixedUnits() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let rows = try XCTUnwrap(TrafficInterfaceFixture.longList(
            arguments: [TrafficInterfaceFixture.longListLaunchArgument],
            calendar: calendar
        ))

        XCTAssertEqual(rows.count, 40)
        XCTAssertEqual(rows.map(\.recordAtUnix), rows.map(\.recordAtUnix).sorted(by: >))
        XCTAssertEqual(
            TrafficDateFormatter.day(
                unixSeconds: try XCTUnwrap(rows.first?.recordAtUnix),
                locale: Locale(identifier: "zh-Hans"),
                timeZone: calendar.timeZone
            ),
            "2026/10/31"
        )
        XCTAssertEqual(
            TrafficDateFormatter.day(
                unixSeconds: try XCTUnwrap(rows.last?.recordAtUnix),
                locale: Locale(identifier: "zh-Hans"),
                timeZone: calendar.timeZone
            ),
            "2026/09/22"
        )

        let units = Set(rows.flatMap {
            [
                TrafficFormatter.adaptive($0.uploadBytes, locale: Locale(identifier: "en_US_POSIX")).unit,
                TrafficFormatter.adaptive($0.downloadBytes, locale: Locale(identifier: "en_US_POSIX")).unit,
            ]
        })
        XCTAssertTrue(units.isSuperset(of: ["KB", "MB", "GB", "TB"]))
    }

    func testLongFixtureIsDebugOnlyAndLoadedThroughExistingUISampleGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/AppModel.swift"))
        let debugStart = try XCTUnwrap(source.range(of: "#if DEBUG\nenum TrafficInterfaceFixture")?.lowerBound)
        let debugEnd = try XCTUnwrap(
            source.range(of: "#endif", range: debugStart..<source.endIndex)?.upperBound
        )
        let fixtureRegion = String(source[debugStart..<debugEnd])
        XCTAssertTrue(fixtureRegion.contains("--ui-traffic-long-list"))
        XCTAssertTrue(fixtureRegion.contains("guard offline"))
        XCTAssertTrue(fixtureRegion.contains("--ui-sample"))
        XCTAssertFalse(fixtureRegion.contains("UserDefaults"))
        XCTAssertFalse(fixtureRegion.contains("Keychain"))
    }

    func testAPIFetchParsesTrafficFieldsIncludingServerRate() async throws {
        let transport = TrafficAPIFixtureTransport()
        let api = V2BoardAPIClient(
            recoveryRouter: APIRecoveryRouter(
                recoveryRuntime: CommerceUnusedRecoveryRuntime(),
                recoveryInitiallySuspendedForFormalVPN: false
            ),
            transport: transport
        )
        let records = try await api.fetchTrafficLog(
            config: TrafficPhaseOneFixture.config,
            session: TrafficPhaseOneFixture.session("API")
        )

        XCTAssertEqual(records, [ProfileTrafficLogRecord(
            uploadBytes: 1_024,
            downloadBytes: 2_048,
            recordAtUnix: 1_735_689_600,
            serverRate: 3.5
        )])
    }

    func testTrafficAPI401And403KeepAuthenticationExpiredSemantics() async throws {
        for status in [401, 403] {
            let transport = TrafficAPIFixtureTransport(
                status: status,
                body: #"{"message":"Unauthenticated"}"#
            )
            let api = V2BoardAPIClient(
                recoveryRouter: APIRecoveryRouter(
                    recoveryRuntime: CommerceUnusedRecoveryRuntime(),
                    recoveryInitiallySuspendedForFormalVPN: false
                ),
                transport: transport
            )
            do {
                _ = try await api.fetchTrafficLog(
                    config: TrafficPhaseOneFixture.config,
                    session: TrafficPhaseOneFixture.session("HTTP-\(status)")
                )
                XCTFail("HTTP \(status) must expire authentication")
            } catch NetworkClientError.authenticationExpired {
                // Expected.
            } catch {
                XCTFail("Unexpected HTTP \(status) error: \(error)")
            }
        }
    }

    func testDailyAggregationSumsRawTrafficIgnoresRateAndSortsDescending() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let records = [
            record(day: 2, upload: 100, download: 200, rate: 10),
            record(day: 1, upload: 8, download: 16, rate: 1),
            record(day: 2, upload: 300, download: 400, rate: 0.5),
        ]

        let days = ProfileTrafficAggregation.daily(records, calendar: calendar)

        XCTAssertEqual(days.count, 2)
        XCTAssertGreaterThan(days[0].recordAtUnix, days[1].recordAtUnix)
        XCTAssertEqual(days[0].uploadBytes, 400)
        XCTAssertEqual(days[0].downloadBytes, 600)
        XCTAssertEqual(days[0].totalBytes, 1_000)
        XCTAssertEqual(days[1].uploadBytes, 8)
        XCTAssertEqual(days[1].downloadBytes, 16)
    }

    func testDailyAggregationClampsIntegerOverflow() {
        let records = [
            ProfileTrafficLogRecord(
                uploadBytes: Int64.max,
                downloadBytes: Int64.max,
                recordAtUnix: 1_735_689_600,
                serverRate: 1
            ),
            ProfileTrafficLogRecord(
                uploadBytes: 1,
                downloadBytes: 1,
                recordAtUnix: 1_735_689_601,
                serverRate: 2
            ),
        ]
        let day = ProfileTrafficAggregation.daily(records).first
        XCTAssertEqual(day?.uploadBytes, Int64.max)
        XCTAssertEqual(day?.downloadBytes, Int64.max)
        XCTAssertEqual(day?.totalBytes, Int64.max)
    }

    func testTrafficDateFormatsChineseAndEnglishUsingProvidedTimeZone() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let timestamp: Int64 = 1_735_689_600
        XCTAssertEqual(
            TrafficDateFormatter.day(
                unixSeconds: timestamp,
                locale: Locale(identifier: "zh-Hans"),
                timeZone: timeZone
            ),
            "2025/01/01"
        )
        XCTAssertEqual(
            TrafficDateFormatter.day(
                unixSeconds: timestamp,
                locale: Locale(identifier: "en_US"),
                timeZone: timeZone
            ),
            "01/01/2025"
        )
    }

    func testAdaptiveFormatterUsesBinaryUnitsThroughTerabytes() {
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(TrafficFormatter.adaptive(535, locale: locale).combined, "535 B")
        XCTAssertEqual(TrafficFormatter.adaptive(1_536, locale: locale).combined, "1.5 KB")
        XCTAssertEqual(TrafficFormatter.adaptive(5_075_845, locale: locale).combined, "4.84 MB")
        XCTAssertEqual(TrafficFormatter.adaptive(1_116_693_258, locale: locale).combined, "1.04 GB")
        XCTAssertEqual(TrafficFormatter.adaptive(1_099_511_627_776, locale: locale).combined, "1 TB")
    }

    @MainActor
    func testFirstEntryLoadsOnceAndManualRefreshLoadsAgain() async {
        let fixture = await TrafficPhaseOneFixture()
        defer { fixture.cleanUp() }
        await fixture.api.set(.records([record(day: 1)]), auth: fixture.accountA.authData)

        await fixture.model.loadTrafficIfNeeded()
        await fixture.model.loadTrafficIfNeeded()
        let automaticCalls = await fixture.api.callCount(auth: fixture.accountA.authData)
        XCTAssertEqual(automaticCalls, 1)
        XCTAssertEqual(fixture.model.trafficLoadState, .loaded)

        await fixture.model.refreshTraffic()
        let totalCalls = await fixture.api.callCount(auth: fixture.accountA.authData)
        XCTAssertEqual(totalCalls, 2)
    }

    @MainActor
    func testLoadingRequestIsSingleFlight() async {
        let fixture = await TrafficPhaseOneFixture()
        defer { fixture.cleanUp() }
        let gate = TrafficResponseGate()
        await fixture.api.set(.held(gate), auth: fixture.accountA.authData)

        let first = Task { await fixture.model.loadTrafficIfNeeded() }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(fixture.model.trafficLoadState, .loading)
        let duplicate = Task { await fixture.model.refreshTraffic() }
        let calls = await fixture.api.callCount(auth: fixture.accountA.authData)
        XCTAssertEqual(calls, 1)

        await gate.resume([record(day: 1)])
        await first.value
        await duplicate.value
        XCTAssertEqual(fixture.model.trafficLoadState, .loaded)
    }

    @MainActor
    func testEmptyFailureRetryAndStaleRefreshPreserveExpectedState() async {
        let fixture = await TrafficPhaseOneFixture()
        defer { fixture.cleanUp() }
        let auth = fixture.accountA.authData

        await fixture.api.set(.records([]), auth: auth)
        await fixture.model.loadTrafficIfNeeded()
        XCTAssertEqual(fixture.model.trafficLoadState, .empty)

        await fixture.api.set(.failure(.noConnection), auth: auth)
        await fixture.model.refreshTraffic()
        guard case .failed = fixture.model.trafficLoadState else {
            return XCTFail("Expected initial failure")
        }

        await fixture.api.set(.records([record(day: 1)]), auth: auth)
        await fixture.model.refreshTraffic()
        XCTAssertEqual(fixture.model.dailyTraffic.count, 1)

        await fixture.api.set(.failure(.timedOut), auth: auth)
        await fixture.model.refreshTraffic()
        guard case .stale = fixture.model.trafficLoadState else {
            return XCTFail("Expected stale data after refresh failure")
        }
        XCTAssertEqual(fixture.model.dailyTraffic.count, 1)
    }

    @MainActor
    func testCancellationIsSilentAndAuthenticationExpiryClearsSession() async {
        let cancelled = await TrafficPhaseOneFixture()
        defer { cancelled.cleanUp() }
        await cancelled.api.set(.cancelled, auth: cancelled.accountA.authData)
        await cancelled.model.loadTrafficIfNeeded()
        XCTAssertEqual(cancelled.model.trafficLoadState, .idle)
        XCTAssertNotNil(cancelled.model.session)

        let expired = await TrafficPhaseOneFixture()
        defer { expired.cleanUp() }
        await expired.api.set(
            .failure(.authenticationExpired("synthetic")),
            auth: expired.accountA.authData
        )
        await expired.model.loadTrafficIfNeeded()
        XCTAssertNil(expired.model.session)
        XCTAssertEqual(expired.model.trafficLoadState, .idle)
    }

    @MainActor
    func testGenerationChangeRejectsLateAccountResponseAndSignOutClearsTraffic() async {
        let fixture = await TrafficPhaseOneFixture()
        defer { fixture.cleanUp() }
        let gate = TrafficResponseGate()
        await fixture.api.set(.held(gate), auth: fixture.accountA.authData)

        let old = Task { await fixture.model.loadTrafficIfNeeded() }
        await fulfillment(of: [gate.entered], timeout: 2)
        await fixture.model.establishAuthenticatedSession(fixture.accountB, source: .login)
        await fixture.api.set(.records([record(day: 3, upload: 33)]), auth: fixture.accountB.authData)
        await fixture.model.loadTrafficIfNeeded()
        XCTAssertEqual(fixture.model.dailyTraffic.first?.uploadBytes, 33)

        await gate.resume([record(day: 1, upload: 11)])
        await old.value
        XCTAssertEqual(fixture.model.dailyTraffic.first?.uploadBytes, 33)

        await fixture.model.signOut()
        XCTAssertTrue(fixture.model.dailyTraffic.isEmpty)
        XCTAssertEqual(fixture.model.trafficLoadState, .idle)
    }

    func testTrafficUIHasFixedHeaderAndOnlyRecordsRegionScrolls() throws {
        let source = try trafficViewSource()
        XCTAssertTrue(source.contains("Image(systemName: ProfileMenuItem.traffic.icon)"))
        XCTAssertTrue(source.contains("RefreshToolbarButton("))
        XCTAssertTrue(source.contains("labelKey: \"profile.traffic.refresh\""))
        XCTAssertTrue(source.contains("identifier: \"profile.traffic.refresh\""))
        XCTAssertTrue(source.contains("profile.traffic.table.header"))
        XCTAssertTrue(source.contains("profile.traffic.records.scroll"))
        XCTAssertTrue(source.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertEqual(source.components(separatedBy: "ScrollView {").count - 1, 1)
        XCTAssertFalse(source.contains(".refreshable"))
        XCTAssertFalse(source.contains("按日历史记录尚未接入"))
    }

    func testTrafficLocalizationKeysExistInBothLanguages() throws {
        let keys = [
            "profile.menu.traffic_details", "profile.traffic.date",
            "profile.traffic.upload", "profile.traffic.download",
            "profile.traffic.total", "profile.traffic.loading",
            "profile.traffic.empty", "profile.traffic.refresh",
            "profile.traffic.retry", "profile.traffic.load_failed",
        ]
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: key, table: nil), key)
            }
        }
    }

    private func record(
        day: Int,
        upload: Int64 = 1,
        download: Int64 = 2,
        rate: Double = 1
    ) -> ProfileTrafficLogRecord {
        ProfileTrafficLogRecord(
            uploadBytes: upload,
            downloadBytes: download,
            recordAtUnix: 1_735_689_600 + Int64(day * 86_400),
            serverRate: rate
        )
    }

    private func trafficViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Views/ProfileView.swift"))
        let start = try XCTUnwrap(source.range(of: "enum TrafficDetailsAppearance")?.lowerBound)
        return String(source[start...])
    }
}

final class CommercePlansLayoutTests: XCTestCase {
    func testExistingPlansUseFixedRefreshIndicatorOnlyWhileLoading() {
        XCTAssertTrue(CommercePlansLayout.showsFixedRefreshIndicator(
            loadState: .loading,
            hasPlans: true
        ))
        XCTAssertFalse(CommercePlansLayout.showsFixedRefreshIndicator(
            loadState: .loaded,
            hasPlans: true
        ))
    }

    func testInitialLoadingRemainsInPlansRegion() {
        XCTAssertFalse(CommercePlansLayout.showsFixedRefreshIndicator(
            loadState: .loading,
            hasPlans: false
        ))
    }

    func testFixedAndScrollableRegionsKeepOneTenPointBoundary() {
        XCTAssertEqual(CommercePlansLayout.sectionSpacing, 10)
    }
}

@MainActor
final class CommerceCouponPhaseOneTests: XCTestCase {
    func testAppModelCouponValidationReturnsAPICouponWithoutGlobalMessage() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        let result = await fixture.model.validateCoupon(code: " SAVE20 ", planID: 1)

        XCTAssertEqual(result, .available(PurchaseCoupon(id: 9, name: "Fixture Coupon")))
        XCTAssertNil(fixture.model.message)
    }

    func testExpiredCouponBusinessMessageMapsToExpiredInlineFeedback() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureCoupon(.business("This coupon has expired"))

        let result = await fixture.model.validateCoupon(code: "EXPIRED", planID: 1)

        XCTAssertEqual(result, .unavailable(.localized("purchase.payment.coupon_expired")))
        XCTAssertNil(fixture.model.message)
    }

    func testOtherCouponBusinessMessageMapsToUnavailableInlineFeedback() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureCoupon(.business(
            "The coupon code cannot be used for this subscription"
        ))

        let result = await fixture.model.validateCoupon(code: "WRONG-PLAN", planID: 1)

        XCTAssertEqual(result, .unavailable(.localized("purchase.payment.coupon_unavailable")))
        XCTAssertNil(fixture.model.message)
    }

    func testArbitraryCouponBusinessRejectionUsesUnavailableWithoutLocalRules() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureCoupon(.business("Synthetic coupon rejection"))

        let result = await fixture.model.validateCoupon(code: "SYNTHETIC", planID: 1)

        XCTAssertEqual(result, .unavailable(.localized("purchase.payment.coupon_unavailable")))
    }

    func testCoupon401UsesAuthenticationExpiryInsteadOfUnavailableFeedback() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureCoupon(.unauthorized)

        let result = await fixture.model.validateCoupon(code: "SAVE20", planID: 1)

        XCTAssertEqual(result, .unavailable(.localized(L10nKey.errorAuthenticationExpired)))
        XCTAssertEqual(fixture.model.authMessage, .localized(L10nKey.errorAuthenticationExpired))
        XCTAssertNil(fixture.model.session)
    }

    func testCouponCancellationStaysSilent() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configureCoupon(.cancelled)

        let result = await fixture.model.validateCoupon(code: "SAVE20", planID: 1)

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(fixture.model.message)
        XCTAssertNil(fixture.model.authMessage)
    }

    func testCouponBusinessFeedbackFromOldAccountIsSilentlyDiscarded() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let gate = await fixture.state.holdCoupon()
        let validation = Task {
            await fixture.model.validateCoupon(code: "EXPIRED", planID: 1)
        }
        await fulfillment(of: [gate.entered], timeout: 2)

        await fixture.model.establishAuthenticatedSession(fixture.b, source: .login)
        await gate.resume(.init(
            status: 500,
            body: #"{"message":"This coupon has expired"}"#
        ))
        let result = await validation.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(fixture.model.message)
        XCTAssertNil(fixture.model.authMessage)
        let aRequests = await fixture.state.couponCount(auth: fixture.a.authData)
        let bRequests = await fixture.state.couponCount(auth: fixture.b.authData)
        XCTAssertEqual(aRequests, 1)
        XCTAssertEqual(bRequests, 0)
    }

    func testCouponBusinessMappingDoesNotCaptureNetworkOrRateLimitErrors() {
        let cases: [(NetworkClientError, LocalizedMessage)] = [
            (.dnsFailure, .localized(L10nKey.errorDNS)),
            (.tlsFailure, .localized(L10nKey.errorTLS)),
            (.timedOut, .localized(L10nKey.errorTimeout)),
            (.noConnection, .localized(L10nKey.errorNetworkUnavailable)),
            (.rateLimited, .localized(L10nKey.errorRateLimited))
        ]
        for (error, expectedFeedback) in cases {
            XCTAssertNil(AppModel.couponBusinessFeedback(for: error))
            XCTAssertEqual(error.userFacingMessage, expectedFeedback)
        }
    }

    func testCreateOrderWithoutCouponOmitsCouponCode() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        await fixture.buy()

        let codes = await fixture.state.submittedCouponCodes(auth: fixture.a.authData)
        XCTAssertEqual(codes.count, 1)
        XCTAssertNil(codes[0])
    }

    func testCreateOrderPassesValidatedCouponCodeOnce() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        let validation = await fixture.model.validateCoupon(code: "SAVE20", planID: 1)
        guard case .available = validation else {
            return XCTFail("Expected coupon validation success")
        }
        await fixture.buy(couponCode: "SAVE20")

        let codes = await fixture.state.submittedCouponCodes(auth: fixture.a.authData)
        XCTAssertEqual(codes, ["SAVE20"])
        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 1)
    }
}

@MainActor
final class WriteRedirectTests: XCTestCase {
    func testDirect301() async throws { try await assertDirect(301) }
    func testDirect302() async throws { try await assertDirect(302) }
    func testDirect303() async throws { try await assertDirect(303) }

    func testSemanticGETWriteDoesNotFollowAnyRedirect() async throws {
        for code in [301, 302, 303, 307, 308] { try await assertDirect(code, method: "GET") }
    }
    func testLoginWriteDoesNotFollowRedirect() async throws { try await assertDirect(307, kind: .apiLogin) }

    func testRecoverySharedTaskPolicyRejectsAllWriteRedirects() async throws {
        let server = try RedirectLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        // ProxyTaskMetrics inherits this exact task delegate. Only the SOCKS
        // socket/Core is substituted; Foundation executes real HTTP redirects.
        for code in [301, 302, 303, 307, 308] {
            var request = URLRequest(url: server.url("/original/\(code)"))
            request.httpMethod = "POST"
            request.httpBody = Data("synthetic-write-body".utf8)
            let (_, response) = try await session.data(for: request,
                delegate: NetworkRedirectPolicyDelegate(kind: .apiWrite))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, code)
            XCTAssertEqual(server.requests(at: "/original/\(code)").count, 1)
            XCTAssertEqual(server.requests(at: "/redirected/\(code)").count, 0)
        }
    }

    func testReadRedirectsStillFollowForDirectAndRecoverySharedPolicy() async throws {
        for recovery in [false, true] {
            let server = try RedirectLoopbackServer()
            try await server.start()
            let session = URLSession(configuration: .ephemeral)
            let transport = URLSessionNetworkTransport(session: session)
            defer { transport.finishTasksAndInvalidate(); server.stop() }
            for code in [301, 302, 303, 307, 308] {
                let request = URLRequest(url: server.url("/original/\(code)"))
                let response: URLResponse
                if recovery {
                    (_, response) = try await session.data(for: request,
                        delegate: NetworkRedirectPolicyDelegate(kind: .apiRead))
                } else { (_, response) = try await transport.data(for: request, kind: .apiRead) }
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(server.requests(at: "/original/\(code)").count, 1)
                XCTAssertEqual(server.requests(at: "/redirected/\(code)").count, 1)
            }
        }
    }

    func testRedirectIsUnknownEvenWithBusinessLookingJSONAndNeverChangesHost() async throws {
        for code in [301, 302, 303, 307, 308] {
            let fixture = try await WriteOutcomeFixture()
            defer { fixture.cleanUp() }
            await fixture.state.configure(create: .redirect(code), newOrders: 0)
            do {
                _ = try await fixture.api.createOrder(config: fixture.config, session: fixture.a,
                    planID: 1, period: .month, couponCode: nil)
                XCTFail("Expected unknown")
            } catch { XCTAssertEqual(error as? PurchaseCommerceError, .orderCreationResultUnknown) }
            let counts = await fixture.state.counts(auth: fixture.a.authData)
            XCTAssertEqual(counts.create, 1)
            let starts = await fixture.runtime.starts
            XCTAssertEqual(starts, 0)
        }
    }

    func testCommerceWritePrimaryFailureCannotStartRecoveryWhileFormalVPNStateIsUnknown() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let transport = RecordingNetworkTransport { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let router = APIRecoveryRouter(
            recoveryRuntime: fixture.runtime,
            writeTransportFactory: { transport }
        )
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)

        do {
            _ = try await api.createOrder(
                config: fixture.config,
                session: fixture.a,
                planID: 1,
                period: .month,
                couponCode: nil
            )
            XCTFail("Commerce must not enter App-only recovery while formal VPN state is unknown")
        } catch {}

        let starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 0)
    }

    func testEveryProductionMutationCarriesSemanticWriteKind() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let transport = RecordingNetworkTransport { request, kind in
            let status = kind == .writeRouteProbe ? 200 : 307
            let body = kind == .writeRouteProbe ? #"{"data":{}}"# : #"{"data":false}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let router = APIRecoveryRouter(recoveryRuntime: fixture.runtime, recoveryInitiallySuspendedForFormalVPN: false, writeTransportFactory: { transport })
        let api = V2BoardAPIClient(recoveryRouter: router, transport: transport)
        let operations: [() async throws -> Void] = [
            { _ = try await api.login(config: fixture.config, email: fixture.a.email, password: "synthetic") },
            { try await api.register(config: fixture.config, email: fixture.a.email, emailCode: nil, password: "synthetic", inviteCode: nil) },
            { try await api.sendRegistrationEmailCode(config: fixture.config, email: fixture.a.email) },
            { try await api.sendPasswordResetEmailCode(config: fixture.config, email: fixture.a.email) },
            { try await api.resetPassword(config: fixture.config, email: fixture.a.email, emailCode: "synthetic", password: "synthetic") },
            { _ = try await api.createOrder(config: fixture.config, session: fixture.a, planID: 1, period: .month, couponCode: nil) },
            { _ = try await api.checkoutOrder(config: fixture.config, session: fixture.a, tradeNo: "trade", methodID: 1) },
            { try await api.cancelOrder(config: fixture.config, session: fixture.a, tradeNo: "trade") },
            { try await api.createInviteCode(config: fixture.config, session: fixture.a) },
            { try await api.changePassword(config: fixture.config, session: fixture.a, oldPassword: "synthetic", newPassword: "synthetic-next") }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("Redirect must be unknown") }
            catch let error as NetworkClientError { XCTAssertEqual(error.logCategory, "write_result_unknown") }
            catch let error as PurchaseCommerceError {
                XCTAssertTrue([.orderCreationResultUnknown, .checkoutResultUnknown, .cancellationResultUnknown].contains(error))
            }
        }
        let calls = await transport.calls
        let writes = calls.filter { $0.kind.isNonIdempotentWrite }
        XCTAssertEqual(writes.count, 10)
        XCTAssertEqual(writes.filter { $0.kind == .apiLogin }.count, 1)
        XCTAssertEqual(writes.filter { $0.method == "GET" }.count, 1)
        XCTAssertEqual(Set(writes.map(\.host)), ["first.api.invalid"])
        XCTAssertEqual(calls.filter { $0.kind == .writeRouteProbe }.count, 10)
    }

    func testCouponPOSTRemainsReadPolicy() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let transport = RecordingNetworkTransport { request, _ in
            (Data(#"{"data":{"id":1,"name":"Fixture"}}"#.utf8), HTTPURLResponse(url: request.url!,
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let api = V2BoardAPIClient(transport: transport)
        _ = try await api.checkCoupon(config: fixture.config, session: fixture.a, code: "synthetic", planID: 1)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.apiRead])
        XCTAssertEqual(calls.map(\.method), ["POST"])
        let body = try XCTUnwrap(calls.first?.body)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["code"] as? String, "synthetic")
        XCTAssertEqual(payload["plan_id"] as? Int, 1)
        XCTAssertNil(payload["period"])
    }

    func test401And429RemainExplicitEvenWithUnusableResponseBody() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        for status in [401, 429] {
            let transport = RecordingNetworkTransport { request, kind in
                let probe = kind == .writeRouteProbe
                return (Data((probe ? #"{"data":{}}"# : "unusable-body").utf8),
                    HTTPURLResponse(url: request.url!, statusCode: probe ? 200 : status,
                        httpVersion: nil, headerFields: ["Content-Type": probe ? "application/json" : "text/html"])!)
            }
            let api = V2BoardAPIClient(recoveryRouter: APIRecoveryRouter(
                recoveryRuntime: f.runtime, writeTransportFactory: { transport }), transport: transport)
            do {
                try await api.sendRegistrationEmailCode(config: f.config, email: f.a.email)
                XCTFail("Expected explicit rejection")
            } catch let error as NetworkClientError {
                XCTAssertEqual(error.logCategory, status == 401 ? "backend_business" : "rate_limited")
            }
            let calls = await transport.calls
            XCTAssertEqual(calls.filter { $0.kind.isNonIdempotentWrite }.count, 1)
        }
    }

    private func assertDirect(_ code: Int, method: String = "POST", kind: NetworkRequestKind = .apiWrite) async throws {
        let server = try RedirectLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let transport = URLSessionNetworkTransport(profile: .api)
        defer { transport.finishTasksAndInvalidate() }
        var request = URLRequest(url: server.url("/original/\(code)"))
        request.httpMethod = method
        if method == "POST" { request.httpBody = Data("synthetic-write-body".utf8) }
        let (_, response) = try await transport.data(for: request, kind: kind)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, code)
        let original = server.requests(at: "/original/\(code)")
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(original.first?.method, method)
        if method == "POST" { XCTAssertEqual(original.first?.body, "synthetic-write-body") }
        XCTAssertEqual(server.requests(at: "/redirected/\(code)").count, 0)
    }
}

@MainActor
final class UnknownWriteResultTests: XCTestCase {
    func testDefiniteCreationReturnsTradeWithoutLegacySuccessMessage() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        let outcome = await fixture.buy()

        XCTAssertEqual(
            outcome,
            .created(tradeNo: "synthetic-A-created-1-0")
        )
        XCTAssertEqual(
            CommerceOrderCreationNavigation.paymentTradeNo(for: outcome),
            "synthetic-A-created-1-0"
        )
        XCTAssertNil(fixture.model.message)
    }

    func testUnknownCreationNeverProducesPaymentNavigation() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configure(create: .timeout, newOrders: 0)

        let outcome = await fixture.buy()

        XCTAssertEqual(outcome, .unknownResult)
        XCTAssertNil(
            CommerceOrderCreationNavigation.paymentTradeNo(for: outcome)
        )
        XCTAssertEqual(
            fixture.model.message,
            .localized("purchase.payment.unknown_order")
        )
    }

    func testKnownOrderCreationRejectionDisplaysBackendMessageAndAllowsANewAttempt() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configure(
            create: .messageOnlyBusinessRejection(
                500,
                "You have an unpaid or pending order, please try again later or cancel it"
            ),
            newOrders: 0
        )

        let rejected = await fixture.buy()

        let backendMessage = "You have an unpaid or pending order, please try again later or cancel it"
        XCTAssertEqual(rejected, .unavailable(.verbatim(backendMessage)))
        XCTAssertEqual(fixture.model.message, .verbatim(backendMessage))
        let retainedIntent = try await fixture.payments.intent(
            for: fixture.a,
            operation: .create
        )
        XCTAssertNil(retainedIntent)

        await fixture.state.configure(create: .success, newOrders: 1)
        let secondAttempt = await fixture.buy()
        guard case .created = secondAttempt else {
            return XCTFail("A definite rejection must not retain the write gate")
        }
        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.create, 2)
    }

    func testPaymentPageNavigationRequiresDefiniteCheckoutResult() {
        XCTAssertNil(CommerceOrderCreationNavigation.checkoutTradeNo(
            tradeNo: "fixture-trade",
            checkout: nil
        ))
        XCTAssertEqual(CommerceOrderCreationNavigation.checkoutTradeNo(
            tradeNo: "fixture-trade",
            checkout: PurchaseCheckoutResult(type: 0, data: "fixture-qr")
        ), "fixture-trade")
    }

    func testOrderDetailReadLoadsServerAmountsWithoutClientRecalculation() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        let outcome = await fixture.model.loadOrderDetail(trade: "detail-trade")

        guard case let .loaded(detail) = outcome else {
            return XCTFail("Expected the server order detail")
        }
        XCTAssertEqual(detail.tradeNo, "detail-trade")
        XCTAssertEqual(detail.planName, "Fixture Plan")
        XCTAssertEqual(detail.planPriceCents, 200)
        XCTAssertEqual(detail.totalAmountCents, 100)
        XCTAssertEqual(detail.discountAmountCents, 10)
        XCTAssertEqual(detail.surplusAmountCents, 20)
        XCTAssertEqual(detail.balanceAmountCents, 30)
        XCTAssertEqual(detail.refundAmountCents, 40)
        XCTAssertEqual(detail.handlingAmountCents, 5)
    }

    func testPaymentMonitoringPersistsStartTimeForCurrentAccount() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        guard case let .created(tradeNo) = await fixture.buy(),
              case let .loaded(detail) = await fixture.model.loadOrderDetail(trade: tradeNo) else {
            return XCTFail("Expected a definite order and detail")
        }

        let outcome = await fixture.model.beginPaymentMonitoring(detail: detail)
        guard case let .ready(payment) = outcome else {
            return XCTFail("Expected monitoring persistence")
        }
        XCTAssertEqual(payment.tradeNo, tradeNo)
        XCTAssertNotNil(payment.paymentStartedAt)
        let restored = await fixture.model.restoredPaymentMonitoring()
        XCTAssertEqual(restored, payment)
    }

    func testPendingStatusKeepsRecoveryAndTerminalStatusClearsIt() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        guard case let .created(tradeNo) = await fixture.buy(),
              case let .loaded(detail) = await fixture.model.loadOrderDetail(trade: tradeNo) else {
            return XCTFail("Expected a definite order and detail")
        }
        guard case .ready = await fixture.model.beginPaymentMonitoring(detail: detail) else {
            return XCTFail("Expected monitoring persistence")
        }

        await fixture.state.configure(status: 0)
        let pendingStatus = await fixture.model.checkPaymentStatus(trade: tradeNo)
        XCTAssertEqual(pendingStatus, .status(.pending))
        let pending = await fixture.model.restoredPaymentMonitoring()
        XCTAssertNotNil(pending)

        await fixture.state.configure(status: 3)
        let completedStatus = await fixture.model.checkPaymentStatus(trade: tradeNo)
        XCTAssertEqual(completedStatus, .status(.completed))
        let cleared = await fixture.model.restoredPaymentMonitoring()
        XCTAssertNil(cleared)
    }

    func testAllPaymentStatusesUseSharedPendingTerminalSemantics() async throws {
        for serverStatus in [0, 1, 99] {
            let fixture = try await WriteOutcomeFixture()
            defer { fixture.cleanUp() }
            let started = try await startPaymentMonitoring(fixture)
            await fixture.state.configure(status: serverStatus)

            let outcome = await fixture.model.checkPaymentStatus(trade: started.tradeNo)

            XCTAssertEqual(
                outcome,
                .status(PurchasePaymentStatus(serverValue: serverStatus))
            )
            let retained = await fixture.payments.payment(for: fixture.a)
            XCTAssertNotNil(retained)
        }

        for serverStatus in [2, 3, 4] {
            let fixture = try await WriteOutcomeFixture()
            defer { fixture.cleanUp() }
            let started = try await startPaymentMonitoring(fixture)
            await fixture.state.configure(status: serverStatus)

            let outcome = await fixture.model.checkPaymentStatus(trade: started.tradeNo)

            XCTAssertEqual(
                outcome,
                .status(PurchasePaymentStatus(serverValue: serverStatus))
            )
            let cleared = await fixture.payments.payment(for: fixture.a)
            XCTAssertNil(cleared)
        }
    }

    func testLegacyCheckOrderUsesTheSharedTerminalSemantics() async throws {
        for serverStatus in [0, 1, 99] {
            let fixture = try await WriteOutcomeFixture()
            defer { fixture.cleanUp() }
            let started = try await startPaymentMonitoring(fixture)
            await fixture.state.configure(status: serverStatus)

            await fixture.model.checkOrder(started.tradeNo)

            let retained = await fixture.payments.payment(for: fixture.a)
            XCTAssertNotNil(retained)
        }

        for serverStatus in [2, 3, 4] {
            let fixture = try await WriteOutcomeFixture()
            defer { fixture.cleanUp() }
            let started = try await startPaymentMonitoring(fixture)
            await fixture.state.configure(status: serverStatus)

            await fixture.model.checkOrder(started.tradeNo)

            let cleared = await fixture.payments.payment(for: fixture.a)
            XCTAssertNil(cleared)
        }
    }

    func testStartedPaymentContinuationChoosesMonitoringInsteadOfCheckout() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let started = try await startPaymentMonitoring(fixture)

        XCTAssertTrue(PurchasePaymentRecoveryPolicy.shouldRestoreMonitoring(
            payment: started.payment,
            tradeNo: started.tradeNo
        ))
        XCTAssertFalse(PurchasePaymentRecoveryPolicy.shouldRestoreMonitoring(
            payment: started.payment,
            tradeNo: "another-trade"
        ))
        let unstarted = PurchasePendingPayment(
            tradeNo: started.tradeNo,
            accountIdentifier: started.payment.accountIdentifier,
            planID: started.payment.planID,
            period: started.payment.period,
            createdAt: started.payment.createdAt,
            paymentStartedAt: nil
        )
        XCTAssertFalse(PurchasePaymentRecoveryPolicy.shouldRestoreMonitoring(
            payment: unstarted,
            tradeNo: started.tradeNo
        ))

        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checkout, 0)
    }

    func testLifecycleRecoveryChecksStatusAndCreatesOnlyOneMonitoringSession() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        _ = try await startPaymentMonitoring(fixture)
        await fixture.state.configure(status: 0)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()

        await coordinator.recoverPendingPaymentIfNeeded(
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US")
        )
        await coordinator.recoverPendingPaymentIfNeeded(
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US")
        )

        for _ in 0..<100 {
            if presenter.activeRequest?.kind == .paymentStatus { break }
            await Task.yield()
        }

        XCTAssertTrue(coordinator.isMonitoring)
        XCTAssertEqual(presenter.activeRequest?.kind, .paymentStatus)
        var counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checks, 1)
        XCTAssertEqual(counts.checkout, 0)

        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        for _ in 0..<50 {
            counts = await fixture.state.counts(auth: fixture.a.authData)
            if counts.checks == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(counts.checks, 2)
        XCTAssertTrue(coordinator.isMonitoring)

        coordinator.stop()
        for _ in 0..<100 {
            if presenter.activeRequest == nil { break }
            await Task.yield()
        }
        XCTAssertNil(presenter.activeRequest)
    }

    func testLifecycleRecoveryIsAccountScoped() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        _ = try await startPaymentMonitoring(fixture)
        await fixture.model.signOut()
        await fixture.model.establishAuthenticatedSession(fixture.b, source: .login)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()

        await coordinator.recoverPendingPaymentIfNeeded(
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertNil(presenter.activeRequest)
        let bCounts = await fixture.state.counts(auth: fixture.b.authData)
        XCTAssertEqual(bCounts.checks, 0)
    }

    func testOldGenerationRecoveryCompletionCannotPresent() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        _ = try await startPaymentMonitoring(fixture)
        let gate = await fixture.state.holdReconcile(auth: fixture.a.authData)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()
        let recovery = Task {
            await coordinator.recoverPendingPaymentIfNeeded(
                model: fixture.model,
                presenter: presenter,
                locale: Locale(identifier: "en_US")
            )
        }
        await fulfillment(of: [gate.entered], timeout: 2)

        await fixture.model.establishAuthenticatedSession(fixture.a, source: .login)
        coordinator.accountContextChanged(
            session: fixture.model.session,
            generation: fixture.model.commerceRecoveryGeneration
        )
        await gate.resume(.init(body: #"{"data":0}"#))
        await recovery.value

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertNil(presenter.activeRequest)
    }

    func testExpiredAutomaticPollingKeepsPendingAndManualCheckStillWorks() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let started = try await startPaymentMonitoring(fixture)
        let oldDate = Date().addingTimeInterval(-(PaymentStatusPollingPolicy.deadline + 1))
        let expired = PurchasePendingPayment(
            tradeNo: started.tradeNo,
            accountIdentifier: started.payment.accountIdentifier,
            planID: started.payment.planID,
            period: started.payment.period,
            createdAt: oldDate,
            paymentStartedAt: oldDate
        )
        try await fixture.payments.save(expired)
        await fixture.state.configure(status: 0)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()

        await coordinator.restore(
            detail: started.detail,
            payment: expired,
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US")
        )
        var counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checks, 1)
        await Task.yield()
        counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checks, 1, "Expired automatic polling must remain stopped")
        let retainedAfterTimeout = await fixture.payments.payment(for: fixture.a)
        XCTAssertNotNil(retainedAfterTimeout)

        let requestID = try XCTUnwrap(presenter.activeRequest?.id)
        let result = await presenter.perform(.checkPaymentStatus, requestID: requestID)
        XCTAssertEqual(result, .completed)
        counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checks, 2)
        let retainedAfterManualCheck = await fixture.payments.payment(for: fixture.a)
        XCTAssertNotNil(retainedAfterManualCheck)

        coordinator.stop()
    }

    func testConcurrentPaymentStatusChecksShareOneRead() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        guard case let .created(tradeNo) = await fixture.buy() else {
            return XCTFail("Expected a definite order")
        }
        let gate = await fixture.state.holdReconcile(auth: fixture.a.authData)

        let first = Task { await fixture.model.checkPaymentStatus(trade: tradeNo) }
        await fulfillment(of: [gate.entered], timeout: 1)
        let second = Task { await fixture.model.checkPaymentStatus(trade: tradeNo) }
        await Task.yield()
        var counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checks, 1)

        await gate.resume(.init(body: #"{"data":1}"#))
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .status(.activating))
        XCTAssertEqual(secondResult, .status(.activating))
        counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.checks, 1)
    }

    func testCheckoutOpenRevalidatesContextAfterYield() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let prepared = try await prepareOwnedCheckout(fixture)
        let gate = CommerceAsyncSuspensionGate(
            description: "checkout ready before external URL open"
        )
        let coordinator = PaymentStatusCoordinator(beforeExternalOpen: {
            await gate.wait()
        })
        let presenter = GlobalModalPresenter()
        var openedURLs: [URL] = []

        let start = Task {
            await coordinator.start(
                detail: prepared.detail,
                checkout: prepared.checkout,
                model: fixture.model,
                presenter: presenter,
                locale: Locale(identifier: "en_US"),
                openURL: {
                    openedURLs.append($0)
                    return true
                }
            )
        }
        await fulfillment(of: [gate.entered], timeout: 2)

        await fixture.model.establishAuthenticatedSession(fixture.b, source: .login)
        coordinator.accountContextChanged(
            session: fixture.model.session,
            generation: fixture.model.commerceRecoveryGeneration
        )
        await gate.resume()

        let didStart = await start.value
        XCTAssertFalse(didStart)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertFalse(coordinator.isMonitoring)
        for _ in 0..<50 where presenter.activeRequest != nil { await Task.yield() }
        XCTAssertNil(presenter.activeRequest)
    }

    func testCheckoutOpenRequiresOrderToRemainPayable() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        await fixture.state.configure(mismatch: "expires_at")
        let prepared = try await prepareOwnedCheckout(fixture)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()
        var openedURLs: [URL] = []

        let didStart = await coordinator.start(
            detail: prepared.detail,
            checkout: prepared.checkout,
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US"),
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        XCTAssertFalse(didStart)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertNil(presenter.activeRequest)
    }

    func testPaymentStatusAwaitCannotPresentOrRefreshAfterAccountSwitch() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let started = try await startPaymentMonitoring(fixture)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()
        await coordinator.restore(
            detail: started.detail,
            payment: started.payment,
            verifiedStatus: .pending,
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US")
        )
        for _ in 0..<100 where presenter.activeRequest == nil { await Task.yield() }
        let requestID = try XCTUnwrap(presenter.activeRequest?.id)
        let gate = await fixture.state.holdReconcile(auth: fixture.a.authData)
        let check = Task {
            await presenter.perform(.checkPaymentStatus, requestID: requestID)
        }
        await fulfillment(of: [gate.entered], timeout: 2)

        await fixture.model.establishAuthenticatedSession(fixture.b, source: .login)
        coordinator.accountContextChanged(
            session: fixture.model.session,
            generation: fixture.model.commerceRecoveryGeneration
        )
        await gate.resume(.init(body: #"{"data":3}"#))
        let interactionResult = await check.value

        XCTAssertEqual(interactionResult, .cancelled)
        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertNil(presenter.activeRequest)
        let bCounts = await fixture.state.counts(auth: fixture.b.authData)
        XCTAssertEqual(bCounts.checks, 0)
        XCTAssertEqual(bCounts.orders, 0)
    }

    func testForegroundDoesNotResumeOldAccountPaymentSession() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let started = try await startPaymentMonitoring(fixture)
        let coordinator = PaymentStatusCoordinator()
        let presenter = GlobalModalPresenter()
        await coordinator.restore(
            detail: started.detail,
            payment: started.payment,
            verifiedStatus: .pending,
            model: fixture.model,
            presenter: presenter,
            locale: Locale(identifier: "en_US")
        )
        coordinator.scenePhaseChanged(.background)

        await fixture.model.establishAuthenticatedSession(fixture.b, source: .login)
        coordinator.accountContextChanged(
            session: fixture.model.session,
            generation: fixture.model.commerceRecoveryGeneration
        )
        coordinator.scenePhaseChanged(.active)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertFalse(coordinator.isMonitoring)
        XCTAssertNil(presenter.activeRequest)
        let bCounts = await fixture.state.counts(auth: fixture.b.authData)
        XCTAssertEqual(bCounts.checks, 0)
    }

    func testPaymentPreparationRetriesReadsWithoutCreatingAnotherOrder() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let creation = await fixture.buy()
        guard case let .created(tradeNo) = creation else {
            return XCTFail("Expected a definite created order")
        }

        await fixture.state.configurePaymentPreparation(orderDetailFails: true)
        guard case .unavailable = await fixture.model.loadOrderDetail(trade: tradeNo) else {
            return XCTFail("Expected the detail read to fail")
        }
        await fixture.state.configurePaymentPreparation(orderDetailFails: false)
        guard case .loaded = await fixture.model.loadOrderDetail(trade: tradeNo) else {
            return XCTFail("Expected the detail retry to succeed")
        }

        await fixture.state.configurePaymentPreparation(paymentMethodsFail: true)
        await fixture.model.loadPaymentMethods()
        XCTAssertNotNil(fixture.model.paymentMethodsLoadState.failureMessage)
        await fixture.state.configurePaymentPreparation(paymentMethodsFail: false)
        await fixture.model.loadPaymentMethods()
        XCTAssertEqual(fixture.model.paymentMethodsLoadState, .loaded)

        let writes = await fixture.state.counts(auth: fixture.a.authData)
        let reads = await fixture.state.paymentPreparationCounts(
            auth: fixture.a.authData
        )
        XCTAssertEqual(writes.create, 1)
        // A failed read uses the existing two-host failover, followed by one
        // successful user retry. Neither path is allowed to repeat order/save.
        XCTAssertEqual(reads.details, 3)
        XCTAssertEqual(reads.methods, 3)
    }

    func testUnknownCreateResponsesDoNotPersistAGate() async throws {
        for response in [WriteFixtureOutcome.timeout, .loss, .nonHTTP, .malformed] {
            let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
            await f.state.configure(create: response, newOrders: 0)

            let first = await f.buy()
            let retained = try await f.payments.intent(for: f.a, operation: .create)
            XCTAssertEqual(first, .unknownResult)
            XCTAssertNil(retained)

            await f.state.configure(create: .success, newOrders: 1)
            guard case .created = await f.buy() else {
                return XCTFail("A later user action must request V2Board again")
            }
            let counts = await f.state.counts(auth: f.a.authData)
            XCTAssertEqual(counts.create, 2)
        }
    }

    func testOrderSaveBackendMessageIsDisplayedVerbatimWithoutPersistingAGate() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(create: .messageOnlyRejection(500), newOrders: 0)

        let outcome = await f.buy()

        XCTAssertEqual(outcome, .unavailable(.verbatim("Synthetic rejection")))
        XCTAssertEqual(f.model.message, .verbatim("Synthetic rejection"))
        let retained = try await f.payments.intent(for: f.a, operation: .create)
        XCTAssertNil(retained)
    }

    func testLegacyCreateIntentIsRemovedWithoutTouchingCheckoutIntent() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        let owner = PendingPaymentStore.accountIdentifier(for: f.a)
        let create = PurchaseWriteIntent(id: UUID(), accountIdentifier: owner,
            operation: .create, tradeNo: nil, planID: 1, period: "month_price",
            priceCents: 100, baselineTradeNos: [], startedAt: Date())
        let checkout = PurchaseWriteIntent(id: UUID(), accountIdentifier: owner,
            operation: .checkout, tradeNo: "trade", planID: nil, period: nil,
            priceCents: nil, baselineTradeNos: [], startedAt: Date())
        _ = try await f.payments.reserve(create)
        _ = try await f.payments.reserve(checkout)

        await f.model.loadCommerce()

        let retainedCreate = try await f.payments.intent(for: f.a, operation: .create)
        let retainedCheckout = try await f.payments.intent(
            for: f.a, operation: .checkout, tradeNo: "trade"
        )
        XCTAssertNil(retainedCreate)
        XCTAssertNotNil(retainedCheckout)
    }
    func testCheckoutProgressAdoptsTradeStatusWithoutAnotherPOST() async throws {
        for status in [1, 2, 3, 4] {
            let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
            await f.state.configure(checkout: .timeout, status: status)
            await f.model.beginCheckout(trade: "trade", method: 1)
            await f.model.beginCheckout(trade: "trade", method: 2)
            let intent = try await f.payments.intent(for: f.a, operation: .checkout, tradeNo: "trade")
            XCTAssertEqual(intent?.resolvedStatus, status)
            XCTAssertEqual(f.model.message, .localized(AppModel.orderStatusKey(status)))
            XCTAssertNil(f.model.checkout, "A status read must not fabricate a payment URL")
            let counts = await f.state.counts(auth: f.a.authData)
            XCTAssertEqual(counts.checkout, 1)
            XCTAssertEqual(counts.checks, 2)
        }
    }
    func testCheckoutQueryFailureKeepsGate() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .loss, queryFails: true)
        await f.model.beginCheckout(trade: "trade", method: 1)
        await f.model.beginCheckout(trade: "trade", method: 2)
        try await assertUncertain(f, .checkout)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.checkout, 1)
    }
    func testCheckoutPendingIsNotProofOfSafeRetry() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .timeout, status: 0)
        await f.model.beginCheckout(trade: "trade", method: 1)
        await f.model.beginCheckout(trade: "trade", method: 1)
        try await assertUncertain(f, .checkout)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.checkout, 1)
        XCTAssertEqual(counts.checks, 2)
    }
    func testUnknownCheckoutSurvivesFreshStoreAndModel() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .timeout)
        await f.model.beginCheckout(trade: "trade", method: 1)
        let reopened = f.newModel(freshStore: true)
        await reopened.establishAuthenticatedSession(f.a, source: .restored)
        await reopened.beginCheckout(trade: "trade", method: 1)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.checkout, 1)
        XCTAssertEqual(reopened.message, .localized("purchase.payment.unknown_checkout"))
    }
    func testCreateRetriesAndUncertainCheckoutRemainAccountScoped() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(create: .timeout, checkout: .timeout, newOrders: 0)
        await f.buy()
        await f.model.beginCheckout(trade: "trade", method: 1)
        await f.model.signOut()
        await f.model.establishAuthenticatedSession(f.b, source: .login)
        await f.state.configure(create: .success, checkout: .success, newOrders: 1)
        await f.buy()
        await f.model.beginCheckout(trade: "trade", method: 1)
        let bCounts = await f.state.counts(auth: f.b.authData)
        XCTAssertEqual(bCounts.create, 1); XCTAssertEqual(bCounts.checkout, 1)
        let bPending = await f.payments.payment(for: f.b)
        XCTAssertNotNil(bPending)
        await f.model.signOut()
        await f.model.establishAuthenticatedSession(f.a, source: .login)
        await f.buy()
        await f.model.beginCheckout(trade: "trade", method: 1)
        let aCounts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(aCounts.create, 2); XCTAssertEqual(aCounts.checkout, 1)
        let bAfter = await f.payments.payment(for: f.b)
        XCTAssertEqual(bAfter, bPending)
    }
    func testLateCheckoutReconciliationCannotAffectB() async throws { try await assertLateReconcile(checkout: true) }

    private func startPaymentMonitoring(
        _ fixture: WriteOutcomeFixture
    ) async throws -> (
        tradeNo: String,
        detail: PurchaseOrderDetail,
        payment: PurchasePendingPayment
    ) {
        guard case let .created(tradeNo) = await fixture.buy(),
              case let .loaded(detail) = await fixture.model.loadOrderDetail(
                trade: tradeNo
              ),
              case let .ready(payment) = await fixture.model.beginPaymentMonitoring(
                detail: detail
              ) else {
            throw XCTSkip("Unable to prepare the synthetic pending payment")
        }
        return (tradeNo, detail, payment)
    }

    private func prepareOwnedCheckout(
        _ fixture: WriteOutcomeFixture
    ) async throws -> (
        tradeNo: String,
        detail: PurchaseOrderDetail,
        checkout: AppModel.OwnedPurchaseCheckout
    ) {
        guard case let .created(tradeNo) = await fixture.buy(),
              case let .loaded(detail) = await fixture.model.loadOrderDetail(
                trade: tradeNo
              ),
              let checkout = await fixture.model.beginCheckout(
                trade: tradeNo,
                method: 1
              ) else {
            throw XCTSkip("Unable to prepare the synthetic owned checkout")
        }
        return (tradeNo, detail, checkout)
    }

    func testExplicitRejectionsRemainExplicitAndReleaseUncertainReservation() async throws {
        for status in [400, 422, 429, 500] {
            let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
            await f.state.configure(create: .rejection(status))
            await f.buy()
            let intent = try await f.payments.intent(for: f.a, operation: .create)
            XCTAssertNil(intent)
            XCTAssertNotEqual(f.model.message, .localized("purchase.payment.unknown_order"))
            await f.state.configure(create: .success)
            await f.buy()
            let counts = await f.state.counts(auth: f.a.authData)
            XCTAssertEqual(counts.create, 2, "An explicit rejection permits a later user action")
        }
    }
    func test401RemainsAuthenticationExpired() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .rejection(401))
        await f.model.beginCheckout(trade: "trade", method: 1)
        XCTAssertNil(f.model.session)
        let intent = try await f.payments.intent(for: f.a, operation: .checkout, tradeNo: "trade")
        XCTAssertNil(intent)
    }
    func testCreate401CannotProducePaymentNavigation() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(create: .rejection(401))

        let outcome = await f.buy()

        guard case .unavailable = outcome else {
            return XCTFail("Expected authentication feedback")
        }
        XCTAssertNil(CommerceOrderCreationNavigation.paymentTradeNo(for: outcome))
        XCTAssertNil(f.model.session)
        let intent = try await f.payments.intent(for: f.a, operation: .create)
        XCTAssertNil(intent)
    }
    func testDNSBeforeSubmissionIsNotUnknownButStillNeverAutoReplays() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(create: .dns)
        await f.buy()
        let intent = try await f.payments.intent(for: f.a, operation: .create)
        XCTAssertNil(intent)
        XCTAssertEqual(f.model.message, NetworkClientError.dnsFailure.userFacingMessage)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.create, 1)
    }
    func testCancelledCreateDoesNotPersistAGateOrDeliverSuccess() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(create: .cancelled)
        let outcome = await f.buy()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(CommerceOrderCreationNavigation.paymentTradeNo(for: outcome))
        XCTAssertNil(f.model.message)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.create, 1); XCTAssertEqual(counts.orders, 0)
        let intent = try await f.payments.intent(for: f.a, operation: .create)
        XCTAssertNil(intent)
    }
    func testLegacyPendingFormatRemainsReadableAndIsPreservedDuringMigration() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        let old = PurchasePendingPayment(tradeNo: "legacy", accountIdentifier: PendingPaymentStore.accountIdentifier(for: f.a),
            planID: 1, period: "month_price", createdAt: Date(), paymentStartedAt: nil)
        UserDefaults(suiteName: f.suite)!.set(try JSONEncoder().encode(old), forKey: "purchase.pending-payment.v1")
        let read = await f.payments.payment(for: f.a)
        XCTAssertEqual(read, old)
        await f.state.configure(checkout: .timeout)
        await f.model.beginCheckout(trade: "legacy", method: 1)
        let fresh = PendingPaymentStore(defaults: UserDefaults(suiteName: f.suite)!)
        let after = await fresh.payment(for: f.a)
        XCTAssertEqual(after, old)
        let unknown = try await fresh.intent(for: f.a, operation: .checkout, tradeNo: "legacy")
        XCTAssertNotNil(unknown)
        let bPayment = await fresh.payment(for: f.b)
        XCTAssertNil(bPayment)
    }
    func testCorruptPersistenceDoesNotBlockCreateButStillProtectsCheckout() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        UserDefaults(suiteName: f.suite)!.set(Data("broken".utf8), forKey: "purchase.pending-payment.v1")
        await f.buy(); await f.model.beginCheckout(trade: "trade", method: 1)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.create, 1); XCTAssertEqual(counts.checkout, 0)
    }
    func testPartialOrMalformedOrderListsCannotEstablishUniqueness() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        for body in [
            #"{"data":[{"trade_no":"one","status":0},42]}"#,
            #"{"data":{"data":[{"trade_no":"one","status":0}],"total":2}}"#,
            #"{"data":[{"trade_no":"one","status":0}],"meta":{"current_page":2,"last_page":2}}"#,
            #"{"data":{"data":[{"trade_no":"one","status":0}],"links":{"next":"synthetic-next"}}}"#
        ] {
            let transport = RecordingNetworkTransport { request, _ in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            let api = V2BoardAPIClient(transport: transport)
            do {
                _ = try await api.fetchOrders(config: f.config, session: f.a, requireComplete: true)
                XCTFail("An incomplete list cannot establish uniqueness")
            } catch { XCTAssertEqual(error as? PurchaseCommerceError, .invalidResponse) }
        }
    }
    func testLateReconciliationWithReplacedAuthDataIsDiscarded() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .timeout)
        let gate = await f.state.holdReconcile(auth: f.a.authData)
        let old = Task { await f.model.beginCheckout(trade: "trade", method: 1) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replacement = WriteOutcomeFixture.session("A", auth: "synthetic-replacement")
        await f.business.setAccountResult(replacement)
        await f.model.refreshAccount()
        XCTAssertEqual(f.model.session?.authData, replacement.authData)
        f.model.message = .verbatim("current credential")
        let before = CommerceVisibleState(f.model)
        await gate.resume(.init(body: #"{"data":3}"#))
        await old.value
        XCTAssertEqual(f.model.session, before.session)
        XCTAssertEqual(f.model.orders, before.orders)
        XCTAssertEqual(f.model.checkout, before.checkout)
        XCTAssertEqual(f.model.message, before.message)
        XCTAssertFalse(f.model.busy, "The unchanged generation releases its completed busy owner")
        let intent = try await f.payments.intent(for: replacement, operation: .checkout, tradeNo: "trade")
        XCTAssertNil(intent?.resolvedStatus)
    }
    func testCheckoutReconciliationQueriesTheOriginalTradeNo() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .timeout, status: 3)
        await f.model.beginCheckout(trade: "original-trade", method: 1)
        let checked = await f.state.checkedTrades
        XCTAssertEqual(checked, ["original-trade"])
    }

    func testIncompleteCheckoutResponseRemainsUnknownAndCannotBeResubmitted() async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(checkout: .incompleteCheckout)
        await f.model.beginCheckout(trade: "trade", method: 1)
        await f.model.beginCheckout(trade: "trade", method: 1)
        try await assertUncertain(f, .checkout)
        XCTAssertNil(f.model.checkout)
        let counts = await f.state.counts(auth: f.a.authData)
        XCTAssertEqual(counts.checkout, 1)
    }

    func testPhaseFourOrderPresentationUsesExpectedStatusHierarchy() {
        XCTAssertEqual(PurchaseOrderPresentation.statusTone(status: 0), .pending)
        XCTAssertEqual(PurchaseOrderPresentation.statusTone(status: 1), .activating)
        XCTAssertEqual(PurchaseOrderPresentation.statusTone(status: 3), .completed)
        XCTAssertEqual(PurchaseOrderPresentation.statusTone(status: 2), .inactive)
        XCTAssertEqual(PurchaseOrderPresentation.statusTone(status: 4), .inactive)
        XCTAssertEqual(PurchaseOrderPresentation.statusTone(status: 99), .inactive)
        XCTAssertEqual(
            PurchaseOrderPresentation.statusKey(status: 0, isExpired: true),
            "profile.orders.status.expired"
        )
        XCTAssertNotNil(PurchaseOrderPresentation.timestamp(
            1_700_000_000,
            locale: Locale(identifier: "zh_CN")
        ))
    }

    func testPhaseFourOrderActionsFollowServerStatusAndPaymentStart() {
        XCTAssertEqual(PurchaseOrderActionPolicy.continuation(
            status: .pending,
            hasStartedPayment: false
        ), .paymentMethods)
        XCTAssertEqual(PurchaseOrderActionPolicy.continuation(
            status: .pending,
            hasStartedPayment: true
        ), .monitoring)
        XCTAssertEqual(PurchaseOrderActionPolicy.continuation(
            status: .activating,
            hasStartedPayment: false
        ), .monitoring)
        for status in [
            PurchasePaymentStatus.cancelled,
            .completed,
            .offset,
            .unknown(99)
        ] {
            XCTAssertEqual(PurchaseOrderActionPolicy.continuation(
                status: status,
                hasStartedPayment: false
            ), .none)
            XCTAssertFalse(PurchaseOrderActionPolicy.canCancel(status: status))
        }
        XCTAssertTrue(PurchaseOrderActionPolicy.canCancel(status: .pending))
        XCTAssertFalse(PurchaseOrderActionPolicy.canCancel(status: .activating))
    }

    func testOrderDetailPaymentAccessOnlyAllowsUnexpiredPendingOrders() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payable = order(status: 0, expiresAt: 1_700_000_100)
        XCTAssertTrue(OrderDetailPaymentAccessPolicy.canPresent(
            status: .pending,
            order: payable,
            at: now
        ))

        let unavailable: [(PurchasePaymentStatus, PurchaseOrderRecord)] = [
            (.activating, order(status: 1)),
            (.cancelled, order(status: 2)),
            (.completed, order(status: 3)),
            (.offset, order(status: 4)),
            (.unknown(99), order(status: 99)),
            (.pending, order(status: 0, expiresAt: 1_699_999_999)),
        ]
        for (status, record) in unavailable {
            XCTAssertFalse(OrderDetailPaymentAccessPolicy.canPresent(
                status: status,
                order: record,
                at: now
            ), "status=\(status)")
        }
    }

    func testOrderDetailPaymentAccessHidesTerminalOrdersWithStaleCheckout() {
        let checkout = PurchaseCheckoutResult(
            type: 1,
            data: "https://payments.example.invalid/stale"
        )
        for status in [
            PurchasePaymentStatus.cancelled,
            .completed,
            .offset,
            .activating,
            .unknown(99),
        ] {
            XCTAssertNotNil(OrderDetailPaymentAccessPolicy.checkoutURL(checkout))
            XCTAssertFalse(OrderDetailPaymentAccessPolicy.canPresent(
                status: status,
                order: order(status: serverValue(status))
            ))
        }
    }

    func testOrderDetailPaymentOpenActionRevalidatesPayableState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let checkout = PurchaseCheckoutResult(
            type: 1,
            data: "https://payments.example.invalid/current"
        )
        var openedURLs: [URL] = []
        let open: (URL) -> Bool = {
            openedURLs.append($0)
            return true
        }

        for (status, record) in [
            (PurchasePaymentStatus.cancelled, order(status: 2)),
            (.completed, order(status: 3)),
            (.offset, order(status: 4)),
            (.activating, order(status: 1)),
            (.unknown(99), order(status: 99)),
            (.pending, order(status: 0, expiresAt: 1_699_999_999)),
        ] {
            XCTAssertFalse(OrderDetailPaymentAccessPolicy.openBrowserCheckoutIfAllowed(
                checkout: checkout,
                status: status,
                order: record,
                at: now,
                openURL: open
            ))
        }
        XCTAssertTrue(openedURLs.isEmpty)

        XCTAssertTrue(OrderDetailPaymentAccessPolicy.openBrowserCheckoutIfAllowed(
            checkout: checkout,
            status: .pending,
            order: order(status: 0, expiresAt: 1_700_000_100),
            at: now,
            openURL: open
        ))
        XCTAssertEqual(openedURLs.map(\.absoluteString), [
            "https://payments.example.invalid/current"
        ])
    }

    func testOrderDetailPaymentCardUsesPolicyAndGuardedButton() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Views/CommerceView.swift"
        ))
        let start = try XCTUnwrap(source.range(
            of: "private var checkoutInformation: some View"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private var orderDetailCard: some View",
            range: start.upperBound..<source.endIndex
        ))
        let region = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(region.contains("if canPresentPaymentAccess, let ownedCheckout = currentCheckout"))
        XCTAssertTrue(region.contains("model.isCurrentCheckout"))
        XCTAssertTrue(region.contains("openBrowserCheckoutIfAllowed"))
        XCTAssertFalse(region.contains("Link(destination:"))
        XCTAssertFalse(region.contains("model.checkout = nil"))
    }

    func testPhaseFourCancellationChoiceIsDestructiveAndPendingOnly() {
        XCTAssertTrue(PurchaseOrderCancellationPresentation.shouldCancel(
            choice: .primary,
            status: .pending
        ))
        XCTAssertFalse(PurchaseOrderCancellationPresentation.shouldCancel(
            choice: .secondary,
            status: .pending
        ))
        XCTAssertFalse(PurchaseOrderCancellationPresentation.shouldCancel(
            choice: .primary,
            status: .activating
        ))
    }

    private func order(
        status: Int,
        expiresAt: Int64? = nil
    ) -> PurchaseOrderRecord {
        PurchaseOrderRecord(
            tradeNo: "fixture-\(status)-\(expiresAt ?? 0)",
            status: status,
            planID: 1,
            planName: "Fixture",
            period: "month_price",
            planPriceCents: 100,
            totalAmountCents: 100,
            discountAmountCents: 0,
            surplusAmountCents: 0,
            balanceAmountCents: 0,
            refundAmountCents: 0,
            handlingAmountCents: 0,
            paymentMethodName: nil,
            createdAtUnix: 1_699_000_000,
            paidAtUnix: nil,
            expiresAtUnix: expiresAt
        )
    }

    private func serverValue(_ status: PurchasePaymentStatus) -> Int {
        switch status {
        case .pending: 0
        case .activating: 1
        case .cancelled: 2
        case .completed: 3
        case .offset: 4
        case let .unknown(value): value
        }
    }

    func testNonPendingOrderCannotReachCancelAPI() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }

        let outcome = await fixture.model.cancelPendingOrder(
            trade: "synthetic-order",
            status: .activating
        )

        XCTAssertEqual(outcome, .cancelled)
        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.cancel, 0)
    }

    func testPendingCancellationCallsAPIOnceAndClearsPending() async throws {
        let fixture = try await WriteOutcomeFixture()
        defer { fixture.cleanUp() }
        let started = try await startPaymentMonitoring(fixture)

        let outcome = await fixture.model.cancelPendingOrder(
            trade: started.tradeNo,
            status: .pending
        )

        XCTAssertEqual(outcome, .cancelledOrder)
        let retained = await fixture.payments.payment(for: fixture.a)
        XCTAssertNil(retained)
        let counts = await fixture.state.counts(auth: fixture.a.authData)
        XCTAssertEqual(counts.cancel, 1)
        XCTAssertEqual(
            fixture.model.orders.first(where: { $0.tradeNo == started.tradeNo })?.status,
            2
        )
    }

    private func assertUncertain(_ f: WriteOutcomeFixture, _ operation: PurchaseWriteIntent.Operation) async throws {
        let intent = try await f.payments.intent(for: f.a, operation: operation, tradeNo: operation == .checkout ? "trade" : nil)
        XCTAssertNotNil(intent)
        XCTAssertNil(intent?.adoptedTradeNo)
        XCTAssertNil(intent?.resolvedStatus)
        XCTAssertEqual(f.model.message, .localized(operation == .create ? "purchase.payment.unknown_order" : "purchase.payment.unknown_checkout"))
    }
    private func assertLateReconcile(checkout: Bool) async throws {
        let f = try await WriteOutcomeFixture(); defer { f.cleanUp() }
        await f.state.configure(create: .timeout, checkout: .timeout)
        let gate = await f.state.holdReconcile(auth: f.a.authData)
        let old = Task {
            if checkout { await f.model.beginCheckout(trade: "trade", method: 1) }
            else { await f.buy() }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        await f.model.signOut()
        await f.model.establishAuthenticatedSession(f.b, source: .login)
        f.model.message = .verbatim("B current message")
        let before = CommerceVisibleState(f.model)
        await gate.resume(.init(body: checkout ? #"{"data":3}"# : #"{"data":[{"trade_no":"A-late","status":0,"plan_id":1,"period":"month_price"}]}"#))
        await old.value
        XCTAssertEqual(CommerceVisibleState(f.model), before)
        let bPending = await f.payments.payment(for: f.b)
        XCTAssertNil(bPending)
    }
}


// A continuation barrier at the Repository-commit/AppModel-publication boundary.
@MainActor
private final class NodeRefreshPublicationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseWaiter = $0 }
        } onCancel: {
            Task { @MainActor in
                self.cancelled = true
                self.cancellationWaiter?.resume()
                self.cancellationWaiter = nil
            }
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }
}

extension AuthenticatedBootstrapTests {
    func testStage2ACommittedRefreshCannotOverwriteNewerSelection() async throws {
        let context = try await makeRefreshContext(extraNode: true)
        defer { removeDefaults(context.suite) }
        let second = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        await context.model.selectNode(second)
        let selected = await context.repository.snapshot()
        XCTAssertEqual(selected.selectedNodeID, second)
        gate.release()
        await refresh.value
        XCTAssertEqual(context.model.nodes.selectedNodeID, second,
                       "A committed refresh must not publish its older selection")
        let finalRepository = await context.repository.snapshot()
        XCTAssertEqual(finalRepository, selected, "Do not roll back a newer Repository selection")
    }

    func testStage2AZeroAvailableRefreshPreservesUsableCatalog() async throws {
        let suite = "NetworkClient.zero-available.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let fetcher = StagedSubscriptionFetcher()
        let repository = NodeRepository(
            subscriptionInfoProvider: StagedSubscriptionInfo(), subscriptionFetcher: fetcher,
            selectionStore: NodeSelectionStore(suiteName: suite)
        )
        let old = try await repository.refresh(config: config(), session: session())
        XCTAssertTrue(old.nodes.contains(where: \.available))
        await fetcher.setYAML("""
        proxies:
          - name: Unsupported Fixture
            type: synthetic-unsupported
            server: 192.0.2.40
            port: 443
        """)
        do {
            _ = try await repository.refresh(config: config(), session: session())
        } catch SubscriptionParserError.noValidNodes {}
        let current = await repository.snapshot()
        XCTAssertEqual(current, old,
                       "A nonempty zero-available replacement must preserve the usable catalog")
    }
}


extension AuthenticatedBootstrapTests {
    private struct Stage2APublicationState: Equatable {
        let nodes: NodeRepositorySnapshot
        let revision: String?
        let latencies: [String: NodeLatencyState]
        let progress: NodeLatencyProgress
        let refreshedAt: Date?
        let loadState: BusinessDataLoadState
        let message: LocalizedMessage?

        @MainActor init(_ model: AppModel) {
            nodes = model.nodes
            revision = model.selectedTunnelRevision
            latencies = model.nodeLatencies
            progress = model.nodeLatencyProgress
            refreshedAt = model.lastNodesRefreshedAt
            loadState = model.nodesLoadState
            message = model.message
        }
    }

    private static var stage2AUnavailableFixture: String {
        """
        proxies:
          - name: Unsupported Fixture
            type: synthetic-unsupported
            server: 192.0.2.40
            port: 443
        """
    }

    private static var stage2AOtherFixture: String {
        """

          - name: Other Fixture
            type: ss
            server: 1.0.0.1
            port: 443
            cipher: aes-128-gcm
            password: other-fixture
        """
    }

    private func makeStage2APublicationContext() async throws -> RefreshContext {
        let context = try await makeRefreshContext(
            extraNode: true, nodeProber: RecordingNodeHTTPProber()
        )
        return context
    }

    private func markStage2ANewOwner(_ model: AppModel) async throws {
        let id = try XCTUnwrap(model.nodes.selectedNodeID)
        await model.testNodeLatency(id)
        guard case .measured = model.nodeLatencies[id] else {
            return XCTFail("The new owner needs a synthetic measured result")
        }
        model.setNodeRefreshDateForTesting(Date(timeIntervalSince1970: 123_456))
        model.message = .localized("stage2a.fixture.new-owner")
    }

    func testStage2ASelectionAfterCommitPreservesAllNewOwnerState() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let second = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        await context.model.selectNode(second)
        try await markStage2ANewOwner(context.model)
        let owner = Stage2APublicationState(context.model)
        XCTAssertEqual(owner.loadState, .loaded)
        let repositoryOwner = await context.repository.snapshot()
        gate.release()
        await refresh.value
        XCTAssertEqual(Stage2APublicationState(context.model), owner)
        let finalRepository = await context.repository.snapshot()
        XCTAssertEqual(finalRepository, repositoryOwner)
    }

    func testStage2ASelectionRoundTripStillInvalidatesCommittedRefresh() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let first = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let second = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        await context.model.selectNode(second)
        await context.model.selectNode(first)
        try await markStage2ANewOwner(context.model)
        let owner = Stage2APublicationState(context.model)
        gate.release()
        await refresh.value
        XCTAssertEqual(Stage2APublicationState(context.model), owner,
                       "Matching ID/revision after A-B-A must not revive an old transaction")
    }

    func testStage2ALogoutAfterCommitDiscardsAllOldPublication() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        await context.model.signOut()
        let signedOut = Stage2APublicationState(context.model)
        gate.release()
        await refresh.value
        XCTAssertNil(context.model.session)
        XCTAssertEqual(Stage2APublicationState(context.model), signedOut)
        let snapshot = await context.repository.snapshot()
        XCTAssertEqual(snapshot, .empty)
    }

    func testStage2ALoginBAfterCommitCannotReceiveAccountAPublication() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refreshA = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        await context.model.signOut()
        context.model.nodeRefreshDidCommitForTesting = nil
        await context.fetcher.setYAML(Self.refreshFixture(password: "account-b-fixture")
            .replacingOccurrences(of: "Stable Fixture", with: "Account B Fixture"))
        let accountB = session(email: "account-b@example.invalid", authData: "synthetic-account-b")
        await context.model.establishAuthenticatedSession(accountB, source: .login)
        let nodeB = try XCTUnwrap(context.model.nodes.nodes.first?.id)
        await context.model.selectNode(nodeB)
        try await markStage2ANewOwner(context.model)
        let ownerB = Stage2APublicationState(context.model)
        let repositoryB = await context.repository.snapshot()
        gate.release()
        await refreshA.value
        XCTAssertEqual(context.model.session?.email, accountB.email)
        XCTAssertEqual(Stage2APublicationState(context.model), ownerB)
        let finalRepository = await context.repository.snapshot()
        XCTAssertEqual(finalRepository, repositoryB)
    }

    func testStage2ANewAuthenticatedGenerationRejectsOldSameAccountPublication() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        context.model.nodeRefreshDidCommitForTesting = nil
        await context.model.establishAuthenticatedSession(session(), source: .login)
        try await markStage2ANewOwner(context.model)
        let newGeneration = Stage2APublicationState(context.model)
        gate.release()
        await refresh.value
        XCTAssertEqual(Stage2APublicationState(context.model), newGeneration)
    }

    func testStage2ANewerRepositoryRefreshInvalidatesPublicationWithoutUICancellation() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let selected = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(selected)
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        let before = Stage2APublicationState(context.model)
        let newer = try await context.repository.prepareRefresh(config: config(), session: session())
        gate.release()
        await refresh.value
        XCTAssertEqual(Stage2APublicationState(context.model), before,
                       "The Repository generation must be checked even when UI identity is unchanged")
        let committed = try await context.repository.commitRefresh(newer)
        let snapshot = await context.repository.snapshot()
        XCTAssertEqual(snapshot, committed)
    }

    func testStage2AManualRefreshSupersedesCommittedAutomaticPublication() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let selected = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(selected)
        let readings = context.model.nodeLatencies
        let first = NodeRefreshPublicationGate()
        let second = NodeRefreshPublicationGate()
        var commits = 0
        context.model.nodeRefreshDidCommitForTesting = {
            commits += 1
            if commits == 1 { await first.pause() }
            else { await second.pause() }
        }
        let automatic = Task { await context.model.initializeAuthenticatedData() }
        await first.waitForEntry()
        let originalDate = context.model.lastNodesRefreshedAt
        let manual = Task { await context.model.refreshNodes() }
        await first.waitForCancellation()
        first.release()
        await second.waitForEntry()
        XCTAssertEqual(context.model.nodeLatencies, readings)
        XCTAssertEqual(context.model.lastNodesRefreshedAt, originalDate,
                       "Cancelled automatic publication must not update the date")
        second.release()
        await automatic.value
        await manual.value
        XCTAssertEqual(commits, 2)
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
    }

    func testStage2AUncontendedCommitPublishesAndClearsManualLatency() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let selected = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(selected)
        let gate = NodeRefreshPublicationGate()
        context.model.nodeRefreshDidCommitForTesting = { await gate.pause() }
        let refresh = Task { await context.model.refreshNodes() }
        await gate.waitForEntry()
        let committed = await context.repository.snapshot()
        gate.release()
        await refresh.value
        XCTAssertEqual(context.model.nodes, committed)
        XCTAssertNotNil(context.model.selectedTunnelRevision)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
    }

    func testStage2AZeroAvailableFailureKeepsConnectedCatalogAndLatency() async throws {
        let context = try await makeRefreshContext(nodeProber: RecordingNodeHTTPProber())
        defer { removeDefaults(context.suite) }
        let selected = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(selected)
        let old = Stage2APublicationState(context.model)
        await context.fetcher.setYAML(Self.stage2AUnavailableFixture)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes, old.nodes)
        XCTAssertEqual(context.model.selectedTunnelRevision, old.revision)
        XCTAssertEqual(context.model.nodeLatencies, old.latencies)
        XCTAssertEqual(context.model.lastNodesRefreshedAt, old.refreshedAt)
        guard case .stale = context.model.nodesLoadState else {
            return XCTFail("Rejected regression must use the existing stale-data failure UI")
        }
    }

    func testStage2AEmptyNetworkAndParserFailuresPreserveUsableCatalog() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let selected = try XCTUnwrap(context.model.nodes.selectedNodeID)
        await context.model.testNodeLatency(selected)
        let old = Stage2APublicationState(context.model)
        for yaml in ["proxies: []", "proxies: [", "proxies: [invalid-node]"] {
            await context.fetcher.setYAML(yaml)
            await context.model.refreshNodes()
            XCTAssertEqual(context.model.nodes, old.nodes)
            XCTAssertEqual(context.model.selectedTunnelRevision, old.revision)
            XCTAssertEqual(context.model.nodeLatencies, old.latencies)
            XCTAssertEqual(context.model.lastNodesRefreshedAt, old.refreshedAt)
            XCTAssertNotNil(context.model.nodesLoadState.failureMessage)
        }
        await context.fetcher.setFailure(true)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes, old.nodes)
        XCTAssertEqual(context.model.nodeLatencies, old.latencies)
        XCTAssertNotNil(context.model.nodesLoadState.failureMessage)
    }

    func testStage2AFirstLoadZeroAvailableCatalogStillCommits() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        await context.model.signOut()
        await context.fetcher.setYAML(Self.stage2AUnavailableFixture)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        XCTAssertEqual(context.model.nodes.nodes.count, 1)
        XCTAssertFalse(context.model.nodes.nodes.contains(where: \.available))
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        let snapshot = await context.repository.snapshot()
        XCTAssertEqual(snapshot, context.model.nodes)
    }

    func testStage2AUnavailableOldCatalogMayAcceptUnavailableReplacement() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        await context.model.signOut()
        await context.fetcher.setYAML(Self.stage2AUnavailableFixture)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let old = context.model.nodes
        await context.fetcher.setYAML(Self.stage2AUnavailableFixture
            .replacingOccurrences(of: "Unsupported Fixture", with: "Another Unsupported Fixture"))
        await context.model.refreshNodes()
        XCTAssertNotEqual(context.model.nodes, old)
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertFalse(context.model.nodes.nodes.contains(where: \.available))
    }

    func testStage2AEmptyStillCannotReplaceExistingUnavailableCatalog() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        await context.model.signOut()
        await context.fetcher.setYAML(Self.stage2AUnavailableFixture)
        await context.model.establishAuthenticatedSession(session(), source: .login)
        let old = context.model.nodes
        await context.fetcher.setYAML("proxies: []")
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes, old)
        XCTAssertNotNil(context.model.nodesLoadState.failureMessage)
    }

    func testStage2AOtherAccountIsNotSubjectToOldAccountsAvailableCatalog() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        await context.fetcher.setYAML(Self.stage2AUnavailableFixture)
        let other = try await context.repository.refresh(
            config: config(), session: session(email: "other@example.invalid")
        )
        XCTAssertEqual(other.nodes.count, 1)
        XCTAssertFalse(other.nodes.contains(where: \.available))
    }

    func testStage2APartialAvailableCatalogWithRuntimeIssueStillCommits() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture") + """

          - name: Unsupported Fixture
            type: synthetic-unsupported
            server: 192.0.2.40
            port: 443
          - name: Unresolved Fixture
            type: ss
            server: 192.0.2.41
            port: 443
            cipher: aes-128-gcm
            password: synthetic-fixture
            dialer-proxy: Missing Fixture
        """)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertEqual(context.model.nodes.nodes.count, 3)
        XCTAssertEqual(context.model.nodes.nodes.filter(\.available).count, 2)
        let parsed = await context.repository.parsedSubscription()
        XCTAssertTrue(parsed?.runtimeProxyRecords.values.contains(where: { $0.issue != nil }) == true)
        let snapshot = await context.repository.snapshot()
        XCTAssertEqual(snapshot, context.model.nodes)
    }

    func testStage2AConnectedUnrelatedAdditionDoesNotSwitchCurrentNode() async throws {
        let context = try await makeRefreshContext()
        defer { removeDefaults(context.suite) }
        let selected = context.model.nodes.selectedNodeID
        let revision = context.model.selectedTunnelRevision
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture")
            + Self.stage2AOtherFixture)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.nodes.count, 2)
        XCTAssertEqual(context.model.nodes.selectedNodeID, selected)
        XCTAssertEqual(context.model.selectedTunnelRevision, revision)
    }

    func testStage2AConnectedNonCurrentRemovalDoesNotSwitchCurrentNode() async throws {
        let context = try await makeRefreshContext(extraNode: true)
        defer { removeDefaults(context.suite) }
        let selected = context.model.nodes.selectedNodeID
        let revision = context.model.selectedTunnelRevision
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture"))
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.nodes.count, 1)
        XCTAssertEqual(context.model.nodes.selectedNodeID, selected)
        XCTAssertEqual(context.model.selectedTunnelRevision, revision)
    }

    func testStage2AConnectedCurrentRemovalDoesNotAutoSelectRemainingNode() async throws {
        let context = try await makeRefreshContext(extraNode: true)
        defer { removeDefaults(context.suite) }
        let remaining = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        let previous = context.model.nodes.selectedNodeID
        context.model.nodeRefreshDidCommitForTesting = {
            XCTAssertEqual(context.model.nodes.selectedNodeID, previous,
                           "Final UI publication must follow Repository commit")
        }
        await context.fetcher.setYAML("proxies:" + Self.stage2AOtherFixture)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodes.nodes.map(\.id), [remaining])
        XCTAssertEqual(context.model.nodes.selectedNodeID, previous)
        XCTAssertNil(context.model.nodes.selectedNode)
        XCTAssertNil(context.model.selectedTunnelRevision)
        let snapshot = await context.repository.snapshot()
        XCTAssertEqual(snapshot, context.model.nodes)
    }

}


extension AuthenticatedBootstrapTests {
    func testStage2AAutomaticRefreshKeepsOnlyUnchangedLatencyReadings() async throws {
        let context = try await makeStage2APublicationContext()
        defer { removeDefaults(context.suite) }
        let first = try XCTUnwrap(context.model.nodes.nodes.first?.id)
        let other = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        await context.model.testNodeLatency(first)
        await context.model.testNodeLatency(other)
        let firstReading = try XCTUnwrap(context.model.nodeLatencies[first])
        XCTAssertNotNil(context.model.nodeLatencies[other])
        let replacement = Self.refreshFixture(password: "initial-fixture")
            + Self.stage2AOtherFixture
                .replacingOccurrences(of: "other-fixture", with: "changed-other-fixture")
            + """

          - name: Added Fixture
            type: ss
            server: 192.0.2.42
            port: 443
            cipher: aes-128-gcm
            password: added-fixture
        """
        await context.fetcher.setYAML(replacement)
        await context.model.initializeAuthenticatedData()
        XCTAssertEqual(context.model.nodesLoadState, .loaded)
        XCTAssertEqual(context.model.nodes.nodes.count, 3)
        XCTAssertEqual(context.model.nodeLatencies[first], firstReading)
        XCTAssertNil(context.model.nodeLatencies[other])
        let added = try XCTUnwrap(context.model.nodes.nodes.last?.id)
        XCTAssertNil(context.model.nodeLatencies[added])
        XCTAssertEqual(context.model.nodes.selectedNodeID, first)
    }
}

extension AuthenticatedBootstrapTests {
    func testStage2CBatchLateSuccessCannotPublishAfterLoginB() async throws {
        let context = try await makeRefreshContext(nodeProber: RecordingNodeHTTPProber())
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { phase in
            if phase == "batch-result" { await gate.pause() }
        }
        let task = Task { await context.model.testAllNodeLatencies() }
        await gate.waitForEntry()
        await context.model.signOut()
        await context.model.establishAuthenticatedSession(
            session(email: "b@example.invalid", authData: "synthetic-b"), source: .login
        )
        let readings = context.model.nodeLatencies
        let progress = context.model.nodeLatencyProgress
        gate.release()
        await task.value
        XCTAssertEqual(context.model.nodeLatencies, readings, "A result cannot enter B cache")
        XCTAssertEqual(context.model.nodeLatencyProgress, progress, "A cannot advance B progress")
    }

    func testStage2CSingleLateSuccessCannotPublishAfterRevisionChange() async throws {
        let context = try await makeRefreshContext(nodeProber: RecordingNodeHTTPProber())
        defer { removeDefaults(context.suite) }
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { phase in
            if phase == "single-result" { await gate.pause() }
        }
        let task = Task { await context.model.testNodeLatency(id) }
        await gate.waitForEntry()
        await context.fetcher.setYAML(Self.refreshFixture(password: "changed-fixture"))
        _ = try await context.repository.refresh(config: config(), session: session())
        gate.release()
        await task.value
        if case .measured = context.model.nodeLatencies[id] {
            XCTFail("A delay for R1 cannot enter the R2 catalog")
        }
    }

    func testStage2CMapperFailureCannotPublishAfterLoginB() async throws {
        let context = try await makeRefreshContext(nodeProber: RecordingNodeHTTPProber())
        defer { removeDefaults(context.suite) }
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture")
            .replacingOccurrences(of: "1.1.1.1", with: "127.0.0.1"))
        await context.model.refreshNodes()
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { phase in
            if phase == "mapper-failure" { await gate.pause() }
        }
        let task = Task { await context.model.testAllNodeLatencies() }
        await gate.waitForEntry()
        await context.model.signOut()
        await context.model.establishAuthenticatedSession(
            session(email: "b@example.invalid", authData: "synthetic-b"), source: .login
        )
        let readings = context.model.nodeLatencies
        let progress = context.model.nodeLatencyProgress
        gate.release()
        await task.value
        XCTAssertEqual(context.model.nodeLatencies, readings, "Stale mapping failure cannot enter B")
        XCTAssertEqual(context.model.nodeLatencyProgress, progress)
    }
}

/// A non-cooperative synthetic callback source. It owns no SDK/Core and can
/// replay a drained round's callback to prove token rejection deterministically.
private actor Stage2CLatencyProber: NodeHTTPProbing {
    private var outcome: NodeProbeOutcome
    private var callbacks: [@Sendable (NodeProbeResult) async -> Void] = []
    private var candidates: [NodeProbeCandidate] = []
    private var throwCancellation = false
    private var throwBatchFailure = false
    private var omitResults = false
    init(_ outcome: NodeProbeOutcome = .measured(43)) { self.outcome = outcome }
    func setOutcome(_ outcome: NodeProbeOutcome) { self.outcome = outcome }
    func cancelOnReturn() { throwCancellation = true }
    func failBatch() { throwBatchFailure = true }
    func omitCallbacks() { omitResults = true }
    func count() -> Int { callbacks.count }
    func probeNode(yaml: String, coreName: String) async throws -> Int {
        if throwCancellation { throw CancellationError() }
        switch outcome {
        case let .measured(ms): return ms
        case .timedOut: throw MihomoNodeProbeError.timeout
        case .failed: throw MihomoNodeProbeError.unreachable
        case .unavailable: throw RecoveryRuntimeError.unavailable
        }
    }
    func probeBatch(_ items: [NodeProbeCandidate],
                    onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool,
                    onResult: @escaping @Sendable (NodeProbeResult) async -> Void) async throws {
        if throwCancellation { throw CancellationError() }
        if throwBatchFailure || omitResults {
            for item in items {
                guard await onStart(item) else { throw CancellationError() }
            }
            if throwBatchFailure { throw MihomoNodeProbeError.unreachable }
            return
        }
        for item in items {
            guard await onStart(item) else { throw CancellationError() }
            candidates.append(item); callbacks.append(onResult)
            await onResult(NodeProbeResult(nodeID: item.nodeID, revision: item.revision, outcome: outcome))
        }
    }
    func replay(_ index: Int, outcome: NodeProbeOutcome) async {
        let item = candidates[index]
        await callbacks[index](NodeProbeResult(nodeID: item.nodeID, revision: item.revision, outcome: outcome))
    }
}

extension AuthenticatedBootstrapTests {
    private func stage2CContext(_ prober: any NodeHTTPProbing) async throws -> RefreshContext {
        try await makeRefreshContext(nodeProber: prober)
    }

    private func assertStage2CNormal(_ outcome: NodeProbeOutcome, batch: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let context = try await stage2CContext(Stage2CLatencyProber(outcome))
        defer { removeDefaults(context.suite) }
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let selected = context.model.nodes
        let revision = context.model.selectedTunnelRevision
        if batch { await context.model.testAllNodeLatencies() }
        else { await context.model.testNodeLatency(id) }
        let expected: NodeLatencyState
        switch outcome {
        case let .measured(ms): expected = ms < 0 ? .failed : .measured(NodeLatencyReading(actualMilliseconds: ms, displayRatio: 1)!)
        case .failed: expected = .failed
        case .timedOut: expected = .timedOut
        case .unavailable: expected = .unavailable
        }
        XCTAssertEqual(context.model.nodeLatencies[id], expected, file: file, line: line)
        if batch { XCTAssertEqual(context.model.nodeLatencyProgress, .init(completed: 1, total: 1), file: file, line: line) }
        XCTAssertEqual(context.model.nodes, selected, file: file, line: line)
        XCTAssertEqual(context.model.selectedTunnelRevision, revision, file: file, line: line)
    }

    func testStage2CNormalBatchSuccessAndFormalStateIsolation() async throws { try await assertStage2CNormal(.measured(43), batch: true) }
    func testStage2CNormalBatchFailure() async throws { try await assertStage2CNormal(.failed, batch: true) }
    func testStage2CNormalBatchTimeout() async throws { try await assertStage2CNormal(.timedOut, batch: true) }
    func testStage2CNormalBatchUnavailable() async throws { try await assertStage2CNormal(.unavailable, batch: true) }
    func testStage2CNormalSingleSuccess() async throws { try await assertStage2CNormal(.measured(43), batch: false) }
    func testStage2CNormalSingleFailure() async throws { try await assertStage2CNormal(.failed, batch: false) }
    func testStage2CNormalSingleTimeout() async throws { try await assertStage2CNormal(.timedOut, batch: false) }
    func testStage2CNormalSingleUnavailable() async throws { try await assertStage2CNormal(.unavailable, batch: false) }
    func testStage2CInvalidRawDelayFailsOnlyCurrentOperation() async throws { try await assertStage2CNormal(.measured(-1), batch: true) }

    private enum Stage2CMutation { case logout, loginB, authGeneration, repositoryGeneration, revision, deleteNode, manualRefresh }

    private func assertStage2CDrop(_ outcome: NodeProbeOutcome, mutation: Stage2CMutation,
                                   batch: Bool = true,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let context = try await stage2CContext(Stage2CLatencyProber(outcome))
        defer { removeDefaults(context.suite) }
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let gate = NodeRefreshPublicationGate()
        let phase = batch ? "batch-result" : "single-result"
        context.model.latencyWillCommitForTesting = { if $0 == phase { await gate.pause() } }
        let task = Task {
            if batch { await context.model.testAllNodeLatencies() }
            else { await context.model.testNodeLatency(id) }
        }
        await gate.waitForEntry()
        switch mutation {
        case .logout: await context.model.signOut()
        case .loginB:
            await context.model.signOut()
            // Identical YAML/ID in B makes account ownership, not naming, decisive.
            await context.model.establishAuthenticatedSession(session(email: "b@example.invalid", authData: "synthetic-b"), source: .login)
        case .authGeneration:
            await context.model.establishAuthenticatedSession(session(), source: .login)
        case .repositoryGeneration:
            _ = try await context.repository.prepareRefresh(config: config(), session: session())
        case .revision:
            await context.fetcher.setYAML(Self.refreshFixture(password: "changed-fixture"))
            _ = try await context.repository.refresh(config: config(), session: session())
        case .deleteNode:
            await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture")
                .replacingOccurrences(of: "Stable Fixture", with: "Other Fixture")
                .replacingOccurrences(of: "1.1.1.1", with: "1.0.0.1"))
            await context.model.refreshNodes()
        case .manualRefresh: await context.model.refreshNodes()

        }
        let oldProgress = context.model.nodeLatencyProgress
        let selected = context.model.nodes
        let selectedRevision = context.model.selectedTunnelRevision
        gate.release()
        await task.value
        if case .measured = context.model.nodeLatencies[id] { XCTFail("Stale measured result published", file: file, line: line) }
        XCTAssertNotEqual(context.model.nodeLatencies[id], .failed, file: file, line: line)
        XCTAssertNotEqual(context.model.nodeLatencies[id], .timedOut, file: file, line: line)
        XCTAssertNotEqual(context.model.nodeLatencies[id], .unavailable, file: file, line: line)
        // Owner cancellation may restore idle progress; it must never count a dropped result.
        XCTAssertLessThanOrEqual(context.model.nodeLatencyProgress.completed, oldProgress.completed, file: file, line: line)
        XCTAssertEqual(context.model.nodes, selected, file: file, line: line)
        XCTAssertEqual(context.model.selectedTunnelRevision, selectedRevision, file: file, line: line)
        XCTAssertFalse(context.model.testingAllNodes, file: file, line: line)
    }

    func testStage2CLogoutDropsBatchSuccess() async throws { try await assertStage2CDrop(.measured(43), mutation: .logout) }
    func testStage2CLoginBDropsBatchFailureWithIdenticalNodeID() async throws { try await assertStage2CDrop(.failed, mutation: .loginB) }
    func testStage2CLoginBDropsBatchTimeout() async throws { try await assertStage2CDrop(.timedOut, mutation: .loginB) }
    func testStage2CLoginBDropsBatchUnavailable() async throws { try await assertStage2CDrop(.unavailable, mutation: .loginB) }
    func testStage2CNewAuthenticatedGenerationDropsResult() async throws { try await assertStage2CDrop(.measured(43), mutation: .authGeneration) }
    func testStage2CRepositoryGenerationDropsBatchResult() async throws { try await assertStage2CDrop(.measured(43), mutation: .repositoryGeneration) }
    func testStage2CRevisionChangeDropsBatchResult() async throws { try await assertStage2CDrop(.measured(43), mutation: .revision) }
    func testStage2CNodeRemovalDropsResult() async throws { try await assertStage2CDrop(.measured(43), mutation: .deleteNode) }
    func testStage2CManualRefreshDropsOldResult() async throws { try await assertStage2CDrop(.measured(43), mutation: .manualRefresh) }
    func testStage2CSingleFailureDropsAfterRevisionChange() async throws { try await assertStage2CDrop(.failed, mutation: .revision, batch: false) }
    func testStage2CSingleTimeoutDropsAfterRevisionChange() async throws { try await assertStage2CDrop(.timedOut, mutation: .revision, batch: false) }
    func testStage2CSingleUnavailableDropsAfterLoginB() async throws { try await assertStage2CDrop(.unavailable, mutation: .loginB, batch: false) }

    private func assertStage2CRoundReplay(_ outcome: NodeProbeOutcome,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let prober = Stage2CLatencyProber()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        let gate1 = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "batch-result" { await gate1.pause() } }
        let first = Task { await context.model.testAllNodeLatencies() }
        await gate1.waitForEntry()
        context.model.cancelAllNodeLatencies()
        // Attempting Round2 before drain must not acquire another Core/slot.
        await context.model.testAllNodeLatencies()
        let beforeDrain = await prober.count()
        XCTAssertEqual(beforeDrain, 1, file: file, line: line)
        gate1.release(); await first.value
        XCTAssertTrue(context.model.nodeLatencies.isEmpty, file: file, line: line)
        await prober.setOutcome(.measured(91))
        let gate2 = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "batch-result" { await gate2.pause() } }
        let second = Task { await context.model.testAllNodeLatencies() }
        await gate2.waitForEntry()
        let testing = context.model.nodeLatencies
        let progress = context.model.nodeLatencyProgress
        context.model.latencyWillCommitForTesting = nil
        await prober.replay(0, outcome: outcome)
        XCTAssertEqual(context.model.nodeLatencies, testing, file: file, line: line)
        XCTAssertEqual(context.model.nodeLatencyProgress, progress, file: file, line: line)
        XCTAssertTrue(context.model.testingAllNodes, file: file, line: line)
        gate2.release(); await second.value
        let complete = context.model.nodeLatencies
        await prober.replay(0, outcome: outcome)
        XCTAssertEqual(context.model.nodeLatencies, complete, file: file, line: line)
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        XCTAssertEqual(complete[id], .measured(NodeLatencyReading(actualMilliseconds: 91, displayRatio: 1)!), file: file, line: line)
    }
    func testStage2CRound1LateSuccessCannotOverwriteRound2() async throws { try await assertStage2CRoundReplay(.measured(10)) }
    func testStage2CRound1LateFailureCannotOverwriteRound2() async throws { try await assertStage2CRoundReplay(.failed) }
    func testStage2CRound1LateTimeoutCannotOverwriteRound2() async throws { try await assertStage2CRoundReplay(.timedOut) }

    func testStage2CCancelledBatchRestoresUIWithoutFailureOrUnavailable() async throws {
        let prober = Stage2CLatencyProber(); await prober.cancelOnReturn()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        await context.model.testAllNodeLatencies()
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        XCTAssertEqual(context.model.nodeLatencyProgress, .idle)
        XCTAssertFalse(context.model.testingAllNodes)
    }
    func testStage2CCancelledSingleRestoresUIWithoutFailure() async throws {
        let prober = Stage2CLatencyProber(); await prober.cancelOnReturn()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        await context.model.testNodeLatency(try XCTUnwrap(context.model.nodes.selectedNodeID))
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
    }
    func testStage2CCancelledCallerDropsNonCooperativeBatchSuccess() async throws {
        let context = try await stage2CContext(Stage2CLatencyProber())
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "batch-result" { await gate.pause() } }
        let task = Task { await context.model.testAllNodeLatencies() }
        await gate.waitForEntry(); task.cancel(); gate.release(); await task.value
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        XCTAssertEqual(context.model.nodeLatencyProgress, .idle)
    }
    func testStage2CWholeBatchFailureUsesFinalGuard() async throws {
        let prober = Stage2CLatencyProber(); await prober.failBatch()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        await context.model.testAllNodeLatencies()
        XCTAssertEqual(context.model.nodeLatencies.values.first, .failed)
        XCTAssertEqual(context.model.nodeLatencyProgress.completed, 1)
    }
    func testStage2CValidMapperFailureStillPublishes() async throws {
        let context = try await stage2CContext(Stage2CLatencyProber())
        defer { removeDefaults(context.suite) }
        await context.fetcher.setYAML(Self.refreshFixture(password: "initial-fixture")
            .replacingOccurrences(of: "1.1.1.1", with: "127.0.0.1"))
        await context.model.refreshNodes()
        await context.model.testAllNodeLatencies()
        XCTAssertEqual(context.model.nodeLatencies.values.first, .failed)
        XCTAssertEqual(context.model.nodeLatencyProgress.completed, 1)
    }
    func testStage2CFailedRefreshPreservesCompletedReading() async throws {
        let context = try await stage2CContext(Stage2CLatencyProber())
        defer { removeDefaults(context.suite) }
        await context.model.testAllNodeLatencies()
        let readings = context.model.nodeLatencies
        await context.fetcher.setFailure(true)
        await context.model.refreshNodes()
        XCTAssertEqual(context.model.nodeLatencies, readings)
        XCTAssertNotNil(context.model.nodesLoadState.failureMessage)
    }
    func testStage2CManualRefreshClearsCompletedReading() async throws {
        let context = try await stage2CContext(Stage2CLatencyProber())
        defer { removeDefaults(context.suite) }
        await context.model.testAllNodeLatencies()
        XCTAssertFalse(context.model.nodeLatencies.isEmpty)
        await context.model.refreshNodes()
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
    }
    func testStage2CDisplayRatioAndRoundingRemainUnchanged() {
        XCTAssertEqual(NodeLatencyReading(actualMilliseconds: 43, displayRatio: 1.5)?.displayMilliseconds, 65)
        XCTAssertEqual(NodeLatencyReading(actualMilliseconds: 43, displayRatio: .nan)?.displayMilliseconds, 43)
        XCTAssertEqual(NodeLatencyReading(actualMilliseconds: 43, displayRatio: 0)?.displayMilliseconds, 43)
    }
    func testStage2COldFinishCannotReleaseNewRound() {
        let owner = NodeLatencyCoordinator()
        let first = owner.begin()!
        owner.cancelActive()
        XCTAssertNil(owner.begin(), "Cancellation must drain before reuse")
        XCTAssertTrue(owner.finish(generation: first))
        let second = owner.begin()!
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(owner.finish(generation: first))
        XCTAssertTrue(owner.isCurrent(second))
        XCTAssertTrue(owner.finish(generation: second))
    }
}

extension AuthenticatedBootstrapTests {
    func testStage2CCommitOfAlreadyPreparedRefreshInvalidatesLateLatency() async throws {
        let context = try await stage2CContext(Stage2CLatencyProber())
        defer { removeDefaults(context.suite) }
        await context.fetcher.setYAML(Self.refreshFixture(password: "changed-fixture"))
        let prepared = try await context.repository.prepareRefresh(config: config(), session: session())
        let before = context.repository.latencySubscriptionGeneration
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "batch-result" { await gate.pause() } }
        let task = Task { await context.model.testAllNodeLatencies() }
        await gate.waitForEntry()
        _ = try await context.repository.commitRefresh(prepared)
        let after = context.repository.latencySubscriptionGeneration
        XCTAssertEqual(before.transaction, after.transaction)
        XCTAssertNotEqual(before.committed, after.committed,
            "Prepare's existing token must also expose the later commit boundary")
        gate.release(); await task.value
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
        XCTAssertEqual(context.model.nodeLatencyProgress, .idle)
    }

    func testStage2CWholeBatchFailureCannotPublishAfterLoginB() async throws {
        let prober = Stage2CLatencyProber(); await prober.failBatch()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "batch-failure" { await gate.pause() } }
        let task = Task { await context.model.testAllNodeLatencies() }
        await gate.waitForEntry()
        await context.model.signOut()
        await context.model.establishAuthenticatedSession(session(email: "b@example.invalid", authData: "synthetic-b"), source: .login)
        let readings = context.model.nodeLatencies
        let progress = context.model.nodeLatencyProgress
        gate.release(); await task.value
        XCTAssertEqual(context.model.nodeLatencies, readings)
        XCTAssertEqual(context.model.nodeLatencyProgress, progress)
    }

    func testStage2CCancelledCallerDropsNonCooperativeSingleTimeout() async throws {
        let context = try await stage2CContext(Stage2CLatencyProber(.timedOut))
        defer { removeDefaults(context.suite) }
        let id = try XCTUnwrap(context.model.nodes.selectedNodeID)
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "single-result" { await gate.pause() } }
        let task = Task { await context.model.testNodeLatency(id) }
        await gate.waitForEntry(); task.cancel(); gate.release(); await task.value
        XCTAssertTrue(context.model.nodeLatencies.isEmpty)
    }
}

extension AuthenticatedBootstrapTests {
    func testStage2CValidBatchCompletionPublishesUnavailable() async throws {
        let prober = Stage2CLatencyProber(); await prober.omitCallbacks()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        await context.model.testAllNodeLatencies()
        XCTAssertEqual(context.model.nodeLatencies.values.first, .unavailable)
        XCTAssertEqual(context.model.nodeLatencyProgress, .init(completed: 1, total: 1))
    }

    func testStage2CBatchCompletionCannotChangeNewAccountProgress() async throws {
        let prober = Stage2CLatencyProber(); await prober.omitCallbacks()
        let context = try await stage2CContext(prober)
        defer { removeDefaults(context.suite) }
        let gate = NodeRefreshPublicationGate()
        context.model.latencyWillCommitForTesting = { if $0 == "batch-completion" { await gate.pause() } }
        let task = Task { await context.model.testAllNodeLatencies() }
        await gate.waitForEntry()
        await context.model.signOut()
        await context.model.establishAuthenticatedSession(session(email: "b@example.invalid", authData: "synthetic-b"), source: .login)
        let readings = context.model.nodeLatencies
        let progress = context.model.nodeLatencyProgress
        gate.release(); await task.value
        XCTAssertEqual(context.model.nodeLatencies, readings)
        XCTAssertEqual(context.model.nodeLatencyProgress, progress)
    }

}


extension AuthenticatedBootstrapTests {




}

// Stage 2B uses fixed synthetic catalogs and in-memory adapters only.
private actor Stage2BMemorySelection: NodeSelectionBindingStoring {
    private var values: [String: StoredNodeSelection] = [:]
    private(set) var writes = 0
    func loadSelectedNodeID(accountScope: NodeSelectionAccountScope) -> String? { values[accountScope.rawValue]?.nodeID }
    func saveSelectedNodeID(_ id: String, accountScope: NodeSelectionAccountScope) { values[accountScope.rawValue] = .legacy(id) }
    func loadSelection(accountScope: NodeSelectionAccountScope) -> StoredNodeSelection? { values[accountScope.rawValue] }
    func saveSelection(_ binding: NodeSelectionBinding?, accountScope: NodeSelectionAccountScope) {
        writes += 1
        values[accountScope.rawValue] = binding.map(StoredNodeSelection.bound)
    }
    func seed(_ value: StoredNodeSelection?, scope: NodeSelectionAccountScope) { values[scope.rawValue] = value }
}

private struct Stage2BUpgradeParser: SubscriptionParsing {
    let legacyRaw: String?
    func parse(_ raw: String) throws -> ParsedSubscription {
        let parsed = try SubscriptionParser().parse(raw)
        if raw == legacyRaw {
            let ordered = parsed.nodes.compactMap { parsed.runtimeProxyRecords[$0.id]?.originalProxy }
            return try Stage2BFixture.legacy(ordered)
        }
        return parsed
    }
}

final class Stage2BSelectionTests: XCTestCase {
    private var config: AppConfig {
        AppConfig(appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil, telegramGroup: nil,
            supportAPI: nil, updateURL: nil, userAgent: "Tests", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: ["https://example.invalid"], activeAPIBaseURL: "https://example.invalid", builtInProxy: [])
    }
    private func account(_ email: String = "stage2b@example.invalid") -> UserSession {
        UserSession(email: email, authData: "synthetic-auth", accountToken: nil, subscriptionURL: "https://example.invalid/synthetic-subscription",
            uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 0, expiredAt: 0, planID: nil,
            planName: "", balanceCents: nil, verifiedAt: Date(timeIntervalSince1970: 0))
    }
    private struct Context {
        let repository: NodeRepository
        let store: Stage2BMemorySelection
        let fetcher: StagedSubscriptionFetcher
        let oldID: String
    }
    private func make(_ proxies: [[String: YAMLValue]], selected: Int = 0, legacy: Bool = false) async throws -> Context {
        let store = Stage2BMemorySelection(), fetcher = StagedSubscriptionFetcher()
        let raw = try Stage2BFixture.yaml(proxies)
        await fetcher.setYAML(raw)
        let repository = NodeRepository(subscriptionInfoProvider: StagedSubscriptionInfo(), subscriptionFetcher: fetcher,
            subscriptionParser: Stage2BUpgradeParser(legacyRaw: legacy ? raw : nil), selectionStore: store)
        let initial = try await repository.refresh(config: config, session: account())
        let id = initial.nodes[selected].id
        _ = try await repository.selectNode(id: id, session: account())
        if legacy { await store.seed(.legacy(id), scope: account().nodeSelectionAccountScope!) }
        return Context(repository: repository, store: store, fetcher: fetcher, oldID: id)
    }
    private func refresh(_ c: Context, _ proxies: [[String: YAMLValue]], cold: Bool = false) async throws -> NodeRepository {
        await c.fetcher.setYAML(try Stage2BFixture.yaml(proxies))
        let repository = cold ? NodeRepository(subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: c.fetcher, selectionStore: c.store) : c.repository
        _ = try await repository.refresh(config: config, session: account())
        return repository
    }
    private func selected(_ repository: NodeRepository) async -> [String: YAMLValue]? {
        let snapshot = await repository.snapshot(), sub = await repository.parsedSubscription()
        return snapshot.selectedNodeID.flatMap { sub?.runtimeProxyRecords[$0]?.originalProxy }
    }
    private func assertSelected(_ repository: NodeRepository, _ expected: [String: YAMLValue]?,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await selected(repository)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func collisionThree() -> [[String: YAMLValue]] {
        Stage2BFixture.variants("flow") + [Stage2BFixture.variants("short")[1]]
    }
    private func sortedCollisionThree() throws -> [[String: YAMLValue]] {
        try collisionThree().sorted { try Stage2BFixture.digest($0) < Stage2BFixture.digest($1) }
    }
    private func seedBinding(_ c: Context, id: String? = nil, digest: String? = nil) async throws {
        let sub = await c.repository.parsedSubscription()!
        let record = sub.runtimeProxyRecords[c.oldID]!
        let binding = NodeSelectionBinding(nodeID: id ?? c.oldID,
            configurationDigest: try digest ?? Stage2BFixture.digest(record.originalProxy), kind: .collision)
        await c.store.seed(.bound(binding), scope: account().nodeSelectionAccountScope!)
    }

    func testNewBindingExactRestoreAfterRepositoryRecreation() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        await assertSelected(try await refresh(c, p.reversed(), cold: true), p[0])
    }
    func testBindingIDExistsButDigestMismatchMigratesToUniqueActualEntity() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        let wrongID = (await c.repository.snapshot()).nodes[1].id
        try await seedBinding(c, id: wrongID)
        let restored = try await refresh(c, p.reversed(), cold: true)
        await assertSelected(restored, p[0])
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.selectedNodeID, c.oldID)
        XCTAssertNotEqual(snapshot.selectedNodeID, wrongID)
    }
    func testBindingUniqueDigestCanMigrateFromMissingID() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        try await seedBinding(c, id: "legacy-ordinal")
        await assertSelected(try await refresh(c, p.reversed(), cold: true), p[0])
    }
    func testBindingNoDigestMatchClearsInsteadOfAcceptingExistingID() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        try await seedBinding(c, digest: String(repeating: "0", count: 64))
        await assertSelected(try await refresh(c, p, cold: true), nil)
        let stored = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        XCTAssertNil(stored)
    }
    func testBindingMultipleDigestMatchesDoesNotGuessOrdinal() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        await assertSelected(try await refresh(c, [p[0],p[0],p[1]], cold: true), nil)
    }
    func testBindingCannotBeDowngradedToUniquePolicyInsideCollision() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        await c.store.seed(.bound(NodeSelectionBinding(nodeID: c.oldID,
            configurationDigest: String(repeating: "0", count: 64), kind: .uniqueName)),
            scope: account().nodeSelectionAccountScope!)
        await assertSelected(try await refresh(c, p, cold: true), nil)
    }
    func testAccountBindingDoesNotSelectForAnotherAccount() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        let other = account("other@example.invalid")
        let cold = NodeRepository(subscriptionInfoProvider: StagedSubscriptionInfo(), subscriptionFetcher: c.fetcher, selectionStore: c.store)
        let snapshot = try await cold.refresh(config: config, session: other)
        XCTAssertNil(snapshot.selectedNodeID)
        let original = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        XCTAssertNotNil(original)
    }
    func testManualSelectionWritesAccountBoundConfigurationDigest() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        let saved = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        guard case let .bound(binding) = saved else { return XCTFail("Missing manual selection binding") }
        XCTAssertEqual(binding.nodeID, c.oldID)
        XCTAssertEqual(binding.configurationDigest, try Stage2BFixture.digest(p[0]))
        XCTAssertEqual(binding.kind, .collision)
    }
    func testPrepareRefreshDoesNotPersistMigratedBinding() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p, legacy: true)
        let before = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        let writes = await c.store.writes
        await c.fetcher.setYAML(try Stage2BFixture.yaml(p.reversed()))
        let prepared = try await c.repository.prepareRefresh(config: config, session: account())
        let afterPrepare = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        let afterWrites = await c.store.writes
        XCTAssertEqual(before, afterPrepare); XCTAssertEqual(writes, afterWrites)
        _ = try await c.repository.commitRefresh(prepared)
        let afterCommit = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        guard case .bound = afterCommit else { return XCTFail("Commit did not persist binding") }
    }
    func testColdLegacyUniqueNameStillRestores() async throws {
        let p = [Stage2BFixture.base()], c = try await make(p, legacy: true)
        await assertSelected(try await refresh(c, p, cold: true), p[0])
    }
    func testColdLegacyOrdinaryDuplicateStillRestores() async throws {
        let a = Stage2BFixture.base(), b = Stage2BFixture.changed(a, "server", .string("198.51.100.11"))
        let c = try await make([a,b], legacy: true)
        await assertSelected(try await refresh(c, [b,a], cold: true), a)
    }
    func testColdLegacyCollisionDoesNotGuessAfterReorder() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p, legacy: true)
        await assertSelected(try await refresh(c, p.reversed(), cold: true), nil)
    }
    func testWarmLegacyFastPathPreservesKnownEntityAfterUpgrade() async throws {
        let pair = Stage2BFixture.variants("flow")
        let p = try pair.sorted { try Stage2BFixture.digest($0) > Stage2BFixture.digest($1) }
        let c = try await make(p, legacy: true)
        let upgraded = try Stage2BFixture.parse(p.reversed())
        XCTAssertNotEqual(c.oldID, try Stage2BFixture.id(p[0], in: upgraded),
                          "The old existing ordinal must actually point to the other entity")
        await assertSelected(try await refresh(c, p.reversed()), p[0])
    }
    func testTripleWarmLegacyRotationPreservesSelectedEntity() async throws {
        let p = collisionThree(), c = try await make(p, legacy: true)
        await assertSelected(try await refresh(c, [p[2],p[0],p[1]]), p[0])
    }
    func testMemberInsertionMigratesSelectionUsingBinding() async throws {
        let p = try sortedCollisionThree(), c = try await make([p[1],p[2]])
        let repository = try await refresh(c, p, cold: true)
        await assertSelected(repository, p[1])
        let snapshot = await repository.snapshot()
        XCTAssertNotEqual(snapshot.selectedNodeID, c.oldID)
    }
    func testMemberRemovalKeepsRemainingSelectedEntity() async throws {
        let p = try sortedCollisionThree(), c = try await make(p, selected: 2)
        await assertSelected(try await refresh(c, [p[0],p[2]], cold: true), p[2])
    }
    func testRemovedSelectedCollisionMemberNeverTransfersToAnother() async throws {
        let p = try sortedCollisionThree(), c = try await make(p, selected: 1)
        await assertSelected(try await refresh(c, [p[0],p[2]], cold: true), nil)
    }
    func testWarmLegacyMemberInsertionKeepsKnownEntity() async throws {
        let p = try sortedCollisionThree(), c = try await make([p[1],p[2]], legacy: true)
        await assertSelected(try await refresh(c, p), p[1])
    }
    func testWarmLegacyRemovedSelectedMemberDoesNotGuess() async throws {
        let p = try sortedCollisionThree(), c = try await make(p, selected: 1, legacy: true)
        await assertSelected(try await refresh(c, [p[0],p[2]]), nil)
    }
    func testAddedIdenticalDuplicateHasNoProvableEntity() async throws {
        let p = Stage2BFixture.variants("flow"), c = try await make(p)
        await assertSelected(try await refresh(c, [p[0],p[0],p[1]]), nil)
    }
    func testRemovedIdenticalDuplicateDoesNotInventOccurrenceIdentity() async throws {
        let a = Stage2BFixture.base(), c = try await make([a,a])
        await assertSelected(try await refresh(c, [a]), nil)
    }
    func testRenameOnlyMigratesAndRebinds() async throws {
        let a = Stage2BFixture.base("Old Name"), c = try await make([a])
        let b = Stage2BFixture.changed(a, "name", .string("New Name"))
        await assertSelected(try await refresh(c, [b]), b)
        let bound = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        guard case let .bound(binding) = bound else { return XCTFail("Missing renamed binding") }
        XCTAssertEqual(binding.configurationDigest, try Stage2BFixture.digest(b))
    }
    private func assertRenameRejected(_ field: String) async throws {
        let pair = Stage2BFixture.variants(field), a = Stage2BFixture.changed(pair[0], "name", .string("Old Name"))
        let b = Stage2BFixture.changed(pair[1], "name", .string("New Name")), c = try await make([a])
        await assertSelected(try await refresh(c, [b]), nil)
    }
    func testRenamePlusFlowRejected() async throws { try await assertRenameRejected("flow") }
    func testRenamePlusRealityKeyRejected() async throws { try await assertRenameRejected("key") }
    func testRenamePlusTransportRejected() async throws { try await assertRenameRejected("ws") }
    func testRenameOneToTwoRejected() async throws {
        let a = Stage2BFixture.base("Old"), c = try await make([a])
        await assertSelected(try await refresh(c, [Stage2BFixture.changed(a,"name",.string("New1")),
                                                   Stage2BFixture.changed(a,"name",.string("New2"))]), nil)
    }
    func testRenameTwoToOneRejected() async throws {
        let a = Stage2BFixture.base("Old1"), b = Stage2BFixture.changed(a,"name",.string("Old2"))
        let c = try await make([a,b])
        await assertSelected(try await refresh(c, [Stage2BFixture.changed(a,"name",.string("New"))]), nil)
    }
    func testExpectedSelectionCannotCommitThroughCatalogRemap() async throws {
        let p = try sortedCollisionThree(), c = try await make([p[1],p[2]])
        let old = await c.repository.parsedSubscription()!, record = old.runtimeProxyRecords[c.oldID]!
        _ = try await refresh(c, p)
        let current = await c.repository.parsedSubscription()!
        XCTAssertEqual(c.oldID, try Stage2BFixture.id(p[0], in: current))
        do {
            _ = try await c.repository.selectNode(id: c.oldID, session: account(),
                expectedRevision: Stage2BFixture.digest(p[1]), expectedCoreName: record.coreName)
            XCTFail("The old intent committed to the newly rebound ordinal")
        } catch is CancellationError {}
        await assertSelected(c.repository, p[1])
    }
    func testCollisionBindingRemainsStrictAfterGroupShrinks() async throws {
        for cold in [false,true] {
            let p = Stage2BFixture.variants("flow"), c = try await make(p)
            _ = try await refresh(c, [p[0]])
            let saved = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
            guard case let .bound(binding) = saved else { return XCTFail("Missing binding") }
            XCTAssertEqual(binding.kind, .collision)
            await assertSelected(try await refresh(c, [p[1]], cold: cold), nil)
        }
    }
    func testExpectedSelectionRejectsSameIDChangedConfiguration() async throws {
        let a = Stage2BFixture.base(), c = try await make([a])
        let old = await c.repository.parsedSubscription()!, core = old.runtimeProxyRecords[c.oldID]!.coreName
        let b = Stage2BFixture.variants("flow")[1]
        _ = try await refresh(c, [b])
        do {
            _ = try await c.repository.selectNode(id: c.oldID, session: account(),
                expectedRevision: Stage2BFixture.digest(a), expectedCoreName: core)
            XCTFail("Stale intent was accepted")
        } catch is CancellationError {}
    }
    func testUniqueLogicalConfigurationRefreshStillUsesRevision() async throws {
        let a = Stage2BFixture.base(), c = try await make([a]), b = Stage2BFixture.variants("flow")[1]
        await assertSelected(try await refresh(c, [b], cold: true), b)
    }
    func testBindingAuditSameUniqueNameAndConfigurationPreservesBinding() async throws {
        let a = Stage2BFixture.base("Unique Fixture"), c = try await make([a])
        let before = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        let restored = try await refresh(c, [a], cold: true)
        let after = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        XCTAssertEqual(before, after)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.selectedNodeID, c.oldID)
        guard case let .bound(binding) = after else { return XCTFail("Missing binding") }
        XCTAssertEqual(binding.kind, .uniqueName)
    }
    func testBindingAuditUniqueNameConfigurationUpdateRebindsDigestWithoutChangingID() async throws {
        let a = Stage2BFixture.base("Unique Fixture"), c = try await make([a])
        let before = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        let b = Stage2BFixture.changed(a, "udp", .bool(false))
        let restored = try await refresh(c, [b], cold: true)
        let after = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        guard case let .bound(old) = before, case let .bound(new) = after else { return XCTFail("Missing binding") }
        XCTAssertEqual(new.nodeID, old.nodeID); XCTAssertEqual(new.kind, old.kind)
        XCTAssertEqual(new.kind, .uniqueName)
        XCTAssertNotEqual(new.configurationDigest, old.configurationDigest)
        XCTAssertEqual(new.configurationDigest, try Stage2BFixture.digest(b))
        await assertSelected(restored, b)
    }
    func testBindingAuditPreparedRefreshPreservesSelectionUntilIdentityCommit() async throws {
        let a = Stage2BFixture.base("Unique Fixture"), c = try await make([a])
        let before = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        let b = Stage2BFixture.changed(a, "udp", .bool(false))
        await c.fetcher.setYAML(try Stage2BFixture.yaml([b]))
        let prepared = try await c.repository.prepareRefresh(config: config, session: account())
        let staged = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        XCTAssertEqual(staged, before)
        let snapshot = try await c.repository.commitRefresh(prepared)
        XCTAssertEqual(snapshot.selectedNodeID, c.oldID)
        let committed = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        guard case let .bound(binding) = committed else { return XCTFail("Missing committed binding") }
        XCTAssertEqual(binding.configurationDigest, try Stage2BFixture.digest(b))
    }
    func testBindingAuditDigestUpdateCannotTransferSelectionToAnotherUniqueName() async throws {
        let a = Stage2BFixture.base("Selected Fixture")
        let other = Stage2BFixture.base("Other Fixture")
        let c = try await make([a, other]), updated = Stage2BFixture.changed(a, "udp", .bool(false))
        let restored = try await refresh(c, [other, updated], cold: true)
        let snapshot = await restored.snapshot(), parsed = await restored.parsedSubscription()!
        XCTAssertEqual(snapshot.selectedNodeID, c.oldID)
        XCTAssertEqual(parsed.runtimeProxyRecords[c.oldID]?.originalProxy, updated)
        XCTAssertEqual(try parsed.runtimeProxyRecords.values.filter {
            try OriginalProxyCanonicalization.digest($0.originalProxy) == Stage2BFixture.digest(updated)
        }.count, 1)
    }
    func testBindingAuditJSONKeyOrderDoesNotChangeProxyDigestOrRecordSemantics() throws {
        let proxy = Stage2BFixture.base("Unique Fixture")
        var reordered: [String: YAMLValue] = [:]
        for key in proxy.keys.sorted().reversed() { reordered[key] = proxy[key] }
        XCTAssertEqual(try OriginalProxyCanonicalization.digest(proxy), try OriginalProxyCanonicalization.digest(reordered))
        struct Record: Decodable { let schemaVersion: Int; let binding: NodeSelectionBinding }
        let digest = String(repeating: "a", count: 64)
        let first = Data("{\"schemaVersion\":1,\"binding\":{\"nodeID\":\"fixture\",\"configurationDigest\":\"\(digest)\",\"kind\":\"uniqueName\"}}".utf8)
        let second = Data("{\"binding\":{\"kind\":\"uniqueName\",\"configurationDigest\":\"\(digest)\",\"nodeID\":\"fixture\"},\"schemaVersion\":1}".utf8)
        XCTAssertNotEqual(first, second)
        let a = try JSONDecoder().decode(Record.self, from: first), b = try JSONDecoder().decode(Record.self, from: second)
        XCTAssertEqual(a.schemaVersion, b.schemaVersion); XCTAssertEqual(a.binding, b.binding)
    }
    func testBindingAuditRenameOnlyUpdatesIDAndDigestUnderExistingUniqueRule() async throws {
        let a = Stage2BFixture.base("Before Fixture"), c = try await make([a])
        let renamed = Stage2BFixture.changed(a, "name", .string("After Fixture"))
        // Rename migration needs the old catalog's unique connection proof;
        // a cold repository must not infer an entity from the new name alone.
        let restored = try await refresh(c, [renamed])
        await assertSelected(restored, renamed)
        let after = await c.store.loadSelection(accountScope: account().nodeSelectionAccountScope!)
        guard case let .bound(binding) = after else { return XCTFail("Missing migrated binding") }
        XCTAssertNotEqual(binding.nodeID, c.oldID); XCTAssertEqual(binding.kind, .uniqueName)
        XCTAssertEqual(binding.configurationDigest, try Stage2BFixture.digest(renamed))
    }
    @MainActor
    func testLatencyDoesNotTransferAcrossCollisionOrdinalShift() throws {
        let p = collisionThree(), old = try Stage2BFixture.parse(Array(p.prefix(2)))
        let new = try Stage2BFixture.parse([p[2],p[0],p[1]]), cache = NodeLatencyCoordinator()
        cache.replaceReadings([old.nodes[0].id: .measured(NodeLatencyReading(actualMilliseconds: 43, displayRatio: 1)!)])
        _ = cache.reconcile(previousNodes: old.nodes, previousSubscription: old, refreshedNodes: new.nodes, refreshedSubscription: new)
        for (id,_) in cache.readings {
            XCTAssertEqual(old.runtimeProxyRecords[id]?.originalProxy, new.runtimeProxyRecords[id]?.originalProxy)
        }
    }
    @MainActor
    func testLatencyDropsChangedRevisionAndKeepsOnlyUnchangedConfig() throws {
        let a = Stage2BFixture.base(), old = try Stage2BFixture.parse([a])
        let new = try Stage2BFixture.parse([Stage2BFixture.variants("flow")[1]]), cache = NodeLatencyCoordinator()
        cache.replaceReadings([old.nodes[0].id: .measured(NodeLatencyReading(actualMilliseconds: 43, displayRatio: 1)!)])
        _ = cache.reconcile(previousNodes: old.nodes, previousSubscription: old, refreshedNodes: old.nodes, refreshedSubscription: old)
        XCTAssertNotNil(cache.readings[old.nodes[0].id])
        _ = cache.reconcile(previousNodes: old.nodes, previousSubscription: old, refreshedNodes: new.nodes, refreshedSubscription: new)
        XCTAssertTrue(cache.readings.isEmpty)
    }
}

final class Stage2BSelectionStoreTests: XCTestCase {
    private let suite = "NetworkClient.Tests.Stage2B.SelectionStore"
    private let scopeA = NodeSelectionAccountScope(accountIdentifier: "a@example.invalid")!
    private let scopeB = NodeSelectionAccountScope(accountIdentifier: "b@example.invalid")!
    override func setUp() { super.setUp(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); super.tearDown() }
    private var binding: NodeSelectionBinding {
        NodeSelectionBinding(nodeID: "synthetic-node-id", configurationDigest: String(repeating: "a", count: 64), kind: .collision)
    }
    func testLegacyStringRemainsReadable() async {
        let store = NodeSelectionStore(suiteName: suite)
        await store.saveSelectedNodeID("legacy-id", accountScope: scopeA)
        let value = await store.loadSelection(accountScope: scopeA)
        XCTAssertEqual(value, .legacy("legacy-id"))
    }
    func testNewBindingSurvivesStoreRecreation() async {
        await NodeSelectionStore(suiteName: suite).saveSelection(binding, accountScope: scopeA)
        let value = await NodeSelectionStore(suiteName: suite).loadSelection(accountScope: scopeA)
        XCTAssertEqual(value, .bound(binding))
    }
    func testSidecarContainsOnlyVersionDigestAndIdentityMetadata() async throws {
        let p = Stage2BFixture.variants("tuic")[0]
        let value = NodeSelectionBinding(nodeID: "synthetic-id", configurationDigest: try Stage2BFixture.digest(p), kind: .collision)
        await NodeSelectionStore(suiteName: suite).saveSelection(value, accountScope: scopeA)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let data = try XCTUnwrap(defaults.data(forKey: "nodeSelection.binding.v1." + scopeA.rawValue))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion","binding"])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let body = try XCTUnwrap(json["binding"] as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["nodeID","configurationDigest","kind"])
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["synthetic-token-a", "198.51.100.10", Stage2BFixture.uuid, "edge.fixture.invalid"] {
            XCTAssertFalse(text.contains(secret))
        }
    }
    func testAccountsAreIsolatedAndClearOnlyCurrentScope() async {
        let store = NodeSelectionStore(suiteName: suite)
        await store.saveSelection(binding, accountScope: scopeA)
        await store.saveSelection(binding, accountScope: scopeB)
        await store.saveSelection(nil, accountScope: scopeA)
        let a = await store.loadSelection(accountScope: scopeA), b = await store.loadSelection(accountScope: scopeB)
        XCTAssertNil(a); XCTAssertEqual(b, .bound(binding))
    }
    func testCorruptSidecarNeverFallsBackToLegacyOrdinal() async {
        let store = NodeSelectionStore(suiteName: suite)
        await store.saveSelectedNodeID("legacy-id", accountScope: scopeA)
        UserDefaults(suiteName: suite)?.set(Data("invalid".utf8), forKey: "nodeSelection.binding.v1." + scopeA.rawValue)
        let result = await store.loadSelection(accountScope: scopeA)
        XCTAssertEqual(result, .invalid)
    }
    func testUnsupportedSchemaNeverFallsBackToLegacyOrdinal() async {
        let store = NodeSelectionStore(suiteName: suite)
        await store.saveSelection(binding, accountScope: scopeA)
        let defaults = UserDefaults(suiteName: suite)!
        let key = "nodeSelection.binding.v1." + scopeA.rawValue
        let data = defaults.data(forKey: key)!
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        defaults.set(Data(text.utf8), forKey: key)
        let result = await store.loadSelection(accountScope: scopeA)
        XCTAssertEqual(result, .invalid)
    }
    func testMismatchedLegacyKeyDoesNotDowngradeBinding() async {
        let store = NodeSelectionStore(suiteName: suite)
        await store.saveSelection(binding, accountScope: scopeA)
        UserDefaults(suiteName: suite)?.set("another-ordinal", forKey: "nodeSelection.selectedNodeId." + scopeA.rawValue)
        let result = await store.loadSelection(accountScope: scopeA)
        XCTAssertEqual(result, .invalid)
    }
    func testClearedRecordDoesNotReviveLegacyChoice() async {
        let store = NodeSelectionStore(suiteName: suite)
        await store.saveSelection(nil, accountScope: scopeA)
        UserDefaults(suiteName: suite)?.set("old-ordinal", forKey: "nodeSelection.selectedNodeId." + scopeA.rawValue)
        let result = await store.loadSelection(accountScope: scopeA)
        XCTAssertNil(result)
    }
}


extension AuthenticatedBootstrapTests {
    private func stage2BSubscription(_ repository: NodeRepository) async throws -> ParsedSubscription {
        let value = await repository.parsedSubscription()
        return try XCTUnwrap(value)
    }
    private func stage2BSelectionContext(_ catalog: [[String: YAMLValue]]? = nil) async throws -> (RefreshContext, [[String: YAMLValue]]) {
        let suite = "NetworkClient.Tests.Stage2B.Connected"
        removeDefaults(suite)
        let sessions = SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        let account = UserSession(email: "account@example.invalid", authData: "synthetic-auth", accountToken: nil,
            subscriptionURL: "https://example.invalid/synthetic-subscription", uploadBytes: 0, downloadBytes: 0, transferEnableBytes: 0, expiredAt: 0,
            planID: nil, planName: "", balanceCents: nil, verifiedAt: Date(timeIntervalSince1970: 0))
        let p = (catalog ?? Stage2BFixture.variants("flow")).map { Stage2BFixture.changed($0, "server", .string("1.1.1.1")) }
        let fetcher = StagedSubscriptionFetcher()
        await fetcher.setYAML(try Stage2BFixture.yaml(p))
        let repository = NodeRepository(subscriptionInfoProvider: StagedSubscriptionInfo(),
            subscriptionFetcher: fetcher, selectionStore: NodeSelectionStore(suiteName: suite))
        let model = AppModel(offline: false, businessDataAPI: BootstrapBusinessAPI(),
            sessionVerifier: BootstrapSessionVerifier(), nodeRepository: repository,
            apiHealthMonitor: offlineHealthMonitor(), sessionStore: sessions, initialConfig: config())
        await model.establishAuthenticatedSession(account, source: .login)
        let sub = try await stage2BSubscription(repository)
        await model.selectNode(try Stage2BFixture.id(p[1], in: sub))
        return (RefreshContext(model: model, repository: repository, fetcher: fetcher, suite: suite), p)
    }
    func testStage2BLegitimateNewIntentCommitsRequestedEntity() async throws {
        let (c,p) = try await stage2BSelectionContext()
        defer { removeDefaults(c.suite) }
        let sub = try await stage2BSubscription(c.repository)
        let id = try Stage2BFixture.id(p[0], in: sub)
        await c.model.selectNode(id)
        XCTAssertEqual(c.model.nodes.selectedNodeID, id)
        let saved = await NodeSelectionStore(suiteName: c.suite).loadSelection(accountScope: c.model.session!.nodeSelectionAccountScope!)
        guard case let .bound(binding) = saved else { return XCTFail("Missing persisted business selection") }
        XCTAssertEqual(binding.configurationDigest, try Stage2BFixture.digest(p[0]))
    }
}

extension AuthenticatedBootstrapTests {
}

final class UsageTermsConsentPlacementTests: XCTestCase {
    func testConnectGatePrecedesVPNStartWithoutEnteringTunnelCore() throws {
        let home = try source("App/Views/HomeView.swift")
        let authorization = try XCTUnwrap(home.range(
            of: "await usageTermsConsent.authorize"
        ))
        let connect = try XCTUnwrap(home.range(of: "try await vpn.connect"))

        XCTAssertLessThan(authorization.lowerBound, connect.lowerBound)
        XCTAssertTrue(home.contains("guard vpn.state == .disconnected"))
        XCTAssertTrue(home.contains("vpn.operation == .idle"))
        XCTAssertFalse(try source("NetworkPacketTunnel/PacketTunnelProvider.swift")
            .contains("UsageTermsConsent"))
    }

    func testPurchaseGatePrecedesOrderCreationAndEveryCheckoutEntry() throws {
        let commerce = try source("App/Views/CommerceView.swift")
        let start = try XCTUnwrap(commerce.range(of: "private func presentPurchaseOrder"))
        let end = try XCTUnwrap(commerce.range(
            of: "@ViewBuilder\n    private var pendingPaymentCard",
            range: start.upperBound..<commerce.endIndex
        ))
        let purchaseRegion = String(commerce[start.lowerBound..<end.lowerBound])
        let authorization = try XCTUnwrap(purchaseRegion.range(
            of: "await usageTermsConsent.authorize"
        ))
        let createOrder = try XCTUnwrap(purchaseRegion.range(of: "await model.createOrder"))

        XCTAssertLessThan(authorization.lowerBound, createOrder.lowerBound)
        XCTAssertEqual(
            commerce.components(separatedBy: "await usageTermsConsent.authorize").count - 1,
            4,
            "Order creation, both payment-method entries, and direct checkout reopening must be gated"
        )
        XCTAssertEqual(
            commerce.components(separatedBy: "await model.beginCheckout").count - 1,
            2
        )
    }

    func testUnifiedConsentUsesIndependentVersionedDeviceKey() {
        XCTAssertEqual(UsageTermsConsentPolicy.requiredVersion, 1)
        XCTAssertEqual(
            UsageTermsConsentPolicy.acceptedVersionKey,
            "ios.usage_terms_privacy.accepted_version"
        )
        XCTAssertEqual(
            UsageTermsConsentPolicy.legacyVPNDisclosureAcceptedVersionKey,
            "ios.vpn.data_disclosure.accepted_version"
        )
        XCTAssertNotEqual(
            UsageTermsConsentPolicy.acceptedVersionKey,
            UsageTermsConsentPolicy.legacyVPNDisclosureAcceptedVersionKey
        )
        XCTAssertFalse(UsageTermsConsentPolicy.acceptedVersionKey.lowercased()
            .contains("retiredbrand"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

extension AuthenticatedBootstrapTests {
    func testStage2BRemapAfterSelectionPersistenceCannotPublishAnotherEntity() async throws {
        let (c,p) = try await stage2BSelectionContext()
        defer { removeDefaults(c.suite) }
        let before = c.model.nodes
        let beforeRevision = c.model.selectedTunnelRevision
        let sub = try await stage2BSubscription(c.repository)
        let target = try Stage2BFixture.id(p[0], in: sub)
        let gate = NodeRefreshPublicationGate()
        c.model.nodeSelectionDidPersistForTesting = { await gate.pause() }
        let selection = Task { await c.model.selectNode(target) }
        await gate.waitForEntry()
        let changed = Stage2BFixture.changed(p[0], "reality-opts.short-id", .string("cdef"))
        await c.fetcher.setYAML(try Stage2BFixture.yaml([changed,p[1]]))
        _ = try await c.repository.refresh(config: config(), session: c.model.session!)
        gate.release(); await selection.value
        XCTAssertEqual(c.model.nodes, before)
        XCTAssertEqual(c.model.selectedTunnelRevision, beforeRevision)
    }
}
