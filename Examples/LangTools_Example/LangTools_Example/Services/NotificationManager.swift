//
//  NotificationManager.swift
//
//  Created by Reid Chatham on 9/9/24.
//

import UIKit
import UserNotifications


class NotificationManager {
    static let shared = NotificationManager()

    private init() { }

    func requestPushNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge], completionHandler: handleRequestAuthorization)
    }

    func handleRequestAuthorization(granted: Bool, error: Error?) {
        if let error = error {
            print("Error requesting authorization for push notifications: \(error.localizedDescription)")
            return
        }

        guard granted else {
            return print("Permission denied for push notifications")
        }
        print("Permission granted for push notifications")
        DispatchQueue.main.async {
            #if canImport(UIKit)
            UIApplication.shared.registerForRemoteNotifications()
            #elseif canImport(AppKit)
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }
}
