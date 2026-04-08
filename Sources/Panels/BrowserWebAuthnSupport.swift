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

    static var scriptSource: String {
        let handlerName = handlerName
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

          const capabilityFlag = (key, fallback) =>
            currentCapabilities()
              .then((capabilities) => {
                if (capabilities.denied === true) {
                  return false;
                }
                if (capabilities.authorized === true || capabilities.canPromptForAccess === true) {
                  const value = capabilities[key];
                  return typeof value === "boolean" ? value : true;
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
                if (!options || !options.publicKey) {
                  return originalCreate.call(this, options);
                }
                return requestAccessIfNeeded().then(() => originalCreate.call(this, options));
              }
            });

            Object.defineProperty(prototype, "get", {
              configurable: true,
              writable: true,
              value: function get(options) {
                if (!options || !options.publicKey) {
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
    }
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
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func install(on webView: WKWebView) {
        self.webView = webView
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
        let denied = state == .denied
        let authorized = state == .authorized
        let canPromptForAccess = state == .notDetermined

        return [
            "authorized": authorized,
            "denied": denied,
            "canPromptForAccess": canPromptForAccess,
            "userVerifyingPlatformAuthenticatorAvailable": !denied,
            "conditionalMediationAvailable": !denied,
            "hybridTransportAvailable": !denied,
            "securityKeysAvailable": {
                if #available(macOS 14.4, *) {
                    return true
                }
                return false
            }(),
        ]
    }
}
