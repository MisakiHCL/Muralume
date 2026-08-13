# Muralume 仓库协作规则

## “双端新版本发布”触发规则

当用户说“完整双端发布”“双端新版本发布”或含义相同的话时，默认是指：从同一个已推送的 `main` 提交，同时完成 GitHub Developer ID 正式发布和 App Store Connect/TestFlight 发布。

执行前必须完整阅读 [`Documentation/DUAL_RELEASE_PLAYBOOK.md`](Documentation/DUAL_RELEASE_PLAYBOOK.md)，并遵守以下约束：

- 唯一正式发布入口是 `make release-dual`。不得把 `release-macos`、`validate-testflight`、`upload-testflight`、手工 Tag 或手工 GitHub Release 串联成正式发布流程。
- 完整门禁只由 `release-dual` 在不可变源码快照上运行一次，并通过 source/Xcode 绑定的 shared gate receipt 复用于双端构建。发布窗口内不要预先重复运行 `make test` 和 `./Scripts/verify.sh release-gate`。
- 代理负责范围确认、版本与构建号、Release Notes、候选提交、推送、双端发布和最终远端核对。`release-dual` 会在内部先执行 doctor；不得在 clean 正式路径前再例行调用一次 `make release-doctor`。常规流程只在创建/轮换 App Store Connect Team API key、Apple 2FA 或新协议确认时请求用户手动操作。
- TestFlight 为 `PROCESSING` 时不得换构建号、重复上传或宣布成功；按 playbook 使用 `make release-status` 等待，变为 `VALID` 后从相同提交恢复 `make release-dual`。
- 只有 GitHub Release、annotated Tag、TestFlight 构建、`main` 和 `origin/main` 都解析到同一提交，附件与摘要通过复验且工作区干净，才可报告完整发布成功。
- 从干净、已推送的候选提交开始，凭据已就绪且 Apple 服务正常时，自动发布主动耗时以 30 分钟内完成为目标。Apple `PROCESSING`、2FA 和协议确认的外部等待不作 30 分钟保证；超预算时立即报告当前阶段，不以重复完整测试作为默认排障手段。
