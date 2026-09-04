import Foundation
import Testing
@testable import RunnerCore

@Suite struct GenerationSpecTests {
    @Test
    func canonicalJSONMatchesServerNumberEncoding() throws {
        let value: JSONPayloadValue = .object([
            "integral": .number(1),
            "fractional": .number(0.5),
            "nested": .object([
                "minimum": .number(-12),
                "maximum": .number(2),
                "step": .number(0.01),
            ]),
        ])

        #expect(String(decoding: try CanonicalJSON.data(value), as: UTF8.self) == #"{"fractional":0.5,"integral":1,"nested":{"maximum":2,"minimum":-12,"step":0.01}}"#)
        #expect(try CanonicalJSON.sha256(value) == "48797ef15da6504d4eefa64c366c354fc5bbfadcb5dd7ae4e5ba7f5aa9070287")
    }

    @Test
    func groupPreparationUsesExplicitCreateSubcommand() {
        #expect(LibTVPreparationArgumentsBuilder.createGroup(
            name: "qumo-job-123",
            projectUUID: "project-uuid"
        ) == [
            "group", "create", "qumo-job-123", "--project", "project-uuid",
        ])
    }

    @Test
    func claimPayloadIsDirectSpecAndLegacyArgumentsAreRejected() throws {
        let hash = String(repeating: "a", count: 64)
        let spec = LibTVGenerationSpecV1(
            modality: .image,
            modelRef: "model/image",
            effectiveSchemaHash: hash,
            prompt: "hello"
        )
        let payload = try payload(spec)
        #expect(try LibTVGenerationSpecV1.decode(payload: payload) == spec)
        #expect(throws: (any Error).self) {
            try LibTVGenerationSpecV1.decode(payload: ["spec": .object(payload)])
        }
        #expect(throws: LibTVCommandBuilderError.structuredPreparerRequired) {
            try RejectingLibTVCommandBuilder().submissionArguments(for: RunnerJob(
                id: "legacy",
                payload: ["arguments": .array([.string("node"), .string("--run")])]
            ))
        }
    }

    @Test
    func validatorPinsBaseSchemaAndOnlyFlattensWhitelistedFields() throws {
        let raw: JSONPayloadValue = .object([
            "modelName": .string("Image Model"),
            "schema": .object([
                "properties": .object([
                    "count": .array([.number(1), .number(2)]),
                    "ratio": .object([
                        "enum": .array([.string("1:1"), .string("16:9")]),
                        "originalField": .string("aspectRatio"),
                    ]),
                    "quality": .object(["min": .number(1), "max": .number(4)]),
                    "modeType": .object([
                        "items": .object(["image2image": .array([.number(1), .number(2)])]),
                    ]),
                ]),
                "config": .object([
                    "settings": .array([.string("ratio")]),
                    "advancedSettings": .array([.string("quality")]),
                ]),
                "rules": .array([
                    .object(["require": .array([.string("prompt"), .string("media")]), "mode": .string("any")]),
                ]),
            ]),
        ])
        let baseHash = try CanonicalJSON.sha256(raw)
        let effectiveHash = String(repeating: "e", count: 64)
        let registry = LibTVSchemaRegistry()
        registry.replace(profileRef: "profile", schemas: [.init(
            modelRef: "model/image",
            modelName: "Image Model",
            schemaHash: baseHash,
            rawSchema: raw,
            approved: true
        )])
        let spec = LibTVGenerationSpecV1(
            modality: .image,
            modelRef: "model/image",
            effectiveSchemaHash: effectiveHash,
            count: 2,
            modeType: "image2image",
            settings: ["ratio": .string("16:9")],
            advancedSettings: ["quality": .number(4)],
            inputs: [.init(
                artifactKey: "objects/ref-1",
                kind: "image",
                role: "reference",
                order: 0,
                sha256: String(repeating: "b", count: 64)
            )]
        )
        let validated = try LibTVGenerationValidator.validate(
            job: RunnerJob(
                id: "job",
                requiredModelRef: "model/image",
                baseSchemaHash: baseHash,
                patchVersion: 1,
                effectiveSchemaHash: effectiveHash,
                payload: try payload(spec)
            ),
            profileRef: "profile",
            registry: registry
        )
        #expect(validated.modelName == "Image Model")
        #expect(validated.flattenedSettings.map(\.0) == ["aspectRatio", "quality"])

        let unknown = LibTVGenerationSpecV1(
            modality: .image,
            modelRef: "model/image",
            effectiveSchemaHash: effectiveHash,
            prompt: "hello",
            settings: ["shell": .string("whoami")]
        )
        #expect(throws: GenerationSpecError.unknownSetting("shell")) {
            try LibTVGenerationValidator.validate(
                job: RunnerJob(
                    id: "bad",
                    baseSchemaHash: baseHash,
                    patchVersion: 1,
                    effectiveSchemaHash: effectiveHash,
                    payload: try payload(unknown)
                ),
                profileRef: "profile",
                registry: registry
            )
        }
    }

    @Test
    func parameterDiagnosticsMatchServerAndExcludePromptAndArtifactIdentity() throws {
        let effectiveHash = String(repeating: "e", count: 64)
        let baseHash = String(repeating: "a", count: 64)
        let spec = LibTVGenerationSpecV1(
            modality: .video,
            modelRef: "video-model",
            effectiveSchemaHash: effectiveHash,
            prompt: "confidential campaign prompt",
            modeType: "image2video",
            settings: ["ratio": .string("16:9")],
            inputs: [.init(
                artifactKey: "private/object/key",
                kind: "image",
                role: "first_frame",
                order: 0,
                sha256: String(repeating: "b", count: 64)
            )]
        )
        let specPayload = try payload(spec)
        let serverFingerprint = try CanonicalJSON.sha256(.object(specPayload))
        let validated = ValidatedLibTVGeneration(
            spec: spec,
            modelName: "Video Model",
            flattenedSettings: [("aspectRatio", .string("16:9"))]
        )
        let diagnostics = try LibTVParameterDiagnosticsBuilder.build(
            job: RunnerJob(
                id: "job",
                baseSchemaHash: baseHash,
                patchVersion: 1,
                effectiveSchemaHash: effectiveHash,
                payload: specPayload,
                result: .object([
                    "parameter_diagnostics": .object([
                        "server_spec_fingerprint": .string(serverFingerprint),
                    ]),
                ])
            ),
            validated: validated
        )

        let object = diagnostics.objectValue ?? [:]
        #expect(object["status"] == .string("matched"))
        #expect(object["fingerprints_match"] == .bool(true))
        #expect(object["flattened_settings"]?.objectValue?["aspectRatio"] == .string("16:9"))
        #expect(object["prompt_present"] == .bool(true))
        let encoded = String(decoding: try CanonicalJSON.data(diagnostics), as: UTF8.self)
        #expect(!encoded.contains("confidential campaign prompt"))
        #expect(!encoded.contains("private/object/key"))
        #expect(!encoded.contains(String(repeating: "b", count: 64)))
    }

    @Test
    func seedanceCompliancePreflightIsDerivedFromApprovedLocalSchemaAndRedacted() throws {
        func schema(portrait: Bool = true, complianceEnabled: Bool = true) -> JSONPayloadValue {
            .object([
                "modality": .string("video"),
                "schema": .object([
                    "properties": .object([
                        "portrait": .bool(portrait),
                        "autoCompliance": .object([
                            "enable": .bool(complianceEnabled),
                            "enum": .array([.number(0), .number(1)]),
                        ]),
                        "modeType": .object([
                            "items": .object([
                                "image2video": .array([.number(1), .number(2)]),
                            ]),
                        ]),
                    ]),
                    "config": .object([
                        "advancedSettings": .object([
                            "image2video": .array([.string("autoCompliance")]),
                        ]),
                        "generateTypes": .object(["text": .number(1), "image": .number(2)]),
                    ]),
                ]),
            ])
        }

        let effectiveHash = String(repeating: "e", count: 64)
        let privateInput = LibTVGenerationInputV1(
            artifactKey: "private/customer/portrait.png",
            kind: "image",
            role: "reference",
            order: 7,
            sha256: String(repeating: "b", count: 64)
        )
        let checking = try validate(
            spec: .init(
                modality: .video,
                modelRef: "seedance-2",
                effectiveSchemaHash: effectiveHash,
                prompt: "animate",
                modeType: "image2video",
                inputs: [privateInput]
            ),
            rawSchema: schema(),
            modelName: "Seedance 2.0"
        )
        #expect(checking.seedanceCompliancePreflight.status == .checking)
        #expect(checking.seedanceCompliancePreflight.inputOrders == [7])

        let skipped = try validate(
            spec: .init(
                modality: .video,
                modelRef: "seedance-2",
                effectiveSchemaHash: effectiveHash,
                prompt: "animate",
                modeType: "image2video",
                advancedSettings: ["autoCompliance": .number(0)],
                inputs: [privateInput]
            ),
            rawSchema: schema(),
            modelName: "Seedance 2.0"
        )
        #expect(skipped.seedanceCompliancePreflight.status == .skipped)

        let skippedBoolean = try validate(
            spec: .init(
                modality: .video,
                modelRef: "seedance-2",
                effectiveSchemaHash: effectiveHash,
                prompt: "animate",
                modeType: "image2video",
                advancedSettings: ["autoCompliance": .bool(false)],
                inputs: [privateInput]
            ),
            rawSchema: schema(),
            modelName: "Seedance 2.0"
        )
        #expect(skippedBoolean.seedanceCompliancePreflight.status == .skipped)

        let noImages = try validate(
            spec: .init(
                modality: .video,
                modelRef: "seedance-2",
                effectiveSchemaHash: effectiveHash,
                prompt: "text only"
            ),
            rawSchema: schema(),
            modelName: "Seedance 2.0"
        )
        #expect(noImages.seedanceCompliancePreflight.status == .notRequired)
        #expect(noImages.seedanceCompliancePreflight.inputOrders.isEmpty)

        let unsupported = try validate(
            spec: .init(
                modality: .video,
                modelRef: "other-video",
                effectiveSchemaHash: effectiveHash,
                prompt: "animate",
                modeType: "image2video",
                inputs: [privateInput]
            ),
            rawSchema: schema(portrait: false),
            modelName: "Other Video"
        )
        #expect(unsupported.seedanceCompliancePreflight.status == .notRequired)

        let prepared = PreparedLibTVSubmission(
            arguments: ["node", "--run"],
            requestFingerprint: "fingerprint",
            seedanceCompliancePreflight: checking.seedanceCompliancePreflight
        )
        let encoded = String(decoding: try CanonicalJSON.data(prepared.seedanceCompliancePreflight.payload()), as: UTF8.self)
        #expect(encoded == #"{"checked":0,"inputs":[{"order":7,"status":"checking"}],"status":"checking","total":1,"type":"seedance_compliance"}"#)
        #expect(!encoded.contains("private/customer"))
        #expect(!encoded.contains(String(repeating: "b", count: 64)))
        #expect(!encoded.contains("profile"))
        #expect(!encoded.contains("http"))
    }

    @Test
    func seedanceCompliancePayloadAlwaysSatisfiesInputStatusAndCountContract() throws {
        let preflight = SeedanceCompliancePreflight(status: .checking, inputOrders: [4, 2])
        let checking = try #require(preflight.payload().objectValue)
        #expect(checking["checked"] == .number(0))
        #expect(checking["total"] == .number(2))
        #expect(checking["inputs"] == .array([
            .object(["order": .number(2), "status": .string("checking")]),
            .object(["order": .number(4), "status": .string("checking")]),
        ]))

        let passed = try #require(preflight.payload(status: .passed).objectValue)
        #expect(passed["checked"] == .number(2))
        #expect(passed["total"] == .number(2))
        #expect(passed["inputs"] == .array([
            .object(["order": .number(2), "status": .string("passed")]),
            .object(["order": .number(4), "status": .string("passed")]),
        ]))

        let skipped = try #require(preflight.payload(status: .skipped).objectValue)
        #expect(skipped["checked"] == .number(0))
        #expect(skipped["inputs"] == .array([
            .object(["order": .number(2), "status": .string("skipped")]),
            .object(["order": .number(4), "status": .string("skipped")]),
        ]))

        let notRequired = try #require(preflight.payload(status: .notRequired).objectValue)
        #expect(notRequired["checked"] == .number(0))
        #expect(notRequired["inputs"] == .array([
            .object(["order": .number(2), "status": .string("not_required")]),
            .object(["order": .number(4), "status": .string("not_required")]),
        ]))

        for status in [
            SeedanceCompliancePreflightStatus.rejected,
            .retryableError,
            .unknown,
        ] {
            let payload = try #require(preflight.payload(status: status).objectValue)
            #expect(payload["status"] == .string(status.rawValue))
            #expect(payload["total"] == .number(2))
            #expect(payload["inputs"] == nil)
        }

        let completeStatusSet = [
            "pending", "checking", "passed", "exempt", "rejected", "retryable_error",
            "unknown", "skipped", "not_required",
        ]
        let decoder = JSONDecoder()
        for rawValue in completeStatusSet {
            #expect(try decoder.decode(
                SeedanceCompliancePreflightStatus.self,
                from: Data("\"\(rawValue)\"".utf8)
            ).rawValue == rawValue)
        }

        let encoded = String(decoding: try CanonicalJSON.data(.object(passed)), as: UTF8.self)
        for forbidden in ["url", "asset", "artifact", "profile", "sha256"] {
            #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test
    func seedanceComplianceCLIErrorClassifierIsStrictAndBilingual() {
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "",
            standardError: "合规检测未通过：素材包含未授权真人"
        ) == .rejected)
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "",
            standardError: "Portrait is not authorized for this account"
        ) == .rejected)
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "",
            standardError: "合规检测服务暂时不可用，请稍后重试"
        ) == .retryableError)
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "Compliance check service temporarily unavailable",
            standardError: ""
        ) == .retryableError)
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "",
            standardError: "Seedance 合规检测失败"
        ) == .uncertain)
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "",
            standardError: "模型生成失败：推理服务异常"
        ) == .unrelated)
        #expect(SeedanceComplianceCLIErrorClassifier.classify(
            standardOutput: "",
            standardError: "Runtime signature verification failed"
        ) == .unrelated)
    }

    @Test
    func imageNodeArgumentsAreBuiltByTheWhitelistedPureFunction() throws {
        let effectiveHash = String(repeating: "e", count: 64)
        let raw: JSONPayloadValue = .object([
            "modality": .string("image"),
            "schema": .object([
                "properties": .object([
                    "count": .array([.number(1)]),
                    "ratio": .object(["enum": .array([.string("1:1"), .string("16:9")])]),
                ]),
                "config": .object(["settings": .array([.string("ratio")])]),
            ]),
        ])
        let spec = LibTVGenerationSpecV1(
            modality: .image,
            modelRef: "image-model",
            effectiveSchemaHash: effectiveHash,
            prompt: "draw --run as text",
            settings: ["ratio": .string("16:9")]
        )
        let generation = try validate(spec: spec, rawSchema: raw, modelName: "Image Model")

        let arguments = try LibTVNodeArgumentsBuilder.imageArguments(
            for: generation,
            projectUUID: "project-uuid",
            groupName: "qumo-job-123",
            generationNodeName: "generate-123",
            inputNodeNames: []
        )

        #expect(arguments == [
            "node", "create", "generate-123",
            "--project", "project-uuid",
            "--group", "qumo-job-123",
            "--type", "image",
            "--set", "model=Image Model",
            "--set", "count=1",
            "--prompt", "draw --run as text",
            "--set", "ratio=16:9",
            "--run",
        ])
        #expect(arguments.first == "node")
        #expect(arguments.dropFirst().first == "create")
        #expect(!arguments.contains("libtv"))
    }

    @Test
    func videoNodeArgumentsPreserveInputOrderAndSchemaSettingOrder() throws {
        let effectiveHash = String(repeating: "e", count: 64)
        let raw: JSONPayloadValue = .object([
            "modality": .string("video"),
            "schema": .object([
                "properties": .object([
                    "count": .array([.number(1)]),
                    "duration": .object(["min": .number(4), "max": .number(15)]),
                    "resolution": .object(["enum": .array([.string("480p"), .string("720p")])]),
                    "modeType": .object([
                        "items": .object(["singleImage2video": .array([.number(1), .number(1)])]),
                    ]),
                ]),
                "config": .object([
                    "settings": .object([
                        "singleImage2video": .array([.string("resolution"), .string("duration")]),
                    ]),
                ]),
            ]),
        ])
        let spec = LibTVGenerationSpecV1(
            modality: .video,
            modelRef: "video-model",
            effectiveSchemaHash: effectiveHash,
            prompt: "animate",
            modeType: "singleImage2video",
            settings: ["resolution": .string("720p"), "duration": .number(5)],
            inputs: [.init(
                artifactKey: "workspace/reference.png",
                kind: "image",
                role: "reference",
                order: 0,
                sha256: String(repeating: "b", count: 64)
            )]
        )
        let generation = try validate(spec: spec, rawSchema: raw, modelName: "Seedance 2.0")

        let arguments = try LibTVNodeArgumentsBuilder.videoArguments(
            for: generation,
            projectUUID: "project-uuid",
            groupName: "qumo-job-456",
            generationNodeName: "generate-456",
            inputNodeNames: ["input-0"]
        )

        #expect(arguments == [
            "node", "create", "generate-456",
            "--project", "project-uuid",
            "--group", "qumo-job-456",
            "--type", "video",
            "--set", "model=Seedance 2.0",
            "--set", "count=1",
            "--prompt", "animate",
            "--set", "modeType=singleImage2video",
            "--set", "duration=5",
            "--set", "resolution=720p",
            "--left", "input-0",
            "--run",
        ])
        #expect(throws: LibTVNodeArgumentsError.inputNodeCountMismatch(expected: 1, actual: 0)) {
            try LibTVNodeArgumentsBuilder.videoArguments(
                for: generation,
                projectUUID: "project-uuid",
                groupName: "qumo-job-456",
                generationNodeName: "generate-456",
                inputNodeNames: []
            )
        }
    }

    @Test
    func textToVideoUsesGenerateTypeWithoutInventingUnsupportedModeType() throws {
        let effectiveHash = String(repeating: "e", count: 64)
        let raw: JSONPayloadValue = .object([
            "modality": .string("video"),
            "schema": .object([
                "properties": .object([
                    "count": .array([.number(1)]),
                    "duration": .object(["min": .number(4), "max": .number(15)]),
                    "resolution": .object(["enum": .array([.string("720p"), .string("1080p")])]),
                    "modeType": .object([
                        "items": .object(["singleImage2video": .array([.number(1), .number(1)])]),
                    ]),
                ]),
                "config": .object([
                    "generateTypes": .object(["text": .number(47), "image": .number(48)]),
                    "settings": .object([
                        "text2video": .array([.string("duration"), .string("resolution")]),
                    ]),
                ]),
                "rules": .array([
                    .object([
                        "forModeTypes": .array([.string("text2video")]),
                        "require": .array([.string("prompt")]),
                    ]),
                ]),
            ]),
        ])
        let spec = LibTVGenerationSpecV1(
            modality: .video,
            modelRef: "star-video2",
            effectiveSchemaHash: effectiveHash,
            prompt: "a quiet cinematic landscape",
            settings: ["duration": .number(5), "resolution": .string("720p")]
        )
        let generation = try validate(spec: spec, rawSchema: raw, modelName: "StarVideo 2.0")

        let arguments = try LibTVNodeArgumentsBuilder.videoArguments(
            for: generation,
            projectUUID: "project-uuid",
            groupName: "qumo-job-text-video",
            generationNodeName: "generate-text-video",
            inputNodeNames: []
        )

        #expect(arguments.contains("model=StarVideo 2.0"))
        #expect(arguments.contains("duration=5"))
        #expect(arguments.contains("resolution=720p"))
        #expect(!arguments.contains(where: { $0.hasPrefix("modeType=") }))
        #expect(arguments.suffix(1) == ["--run"])
    }

    @Test
    func localSchemaCannotRemapSettingsOntoReservedCommandFields() throws {
        let effectiveHash = String(repeating: "e", count: 64)
        let raw: JSONPayloadValue = .object([
            "modality": .string("image"),
            "schema": .object([
                "properties": .object([
                    "override": .object(["originalField": .string("model")]),
                ]),
                "config": .object(["settings": .array([.string("override")])]),
            ]),
        ])
        let spec = LibTVGenerationSpecV1(
            modality: .image,
            modelRef: "image-model",
            effectiveSchemaHash: effectiveHash,
            prompt: "hello",
            settings: ["override": .string("unapproved-model")]
        )
        #expect(throws: GenerationSpecError.reservedSettingDestination("model")) {
            try validate(spec: spec, rawSchema: raw, modelName: "Approved Model")
        }
    }

    @Test
    func projectResponseParserHandlesNestedCreateAndListPayloads() {
        let projectName = "Qumo Runner Hidden · abc123"
        #expect(LibTVProjectResponseParser.projectUUID(
            from: "progress\n{\"data\":{\"project\":{\"uuid\":\"86ba514d50e34c7dbd2ef571a2885383\"}}}\n"
        ) == "86ba514d50e34c7dbd2ef571a2885383")
        #expect(LibTVProjectResponseParser.projectUUID(
            from: "{\"projectMetaList\":[{\"uuid\":\"existing-project-uuid\",\"name\":\"\(projectName)\"}]}",
            named: projectName
        ) == "existing-project-uuid")
        #expect(LibTVProjectResponseParser.projectUUID(
            from: "{\"projectMetaList\":[{\"uuid\":\"wrong-project-uuid\",\"name\":\"Other\"}]}",
            named: projectName
        ) == nil)
    }

    @Test
    func executionRetentionIsTwentyFourHoursForSuccessAndSevenDaysForDiagnostics() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let now = Date(timeIntervalSince1970: 10_000_000)
        let rows: [(String, RunnerJobState, TimeInterval)] = [
            ("success-old", .succeeded, 25 * 60 * 60),
            ("failed-recent", .failed, 2 * 24 * 60 * 60),
            ("review-old", .needsReview, 8 * 24 * 60 * 60),
        ]
        for (jobID, state, age) in rows {
            let timestamp = now.addingTimeInterval(-age)
            _ = try await journal.recordSubmissionIntent(
                jobID: jobID, profileRef: "profile", requestFingerprint: "hash", at: timestamp
            )
            try await journal.recordExecutionLayout(
                jobID: jobID,
                profileRef: "profile",
                projectUUID: "project",
                groupName: "group-\(jobID)",
                inputNodeNames: ["input"],
                generationNodeName: "generation",
                at: timestamp
            )
            try await journal.markTerminal(jobID: jobID, state: state, at: timestamp)
        }
        let expired = try await journal.expiredExecutionLayouts(at: now).map(\.jobID)
        #expect(expired == ["review-old", "success-old"])
    }

    private func payload(_ spec: LibTVGenerationSpecV1) throws -> [String: JSONPayloadValue] {
        let data = try JSONEncoder().encode(spec)
        return try #require(JSONDecoder().decode(JSONPayloadValue.self, from: data).objectValue)
    }

    @Test
    func hiddenProjectPreparationUsesTheJobsPinnedRuntime() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultBinary = root.appending(path: "default")
        let candidate = root.appending(path: "candidate")
        try "#!/bin/sh\necho wrong-runtime >> \"$HOME/default-called\"\nexit 1\n".write(to: defaultBinary, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$HOME/candidate-called"
        if [ "$1" = project ] && [ "$2" = create ]; then
          echo '{"uuid":"pinned-project-1234567890"}'
        else
          echo '{}'
        fi
        """.write(to: candidate, atomically: true, encoding: .utf8)
        for file in [defaultBinary, candidate] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let executor = ProfileExecutor(profileRef: "profile", runner: LibTVProcessRunner(executableURL: defaultBinary, homeURL: root), limiter: try GlobalConcurrencyLimiter(limit: 1))
        try await executor.bindRuntime(jobID: "job", executableURL: candidate)
        let raw: JSONPayloadValue = .object([
            "modelName": .string("Image Model"),
            "schema": .object(["properties": .object(["count": .array([.number(1)])])]),
        ])
        let hash = try CanonicalJSON.sha256(raw)
        let registry = LibTVSchemaRegistry()
        registry.replace(profileRef: "profile", schemas: [.init(modelRef: "image", modelName: "Image Model", schemaHash: hash, rawSchema: raw, approved: true)])
        let spec = LibTVGenerationSpecV1(modality: .image, modelRef: "image", effectiveSchemaHash: hash, prompt: "test")
        let job = RunnerJob(id: "job", requiredModelRef: "image", baseSchemaHash: hash, patchVersion: 1, effectiveSchemaHash: hash, payload: try payload(spec))
        let preparer = LibTVGenerationPreparer(
            registry: registry,
            projectStore: LibTVExecutionProjectStore(fileURL: root.appending(path: "projects.json")),
            stagingRoot: root.appending(path: "staging"),
            journal: try SubmissionJournal(databaseURL: root.appending(path: "journal.sqlite"))
        )
        let prepared = try await preparer.prepare(job: job, profileRef: "profile", executor: executor)
        #expect(prepared.arguments.contains("pinned-project-1234567890"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "default-called").path))
        let log = try String(contentsOf: root.appending(path: "candidate-called"), encoding: .utf8)
        #expect(log.contains("project list"))
        #expect(log.contains("project create"))
        #expect(log.contains("group create"))
        #expect(!log.contains("--run"))
    }

    private func validate(
        spec: LibTVGenerationSpecV1,
        rawSchema: JSONPayloadValue,
        modelName: String
    ) throws -> ValidatedLibTVGeneration {
        let baseHash = try CanonicalJSON.sha256(rawSchema)
        let registry = LibTVSchemaRegistry()
        registry.replace(profileRef: "profile", schemas: [.init(
            modelRef: spec.modelRef,
            modelName: modelName,
            schemaHash: baseHash,
            rawSchema: rawSchema,
            approved: true
        )])
        return try LibTVGenerationValidator.validate(
            job: RunnerJob(
                id: "job",
                requiredModelRef: spec.modelRef,
                baseSchemaHash: baseHash,
                patchVersion: 1,
                effectiveSchemaHash: spec.effectiveSchemaHash,
                payload: try payload(spec)
            ),
            profileRef: "profile",
            registry: registry
        )
    }
}
