import XCTest

final class QuotaStateCopyTests: XCTestCase {
    func testEveryPersistedQuotaStateHasDistinctUserFacingCopy() {
        let titles: [QuotaState: String] = [
            .unknown: "积分未知",
            .refreshing: "积分刷新中",
            .available: "积分可用",
            .zero: "积分为零",
            .stale: "积分已陈旧",
            .webAuthRequired: "需 Chrome 授权",
            .identityMismatch: "授权身份不一致",
        ]

        for (state, expected) in titles {
            XCTAssertEqual(state.title, expected)
        }
        XCTAssertEqual(Set(titles.values).count, titles.count)
    }

    func testWireValuesDecodeIntoTheIntendedUIStates() throws {
        for state in [QuotaState.unknown, .refreshing, .available, .zero, .stale, .webAuthRequired, .identityMismatch] {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(QuotaState.self, from: data), state)
        }
        XCTAssertEqual(QuotaState.webAuthRequired.rawValue, "web_auth_required")
        XCTAssertEqual(QuotaState.identityMismatch.rawValue, "identity_mismatch")
    }

    func testAccountInsightStatusPrioritizesRefreshAuthFailureAndSuccess() {
        XCTAssertEqual(account(refreshing: true, quotaState: .available, error: "old").insightStatus, .refreshing)
        XCTAssertEqual(account(quotaState: .webAuthRequired).insightStatus, .webLoginRequired)
        XCTAssertEqual(account(quotaState: .identityMismatch).insightStatus, .webLoginRequired)
        XCTAssertEqual(account(quotaState: .unknown, error: "parse failed").insightStatus, .failed)
        XCTAssertEqual(account(quotaState: .available).insightStatus, .succeeded)
        XCTAssertEqual(account(quotaState: .zero).insightStatus, .succeeded)
        XCTAssertEqual(account(quotaState: .unknown).insightStatus, .neverRefreshed)
    }

    func testGlobalModelCatalogDeduplicatesAcrossProfilesAndMergesModalities() {
        let first = account(
            id: "profile-a",
            quotaState: .available,
            models: [model(ref: "shared-model", name: "Shared", modalities: ["image"], schema: "schema-a", state: .approved)]
        )
        let second = account(
            id: "profile-b",
            quotaState: .available,
            models: [model(ref: "shared-model", name: "Shared", modalities: ["video"], schema: "schema-a", state: .pending)]
        )

        let result = RunnerGlobalModelCatalogItem.aggregate(accounts: [first, second])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].modelRef, "shared-model")
        XCTAssertEqual(result[0].modalities, ["image", "video"])
        XCTAssertEqual(result[0].occurrences.count, 2)
        XCTAssertEqual(result[0].approvedOccurrenceCount, 1)
        XCTAssertEqual(result[0].approvalState, .pending)
    }

    func testGlobalModelCatalogReportsSchemaConflictAndChangedState() {
        let accounts = [
            account(id: "profile-a", quotaState: .available, models: [model(ref: "m", schema: "schema-a", state: .approved)]),
            account(id: "profile-b", quotaState: .available, models: [model(ref: "m", schema: "schema-b", state: .changed)]),
        ]

        let item = try! XCTUnwrap(RunnerGlobalModelCatalogItem.aggregate(accounts: accounts).first)
        XCTAssertTrue(item.hasSchemaConflict)
        XCTAssertEqual(item.schemaVariantCount, 2)
        XCTAssertEqual(item.approvalState, .changed)
    }

    func testGlobalModelCatalogExcludesPendingProfileAndKeepsRemovedState() {
        let pending = account(
            id: "pending-profile",
            accountRef: "pending",
            quotaState: .unknown,
            models: [model(ref: "ignored", schema: "schema", state: .pending)]
        )
        let removed = account(
            id: "profile-a",
            quotaState: .available,
            models: [model(ref: "removed", schema: "schema", state: .removed)]
        )

        let result = RunnerGlobalModelCatalogItem.aggregate(accounts: [pending, removed])
        XCTAssertEqual(result.map(\.modelRef), ["removed"])
        XCTAssertEqual(result[0].approvalState, .removed)
        XCTAssertTrue(result[0].activeOccurrences.isEmpty)
    }

    func testBatchPlanFreezesOnlyEligibleProfileSchemaHashes() {
        let accounts = [
            account(id: "profile-a", quotaState: .available, models: [model(ref: "shared", schema: "schema-a", state: .approved)]),
            account(id: "profile-b", quotaState: .available, models: [model(ref: "shared", schema: "schema-b", state: .pending)]),
            account(id: "profile-c", quotaState: .available, models: [model(ref: "removed", schema: "schema-c", state: .removed)]),
        ]
        let models = RunnerGlobalModelCatalogItem.aggregate(accounts: accounts)

        let enablePlan = RunnerModelBatchPlan.make(models: models, approved: true)
        XCTAssertEqual(enablePlan.modelCount, 1)
        XCTAssertEqual(enablePlan.configurationCount, 1)
        XCTAssertEqual(enablePlan.schemaConflictCount, 1)
        XCTAssertEqual(enablePlan.expectedSchemaHashesByModel["shared"], ["profile-b": "schema-b"])

        let disablePlan = RunnerModelBatchPlan.make(models: models, approved: false)
        XCTAssertEqual(disablePlan.modelCount, 1)
        XCTAssertEqual(disablePlan.configurationCount, 1)
        XCTAssertEqual(disablePlan.expectedSchemaHashesByModel["shared"], ["profile-a": "schema-a"])
        XCTAssertNil(disablePlan.expectedSchemaHashesByModel["removed"])
    }

    private func account(
        id: String = "profile-a",
        accountRef: String = "account-a",
        refreshing: Bool = false,
        quotaState: QuotaState,
        error: String? = nil,
        models: [RunnerModelCatalogItem] = []
    ) -> RunnerAccount {
        RunnerAccount(
            id: id,
            displayName: "Test",
            accountRef: accountRef,
            enabled: true,
            healthy: true,
            authExpired: false,
            capabilities: [],
            currentJobTitle: nil,
            currentJobCount: 0,
            lastCheckedAt: nil,
            insightError: error,
            insightRefreshing: refreshing,
            autoConcurrencyActivated: false,
            quotaState: quotaState,
            quota: nil,
            plan: nil,
            detectedMaxConcurrency: nil,
            effectiveMaxConcurrency: 1,
            catalogRevision: nil,
            catalogRefreshedAt: nil,
            catalogError: nil,
            catalogRefreshing: false,
            models: models
        )
    }

    private func model(
        ref: String,
        name: String = "Model",
        modalities: [String] = ["image"],
        schema: String,
        state: ModelApprovalState
    ) -> RunnerModelCatalogItem {
        RunnerModelCatalogItem(
            modelRef: ref,
            displayName: name,
            modalities: modalities,
            summaryHash: "summary-\(schema)",
            schemaHash: schema,
            approvalState: state,
            approved: state == .approved,
            missingRefreshCount: state == .removed ? 2 : 0
        )
    }
}
