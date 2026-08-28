import Foundation
import XCTest

final class AgentProfileRegistryTests: XCTestCase {
    func testUnresolvedAccountCannotBecomeHealthy() throws {
        try withRegistry { registry, root in
            let prepared = try registry.prepare(profileRef: "pending-profile")
            XCTAssertEqual(prepared.0.accountRef, "pending")
            XCTAssertFalse(prepared.0.healthy)

            XCTAssertThrowsError(
                try registry.markLogin(
                    profileRef: prepared.0.profileRef,
                    accountRef: "pending",
                    displayName: "登录中…",
                    capabilities: ["image"],
                    healthy: true
                )
            ) { error in
                XCTAssertEqual(error as? AgentProfileRegistryError, .unresolvedAccount)
            }

            let reloaded = AgentProfileRegistry(root: root)
            let profile = try XCTUnwrap(reloaded.all().first)
            XCTAssertEqual(profile.accountRef, "pending")
            XCTAssertFalse(profile.healthy)
            XCTAssertTrue(profile.capabilities.isEmpty)
        }
    }

    func testDuplicateAccountRefIsRejectedWithoutMutatingPendingProfile() throws {
        try withRegistry { registry, root in
            let first = try registry.prepare(profileRef: "profile-one").0
            try registry.markLogin(
                profileRef: first.profileRef,
                accountRef: "account-5001033",
                displayName: "趣摩AI",
                capabilities: ["image"],
                healthy: true
            )

            let duplicate = try registry.prepare(profileRef: "profile-two").0
            XCTAssertThrowsError(
                try registry.markLogin(
                    profileRef: duplicate.profileRef,
                    accountRef: "account-5001033",
                    displayName: "重复账号",
                    capabilities: ["video"],
                    healthy: true
                )
            ) { error in
                XCTAssertEqual(
                    error as? AgentProfileRegistryError,
                    .duplicateAccount(accountRef: "account-5001033", existingProfileRef: first.profileRef)
                )
            }

            let reloaded = AgentProfileRegistry(root: root).all()
            let existing = try XCTUnwrap(reloaded.first(where: { $0.profileRef == first.profileRef }))
            let rejected = try XCTUnwrap(reloaded.first(where: { $0.profileRef == duplicate.profileRef }))
            XCTAssertEqual(existing.accountRef, "account-5001033")
            XCTAssertTrue(existing.healthy)
            XCTAssertEqual(rejected.accountRef, "pending")
            XCTAssertFalse(rejected.healthy)
            XCTAssertTrue(rejected.capabilities.isEmpty)
        }
    }

    func testDiscardPendingRemovesRegistryEntryAndTemporaryProfileDirectory() throws {
        try withRegistry { registry, root in
            let prepared = try registry.prepare(profileRef: "temporary-profile")
            let marker = prepared.1.home.appending(path: "temporary-login-marker")
            try Data("temporary".utf8).write(to: marker)
            XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.1.root.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

            try registry.discardPending(profileRef: prepared.0.profileRef)

            XCTAssertTrue(registry.all().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.1.root.path))
            XCTAssertTrue(AgentProfileRegistry(root: root).all().isEmpty)
        }
    }

    func testDiscardPendingAlsoCleansChromeDirectoryRecreatedAfterRollback() throws {
        try withRegistry { registry, root in
            let prepared = try registry.prepare(profileRef: "recreated-profile")
            try registry.discardPending(profileRef: prepared.0.profileRef)

            let recreated = prepared.1.root.appending(path: "chrome-auth", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: recreated, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recreated.path))

            try registry.discardPending(profileRef: prepared.0.profileRef)

            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.1.root.path))
        }
    }

    private func withRegistry(
        _ body: (AgentProfileRegistry, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agent-profile-registry-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AgentProfileRegistry(root: root), root)
    }
}
