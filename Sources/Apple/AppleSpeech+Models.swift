//
//  AppleSpeech+Models.swift
//  LangTools
//
//  Model definitions for AppleSpeech provider
//

import Foundation

extension AppleSpeech {
    /// Model identifier for Apple Speech framework
    ///
    /// Apple Speech uses on-device models that are automatically
    /// selected based on the device and iOS/macOS version.
    public enum Model: String, Codable, CaseIterable {
        /// On-device speech recognition model
        /// Automatically uses the best available model for the device
        case onDevice = "on-device"

        public var id: String { rawValue }
        public var displayName: String { "Apple Speech (On-Device)" }
    }
}
