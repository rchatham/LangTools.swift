//
//  NotificationEncryptionService.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit

/// Service for encrypting and decrypting agent notifications using AES-GCM
public final class NotificationEncryptionService: Sendable {
    public init() {}

    /// Encrypts an agent notification for secure transmission
    public func encrypt(
        notification: AgentNotification,
        userKey: String
    ) throws -> EncryptedNotificationPayload {
        guard let keyData = Data(base64Encoded: userKey) else {
            throw CloudAgentError.encryptionFailed("Invalid base64 key")
        }

        let symmetricKey = SymmetricKey(data: keyData)
        let notificationData = try JSONEncoder().encode(notification)
        let nonce = AES.GCM.Nonce()

        let sealedBox = try AES.GCM.seal(notificationData, using: symmetricKey, nonce: nonce)

        let ciphertext = sealedBox.ciphertext.base64EncodedString()
        let tag = sealedBox.tag.base64EncodedString()
        let nonceData = nonce.withUnsafeBytes { Data($0) }

        return EncryptedNotificationPayload(
            data: ciphertext + "." + tag, // Combine ciphertext and tag
            nonce: nonceData.base64EncodedString(),
            agentId: notification.agentName
        )
    }

    /// Decrypts an encrypted notification payload
    public func decrypt(
        payload: EncryptedNotificationPayload,
        userKey: String
    ) throws -> AgentNotification {
        guard let keyData = Data(base64Encoded: userKey),
              let nonceData = Data(base64Encoded: payload.nonce) else {
            throw CloudAgentError.decryptionFailed("Invalid base64 data")
        }

        // Split combined data into ciphertext and tag
        let components = payload.data.split(separator: ".")
        guard components.count == 2,
              let encryptedData = Data(base64Encoded: String(components[0])),
              let tagData = Data(base64Encoded: String(components[1])) else {
            throw CloudAgentError.decryptionFailed("Invalid payload format")
        }

        let symmetricKey = SymmetricKey(data: keyData)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encryptedData, tag: tagData)
        let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)

        return try JSONDecoder().decode(AgentNotification.self, from: decryptedData)
    }

    /// Generates a new encryption key
    public func generateEncryptionKey() -> String {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        return keyData.base64EncodedString()
    }

    /// Generates a random nonce for encryption
    public func generateNonce() -> String {
        let nonce = AES.GCM.Nonce()
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        return nonceData.base64EncodedString()
    }
}

#else

/// Stub implementation for platforms without CryptoKit (e.g., Linux)
/// On Linux, use OpenSSL or another crypto library for production
public final class NotificationEncryptionService: Sendable {
    public init() {}

    /// Encrypts an agent notification (stub - requires OpenSSL on Linux)
    public func encrypt(
        notification: AgentNotification,
        userKey: String
    ) throws -> EncryptedNotificationPayload {
        // For Linux, integrate with OpenSSL or use swift-crypto package
        throw CloudAgentError.encryptionFailed("CryptoKit not available on this platform. Use swift-crypto for cross-platform support.")
    }

    /// Decrypts an encrypted notification payload (stub - requires OpenSSL on Linux)
    public func decrypt(
        payload: EncryptedNotificationPayload,
        userKey: String
    ) throws -> AgentNotification {
        throw CloudAgentError.decryptionFailed("CryptoKit not available on this platform. Use swift-crypto for cross-platform support.")
    }

    /// Generates a new encryption key using random bytes
    public func generateEncryptionKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }

    /// Generates a random nonce
    public func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }
}

#endif
