import AppKit
import XCTest
@testable import ColimaDock

final class RemoteConnectionFormTests: XCTestCase {
    @MainActor
    func testAlertMakesAllConnectionFieldsVisible() {
        let form = RemoteConnectionForm(existing: nil, offersSparky: true)
        let alert = NSAlert()
        alert.messageText = "Add Remote Colima"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form.view
        alert.layout()
        alert.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(form.view.bounds.height, 100)
        for field in [form.name, form.alias, form.profile, form.forwards] {
            XCTAssertGreaterThan(field.bounds.width, 200)
            XCTAssertGreaterThan(field.bounds.height, 16)
            XCTAssertTrue(form.view.bounds.contains(field.convert(field.bounds, to: form.view)))
        }
        XCTAssertEqual(form.name.stringValue, "Sparky")
        XCTAssertEqual(form.alias.stringValue, "sparky-local")
        XCTAssertEqual(form.profile.stringValue, "komodo-dev")
    }
}
