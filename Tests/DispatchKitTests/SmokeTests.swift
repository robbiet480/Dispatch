import Testing
@testable import DispatchKit

@Test func schemaVersionIsTwo() {
    #expect(DispatchKitInfo.schemaVersion == 2)
}
