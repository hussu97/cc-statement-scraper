import Foundation
import Sentry

/// What must never reach Sentry: SMS text, passwords, tokens, auth headers,
/// emails. Detection is deliberately broad — a dropped breadcrumb costs
/// nothing; a leaked bank SMS is the thing this file exists to prevent.
public enum SensitiveText {
    static let keyDenylist: Set<String> = [
        "body", "sms", "sms_body", "message_body", "text", "message_text", "content",
        "password", "pass", "secret", "token", "access_token", "refresh_token",
        "authorization", "apikey", "api_key", "x-profile-key", "cookie", "set-cookie", "email",
    ]

    static let jwt = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#)
    static let bearer = try! NSRegularExpression(pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#)
    static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    static let serviceToken = try! NSRegularExpression(pattern: #"\bccs_[A-Za-z0-9_-]{8,}"#)

    public static func isSensitiveKey(_ key: String) -> Bool {
        keyDenylist.contains(key.lowercased())
    }

    /// True when `text` looks like a bank SMS (or an OTP), or carries a credential.
    public static func containsSensitive(_ text: String) -> Bool {
        looksLikeSMS(text) || matches(jwt, text) || matches(bearer, text) || matches(email, text)
            || matches(serviceToken, text)
    }

    /// An amount next to a currency, card wording, or an OTP.
    public static func looksLikeSMS(_ text: String) -> Bool {
        SMSCapture.isOTP(text)
            || matches(SMSCapture.amountPattern, text)
            || matches(SMSCapture.creditCardPattern, text)
            || matches(SMSCapture.accountPattern, text)
            || text.range(of: #"(?i)card\s+(ending|no\.?)\s*[x*\d]"#, options: .regularExpression) != nil
    }

    /// Any value (string, number, nested dictionary/array) containing sensitive text.
    static func valueIsSensitive(_ value: Any) -> Bool {
        switch value {
        case let s as String: return containsSensitive(s)
        case let d as [String: Any]: return d.contains { isSensitiveKey($0.key) || valueIsSensitive($0.value) }
        case let a as [Any]: return a.contains(where: valueIsSensitive)
        default: return false
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// `beforeSend` / `beforeBreadcrumb` for every Ledger runtime on the phone.
public enum TelemetryScrubber {
    static let redacted = "[redacted]"
    static let headerDenylist: Set<String> = ["authorization", "apikey", "x-profile-key", "cookie", "x-client-info"]
    static let sdkContexts: Set<String> = ["device", "os", "app", "culture", "runtime", "trace", "gpu", "cloud_resource"]

    public static func scrub(_ event: Event) -> Event? {
        event.user = event.user.map { user in
            // Keep only the opaque id; never email, name or IP.
            let kept = User()
            kept.userId = user.userId
            return kept
        }
        if let message = event.message, SensitiveText.containsSensitive(message.formatted) {
            event.message = SentryMessage(formatted: redacted)
        }
        event.exceptions?.forEach { exception in
            if let value = exception.value, SensitiveText.containsSensitive(value) {
                exception.value = redacted
            }
        }
        event.extra = scrubDictionary(event.extra)
        event.tags = event.tags?.filter { !SensitiveText.isSensitiveKey($0.key) && !SensitiveText.containsSensitive($0.value) }
        if let context = event.context {
            var cleaned: [String: [String: Any]] = [:]
            // SDK-generated device facts ("ARM64", model ids) trip the amount
            // heuristic and carry no user data; everything else is scrubbed.
            for (key, value) in context {
                cleaned[key] = sdkContexts.contains(key) ? value : (scrubDictionary(value) ?? [:])
            }
            event.context = cleaned
        }
        event.breadcrumbs = event.breadcrumbs?.compactMap(scrub(breadcrumb:))
        if let request = event.request {
            request.headers = request.headers?.filter { !headerDenylist.contains($0.key.lowercased()) }
            request.cookies = nil
            if let query = request.queryString, SensitiveText.containsSensitive(query) { request.queryString = nil }
        }
        return event
    }

    /// Drops a breadcrumb whose message or data carries SMS text or a credential.
    public static func scrub(breadcrumb: Breadcrumb) -> Breadcrumb? {
        if let message = breadcrumb.message, SensitiveText.containsSensitive(message) { return nil }
        if let data = breadcrumb.data, SensitiveText.valueIsSensitive(data) { return nil }
        return breadcrumb
    }

    /// Removes denylisted keys and any value that contains sensitive text.
    static func scrubDictionary(_ dict: [String: Any]?) -> [String: Any]? {
        guard let dict else { return nil }
        var out: [String: Any] = [:]
        for (key, value) in dict where !SensitiveText.isSensitiveKey(key) && !SensitiveText.valueIsSensitive(value) {
            out[key] = value
        }
        return out
    }
}
