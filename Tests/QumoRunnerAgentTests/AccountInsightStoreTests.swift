import Foundation
import XCTest

final class AccountInsightStoreTests: XCTestCase {
    func testQuotaAndPlanSurviveStoreReloadWithProtectedPermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "account-insight-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AccountInsightStore(root: root)
        try await store.update("profile-a") { insight in
            insight.quota = StoredQuota(
                state: .available,
                snapshot: AgentQuotaSnapshot(
                    total: 123,
                    membership: 80,
                    recharge: 30,
                    modelCard: 10,
                    free: 3,
                    fetchedAt: fetchedAt,
                    stale: false
                ),
                error: nil,
                observedAt: fetchedAt
            )
            insight.plan = AgentPlanSnapshot(
                name: "Pro",
                detectedMaxConcurrency: 4,
                unlimitedConcurrency: false,
                fetchedAt: fetchedAt,
                stale: false,
                detectionNote: "页面明示并发"
            )
            insight.autoConcurrencyActivated = true
        }

        let reloaded = AccountInsightStore(root: root)
        let profile = await reloaded.profile("profile-a")
        XCTAssertEqual(profile.quota.state, .available)
        XCTAssertEqual(profile.quota.snapshot?.total, 123)
        XCTAssertEqual(profile.quota.snapshot?.fetchedAt, fetchedAt)
        XCTAssertEqual(profile.plan?.name, "Pro")
        XCTAssertEqual(profile.plan?.detectedMaxConcurrency, 4)
        XCTAssertTrue(profile.autoConcurrencyActivated)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appending(path: "account-insights.json").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testFailedRefreshStateAndRecentStaleSnapshotSurviveReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "account-insight-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let store = AccountInsightStore(root: root)
        try await store.update("profile-b") { insight in
            insight.quota = StoredQuota(
                state: .stale,
                snapshot: AgentQuotaSnapshot(
                    total: 9,
                    membership: 4,
                    recharge: 3,
                    modelCard: 1,
                    free: 1,
                    fetchedAt: fetchedAt,
                    stale: true
                ),
                error: "网络暂时不可用",
                observedAt: fetchedAt.addingTimeInterval(30)
            )
            insight.planError = "套餐页加载失败"
        }

        let reloaded = AccountInsightStore(root: root)
        let profile = await reloaded.profile("profile-b")
        XCTAssertEqual(profile.quota.state, .stale)
        XCTAssertEqual(profile.quota.snapshot?.total, 9)
        XCTAssertTrue(profile.quota.snapshot?.stale == true)
        XCTAssertEqual(profile.quota.error, "网络暂时不可用")
        XCTAssertEqual(profile.planError, "套餐页加载失败")
    }

    func testModelApprovalUsesSchemaHashCompareAndSet() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "account-insight-cas-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountInsightStore(root: root)
        let pendingItem = catalogItem(schema: "schema-a", state: .pending)
        try await store.update("profile-a") { $0.catalog = [pendingItem] }

        try await store.approve(
            profileRef: "profile-a",
            modelRef: "image-gen",
            expectedSchemaHash: "schema-a",
            approved: true
        )
        let approvedProfile = await store.profile("profile-a")
        XCTAssertEqual(approvedProfile.catalog[0].approvalState, .approved)

        try await store.update("profile-a") { profile in
            profile.catalog[0].schemaHash = "schema-b"
            profile.catalog[0].approvalState = .changed
            profile.catalog[0].approved = false
        }
        do {
            try await store.approve(
                profileRef: "profile-a",
                modelRef: "image-gen",
                expectedSchemaHash: "schema-a",
                approved: true
            )
            XCTFail("旧 schema 不应写入审批状态")
        } catch AccountInsightStoreError.modelSchemaChanged {
            let changedProfile = await store.profile("profile-a")
            XCTAssertEqual(changedProfile.catalog[0].approvalState, .changed)
        }
    }

    func testCatalogReconcileUsesLatestManualApprovalStateAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "account-insight-reconcile-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountInsightStore(root: root)
        let approvedItem = catalogItem(schema: "schema-a", state: .approved)
        try await store.update("profile-a") { $0.catalog = [approvedItem] }

        try await store.approve(
            profileRef: "profile-a",
            modelRef: "image-gen",
            expectedSchemaHash: "schema-a",
            approved: false
        )
        try await store.reconcileCatalog(profileRef: "profile-a", incoming: [candidate(schema: "schema-a")])
        var current = await store.profile("profile-a").catalog[0]
        XCTAssertEqual(current.approvalState, .pending)
        XCTAssertFalse(current.approved)

        try await store.approve(
            profileRef: "profile-a",
            modelRef: "image-gen",
            expectedSchemaHash: "schema-a",
            approved: true
        )
        try await store.reconcileCatalog(profileRef: "profile-a", incoming: [candidate(schema: "schema-b")])
        current = await store.profile("profile-a").catalog[0]
        XCTAssertEqual(current.approvalState, .changed)
        XCTAssertFalse(current.approved)
    }

    private func catalogItem(schema: String, state: ModelApprovalState) -> StoredCatalogItem {
        StoredCatalogItem(
            modelRef: "image-gen",
            displayName: "Image Gen",
            modalities: ["image"],
            summaryHash: "summary",
            schemaHash: schema,
            approvalState: state,
            approved: state == .approved,
            missingRefreshCount: 0
        )
    }

    private func candidate(schema: String) -> CatalogCandidate {
        CatalogCandidate(
            modelRef: "image-gen",
            displayName: "Image Gen",
            modalities: ["image"],
            summaryHash: "summary",
            schemaHash: schema
        )
    }
}
