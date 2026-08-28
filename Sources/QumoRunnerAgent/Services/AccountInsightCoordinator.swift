import Foundation
import CryptoKit
import RunnerCore

actor AccountInsightCoordinator {
    private struct Context: Sendable {
        var accountRef: String
        let runner: LibTVProcessRunner
    }

    private let store: AccountInsightStore
    private let profileAPI = AccountProfileAPIService()
    private let catalogService = ModelCatalogService()
    private var contexts: [String: Context] = [:]
    private var webFlights = Set<String>()
    private var catalogFlights = Set<String>()
    private var startupScheduled = Set<String>()
    private var nextWebRefresh: [String: Date] = [:]
    private var lastFullSchemaRefresh: [String: Date] = [:]
    private var taskFinishedDebounces: [String: Task<Void, Never>] = [:]
    private var taskFinishedGenerations: [String: UUID] = [:]

    init(root: URL) {
        store = AccountInsightStore(root: root)
    }

    func register(profile: RunnerProfile, runner: LibTVProcessRunner) {
        contexts[profile.profileRef] = Context(accountRef: profile.accountRef, runner: runner)
    }

    func remove(profileRef: String) async {
        contexts.removeValue(forKey: profileRef)
        webFlights.remove(profileRef)
        catalogFlights.remove(profileRef)
        startupScheduled.remove(profileRef)
        nextWebRefresh.removeValue(forKey: profileRef)
        lastFullSchemaRefresh.removeValue(forKey: profileRef)
        taskFinishedDebounces.removeValue(forKey: profileRef)?.cancel()
        taskFinishedGenerations.removeValue(forKey: profileRef)
        try? await store.remove(profileRef)
    }

    func tick(profiles: [RunnerProfile]) async {
        let now = Date()
        for profile in profiles where profile.accountRef != "pending" {
            if var context = contexts[profile.profileRef] {
                context.accountRef = profile.accountRef
                contexts[profile.profileRef] = context
            }
            if !startupScheduled.contains(profile.profileRef) {
                startupScheduled.insert(profile.profileRef)
                scheduleWeb(profileRef: profile.profileRef, reason: .startup)
                scheduleCatalog(profileRef: profile.profileRef)
                continue
            }
            if nextWebRefresh[profile.profileRef, default: .distantPast] <= now {
                scheduleWeb(profileRef: profile.profileRef, reason: .scheduled)
            }
            let insight = await store.profile(profile.profileRef)
            if insight.catalogRefreshedAt.map({ now.timeIntervalSince($0) >= 6 * 60 * 60 }) ?? true {
                scheduleCatalog(profileRef: profile.profileRef)
            }
        }
    }

    func refresh(profileRef: String, reason: AccountInsightRefreshReason, includeCatalog: Bool) {
        if reason == .taskFinished {
            scheduleTaskFinishedRefresh(profileRef: profileRef)
        } else {
            scheduleWeb(profileRef: profileRef, reason: reason)
        }
        if includeCatalog { scheduleCatalog(profileRef: profileRef) }
    }

    func approveModel(profileRef: String, modelRef: String, expectedSchemaHash: String, approved: Bool) async throws {
        try await store.approve(
            profileRef: profileRef,
            modelRef: modelRef,
            expectedSchemaHash: expectedSchemaHash,
            approved: approved
        )
    }

    func schemaHash(profileRef: String, modelRef: String) async throws -> String {
        try await store.schemaHash(profileRef: profileRef, modelRef: modelRef)
    }

    func activateAutoConcurrency(profileRef: String) async {
        try? await store.update(profileRef) { $0.autoConcurrencyActivated = true }
    }

    func view(profileRef: String, globalLimit: Int) async -> AccountInsightView {
        let insight = await store.profile(profileRef)
        let plan = usablePlan(insight.plan)
        let detected = plan?.detectedMaxConcurrency.map { min(8, max(0, $0)) }
        let effectiveQuota = effectiveQuota(for: insight)
        let policyQuotaState: AccountQuotaState = effectiveQuota.state == .stale && effectiveQuota.snapshot?.total == 0 ? .zero : effectiveQuota.state
        let effective = AccountConcurrencyPolicy.effective(
            autoActivated: insight.autoConcurrencyActivated,
            quotaState: policyQuotaState,
            detected: detected,
            unlimited: plan?.unlimitedConcurrency == true,
            globalLimit: globalLimit
        )
        return AccountInsightView(
            refreshing: webFlights.contains(profileRef),
            autoConcurrencyActivated: insight.autoConcurrencyActivated,
            quotaState: webFlights.contains(profileRef) ? .refreshing : effectiveQuota.state,
            quota: effectiveQuota.snapshot,
            plan: plan,
            lastAttemptAt: hasAttemptedRefresh(insight) ? insight.quota.observedAt : nil,
            refreshError: combinedRefreshError(insight),
            detectedMaxConcurrency: detected,
            effectiveMaxConcurrency: effective,
            catalogRevision: insight.catalogRevision,
            catalogRefreshedAt: insight.catalogRefreshedAt,
            catalogError: insight.catalogError,
            catalogRefreshing: catalogFlights.contains(profileRef),
            models: insight.catalog.map(\.agentValue)
        )
    }

    func inventory(profileRef: String, globalLimit: Int) async -> ProfileInventoryRequest {
        let insight = await store.profile(profileRef)
        let currentView = await view(profileRef: profileRef, globalLimit: globalLimit)
        let effectiveQuota = effectiveQuota(for: insight)
        let quotaSnapshot = effectiveQuota.snapshot
        let wireQuotaState = effectiveQuota.state.inventoryValue(snapshot: quotaSnapshot)
        let quota = ProfileQuotaSnapshot(
            state: wireQuotaState,
            observedAt: quotaSnapshot?.fetchedAt ?? insight.quota.observedAt,
            staleAt: effectiveQuota.state == .stale ? quotaSnapshot?.fetchedAt.addingTimeInterval(10 * 60) : nil,
            totalBalance: quotaSnapshot.map { Self.decimalString($0.total) },
            membershipPoints: quotaSnapshot.map { Self.decimalString($0.membership) },
            rechargePoints: quotaSnapshot.map { Self.decimalString($0.recharge) },
            modelCardPoints: quotaSnapshot.map { Self.decimalString($0.modelCard) },
            freePoints: quotaSnapshot.map { Self.decimalString($0.free) }
        )
        let plan = ProfilePlanSnapshot(
            observedAt: insight.plan?.fetchedAt ?? insight.quota.observedAt,
            planName: currentView.plan?.name,
            detectedMaxConcurrency: currentView.detectedMaxConcurrency,
            maxConcurrency: currentView.effectiveMaxConcurrency
        )
        let models = insight.catalog
            .filter { $0.approvalState != .removed && $0.missingRefreshCount == 0 }
            .map {
                ProfileModelInventory(
                    modelRef: $0.modelRef,
                    displayName: $0.displayName,
                    modality: $0.modalities.first ?? "unknown",
                    summaryHash: $0.summaryHash,
                    schemaHash: $0.schemaHash,
                    capabilities: $0.modalities
                )
            }
            .sorted { $0.modelRef < $1.modelRef }
        let inventoryRevision = ProfileInventoryRequest.contentRevision(
            catalogRevision: insight.catalogRevision,
            quota: quota,
            plan: plan,
            models: models
        )
        return ProfileInventoryRequest(
            inventoryRevision: inventoryRevision,
            catalogRevision: insight.catalogRevision,
            quota: quota,
            plan: plan,
            models: models
        )
    }

    func generationSchemas(profileRef: String) async -> [LibTVModelSchemaSnapshot] {
        await store.generationSchemas(profileRef: profileRef)
    }

    func schemaUpload(
        profileRef: String,
        required: RequiredSchemaUpload
    ) async throws -> ProfileModelSchemaUploadRequest {
        try await store.schemaUpload(profileRef: profileRef, required: required)
    }

    private func scheduleWeb(profileRef: String, reason: AccountInsightRefreshReason) {
        guard contexts[profileRef] != nil, webFlights.insert(profileRef).inserted else { return }
        Task { [weak self] in await self?.performWebRefresh(profileRef: profileRef, reason: reason) }
    }

    private func scheduleTaskFinishedRefresh(profileRef: String) {
        taskFinishedDebounces[profileRef]?.cancel()
        let generation = UUID()
        taskFinishedGenerations[profileRef] = generation
        taskFinishedDebounces[profileRef] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            await self?.finishTaskDebounce(profileRef: profileRef, generation: generation)
        }
    }

    private func finishTaskDebounce(profileRef: String, generation: UUID) {
        guard taskFinishedGenerations[profileRef] == generation else { return }
        taskFinishedGenerations.removeValue(forKey: profileRef)
        taskFinishedDebounces.removeValue(forKey: profileRef)
        scheduleWeb(profileRef: profileRef, reason: .taskFinished)
    }

    private func scheduleCatalog(profileRef: String) {
        guard contexts[profileRef] != nil, catalogFlights.insert(profileRef).inserted else { return }
        Task { [weak self] in await self?.performCatalogRefresh(profileRef: profileRef) }
    }

    private func performWebRefresh(profileRef: String, reason: AccountInsightRefreshReason) async {
        defer {
            webFlights.remove(profileRef)
            nextWebRefresh[profileRef] = Date().addingTimeInterval(15 * 60 + jitter(for: profileRef))
        }
        guard let context = contexts[profileRef] else { return }
        let current = await store.profile(profileRef)
        let page: WebPagePayload
        do {
            page = try await profileAPI.load(using: context.runner)
        } catch {
            await recordQuotaFailure(error, profileRef: profileRef, previous: current.quota)
            await recordPlanFailure(error, profileRef: profileRef)
            return
        }
        do {
            let parsed = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: context.accountRef)
            try await storeQuota(parsed, profileRef: profileRef)
        } catch {
            await recordQuotaFailure(error, profileRef: profileRef, previous: current.quota)
        }
        do {
            let plan = try AccountInsightParser.parsePlan(page: page)
            try await storePlan(plan, profileRef: profileRef)
        } catch {
            await recordPlanFailure(error, profileRef: profileRef)
        }
        _ = reason
    }

    private func storeQuota(_ parsed: ParsedQuota, profileRef: String) async throws {
        let snapshot = AgentQuotaSnapshot(
            total: parsed.total,
            membership: parsed.membership,
            recharge: parsed.recharge,
            modelCard: parsed.modelCard,
            free: parsed.free,
            fetchedAt: .now,
            stale: false
        )
        try await store.update(profileRef) { insight in
            insight.quota = StoredQuota(state: parsed.total == 0 ? .zero : .available, snapshot: snapshot, error: nil, observedAt: .now)
        }
    }

    private func storePlan(_ parsed: ParsedPlan, profileRef: String) async throws {
        let plan = AgentPlanSnapshot(
            name: parsed.name,
            detectedMaxConcurrency: parsed.maxConcurrency,
            unlimitedConcurrency: parsed.unlimited,
            fetchedAt: .now,
            stale: false,
            detectionNote: parsed.evidence
        )
        try await store.update(profileRef) {
            $0.plan = plan
            $0.planError = nil
            $0.autoConcurrencyActivated = true
        }
    }

    private func recordQuotaFailure(_ error: Error, profileRef: String, previous: StoredQuota) async {
        let failure = (error as? WebInsightFailure) ?? .permanent(error.localizedDescription)
        let recent = previous.snapshot.flatMap { Date().timeIntervalSince($0.fetchedAt) < 10 * 60 ? $0 : nil }
        let preserved = failure.preservesRecentQuota ? recent : nil
        let state: AccountQuotaState
        switch failure {
        case .webAuthRequired: state = .webAuthRequired
        case .identityMismatch: state = .identityMismatch
        default: state = preserved == nil ? .unknown : .stale
        }
        let stale = preserved.map {
            AgentQuotaSnapshot(total: $0.total, membership: $0.membership, recharge: $0.recharge, modelCard: $0.modelCard, free: $0.free, fetchedAt: $0.fetchedAt, stale: true)
        }
        try? await store.update(profileRef) { $0.quota = StoredQuota(state: state, snapshot: stale, error: failure.localizedDescription, observedAt: .now) }
    }

    private func recordPlanFailure(_ error: Error, profileRef: String) async {
        try? await store.update(profileRef) { insight in
            insight.planError = error.localizedDescription
            guard let previous = insight.plan, Date().timeIntervalSince(previous.fetchedAt) < 24 * 60 * 60 else {
                insight.plan = nil
                return
            }
            insight.plan = AgentPlanSnapshot(
                name: previous.name,
                detectedMaxConcurrency: previous.detectedMaxConcurrency,
                unlimitedConcurrency: previous.unlimitedConcurrency,
                fetchedAt: previous.fetchedAt,
                stale: true,
                detectionNote: "\(previous.detectionNote)；本次刷新失败"
            )
        }
    }

    private func performCatalogRefresh(profileRef: String) async {
        defer { catalogFlights.remove(profileRef) }
        guard let context = contexts[profileRef] else { return }
        do {
            let current = await store.profile(profileRef)
            let forceSchemaRefresh = lastFullSchemaRefresh[profileRef].map { Date().timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
            let incoming = try await catalogService.fetch(
                using: context.runner,
                existing: current.catalog,
                forceSchemaRefresh: forceSchemaRefresh
            )
            try await store.reconcileCatalog(profileRef: profileRef, incoming: incoming)
            if forceSchemaRefresh { lastFullSchemaRefresh[profileRef] = .now }
        } catch {
            try? await store.update(profileRef) { $0.catalogError = error.localizedDescription }
        }
    }

    private func usablePlan(_ plan: AgentPlanSnapshot?) -> AgentPlanSnapshot? {
        guard let plan, Date().timeIntervalSince(plan.fetchedAt) < 24 * 60 * 60 else { return nil }
        return plan
    }

    private func hasAttemptedRefresh(_ insight: StoredProfileInsight) -> Bool {
        insight.quota.snapshot != nil || insight.quota.error != nil || insight.plan != nil || insight.planError != nil
    }

    private func combinedRefreshError(_ insight: StoredProfileInsight) -> String? {
        var seen = Set<String>()
        let errors = [insight.quota.error, insight.planError]
            .compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return errors.isEmpty ? nil : errors.joined(separator: "；")
    }

    private func effectiveQuota(for insight: StoredProfileInsight) -> (state: AccountQuotaState, snapshot: AgentQuotaSnapshot?) {
        guard insight.quota.state == .stale else { return (insight.quota.state, insight.quota.snapshot) }
        guard let snapshot = insight.quota.snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 10 * 60 else {
            return (.unknown, nil)
        }
        return (.stale, snapshot)
    }

    private func jitter(for profileRef: String) -> TimeInterval {
        TimeInterval(profileRef.utf8.reduce(0) { (($0 &* 31) &+ Int($1)) % 121 })
    }

    private nonisolated static func decimalString(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
