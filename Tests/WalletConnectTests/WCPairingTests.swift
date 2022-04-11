import XCTest
@testable import WalletConnect

final class WCPairingTests: XCTestCase {
    
    var referenceDate: Date!
    
    override func setUp() {
        referenceDate = Date()
        func getDate() -> Date { return referenceDate }
        WCPairing.dateInitializer = getDate
    }
    
    override func tearDown() {
        WCPairing.dateInitializer = Date.init
    }
    
    func testAbsoluteValues() {
        XCTAssertEqual(WCPairing.timeToLiveInactive, 5 * .minute, "Inactive time-to-live is 5 minutes.")
        XCTAssertEqual(WCPairing.timeToLiveActive, 30 * .day, "Active time-to-live is 30 days.")
    }
    
    func testInitInactiveFromTopic() {
        let pairing = WCPairing(topic: "", selfMetadata: AppMetadata.stub())
        let inactiveExpiry = referenceDate.advanced(by: WCPairing.timeToLiveInactive)
        XCTAssertFalse(pairing.isActive)
        XCTAssertEqual(pairing.expiryDate, inactiveExpiry)
    }
    
    func testInitInactiveFromURI() {
        let pairing = WCPairing(uri: WalletConnectURI.stub())
        let inactiveExpiry = referenceDate.advanced(by: WCPairing.timeToLiveInactive)
        XCTAssertFalse(pairing.isActive)
        XCTAssertEqual(pairing.expiryDate, inactiveExpiry)
    }
    
    func testUpdateExpiry() {
        var pairing = WCPairing(topic: "", selfMetadata: AppMetadata.stub())
        let activeExpiry = referenceDate.advanced(by: WCPairing.timeToLiveActive)
        try? pairing.updateExpiry()
        XCTAssertEqual(pairing.expiryDate, activeExpiry)
    }
    
    func testActivate() {
        var pairing = WCPairing(topic: "", selfMetadata: AppMetadata.stub())
        let activeExpiry = referenceDate.advanced(by: WCPairing.timeToLiveActive)
        pairing.activate()
        XCTAssertTrue(pairing.isActive)
        XCTAssertEqual(pairing.expiryDate, activeExpiry)
    }
}
