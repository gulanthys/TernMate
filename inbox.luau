--!strict

local materials = require("./materials")
local runtime = require("./runtime")
local verification = require("./verification")
local ui = tern.ui
local inbox = {}
local PAGE = 15

type Entry = {kind: string, item: any, queues: {[string]: boolean}, reasons: {string}, related: {any}}
local queues = {
	{"all", "全部"}, {"triage", "待分诊"}, {"missing", "缺证暂存"}, {"blocked", "执行卡点"},
	{"candidate", "待验证"}, {"limited", "验证受限"}, {"passed", "已验证"}, {"unknown", "待核对"},
}

local function text(value: string, tone: string?): Node
	return ui.text({ui.span(value, tone or "muted")})
end

local function button(label: string, action: string, on: boolean?, disabled: boolean?): Node
	return ui.button(label, {key = action, size = "sm", on = on, disabled = disabled, actions = {click = "inbox:" .. action}})
end

local function nodes(connection: any): {any}
	return if type(connection) == "table" and type(connection.nodes) == "table" then connection.nodes else {}
end

local function complete(connection: any): boolean
	return type(connection) == "table" and type(connection.pageInfo) == "table" and connection.pageInfo.hasNextPage == false
end

local function stateName(item: any): string
	return if item.state == "OPEN" then "开放" elseif item.state == "MERGED" then "已合并" elseif item.state == "CLOSED" then "已关闭" else "状态未知"
end

local function add(entry: Entry, queue: string, reason: string)
	entry.queues[queue] = true
	table.insert(entry.reasons, reason)
end

local function reviewSignals(entry: Entry)
	local pr = entry.item
	if pr.state ~= "OPEN" then return end
	local undatedReview = false
	for _, review in nodes(pr.latestReviews) do
		if review.state == "CHANGES_REQUESTED" then
			if type(review.commit) == "table" and review.commit.oid == pr.headRefOid then
				if pr.reviewDecision == "CHANGES_REQUESTED" then
					local actor = if type(review.author) == "table" and review.author.__typename == "Bot" then "自动审查要求修改" else "当前 head 有要求修改的审查"
					add(entry, "blocked", actor .. " → 作者核对")
				end
			else
				undatedReview = true
			end
		end
	end
	if pr.reviewDecision == "CHANGES_REQUESTED" and not entry.queues.blocked then
		add(entry, "unknown", if undatedReview then "要求修改的审查未对应当前 head → 复审待核对" else "整体要求修改；缺当前 head 的审查出处")
	elseif pr.reviewDecision == "REVIEW_REQUIRED" and not pr.isDraft then
		add(entry, "blocked", "GitHub 要求审查 → 审查者")
	end
	local unresolved = false
	for _, thread in nodes(pr.reviewThreads) do if thread.isResolved == false then unresolved = true; break end end
	if unresolved then add(entry, "blocked", "有未解决线程 → 作者／审查者核对")
	elseif not complete(pr.reviewThreads) then add(entry, "unknown", "审查线程只读到部分") end
	if pr.mergeable == "CONFLICTING" then add(entry, "blocked", "当前合并冲突 → 作者")
	elseif pr.mergeable == "UNKNOWN" then add(entry, "unknown", "可合并性未知") end
	local last = nodes(pr.commits)[1]
	local commit = if type(last) == "table" then last.commit else nil
	if type(commit) ~= "table" or not pr.headRefOid or commit.oid ~= pr.headRefOid then
		add(entry, "unknown", "CI 未核对到当前 head")
	else
		local rollup = commit.statusCheckRollup
		if type(rollup) == "table" then
			if rollup.state == "FAILURE" or rollup.state == "ERROR" then add(entry, "blocked", "当前 head CI 失败 → 作者／CI 管理者")
			elseif rollup.state == "PENDING" or rollup.state == "EXPECTED" then table.insert(entry.reasons, "当前 head CI 等自动检查")
			elseif rollup.state == "SUCCESS" then table.insert(entry.reasons, "当前 head CI 通过（不是验收）")
			else add(entry, "unknown", "当前 head CI 结论未知") end
		else table.insert(entry.reasons, "当前 head 无检查摘要") end
	end
	if pr.isCrossRepository then table.insert(entry.reasons, "跨仓贡献") end
end

local function classify(snapshot: any, index: any, fd: boolean): {Entry}
	local byIssue: {[string]: {any}} = {}
	local all: {Entry} = {}
	for _, pr in snapshot.prs do
		for _, issue in nodes(pr.closingIssuesReferences) do
			if type(issue.id) == "string" then
				local linked = byIssue[issue.id] or {}
				byIssue[issue.id] = linked
				table.insert(linked, pr)
			end
		end
		local entry: Entry = {kind = "pr", item = pr, queues = {}, reasons = {}, related = {}}
		reviewSignals(entry)
		if #entry.reasons == 0 then add(entry, "unknown", "没有可确认的下一行动") end
		table.insert(all, entry)
	end
	for _, issue in snapshot.issues do
		local linked: {any} = byIssue[issue.id] or {}
		local entry: Entry = {kind = "issue", item = issue, queues = {}, reasons = {}, related = linked}
		local labels: {[string]: boolean} = {}
		for _, label in nodes(issue.labels) do labels[label.name] = true end
		if issue.state == "OPEN" then
			if fd and labels["roost:waiting"] then add(entry, "missing", "仓库标记 roost:waiting → 核对缺口；不推定已经发出请求")
			elseif fd and complete(issue.labels) and not labels.triaged and #linked == 0 then add(entry, "triage", "未见 triaged 标记 → 维护者核对；不是无人处理") end
			if fd and labels["roost:maintainer"] then add(entry, "blocked", "仓库标记 roost:maintainer → 维护者核对") end
			if fd and labels["roost:pr"] and #linked == 0 then add(entry, "unknown", "有仓库关联标记，尚无可核对的 PR 引用") end
		end
		local summary = index[issue.id]
		if summary then
			if summary.passed > 0 then add(entry, "passed", tostring(summary.passed) .. " 个本机范围有通过记录；不代表整个 Issue") end
			if summary.limited > 0 then
				add(entry, "limited", tostring(summary.limited) .. " 个本机范围受限")
				add(entry, "candidate", "本机记录已定位候选构建与症状；受限范围仍待验证")
			end
			if summary.failed > 0 then add(entry, "blocked", tostring(summary.failed) .. " 个本机范围复测失败 → 调查") end
		end
		for _, pr in linked do
			if pr.state == "MERGED" then
				add(entry, "unknown", "PR #" .. pr.number .. " 已合并且明确引用本 Issue；仅凭引用不能核定原症状或验收范围")
			elseif pr.state == "OPEN" then
				table.insert(entry.reasons, "PR #" .. pr.number .. " 明确引用本 Issue")
				local prEntry: Entry = {kind = "pr", item = pr, queues = {}, reasons = {}, related = {}}
				reviewSignals(prEntry)
				if prEntry.queues.blocked then add(entry, "blocked", "PR #" .. pr.number .. " 有执行卡点 → 查看具名 PR") end
			end
		end
		if #entry.reasons == 0 then add(entry, "unknown", "没有可确认的下一行动") end
		table.insert(all, entry)
	end
	table.sort(all, function(a, b)
		if a.item.updatedAt ~= b.item.updatedAt then return tostring(a.item.updatedAt) > tostring(b.item.updatedAt) end
		return a.item.number > b.item.number
	end)
	return all
end

local function githubUrl(ctx: any, url: any): boolean
	return type(url) == "string" and url:sub(1, #ctx.repo.host + 9):lower() == "https://" .. ctx.repo.host:lower() .. "/"
end

function inbox.new(ctx: any): any
	local all: {Entry} = {}
	local visible: {Entry} = {}
	local entries: {[string]: Entry} = {}
	local prefs: any = ctx.prefs.inbox or {}
	ctx.prefs.inbox = prefs
	local queue = prefs.queue or "all"
	local position = 1
	local serial = 0
	local snapshot: any = nil
	local index: any = {}
	local errorText: string? = nil
	local localError: string? = nil
	local loading = false
	local detail: Entry? = nil
	local detailObservedAt: string? = nil
	local discussion: any = nil
	local discussionError: string? = nil
	local personal: any = nil
	local personalSummary: any = nil
	local editor: any = nil
	local needle: string = prefs.needle or ""

	local function refilter()
		table.clear(visible)
		local number = tonumber(needle:match("^#(%d+)$"))
		local found: number? = nil
		local query = needle:lower()
		for _, entry in all do
			if (queue == "all" or entry.queues[queue]) and (query == "" or (if number then entry.item.number == number else entry.item.title:lower():find(query, 1, true) ~= nil)) then
				table.insert(visible, entry)
				if entry.item.id == prefs.selected then found = #visible end
			end
		end
		position = found or math.clamp(position, 1, math.max(1, #visible))
	end

	local function reclassify()
		if not snapshot then
			table.clear(all)
			table.clear(entries)
			table.clear(visible)
			return
		end
		all = classify(snapshot, index, runtime.repoKey(ctx.repo) == "github.com/zerx-lab/fluxdown")
		table.clear(entries)
		for _, entry in all do entries[tostring(entry.item.number)] = entry end
		refilter()
	end

	local function privateRecords(revision: number)
		verification.index(ctx, function(value, err)
			if not ctx.alive() or revision ~= serial then return end
			index, localError = value or {}, err
			reclassify()
			ctx.render()
		end)
	end

	local function refresh(force: boolean)
		if loading then return end
		serial += 1
		local revision = serial
		loading, errorText = true, nil
		ctx.fetch(force, function(value, err)
			if not ctx.alive() or revision ~= serial then return end
			snapshot, errorText, loading = value, err, false
			reclassify()
			if value then privateRecords(revision) end
			ctx.render()
		end, function(value)
			if not ctx.alive() or revision ~= serial then return end
			snapshot = value
			reclassify()
			ctx.render()
		end)
	end

	local function select(at: number)
		position = math.clamp(at, 1, math.max(1, #visible))
		prefs.selected = if visible[position] then visible[position].item.id else nil
	end

	local function showDetail(entry: Entry)
		detail, discussion, discussionError, personalSummary = entry, nil, nil, nil
		detailObservedAt = if snapshot then snapshot.observedAt else nil
		if entry.kind == "issue" then
			materials.collect(runtime.exec, ctx.repo, "issue", entry.item.number, function() return ctx.alive() and detail == entry end, function(value, err)
				if not ctx.alive() or detail ~= entry then return end
				discussion = if value and value.identity.id == entry.item.id then value else nil
				discussionError = if value and not discussion then "Issue 身份已变化。" else err
				ctx.render()
			end)
			verification.read(ctx, entry.item, function(value, _err)
				if ctx.alive() and detail == entry then personalSummary = value; ctx.render() end
			end)
		end
	end

	local function detailView(entry: Entry): {Node}
		local item = entry.item
		local result = { ui.row({button("返回收件箱", "close"), button("在 omp 打开", "open=" .. item.number),
			button("查看原件", "source", false, not githubUrl(ctx, item.url))}),
			text("#" .. item.number .. " " .. item.title, "strong"), text(stateName(item) .. " · GitHub 更新时间 " .. tostring(item.updatedAt)),
			text("扫描于 " .. (detailObservedAt or "未知")) }
		for _, reason in entry.reasons do table.insert(result, text(reason)) end
		if entry.kind == "pr" then
			table.insert(result, text("head " .. tostring(item.headRefOid) .. " · 整体审查 " .. tostring(item.reviewDecision or "无结论")))
			for i, review in nodes(item.latestReviews) do
				local actor = if type(review.author) == "table" then tostring(review.author.login) .. (if review.author.__typename == "Bot" then "（机器人）" else "") else "未知作者"
				local commit = if type(review.commit) == "table" then tostring(review.commit.oid) else "未知提交"
				table.insert(result, ui.row({text(actor .. " · " .. tostring(review.state) .. " · " .. commit), button("审查出处", "review=" .. i, false, not githubUrl(ctx, review.url))}))
			end
			if not complete(item.latestReviews) then table.insert(result, text("这里只展示部分审查。", "warning")) end
		else
			local labels, assignees = {}, {}
			for _, label in nodes(item.labels) do table.insert(labels, label.name) end
			for _, assignee in nodes(item.assignees) do table.insert(assignees, assignee.login) end
			table.insert(result, text("GitHub 标签：" .. (if #labels > 0 then table.concat(labels, "、") else "未见") .. (if complete(item.labels) then "" else "（部分）")))
			table.insert(result, text("公开指派：" .. (if #assignees > 0 then table.concat(assignees, "、") else "未见接手信号") .. (if complete(item.assignees) then "" else "（部分）")))
			table.insert(result, button(if personalSummary and personalSummary.bookmarked then "我在看 · 私有书签与验收" else "私有书签与验收", "personal"))
			if personalSummary then
				for i = 1, math.min(#personalSummary.scopes, 5) do
					local scope = personalSummary.scopes[i]
					local resultName = if scope.outcome == "pass" then "指定范围通过" elseif scope.outcome == "fail" then "复测失败" else "受限"
					table.insert(result, text(scope.symptom .. " · " .. scope.environment .. " · " .. scope.version .. " · " .. resultName))
				end
			end
			for _, pr in entry.related do table.insert(result, button("处理 PR #" .. pr.number .. " · " .. stateName(pr), "linked=" .. pr.number)) end
			if #entry.related == 0 then table.insert(result, text("当前扫描未见可核对的关闭引用；并不排除原件中有其他关联。")) end
			if discussionError then table.insert(result, text(discussionError, "warning"))
			elseif discussion then
				table.insert(result, text("讨论出处（不自动判断等谁、复现或验收）", "strong"))
				for i = #discussion.discussion, math.max(1, #discussion.discussion - 4), -1 do
					local comment = discussion.discussion[i]
					local login = if type(comment.author) == "table" then comment.author.login else "未知作者"
					table.insert(result, button(tostring(login) .. " · " .. tostring(comment.updatedAt), "comment=" .. i, false, not githubUrl(ctx, comment.url)))
				end
			else table.insert(result, text("正在读取讨论出处…")) end
		end
		return result
	end

	local function view(): {Node}
		if personal then
			local result: {Node} = {button("返回依据", "personal_close")}
			for _, node in personal.view() do table.insert(result, node) end
			return result
		end
		if detail then
			local nodes = detailView(detail)
			if loading or entries[tostring(detail.item.number)] ~= detail or not snapshot or not ctx.fresh(snapshot) then
				table.insert(nodes, 1, text("列表证据未齐、已更新或已过期；以 GitHub 原件为准。", "warning"))
			end
			return nodes
		end
		local children: {Node} = {text("社区收件箱 · 已观察事实与下一动作", "strong")}
		local width = if ctx.cx.cols >= 95 then 4 else 2
		for first = 1, #queues, width do
			local row: {Node} = {}
			for i = first, math.min(first + width - 1, #queues) do
				local choice = queues[i]
				table.insert(row, button(choice[2], "queue=" .. choice[1], queue == choice[1]))
			end
			table.insert(children, ui.row(row))
		end
		table.insert(children, ui.row({button(if needle == "" then "标题／#编号…" else "筛选：" .. needle, "filter"), button("刷新证据", "refresh", false, loading)}))
		if editor then table.insert(children, text("输入标题或 #编号：" .. editor.text .. "▏ · Enter 应用 · Esc 取消", "accent")) end
		if loading then table.insert(children, ui.progress(nil, "正在读取开放与历史事项…")) end
		if errorText then table.insert(children, text("覆盖不完整：" .. errorText, "warning")) end
		if localError then table.insert(children, text("私有验收记录不可读：" .. localError, "warning")) end
		if snapshot then
			local stale = snapshot.complete and not loading and not ctx.fresh(snapshot)
			local incomplete = not snapshot.complete or stale
			if stale then table.insert(children, text("扫描已过期，请刷新证据。", "warning")) end
			local first = (math.ceil(position / PAGE) - 1) * PAGE + 1
			local rows: {Node} = {}
			local badge = ctx.issueBadges()
			for i = first, math.min(#visible, first + PAGE - 1) do
				local entry = visible[i]
				local label = (if entry.kind == "issue" then "Issue #" else "PR #") .. entry.item.number .. " · " .. entry.item.title
				local status = if entry.kind == "issue" then badge(entry.item.number) else ""
				local item = ui.node("item", {key = "n" .. entry.item.number, label = label,
					detail = (if status == "" then "" else status .. " · ") .. stateName(entry.item) .. " · " .. table.concat(entry.reasons, " · "),
					actions = {click = "inbox:open=" .. entry.item.number,
						menu = {{id = "inbox:detail=" .. entry.item.number, label = "查看依据"}}}})
				table.insert(rows, item)
			end
			if #rows > 0 then
				local selected = visible[position]
				table.insert(children, ui.node("list", {key = "inbox_results", selected = if selected then "main.inbox_results.n" .. selected.item.number else nil,
					max = {lines = math.clamp(ctx.cx.rows - 14, 4, 12)}}, rows))
				table.insert(children, ui.row({button("上一页", "prev", false, first <= 1), button("下一页", "next", false, first + PAGE > #visible), button("选中项依据", "detail")}))
			end
			table.insert(children, text(if incomplete or loading or localError then "已知匹配 " .. #visible .. " 项；证据未齐" else "匹配 " .. #visible .. " 项 · ↑↓ 选择 · Enter 打开 · E 依据"))
		end
		return children
	end

	local function open(entry: Entry)
		prefs.selected = entry.item.id
		ctx.open(entry.kind, entry.item.number)
	end

	local function event(action: string, value: string?)
		if action == "personal_close" then
			personal = nil
			if detail then showDetail(detail) end
			privateRecords(serial)
			return
		end
		if personal then
			local command = action:match("^verify:(.*)$")
			if command then personal.event(command, value) end
			return
		end
		local entry = if value then entries[value] else visible[position]
		if action == "open" and entry then open(entry)
		elseif action == "detail" and entry then showDetail(entry)
		elseif action == "close" then detail = nil
		elseif action == "refresh" then refresh(true)
		elseif action == "personal" and detail and detail.kind == "issue" then personal = verification.new(ctx, detail.item)
		elseif action == "filter" then editor = {text = needle}
		elseif action == "queue" and value then
			for _, choice in queues do
				if choice[1] == value then queue, prefs.queue, position, prefs.selected = value, value, 1, nil; refilter(); break end
			end
		elseif action == "prev" then select(position - PAGE)
		elseif action == "next" then select(position + PAGE)
		elseif detail then
			if action == "linked" and entry and entry.kind == "pr" then
				for _, pr in detail.related do if pr.id == entry.item.id then ctx.open("pr", pr.number); break end end
			elseif action == "source" and githubUrl(ctx, detail.item.url) then ctx.cx:open(detail.item.url)
			elseif action == "review" or action == "comment" then
				local source = if action == "review" then nodes(detail.item.latestReviews) else if discussion then discussion.discussion else {}
				local record = source[tonumber(value) or 0]
				if record and githubUrl(ctx, record.url) then ctx.cx:open(record.url) end
			end
		end
	end

	local function key(k: Key): boolean
		if personal then
			if personal.key and personal.key(k) then return true end
			if k.name == "escape" then event("personal_close", nil); return true end
			return false
		end
		if k.ctrl or k.alt or k.meta then return false end
		if editor then
			if k.name == "escape" then editor = nil
			elseif k.name == "enter" then
				needle = runtime.trim(editor.text)
				prefs.needle, editor, position, prefs.selected = needle, nil, 1, nil
				refilter()
			elseif k.name == "backspace" then
				local at = utf8.offset(editor.text, -1)
				if at then editor.text = editor.text:sub(1, at - 1) end
			elseif k.text and #editor.text + #k.text <= 512 then editor.text ..= k.text:gsub("[%c]", "")
			else return false end
			return true
		end
		if detail then
			if k.name == "escape" then detail = nil; return true end
			if k.name == "enter" then open(detail); return true end
			return false
		end
		if k.name == "up" then select(position - 1)
		elseif k.name == "down" then select(position + 1)
		elseif k.name == "page_up" then select(position - PAGE)
		elseif k.name == "page_down" then select(position + PAGE)
		elseif k.name == "enter" and visible[position] then open(visible[position])
		elseif k.name == "e" and visible[position] then showDetail(visible[position])
		elseif k.text == "/" then event("filter", nil)
		else return false end
		return true
	end

	refresh(false)
	return {view = view, event = event, key = key, refresh = function() refresh(true) end}
end

return inbox
