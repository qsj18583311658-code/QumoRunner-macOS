import XCTest

final class AccountInsightParserTests: XCTestCase {
    func testParsesCalculationTotalAndFourBuckets() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分明细",
            bodyText: """
            当前账户总余额：1,234.5
            会员订阅积分 800
            通用充值积分 300.5
            模型卡积分 100
            免费积分 34
            """,
            embeddedJSON: #"{"activeAccountId":"account-42"}"#
        )

        let quota = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: "ACCOUNT-42")

        XCTAssertEqual(quota.total, 1_234.5)
        XCTAssertEqual(quota.membership, 800)
        XCTAssertEqual(quota.recharge, 300.5)
        XCTAssertEqual(quota.modelCard, 100)
        XCTAssertEqual(quota.free, 34)
    }

    func testIncompleteCalculationNeverBecomesZero() {
        let page = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分",
            bodyText: "当前账户总余额 0\n免费积分 0",
            embeddedJSON: nil
        )

        XCTAssertThrowsError(try AccountInsightParser.parseQuota(page: page, expectedAccountRef: nil)) { error in
            guard case WebInsightFailure.parse = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAuthenticationAndIdentityMismatchAreExplicit() {
        let login = WebPagePayload(url: "https://www.liblib.art/login", title: "登录", bodyText: "登录/注册", embeddedJSON: nil)
        XCTAssertThrowsError(try AccountInsightParser.parseQuota(page: login, expectedAccountRef: "a")) { error in
            guard case WebInsightFailure.webAuthRequired = error else { return XCTFail("unexpected \(error)") }
        }

        let mismatch = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分",
            bodyText: "当前账户总余额 5\n会员订阅积分 1\n通用充值积分 1\n模型卡积分 1\n免费积分 2",
            embeddedJSON: #"{"account_id":"other"}"#
        )
        XCTAssertThrowsError(try AccountInsightParser.parseQuota(page: mismatch, expectedAccountRef: "expected")) { error in
            guard case WebInsightFailure.identityMismatch = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testParsesExplicitPlanConcurrency() throws {
        let structured = WebPagePayload(
            url: "https://www.liblib.art/viphome",
            title: "会员",
            bodyText: "",
            embeddedJSON: #"{"membership":{"planName":"Pro","maxConcurrency":6}}"#
        )
        let plan = try AccountInsightParser.parsePlan(page: structured)
        XCTAssertEqual(plan.name, "Pro")
        XCTAssertEqual(plan.maxConcurrency, 6)
        XCTAssertFalse(plan.unlimited)

        let unlimited = WebPagePayload(url: structured.url, title: structured.title, bodyText: "当前套餐：Enterprise\n并发上限：无限", embeddedJSON: nil)
        let unlimitedPlan = try AccountInsightParser.parsePlan(page: unlimited)
        XCTAssertTrue(unlimitedPlan.unlimited)
        XCTAssertNil(unlimitedPlan.maxConcurrency)
    }

    func testPrefersCapturedStructuredQuotaAndAcceptsBucketRows() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/calculation?tab=credits",
            title: "账户积分",
            bodyText: "页面正在加载",
            embeddedJSON: #"{"apiResponses":[{"url":"https://www.liblib.art/api/account","body":{"data":{"activeAccountId":"account-9","totalBalance":"1,000.5","creditBuckets":[{"typeName":"会员订阅积分","remaining":600},{"typeName":"通用充值积分","remaining":"250.5"},{"typeName":"模型卡积分","remaining":100},{"typeName":"免费积分","remaining":50}]}}}]}"#
        )

        let quota = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: "ACCOUNT-9")

        XCTAssertEqual(quota.total, 1_000.5)
        XCTAssertEqual(quota.membership, 600)
        XCTAssertEqual(quota.recharge, 250.5)
        XCTAssertEqual(quota.modelCard, 100)
        XCTAssertEqual(quota.free, 50)
    }

    func testStructuredQuotaCanMergeWithTolerantTextFallback() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分",
            bodyText: "会员订阅积分\n800\n通用充值积分：300\n模型专享积分 100\n免费积分 34",
            embeddedJSON: #"{"initialState":{"account":{"currentAccountTotalBalance":1234,"active_account_id":"same"}}}"#
        )

        let quota = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: "same")
        XCTAssertEqual(quota.total, 1_234)
        XCTAssertEqual(quota.membership, 800)
        XCTAssertEqual(quota.recharge, 300)
        XCTAssertEqual(quota.modelCard, 100)
        XCTAssertEqual(quota.free, 34)
    }

    func testLabelThenValueLayoutDoesNotReusePreviousCardValue() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分",
            bodyText: """
            当前账户总余额
            1234
            会员订阅积分
            800
            通用充值积分
            300
            模型卡积分
            100
            免费积分
            34
            """,
            embeddedJSON: nil
        )

        let quota = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: nil)
        XCTAssertEqual(quota.total, 1_234)
        XCTAssertEqual(quota.membership, 800)
        XCTAssertEqual(quota.recharge, 300)
        XCTAssertEqual(quota.modelCard, 100)
        XCTAssertEqual(quota.free, 34)
    }

    func testParsesPlanAliasesAndExplicitUnlimitedFlag() throws {
        let finite = WebPagePayload(
            url: "https://www.liblib.art/viphome",
            title: "会员",
            bodyText: "",
            embeddedJSON: #"{"apiResponses":[{"body":{"vipInfo":{"accountLevelName":"Studio Pro","packageInfo":{"attr":{"concurrent":"8个任务"}}}}}]}"#
        )
        let parsed = try AccountInsightParser.parsePlan(page: finite)
        XCTAssertEqual(parsed.name, "Studio Pro")
        XCTAssertEqual(parsed.maxConcurrency, 8)

        let unlimited = WebPagePayload(
            url: finite.url,
            title: finite.title,
            bodyText: "",
            embeddedJSON: #"{"membership":{"levelName":"Enterprise","unlimitedConcurrency":true}}"#
        )
        let unlimitedParsed = try AccountInsightParser.parsePlan(page: unlimited)
        XCTAssertEqual(unlimitedParsed.name, "Enterprise")
        XCTAssertTrue(unlimitedParsed.unlimited)
    }

    func testParsesOfficialQuotaShapeAndDerivedTotal() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分",
            bodyText: "",
            embeddedJSON: #"{"apiResponses":[{"url":"https://api2.liblib.art/vip","body":{"vipInfo":{"attr":{"usablePower":100,"libtvUsablePower":20,"rechargeUsablePower":70,"freeUsablePower":30,"exPowerSummary":{"usablePower":5}}}}},{"url":"https://api2.liblib.art/member-power","body":{"data":{"list":[{"memberId":"member-1","currentPower":{"balance":40}}]}}}]}"#
        )

        let quota = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: nil)
        XCTAssertEqual(quota.total, 125)
        XCTAssertEqual(quota.membership, 40)
        XCTAssertEqual(quota.recharge, 70)
        XCTAssertEqual(quota.modelCard, 5)
        XCTAssertEqual(quota.free, 30)
    }

    func testOfficialQuotaRequiresMemberPowerUnlessMembershipIsInactive() throws {
        let incomplete = WebPagePayload(
            url: "https://www.liblib.art/calculation",
            title: "积分",
            bodyText: "",
            embeddedJSON: #"{"vipInfo":{"attr":{"usablePower":10,"libtvUsablePower":2,"rechargeUsablePower":8,"freeUsablePower":2,"exPowerSummary":{"usablePower":1}}}}"#
        )
        XCTAssertThrowsError(try AccountInsightParser.parseQuota(page: incomplete, expectedAccountRef: nil))

        let inactive = WebPagePayload(
            url: incomplete.url,
            title: incomplete.title,
            bodyText: "",
            embeddedJSON: #"{"vipInfo":{"effective":false,"attr":{"usablePower":10,"libtvUsablePower":2,"rechargeUsablePower":8,"freeUsablePower":2,"exPowerSummary":{"usablePower":1}}}}"#
        )
        let quota = try AccountInsightParser.parseQuota(page: inactive, expectedAccountRef: nil)
        XCTAssertEqual(quota.membership, 0)
        XCTAssertEqual(quota.total, 13)
    }

    func testDoesNotTreatPurchasableSKUAsCurrentPlan() {
        let page = WebPagePayload(
            url: "https://www.liblib.art/viphome",
            title: "会员",
            bodyText: "",
            embeddedJSON: #"{"packages":[{"productName":"SKU Pro","attr":{"concurrent":99}}]}"#
        )

        XCTAssertThrowsError(try AccountInsightParser.parsePlan(page: page))

        let nestedPackage = WebPagePayload(
            url: page.url,
            title: page.title,
            bodyText: "",
            embeddedJSON: #"{"packages":[{"packageInfo":{"attr":{"concurrent":99}}}]}"#
        )
        XCTAssertThrowsError(try AccountInsightParser.parsePlan(page: nestedPackage))
    }

    func testParsesCurrentPackageInfoConcurrent() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/viphome",
            title: "会员",
            bodyText: "",
            embeddedJSON: #"{"vipInfo":{"accountLevelName":"创作会员","packageInfo":{"attr":{"concurrent":4}}}}"#
        )

        let plan = try AccountInsightParser.parsePlan(page: page)
        XCTAssertEqual(plan.name, "创作会员")
        XCTAssertEqual(plan.maxConcurrency, 4)
    }

    func testParsesCredentialAuthenticatedAccountEnvelope() throws {
        let page = WebPagePayload(
            url: "https://api2.liblib.art/api/www/member/account?isApp=false",
            title: "Liblib account APIs",
            bodyText: "",
            embeddedJSON: #"{"activeAccountId":"5001033","apiResponses":[{"url":"https://api2.liblib.art/api/www/member/account?isApp=false","body":{"code":0,"data":{"accountLevel":7,"accountLevelName":"至尊版VIP","effective":true,"attr":{"usablePower":100,"libtvUsablePower":20,"rechargeUsablePower":70,"freeUsablePower":30,"concurrent":3,"exPowerSummary":{"usablePower":5}}}}},{"url":"https://api2.liblib.art/api/www/member/memberPower/list","body":{"code":0,"data":{"list":[{"currentPower":{"balance":40}}]}}}]}"#
        )

        let quota = try AccountInsightParser.parseQuota(page: page, expectedAccountRef: "5001033")
        let plan = try AccountInsightParser.parsePlan(page: page)

        XCTAssertEqual(quota.total, 125)
        XCTAssertEqual(quota.membership, 40)
        XCTAssertEqual(plan.name, "至尊版VIP")
        XCTAssertEqual(plan.maxConcurrency, 3)
    }

    func testParsesUniqueCurrentPlanTaskCountText() throws {
        let page = WebPagePayload(
            url: "https://www.liblib.art/viphome",
            title: "会员",
            bodyText: "我的会员\n创作会员\n权益详情\n并发任务数 4 个",
            embeddedJSON: nil
        )
        let plan = try AccountInsightParser.parsePlan(page: page)
        XCTAssertEqual(plan.maxConcurrency, 4)
    }
}
