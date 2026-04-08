import AuthenticationServices
import Foundation
import WebKit

/// Thin browser-passkey bridge for `WKWebView`.
///
/// WebKit remains responsible for the actual WebAuthn ceremony and credential
/// marshalling. The bridge only exposes the browser's authorization state and
/// requests passkey access the first time a page initiates a credential flow.
enum BrowserWebAuthnBridgeContract {
    static let handlerName = "cmuxWebAuthn"

    static let scriptSource: String = {
        let handlerName = BrowserWebAuthnBridgeContract.handlerName
        return #"""
        (() => {
          if (window.__cmuxWebAuthnBridgeInstalled) {
            return true;
          }
          window.__cmuxWebAuthnBridgeInstalled = true;

          const handlerName = "\#(handlerName)";

          const nativeHandler = () => {
            try {
              const handlers = window.webkit && window.webkit.messageHandlers;
              const handler = handlers && handlers[handlerName];
              return handler && typeof handler.postMessage === "function" ? handler : null;
            } catch (_) {
              return null;
            }
          };

          const makeError = (name, message) => {
            const safeName = name || "UnknownError";
            const safeMessage = message || "The passkey request failed.";
            if (safeName === "TypeError") {
              return new TypeError(safeMessage);
            }
            try {
              return new DOMException(safeMessage, safeName);
            } catch (_) {
              const error = new Error(safeMessage);
              error.name = safeName;
              return error;
            }
          };

          const ensureReplySuccess = (reply) => {
            if (reply && reply.ok === true) {
              return reply;
            }
            const error = reply && reply.error ? reply.error : { name: "UnknownError", message: "The passkey request failed." };
            throw makeError(error.name, error.message);
          };

          const callNative = (kind) => {
            const handler = nativeHandler();
            if (!handler) {
              return Promise.reject(makeError("NotSupportedError", "Native passkey support is unavailable."));
            }
            return handler.postMessage({ kind }).then(ensureReplySuccess);
          };

          const currentCapabilities = () =>
            callNative("capabilities").then((reply) => reply.capabilities || {});

          const requestAccessIfNeeded = () =>
            callNative("requestAccess").then((reply) => {
              if (reply.authorized === true) {
                return true;
              }
              if (reply.denied === true) {
                throw makeError("NotAllowedError", "Passkey access was denied for this browser.");
              }
              throw makeError("NotAllowedError", "Passkey access is not available.");
            });

          const normalizedString = (value) =>
            typeof value === "string" ? value.toLowerCase() : "";

          const credentialTransports = (credentials) => {
            if (!Array.isArray(credentials)) {
              return [];
            }

            const transports = [];
            for (const credential of credentials) {
              if (!credential || !Array.isArray(credential.transports)) {
                continue;
              }

              for (const transport of credential.transports) {
                const normalizedTransport = normalizedString(transport);
                if (normalizedTransport) {
                  transports.push(normalizedTransport);
                }
              }
            }

            return transports;
          };

          const hasAnyTransport = (transports, candidates) =>
            transports.some((transport) => candidates.includes(transport));

          const requiresPasskeyAuthorization = (options, operation) => {
            const publicKey = options && options.publicKey;
            if (!publicKey) {
              return false;
            }

            const attachment = normalizedString(
              publicKey.authenticatorSelection &&
                publicKey.authenticatorSelection.authenticatorAttachment
            );
            if (attachment === "platform") {
              return true;
            }
            if (attachment === "cross-platform") {
              return false;
            }

            if (
              operation === "get" &&
              normalizedString(options && options.mediation) === "conditional"
            ) {
              return true;
            }

            const allowCredentialTransports = credentialTransports(publicKey.allowCredentials);
            if (allowCredentialTransports.length > 0) {
              const hasPlatformTransport = hasAnyTransport(
                allowCredentialTransports,
                ["internal", "hybrid"]
              );
              const hasCrossPlatformTransport = hasAnyTransport(
                allowCredentialTransports,
                ["usb", "nfc", "ble"]
              );
              if (hasCrossPlatformTransport && !hasPlatformTransport) {
                return false;
              }
              if (hasPlatformTransport) {
                return true;
              }
            }

            return operation === "create";
          };

          const capabilityFlag = (key, fallback) =>
            currentCapabilities()
              .then((capabilities) => {
                if (capabilities.denied === true) {
                  return false;
                }
                const value = capabilities[key];
                if (typeof value === "boolean") {
                  return value;
                }
                return typeof fallback === "function" ? fallback() : !!fallback;
              })
              .catch(() => (typeof fallback === "function" ? fallback() : !!fallback));

          if (window.CredentialsContainer && window.CredentialsContainer.prototype) {
            const prototype = window.CredentialsContainer.prototype;
            const originalCreate = prototype.create;
            const originalGet = prototype.get;

            Object.defineProperty(prototype, "create", {
              configurable: true,
              writable: true,
              value: function create(options) {
                if (!options || !options.publicKey || !requiresPasskeyAuthorization(options, "create")) {
                  return originalCreate.call(this, options);
                }
                return requestAccessIfNeeded().then(() => originalCreate.call(this, options));
              }
            });

            Object.defineProperty(prototype, "get", {
              configurable: true,
              writable: true,
              value: function get(options) {
                if (!options || !options.publicKey || !requiresPasskeyAuthorization(options, "get")) {
                  return originalGet.call(this, options);
                }
                return requestAccessIfNeeded().then(() => originalGet.call(this, options));
              }
            });
          }

          if (window.PublicKeyCredential) {
            const originalUVPA =
              typeof window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable === "function"
                ? window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable.bind(window.PublicKeyCredential)
                : null;
            const originalConditional =
              typeof window.PublicKeyCredential.isConditionalMediationAvailable === "function"
                ? window.PublicKeyCredential.isConditionalMediationAvailable.bind(window.PublicKeyCredential)
                : null;

            window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function isUserVerifyingPlatformAuthenticatorAvailable() {
              return capabilityFlag(
                "userVerifyingPlatformAuthenticatorAvailable",
                originalUVPA || false
              );
            };

            if (originalConditional) {
              window.PublicKeyCredential.isConditionalMediationAvailable = function isConditionalMediationAvailable() {
                return capabilityFlag("conditionalMediationAvailable", originalConditional);
              };
            }
          }

          return true;
        })();
        """#
    }()
}

private enum BrowserWebAuthnBridgeMessageKind: String {
    case capabilities
    case requestAccess
}

private enum BrowserWebAuthnErrorName: String {
    case notAllowed = "NotAllowedError"
    case notSupported = "NotSupportedError"
    case type = "TypeError"
    case unknown = "UnknownError"
}

private struct BrowserWebAuthnBridgeError: Error {
    let name: BrowserWebAuthnErrorName
    let message: String

    func replyObject() -> [String: Any] {
        [
            "ok": false,
            "error": [
                "name": name.rawValue,
                "message": message,
            ],
        ]
    }

    static func notAllowed(_ message: String) -> Self {
        .init(name: .notAllowed, message: message)
    }

    static func notSupported(_ message: String) -> Self {
        .init(name: .notSupported, message: message)
    }

    static func type(_ message: String) -> Self {
        .init(name: .type, message: message)
    }

    static func unknown(_ message: String) -> Self {
        .init(name: .unknown, message: message)
    }
}

private enum BrowserWebAuthnRequestParser {
    static func parseKind(from body: Any) throws -> BrowserWebAuthnBridgeMessageKind {
        guard let root = body as? [String: Any],
              let rawKind = root["kind"] as? String,
              let kind = BrowserWebAuthnBridgeMessageKind(rawValue: rawKind) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        return kind
    }
}

private struct BrowserWebAuthnSecurityOrigin {
    let scheme: String
    let host: String
    let port: Int

    init(origin: WKSecurityOrigin) {
        scheme = origin.protocol.lowercased()
        host = origin.host.lowercased()
        port = Self.normalizedPort(scheme: scheme, port: origin.port)
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = Self.normalizedPort(scheme: scheme, port: url.port)
    }

    func matches(_ origin: WKSecurityOrigin) -> Bool {
        let other = Self(origin: origin)
        return scheme == other.scheme && host == other.host && port == other.port
    }

    private static func normalizedPort(scheme: String, port: Int?) -> Int {
        if let port, port > 0 {
            return port
        }

        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return -1
        }
    }
}

@MainActor
private final class BrowserPasskeyAuthorizationGate {
    static let shared = BrowserPasskeyAuthorizationGate()

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var inFlightRequest: Task<ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState, Never>?

    func currentAuthorizationState() -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        manager.authorizationStateForPlatformCredentials
    }

    func authorizeIfNeeded() async -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        let currentState = manager.authorizationStateForPlatformCredentials
        guard currentState == .notDetermined else { return currentState }

        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task { @MainActor [manager] in
            await withCheckedContinuation { continuation in
                manager.requestAuthorizationForPublicKeyCredentials { authorizationState in
                    continuation.resume(returning: authorizationState)
                }
            }
        }
        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }
}

final class BrowserWebAuthnCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    override init() {
        super.init()
    }

    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: BrowserWebAuthnBridgeContract.handlerName, contentWorld: .page)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: BrowserWebAuthnBridgeContract.handlerName)
    }

    func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserWebAuthnBridgeContract.handlerName,
            contentWorld: .page
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                switch try BrowserWebAuthnRequestParser.parseKind(from: message.body) {
                case .capabilities:
                    replyHandler(capabilityReply(for: BrowserPasskeyAuthorizationGate.shared.currentAuthorizationState()), nil)
                case .requestAccess:
                    try validateAuthorizationRequestOrigin(for: message)
                    let state = await BrowserPasskeyAuthorizationGate.shared.authorizeIfNeeded()
                    replyHandler(accessReply(for: state), nil)
                }
            } catch let error as BrowserWebAuthnBridgeError {
                replyHandler(error.replyObject(), nil)
            } catch {
                replyHandler(BrowserWebAuthnBridgeError.unknown(error.localizedDescription).replyObject(), nil)
            }
        }
    }
}

@MainActor
private extension BrowserWebAuthnCoordinator {
    func capabilityReply(
        for state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> [String: Any] {
        [
            "ok": true,
            "capabilities": capabilityPayload(for: state),
        ]
    }

    func accessReply(
        for state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> [String: Any] {
        let capabilities = capabilityPayload(for: state)
        return [
            "ok": true,
            "authorized": capabilities["authorized"] as? Bool ?? false,
            "denied": capabilities["denied"] as? Bool ?? false,
            "capabilities": capabilities,
        ]
    }

    func capabilityPayload(
        for state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> [String: Any] {
        let authorized = state == .authorized
        let denied = state == .denied
        let canPromptForAccess = state == .notDetermined
        var payload: [String: Any] = [
            "authorized": authorized,
            "denied": denied,
            "canPromptForAccess": canPromptForAccess,
        ]

        if #available(macOS 26.2, *), state != .denied {
            payload["userVerifyingPlatformAuthenticatorAvailable"] =
                ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys
        }

        return payload
    }

    func validateAuthorizationRequestOrigin(for message: WKScriptMessage) throws {
        let currentState = BrowserPasskeyAuthorizationGate.shared.currentAuthorizationState()
        guard currentState == .notDetermined else { return }
        guard callerMayRequestAuthorization(message) else {
            throw BrowserWebAuthnBridgeError.notAllowed("Passkey access is not available.")
        }
    }

    func callerMayRequestAuthorization(_ message: WKScriptMessage) -> Bool {
        if message.frameInfo.isMainFrame {
            return true
        }

        guard let webView = message.webView,
              let topLevelURL = webView.url,
              let topLevelOrigin = BrowserWebAuthnSecurityOrigin(url: topLevelURL) else {
            return false
        }

        return topLevelOrigin.matches(message.frameInfo.securityOrigin)
    }
}
