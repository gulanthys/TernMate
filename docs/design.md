# TernMate 技术设计

状态：首版已实现。用户行为以[产品需求](requirements.md)为准。采用 [Tern Luau Block](https://docs.stencil.so/tern/guides/blocks.html)、GitHub CLI、Git 和交互式 omp，不设后端服务，不自建账户系统。

## 安装与使用

在运行 Tern 宿主的机器上准备 `git`、已登录的 `gh` 和 `omp`（支持 Tern 随附路径或宿主 `PATH`）。读取 Actions 日志需要 `gh api --help` 列出 `--allow-escape-sequences`。在插件目录执行：

```sh
tern plugin link .
tern plugin list
```

在项目目录的 Tern 窗口从命令面板打开 **New TernMate**。有多个 GitHub remote 或 fork 上游时先选 `owner/repo`；也可以通过 **本地 checkout…** 指定另一个 Git checkout。`↑`/`↓` 移动选中项，单击或 `Enter` 打开，`Tab` 切换 Issue / PR，`/` 编辑标题关键词，`R` 刷新。快捷筛选会替换当前条件；随后仍可叠加条件或逐项移除。

插件数据目录下的 `task-sessions-v1/` 保存私有任务材料、omp 会话和 PR worktree。关闭面板不删除这些文件；不要为清理空间直接删除其中仍有未提交修改或本地提交的 worktree。

## 模块与数据流

| 边界 | 输入 → 输出 | 职责 |
| --- | --- | --- |
| `plugin.toml`、`host.luau`、`window.luau` | Block 事件 → 视图或异步操作 | 列表、筛选、进度、错误及桌面焦点刷新；`view` 不做 I/O |
| `github.luau`、`runtime.luau` | 本地路径、目标仓库、类型、条件 → 分页条目 | 发现 checkout 和远端仓库；通过 `gh` 查询列表；提供可替换的 argv 执行接口 |
| `materials.luau` | 任务身份、版本 → 私有材料 | Issue 正文与讨论；PR 未解决线程和当前版本的 CI 证据 |
| `sessions.luau`、`session-setup.sh` | 任务身份、材料、来源面板 → 交互式 omp 面板 | 私有目录与工作树、防重、启动、聚焦和恢复 |

入口使用 `--!strict`。进程调用通过一个可替换的 argv 执行函数传入；先按职责隔离，不要求每个职责都有框架或服务。

## 检索、状态与一致性

- 用 Git remote 识别候选仓库，用 `gh` 确认身份与访问权限。选定后查询显式携带 host 和 `owner/repo`；PR 编号属于 base 仓库，代码可能来自 fork。
- 列表按更新时间倒序，编号作为稳定次序。精确编号直查并校验类型与其他条件。状态和 PR 目标分支在 GitHub 侧筛选；其余条件在游标遍历时取交集。审查请求指直接发给当前用户的请求，不把团队请求算作个人请求。候选页携带线程和 CI 摘要，需继续遍历的嵌套连接走独立游标。找到当前显示页后可暂停，继续加载时沿游标推进。
- 以 `headRefOid` 标识 PR 版本；审查请求与 `reviewThreads.isResolved` 分开。过时行评论仍可未解决，保留原位置并标记过时。读取当前提交的检查及状态；区分失败、进行中、通过、无检查与未知。Actions 的 PR 测试可能运行在合并提交上，须用 PR/run 关联与版本证据核对；无法对应时不引用为当前日志。
- 每次切换仓库、条件或刷新都递增查询代号；迟到的回调不得覆盖新视图。切回列表时刷新；仅查询摘要，进入任务后才取正文、讨论和失败日志。限流时显示已加载范围与可重试时间，不持续轮询。
- 每个仓库和列表类型保存筛选、排序位置及选中条目的稳定键，不持久化整张列表。面板保存值只含 UI 恢复所需数据；跨面板的会话索引单独保存，不把 token、评论或日志写入索引。

## 启动与恢复协议

1. 任务键取 `(host, owner/repo, issue|pr, number)`；本地会话记录另绑定 checkout 身份，避免两个本地副本误用工作区。对同一记录串行执行打开操作。不同任务不互相阻塞。
2. 已有记录时，按任务目录筛出候选面板，再经 `tern process` 核对实际运行的 omp 参数和工作目录后聚焦；不使用面板标题。面板已关闭则核对确切会话文件及其中记录的 checkout 后调用 `omp --resume`。记录或文件失效时明确提示，不用全局 `--continue` 猜测。再次打开 PR 时检查远端版本变化。
3. 首次打开为任务分配私有状态目录，用 `--session-dir` 隔离会话文件。材料分别保存出处、正文、讨论、审查及 CI 证据；超长段落标记截断。启动参数使用固定任务说明与 `@材料文件`，不把远端文本拼进命令。
4. 宿主按 argv 调用 `tern split <来源面板> right --cwd <私有启动目录> -- omp --cwd=<工作目录> …`，并显式指定来源窗口；在多个窗口中无法唯一确定来源时不启动。私有启动目录避免在启动阶段加载 PR 的 `.env`。确认实际进程后记录面板身份；确认生成唯一会话文件后原子保存恢复路径。

## PR 工作区与安全边界

- 从目标仓库以 HTTPS 获取 `refs/pull/<number>/head`，核对实际提交与查询的 head SHA。每个版本使用新建的私有 Git 存储及其 detached worktree，不继承原 checkout 的 Git 配置、引用、hook 或 filter，也不在原 checkout 执行 checkout、reset 或清理。
- 恢复时分别检查上游 SHA、工作区 HEAD、未提交修改。远端变化时显示新旧 SHA；选择旧版本只继续界面明确显示的版本，不改用其他面板最近打开的版本。选择新版本则在再次核对远端后创建独立工作区。即使旧工作区干净，也不会丢弃本地提交。
- Issue 内容、审查评论、日志和 PR 代码均不可信。外部内容作为带来源的数据，不授予执行指令的权力。worktree 是修改隔离，不是执行沙箱；对外部贡献的 PR，执行仓库脚本前确认信任或在无凭据的隔离环境运行，不开启 omp 自动批准。只使用已有 `gh` 登录态；第三方 CI 无法读取日志时提供检查链接并标记证据缺失。
- GitHub CLI 的终端转义豁免只用于捕获已验证 job 的日志，不直出到面板；插件剥离 ANSI 格式、跳过其他终端序列，仅把脱敏、限长且标记截断的相关失败行交给 omp。私有材料不写入仓库，关闭面板不删除 worktree。

## 验证

- macOS Tern 0.9.28 隔离窗口：从 fork 选择上游；标题筛选命中首屏之外的 Issue；单击后 omp 收到来源、正文和讨论，首轮回复后原 checkout 无变化；重复打开聚焦原面板，关闭后从确切文件恢复。
- 同一窗口实测公开 PR `cli/cli#14927`：列表同时标出未解决线程和当前失败 CI；连按 Enter 只启动一个 omp。材料包含 4 条未解决线程、失败 job 和 step、3 行无终端转义的日志摘录。worktree HEAD 等于 PR head，原 checkout 保持不变；切回 Issue 保留筛选和选中项。
- 在隔离窗口注入变化后的 head 响应：面板显示新旧两组 SHA；材料仍属旧 head 时拒绝启动新版本；选择旧版本聚焦原会话，保留旧 worktree 的本地提交及未提交文件。
- Shell 通过 `/bin/sh -n`，Luau 通过 `luau-lsp analyze`。未实测 GitHub 上实际发生的 head 更新及跨窗口消歧；未执行该外部 PR 的脚本，也未写入 GitHub。
