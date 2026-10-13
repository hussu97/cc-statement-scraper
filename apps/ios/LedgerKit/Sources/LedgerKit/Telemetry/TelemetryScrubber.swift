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
    // SMS shapes. These were the phone's "credit card or not" filter; the phone no
    // longer filters (the server classifies), but the scrubber still needs them.
    /// A currency code or symbol next to a number.
    static let amountPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z]{3}\s?\d[\d,]*(\.\d+)?|\d[\d,]*(\.\d+)?\s?[A-Z]{3}\b|[$€£₹]\s?\d|\bRs\.?\s?\d"#,
        options: [])
    static let creditCardPattern = try! NSRegularExpression(
        pattern: #"credit\s*card|\bcr\.?\s*card\b|\bcc\s+(ending|no)|covered\s+card"#,
        options: [.caseInsensitive])
    static let accountPattern = try! NSRegularExpression(
        pattern: #"debit\s*card|\bdc\s+ending|\ba/c\b|\bacct?\b\.?\s*(no\.?\s*)?[x*\d]|\baccount\s*(no\.?|number)?\s*[x*\d]{3,}|\bsalary\b|\btransfer(red)?\b|\biban\b|\bcredited\s+to\s+your\s+(a/c|account)"#,
        options: [.caseInsensitive])

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
            || matches(amountPattern, text)
            || matches(creditCardPattern, text)
            || matches(accountPattern, text)
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
            // Failed-request capture copies the PostgREST query, which carries
            // what was typed in Activity's search (`or=(description.ilike.*…*)`).
            request.url = request.url.map(withoutQuery)
            request.queryString = nil
            request.fragment = nil
        }
        return event
    }

    /// Drops a breadcrumb whose message or data carries SMS text or a credential,
    /// and takes the query string off an HTTP breadcrumb's URL.
    public static func scrub(breadcrumb: Breadcrumb) -> Breadcrumb? {
        if let data = breadcrumb.data {
            for (key, value) in urlDataEdits(data) { breadcrumb.setData(value: value, key: key) }
        }
        if let message = breadcrumb.message, SensitiveText.containsSensitive(message) { return nil }
        if let data = breadcrumb.data, SensitiveText.valueIsSensitive(data) { return nil }
        return breadcrumb
    }

    /// HTTP spans carry the query string too (`http.query`).
    public static func scrub(span: any Span) -> (any Span)? {
        for (key, value) in urlDataEdits(span.data) {
            if let value { span.setData(value: value, key: key) } else { span.removeData(key: key) }
        }
        return span
    }

    /// Keys Sentry's network tracking fills with a URL's query and fragment.
    static let urlQueryKeys: Set<String> = ["http.query", "http.fragment"]
    /// Keys holding a whole URL.
    static let urlKeys: Set<String> = ["url", "http.url"]

    /// What to change in breadcrumb or span data so no query string or
    /// fragment reaches Sentry: key → new value, or nil to remove the key.
    static func urlDataEdits(_ data: [String: Any]) -> [String: String?] {
        var edits: [String: String?] = [:]
        for (key, value) in data {
            if urlQueryKeys.contains(key) {
                edits[key] = .some(nil)
            } else if urlKeys.contains(key), let url = value as? String, withoutQuery(url) != url {
                edits[key] = withoutQuery(url)
            }
        }
        return edits
    }

    /// `https://host/rest/v1/v_transactions?or=(…)#x` → `https://host/rest/v1/v_transactions`.
    public static func withoutQuery(_ url: String) -> String {
        guard let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        return String(url[..<cut])
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
