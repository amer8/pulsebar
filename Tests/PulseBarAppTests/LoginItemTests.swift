import XCTest

@testable import PulseBarApp

@MainActor
final class LoginItemTests: XCTestCase {
    func testEnabledAndDisabledFollowServiceState() async {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        await controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testApprovalAndExternalChangesAreReflected() async {
        let service = FakeLoginItemService()
        service.needsApproval = true
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.status.requested)
        service.status = .enabled
        controller.refresh()
        XCTAssertEqual(controller.status, .enabled)
    }

    func testFailureLeavesToggleAtActualState() async {
        let service = FakeLoginItemService()
        service.fail = true
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isUpdating)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServing {
    var status: LoginItemStatus = .disabled
    var needsApproval = false
    var fail = false
    func setEnabled(_ enabled: Bool) async throws {
        if fail { throw URLError(.unknown) }
        status = enabled ? (needsApproval ? .requiresApproval : .enabled) : .disabled
    }
}
