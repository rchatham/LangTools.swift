# iOS settings screenshots

Captured from the Botsworth iPhone 17 Pro / iOS 26.3.1 integration fixture.

![Settings menu](menu.png)
![Advanced settings retained after reopening](advanced-persisted.png)

Automated simulator screenshot comparisons live in the consuming Botsworth app:
`App/UITests/ProxyModelDiscoveryUITests.swift`, `testSettingsScreenshotBaselines`.
See [Botsworth MR !44](https://gitlab.com/rchatham/Botsworth/-/merge_requests/44)
for the baseline images, runtime contract, and verification results. This tests
these shared views inside their actual iOS NavigationStack and Form host.
