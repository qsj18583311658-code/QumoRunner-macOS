import Foundation
import RunnerCore

actor AgentAPITransport: RunnerAPITransport, ArtifactAPITransport, ProfileInventoryAPITransport, ProfileModelApprovalAPITransport, GenerationInputMaterializing {
    private let base: RunnerAPIClient
    private var jobs: [String: RunnerJob] = [:]
    private var serviceCommands: [RunnerControlCommand] = []

    init(base: RunnerAPIClient) { self.base = base }

    func syncProfiles(_ profiles: [RunnerProfile]) async throws -> SyncProfilesResponse {
        try await base.syncProfiles(profiles)
    }

    func claim(profileRef: String, capabilities: [String]) async throws -> ClaimedJob {
        let response = try await base.claim(profileRef: profileRef, capabilities: capabilities)
        if var job = response.job {
            job.executionProfileRef = profileRef
            jobs[job.id] = job
            trimHistory()
        }
        return response
    }

    func heartbeat(_ request: RunnerHeartbeatRequest) async throws -> RunnerHeartbeatResponse {
        let response = try await base.heartbeat(request)
        serviceCommands.append(contentsOf: response.commands.filter {
            switch $0.kind {
            case .refreshProfiles, .refreshInventory, .diagnostics, .healthCheck: true
            default: false
            }
        })
        return response
    }

    func acknowledge(commandID: String, acknowledgement: CommandAcknowledgement) async throws {
        try await base.acknowledge(commandID: commandID, acknowledgement: acknowledgement)
    }

    func postJobEvent(jobID: String, event: JobEventRequest) async throws {
        try await base.postJobEvent(jobID: jobID, event: event)
        if var job = jobs[jobID] {
            job.state = event.status
            job.executionProfileRef = event.profileRef
            job.remoteTaskID = event.remoteTaskID ?? job.remoteTaskID
            job.result = event.result ?? job.result
            job.error = event.error
            job.updatedAt = .now
            jobs[jobID] = job
        }
    }

    func cancelLeasedJob(jobID: String, profileRef: String) async throws -> RunnerJob {
        let cancelled = try await base.cancelLeasedJob(jobID: jobID, profileRef: profileRef)
        jobs[jobID] = cancelled
        return cancelled
    }

    func initializeArtifact(jobID: String, request: ArtifactInitRequest) async throws -> ArtifactInitResponse {
        try await base.initializeArtifact(jobID: jobID, request: request)
    }

    func uploadArtifact(fileURL: URL, to signedURL: URL, method: String, contentType: String, headers: [String: String]) async throws {
        try await base.uploadArtifact(fileURL: fileURL, to: signedURL, method: method, contentType: contentType, headers: headers)
    }

    func materialize(
        jobID: String,
        input: LibTVGenerationInputV1,
        destinationURL: URL
    ) async throws {
        try await base.materialize(jobID: jobID, input: input, destinationURL: destinationURL)
    }

    func completeArtifact(jobID: String, artifactID: String, request: ArtifactCompleteRequest) async throws -> ArtifactCompleteResponse {
        try await base.completeArtifact(jobID: jobID, artifactID: artifactID, request: request)
    }

    func syncProfileInventory(profileRef: String, request: ProfileInventoryRequest) async throws -> ProfileInventoryResponse {
        try await base.syncProfileInventory(profileRef: profileRef, request: request)
    }

    func uploadProfileModelSchema(
        profileRef: String,
        request: ProfileModelSchemaUploadRequest
    ) async throws -> ProfileModelSchemaUploadResponse {
        try await base.uploadProfileModelSchema(profileRef: profileRef, request: request)
    }

    func setProfileModelApproval(
        profileRef: String,
        modelRef: String,
        request: ProfileModelApprovalRequest
    ) async throws -> ProfileModelApprovalResponse {
        try await base.setProfileModelApproval(profileRef: profileRef, modelRef: modelRef, request: request)
    }

    func jobsSnapshot() -> [RunnerJob] {
        jobs.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func consumeServiceCommands() -> [RunnerControlCommand] {
        defer { serviceCommands.removeAll(keepingCapacity: true) }
        return serviceCommands
    }

    private func trimHistory() {
        if jobs.count <= 200 { return }
        for job in jobs.values.sorted(by: { $0.updatedAt > $1.updatedAt }).dropFirst(200) { jobs.removeValue(forKey: job.id) }
    }
}
