import Foundation
import Testing
@testable import RunnerCore

@Suite struct RunnerAPITests {
    @Test
    func testEveryEndpointIsUnderCanvasV1Prefix() {
        let configuration = RunnerAPIConfiguration(serverURL: URL(string: "https://canvas.test/root")!)
        #expect(configuration.url(path: "runners/id/claim").absoluteString ==
            "https://canvas.test/root/api/canvas/v1/runners/id/claim")
    }

    @Test
    func testInputDownloadURLAllowsOnlyHTTPSOrExactHTTPLoopback() {
        for value in [
            "https://objects.example.test/input",
            "http://localhost:9000/bucket/input",
            "http://127.0.0.1:9000/bucket/input",
            "http://[::1]:9000/bucket/input",
        ] {
            #expect(RunnerAPIClient.isAllowedInputDownloadURL(URL(string: value)!))
        }
        for value in [
            "http://objects.example.test/input",
            "http://localhost.example.test/input",
            "http://127.0.0.2/input",
            "http://192.168.1.10/input",
            "file:///tmp/input",
        ] {
            #expect(!RunnerAPIClient.isAllowedInputDownloadURL(URL(string: value)!))
        }
    }

    @Test
    func testUnifiedResponseDecodesData() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            UnifiedResponse<ExchangeRunnerPairingResponse>.self,
            from: Data(#"{"code":0,"message":"ok","data":{"runner_id":"r1","device_token":"secret","display_name":"Mini","workspace_id":"w1"},"request_id":"req1"}"#.utf8)
        )
        #expect(envelope.code == 0)
        #expect(envelope.data.runnerID == "r1")
        #expect(envelope.data.workspaceID == "w1")
    }

    @Test
    func testPairingBodiesMatchServerContract() throws {
        let encoder = JSONEncoder()
        let create = try JSONSerialization.jsonObject(with: encoder.encode(
            CreateRunnerPairingRequest(displayName: "Studio Mini")
        )) as? [String: Any]
        #expect(create?["display_name"] as? String == "Studio Mini")
        #expect(create?["expires_in_seconds"] == nil)

        let exchange = try JSONSerialization.jsonObject(with: encoder.encode(
            ExchangeRunnerPairingRequest(
                pairingCode: "ABC123",
                displayName: "Studio Mini",
                hostname: "runner.local",
                version: "1.0.0",
                capabilities: ["image"]
            )
        )) as? [String: Any]
        #expect(exchange?["pairing_code"] as? String == "ABC123")
        #expect(exchange?["hostname"] as? String == "runner.local")
        #expect(exchange?["device_name"] == nil)
    }

    @Test
    func testCommandAndAcknowledgementKeysMatchContract() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let command = try decoder.decode(
            RunnerControlCommand.self,
            from: Data(#"{"id":"c1","command":"pause","payload":{},"created_at":"2026-08-24T00:00:00Z"}"#.utf8)
        )
        #expect(command.kind == .pause)

        let encoder = JSONEncoder()
        let ack = try JSONSerialization.jsonObject(with: encoder.encode(
            CommandAcknowledgement(status: "failed", detail: "bad command")
        )) as? [String: Any]
        #expect(ack?["status"] as? String == "failed")
        #expect(ack?["detail"] as? String == "bad command")
        #expect(ack?["message"] == nil)
    }

    @Test
    func testHeartbeatDecodesServiceLevelCommands() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            UnifiedResponse<RunnerHeartbeatResponse>.self,
            from: Data(#"{"code":0,"message":"ok","data":{"ok":true,"server_time":"2026-08-24T00:00:00Z","lease_seconds":60,"renewed_job_ids":[],"commands":[{"id":"c1","command":"refresh_profiles","payload":{},"created_at":"2026-08-24T00:00:00Z"},{"id":"c2","command":"refresh_inventory","payload":{},"created_at":"2026-08-24T00:00:01Z"},{"id":"c3","command":"diagnostics","payload":{},"created_at":"2026-08-24T00:00:02Z"}]},"request_id":"req-heartbeat"}"#.utf8)
        )

        #expect(envelope.data.commands.map(\.kind) == [
            .refreshProfiles,
            .refreshInventory,
            .diagnostics,
        ])
    }

    @Test
    func testHeartbeatEncodesGlobalRemoteJobLimit() throws {
        let data = try JSONEncoder().encode(RunnerHeartbeatRequest(
            state: .busy,
            hostname: "runner.local",
            version: "1.0.0",
            capabilities: ["image"],
            activeJobIDs: ["job-1"],
            globalMaxConcurrency: 4
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["global_max_concurrency"] as? Int == 4)
    }

    @Test
    func testDeviceModelApprovalPinsTheReviewedSchema() throws {
        let hash = String(repeating: "a", count: 64)
        let data = try JSONEncoder().encode(ProfileModelApprovalRequest(
            approved: true,
            schemaHash: hash
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["approved"] as? Bool == true)
        #expect(object["schema_hash"] as? String == hash)

        let response = try JSONDecoder().decode(
            ProfileModelApprovalResponse.self,
            from: Data(#"{"model_ref":"vendor/image/v2","schema_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","approval_state":"approved"}"#.utf8)
        )
        #expect(response.modelRef == "vendor/image/v2")
        #expect(response.approvalState == "approved")
    }

    @Test
    func testRunnerJobAcronymKeysDecodeExactly() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(RunnerJob.self, from: Data(#"{"id":"j","canvas_key":"c","source_node_id":"s","result_node_id":"r","idempotency_key":"i","capability":"image","base_schema_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","patch_version":2,"effective_schema_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","payload":{},"status":"leased","runner_id":"runner","execution_profile_ref":"profile","remote_task_id":"remote","result":null,"error":null,"result_artifact_id":"artifact","lease_expires_at":"2026-08-24T00:01:00Z","created_at":"2026-08-24T00:00:00Z","updated_at":"2026-08-24T00:00:00Z"}"#.utf8))
        #expect(job.runnerID == "runner")
        #expect(job.sourceNodeID == "s")
        #expect(job.remoteTaskID == "remote")
        #expect(job.resultArtifactID == "artifact")
        #expect(job.patchVersion == 2)
        #expect(job.effectiveSchemaHash == String(repeating: "b", count: 64))
    }

    @Test
    func testDynamicProfileAndInventoryKeysMatchContract() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profile = RunnerProfile(
            profileRef: "profile-a",
            accountRef: "account-a",
            displayName: "Studio",
            detectedMaxConcurrency: 4,
            maxConcurrency: 3,
            planName: "Pro",
            quotaState: "available",
            catalogRevision: "catalog-1"
        )
        let encodedProfile = try JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any]
        #expect(encodedProfile?["detected_max_concurrency"] as? Int == 4)
        #expect(encodedProfile?["max_concurrency"] as? Int == 3)
        #expect(encodedProfile?["quota_state"] as? String == "available")

        let request = ProfileInventoryRequest(
            inventoryRevision: "inventory-1",
            catalogRevision: "catalog-1",
            quota: .init(state: "available", observedAt: Date(timeIntervalSince1970: 0), totalBalance: "100"),
            plan: .init(observedAt: Date(timeIntervalSince1970: 0), planName: "Pro", detectedMaxConcurrency: 4, maxConcurrency: 3),
            models: [.init(modelRef: "image-pro", displayName: "Image Pro", modality: "image", summaryHash: String(repeating: "a", count: 64), schemaHash: String(repeating: "b", count: 64), capabilities: ["text-to-image"])]
        )
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        #expect(encoded?["inventory_revision"] as? String == "inventory-1")
        let quota = encoded?["quota"] as? [String: Any]
        #expect(quota?["total_balance"] as? String == "100")
        let models = encoded?["models"] as? [[String: Any]]
        #expect(models?.first?["model_ref"] as? String == "image-pro")
    }

    @Test
    func inventoryDecodesRequiredSchemaUploadsAndUploadKeepsFullDocument() throws {
        let hash = String(repeating: "a", count: 64)
        let response = try JSONDecoder().decode(
            ProfileInventoryResponse.self,
            from: Data("""
            {
              "runner_id":"runner",
              "profile_ref":"profile",
              "inventory_revision":"revision",
              "idempotent":false,
              "max_concurrency":2,
              "required_schema_uploads":[{"model_ref":"video/model","schema_hash":"\(hash)"}]
            }
            """.utf8)
        )
        #expect(response.requiredSchemaUploads == [RequiredSchemaUpload(modelRef: "video/model", schemaHash: hash)])

        let document: JSONPayloadValue = .object([
            "modelKey": .string("video/model"),
            "modality": .string("video"),
            "schema": .object([
                "properties": .object(["duration": .object(["min": .number(4), "max": .number(15)])]),
                "config": .object(["settings": .array([.string("duration")])]),
                "rules": .array([]),
            ]),
        ])
        let request = ProfileModelSchemaUploadRequest(
            modelRef: "video/model",
            schemaHash: try CanonicalJSON.sha256(document),
            schema: document
        )
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let schema = try #require(encoded["schema"] as? [String: Any])
        #expect(schema["modelKey"] as? String == "video/model")
        #expect((schema["schema"] as? [String: Any])?["rules"] is [Any])
    }

    @Test
    func inventoryRevisionPinsTheEntireSubmittedContent() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = ProfileQuotaSnapshot(state: "available", observedAt: observedAt, totalBalance: "10")
        let model = ProfileModelInventory(
            modelRef: "lib-image-2",
            displayName: "Lib Image",
            modality: "image",
            summaryHash: String(repeating: "a", count: 64),
            schemaHash: String(repeating: "b", count: 64),
            capabilities: ["image"]
        )
        let first = ProfileInventoryRequest.contentRevision(
            catalogRevision: "catalog-a",
            quota: quota,
            plan: nil,
            models: [model]
        )
        let repeated = ProfileInventoryRequest.contentRevision(
            catalogRevision: "catalog-a",
            quota: quota,
            plan: nil,
            models: [model]
        )
        let refreshedQuota = ProfileQuotaSnapshot(
            state: "available",
            observedAt: observedAt.addingTimeInterval(1),
            totalBalance: "10"
        )
        let changed = ProfileInventoryRequest.contentRevision(
            catalogRevision: "catalog-a",
            quota: refreshedQuota,
            plan: nil,
            models: [model]
        )

        #expect(first == repeated)
        #expect(first != changed)
    }
}
