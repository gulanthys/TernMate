# TernMate

TernMate 是 [Tern](https://docs.stencil.so/tern/guides/blocks.html) 的 GitHub Issue / PR 工作台。在项目窗口里筛选任务，单击或按 `Enter`，即可在对应代码目录启动或恢复交互式 `omp` 会话，无需复制链接或补写提示。

## 安装

在 Tern 宿主机上准备 `tern`、`git`、`gh` 和 `omp`（可使用 Tern 随附的 `omp`）。使用 `gh auth status` 确认已登录；未登录时运行 `gh auth login`。读取 GitHub Actions 日志还要求 `gh api --help` 中列出 `--allow-escape-sequences`。

```sh
git clone https://github.com/gulanthys/TernMate.git
cd TernMate
tern plugin link .
tern plugin list
```

## 使用

1. 在 Tern 命令面板选择 **New TernMate**，工作台会在当前 session 中、来源面板右侧分屏打开，不新建 tab。仓库发现从来源 Tern 面板的工作目录开始，不读取 `omp --cwd`，也无需先启动 omp。若有多个候选仓库（如 fork 和上游），先选 `owner/repo`；也可用 **本地 checkout…** 指定代码目录。
2. 按 `Tab` 切换 Issue / PR，按 `/` 编辑标题关键词，按 `R` 刷新。可组合作者、标签、编号等条件；PR 还可按目标分支、审查和 CI 状态筛选。审查请求与未解决线程是不同条件。
3. 用 `↑` / `↓` 移动选中项，单击或按 `Enter` 打开。再次打开同一任务会聚焦已有面板或恢复对应会话；返回列表保留筛选和位置。
4. **社区收件箱**按观察到的证据组织 Issues 和 PRs。按 `E`、右键「查看依据」，或点「选中项依据」，查看原因和具名关联 PR。可在 Issue 依据中添加可撤销的本机书签，或按症状、环境和构建记录复测；通过不等于关单。
5. **新建 Issue**先核对目标仓库、账号与模板。受支持的表单可保存本地草稿、查重、预览、明确确认一次创建；其他模板走 GitHub 原生入口。提交结果未知时只能核对回执，不能重发。模板解析使用宿主的 `/usr/bin/ruby`，不可用时仍可用原生入口。
6. **批次回顾**先确认 milestone 或标题标记来源，再选批次；没有基线时仅盘点。开批逐项确认承诺并保存本机基线，收批比较范围变化和验收证据，可复制 Markdown 草稿，不发布到 GitHub。

| 任务 | 打开后的行为 |
| --- | --- |
| Issue | 将正文、讨论和链接交给 `omp`，在本地 checkout 中分析。点击不授权修改文件；可在会话中明确要求修复。 |
| PR | 核对 PR head SHA 后在独立 worktree 中打开，提供未解决审查线程及可读取的当前版本 CI 失败证据。可在本地修复和验证；不会自动推送、评论、解决线程、批准或合并。 |

PR 出现新提交时，TernMate 提示版本变化，不覆盖旧 worktree。关闭面板不会删除 worktree 或会话。**worktree 不是沙箱**：不要在带凭据的环境中运行不可信 PR 的脚本。

任务材料和 worktree 位于插件数据目录的 `task-sessions-v1/`；草稿、书签、验收及基线位于 `maintenance-v1/`，按 GitHub 主机、仓库稳定 ID 和账号隔离。唯一的插件 GitHub 写入是从最终预览明确确认的 Issue 创建；单击现有任务、复制结算或保存本机记录都不写 GitHub。

## 文档

- [产品需求与验收场景](docs/requirements.md)
- [技术设计与验证记录](docs/design.md)
- [开源维护工作台与证据边界](docs/open-source-workbench.md)
