import XCTest
import SwiftUI
@testable import Chat

@MainActor
final class CheckboxToggleStyleTests: XCTestCase {
    func testStylingDoesNotDiscardToggleContent() {
        let toggle = Toggle("Native toggle", isOn: .constant(false))
        let styled = toggle.checkboxToggleStyle()

        XCTAssertNotEqual(
            ObjectIdentifier(type(of: styled)),
            ObjectIdentifier(EmptyView.self)
        )
    }

    #if !os(macOS)
    func testNonMacOSStylingPreservesOriginalToggleType() {
        let toggle = Toggle("Native toggle", isOn: .constant(false))
        let styled = toggle.checkboxToggleStyle()

        XCTAssertEqual(
            ObjectIdentifier(type(of: styled)),
            ObjectIdentifier(type(of: toggle))
        )
    }
    #endif
}
