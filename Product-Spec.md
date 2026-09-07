# Qumo Runner macOS 产品边界

## 目标

Qumo Runner 是部署在公司专用 Apple Silicon Mac mini 上的原生生成任务执行器。它由 SwiftUI 运维 App、`SMAppService` 用户级 LaunchAgent 和共享 `RunnerCore` 组成，支持 macOS 14 或更新版本。

Canvas Web/API、PostgreSQL、对象存储和 Codex Agent 保持在 Qumo 服务器中。Mac mini 只执行 LibTV 生成任务，不承载业务数据库或画布 Agent。

## 必须保持的契约

- 任务状态为 `queued -> leased -> submitting -> running -> succeeded / failed / cancelled / needs_review`。
- 取得远端任务 ID 后只允许查询，禁止换 Runtime、换账号或重新提交。
- 生产输入只接受 `LibTVGenerationSpecV1`，最终参数必须经当前 Profile 已批准 Schema 展开。
- 每个 LibTV 账号使用独立 Profile HOME。同一 Profile 的 CLI 调用串行，远端任务可在套餐和全局限额内并行。
- Runner 设备 Token 只保存在本机 Keychain；LibTV 凭据只保存在对应 Profile；两者均不得上传服务器、日志、诊断包或 Git。
- App Bundle 内保留经验证的 LibTV 1.0.2 ARM64 最终兜底。外置 Runtime 只能来自官方版本化 HTTPS ZIP，并验证版本、SHA-256、arm64、严格签名和 Team ID `U5N2L989V7`。
- 关闭 App 窗口不停止 Agent；只有“停止服务并退出”才注销后台服务。

## 新 Mac mini 迁移

1. 使用完整 Xcode 16+、XcodeGen 和可信 Apple Development 身份构建 App 与 Agent。
2. 通过 `QUMO_LIBTV_SOURCE` 提供经验证的 1.0.2 ARM64 构建输入；签名前执行仓库校验脚本。
3. 将 App 安装到 `/Applications`，批准后台项目，先保持“暂停领取”。
4. 使用 `https://qmoreai.com` 和管理后台的 10 分钟单次配对码创建新设备身份。
5. 在新设备逐个重新授权 LibTV 账号，同步积分、套餐、模型目录和 Schema。
6. 通过完整网页、任务队列和 Artifact 链路验收图片、视频及双账号并发。付费验收必须事先获得用户确认。
7. 新 Runner 开始领取前暂停旧 Runner；保留旧机器一个版本周期用于回滚，不允许新旧机器同时领取生产任务。

## 仓库安全边界

仓库不包含 LibTV 二进制、App 构建产物、Apple 签名私钥、SSH 私钥、Runner Token、LibTV 凭据、Chrome 资料、Runtime 激活状态和本地任务数据库。Runner 运行时通过 HTTPS 设备配对通信，不需要云服务器 SSH 私钥。
