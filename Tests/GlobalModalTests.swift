import XCTest
@testable import NetworkClient

private actor AuthSubmissionAuthorizationGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func authorize() async -> Bool {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return true
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class GlobalModalTests: XCTestCase {
    func testHostLayoutAccountsForVerticalPaddingInsideViewport() {
        let viewportHeight: CGFloat = 800
        let availableHeight = GlobalModalHostLayoutMetrics
            .availableContentHeight(in: viewportHeight)

        XCTAssertEqual(availableHeight, 760)
        XCTAssertEqual(
            availableHeight + GlobalModalHostLayoutMetrics.verticalPadding * 2,
            viewportHeight
        )
    }

    func testHostLayoutDoesNotCreateOverflowForShortContent() {
        XCTAssertFalse(GlobalModalHostLayoutMetrics.contentOverflows(
            320,
            in: 800
        ))
    }

    func testHostLayoutPreservesScrollingForRealOverflow() {
        XCTAssertTrue(GlobalModalHostLayoutMetrics.contentOverflows(
            761,
            in: 800
        ))
        XCTAssertEqual(
            GlobalModalHostLayoutMetrics.availableContentHeight(in: 30),
            0
        )
    }

    func testCreatedOrderStaysOnPurchaseBackgroundUntilCheckoutReturns() {
        let tradeNo = CommerceOrderCreationNavigation.paymentTradeNo(
            for: .created(tradeNo: "fixture-trade")
        )

        XCTAssertEqual(tradeNo, "fixture-trade")
        XCTAssertNil(CommerceOrderCreationNavigation.checkoutTradeNo(
            tradeNo: "fixture-trade",
            checkout: nil
        ))
        XCTAssertEqual(CommerceOrderCreationNavigation.checkoutTradeNo(
            tradeNo: "fixture-trade",
            checkout: PurchaseCheckoutResult(type: 1, data: "https://example.invalid/pay")
        ), "fixture-trade")
    }

    func testInformationRequestSupportsLocalizedAndVerbatimText() {
        let id = UUID()
        let request = GlobalModalRequest.information(
            id: id,
            title: .localized("fixture.title"),
            message: .verbatim("Runtime message")
        )

        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.kind, .information)
        XCTAssertEqual(request.title, .localized("fixture.title"))
        XCTAssertEqual(request.message, .verbatim("Runtime message"))
        XCTAssertEqual(request.primary.role, .normal)
        XCTAssertNil(request.secondary)
    }

    func testDestructiveRequestHasDestructivePrimaryAndCancelSecondary() throws {
        let request = GlobalModalRequest.destructive(
            title: .localized("fixture.clear.title"),
            message: .localized("fixture.clear.message"),
            primaryTitle: .verbatim("Delete")
        )

        XCTAssertEqual(request.kind, .destructive)
        XCTAssertEqual(request.primary.role, .destructive)
        XCTAssertEqual(request.primary.identifier, "global.modal.primary")
        XCTAssertEqual(try XCTUnwrap(request.secondary).role, .cancel)
        XCTAssertEqual(request.secondary?.identifier, "global.modal.secondary")
    }

    func testDiagnosticsLogClearRequestUsesExistingCopyAndDestructiveRoles() throws {
        let request = DiagnosticsLogClearPresentation.request()

        XCTAssertEqual(request.kind, .destructive)
        XCTAssertEqual(request.title, .localized("diagnostics.clear.confirm.title"))
        XCTAssertEqual(request.message, .localized("diagnostics.clear.confirm.message"))
        XCTAssertEqual(request.primary.title, .localized("diagnostics.clear"))
        XCTAssertEqual(request.primary.role, .destructive)
        XCTAssertEqual(request.primary.identifier, "global.modal.primary")
        let cancel = try XCTUnwrap(request.secondary)
        XCTAssertEqual(cancel.title, .localized("取消"))
        XCTAssertEqual(cancel.role, .cancel)
        XCTAssertEqual(cancel.identifier, "global.modal.secondary")
    }

    func testDiagnosticsLogClearFailureUsesSafeInformationRequest() {
        let request = DiagnosticsLogClearPresentation.failureRequest()

        XCTAssertEqual(request.kind, .information)
        XCTAssertEqual(request.title, .localized("diagnostics.title"))
        XCTAssertEqual(request.message, .localized("diagnostics.clear.failed"))
        let description = String(describing: request)
        XCTAssertFalse(description.contains("/Library/"))
        XCTAssertFalse(description.contains("NSError"))
        XCTAssertFalse(description.contains("POSIX"))
    }

    func testDiagnosticsLogClearCancelDoesNotRunOwnerClearAction() async {
        let presenter = GlobalModalPresenter()
        let request = DiagnosticsLogClearPresentation.request()
        var clearCount = 0
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertTrue(presenter.resolve(.secondary, requestID: request.id))
        let choice = await result.value
        if DiagnosticsLogClearPresentation.shouldClear(for: choice) {
            clearCount += 1
        }

        XCTAssertEqual(choice, .secondary)
        XCTAssertEqual(clearCount, 0)
    }

    func testDiagnosticsLogClearConfirmRunsOwnerClearActionOnlyOnce() async {
        let presenter = GlobalModalPresenter()
        let request = DiagnosticsLogClearPresentation.request()
        var clearCount = 0
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        XCTAssertFalse(presenter.resolve(.primary, requestID: request.id))
        let choice = await result.value
        if DiagnosticsLogClearPresentation.shouldClear(for: choice) {
            clearCount += 1
        }

        XCTAssertEqual(choice, .primary)
        XCTAssertEqual(clearCount, 1)
    }

    func testAppModelMessageRequestUsesInformationAndPreservesRuntimeVerbatimText() {
        let runtimeMessage = LocalizedMessage.verbatim("Runtime response, not a localization key")
        let request = AppModelMessagePresentation.request(for: runtimeMessage)

        XCTAssertEqual(request.kind, .information)
        XCTAssertEqual(request.title, .localized("提示"))
        XCTAssertEqual(request.message, runtimeMessage)
        XCTAssertEqual(request.primary.title, .localized("确定"))
        XCTAssertEqual(request.primary.role, .normal)
        XCTAssertNil(request.secondary)
    }

    func testAppModelMessagePrimaryAndDismissAreSafeConsumptionChoices() {
        XCTAssertTrue(AppModelMessagePresentation.shouldConsume(for: .primary))
        XCTAssertTrue(AppModelMessagePresentation.shouldConsume(for: .dismissed))
        XCTAssertFalse(AppModelMessagePresentation.shouldConsume(for: .secondary))
        XCTAssertFalse(AppModelMessagePresentation.shouldConsume(for: .alreadyPresenting))
    }

    func testAppModelMessageDismissConsumesOnlyTheDisplayedCurrentValue() async {
        let presenter = GlobalModalPresenter()
        let bridge = AppModelMessageBridge()
        let message = LocalizedMessage.verbatim("Dismissed message")
        var current: LocalizedMessage? = message
        var consumed: [LocalizedMessage] = []
        let dismissedMessageConsumed = expectation(description: "dismissed message consumed")

        bridge.synchronize(
            currentMessage: { current },
            presenter: presenter,
            consume: { displayedMessage in
                consumed.append(displayedMessage)
                if current == displayedMessage { current = nil }
                dismissedMessageConsumed.fulfill()
            }
        )
        await Task.yield()

        XCTAssertTrue(presenter.resolve(.dismissed, requestID: presenter.activeRequest?.id))
        await fulfillment(of: [dismissedMessageConsumed], timeout: 1)

        XCTAssertNil(current)
        XCTAssertEqual(consumed, [message])
        XCTAssertNil(presenter.activeRequest)
    }

    func testAppModelMessageStaleCompletionDoesNotClearNewerMessage() async {
        let presenter = GlobalModalPresenter()
        let bridge = AppModelMessageBridge()
        let first = LocalizedMessage.verbatim("A")
        let second = LocalizedMessage.verbatim("B")
        var current: LocalizedMessage? = first
        var consumed: [LocalizedMessage] = []
        let secondConsumed = expectation(description: "newest message consumed")

        bridge.synchronize(
            currentMessage: { current },
            presenter: presenter,
            consume: { message in
                consumed.append(message)
                if current == message { current = nil }
                if message == second { secondConsumed.fulfill() }
            }
        )
        await Task.yield()
        let firstRequest = presenter.activeRequest
        XCTAssertEqual(firstRequest?.message, first)

        current = second
        XCTAssertTrue(presenter.resolve(.primary, requestID: firstRequest?.id))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(current, second)
        XCTAssertEqual(consumed, [])
        XCTAssertEqual(presenter.activeRequest?.message, second)

        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        await fulfillment(of: [secondConsumed], timeout: 1)
        XCTAssertNil(current)
        XCTAssertEqual(consumed, [second])
    }

    func testAppModelMessageSameValueDoesNotPresentTwiceDuringViewUpdates() async {
        let presenter = GlobalModalPresenter()
        let bridge = AppModelMessageBridge()
        let message = LocalizedMessage.verbatim("One presentation")
        var current: LocalizedMessage? = message
        var consumeCount = 0
        let synchronize = {
            bridge.synchronize(
                currentMessage: { current },
                presenter: presenter,
                consume: { displayedMessage in
                    consumeCount += 1
                    if current == displayedMessage { current = nil }
                }
            )
        }

        synchronize()
        synchronize()
        await Task.yield()
        let requestID = presenter.activeRequest?.id
        synchronize()
        XCTAssertEqual(presenter.activeRequest?.id, requestID)

        XCTAssertTrue(presenter.resolve(.primary, requestID: requestID))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(consumeCount, 1)
        XCTAssertNil(current)
        XCTAssertNil(presenter.activeRequest)
    }

    func testAppModelMessageWaitsForActiveModalAndUsesOnlyLatestCurrentValue() async {
        let presenter = GlobalModalPresenter()
        let bridge = AppModelMessageBridge()
        let existing = GlobalModalRequest.information(message: .verbatim("Existing modal"))
        let existingResult = Task { await presenter.present(existing) }
        await Task.yield()

        var current: LocalizedMessage? = .verbatim("A")
        var consumed: [LocalizedMessage] = []
        let synchronize = {
            bridge.synchronize(
                currentMessage: { current },
                presenter: presenter,
                consume: { displayedMessage in
                    consumed.append(displayedMessage)
                    if current == displayedMessage { current = nil }
                }
            )
        }

        synchronize()
        await Task.yield()
        current = .verbatim("B")
        synchronize()
        await Task.yield()

        XCTAssertEqual(presenter.activeRequest, existing)
        XCTAssertEqual(current, .verbatim("B"))
        XCTAssertEqual(consumed, [])

        XCTAssertTrue(presenter.resolve(.primary, requestID: existing.id))
        _ = await existingResult.value
        synchronize()
        await Task.yield()

        XCTAssertEqual(presenter.activeRequest?.message, .verbatim("B"))
        XCTAssertEqual(consumed, [])

        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        await Task.yield()
        XCTAssertNil(current)
        XCTAssertEqual(consumed, [.verbatim("B")])
    }

    func testChangePasswordSuccessUsesExistingCopyAndSuccessResult() {
        let request = ChangePasswordSuccessPresentation.request()

        XCTAssertEqual(request.kind, .result(.success))
        XCTAssertEqual(request.title, .localized("profile.change_password.success"))
        XCTAssertNil(request.message)
        XCTAssertEqual(request.primary.title, .localized("确定"))
        XCTAssertEqual(request.primary.role, .normal)
        XCTAssertNil(request.secondary)
    }

    func testChangePasswordSuccessDismissesOnlyForPrimaryChoice() {
        XCTAssertTrue(ChangePasswordSuccessPresentation.shouldInvalidateSession(for: .primary))
        XCTAssertFalse(ChangePasswordSuccessPresentation.shouldInvalidateSession(for: .secondary))
        XCTAssertFalse(ChangePasswordSuccessPresentation.shouldInvalidateSession(for: .dismissed))
        XCTAssertFalse(ChangePasswordSuccessPresentation.shouldInvalidateSession(for: .alreadyPresenting))
    }

    func testChangePasswordCompletionCancelHasNoOwnerSideEffects() async {
        var events: [String] = []

        let outcome = await ChangePasswordCompletionFlow.complete(
            choice: .secondary,
            vpnIsActive: true,
            invalidateSession: {
                events.append("invalidate")
                return .invalidated(storageCleared: true)
            },
            disconnectVPN: {
                events.append("disconnect")
            },
            reportVPNDisconnectFailure: {
                events.append("report")
            }
        )

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(events, [])
    }

    func testChangePasswordCompletionInvalidatesBeforeBestEffortVPNDisconnect() async {
        var events: [String] = []

        let outcome = await ChangePasswordCompletionFlow.complete(
            choice: .primary,
            vpnIsActive: true,
            invalidateSession: {
                events.append("invalidate")
                return .invalidated(storageCleared: true)
            },
            disconnectVPN: {
                events.append("disconnect")
            },
            reportVPNDisconnectFailure: {
                events.append("report")
            }
        )

        XCTAssertEqual(
            outcome,
            .completed(storageCleared: true, vpnDisconnectFailed: false)
        )
        XCTAssertEqual(events, ["invalidate", "disconnect"])
    }

    func testChangePasswordCompletionReportsVPNFailureWithoutUndoingInvalidation() async {
        var events: [String] = []

        let outcome = await ChangePasswordCompletionFlow.complete(
            choice: .primary,
            vpnIsActive: true,
            invalidateSession: {
                events.append("invalidate")
                return .invalidated(storageCleared: false)
            },
            disconnectVPN: {
                events.append("disconnect")
                throw URLError(.cannotConnectToHost)
            },
            reportVPNDisconnectFailure: {
                events.append("report")
            }
        )

        XCTAssertEqual(
            outcome,
            .completed(storageCleared: false, vpnDisconnectFailed: true)
        )
        XCTAssertEqual(events, ["invalidate", "disconnect", "report"])
    }

    func testChangePasswordCompletionDoesNotTouchVPNForStaleSession() async {
        var events: [String] = []

        let outcome = await ChangePasswordCompletionFlow.complete(
            choice: .primary,
            vpnIsActive: true,
            invalidateSession: {
                events.append("invalidate")
                return .stale
            },
            disconnectVPN: {
                events.append("disconnect")
            },
            reportVPNDisconnectFailure: {
                events.append("report")
            }
        )

        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(events, ["invalidate"])
    }

    func testProfileSignOutRequestUsesExistingCopyAndDestructiveRole() throws {
        let request = ProfileSignOutPresentation.request()

        XCTAssertEqual(request.kind, .destructive)
        XCTAssertEqual(request.title, .localized("profile.sign_out.message"))
        XCTAssertNil(request.message)
        XCTAssertEqual(request.primary.title, .localized("退出登录"))
        XCTAssertEqual(request.primary.role, .destructive)
        let cancel = try XCTUnwrap(request.secondary)
        XCTAssertEqual(cancel.title, .localized("取消"))
        XCTAssertEqual(cancel.role, .cancel)
    }

    func testAccountDeletionConfirmationUsesDestructiveGlobalModal() throws {
        let request = AccountDeletionRequestPresentation.confirmationRequest()

        XCTAssertEqual(request.kind, .destructive)
        XCTAssertEqual(request.title, .localized("profile.account_deletion.title"))
        XCTAssertEqual(
            request.message,
            .localized("profile.account_deletion.confirm.message")
        )
        XCTAssertEqual(request.primary.title, .localized("profile.account_deletion.submit"))
        XCTAssertEqual(request.primary.role, .destructive)
        let cancel = try XCTUnwrap(request.secondary)
        XCTAssertEqual(cancel.title, .localized("profile.action.cancel"))
        XCTAssertEqual(cancel.role, .cancel)
        XCTAssertTrue(AccountDeletionRequestPresentation.shouldSubmit(for: .primary))
        XCTAssertFalse(AccountDeletionRequestPresentation.shouldSubmit(for: .secondary))
        XCTAssertFalse(AccountDeletionRequestPresentation.shouldSubmit(for: .dismissed))
    }

    func testAccountDeletionSuccessModalDescribesSubmittedRequestOnly() {
        let request = AccountDeletionRequestPresentation.successRequest()

        XCTAssertEqual(request.kind, .result(.success))
        XCTAssertEqual(
            request.title,
            .localized("profile.account_deletion.success.title")
        )
        XCTAssertEqual(
            request.message,
            .localized("profile.account_deletion.success.message")
        )
        XCTAssertEqual(
            request.primary.title,
            .localized("profile.account_deletion.success.acknowledge")
        )
        XCTAssertNil(request.secondary)
        XCTAssertNotEqual(request.title, .verbatim("账户已删除"))
    }

    func testProfileSignOutCancelDoesNotRunOwnerChain() async {
        var ownerEvents: [String] = []

        let outcome = await ProfileSignOutFlow.complete(
            choice: .secondary,
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: { ownerEvents.append("disconnect") },
            confirmVPNDisconnected: {
                ownerEvents.append("confirm")
                return true
            },
            signOut: { ownerEvents.append("signOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("report") }
        )

        XCTAssertEqual(outcome, .ignored)
        XCTAssertTrue(ownerEvents.isEmpty)
    }

    func testProfileSignOutAlreadyDisconnectedSkipsDisconnectAndSignsOutOnce() async {
        var ownerEvents: [String] = []

        let outcome = await ProfileSignOutFlow.complete(
            choice: .primary,
            isVPNConfirmedDisconnected: { true },
            disconnectVPN: { ownerEvents.append("disconnect") },
            confirmVPNDisconnected: {
                ownerEvents.append("confirm")
                return true
            },
            signOut: { ownerEvents.append("signOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("report") }
        )

        XCTAssertEqual(outcome, .signOutRequested)
        XCTAssertEqual(ownerEvents, ["signOut"])
    }

    func testProfileSignOutWaitsForConfirmedDisconnectBeforeSigningOut() async {
        var ownerEvents: [String] = []

        let outcome = await ProfileSignOutFlow.complete(
            choice: .primary,
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: { ownerEvents.append("disconnect") },
            confirmVPNDisconnected: {
                XCTAssertEqual(ownerEvents, ["disconnect"])
                ownerEvents.append("confirmedDisconnected")
                return true
            },
            signOut: { ownerEvents.append("signOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("report") }
        )

        XCTAssertEqual(outcome, .signOutRequested)
        XCTAssertEqual(ownerEvents, ["disconnect", "confirmedDisconnected", "signOut"])
    }

    func testProfileSignOutDisconnectErrorKeepsAuthenticationAndReportsFailure() async {
        var ownerEvents: [String] = []

        let outcome = await ProfileSignOutFlow.complete(
            choice: .primary,
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: {
                ownerEvents.append("disconnect")
                throw URLError(.cannotConnectToHost)
            },
            confirmVPNDisconnected: {
                ownerEvents.append("confirm")
                return true
            },
            signOut: { ownerEvents.append("signOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("report") }
        )

        XCTAssertEqual(outcome, .vpnDisconnectFailed)
        XCTAssertEqual(ownerEvents, ["disconnect", "report"])
    }

    func testProfileSignOutUnconfirmedDisconnectKeepsAuthenticationAndReportsFailure() async {
        var ownerEvents: [String] = []

        let outcome = await ProfileSignOutFlow.complete(
            choice: .primary,
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: { ownerEvents.append("disconnect") },
            confirmVPNDisconnected: {
                ownerEvents.append("timeout")
                return false
            },
            signOut: { ownerEvents.append("signOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("report") }
        )

        XCTAssertEqual(outcome, .vpnDisconnectFailed)
        XCTAssertEqual(ownerEvents, ["disconnect", "timeout", "report"])
    }

    func testProfileSignOutCancellationNeverSignsOutOrReportsFailure() async {
        var ownerEvents: [String] = []

        let outcome = await ProfileSignOutFlow.complete(
            choice: .primary,
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: {
                ownerEvents.append("disconnect")
                throw CancellationError()
            },
            confirmVPNDisconnected: { true },
            signOut: { ownerEvents.append("signOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("report") }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(ownerEvents, ["disconnect"])
    }

    func testProfileSignOutConfirmedDisconnectWaiterDoesNotAcceptIntermediateState() async throws {
        var confirmedDisconnected = false
        let transition = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(5))
            confirmedDisconnected = true
        }

        let confirmed = try await ProfileSignOutFlow.waitForConfirmedDisconnect(
            isConfirmed: { confirmedDisconnected },
            timeout: .milliseconds(100),
            pollInterval: .milliseconds(1)
        )
        _ = try await transition.value

        XCTAssertTrue(confirmed)
    }

    func testProfileSignOutCoordinatorRejectsConcurrentConfirmation() async throws {
        let coordinator = ProfileSignOutCoordinator()
        let presenter = GlobalModalPresenter()
        let request = ProfileSignOutPresentation.request()
        var ownerEvents: [String] = []

        let first = Task { @MainActor in
            await coordinator.run(
                present: { await presenter.present(request) },
                isVPNConfirmedDisconnected: { false },
                disconnectVPN: { ownerEvents.append("disconnect") },
                confirmVPNDisconnected: {
                    ownerEvents.append("confirmedDisconnected")
                    return true
                },
                signOut: { ownerEvents.append("signOut") },
                reportVPNDisconnectFailure: { ownerEvents.append("report") }
            )
        }
        for _ in 0..<100 where presenter.activeRequest == nil {
            await Task.yield()
        }
        XCTAssertNotNil(presenter.activeRequest)

        let second = await coordinator.run(
            present: {
                XCTFail("A concurrent confirmation must not be presented")
                return .dismissed
            },
            isVPNConfirmedDisconnected: { false },
            disconnectVPN: { ownerEvents.append("secondDisconnect") },
            confirmVPNDisconnected: { true },
            signOut: { ownerEvents.append("secondSignOut") },
            reportVPNDisconnectFailure: { ownerEvents.append("secondReport") }
        )

        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .signOutRequested)
        XCTAssertEqual(ownerEvents, ["disconnect", "confirmedDisconnected", "signOut"])
    }

    func testProfileSignOutVPNDisconnectFailureCopyIsLocalized() {
        XCTAssertEqual(
            AppLocalization.string(
                "profile.sign_out.vpn_disconnect_failed",
                locale: Locale(identifier: "zh-Hans")
            ),
            "VPN 未能安全断开，请稍后重试退出登录"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "profile.sign_out.vpn_disconnect_failed",
                locale: Locale(identifier: "en")
            ),
            "The VPN could not be safely disconnected. Please try signing out again later."
        )
    }

    func testAnnouncementRequestUsesDedicatedSpecialContentKindAndTwoActions() throws {
        let request = GlobalModalRequest.announcement(
            title: .verbatim("Service notice"),
            detail: .verbatim("2026-09-26 23:10"),
            message: .verbatim("Long announcement content"),
            copyText: "Long announcement content"
        )

        XCTAssertEqual(request.kind, .announcement)
        XCTAssertEqual(request.title, .verbatim("Service notice"))
        XCTAssertEqual(request.detail, .verbatim("2026-09-26 23:10"))
        XCTAssertEqual(request.message, .verbatim("Long announcement content"))
        XCTAssertEqual(request.copyText, "Long announcement content")
        XCTAssertEqual(request.primary.title, .localized("home.notice.dismiss"))
        XCTAssertEqual(request.primary.role, .normal)
        let copyAction = try XCTUnwrap(request.secondary)
        XCTAssertEqual(copyAction.title, .localized("home.notice.copy_content"))
        XCTAssertEqual(copyAction.role, .tonal)
        XCTAssertEqual(copyAction.identifier, "global.modal.announcement.copy")
    }

    func testHomeNoticePresentationPreservesPlainTextAndUsesExistingFallbacks() throws {
        let notice = HomeNotice(
            id: 7,
            title: "Maintenance",
            content: "<p>Hello &amp; welcome</p>",
            imageURL: nil,
            tags: [],
            createdAt: 1
        )
        let request = HomeNoticePresentation.request(
            for: notice,
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )

        XCTAssertEqual(request.kind, .announcement)
        XCTAssertEqual(request.title, .verbatim("Maintenance"))
        XCTAssertEqual(request.detail, .verbatim("1970-01-01 00:00"))
        XCTAssertEqual(request.message, .verbatim("Hello & welcome"))
        XCTAssertEqual(request.copyText, "Hello & welcome")

        let fallback = HomeNoticePresentation.request(for: HomeNotice(
            id: 8,
            title: "",
            content: "",
            imageURL: nil,
            tags: [],
            createdAt: 0
        ))
        XCTAssertEqual(fallback.title, .localized(L10nKey.homeNoticeFallbackTitle))
        XCTAssertNil(fallback.detail)
        XCTAssertEqual(fallback.message, .localized("home.notice.empty_content"))
        XCTAssertEqual(fallback.copyText, "")
    }

    func testHomeNoticePopupTagRequiresExactTrimmedTag() {
        XCTAssertTrue(notice(id: 1, tags: ["弹窗"]).isPopup)
        XCTAssertTrue(notice(id: 2, tags: ["重要", "弹窗"]).isPopup)
        XCTAssertTrue(notice(id: 3, tags: [" 弹窗 "]).isPopup)
        XCTAssertFalse(notice(id: 4, tags: ["重要"]).isPopup)
        XCTAssertFalse(notice(id: 5, tags: ["弹窗公告"]).isPopup)
        XCTAssertFalse(notice(id: 6, tags: []).isPopup)
    }

    func testHomeNoticePopupQueueFiltersDeduplicatesAndSortsByIDDescending() {
        let queue = HomeNoticeAutoPresentation.popupQueue(from: [
            notice(id: 98, tags: ["弹窗"]),
            notice(id: 105, tags: ["弹窗"]),
            notice(id: 96, tags: ["重要"]),
            notice(id: 103, tags: ["重要", "弹窗"]),
            notice(id: 105, title: "duplicate", tags: ["弹窗"])
        ])

        XCTAssertEqual(queue.map(\.id), [105, 103, 98])
    }

    func testHomeNoticeAutomaticQueuePresentsSequentiallyAndSameRoundDoesNotRepeat() async throws {
        let presenter = GlobalModalPresenter()
        let coordinator = HomeNoticeAutoPresentationCoordinator()
        let generation = UUID()
        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        let notices = [
            notice(id: 98, tags: ["弹窗"]),
            notice(id: 105, tags: ["弹窗"]),
            notice(id: 96, tags: ["重要"]),
            notice(id: 103, tags: ["重要", "弹窗"])
        ]

        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: notices,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        try await waitForNotice(id: 105, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNotice(id: 103, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNotice(id: 98, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNoModal(presenter)

        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: notices,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        await Task.yield()
        XCTAssertNil(presenter.activeRequest)
        XCTAssertTrue(coordinator.pendingIDs.isEmpty)
    }

    func testHomeNoticeNewSuccessfulLoadRoundCanPresentSameTaggedNoticeAgain() async throws {
        let presenter = GlobalModalPresenter()
        let coordinator = HomeNoticeAutoPresentationCoordinator()
        let generation = UUID()
        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )

        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: [notice(id: 105, tags: ["弹窗"])],
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        try await waitForNotice(id: 105, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNoModal(presenter)

        coordinator.receiveSuccessfulLoad(
            revision: 2,
            notices: [notice(id: 105, tags: ["弹窗"])],
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        try await waitForNotice(id: 105, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNoModal(presenter)
    }

    func testHomeNoticeQueueWaitsForBusinessModalAndResumesWhenIdle() async throws {
        let presenter = GlobalModalPresenter()
        let coordinator = HomeNoticeAutoPresentationCoordinator()
        let generation = UUID()
        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        let businessRequest = GlobalModalRequest.information(message: .verbatim("Business"))
        let businessTask = Task { await presenter.present(businessRequest) }
        await Task.yield()

        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: [notice(id: 105, tags: ["弹窗"])],
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        await Task.yield()
        XCTAssertEqual(presenter.activeRequest, businessRequest)
        XCTAssertEqual(coordinator.pendingIDs, [105])

        XCTAssertTrue(presenter.resolve(.primary, requestID: businessRequest.id))
        _ = await businessTask.value
        coordinator.modalAvailabilityChanged(presenter: presenter)
        try await waitForNotice(id: 105, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNoModal(presenter)
    }

    func testHomeNoticeQueueWaitsUntilHomeVisibleAndAppActive() async throws {
        let presenter = GlobalModalPresenter()
        let coordinator = HomeNoticeAutoPresentationCoordinator()
        let generation = UUID()
        coordinator.updateAvailability(
            homeVisible: false,
            appActive: false,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: [notice(id: 105, tags: ["弹窗"])],
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        await Task.yield()
        XCTAssertNil(presenter.activeRequest)

        coordinator.updateAvailability(
            homeVisible: true,
            appActive: false,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        await Task.yield()
        XCTAssertNil(presenter.activeRequest)

        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        try await waitForNotice(id: 105, presenter: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNoModal(presenter)
    }

    func testManualNoticePresentationRemovesSameNoticeFromCurrentAutomaticRound() async throws {
        let presenter = GlobalModalPresenter()
        let coordinator = HomeNoticeAutoPresentationCoordinator()
        let generation = UUID()
        coordinator.updateAvailability(
            homeVisible: true,
            appActive: false,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        let popup = notice(id: 105, tags: ["弹窗"])
        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: [popup],
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )

        coordinator.presentManually(popup, timeZone: .current, presenter: presenter)
        try await waitForNotice(id: 105, presenter: presenter)
        XCTAssertTrue(coordinator.pendingIDs.isEmpty)
        XCTAssertTrue(presenter.resolve(.primary, requestID: presenter.activeRequest?.id))
        try await waitForNoModal(presenter)

        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: generation,
            presenter: presenter
        )
        await Task.yield()
        XCTAssertNil(presenter.activeRequest)
    }

    func testHomeNoticeQueueIsInvalidatedByGenerationChangeAndSignOut() async throws {
        let presenter = GlobalModalPresenter()
        let coordinator = HomeNoticeAutoPresentationCoordinator()
        let firstGeneration = UUID()
        coordinator.updateAvailability(
            homeVisible: true,
            appActive: false,
            accountScope: "fixture-account",
            generation: firstGeneration,
            presenter: presenter
        )
        coordinator.receiveSuccessfulLoad(
            revision: 1,
            notices: [notice(id: 105, tags: ["弹窗"])],
            accountScope: "fixture-account",
            generation: firstGeneration,
            presenter: presenter
        )
        XCTAssertEqual(coordinator.pendingIDs, [105])

        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: UUID(),
            presenter: presenter
        )
        await Task.yield()
        XCTAssertTrue(coordinator.pendingIDs.isEmpty)
        XCTAssertNil(presenter.activeRequest)

        let currentGeneration = UUID()
        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: "fixture-account",
            generation: currentGeneration,
            presenter: presenter
        )
        coordinator.receiveSuccessfulLoad(
            revision: 2,
            notices: [notice(id: 106, tags: ["弹窗"])],
            accountScope: "fixture-account",
            generation: currentGeneration,
            presenter: presenter
        )
        try await waitForNotice(id: 106, presenter: presenter)

        coordinator.updateAvailability(
            homeVisible: true,
            appActive: true,
            accountScope: nil,
            generation: nil,
            presenter: presenter
        )
        try await waitForNoModal(presenter)
        XCTAssertTrue(coordinator.pendingIDs.isEmpty)
        XCTAssertNil(presenter.activeRequest)
    }

    private func notice(
        id: Int,
        title: String? = nil,
        tags: [String]
    ) -> HomeNotice {
        HomeNotice(
            id: id,
            title: title ?? "Notice \(id)",
            content: "<p>Content \(id)</p>",
            imageURL: nil,
            tags: tags,
            createdAt: Int64(id)
        )
    }

    private func waitForNotice(
        id: Int,
        presenter: GlobalModalPresenter
    ) async throws {
        for _ in 0..<100 {
            if presenter.activeRequest?.title == .verbatim("Notice \(id)") { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected notice \(id) to be presented")
    }

    private func waitForNoModal(_ presenter: GlobalModalPresenter) async throws {
        for _ in 0..<100 {
            if presenter.activeRequest == nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected modal presenter to become idle")
    }

    func testProxyModeSelectionRequestDefaultsToCurrentModeAndHasOnlyTwoOptions() throws {
        let request = ProxyModeModalPresentation.request(currentMode: .global)

        XCTAssertEqual(request.kind, .selection)
        XCTAssertEqual(request.title, .localized(L10nKey.proxyModeDialogTitle))
        XCTAssertEqual(request.initialSelectionID, ProxyMode.global.rawValue)
        XCTAssertEqual(request.selectionOptions.map(\.id), [
            ProxyMode.rule.rawValue,
            ProxyMode.global.rawValue
        ])
        XCTAssertEqual(request.selectionOptions[0].title, .localized(L10nKey.proxyModeRule))
        XCTAssertEqual(
            request.selectionOptions[0].message,
            .localized(L10nKey.proxyModeDialogRuleDescription)
        )
        XCTAssertEqual(request.selectionOptions[1].title, .localized(L10nKey.proxyModeGlobal))
        XCTAssertEqual(
            request.selectionOptions[1].message,
            .localized(L10nKey.proxyModeDialogGlobalDescription)
        )
        XCTAssertEqual(request.primary.title, .localized(L10nKey.proxyModeDialogApply))
        let cancel = try XCTUnwrap(request.secondary)
        XCTAssertEqual(cancel.title, .localized(L10nKey.proxyModeDialogCancel))
        XCTAssertEqual(cancel.role, .cancel)
        XCTAssertEqual(request.selectionBehavior, .confirm)
        XCTAssertFalse(request.allowsBackdropDismiss)
    }

    @MainActor
    func testImmediateSelectionReturnsChoiceWithoutChangingPresenterSemantics() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.immediateSelection(
            title: .localized("语言"),
            options: [
                GlobalModalSelectionOption(id: "zh-Hans", title: .localized("简体中文")),
                GlobalModalSelectionOption(id: "en", title: .localized("English")),
            ],
            initialSelectionID: "zh-Hans"
        )

        let task = Task { await presenter.present(request) }
        await Task.yield()
        XCTAssertEqual(presenter.activeRequest?.selectionBehavior, .immediate)
        XCTAssertEqual(presenter.activeRequest?.allowsBackdropDismiss, false)
        XCTAssertNil(presenter.activeRequest?.secondary)
        XCTAssertTrue(presenter.resolve(.selection("en"), requestID: request.id))
        let choice = await task.value
        XCTAssertEqual(choice, .selection("en"))
        XCTAssertNil(presenter.activeRequest)
    }

    func testBackdropDismissDefaultsOffForExistingModalKinds() {
        let requests: [GlobalModalRequest] = [
            .information(message: .verbatim("Info")),
            .confirmation(message: .verbatim("Confirm"), primaryTitle: .verbatim("OK")),
            .destructive(message: .verbatim("Delete"), primaryTitle: .verbatim("Delete")),
            .result(style: .success, message: .verbatim("Done")),
            .announcement(title: .verbatim("Notice"), message: .verbatim("Body"), copyText: "Body"),
        ]

        XCTAssertTrue(requests.allSatisfy { !$0.allowsBackdropDismiss })
    }

    func testBackdropDismissRequiresOptInAndTapOutsideMeasuredCard() {
        let frame = CGRect(x: 24, y: 200, width: 345, height: 260)

        XCTAssertTrue(GlobalModalBackdropDismissal.shouldDismiss(
            allowsBackdropDismiss: true,
            modalFrame: frame,
            tapLocation: CGPoint(x: 10, y: 300)
        ))
        XCTAssertFalse(GlobalModalBackdropDismissal.shouldDismiss(
            allowsBackdropDismiss: true,
            modalFrame: frame,
            tapLocation: CGPoint(x: 100, y: 300)
        ))
        XCTAssertFalse(GlobalModalBackdropDismissal.shouldDismiss(
            allowsBackdropDismiss: false,
            modalFrame: frame,
            tapLocation: CGPoint(x: 10, y: 300)
        ))
        XCTAssertFalse(GlobalModalBackdropDismissal.shouldDismiss(
            allowsBackdropDismiss: true,
            modalFrame: .zero,
            tapLocation: CGPoint(x: 10, y: 300)
        ))
    }

    func testProxyModeSelectionOnlyChangesPendingSelection() {
        let request = ProxyModeModalPresentation.request(currentMode: .rule)
        var selection = GlobalModalSelectionState(
            options: request.selectionOptions,
            initialSelectionID: request.initialSelectionID
        )

        XCTAssertEqual(selection.pendingID, ProxyMode.rule.rawValue)
        selection.select(ProxyMode.global.rawValue)
        XCTAssertEqual(selection.pendingID, ProxyMode.global.rawValue)
        XCTAssertEqual(request.initialSelectionID, ProxyMode.rule.rawValue)

        selection.select("tun")
        XCTAssertEqual(selection.pendingID, ProxyMode.global.rawValue)
    }

    func testProxyModeCancelProducesNoSelectedMode() {
        XCTAssertNil(ProxyModeModalPresentation.selectedMode(for: .secondary))
        XCTAssertNil(ProxyModeModalPresentation.selectedMode(for: .dismissed))
        XCTAssertNil(ProxyModeModalPresentation.selectedMode(for: .primary))
    }

    func testProxyModeApplySameModeDoesNotSwitchOrUpdate() async {
        var switchCount = 0

        let result = await ProxyModeModalPresentation.appliedMode(
            selectedMode: .rule,
            currentMode: .rule,
            isConnected: true,
            switchMode: { _ in
                switchCount += 1
                return true
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(switchCount, 0)
    }

    func testProxyModeDisconnectedApplyUpdatesWithoutSwitch() async {
        var switchCount = 0

        let result = await ProxyModeModalPresentation.appliedMode(
            selectedMode: .global,
            currentMode: .rule,
            isConnected: false,
            switchMode: { _ in
                switchCount += 1
                return true
            }
        )

        XCTAssertEqual(result, .global)
        XCTAssertEqual(switchCount, 0)
    }

    func testProxyModeConnectedApplyUsesSwitchOnceAndUpdatesOnlyOnSuccess() async {
        var switchedModes: [ProxyMode] = []

        let result = await ProxyModeModalPresentation.appliedMode(
            selectedMode: .global,
            currentMode: .rule,
            isConnected: true,
            switchMode: { mode in
                switchedModes.append(mode)
                return true
            }
        )

        XCTAssertEqual(result, .global)
        XCTAssertEqual(switchedModes, [.global])
    }

    func testProxyModeFailedSwitchDoesNotUpdateMode() async {
        let result = await ProxyModeModalPresentation.appliedMode(
            selectedMode: .global,
            currentMode: .rule,
            isConnected: true,
            switchMode: { _ in false }
        )

        XCTAssertNil(result)
    }

    func testProxyModeCancellationDoesNotUpdateMode() async {
        let result = await ProxyModeModalPresentation.appliedMode(
            selectedMode: .global,
            currentMode: .rule,
            isConnected: true,
            switchMode: { _ in throw CancellationError() }
        )

        XCTAssertNil(result)
    }

    func testProxyModeSelectionChoiceReturnsPendingMode() async {
        let presenter = GlobalModalPresenter()
        let request = ProxyModeModalPresentation.request(currentMode: .rule)
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertTrue(presenter.resolve(
            .selection(ProxyMode.global.rawValue),
            requestID: request.id
        ))
        let choice = await result.value
        XCTAssertEqual(
            ProxyModeModalPresentation.selectedMode(for: choice),
            .global
        )
    }

    func testPurchaseOrderRequestContainsPlanPeriodPriceAndActions() throws {
        let plan = PurchasePlan(
            id: 7,
            name: "Fixture Plan",
            content: "",
            sort: 1,
            cycles: [],
            features: []
        )
        let cycle = PurchasePlanCycle(period: .month, priceCents: 1_288)
        let request = PurchaseOrderModalPresentation.request(
            plan: plan,
            cycle: cycle,
            locale: Locale(identifier: "zh_CN")
        )

        XCTAssertEqual(request.kind, .purchaseOrder)
        XCTAssertEqual(request.title, .localized("purchase.payment.confirm_title"))
        XCTAssertEqual(request.purchaseOrderContent?.planName, "Fixture Plan")
        XCTAssertEqual(request.purchaseOrderContent?.period, .localized("purchase.period.month"))
        XCTAssertEqual(request.purchaseOrderContent?.price, "¥12.88")
        XCTAssertEqual(request.primary.title, .localized("purchase.payment.create_order"))
        XCTAssertEqual(request.primary.role, .normal)
        let cancel = try XCTUnwrap(request.secondary)
        XCTAssertEqual(cancel.title, .localized("purchase.payment.cancel"))
        XCTAssertEqual(cancel.role, .cancel)
    }

    func testPurchaseCouponEmptyCodeCanSubmitNil() {
        let state = GlobalModalCouponInputState()

        XCTAssertTrue(state.canSubmit)
        XCTAssertNil(state.submittedCode)
    }

    func testPurchaseCouponMustValidateBeforeSubmission() {
        var state = GlobalModalCouponInputState()
        state.updateText(" SAVE20 ")

        XCTAssertFalse(state.canSubmit)
        XCTAssertNil(state.submittedCode)
        XCTAssertEqual(state.beginValidation(), "SAVE20")
        XCTAssertFalse(state.canSubmit)

        state.finishValidation(
            code: "SAVE20",
            result: .couponAvailable(name: "Fixture Coupon")
        )
        XCTAssertTrue(state.canSubmit)
        XCTAssertEqual(state.submittedCode, "SAVE20")
        XCTAssertEqual(
            state.validation,
            .available(code: "SAVE20", name: "Fixture Coupon")
        )
    }

    func testPurchaseCouponFailureDoesNotPermitCreation() {
        var state = GlobalModalCouponInputState()
        state.updateText("EXPIRED")
        let code = state.beginValidation()
        state.finishValidation(
            code: code!,
            result: .couponUnavailable(.verbatim("Coupon expired"))
        )

        XCTAssertFalse(state.canSubmit)
        XCTAssertNil(state.submittedCode)
        XCTAssertEqual(
            state.validation,
            .unavailable(code: "EXPIRED", message: .verbatim("Coupon expired"))
        )
    }

    func testPurchaseCouponEditInvalidatesPriorValidation() {
        var state = GlobalModalCouponInputState()
        state.updateText("SAVE20")
        _ = state.beginValidation()
        state.finishValidation(
            code: "SAVE20",
            result: .couponAvailable(name: "Fixture Coupon")
        )
        XCTAssertTrue(state.canSubmit)

        state.updateText("SAVE30")

        XCTAssertEqual(state.validation, .idle)
        XCTAssertFalse(state.canSubmit)
        XCTAssertNil(state.submittedCode)
    }

    func testPurchaseOrderCancelDoesNotCreateAndCreateChoiceRunsOnce() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.purchaseOrder(
            planName: "Fixture",
            period: .localized("purchase.period.month"),
            price: "¥1.00"
        )
        var submissions: [PurchaseOrderModalSubmission] = []
        let cancelled = Task { await presenter.present(request) }
        await Task.yield()
        XCTAssertTrue(presenter.resolve(.secondary, requestID: request.id))
        if let submission = PurchaseOrderModalPresentation.submission(
            for: await cancelled.value
        ) {
            submissions.append(submission)
        }
        XCTAssertTrue(submissions.isEmpty)

        let createRequest = GlobalModalRequest.purchaseOrder(
            planName: "Fixture",
            period: .localized("purchase.period.month"),
            price: "¥1.00"
        )
        let created = Task { await presenter.present(createRequest) }
        await Task.yield()
        XCTAssertTrue(presenter.resolve(
            .purchaseOrder(couponCode: "SAVE20"),
            requestID: createRequest.id
        ))
        XCTAssertFalse(presenter.resolve(
            .purchaseOrder(couponCode: "SAVE20"),
            requestID: createRequest.id
        ))
        if let submission = PurchaseOrderModalPresentation.submission(
            for: await created.value
        ) {
            submissions.append(submission)
        }

        XCTAssertEqual(submissions, [PurchaseOrderModalSubmission(couponCode: "SAVE20")])
    }

    func testPurchaseCouponInteractionStaysOwnedByPresenterCaller() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.purchaseOrder(
            planName: "Fixture",
            period: .localized("purchase.period.month"),
            price: "¥1.00"
        )
        var validatedCodes: [String] = []
        let presentation = Task {
            await presenter.present(request) { interaction in
                guard case let .validatePurchaseCoupon(code) = interaction else {
                    return .cancelled
                }
                validatedCodes.append(code)
                return .couponAvailable(name: "Fixture Coupon")
            }
        }
        await Task.yield()

        let result = await presenter.perform(
            .validatePurchaseCoupon("SAVE20"),
            requestID: request.id
        )

        XCTAssertEqual(result, .couponAvailable(name: "Fixture Coupon"))
        XCTAssertEqual(validatedCodes, ["SAVE20"])
        XCTAssertTrue(presenter.resolve(.secondary, requestID: request.id))
        _ = await presentation.value
    }

    func testPaymentSummaryHidesZeroAdjustmentsAndShowsNonZeroServerFields() throws {
        let zero = paymentDetail()
        let zeroRows = PaymentMethodModalPresentation.summaryRows(
            detail: zero,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(zeroRows.map(\.id), ["plan", "period", "plan-price"])

        let adjusted = paymentDetail(
            discount: 100,
            surplus: 200,
            balance: 300,
            refund: 400
        )
        let adjustedRows = PaymentMethodModalPresentation.summaryRows(
            detail: adjusted,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(
            adjustedRows.map(\.id),
            ["plan", "period", "plan-price", "discount", "surplus", "balance", "refund"]
        )
        XCTAssertTrue(try XCTUnwrap(adjustedRows.first { $0.id == "discount" }).value.hasPrefix("−"))
        XCTAssertTrue(try XCTUnwrap(adjustedRows.first { $0.id == "refund" }).value.hasPrefix("+"))
    }

    func testPaymentMethodsExposeIconFeeAvailabilityAndExactAmountDue() throws {
        let methods = [
            PurchasePaymentMethod(
                id: 1,
                name: "Card",
                payment: "StripeCredit",
                iconURL: URL(string: "https://example.invalid/card.png"),
                handlingFeeFixedCents: 0,
                handlingFeePercent: 0
            ),
            PurchasePaymentMethod(
                id: 2,
                name: "Fixture Pay",
                payment: "EPay",
                iconURL: URL(string: "https://example.invalid/pay.png"),
                handlingFeeFixedCents: 50,
                handlingFeePercent: 1.5
            )
        ]
        let detail = paymentDetail(total: 10_000)
        let request = PaymentMethodModalPresentation.request(
            detail: detail,
            methods: methods,
            locale: Locale(identifier: "en_US")
        )
        let content = try XCTUnwrap(request.paymentMethodContent)
        let card = try XCTUnwrap(content.methods.first { $0.id == 1 })
        let fixture = try XCTUnwrap(content.methods.first { $0.id == 2 })

        XCTAssertEqual(request.kind, .paymentMethod)
        XCTAssertEqual(request.title, .localized("purchase.payment.checkout_title"))
        XCTAssertFalse(card.isEnabled)
        XCTAssertEqual(card.disabledReason, .localized("purchase.payment.unsupported"))
        XCTAssertEqual(card.iconURL, methods[0].iconURL)
        XCTAssertTrue(fixture.isEnabled)
        XCTAssertNotNil(fixture.feeDescription)
        XCTAssertEqual(fixture.handlingAmount, "+\(CommerceView.price(200, locale: Locale(identifier: "en_US")))")
        XCTAssertEqual(fixture.amountDue, CommerceView.price(10_200, locale: Locale(identifier: "en_US")))
        XCTAssertEqual(methods[1].handlingAmountCents(for: 10_000), 200)
    }

    func testPaymentMethodStateDefaultsToFirstSupportedAndOnlyChangesPendingSelection() {
        let disabled = GlobalModalPaymentMethodOption(
            id: 1, name: "Disabled", iconURL: nil, feeDescription: nil,
            handlingAmount: nil, amountDue: "--", isEnabled: false,
            disabledReason: .localized("purchase.payment.unsupported")
        )
        let first = GlobalModalPaymentMethodOption(
            id: 2, name: "First", iconURL: nil, feeDescription: nil,
            handlingAmount: nil, amountDue: "¥10.00", isEnabled: true,
            disabledReason: nil
        )
        let second = GlobalModalPaymentMethodOption(
            id: 3, name: "Second", iconURL: nil, feeDescription: nil,
            handlingAmount: nil, amountDue: "¥10.00", isEnabled: true,
            disabledReason: nil
        )
        var state = GlobalModalPaymentMethodState(methods: [disabled, first, second])
        var checkoutCount = 0

        XCTAssertEqual(state.pendingMethodID, 2)
        state.select(1)
        XCTAssertEqual(state.pendingMethodID, 2)
        state.select(3)
        XCTAssertEqual(state.pendingMethodID, 3)
        XCTAssertEqual(checkoutCount, 0, "Selection is presentation state only")
        if state.pendingMethodID == nil { checkoutCount += 1 }
        XCTAssertEqual(checkoutCount, 0)
    }

    func testPaymentCancelDoesNotCheckoutAndSubmitChoiceRunsOwnerOnce() async {
        let option = GlobalModalPaymentMethodOption(
            id: 7, name: "Fixture Pay", iconURL: nil, feeDescription: nil,
            handlingAmount: nil, amountDue: "¥10.00", isEnabled: true,
            disabledReason: nil
        )
        let presenter = GlobalModalPresenter()
        var submittedMethods: [Int] = []

        let cancelledRequest = GlobalModalRequest.paymentMethod(
            tradeNo: "trade", summaryRows: [], methods: [option], baseAmountDue: "¥10.00"
        )
        let cancelled = Task { await presenter.present(cancelledRequest) }
        await Task.yield()
        XCTAssertTrue(presenter.resolve(.secondary, requestID: cancelledRequest.id))
        if let method = PaymentMethodModalPresentation.selectedMethodID(for: await cancelled.value) {
            submittedMethods.append(method)
        }
        XCTAssertTrue(submittedMethods.isEmpty)

        let submitRequest = GlobalModalRequest.paymentMethod(
            tradeNo: "trade", summaryRows: [], methods: [option], baseAmountDue: "¥10.00"
        )
        let submitted = Task { await presenter.present(submitRequest) }
        await Task.yield()
        XCTAssertTrue(presenter.resolve(.paymentMethod(7), requestID: submitRequest.id))
        XCTAssertFalse(presenter.resolve(.paymentMethod(7), requestID: submitRequest.id))
        if let method = PaymentMethodModalPresentation.selectedMethodID(for: await submitted.value) {
            submittedMethods.append(method)
        }
        XCTAssertEqual(submittedMethods, [7])
    }

    func testPaymentCloseButtonKeepsVisualSizeAndMeetsMinimumHitTarget() {
        XCTAssertEqual(GlobalModalPaymentCloseButtonMetrics.symbolSize, 14)
        XCTAssertEqual(GlobalModalPaymentCloseButtonMetrics.visualFrameSize, 32)
        XCTAssertEqual(GlobalModalPaymentCloseButtonMetrics.headerHeight, 32)
        XCTAssertEqual(GlobalModalPaymentCloseButtonMetrics.titleSpacing, 12)
        XCTAssertGreaterThanOrEqual(
            GlobalModalPaymentCloseButtonMetrics.minimumHitTargetSize,
            44
        )
    }

    func testPaymentCloseRemainsDismissedWithoutChangingBackdropPolicy() async {
        let option = GlobalModalPaymentMethodOption(
            id: 7, name: "Fixture Pay", iconURL: nil, feeDescription: nil,
            handlingAmount: nil, amountDue: "¥10.00", isEnabled: true,
            disabledReason: nil
        )
        let requests = [
            GlobalModalRequest.paymentMethod(
                tradeNo: "trade", summaryRows: [], methods: [option],
                baseAmountDue: "¥10.00"
            ),
            GlobalModalRequest.paymentStatus(
                id: UUID(), tradeNo: "trade", summaryRows: [],
                amountDue: "¥10.00", status: .pending
            ),
        ]

        for request in requests {
            XCTAssertFalse(request.allowsBackdropDismiss)
            let presenter = GlobalModalPresenter()
            let result = Task { await presenter.present(request) }
            await Task.yield()

            XCTAssertTrue(presenter.resolve(.dismissed, requestID: request.id))
            let choice = await result.value
            XCTAssertEqual(choice, .dismissed)
            XCTAssertNil(presenter.activeRequest)
        }
    }

    func testPaymentMethodTitleUsesOrderConfirmationWording() {
        XCTAssertEqual(
            AppLocalization.string(
                "purchase.payment.checkout_title",
                locale: Locale(identifier: "zh-Hans")
            ),
            "确认订单"
        )
        XCTAssertEqual(
            AppLocalization.string(
                "purchase.payment.checkout_title",
                locale: Locale(identifier: "en")
            ),
            "Confirm Order"
        )
    }

    func testPaymentStatusRequestUsesPureSummaryAndExpectedActions() throws {
        let request = PaymentStatusModalPresentation.request(
            id: UUID(),
            detail: paymentDetail(total: 1_000),
            status: .pending,
            feedback: nil,
            locale: Locale(identifier: "zh_CN")
        )
        let content = try XCTUnwrap(request.paymentStatusContent)

        XCTAssertEqual(request.kind, .paymentStatus)
        XCTAssertEqual(request.title, .localized("purchase.payment.status_title"))
        XCTAssertEqual(request.primary.title, .localized("purchase.payment.paid"))
        XCTAssertEqual(request.secondary?.title, .localized("purchase.payment.cancel_order"))
        XCTAssertEqual(content.tradeNo, "fixture-trade")
        XCTAssertEqual(content.summaryRows.map(\.id), [
            "plan", "period", "plan-price", "order-amount"
        ])
        XCTAssertEqual(content.status, .pending)
    }

    func testTerminalPaymentStatusHasOnlyCloseAction() {
        let request = PaymentStatusModalPresentation.request(
            id: UUID(),
            detail: paymentDetail(),
            status: .completed,
            feedback: nil,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(request.primary.title, .localized("purchase.payment.close"))
        XCTAssertNil(request.secondary)
        XCTAssertEqual(request.paymentStatusContent?.status, .completed)
    }

    func testOnlyPendingPaymentStatusOffersOrderCancellation() {
        let pending = PaymentStatusModalPresentation.request(
            id: UUID(),
            detail: paymentDetail(),
            status: .pending,
            feedback: nil,
            locale: Locale(identifier: "en_US")
        )
        let activating = PaymentStatusModalPresentation.request(
            id: UUID(),
            detail: paymentDetail(),
            status: .activating,
            feedback: nil,
            locale: Locale(identifier: "en_US")
        )
        let unknown = PaymentStatusModalPresentation.request(
            id: UUID(),
            detail: paymentDetail(),
            status: .unknown(99),
            feedback: nil,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(
            pending.secondary?.title,
            .localized("purchase.payment.cancel_order")
        )
        XCTAssertNil(activating.secondary)
        XCTAssertNil(unknown.secondary)
    }

    func testOrderCancellationRequestUsesDestructiveConfirmation() throws {
        let request = GlobalModalRequest.orderCancellation()

        XCTAssertEqual(request.kind, .destructive)
        XCTAssertEqual(request.title, .localized("profile.orders.cancel.title"))
        XCTAssertEqual(request.message, .localized("profile.orders.cancel.message"))
        XCTAssertEqual(request.primary.title, .localized("profile.orders.cancel.confirm"))
        XCTAssertEqual(request.primary.role, .destructive)
        XCTAssertEqual(request.secondary?.title, .localized("purchase.payment.cancel"))
        XCTAssertEqual(request.secondary?.role, .cancel)
    }

    func testPresenterCanUpdateActivePaymentStatusWithoutResolvingIt() async {
        let presenter = GlobalModalPresenter()
        let id = UUID()
        let pending = PaymentStatusModalPresentation.request(
            id: id,
            detail: paymentDetail(),
            status: .pending,
            feedback: nil,
            locale: Locale(identifier: "en_US")
        )
        let result = Task { await presenter.present(pending) }
        await Task.yield()

        let completed = PaymentStatusModalPresentation.request(
            id: id,
            detail: paymentDetail(),
            status: .completed,
            feedback: nil,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertTrue(presenter.update(completed, requestID: id))
        XCTAssertEqual(presenter.activeRequest?.paymentStatusContent?.status, .completed)
        XCTAssertTrue(presenter.resolve(.primary, requestID: id))
        let resolved = await result.value
        XCTAssertEqual(resolved, .primary)
    }

    func testPaymentPollingPolicyUsesBoundedForegroundSchedule() {
        let started = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(PaymentStatusPollingPolicy.delaySeconds(
            startedAt: started,
            now: started.addingTimeInterval(59)
        ), 3)
        XCTAssertEqual(PaymentStatusPollingPolicy.delaySeconds(
            startedAt: started,
            now: started.addingTimeInterval(60)
        ), 5)
        XCTAssertEqual(PaymentStatusPollingPolicy.delaySeconds(
            startedAt: started,
            now: started.addingTimeInterval(5 * 60)
        ), 10)
        XCTAssertNil(PaymentStatusPollingPolicy.delaySeconds(
            startedAt: started,
            now: started.addingTimeInterval(10 * 60)
        ))
    }

    func testUsageTermsConsentRequestUsesExistingConfirmationPresentation() {
        let request = GlobalModalRequest.usageTermsConsent()

        XCTAssertEqual(request.kind, .confirmation)
        XCTAssertEqual(request.title, .localized("consent.modal.title"))
        XCTAssertEqual(request.message, .localized("consent.modal.message"))
        XCTAssertEqual(request.primary.title, .localized("consent.action.agree"))
        XCTAssertEqual(request.primary.identifier, "unified.consent.agree")
        XCTAssertEqual(request.secondary?.title, .localized("consent.action.decline"))
        XCTAssertEqual(request.secondary?.role, .cancel)
        XCTAssertEqual(request.secondary?.identifier, "unified.consent.decline")
        XCTAssertFalse(request.allowsBackdropDismiss)
    }

    func testUsageTermsConsentDeclineDoesNotAcceptAndCanRetry() async throws {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = UsageTermsConsentCoordinator(defaults: defaults, arguments: [])
        let presenter = GlobalModalPresenter()

        let first = Task {
            await coordinator.authorize(presenter: presenter)
        }
        let firstRequest = try await requireActiveRequest(from: presenter)
        XCTAssertTrue(presenter.resolve(.secondary, requestID: firstRequest.id))
        let firstAccepted = await first.value
        XCTAssertFalse(firstAccepted)
        XCTAssertEqual(coordinator.acceptedVersion, 0)
        XCTAssertTrue(coordinator.requiresAcceptance)

        let retry = Task {
            await coordinator.authorize(presenter: presenter)
        }
        let retryRequest = try await requireActiveRequest(from: presenter)
        XCTAssertNotEqual(retryRequest.id, firstRequest.id)
        XCTAssertTrue(presenter.resolve(.dismissed, requestID: retryRequest.id))
        let retryAccepted = await retry.value
        XCTAssertFalse(retryAccepted)
        XCTAssertEqual(defaults.integer(forKey: UsageTermsConsentPolicy.acceptedVersionKey), 0)
    }

    func testUsageTermsConsentAgreePersistsVersionAndMakesLaterGatesSilent() async throws {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = UsageTermsConsentCoordinator(defaults: defaults, arguments: [])
        let presenter = GlobalModalPresenter()

        let first = Task {
            await coordinator.authorize(presenter: presenter)
        }
        let request = try await requireActiveRequest(from: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        XCTAssertEqual(coordinator.acceptedVersion, UsageTermsConsentPolicy.requiredVersion)
        XCTAssertEqual(
            defaults.integer(forKey: UsageTermsConsentPolicy.acceptedVersionKey),
            UsageTermsConsentPolicy.requiredVersion
        )
        XCTAssertFalse(coordinator.requiresAcceptance)
        XCTAssertTrue(coordinator.hasAcceptedCurrentVersion)

        let repeatAccepted = await coordinator.authorize(presenter: presenter)
        XCTAssertTrue(repeatAccepted)
        XCTAssertNil(presenter.activeRequest)
    }

    func testUsageTermsConsentVersionBumpRequiresFreshAgreement() async throws {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: UsageTermsConsentPolicy.acceptedVersionKey)
        let coordinator = UsageTermsConsentCoordinator(
            defaults: defaults,
            requiredVersion: 2,
            arguments: []
        )
        let presenter = GlobalModalPresenter()

        XCTAssertTrue(coordinator.requiresAcceptance)
        let task = Task {
            await coordinator.authorize(presenter: presenter)
        }
        let request = try await requireActiveRequest(from: presenter)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        let accepted = await task.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(coordinator.acceptedVersion, 2)
        XCTAssertEqual(defaults.integer(forKey: UsageTermsConsentPolicy.acceptedVersionKey), 2)
    }

    func testUsageTermsConsentIsSingleFlightAcrossConcurrentIntents() async throws {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = UsageTermsConsentCoordinator(defaults: defaults, arguments: [])
        let presenter = GlobalModalPresenter()

        let first = Task {
            await coordinator.authorize(presenter: presenter)
        }
        let request = try await requireActiveRequest(from: presenter)
        let overlapping = await coordinator.authorize(presenter: presenter)

        XCTAssertFalse(overlapping)
        XCTAssertEqual(presenter.activeRequest?.id, request.id)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        XCTAssertEqual(defaults.integer(forKey: UsageTermsConsentPolicy.acceptedVersionKey), 1)
    }

    func testUsageTermsConsentCancellationNeverAccepts() async throws {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = UsageTermsConsentCoordinator(defaults: defaults, arguments: [])
        let presenter = GlobalModalPresenter()

        let task = Task {
            await coordinator.authorize(presenter: presenter)
        }
        _ = try await requireActiveRequest(from: presenter)
        task.cancel()

        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertNil(presenter.activeRequest)
        XCTAssertEqual(coordinator.acceptedVersion, 0)
        XCTAssertTrue(coordinator.requiresAcceptance)
    }

    func testLegacyVPNDisclosureAcceptanceDoesNotUpgradeUnifiedConsent() async {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            99,
            forKey: UsageTermsConsentPolicy.legacyVPNDisclosureAcceptedVersionKey
        )
        let coordinator = UsageTermsConsentCoordinator(defaults: defaults, arguments: [])

        XCTAssertEqual(coordinator.acceptedVersion, 0)
        XCTAssertTrue(coordinator.requiresAcceptance)
        XCTAssertFalse(coordinator.hasAcceptedCurrentVersion)
    }

    func testExplicitCheckboxSelectionUsesUnifiedVersionAndCanBeRevoked() {
        let (defaults, suite) = makeConsentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = UsageTermsConsentCoordinator(defaults: defaults, arguments: [])

        XCTAssertFalse(coordinator.hasAcceptedCurrentVersion)
        coordinator.setAccepted(true)
        XCTAssertTrue(coordinator.hasAcceptedCurrentVersion)
        XCTAssertEqual(
            defaults.integer(forKey: UsageTermsConsentPolicy.acceptedVersionKey),
            UsageTermsConsentPolicy.requiredVersion
        )

        coordinator.setAccepted(false)
        XCTAssertFalse(coordinator.hasAcceptedCurrentVersion)
        XCTAssertNil(defaults.object(forKey: UsageTermsConsentPolicy.acceptedVersionKey))
    }

    func testAuthSubmissionDeclineDoesNotSubmit() async {
        let coordinator = AuthSubmissionCoordinator()
        var submissionCount = 0

        await coordinator.perform(
            authorize: { false },
            submit: { submissionCount += 1 }
        )

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testAuthSubmissionAgreeContinuesOnceAndRejectsOverlappingTap() async {
        let coordinator = AuthSubmissionCoordinator()
        let gate = AuthSubmissionAuthorizationGate()
        var submissionCount = 0

        let first = Task {
            await coordinator.perform(
                authorize: { await gate.authorize() },
                submit: { submissionCount += 1 }
            )
        }
        await gate.waitUntilEntered()
        await coordinator.perform(
            authorize: { true },
            submit: { submissionCount += 1 }
        )
        await gate.release()
        await first.value

        XCTAssertEqual(submissionCount, 1)
        XCTAssertFalse(coordinator.isRunning)
    }

    private func makeConsentDefaults() -> (UserDefaults, String) {
        let suite = "UsageTermsConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func requireActiveRequest(
        from presenter: GlobalModalPresenter
    ) async throws -> GlobalModalRequest {
        for _ in 0..<100 {
            if let request = presenter.activeRequest { return request }
            await Task.yield()
        }
        return try XCTUnwrap(presenter.activeRequest)
    }

    private func paymentDetail(
        total: Int64 = 1_000,
        discount: Int64 = 0,
        surplus: Int64 = 0,
        balance: Int64 = 0,
        refund: Int64 = 0
    ) -> PurchaseOrderDetail {
        PurchaseOrderDetail(
            tradeNo: "fixture-trade",
            status: 0,
            checkoutType: nil,
            planID: 1,
            planName: "Fixture Plan",
            period: "month_price",
            planPriceCents: 1_500,
            totalAmountCents: total,
            discountAmountCents: discount,
            surplusAmountCents: surplus,
            balanceAmountCents: balance,
            refundAmountCents: refund,
            handlingAmountCents: 0
        )
    }

    func testPresenterStartsIdle() {
        XCTAssertNil(GlobalModalPresenter().activeRequest)
    }

    func testPresentPublishesRequestAndPrimaryCompletesOnce() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.information(message: .verbatim("One"))
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertEqual(presenter.activeRequest, request)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        XCTAssertFalse(presenter.resolve(.secondary, requestID: request.id))
        let choice = await result.value
        XCTAssertEqual(choice, .primary)
        XCTAssertNil(presenter.activeRequest)
    }

    func testSecondaryReturnsChoiceAndClearsActiveRequest() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.confirmation(
            message: .verbatim("Continue?"),
            primaryTitle: .verbatim("Continue")
        )
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertTrue(presenter.resolve(.secondary, requestID: request.id))
        let choice = await result.value
        XCTAssertEqual(choice, .secondary)
        XCTAssertNil(presenter.activeRequest)
    }

    func testDismissReturnsChoiceAndClearsActiveRequest() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.information(message: .verbatim("Dismiss"))
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertTrue(presenter.resolve(.dismissed, requestID: request.id))
        let choice = await result.value
        XCTAssertEqual(choice, .dismissed)
        XCTAssertNil(presenter.activeRequest)
    }

    func testSecondRequestDoesNotReplaceActiveRequest() async {
        let presenter = GlobalModalPresenter()
        let first = GlobalModalRequest.information(message: .verbatim("First"))
        let second = GlobalModalRequest.information(message: .verbatim("Second"))
        let firstResult = Task { await presenter.present(first) }
        await Task.yield()

        let secondChoice = await presenter.present(second)
        XCTAssertEqual(secondChoice, .alreadyPresenting)
        XCTAssertEqual(presenter.activeRequest, first)
        XCTAssertTrue(presenter.resolve(.primary, requestID: first.id))
        let firstChoice = await firstResult.value
        XCTAssertEqual(firstChoice, .primary)
    }

    func testDuplicateRequestDoesNotCreateSecondPresentation() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.information(message: .verbatim("Duplicate"))
        let firstResult = Task { await presenter.present(request) }
        await Task.yield()

        let duplicateChoice = await presenter.present(request)
        XCTAssertEqual(duplicateChoice, .alreadyPresenting)
        XCTAssertEqual(presenter.activeRequest?.id, request.id)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        let firstChoice = await firstResult.value
        XCTAssertEqual(firstChoice, .primary)
    }

    func testMismatchedRequestCannotResolveActivePresentation() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.information(message: .verbatim("Current"))
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertFalse(presenter.resolve(.primary, requestID: UUID()))
        XCTAssertEqual(presenter.activeRequest, request)
        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        let choice = await result.value
        XCTAssertEqual(choice, .primary)
    }

    func testCancellationDismissesOnceAndClearsActiveRequest() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.information(message: .verbatim("Cancel"))
        let result = Task { await presenter.present(request) }
        await Task.yield()

        result.cancel()

        let choice = await result.value
        XCTAssertEqual(choice, .dismissed)
        XCTAssertNil(presenter.activeRequest)
        XCTAssertFalse(presenter.resolve(.primary, requestID: request.id))
    }

    func testAlreadyCancelledTaskDoesNotPublishRequest() async {
        let presenter = GlobalModalPresenter()
        let request = GlobalModalRequest.information(message: .verbatim("Cancelled"))
        let result = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await presenter.present(request)
        }

        let choice = await result.value
        XCTAssertEqual(choice, .dismissed)
        XCTAssertNil(presenter.activeRequest)
    }
}
