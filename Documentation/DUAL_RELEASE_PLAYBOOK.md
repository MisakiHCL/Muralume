# Muralume 双端发布操作手册

本文是 Muralume 新版本的正式发布规范。目标是在候选提交已干净推送、凭据已配置且 Apple 服务正常的情况下，用不超过约 30 分钟的自动发布主动耗时，从这个确定的 `main` 提交完成：

- GitHub 上的 Developer ID 签名、公证 DMG 正式 Release；
- App Store Connect 中的同版本 TestFlight 构建；
- Tag、Release、TestFlight、`main` 的来源一致性和远端复验。

## 唯一正式入口

正式发布只运行：

```bash
make release-dual \
  RELEASE_TITLE='Muralume vX.Y.Z — release title' \
  RELEASE_NOTES_FILE='/absolute/path/to/RELEASE_NOTES_VX.Y.Z.md'
```

`release-dual` 会锁定一个干净且已推送的 `main` 提交，在 detached snapshot 上运行一次 shared `all` gate，并将 source commit、source tree、Xcode 版本和 gate 脚本绑定到私有 receipt。Developer ID 与 App Store 两条构建分支只消费该 receipt，不各自重跑完整门禁。

以下 target 是开发、诊断或受控恢复工具，不是另一套正式发布方案：

- `make release-doctor`（首次配置、凭据变更或失败诊断）
- `make release-status`（部分发布后的等待与恢复）
- `make release-macos`
- `make mas-preflight`
- `make validate-testflight`
- `make upload-testflight`
- `./Scripts/verify.sh release-gate`

不得依次调用这些 standalone target 来代替 `release-dual`，也不得手工补 Tag、公开 GitHub Release 或重复上传 TestFlight。这样做会绕过 shared gate、远端状态机和 provenance 校验，并使一次发布重复执行昂贵测试。

## 一次性工作站配置

这些配置必须在发布窗口前完成。所有私密文件均须是普通文件、权限 `0600`，不得提交到 Git：

1. `Config/Release.local.mk`
   - `MURALUME_DEVELOPER_ID_APPLICATION`
   - `MURALUME_NOTARY_KEYCHAIN_PROFILE`
   - `MURALUME_EXPECTED_TEAM_IDENTIFIER`
   - Keychain 中必须有匹配的 Developer ID Application 证书与私钥，以及可用的 `notarytool` profile。
2. `Config/Distribution.requirements`
   - 只能通过 `make prepare-distribution-requirements` 生成，不能手写或从旧 App/Archive 复制。
3. `Config/AppStore.local.xcconfig`
   - 只填写与 App Store Connect App 一致的 Team ID；保留 automatic signing，profile selector 留空。
   - Xcode Settings 中预先登录同一 Team，让 Xcode 管理 distribution certificate 和 provisioning profile。
4. `Config/AppStoreConnect.local.mk`
   - `MURALUME_ASC_KEY_ID`
   - `MURALUME_ASC_ISSUER_ID`
   - `MURALUME_ASC_PRIVATE_KEY_PATH`
   - 必须使用 App Store Connect **Team API key**；`.p8` 存在仓库之外且权限为 `0600`。
5. GitHub 与本机环境
   - `gh auth status --hostname github.com` 可访问并写入 `MisakiHCL/Muralume`；正常 Git 凭据可推送 `main` 和 Tag。
   - Xcode license/first-launch 已完成，至少有 15 GiB 可用空间。
   - 本地代理变量要么指向正在运行的代理，要么在发布前取消，不能把归档完成后的网络请求送到失效端口。

常规发布中，代理应自行完成所有可自动化操作。只有以下交互需要用户介入：

- 在 App Store Connect 创建或轮换 Team API key，并安全提供只能下载一次的 `.p8`；
- Apple 或 Xcode 弹出的 2FA；
- Apple 更新开发者协议、付费协议或税务/银行协议后的账户持有人确认。

Developer ID 私钥、notary profile 或 Xcode Team 登录缺失属于工作站配置损坏，应在发布前修复，不能在正式流程中绕过或临时改成手工签名。

## 发布候选准备

### 1. 确认版本范围

- 获取 `origin/main` 和 Tags 的最新状态，确认本地位于 `main`。
- 阅读当前请求中点名的任务/对话，并检查从最近正式 Tag 到 `HEAD` 的全部未发布提交和实际 diff。
- 确认工作区中的既有改动归属；不得覆盖无关用户改动。
- 确认目标 Tag、GitHub Release 和 App Store Connect 构建号尚未被其他来源占用。如果存在部分发布，先进入“恢复与等待”，不要新建并行状态。

### 2. 设置版本和构建号

- `Config/Base.xcconfig`
  - `MARKETING_VERSION = X.Y.Z`
  - `CURRENT_PROJECT_VERSION = D`（Developer ID 构建号）
- `Config/AppStore.xcconfig`
  - `MARKETING_VERSION = X.Y.Z`
  - `CURRENT_PROJECT_VERSION = A`（App Store/TestFlight 构建号）

两个 `MARKETING_VERSION` 必须相同。`D` 和 `A` 都必须是未使用的整数、均高于两个渠道的全部历史构建号，且 `A > D`。正常做法是以已知最大历史构建号为基准，Developer ID 使用 `max + 1`，App Store 使用 `max + 2`；不得让 Xcode 在 export 时自动改号。

### 3. 准备同提交的发布材料

- 根据实际提交编写并跟踪 `RELEASE_NOTES_VX.Y.Z.md`。
- 更新仓库内其他明确展示当前候选版本的位置。
- 只做轻量、定向检查，例如 `git diff --check` 和被编辑配置/文档的静态校验。
- 将候选版本更新提交到 `main` 并推送；记录 `HEAD^{commit}` 与 `HEAD^{tree}`。
- 确认工作区干净，并且 `HEAD == origin/main`。

产品改动应在开发和评审阶段完成 focused tests 与 `make test`。正式发布窗口不再额外运行一遍 `make test` 或独立 `release-gate`：`release-dual` 中的 shared gate 才是该不可变候选提交的最终完整测试、Release 构建门禁和 App Store 预检。

## 30 分钟自动发布预算

预算从干净候选提交已推送、`HEAD == origin/main` 时开始计时，衡量自动发布流程的主动耗时。范围整理、版本与 Notes 编写属于候选准备；Team API key 配置、2FA、协议确认和 Apple `PROCESSING` 的外部等待不作 30 分钟保证。

| 时间 | 阶段 | 完成条件 |
|---|---|---|
| 0–2 分钟 | 内置 fail-fast | `release-dual` 内部 doctor 全部通过 |
| 2–12 分钟 | Shared `all` gate | 同一 source/Xcode 绑定的唯一 gate receipt 生成 |
| 12–20 分钟 | Developer ID | DMG 签名、公证、装订、Gatekeeper 和 SHA-256 通过 |
| 20–27 分钟 | TestFlight | App Store Archive validation/upload 被接受 |
| 27–30 分钟 | 正常远端处理和最终核对 | TestFlight 为 `VALID`，GitHub Release 公开为 Latest，全部来源一致 |

clean 正式路径只有一条命令：

```bash
make release-dual \
  RELEASE_TITLE='Muralume vX.Y.Z — release title' \
  RELEASE_NOTES_FILE='/absolute/path/to/RELEASE_NOTES_VX.Y.Z.md'
```

`release-dual` 会在昂贵构建前内部执行 doctor，检查干净的 `main` 与 `origin/main`、版本对、私密文件权限、签名身份、notary、GitHub CLI/Git push、ASC Team API、Xcode、App Store automatic signing、代理和磁盘空间。任何失败都会在 shared gate 前 fail-fast。

`make release-doctor` 只用于首次配置工作站、凭据/证书/代理发生变化后的预配置验证，或对 `release-dual` 的 doctor 失败做诊断；它不是每次正式发布前的额外步骤。保持 `release-dual` 终端会话运行，并记录 quiet workflow 输出的阶段和耗时。正常流程自动完成：

1. 捕获 immutable source commit/tree；
2. 运行一次 shared `all` gate；
3. 构建 Developer ID Archive 和 DMG，完成签名、公证、staple、Gatekeeper 与 SHA-256 校验；
4. 创建带 commit/tree、DMG digest 和 App Store version/build 的 annotated Tag；
5. 先创建私有 GitHub draft，并上传 `Muralume.dmg`、`Muralume.dmg.sha256`、`Muralume.release-provenance`；
6. 从同一 source 和 gate receipt 构建、校验、validation 并上传 TestFlight；
7. 等待 ASC 返回 `VALID`，再把 GitHub Release 设为 Latest、非草稿、非预发布；
8. 最后重新读取并验证两个远端。

完整门禁对同一个 source commit 最多执行一次。若失败，先依据失败点做 focused diagnosis；确实需要修改代码或脚本时，提交并推送新的候选 commit，然后重新运行唯一正式入口 `release-dual`。不要为了“确认一下”在每次小改后同时运行 `make test`、standalone gate 和两条 standalone 发布。

## 恢复与 `PROCESSING`

`release-dual` 是可恢复事务。失败后保留已经被验证的远端结果，不清理或重建公共状态：

```bash
make release-status
```

- TestFlight 为 `PROCESSING`：这是等待，不是成功或新失败。不得换 build number、不得再次上传、不得公开 GitHub draft、不得报告完整发布成功。间隔查询 `make release-status`，不要用重复归档填满等待时间。
- TestFlight 变为 `VALID`：保持相同 `HEAD`、版本、构建号和 Notes，重新执行同一条 `make release-dual ...`，让状态机验证已有 receipt/provenance 并完成剩余事务。
- 上传已返回接受回执但 ASC 暂时仍显示缺失：不要重试该构建号；等待并使用 `release-status`。
- GitHub draft/附件或 TestFlight 已成功、另一端失败：不要手工补发布。保持相同提交，修复凭据或网络后重跑 `release-dual`；它会验证并复用可证明来源的结果。
- 已公开但不完整的 GitHub Release、来源不匹配的 Tag、`FAILED`/`INVALID` 的 ASC build，或缺失/不匹配的 provenance：停止自动操作并报告精确状态，不能覆盖公共附件、移动 Tag 或伪造 receipt。

Apple 正常 `PROCESSING`、2FA 或协议确认导致墙钟时间超过 30 分钟时，应在第 30 分钟报告：source commit、已完成阶段、外部状态和下一步；这些外部等待不计为自动流程主动耗时，也不代表完整发布成功。等待期间不做第二轮完整测试。

## 最终验收

只有以下全部成立才报告“完整双端发布成功”：

- `make release-status` 通过；TestFlight 中存在目标 version/build，状态为 `VALID`，并有匹配 source provenance。
- GitHub Releases 页面存在目标版本，且为 Latest、非草稿、非预发布。
- Tags 页面存在 annotated `vX.Y.Z`，其 peeled commit 等于发布 source commit。
- `Muralume.dmg`、`Muralume.dmg.sha256` 和 `Muralume.release-provenance` 均可下载；重新计算的 SHA-256 与 checksum/provenance 一致。
- Developer ID DMG 的公证票据、Gatekeeper、签名、entitlements、隐私清单与 provisioning profile 验证均来自本次 workflow 的成功输出。
- GitHub Release、Tag、TestFlight receipt、`HEAD` 与 `origin/main` 指向同一个 commit/tree。
- 本地位于 `main`，`main == origin/main`，工作区干净。

最终汇报应给出版本、Developer ID/App Store 构建号、source commit、Release URL、TestFlight 状态、DMG SHA-256 和工作区状态。任何一端缺失或仍为 `PROCESSING`，只能报告“部分完成/等待”，不能缩写为成功。
