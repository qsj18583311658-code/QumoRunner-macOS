import XCTest
import RunnerCore

final class ModelCatalogParserTests: XCTestCase {
    func testSearchParserAcceptsMultilineCLIOutput() throws {
        let output = """
        diagnostic line
        {"matches":[{"modelKey":"image-gen","modelName":"Image Gen","description":"x","labels":["b","a"]}]}
        """
        let models = try ModelCatalogParser.parseSearch(output, modality: "image")
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].modelRef, "image-gen")
        XCTAssertEqual(models[0].modality, "image")
        XCTAssertEqual(models[0].summaryHash.count, 64)
    }

    func testSchemaHashIsStableAcrossObjectKeyOrder() throws {
        let first = try ModelCatalogParser.schemaHash("{\"b\":2,\"a\":1}")
        let second = try ModelCatalogParser.schemaHash("{\"a\":1,\"b\":2}")
        XCTAssertEqual(first, second)
    }

    func testSchemaParserRetainsTheCompleteCanonicalDocument() throws {
        let parsed = try ModelCatalogParser.parseSchema(
            #"{"modelKey":"video-gen","modality":"video","schema":{"properties":{"duration":{"min":4,"max":15}},"config":{"settings":["duration"]},"rules":[]}}"#
        )
        XCTAssertEqual(parsed.hash, try CanonicalJSON.sha256(parsed.document))
        XCTAssertEqual(parsed.document.objectValue?["modelKey"]?.stringValue, "video-gen")
        XCTAssertEqual(
            parsed.document.objectValue?["schema"]?.objectValue?["config"]?.objectValue?["settings"]?.arrayValue?.first?.stringValue,
            "duration"
        )
        XCTAssertNotNil(parsed.document.objectValue?["schema"]?.objectValue?["rules"]?.arrayValue)
    }

    func testSchemaFetchPlanReusesUnchangedSchema() {
        let cachedSchema: JSONPayloadValue = .object(["schema": .object([:])])
        let existing = StoredCatalogItem(
            modelRef: "image-gen",
            displayName: "Image Gen",
            modalities: ["image"],
            summaryHash: "same-summary",
            schemaHash: try! CanonicalJSON.sha256(cachedSchema),
            rawSchema: cachedSchema,
            approvalState: .approved,
            approved: true,
            missingRefreshCount: 0
        )
        XCTAssertFalse(ModelCatalogParser.needsSchemaFetch(modelRef: "image-gen", summaryHash: "same-summary", existing: [existing]))
        XCTAssertTrue(ModelCatalogParser.needsSchemaFetch(modelRef: "image-gen", summaryHash: "same-summary", existing: [existing], force: true))
        XCTAssertTrue(ModelCatalogParser.needsSchemaFetch(modelRef: "image-gen", summaryHash: "changed-summary", existing: [existing]))
        XCTAssertTrue(ModelCatalogParser.needsSchemaFetch(modelRef: "new-model", summaryHash: "same-summary", existing: [existing]))

        var corrupted = existing
        corrupted.rawSchema = .object(["schema": .object(["changed": .bool(true)])])
        XCTAssertTrue(ModelCatalogParser.needsSchemaFetch(modelRef: "image-gen", summaryHash: "same-summary", existing: [corrupted]))
    }

    func testNewChangedAndTwoMissingRefreshesRequireReview() {
        let initial = ModelCatalogParser.reconcile(existing: [], incoming: [candidate(schema: "v1")])
        XCTAssertEqual(initial[0].approvalState, .pending)
        XCTAssertFalse(initial[0].approved)

        var approved = initial[0]
        approved.approvalState = .approved
        approved.approved = true
        let unchanged = ModelCatalogParser.reconcile(existing: [approved], incoming: [candidate(schema: "v1")])
        XCTAssertEqual(unchanged[0].approvalState, .approved)

        let changed = ModelCatalogParser.reconcile(existing: unchanged, incoming: [candidate(schema: "v2")])
        XCTAssertEqual(changed[0].approvalState, .changed)
        XCTAssertFalse(changed[0].approved)

        let missingOnce = ModelCatalogParser.reconcile(existing: unchanged, incoming: [])
        XCTAssertEqual(missingOnce[0].missingRefreshCount, 1)
        XCTAssertNotEqual(missingOnce[0].approvalState, .removed)
        let missingTwice = ModelCatalogParser.reconcile(existing: missingOnce, incoming: [])
        XCTAssertEqual(missingTwice[0].approvalState, .removed)
        XCTAssertEqual(missingTwice[0].missingRefreshCount, 2)
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
