import SwiftUI

extension View {
    /// Checkbox affordance on macOS; other platforms keep their native toggle
    /// styling. `ToggleStyle.checkbox` is unavailable on iOS, so shared view
    /// code must route through this helper instead of applying it directly.
    @ViewBuilder
    public func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}