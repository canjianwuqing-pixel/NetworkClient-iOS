import CoreFoundation
import Foundation

enum V2BoardRequestContext: Sendable, Equatable {
    case login
    case authenticated
}

enum V2BoardAPIResponsePolicy: Sendable, Equatable {
    case standard
    case couponCheck
    case invitation
    case orderCreation
    case changePassword
    case authBusiness(V2BoardAuthEndpoint)
}

enum V2BoardAPIErrorParser {
    static func decodeResponse(
        data: Data,
        statusCode: Int,
        contentType: String?,
        context: V2BoardRequestContext,
        responsePolicy: V2BoardAPIResponsePolicy = .standard
    ) throws -> [String: Any] {
        let root = decodeJSONObject(data)
        // V2Board may append Laravel debug metadata to an otherwise explicit
        // invitation rejection. Invitation endpoints use only the safe
        // top-level business message; debug siblings are never surfaced and a
        // boolean data=false is never misread as the string "0".
        let message = responsePolicy == .invitation
            ? root.flatMap(extractSafeTopLevelBusinessMessage)
            : root.flatMap(extractSafeBusinessMessage)

        guard (200...299).contains(statusCode) else {
            if statusCode == 429 {
                if let endpoint = responsePolicy.authEndpoint, let message {
                    throw NetworkClientError.authBusinessRejected(
                        endpoint: endpoint,
                        message: message
                    )
                }
                throw NetworkClientError.rateLimited
            }
            if context == .authenticated, statusCode == 401 {
                throw NetworkClientError.authenticationExpired(L10nKey.errorAuthenticationExpired)
            }
            // The deployed invite/save path can be translated by an upstream
            // proxy to 502 while retaining V2Board's JSON business message and
            // mislabelling its Content-Type. For invitation rejections only,
            // accept that response when the body itself is valid JSON and its
            // top-level message passes the existing safety filter. HTML,
            // malformed JSON, unsafe messages, and every other endpoint still
            // require the normal JSON Content-Type contract.
            let hasSafeInvitationBusinessPayload = responsePolicy == .invitation
                && root != nil
                && message != nil
            guard isExpectedJSONContentType(contentType) || hasSafeInvitationBusinessPayload,
                  let root else {
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试",
                    retryable: statusCode >= 500
                )
            }
            if let message,
               context == .authenticated,
               isAuthenticationExpired(message) {
                throw NetworkClientError.authenticationExpired(message)
            }
            if responsePolicy == .orderCreation, let message {
                throw NetworkClientError.orderCreationRejected(message)
            }
            if responsePolicy == .changePassword,
               statusCode != 401,
               let message {
                throw NetworkClientError.changePasswordRejected(message)
            }
            if responsePolicy == .invitation,
               statusCode != 401,
               let message {
                throw NetworkClientError.invitationRejected(message)
            }
            if let endpoint = responsePolicy.authEndpoint,
               statusCode != 401,
               let message {
                throw NetworkClientError.authBusinessRejected(
                    endpoint: endpoint,
                    message: message
                )
            }
            // A 5xx JSON message alone may be a proxy/framework error. Standard
            // requests remain conservative. Narrow endpoint policies opt in to
            // their endpoint's safe business message only.
            if statusCode >= 500,
               !isBusinessFailure(root),
               !([.couponCheck, .invitation].contains(responsePolicy) && message != nil) {
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试", retryable: true
                )
            }
            guard let message else {
                if statusCode < 500 { throw NetworkClientError.backendBusinessError("") }
                throw NetworkClientError.serviceUnavailable(
                    "服务暂时不可用，请稍后重试", retryable: true
                )
            }
            throw classifyHTTPError(
                statusCode: statusCode,
                message: message,
                context: context
            )
        }

        guard let root else {
            throw NetworkClientError.responseInvalid("无效的 API 响应")
        }

        guard isExpectedJSONContentType(contentType) else {
            throw NetworkClientError.responseInvalid("无效的 API 响应")
        }

        if isBusinessFailure(root) {
            if let message {
                if responsePolicy == .orderCreation {
                    throw NetworkClientError.orderCreationRejected(message)
                }
                if responsePolicy == .changePassword {
                    throw NetworkClientError.changePasswordRejected(message)
                }
                if responsePolicy == .invitation {
                    throw NetworkClientError.invitationRejected(message)
                }
                if let endpoint = responsePolicy.authEndpoint {
                    throw NetworkClientError.authBusinessRejected(
                        endpoint: endpoint,
                        message: message
                    )
                }
                throw classifyBusinessMessage(message, context: context)
            }
            throw NetworkClientError.backendBusinessError("")
        }
        return root
    }

    private static func classifyHTTPError(
        statusCode: Int,
        message: String?,
        context: V2BoardRequestContext
    ) -> NetworkClientError {
        if let message {
            if context == .authenticated, isAuthenticationExpired(message) {
                return .authenticationExpired(message)
            }
            return classifyBusinessMessage(message, context: context)
        }

        if context == .authenticated, statusCode == 401 {
            return .authenticationExpired(L10nKey.errorAuthenticationExpired)
        }

        return .serviceUnavailable(
            "服务暂时不可用，请稍后重试",
            retryable: true
        )
    }

    private static func classifyBusinessMessage(
        _ message: String,
        context: V2BoardRequestContext
    ) -> NetworkClientError {
        if context == .authenticated, isAuthenticationExpired(message) {
            return .authenticationExpired(message)
        }
        // The desktop client has already confirmed these exact response texts.
        if message == "the old password is wrong" || message == "旧密码有误" {
            return .validation("profile.change_password.error.current_incorrect")
        }
        return .backendBusinessError(message)
    }

    private static func decodeJSONObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }
        return root
    }

    private static func isExpectedJSONContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let mediaType = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json"
    }

    private static func extractSafeBusinessMessage(from root: [String: Any]) -> String? {
        guard !containsDebugDetails(root) else { return nil }

        if let errors = firstText(root["errors"])?.safeV2BoardBusinessMessage {
            return errors
        }
        if let data = root["data"] as? [String: Any] {
            for key in ["message", "msg", "error"] {
                if let value = string(data[key])?.safeV2BoardBusinessMessage {
                    return value
                }
            }
        }
        for key in ["message", "msg", "error"] {
            if let value = string(root[key])?.safeV2BoardBusinessMessage {
                return value
            }
        }
        return string(root["data"])?.safeV2BoardBusinessMessage
    }

    private static func extractSafeTopLevelBusinessMessage(
        from root: [String: Any]
    ) -> String? {
        string(root["message"])?.safeV2BoardBusinessMessage
    }

    private static func containsDebugDetails(_ value: Any) -> Bool {
        switch value {
        case let object as [String: Any]:
            let unsafeKeys = Set([
                "debug", "exception", "file", "line", "trace", "stack", "stacktrace"
            ])
            if object.keys.contains(where: { unsafeKeys.contains($0.lowercased()) }) {
                return true
            }
            return object.values.contains(where: containsDebugDetails)
        case let array as [Any]:
            return array.contains(where: containsDebugDetails)
        default:
            return false
        }
    }

    private static func firstText(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            text
        case let number as NSNumber:
            number.stringValue
        case let array as [Any]:
            array.lazy.compactMap(firstText).first
        case let object as [String: Any]:
            object.values.lazy.compactMap(firstText).first
        default:
            nil
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

    private static func isBusinessFailure(_ root: [String: Any]) -> Bool {
        if let success = jsonBoolean(root["success"]), !success { return true }
        if let data = jsonBoolean(root["data"]), !data { return true }
        if let code = int(root["code"]), code != 0 && code != 200 { return true }
        if let status = jsonBoolean(root["status"]), !status { return true }
        if let status = string(root["status"])?.lowercased(),
           ["fail", "failed", "error", "false"].contains(status) {
            return true
        }
        return false
    }

    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func isAuthenticationExpired(_ message: String) -> Bool {
        let value = message.lowercased()
        return [
            "未登录或登陆已过期",
            "未登录或登录已过期",
            "登录状态已失效",
            "login has expired",
            "authentication expired",
            "unauthenticated"
        ].contains { value.contains($0.lowercased()) }
    }

}

private extension String {
    var safeV2BoardBusinessMessage: String? {
        let normalized = replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmed
        guard !normalized.isEmpty, normalized.count <= 240 else { return nil }

        let lower = normalized.lowercased()
        let unsafeFragments = [
            "<html", "<!doctype", "http://", "https://", "http ", "/api/", "api endpoint",
            "nsurlerrordomain", "urlsession", "transport failure", "stack trace", "stacktrace",
            "traceback", "sqlstate", "laravel", "illuminate\\", ".php", "/var/", "/home/",
            "exception", "undefined", "route", "token", "auth_data", "file path", "json key",
            "trade_no", "plan_id", "month_price", "controller.php", "swift:"
        ]
        guard !unsafeFragments.contains(where: lower.contains),
              lower != "not found",
              lower != "internal server error",
              lower != "server error",
              lower != "bad gateway",
              lower != "service unavailable",
              lower != "gateway timeout",
              lower != "uh-oh, we've had some problems, we're working on it.",
              lower != "the given data was invalid." else {
            return nil
        }
        return normalized
    }
}

private extension V2BoardAPIResponsePolicy {
    var authEndpoint: V2BoardAuthEndpoint? {
        guard case let .authBusiness(endpoint) = self else { return nil }
        return endpoint
    }
}
