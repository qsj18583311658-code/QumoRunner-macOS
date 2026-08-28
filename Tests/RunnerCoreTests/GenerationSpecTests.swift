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
                    "settings": .array([.string("duration"), .string("resolution")]),
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
