import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class WebAuthnSession: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private var originalChallenge = ""
    private static var retained: WebAuthnSession?

    static func authenticate(_ challenge: WebAuthnChallenge, fallbackRPID: String) async throws -> String {
        let session = WebAuthnSession()
        retained = session
        defer { retained = nil }
        return try await session.perform(challenge, fallbackRPID: fallbackRPID)
    }

    private func perform(_ challenge: WebAuthnChallenge, fallbackRPID: String) async throws -> String {
        let publicKey = challenge.publicKey
        guard let challengeData = Data(base64URLEncoded: publicKey.challenge) else { throw ProxmoxError.decodingFailed("Invalid WebAuthn challenge") }
        originalChallenge = challenge.string ?? publicKey.challenge
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: publicKey.rpId ?? fallbackRPID)
        let request = provider.createCredentialAssertionRequest(challenge: challengeData)
        if let descriptors = publicKey.allowCredentials {
            request.allowedCredentials = descriptors.compactMap { descriptor in
                Data(base64URLEncoded: descriptor.id).map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            continuation?.resume(throwing: ProxmoxError.authenticationFailed("Unsupported WebAuthn credential")); continuation=nil; return
        }
        let response: [String: Any] = [
            "id": credential.credentialID.base64URLEncodedString(),
            "type": "public-key",
            "challenge": originalChallenge,
            "rawId": credential.credentialID.base64URLEncodedString(),
            "response": [
                "authenticatorData": credential.rawAuthenticatorData.base64URLEncodedString(),
                "clientDataJSON": credential.rawClientDataJSON.base64URLEncodedString(),
                "signature": credential.signature.base64URLEncodedString(),
            ],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: response)
            continuation?.resume(returning: String(decoding: data, as: UTF8.self))
        } catch { continuation?.resume(throwing: error) }
        continuation=nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error); continuation=nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
