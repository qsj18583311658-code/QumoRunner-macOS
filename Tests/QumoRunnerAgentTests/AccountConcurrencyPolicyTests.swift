import XCTest

final class AccountConcurrencyPolicyTests: XCTestCase {
    func testExistingProfileStaysAtOneBeforeActivation() {
        XCTAssertEqual(
            AccountConcurrencyPolicy.effective(
                autoActivated: false,
                quotaState: .unknown,
                detected: nil,
                unlimited: false,
                globalLimit: 8
            ),
            1
        )
    }

    func testActivatedProfileFallsBackToTwoAndZeroQuotaWins() {
        XCTAssertEqual(
            AccountConcurrencyPolicy.effective(
                autoActivated: true,
                quotaState: .unknown,
                detected: nil,
                unlimited: false,
                globalLimit: 8
            ),
            2
        )
        XCTAssertEqual(
            AccountConcurrencyPolicy.effective(
                autoActivated: true,
                quotaState: .zero,
                detected: 6,
                unlimited: false,
                globalLimit: 8
            ),
            0
        )
    }

    func testMigrationDecodeDefaultsAutoConcurrencyToOff() throws {
        let current = StoredProfileInsight.empty()
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "autoConcurrencyActivated")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StoredProfileInsight.self, from: legacy)

        XCTAssertFalse(decoded.autoConcurrencyActivated)
    }

    func testMigrationDecodeDefaultsPlanRefreshErrorToNil() throws {
        let current = StoredProfileInsight.empty()
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "planError")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StoredProfileInsight.self, from: legacy)

        XCTAssertNil(decoded.planError)
    }

    func testQuotaWireMappingIsExplicitAndConservative() {
        let positive = AgentQuotaSnapshot(total: 3, membership: 1, recharge: 1, modelCard: 1, free: 0, fetchedAt: .now, stale: true)
        let zero = AgentQuotaSnapshot(total: 0, membership: 0, recharge: 0, modelCard: 0, free: 0, fetchedAt: .now, stale: true)
        XCTAssertEqual(AccountQuotaState.zero.inventoryValue(snapshot: zero), "exhausted")
        XCTAssertEqual(AccountQuotaState.available.inventoryValue(snapshot: positive), "available")
        XCTAssertEqual(AccountQuotaState.webAuthRequired.inventoryValue(snapshot: nil), "webAuthRequired")
        XCTAssertEqual(AccountQuotaState.stale.inventoryValue(snapshot: positive), "available")
        XCTAssertEqual(AccountQuotaState.stale.inventoryValue(snapshot: zero), "exhausted")
        XCTAssertEqual(AccountQuotaState.stale.inventoryValue(snapshot: nil), "unknown")
        XCTAssertEqual(AccountQuotaState.refreshing.inventoryValue(snapshot: nil), "unknown")
        XCTAssertEqual(AccountQuotaState.identityMismatch.inventoryValue(snapshot: nil), "unknown")
        XCTAssertEqual(AccountQuotaState.unknown.inventoryValue(snapshot: nil), "unknown")
    }
}
