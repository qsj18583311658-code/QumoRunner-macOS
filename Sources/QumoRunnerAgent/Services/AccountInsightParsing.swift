import Foundation

enum AccountInsightParser {
    static func parseQuota(page: WebPagePayload, expectedAccountRef: String?) throws -> ParsedQuota {
        let text = normalized(page.bodyText)
        if isAuthenticationPage(url: page.url, title: page.title, text: text) { throw WebInsightFailure.webAuthRequired }
        var builder = QuotaBuilder()
        if let json = page.embeddedJSON { builder = quotaFromJSON(json) ?? builder }
        let labels: [(WritableKeyPath<QuotaBuilder, Double?>, [String])] = [
            (\.total, ["当前账户总余额", "当前总余额", "总余额"]),
            (\.membership, ["会员订阅积分", "订阅会员积分"]),
            (\.recharge, ["通用充值积分", "充值通用积分"]),
            (\.modelCard, ["模型卡积分", "模型专享积分"]),
            (\.free, ["免费积分"]),
        ]
        for (keyPath, labels) in labels {
            if builder[keyPath: keyPath] == nil { builder[keyPath: keyPath] = value(nearAny: labels, in: text) }
        }
        guard let total = builder.total,
              let membership = builder.membership,
              let recharge = builder.recharge,
              let modelCard = builder.modelCard,
              let free = builder.free else {
            throw WebInsightFailure.parse("积分页结构无法识别；本次不会将余额误判为 0。")
        }
        let pageAccount = embeddedAccountRef(page.embeddedJSON)
        if let expected = normalizedIdentifier(expectedAccountRef),
           let actual = normalizedIdentifier(pageAccount), expected != actual {
            throw WebInsightFailure.identityMismatch
        }
        return ParsedQuota(total: total, membership: membership, recharge: recharge, modelCard: modelCard, free: free, accountRef: pageAccount)
    }

    static func parsePlan(page: WebPagePayload) throws -> ParsedPlan {
        if let json = page.embeddedJSON, let parsed = planFromJSON(json) { return parsed }
        let text = normalized(page.bodyText)
        let patterns = [
            "(?:当前套餐|当前会员|已开通套餐|我的套餐)[^\\n]{0,120}?(?:并发任务数|并发|同时生成)\\s*[:：-]?\\s*(无限|\\d+)\\s*个?",
            "(?:并发上限|最大并发|同时任务)\\s*[:：-]?\\s*(无限|\\d+)",
        ]
        for pattern in patterns {
            if let token = firstCapture(pattern, in: text) {
                let unlimited = token == "无限"
                let name = firstCapture("(?:当前套餐|当前会员|已开通套餐|我的套餐)\\s*[:：-]?\\s*([^\\n]{1,32})", in: text)
                return ParsedPlan(name: name, maxConcurrency: unlimited ? nil : Int(token), unlimited: unlimited, evidence: "页面明示并发")
            }
        }
        let taskCounts = captures("并发任务数\\s*[:：-]?\\s*(无限|\\d+)\\s*个?", in: text)
        let hasCurrentPlanMarker = ["当前套餐", "当前会员", "已开通套餐", "我的套餐", "我的会员"].contains(where: text.contains)
        if hasCurrentPlanMarker, taskCounts.count == 1, let token = taskCounts.first {
            let unlimited = token == "无限"
            return ParsedPlan(name: nil, maxConcurrency: unlimited ? nil : Int(token), unlimited: unlimited, evidence: "页面唯一并发任务数")
        }
        throw WebInsightFailure.parse("页面未提供可验证的套餐并发上限。")
    }

    private static func value(nearAny labels: [String], in text: String) -> Double? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where labels.contains(where: line.contains) {
            // Cards normally render label then value. Looking at the previous line
            // first can accidentally consume the preceding card's numeric value.
            for candidate in [line, index + 1 < lines.count ? lines[index + 1] : "", index > 0 ? lines[index - 1] : ""] {
                if let number = firstNumber(in: candidate.replacingOccurrences(of: labels.first(where: candidate.contains) ?? "", with: "")) { return number }
            }
        }
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            for pattern in ["\(escaped)\\s*[:：]?\\s*([0-9][0-9,.]*)", "([0-9][0-9,.]*)\\s*\(escaped)"] {
                if let value = firstCapture(pattern, in: text).flatMap(parseNumber) { return value }
            }
        }
        return nil
    }

    private static func firstNumber(in value: String) -> Double? {
        firstCapture("(^|[^0-9])([0-9][0-9,.]*)", in: value, group: 2).flatMap(parseNumber)
    }

    private static func parseNumber(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func isAuthenticationPage(url: String, title: String, text: String) -> Bool {
        let lowerURL = url.lowercased()
        if ["login", "signin", "passport", "auth"].contains(where: lowerURL.contains) { return true }
        return (text.contains("登录/注册") || title.contains("登录")) && !text.contains("当前账户总余额")
    }

    private static func quotaFromJSON(_ raw: String) -> QuotaBuilder? {
        guard let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let official = findOfficialQuota(value: json) { return official }
        if let complete = findCompleteQuota(value: json) { return complete }
        var builder = QuotaBuilder()
        collectQuota(value: json, builder: &builder)
        return builder.hasAnyValue ? builder : nil
    }

    private static func findOfficialQuota(value: Any) -> QuotaBuilder? {
        guard let source = findOfficialQuotaSource(value: value) else { return nil }
        let membership = findOfficialMembership(value: value) ?? (source.effective == false ? 0 : nil)
        guard let membership else { return nil }
        return officialQuota(attrRaw: source.attr, membership: membership)
    }

    private static func findOfficialQuotaSource(value: Any) -> (attr: [String: Any], effective: Bool?)? {
        if let object = value as? [String: Any] {
            let root = normalizedObject(object)
            let candidates = [root["vipinfo"] as? [String: Any], object].compactMap { $0 }
            for candidate in candidates {
                let normalized = normalizedObject(candidate)
                guard let attrRaw = normalized["attr"] as? [String: Any] else { continue }
                let attr = normalizedObject(attrRaw)
                let hasOfficialShape = attr["libtvusablepower"] != nil
                    && attr["rechargeusablepower"] != nil
                    && attr["freeusablepower"] != nil
                    && attr["expowersummary"] != nil
                if hasOfficialShape {
                    return (attrRaw, booleanValue(normalized["effective"]))
                }
            }
            for nested in object.values {
                if let found = findOfficialQuotaSource(value: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findOfficialQuotaSource(value: nested) { return found }
            }
        }
        return nil
    }

    private static func officialQuota(attrRaw: [String: Any], membership: Double) -> QuotaBuilder? {
        let attr = normalizedObject(attrRaw)
        guard let libtvPower = numericValue(for: ["libtvusablepower"], in: attr),
              let recharge = numericValue(for: ["rechargeusablepower"], in: attr),
              let free = numericValue(for: ["freeusablepower"], in: attr),
              let summaryRaw = attr["expowersummary"] as? [String: Any],
              let modelCard = numericValue(for: ["usablepower"], in: normalizedObject(summaryRaw)) else { return nil }
        var base = numericValue(for: ["usablepower"], in: attr)
        if base == nil,
           let totalPower = numericValue(for: ["totalpower"], in: attr),
           let usedPower = numericValue(for: ["usedpower"], in: attr) {
            base = totalPower - usedPower
        }
        guard let base else { return nil }
        return QuotaBuilder(
            total: max(base, 0) + max(libtvPower, 0) + max(modelCard, 0),
            membership: membership,
            recharge: recharge,
            modelCard: modelCard,
            free: free
        )
    }

    private static func findOfficialMembership(value: Any) -> Double? {
        if let object = value as? [String: Any] {
            let normalized = normalizedObject(object)
            if let currentRaw = normalized["currentpower"] as? [String: Any],
               let balance = numericValue(for: ["balance"], in: normalizedObject(currentRaw)) {
                return balance
            }
            for nested in object.values {
                if let found = findOfficialMembership(value: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findOfficialMembership(value: nested) { return found }
            }
        }
        return nil
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func findCompleteQuota(value: Any) -> QuotaBuilder? {
        if let object = value as? [String: Any] {
            let normalized = normalizedObject(object)
            let builder = QuotaBuilder(
                total: numericValue(for: ["currentaccounttotalbalance", "currenttotalbalance", "totalbalance", "totalcredits", "creditbalance"], in: normalized),
                membership: numericValue(for: ["membershipcredits", "membershipbalance", "subscriptioncredits", "vipcredits"], in: normalized),
                recharge: numericValue(for: ["rechargecredits", "rechargebalance", "topupcredits", "generalcredits"], in: normalized),
                modelCard: numericValue(for: ["modelcardcredits", "modelcardbalance", "modelcredits"], in: normalized),
                free: numericValue(for: ["freecredits", "freebalance", "giftcredits"], in: normalized)
            )
            if builder.isComplete { return builder }
            for nested in object.values { if let found = findCompleteQuota(value: nested) { return found } }
        } else if let array = value as? [Any] {
            for nested in array { if let found = findCompleteQuota(value: nested) { return found } }
        }
        return nil
    }

    private static func collectQuota(value: Any, builder: inout QuotaBuilder) {
        if let object = value as? [String: Any] {
            let normalized = normalizedObject(object)
            builder.total = builder.total ?? numericValue(for: ["currentaccounttotalbalance", "currenttotalbalance", "totalbalance", "totalcredits", "creditbalance"], in: normalized)
            let label = ["label", "name", "typename", "credittype", "creditname", "category", "title"].compactMap { normalized[$0] as? String }.first?.lowercased() ?? ""
            let amount = numericValue(for: ["remaining", "remain", "available", "amount", "balance", "credits", "credit", "value"], in: normalized)
            if let amount {
                if containsAny(label, ["会员", "订阅", "membership", "subscription", "vip"]) { builder.membership = builder.membership ?? amount }
                else if containsAny(label, ["充值", "通用", "recharge", "topup", "general"]) { builder.recharge = builder.recharge ?? amount }
                else if containsAny(label, ["模型卡", "模型专享", "modelcard", "model card"]) { builder.modelCard = builder.modelCard ?? amount }
                else if containsAny(label, ["免费", "赠送", "free", "gift"]) { builder.free = builder.free ?? amount }
            }
            for nested in object.values { collectQuota(value: nested, builder: &builder) }
        } else if let array = value as? [Any] {
            for nested in array { collectQuota(value: nested, builder: &builder) }
        }
    }

    private static func embeddedAccountRef(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findString(keys: ["accountid", "account_id", "activeaccountid", "teamid"], value: value)
    }

    private static func planFromJSON(_ raw: String) -> ParsedPlan? {
        guard let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findPlan(value: json, currentAccountContext: false, inheritedName: nil)
    }

    private static func findPlan(value: Any, currentAccountContext: Bool, inheritedName: String?) -> ParsedPlan? {
        if let object = value as? [String: Any] {
            let normalized = normalizedObject(object)
            let directEvidence = currentAccountContext
                || ["accountlevel", "accountlevelname", "mempkgid", "currentplan", "effectiveplan"].contains(where: { normalized[$0] != nil })
                || ["iscurrent", "current", "effective", "active"].contains(where: { normalized[$0] as? Bool == true })
            let name = ["accountlevelname", "planname", "packagename", "membershipname", "vipname", "levelname"].compactMap { normalized[$0] as? String }.first ?? inheritedName
            let attr = (normalized["attr"] as? [String: Any]).map(normalizedObject)
            let concurrency = ["concurrent", "maxconcurrency", "concurrency", "concurrentlimit", "parallelcount", "maxparallelcount", "concurrencylimit", "simultaneoustasks"]
                .compactMap { normalized[$0] ?? attr?[$0] }.first
            let explicitlyUnlimited = ["unlimitedconcurrency", "isunlimited", "concurrencyunlimited"].compactMap { normalized[$0] as? Bool ?? attr?[$0] as? Bool }.contains(true)
            if directEvidence, explicitlyUnlimited { return ParsedPlan(name: name, maxConcurrency: nil, unlimited: true, evidence: "页面结构化套餐数据") }
            if directEvidence, let parsed = concurrencyToken(concurrency) {
                return ParsedPlan(name: name, maxConcurrency: parsed.value, unlimited: parsed.unlimited, evidence: "页面结构化套餐数据")
            }
            for (key, nested) in object {
                let normalizedChildKey = normalizedKey(key)
                let childContext = directEvidence || ["vipinfo", "membership", "currentmembership", "userplan", "accountplan"].contains(normalizedChildKey)
                if let found = findPlan(value: nested, currentAccountContext: childContext, inheritedName: name) { return found }
            }
        } else if let array = value as? [Any] {
            // Never inherit current-account evidence into an array: viphome also embeds
            // purchasable SKU lists whose concurrency must not be mistaken for this user.
            for nested in array { if let found = findPlan(value: nested, currentAccountContext: false, inheritedName: nil) { return found } }
        }
        return nil
    }

    private static func concurrencyToken(_ value: Any?) -> (value: Int?, unlimited: Bool)? {
        if let number = value as? NSNumber {
            if isBoolean(number) { return nil }
            let int = number.intValue
            return int < 0 ? (nil, true) : (int, false)
        }
        if let string = value as? String {
            let normalized = string.lowercased()
            if normalized.contains("无限") || normalized.contains("unlimited") { return (nil, true) }
            if let int = Int(normalized.filter(\.isNumber)) { return (int, false) }
        }
        return nil
    }

    private static func findString(keys: Set<String>, value: Any) -> String? {
        if let object = value as? [String: Any] {
            for (key, value) in object where keys.contains(normalizedKey(key)) {
                if let string = value as? String, !string.isEmpty { return string }
                if let number = value as? NSNumber { return number.stringValue }
            }
            for nested in object.values { if let found = findString(keys: keys, value: nested) { return found } }
        } else if let array = value as? [Any] {
            for nested in array { if let found = findString(keys: keys, value: nested) { return found } }
        }
        return nil
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }

    private static func normalizedObject(_ object: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: object.map { (normalizedKey($0.key), $0.value) })
    }

    private static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func numericValue(for keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let number = value as? NSNumber {
                if isBoolean(number) { continue }
                return number.doubleValue
            }
            if let string = value as? String, let number = parseNumber(firstCapture("([0-9][0-9,.]*)", in: string) ?? string) { return number }
        }
        return nil
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{00a0}", with: " ")
    }

    private static func firstCapture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func captures(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private struct QuotaBuilder {
    var total, membership, recharge, modelCard, free: Double?
    var isComplete: Bool { total != nil && membership != nil && recharge != nil && modelCard != nil && free != nil }
    var hasAnyValue: Bool { total != nil || membership != nil || recharge != nil || modelCard != nil || free != nil }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
