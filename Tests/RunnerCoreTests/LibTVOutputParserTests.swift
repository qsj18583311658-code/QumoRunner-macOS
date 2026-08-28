import Testing
@testable import RunnerCore

@Suite struct LibTVOutputParserTests {
    @Test
    func testRemoteTaskIDCanBeExtractedFromLiveRunLineWithoutTerminalSnapshot() {
        #expect(
            LibTVOutputParser.remoteTaskID(
                in: "[run] task=20260827145603757415890 status=1 progress=80%"
            ) == "20260827145603757415890"
        )
    }

    @Test
    func testNumericSuccessUsesNestedTaskInfoAndOutput() throws {
        let snapshot = try LibTVOutputParser.parse("""
            {"data":{"taskInfo":{"taskId":"task-42","status":2,"loading":false,"progressPercent":100,"outputs":[{"url":"https://cdn.test/a.png"}]}}}
            """)
        #expect(snapshot.taskID == "task-42")
        #expect(snapshot.state == .succeeded)
        #expect(snapshot.progressPercent == 100)
        #expect(snapshot.outputs == ["https://cdn.test/a.png"])
    }

    @Test
    func testNumericSuccessUsesSiblingNodeURL() throws {
        let snapshot = try LibTVOutputParser.parse("""
            {"data":{"url":["https://cdn.test/video.mp4"],"taskInfo":{"taskId":"task-video","status":2,"loading":false,"progressPercent":100}}}
            """)
        #expect(snapshot.taskID == "task-video")
        #expect(snapshot.state == .succeeded)
        #expect(snapshot.outputs == ["https://cdn.test/video.mp4"])
    }

    @Test
    func testNumericAndEnglishRunningStates() throws {
        let numeric = try LibTVOutputParser.parse(
            #"{"data":{"taskInfo":{"status":1,"loading":true,"progressPercent":25}}}"#
        )
        let english = try LibTVOutputParser.parse(
            #"{"data":{"taskInfo":{"status":"in_progress","progressPercent":50}}}"#
        )
        #expect(numeric.state == .running)
        #expect(english.state == .running)
    }

    @Test
    func testFailureAndCancellation() throws {
        #expect(try state(for: "failed") == .failed)
        #expect(try state(for: "cancelled") == .cancelled)
        #expect(try state(for: 3) == .failed)
    }

    @Test
    func testStderrProgressLinePreservesFailedRemoteTask() throws {
        let snapshot = try LibTVOutputParser.parse(
            "[run] task=20260827105303945725890 status=3 progress=100%"
        )
        #expect(snapshot.taskID == "20260827105303945725890")
        #expect(snapshot.state == .failed)
        #expect(snapshot.progressPercent == 100)
    }

    @Test
    func testFailureReasonIsPreserved() throws {
        let snapshot = try LibTVOutputParser.parse(
            #"{"data":{"taskInfo":{"taskId":"failed-1","status":3,"progressPercent":100,"failedReason":"生成失败，积分将返还"}}}"#
        )
        #expect(snapshot.state == .failed)
        #expect(snapshot.failureReason == "生成失败，积分将返还")
    }

    @Test
    func testUnknownStatusRequiresReview() throws {
        #expect(try state(for: "mysterious_terminal") == .needsReview)
        #expect(try state(for: 99) == .needsReview)
    }

    @Test
    func testStatusTwoWithoutOutputAtCompletionRequiresReview() throws {
        let snapshot = try LibTVOutputParser.parse(
            #"{"data":{"taskInfo":{"status":2,"loading":false,"progressPercent":100}}}"#
        )
        #expect(snapshot.state == .needsReview)
    }

    @Test
    func testMultilineLogsAndMultipleObjectsSelectTaskInfo() throws {
        let snapshot = try LibTVOutputParser.parse("""
            libtv: starting {not-json}
            {"event":"login","message":"brace in string: { ok }"}
            progress log
            {
              "data": {
                "taskInfo": {
                  "taskId": "multi",
                  "status": "succeeded",
                  "progressPercent": 100,
                  "output": {"url": "https://cdn.test/multi.mp4"}
                }
              }
            }
            """)
        #expect(snapshot.taskID == "multi")
        #expect(snapshot.state == .succeeded)
    }

    @Test
    func testMalformedJSON() {
        #expect(throws: LibTVParseError.malformedJSON) {
            try LibTVOutputParser.parse("log { definitely broken")
        }
    }

    private func state(for status: String) throws -> RunnerJobState {
        try LibTVOutputParser.parse(
            "{\"data\":{\"taskInfo\":{\"status\":\"\(status)\"}}}"
        ).state
    }

    private func state(for status: Int) throws -> RunnerJobState {
        try LibTVOutputParser.parse(
            "{\"data\":{\"taskInfo\":{\"status\":\(status)}}}"
        ).state
    }
}
