# Qumo Runner for macOS

Qumo Runner 是面向 macOS 14+ / Apple Silicon 的原生 Runner 运维客户端。工程包含：

- `QumoRunnerApp`：SwiftUI Dock 应用，提供总览、任务、账号、日志与设置。
- `QumoRunnerAgent`：由 `SMAppService` 注册的用户级 LaunchAgent，App 窗口关闭后继续运行。
- `RunnerCore`：App 与 Agent 共用的 Runner 状态机、LibTV、API 与本地持久化代码。

第一版面向专用 Mac mini，本机开发签名、手工安装，不启用 App Sandbox，也不制作 DMG。

## 前置条件

- Apple Silicon Mac，macOS 14 或更新版本
- 完整 Xcode 16 或更新版本（仅安装 Command Line Tools 不足以构建 `.app`）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 已核验的 LibTV CLI 1.0.2 ARM64 构建输入。默认读取 `$HOME/.libtv/libtv`，也可通过 `QUMO_LIBTV_SOURCE` 指定绝对路径；56 MB 二进制不提交到仓库。该文件必须是固定校验和的 1.0.2，不能直接使用已自助升级的当前 CLI。

## 生成与构建

```bash
cd /path/to/QumoRunner-macOS
./Scripts/generate-project.sh
QUMO_LIBTV_SOURCE='/absolute/path/to/verified/libtv-1.0.2' \
  xcodebuild -project QumoRunner.xcodeproj \
  -scheme QumoRunner \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```

在真实 Mac mini 上，请在 Xcode 中选择本机开发团队再进行开发签名构建。构建阶段会把 `QumoRunnerAgent` 复制到 App 的 `Contents/Resources/QumoRunnerAgent`，把 LaunchAgent plist 复制到 `Contents/Library/LaunchAgents`，并在校验通过后把 LibTV 复制到 `Contents/Resources/Tools/libtv`。运行时始终使用这个绝对路径，不读取 `PATH`。

`SMAppService` 的持久 LaunchAgent 必须使用可信的 Apple Development 或 Developer ID 签名链。Xcode 的 ad-hoc “Sign to Run Locally” 可以启动前台 App，但在部分 macOS 版本上会被 Launch Constraint 拒绝。请先在 Xcode 的 Accounts 设置中登录开发者账号并创建 Apple Development 证书，然后选择同一个 Team 签名 App 与 Agent：

```bash
xcodebuild -project QumoRunner.xcodeproj \
  -scheme QumoRunner \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM='<TEAM_ID>' \
  CODE_SIGN_IDENTITY='Apple Development' build
```

安装前可运行 `security find-identity -v -p codesigning`，确认至少存在一个有效 Apple Development 身份；同时用 `codesign --verify --deep --strict 'Qumo Runner.app'` 验证完整 App Bundle。

## 安装与启动

1. 将开发签名后的 `Qumo Runner.app` 复制到 `/Applications`。
2. 启动 App。首次启动会用 `SMAppService` 注册 `com.qumo.runner.agent.plist`。
3. 若 macOS 要求批准后台项目，在“系统设置 → 通用 → 登录项与扩展”中允许 Qumo Runner。
4. 在“设置”中输入 Canvas API 地址与 10 分钟有效、单次使用的配对码。
5. 在“账号”中添加至少两个独立 LibTV 登录身份并执行健康检查。

关闭最后一个窗口只关闭界面，后台 Agent 继续运行。要同时停止领取并注销 Agent，请使用 App 菜单的“停止服务并退出…”。

## XPC 契约

App 通过用户级 Mach Service `com.qumo.runner.agent.service` 连接 Agent。为减少进程间模型版本耦合，XPC 接口只传输 Foundation 类型：

- `fetchSnapshot(reply: Data)`：返回 ISO-8601 日期编码的 `RunnerSnapshot` JSON。
- `performCommand(_:payload:reply:)`：payload 为 `[String:String]` JSON，response 为 `AgentCommandResponse` JSON。
- `ping(reply:)`：连通性与版本探测。

UI 已固定以下控制语义：

- “暂停领取”只停止新 Claim，已经运行的任务继续。
- `queued / leased` 阶段才显示“取消（尚未提交）”。
- `submitting / running` 只能“停止跟踪”，远端任务不称为已取消，并进入 `needs_review`。
- `needs_review` 不自动重试或重新提交，只允许人工核对后确认结果。

Agent 为新租约保留 8 秒提交前窗口。窗口内取消由 `RunnerEngine` 原子协调本地任务与服务端 `leased → cancelled`；一旦进入 `submitting`，界面只允许“停止跟踪”。

账号页使用 XPC 命令 `authorize_chrome_profile` / `refresh_account_insights` / `refresh_model_catalog` 主动驱动后台。授权命令运行当前 Profile 隔离 HOME 下的 `libtv login web`，App 使用该 Profile 专属的 Chrome 用户数据目录打开官方一次性 URL。获取该 URL 和等待用户完成 Chrome 登录都不设超时，直到进程明确失败、授权成功或用户主动取消；获取 URL 期间也会显示可取消的临时 Profile 并防止重复点击。授权回调完成后自动刷新账号、积分、套餐和模型。新增账号在真实 ID 校验和去重成功前保持临时状态，失败或重复会自动回滚。旧 `open_web_login` 命令仅作为兼容别名保留。

## 设备凭证与本地数据

- 配对成功后，原始设备 Token 只写入登录 Keychain，使用 `AfterFirstUnlockThisDeviceOnly` 可访问级别。
- LibTV Profile 位于 `~/Library/Application Support/QumoRunner/Profiles/{profile-id}`，Profile 目录必须为 `0700`，凭证必须为 `0600`。
- 诊断 ZIP 会脱敏 Token、Authorization、密码与密钥，不包含 `credentials.json`。
- Runner 不读取或复制日常 Chrome 的 Cookie、历史、密码、local storage 和 session storage。每个 Profile 的 `chrome-auth` 目录权限为 `0700`，只用于隔离官方授权会话；LibTV CLI 凭据继续保存在权限为 `0600` 的 Profile `credentials.json` 中。
- 服务端只接收非敏感账号元数据、积分数值、套餐并发和模型 hash/模态，不接收 LibTV Token、Cookie 或 Profile 文件。

## 积分、套餐与模型目录

- Agent 在启动、登录完成和人工请求时刷新；同一 Profile 任务结束后使用 60 秒可重置防抖合并刷新。定时刷新为 15 分钟加 0–120 秒的 Profile 稳定抖动，同一 Profile 由 SingleFlight 去重。
- 积分解析要求“当前账户总余额”与会员订阅、通用充值、模型卡、免费四个 bucket 同时可识别。只有成功解析且总额为 0 才把有效并发设为 0；抓取失败不会误判零额。
- 网络、429/5xx 错误只可在 10 分钟内使用陈旧积分；套餐的最后可用值最长 24 小时。`web_auth_required` 和授权身份不匹配不影响其他 Profile。
- 套餐有效并发取套餐检测值和全局上限的较小值；无限套餐受全局上限限制，未能明确解析时保守回退为 2。缩容只阻止新 Claim，不终止已运行任务。
- 模型目录每 6 小时检索 image/video/audio/text/script/storyboard 六种模态。只有新增或摘要 hash 变化的模型才查询完整 schema；新增为 `pending`，schema 变更为 `changed`，连续两次缺失为 `removed`。

## LibTV 校验

把二进制嵌入 App 前执行：

```bash
./Scripts/verify-bundled-libtv.sh "$HOME/.libtv/libtv" \
  8605ff53e9f2185f09ba59597ba811e12d90294411ae15710e334be56a4d6e34
```

如果 `$HOME/.libtv/libtv` 已是更新版本，请将从旧 App Bundle 或官方版本化 ZIP 获得的已验证 1.0.2 放在独立路径，并在构建时指定：

```bash
QUMO_LIBTV_SOURCE='/absolute/path/to/verified/libtv-1.0.2' \
  xcodebuild -project QumoRunner.xcodeproj \
  -scheme QumoRunner \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM='<TEAM_ID>' \
  CODE_SIGN_IDENTITY='Apple Development' build
```

不要从旧 Mac 复制 Keychain 设备 Token、`credentials.json`、Chrome 数据、本地 SQLite 或 Runtime 激活状态。新 Mac 应使用 Qumo 管理后台生成的单次配对码，并为每个 LibTV Profile 重新执行 Chrome 授权。Runner 只通过 HTTPS 连接 Canvas API，运行时不需要云服务器 SSH 私钥。

脚本会校验当前架构、固定 SHA-256、严格代码签名与版本字符串 `1.0.2`。Agent 启动时还会调用 `RunnerCore.LibTVBinaryVerifier` 重复校验；任何一项失败都会进入 `degraded`、禁止登录与 Claim。LibTV 只能通过绝对路径与 `Process.arguments` 启动，禁止使用 shell 或依赖 `PATH`。

## 本地验证

运行构建与 Agent 纯解析测试：

```bash
QUMO_LIBTV_SOURCE='/absolute/path/to/verified/libtv-1.0.2' \
  xcodebuild -project QumoRunner.xcodeproj \
  -scheme QumoRunner \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test
```

当前代码已通过 Xcode 16.4、macOS 15.5 SDK、Swift 6 严格并发的完整 Debug 构建；RunnerCore 103 项测试以及 Agent/App 42 项测试全部通过。当前 Mac 已完成可信开发签名安装、`SMAppService` 拉起、旧 Profile 账号标识迁移和真实 Liblib 套餐/积分手动刷新验证；多账号并行与 72 小时故障验收仍需在专用 Mac mini 持续执行。

## CLI 兼容与升级

业务任务继续使用 `LibTVGenerationSpecV1`。模型参数由审批过的原始 Schema 映射；CLI 命令语法及输出解析入口集中在 `Sources/RunnerCore/LibTVCLIAdapter.swift`，当前契约为 `libtv-cli-v1`。

拿到新版本后，先对已下载、可信的可执行文件运行只读检查：

```bash
swift run --package-path . libtv-contract-check /absolute/path/to/libtv
```

以上命令从 Runner 仓库根目录运行，只调用 `--version` 和各命令的 `--help`，使用临时 HOME，输出版本、SHA-256、适配器 ID 和标准化命令指纹。它不改变本机版本，不登录或生成媒体，也不代替官方签名验证。语法不匹配时返回失败。回归样本 `Tests/RunnerCoreTests/Resources/cli-contract-*.json` 采集自实际的 1.0.2 和 1.1.3 二进制，包含对应 SHA-256；不代表这些版本都已获生产批准。

升级顺序：

1. 管理后台发现官方版本，使用隔离账号验证。下载器先验证签名/校验和，再验证 CLI 语法；失败时保留当前版本。
2. 执行原有图片/视频队列验收，检查真实参数、结果解析、远端 ID 和产物；审核 Schema 差异。帮助文本只证明命令形状，不能证明参数和服务端行为保持不变。
3. 管理员批准，等待任务清空后激活。目标 Runner 再次验证本地适配器与命令契约；启动失败时使用已验证兜底。回滚前也检查目标二进制。
4. 任务记录 Runtime 版本/校验和及适配器 ID。准备隐藏画布、提交和恢复查询均使用该绑定。旧任务缺失所需适配器时进入复核，不换版本重提。

兼容的 CLI 升级可沿用 v1 适配器，无需仅为版本号重新发布 App。模型字段变化走现有 Schema 同步/审批；命令或输出含义发生不兼容变化时，新增适配器版本、帮助/输出回归样本并发布 Runner，再重新执行隔离验收。不要原地改变 v1 的含义，旧任务仍可能需要它。当前只实现 v1，未知适配器会拒绝执行；未来增加版本时需同时补充选择和旧任务分派。

升级本功能前产生的通过/批准记录缺少 `cli_contract` 时，后台会要求重新验证，且不能再用于批准或激活。先更新 Runner，再从该版本卡片的“隔离验证”入口补齐证据；当前已运行任务保持自己的版本绑定。

## Runner CLI 自助更新（2026-09-04）

- Runner 启动时及每 6 小时检查 LibTV 官网 CLI 页面和官方安装清单，设置页提供手动检查、来源和成功检查时间。只解析官方版本化安装链接；官网无版本号、清单滞后或网络失败时明确说明，不误报“已是最新版”，不自动降级。
- 发现较新版本时，总览和系统通知提示更新；用户可以直接下载并更新，也可在清单滞后时填写已发布的官方版本号。安装仅使用官方 HTTPS 版本路径，并验证官方签名、架构、SHA-256、版本和当前命令契约。
- 更新期间保持心跳和已有任务查询，独立维护锁禁止新领取及并发版本切换。等待所有现有任务和在途 Claim 排空后原子切换，保留之前版本用于设置页回滚；切换失败恢复原版。已提交任务保留原 Runtime，不重复提交。
- 运行版本与内嵌恢复版本分开显示。切换后重新绑定执行器并强制刷新模型 Schema；拒绝旧版本未完成的目录查询覆盖新版结果。命令格式不兼容时提示需更新 Runner，不能把任意上游失败自动归咎于业务代码。
- 本机自助更新与管理员批量验证/发布并存；不要求为每次兼容 CLI 更新创建新 Runner 版本，也不自动发起付费图片/视频测试。

## Runner 夜间维护窗口与参数验证（2026-09-04）

- 默认启用本机时区每日 03:00–04:00 的 CLI 自动更新窗口，设置页可关闭；仅在发现新版、最近检查成功且 Runner 空闲、未手动暂停时启动。忙碌则在窗口内等待，错过窗口顺延下一晚，每晚最多尝试一次；不自动升级到未发现的猜测版本。
- 下载与签名/命令验证先于暂停领取；下载最多 5 分钟。开始切换前暂停领取并排空已有任务和在途 Claim，窗口结束前仍未能切换则保留当前版本，等待下一晚。
- 模型参数缓存持久化其对应的不可变 CLI 路径。旧数据迁移、重启或版本切换时，缓存未匹配当前 CLI 的账号并发为零，禁止用旧 Schema 领取新任务；新版完整目录与 Schema 查询成功后才恢复。
- 更新成功必须包含所有启用且健康账号的参数验证以及执行器重建。整个流程最多 45 分钟，超时取消并等待旧操作退出后恢复原版；恢复及参数验证另有 2 分钟上限，仍失败则保持暂停并提示检查。后台目录失败按至少 60 秒间隔重试，不误判为验证通过。
- 下载、CLI 子进程和同步验证工具均有超时保护。自动更新不会发起付费图片或视频生成；真实生成的验收仍由既有任务和人工验证承担。
