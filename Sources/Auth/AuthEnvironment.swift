import Foundation

enum AuthEnvironment {
    private static let productionStackProjectID = "8a877114-b905-47c5-8b64-3a2d90679577"
    private static let productionStackPublishableClientKey = "pck_pqghntgd942k1hg066m7htjakb8g4ybaj66hqj2g2frj0"

    static var callbackScheme: String {
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
#if DEBUG
        return "cmux-dev"
#else
        return "cmux"
#endif
    }

    static var callbackURL: URL {
        URL(string: "\(callbackScheme)://auth-callback")!
    }

    static var websiteOrigin: URL {
        resolvedURL(
            environmentKey: "CMUX_WWW_ORIGIN",
            fallback: "https://cmux.dev"
        )
    }

    static var signInWebsiteOrigin: URL {
        canonicalizedLoopbackURL(
            resolvedURL(
            environmentKey: "CMUX_AUTH_WWW_ORIGIN",
            fallback: "https://cmux.dev"
        )
        )
    }

    static var apiBaseURL: URL {
        canonicalizedLoopbackURL(
            resolvedURL(
                environmentKey: "CMUX_API_BASE_URL",
                fallback: "https://api.cmux.sh"
            )
        )
    }

    static var stackBaseURL: URL {
        resolvedURL(
            environmentKey: "CMUX_STACK_BASE_URL",
            fallback: "https://api.stack-auth.com"
        )
    }

    static var stackProjectID: String {
        let environment = ProcessInfo.processInfo.environment
        if let projectID = environment["CMUX_STACK_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        return productionStackProjectID
    }

    static var stackPublishableClientKey: String {
        let environment = ProcessInfo.processInfo.environment
        if let clientKey = environment["CMUX_STACK_PUBLISHABLE_CLIENT_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !clientKey.isEmpty {
            return clientKey
        }
        return productionStackPublishableClientKey
    }

    static func signInURL() -> URL {
        var afterSignInComponents = URLComponents(
            url: signInWebsiteOrigin.appendingPathComponent("handler/after-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        afterSignInComponents.queryItems = [
            URLQueryItem(
                name: "native_app_return_to",
                value: callbackURL.absoluteString
            ),
        ]

        var components = URLComponents(
            url: signInWebsiteOrigin.appendingPathComponent("handler/sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "after_auth_return_to",
                value: afterSignInComponents.url!.absoluteString
            ),
        ]
        return components.url!
    }

    private static func resolvedURL(environmentKey: String, fallback: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let overridden = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return url
        }
        return URL(string: fallback)!
    }

    private static func canonicalizedLoopbackURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else {
            return url
        }

        let loopbackHosts = ["127.0.0.1", "::1", "[::1]", "0.0.0.0"]
        guard loopbackHosts.contains(host) else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "localhost"
        return components?.url ?? url
    }
}
