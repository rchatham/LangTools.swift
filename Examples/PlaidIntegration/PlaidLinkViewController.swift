//
//  PlaidLinkViewController.swift
//  PlaidIntegration
//
//  Created by Claude on 1/10/26.
//
//  NOTE: This file requires the Plaid Link iOS SDK (LinkKit).
//  Add to your project's dependencies:
//  .package(url: "https://github.com/plaid/plaid-link-ios.git", from: "5.0.0")
//

#if canImport(UIKit)
import UIKit

// MARK: - Plaid Link Coordinator

/// Coordinator for managing the Plaid Link authentication flow.
/// This class handles the presentation and callbacks of Plaid Link.
///
/// Usage with PlaidAgent:
/// ```swift
/// let coordinator = PlaidLinkCoordinator(
///     plaidService: plaidService,
///     presentingViewController: viewController
/// )
///
/// let agent = PlaidAgent(
///     plaidService: plaidService,
///     onInitiateLink: { try await coordinator.presentPlaidLink() }
/// )
/// ```
public class PlaidLinkCoordinator {

    // MARK: - Properties

    private let plaidService: PlaidService
    private weak var presentingViewController: UIViewController?

    // MARK: - Initialization

    public init(plaidService: PlaidService, presentingViewController: UIViewController) {
        self.plaidService = plaidService
        self.presentingViewController = presentingViewController
    }

    // MARK: - Public Methods

    /// Present the Plaid Link flow and return the result.
    /// This method handles the complete flow:
    /// 1. Requests a link token from the backend
    /// 2. Presents the Plaid Link UI
    /// 3. Exchanges the public token for an access token
    /// 4. Returns a success message or throws an error
    public func presentPlaidLink() async throws -> String {
        guard let viewController = presentingViewController else {
            throw PlaidServiceError.linkError("No presenting view controller available")
        }

        // Step 1: Get link token
        let linkToken = try await plaidService.createLinkToken()

        // Step 2: Present Plaid Link and wait for result
        let publicToken = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.main.async {
                self.presentLinkUI(
                    token: linkToken,
                    from: viewController,
                    onSuccess: { publicToken in
                        continuation.resume(returning: publicToken)
                    },
                    onExit: { error in
                        if let error = error {
                            continuation.resume(throwing: PlaidServiceError.linkError(error.localizedDescription))
                        } else {
                            continuation.resume(throwing: PlaidServiceError.linkError("User cancelled the connection"))
                        }
                    }
                )
            }
        }

        // Step 3: Exchange public token for access token
        let result = try await plaidService.exchangePublicToken(publicToken)
        return result
    }

    // MARK: - Private Methods

    /// Present the Plaid Link UI.
    /// NOTE: This is a placeholder implementation. In production, you would use LinkKit.
    private func presentLinkUI(
        token: String,
        from viewController: UIViewController,
        onSuccess: @escaping (String) -> Void,
        onExit: @escaping (Error?) -> Void
    ) {
        // ============================================================
        // PRODUCTION IMPLEMENTATION:
        // Replace this placeholder with actual LinkKit integration:
        //
        // import LinkKit
        //
        // let config = LinkTokenConfiguration(
        //     token: token,
        //     onSuccess: { success in
        //         onSuccess(success.publicToken)
        //     }
        // ) { exit in
        //     onExit(exit.error)
        // }
        //
        // let result = Plaid.create(config)
        // switch result {
        // case .success(let handler):
        //     handler.open(presentUsing: .viewController(viewController))
        // case .failure(let error):
        //     onExit(error)
        // }
        // ============================================================

        // Placeholder: Show a simulated Plaid Link experience
        let alertController = UIAlertController(
            title: "Connect Your Bank",
            message: "This is a simulated Plaid Link flow.\n\nIn production, this would show the real Plaid Link UI where you can securely connect your bank account.\n\nLink Token: \(String(token.prefix(20)))...",
            preferredStyle: .alert
        )

        alertController.addAction(UIAlertAction(title: "Simulate Success", style: .default) { _ in
            // Simulate successful connection
            let simulatedPublicToken = "public-sandbox-" + UUID().uuidString
            onSuccess(simulatedPublicToken)
        })

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            onExit(nil)
        })

        viewController.present(alertController, animated: true)
    }
}

// MARK: - Plaid Link View Controller

/// A view controller that wraps the Plaid Link experience.
/// Use this when you need a dedicated view controller for the Link flow.
public class PlaidLinkViewController: UIViewController {

    // MARK: - Callbacks

    public var onSuccess: ((String) -> Void)?
    public var onExit: ((Error?) -> Void)?

    // MARK: - Properties

    private let linkToken: String
    private let plaidService: PlaidService

    // MARK: - Initialization

    public init(linkToken: String, plaidService: PlaidService) {
        self.linkToken = linkToken
        self.plaidService = plaidService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentLink()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        let activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)

        let label = UILabel()
        label.text = "Loading Plaid Link..."
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    // MARK: - Plaid Link

    private func presentLink() {
        // ============================================================
        // PRODUCTION IMPLEMENTATION:
        // Use LinkKit to present the actual Plaid Link:
        //
        // import LinkKit
        //
        // let config = LinkTokenConfiguration(
        //     token: linkToken,
        //     onSuccess: { [weak self] success in
        //         self?.onSuccess?(success.publicToken)
        //         self?.dismiss(animated: true)
        //     }
        // ) { [weak self] exit in
        //     self?.onExit?(exit.error)
        //     self?.dismiss(animated: true)
        // }
        //
        // switch Plaid.create(config) {
        // case .success(let handler):
        //     handler.open(presentUsing: .viewController(self))
        // case .failure(let error):
        //     onExit?(error)
        //     dismiss(animated: true)
        // }
        // ============================================================

        // Placeholder implementation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showPlaceholderUI()
        }
    }

    private func showPlaceholderUI() {
        let alertController = UIAlertController(
            title: "Plaid Link",
            message: "This is a simulated Plaid Link experience.\n\nIn production, you would see the actual Plaid Link UI here.",
            preferredStyle: .alert
        )

        alertController.addAction(UIAlertAction(title: "Connect Bank", style: .default) { [weak self] _ in
            let publicToken = "public-sandbox-" + UUID().uuidString
            self?.onSuccess?(publicToken)
            self?.dismiss(animated: true)
        })

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.onExit?(nil)
            self?.dismiss(animated: true)
        })

        present(alertController, animated: true)
    }
}

// MARK: - UIViewController Extension

extension UIViewController {

    /// Helper method to present Plaid Link and get the result.
    /// Returns the result message from a successful connection.
    public func presentPlaidLink(plaidService: PlaidService) async throws -> String {
        let coordinator = PlaidLinkCoordinator(
            plaidService: plaidService,
            presentingViewController: self
        )
        return try await coordinator.presentPlaidLink()
    }
}

#endif // canImport(UIKit)
