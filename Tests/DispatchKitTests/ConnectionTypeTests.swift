import Foundation
import Testing
@testable import DispatchKit

/// Raw-value freeze: any renumbering of ConnectionType breaks loudly here.
/// 0–2 are the original Reporter export values; 3+ are additive (plan 26).
@Test func connectionTypeRawValuesAreFrozen() {
    #expect(ConnectionType.cellular.rawValue == 0)
    #expect(ConnectionType.wifi.rawValue == 1)
    #expect(ConnectionType.none.rawValue == 2)
    #expect(ConnectionType.wired.rawValue == 3)
    #expect(ConnectionType.cellular5G.rawValue == 4)
    #expect(ConnectionType.cellularLTE.rawValue == 5)
    #expect(ConnectionType.cellular3G.rawValue == 6)
    #expect(ConnectionType.cellular2G.rawValue == 7)
    #expect(ConnectionType.satellite.rawValue == 8)
    #expect(ConnectionType.allCases.count == 9)
}

@Test func connectionTypeDisplayNames() {
    #expect(ConnectionType.none.displayName == "None")
    #expect(ConnectionType.wifi.displayName == "Wi-Fi")
    #expect(ConnectionType.wired.displayName == "Wired")
    #expect(ConnectionType.cellular5G.displayName == "5G")
    #expect(ConnectionType.cellularLTE.displayName == "LTE")
    #expect(ConnectionType.cellular3G.displayName == "3G")
    #expect(ConnectionType.cellular2G.displayName == "2G")
    #expect(ConnectionType.cellular.displayName == "Cellular")
    #expect(ConnectionType.satellite.displayName == "Satellite")
}

@Test func radioAccessTechnologyMapping() {
    #expect(ConnectionType.cellular(fromRadioAccessTechnology: "CTRadioAccessTechnologyNR") == .cellular5G)
    #expect(ConnectionType.cellular(fromRadioAccessTechnology: "CTRadioAccessTechnologyNRNSA") == .cellular5G)
    #expect(ConnectionType.cellular(fromRadioAccessTechnology: "CTRadioAccessTechnologyLTE") == .cellularLTE)
    for threeG in ["CTRadioAccessTechnologyWCDMA", "CTRadioAccessTechnologyHSDPA",
                   "CTRadioAccessTechnologyHSUPA", "CTRadioAccessTechnologyCDMAEVDORev0",
                   "CTRadioAccessTechnologyCDMAEVDORevA", "CTRadioAccessTechnologyCDMAEVDORevB",
                   "CTRadioAccessTechnologyeHRPD"] {
        #expect(ConnectionType.cellular(fromRadioAccessTechnology: threeG) == .cellular3G)
    }
    for twoG in ["CTRadioAccessTechnologyEdge", "CTRadioAccessTechnologyGPRS",
                 "CTRadioAccessTechnologyCDMA1x"] {
        #expect(ConnectionType.cellular(fromRadioAccessTechnology: twoG) == .cellular2G)
    }
    #expect(ConnectionType.cellular(fromRadioAccessTechnology: nil) == .cellular)
    #expect(ConnectionType.cellular(fromRadioAccessTechnology: "garbage") == .cellular)
}
