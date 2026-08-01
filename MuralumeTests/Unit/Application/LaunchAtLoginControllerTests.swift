import XCTest
@testable import Muralume

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testControllerUsesSystemStatusAsSourceOfTruth() {
        let service = TestLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertFalse(controller.isEffective)
        XCTAssertTrue(controller.isRequested)

        service.status = .enabled
        controller.refresh()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEffective)
    }

    func testEnablingRegistersAndOnlyEnabledStatusBecomesEffective() {
        let service = TestLaunchAtLoginService(status: .disabled)
        service.statusAfterRegister = .enabled
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEffective)
        XCTAssertNil(controller.operationFailure)
    }

    func testApprovalRequiredDoesNotClaimLoginStartupIsEffective() {
        let service = TestLaunchAtLoginService(status: .disabled)
        service.statusAfterRegister = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertFalse(controller.isEffective)
        XCTAssertTrue(controller.isRequested)
        XCTAssertNil(controller.operationFailure)

        controller.openSystemSettings()
        XCTAssertEqual(service.openSystemSettingsCount, 1)

        service.statusAfterUnregister = .disabled
        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(controller.isRequested)
    }

    func testRegistrationFailureRefreshesActualStatusAndReportsFailure() {
        let service = TestLaunchAtLoginService(status: .disabled)
        service.registerError = TestLaunchAtLoginError.failed
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .disabled)
        XCTAssertEqual(controller.operationFailure, .enableFailed)
        XCTAssertFalse(controller.isUpdating)

        controller.refresh()
        XCTAssertEqual(controller.operationFailure, .enableFailed)
    }

    func testDisablingUnregistersWithoutClearingOtherPreferences() {
        let service = TestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .disabled
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(controller.isEffective)
    }

    func testDisableFailureSurvivesRefreshUntilSystemReportsDisabled() {
        let service = TestLaunchAtLoginService(status: .enabled)
        service.unregisterError = TestLaunchAtLoginError.failed
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)
        controller.refresh()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(controller.operationFailure, .disableFailed)

        service.status = .disabled
        controller.refresh()
        XCTAssertNil(controller.operationFailure)
    }
}

private enum TestLaunchAtLoginError: Error {
    case failed
}

@MainActor
private final class TestLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var statusAfterRegister: LaunchAtLoginStatus?
    var statusAfterUnregister: LaunchAtLoginStatus?
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        if let statusAfterRegister {
            status = statusAfterRegister
        }
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
    }

    func openSystemSettings() {
        openSystemSettingsCount += 1
    }
}
