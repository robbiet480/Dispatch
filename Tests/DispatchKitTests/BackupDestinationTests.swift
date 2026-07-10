import Foundation
import Testing
@testable import DispatchKit

// MARK: - stored raw value → mode

@Test func destinationDefaultsToBothWhenNothingStored() {
    #expect(BackupDestination.stored(nil) == .both)
}

@Test func destinationRoundTripsEveryCase() {
    for destination in BackupDestination.allCases {
        #expect(BackupDestination.stored(destination.rawValue) == destination)
    }
}

@Test func destinationFallsBackToBothForUnknownStoredValue() {
    // A future build's value (or corruption) must not crash or silently
    // disable backups — fall back to the belt-and-braces default.
    #expect(BackupDestination.stored("dropbox") == .both)
    #expect(BackupDestination.stored("") == .both)
}

// MARK: - effective write targets

@Test func localModeWritesOnlyLocalRegardlessOfICloud() {
    #expect(BackupDestination.local.writesLocal(iCloudAvailable: true))
    #expect(BackupDestination.local.writesLocal(iCloudAvailable: false))
    #expect(!BackupDestination.local.writesICloud(iCloudAvailable: true))
    #expect(!BackupDestination.local.writesICloud(iCloudAvailable: false))
}

@Test func bothModeWritesBothWhenICloudAvailable() {
    #expect(BackupDestination.both.writesLocal(iCloudAvailable: true))
    #expect(BackupDestination.both.writesICloud(iCloudAvailable: true))
}

@Test func bothModeDegradesToLocalOnlyWhenICloudUnavailable() {
    #expect(BackupDestination.both.writesLocal(iCloudAvailable: false))
    #expect(!BackupDestination.both.writesICloud(iCloudAvailable: false))
}

@Test func iCloudModeWritesOnlyICloudWhenAvailable() {
    #expect(!BackupDestination.iCloudDrive.writesLocal(iCloudAvailable: true))
    #expect(BackupDestination.iCloudDrive.writesICloud(iCloudAvailable: true))
}

@Test func iCloudModeFallsBackToLocalWhenUnavailable() {
    // Never back up nowhere: iCloud-only with no container resolves to the
    // guaranteed local copy.
    #expect(BackupDestination.iCloudDrive.writesLocal(iCloudAvailable: false))
    #expect(!BackupDestination.iCloudDrive.writesICloud(iCloudAvailable: false))
}

@Test func everyModeAlwaysWritesSomewhere() {
    for destination in BackupDestination.allCases {
        for available in [true, false] {
            #expect(destination.writesLocal(iCloudAvailable: available)
                || destination.writesICloud(iCloudAvailable: available))
        }
    }
}
