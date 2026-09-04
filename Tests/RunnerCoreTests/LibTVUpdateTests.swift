import Foundation
import Testing
@testable import RunnerCore

@Suite struct LibTVUpdateTests {
    @Test func numericVersionsAndNoImplicitDowngrade() {
        #expect(LibTVReleaseVersion.isNewer("1.10.0", than: "1.9.9"))
        #expect(!LibTVReleaseVersion.isNewer("1.0.2", than: "1.1.3"))
        #expect(!LibTVReleaseVersion.isNewer("1.1.3", than: "1.1.3"))
        var state = LibTVUpdateStatus()
        state.channelVersion = "1.0.2"
        #expect(state.availableVersion(current: "1.1.3") == nil)
        state.channelVersion = "1.2.0"
        state.checkError = "offline"
        #expect(state.availableVersion(current: "1.1.3") == "1.2.0")
    }

    @Test func manifestRejectsInvalidAndUnsafeVersions() throws {
        #expect(try LibTVUpdateClient.parseManifest(Data(#"{"version":"1.1.3"}"#.utf8)) == "1.1.3")
        for version in ["../evil", "1.2.3?x", "01.2.3", "1.2", "1.2.3-beta", "99999999999999999999999.1.2"] {
            #expect(throws: (any Error).self) { try LibTVReleaseVersion.release(version) }
            let data = try JSONSerialization.data(withJSONObject: ["version": version])
            #expect(throws: (any Error).self) { try LibTVUpdateClient.parseManifest(data) }
        }
        #expect(throws: (any Error).self) { try LibTVUpdateClient.parseManifest(Data("<html>down</html>".utf8)) }
    }

    @Test func websiteUsesOnlyOfficialCLIDownloadLinks() throws {
        let html = """
        <h1>LibTV CLI</h1><script>version='99.0.0'</script>
        <a href="https://evil.example/cli/88.0.0/libtv-macos-arm64.zip">bad</a>
        <a href="https://liblibai-web-static.liblib.cloud/cli/1.9.0/libtv-macos-arm64.zip">old</a>
        <a href="https://liblibai-web-static.liblib.cloud/cli/1.10.0/libtv-macos-arm64.zip">new</a>
        """
        #expect(try LibTVUpdateClient.parseWebsite(Data(html.utf8)) == "1.10.0")
        let currentPage = "<h1>LibTV CLI</h1>curl https://liblibai-web-static.liblib.cloud/cli/latest/install-libtv-cli.sh"
        #expect(try LibTVUpdateClient.parseWebsite(Data(currentPage.utf8)) == nil)
        #expect(throws: (any Error).self) { try LibTVUpdateClient.parseWebsite(Data("Bad gateway".utf8)) }
    }

    @Test func approvedDownloadLocationCannotBeOverridden() throws {
        let release = try LibTVReleaseVersion.release("1.1.3")
        #expect(release.archiveURL.absoluteString == "https://liblibai-web-static.liblib.cloud/cli/1.1.3/libtv-macos-arm64.zip")
    }

    @Test func nightlyWindowUsesLocalDayAndDoesNotCatchUp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        #expect(!LibTVMaintenanceWindow.contains(date(4, 2, 59), calendar: calendar))
        #expect(LibTVMaintenanceWindow.contains(date(4, 3), calendar: calendar))
        #expect(!LibTVMaintenanceWindow.contains(date(4, 4), calendar: calendar))
        #expect(LibTVMaintenanceWindow.shouldAttempt(now: date(4, 3), lastAttempt: date(3, 3), checkedAt: date(4, 2), calendar: calendar))
        #expect(!LibTVMaintenanceWindow.shouldAttempt(now: date(4, 3, 30), lastAttempt: date(4, 3), checkedAt: date(4, 2), calendar: calendar))
        #expect(!LibTVMaintenanceWindow.shouldAttempt(now: date(4, 3), lastAttempt: nil, checkedAt: date(3, 12), calendar: calendar))
        #expect(!LibTVMaintenanceWindow.shouldAttempt(now: date(4, 9), lastAttempt: nil, checkedAt: date(4, 8), calendar: calendar))
    }

    @Test func timeoutJoinsCancelledWorkBeforeReturning() async throws {
        actor State {
            var finished = false
            var published = false
            func finish() { finished = true }
            func publish() { published = true }
        }
        let state = State()
        await #expect(throws: LibTVUpdateError.self) {
            try await LibTVUpdateDeadline.run(for: .milliseconds(20)) {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { await state.finish(); throw error }
                await state.publish()
            }
        }
        #expect(await state.finished)
        #expect(!(await state.published))
        let result = try await LibTVUpdateDeadline.run(for: .seconds(1)) { 42 }
        #expect(result == 42)
    }

}
