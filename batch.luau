--!strict

local runtime = require("./runtime")
local ui = tern.ui

local batch = {}
local PAGE = 15
local queues = {
	{ "all", "全部" }, { "decision", "待决策" }, { "schedule", "待排期" }, { "blocked", "执行卡点" },
	{ "feedback", "等反馈" }, { "check", "待核对" }, { "history", "历史" },
}
local phases: { [string]: { string } } = {
	["待批准方案"] = { "decision", "维护者" }, ["待维护者决策"] = { "decision", "维护者" }, ["待决策"] = { "decision", "维护者" },
	["已分诊待排期"] = { "schedule", "批次负责人" }, ["待排期"] = { "schedule", "批次负责人" },
	["待维护者处理"] = { "blocked", "维护者" }, ["待用户反馈"] = { "feedback", "报告人" },
	["持续记录"] = { "check", "维护者" },
}
local outcomes: { [string]: string } = { accepted = "已验收", deferred = "延期", cancelled = "取消", pending = "未决" }
local outcomeOrder = { "accepted", "deferred", "cancelled", "pending" }

local function button(label: string, action: string, value: string?, active: boolean?, disabled: boolean?): Node
	local id = "batch:" .. action .. (if value then "=" .. value else "")
	return ui.button(label, { key = id, size = "sm", on = active, disabled = disabled, actions = { click = id } })
end

local function text(label: string, tone: string?): Node
	return ui.text({ ui.span(label, tone or "muted") })
end

local function chunks(parent: { Node }, controls: { Node }, width: number)
	for first = 1, #controls, width do
		local row: { Node } = {}
		for i = first, math.min(first + width - 1, #controls) do table.insert(row, controls[i]) end
		table.insert(parent, ui.row(row))
	end
end

local function nodes(conn: any): { any }
	return if type(conn) == "table" and type(conn.nodes) == "table" then conn.nodes else {}
end

local function covered(conn: any): boolean
	return type(conn) == "table" and type(conn.nodes) == "table" and type(conn.pageInfo) == "table"
		and conn.pageInfo.hasNextPage == false
end

local function titleMarks(title: string): { string }
	local marks = {}
	while true do
		local token, stop = title:match("^【(.-)】()")
		if not token or not stop or token == "" or token:find("【", 1, true) then break end
		table.insert(marks, token)
		title = title:sub(stop)
	end
	return marks
end

local function membership(issue: any, source: string?): (string?, string?, string?)
	if source == "milestone" then
		local milestone = issue.milestone
		if type(milestone) == "table" and type(milestone.id) == "string" then
			return milestone.id, milestone.title, milestone.url
		end
	elseif source == "title" then
		local key = nil
		for _, mark in titleMarks(issue.title) do
			if #mark <= 24 and mark:match("^%d+$") then
				if key and key ~= mark then return nil, nil, nil end
				key = mark
			end
		end
		return key, key, nil
	end
	return nil, nil, nil
end

local function ci(pr: any): string?
	local node = nodes(pr.commits)[1]
	local commit = node and node.commit
	if type(commit) ~= "table" or commit.oid ~= pr.headRefOid then return nil end
	local rollup = commit.statusCheckRollup
	return if type(rollup) == "table" then rollup.state else nil
end

local function onCurrentHead(pr: any, review: any): boolean
	return type(pr.headRefOid) == "string" and type(review.commit) == "table" and review.commit.oid == pr.headRefOid
end

local function hasCurrentChangeRequest(pr: any): boolean
	for _, review in nodes(pr.latestReviews) do
		if review.state == "CHANGES_REQUESTED" and onCurrentHead(pr, review) then return true end
	end
	return false
end

local function prFacts(pr: any): { string }
	local facts = { tostring(pr.state), "head " .. tostring(pr.headRefOid or "未知") }
	if type(pr.reviewDecision) == "string" then table.insert(facts, "审查 " .. pr.reviewDecision) end
	if pr.reviewDecision == "CHANGES_REQUESTED" then
		table.insert(facts, if hasCurrentChangeRequest(pr) then "有当前 head 的修改请求" else "修改请求属于旧版本或无法核对 head")
	end
	if not covered(pr.latestReviews) then table.insert(facts, "审查记录覆盖不全") end
	if pr.isDraft then table.insert(facts, "草稿") end
	if pr.mergeable == "CONFLICTING" then table.insert(facts, "合并冲突") end
	for _, thread in nodes(pr.reviewThreads) do
		if thread.isResolved == false then table.insert(facts, "有未解决线程"); break end
	end
	if not covered(pr.reviewThreads) then table.insert(facts, "线程覆盖不全") end
	local check = ci(pr)
	table.insert(facts, if check then "当前 head 检查 " .. check else "当前 head 检查状态未确认")
	return facts
end

local function classify(issue: any, key: string?, prs: { any }, fd: boolean, scanComplete: boolean): ({ [string]: boolean }, string)
	if issue.state == "CLOSED" then return { history = true }, "GitHub 已关闭，不能据此判定验收 · 维护者按原条件核验" end
	local flags: { [string]: boolean } = {}
	local why: { string } = {}
	local function add(queue: string, reason: string, role: string)
		flags[queue] = true
		table.insert(why, reason .. " → " .. role)
	end
	if fd then
		local seen = {}
		for _, mark in titleMarks(issue.title) do
			local phase = phases[mark]
			if phase and not seen[mark] then add(phase[1], "标题【" .. mark .. "】", phase[2]); seen[mark] = true end
		end
		if #why > 1 then add("check", "多个阶段标记并存，待确认现阶段", "维护者") end
	end
	if not key then add("check", "批次未映射或标题有多个数字标记", "维护者") end
	if not scanComplete then add("check", "关联 PR 扫描未完整", "维护者") end
	for _, pr in prs do
		local prefix = "PR #" .. pr.number .. " "
		if pr.state == "MERGED" then
			add("check", prefix .. "已合并，验收未推定", "验收人")
		elseif pr.state == "OPEN" then
			if pr.reviewDecision == "CHANGES_REQUESTED" then
				if hasCurrentChangeRequest(pr) then add("blocked", prefix .. "当前 head 审查要求修改", "PR 作者")
				else add("check", prefix .. "整体要求修改，但未证实当前 head 的修改请求", "维护者") end
			end
			if pr.mergeable == "CONFLICTING" then add("blocked", prefix .. "存在合并冲突", "PR 作者") end
			for _, thread in nodes(pr.reviewThreads) do
				if thread.isResolved == false then add("blocked", prefix .. "有未解决线程", "作者／审查者"); break end
			end
			local check = ci(pr)
			if check == "FAILURE" or check == "ERROR" then add("blocked", prefix .. "当前 head 检查失败", "PR 作者") end
			if not covered(pr.reviewThreads) or not check then add("check", prefix .. "审查线程或检查证据未知", "维护者") end
		end
	end
	if #why == 0 then add("check", "未见可确认的阶段依据", "维护者") end
	return flags, table.concat(why, "；")
end

local function collect(snapshot: any, source: string?, fd: boolean): any
	local index: any = { issues = {}, byId = {}, byNumber = {}, batches = {}, byBatch = {}, linksComplete = true, prCount = 0 }
	if not snapshot then return index end
	local prsByIssue: { [string]: { any } } = {}
	local prSeen = {}
	for _, pr in snapshot.prs do
		if type(pr.id) == "string" and not prSeen[pr.id] then
			prSeen[pr.id], index.prCount = true, index.prCount + 1
			if not covered(pr.closingIssuesReferences) then index.linksComplete = false end
			local seen = {}
			for _, issue in nodes(pr.closingIssuesReferences) do
				if type(issue.id) == "string" and not seen[issue.id] then
					seen[issue.id] = true
					local linked = prsByIssue[issue.id] or {}
					prsByIssue[issue.id] = linked
					table.insert(linked, pr)
				end
			end
		end
	end
	for _, issue in snapshot.issues do
		if type(issue.id) == "string" and type(issue.title) == "string" and not index.byId[issue.id] then
			local key, label, url = membership(issue, source)
			local prs = prsByIssue[issue.id] or {}
			local flags, reason = classify(issue, key, prs, fd and source == "title", snapshot.complete and index.linksComplete)
			local row = { issue = issue, batch = key, prs = prs, flags = flags, reason = reason }
			table.insert(index.issues, row)
			index.byId[issue.id], index.byNumber[issue.number] = row, row
			if key and not index.byBatch[key] then
				local choice = { key = key, label = label or key, url = url }
				index.byBatch[key] = choice
				table.insert(index.batches, choice)
			end
		end
	end
	table.sort(index.batches, function(a, b) return a.label < b.label or (a.label == b.label and a.key < b.key) end)
	return index
end

local function keyFor(source: string, id: string): string?
	local hex = id:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)
	if #hex > 140 then return nil end
	return "batch-baseline-" .. source .. "-" .. hex .. "-"
end

local function safeUrl(value: any): boolean
	return type(value) == "string" and #value <= 2048
		and value:match("^https://[%w%.%-]+/[^?%s%c<>()`%[%]\\]+$") ~= nil
end

local function md(value: any): string
	local clean = tostring(value or ""):gsub("[%c]", " ")
	return (clean:gsub("([\\`*_{}%[%]<>#!|])", "\\%1"))
end

local function link(label: string, url: any): string
	return if safeUrl(url) then "[" .. md(label) .. "](" .. url .. ")" else md(label)
end

local function validBaseline(record: any, snapshot: any, host: string, source: string?, id: string?, revision: number, previous: any): boolean
	if type(record) ~= "table" or not snapshot or record.repoId ~= snapshot.repoId or record.host ~= host
		or record.mapping ~= source or record.batch ~= id or record.revision ~= revision
		or record.supersedes ~= (if previous then previous.id else nil) or type(record.id) ~= "string"
		or not safeUrl(record.source) or type(record.version) ~= "string" or type(record.items) ~= "table"
		or type(record.scope) ~= "table" or type(record.batchLabel) ~= "string" or type(record.initialScope) ~= "table" then return false end
	local seen = {}
	for _, item in record.items do
		if type(item) ~= "table" or type(item.id) ~= "string" or seen[item.id] or type(item.number) ~= "number"
			or type(item.condition) ~= "string" or item.condition == "" then return false end
		seen[item.id] = true
	end
	return next(seen) ~= nil
end

local function ordered(items: any): { any }
	local result: { any } = {}
	for _, item in items do table.insert(result, item) end
	table.sort(result, function(a, b) return a.number < b.number end)
	return result
end

local function compare(index: any, selected: string?, baseline: any, complete: boolean, decisions: any): any
	local result: any = { original = {}, additions = {}, moved = {}, changed = {}, missing = {}, publications = {} }
	local known = {}
	local evidenceComplete = true
	local function entry(item: any, row: any): any
		local decision = decisions[item.id] or {}
		local outcome = if row and decision.outcome and safeUrl(decision.evidence) and decision.result and decision.result ~= ""
			and (decision.outcome ~= "accepted" or (decision.environment and decision.environment ~= ""
				and (item.condition or (decision.condition and decision.condition ~= "")))) then decision.outcome else "pending"
		if row then
			for _, pr in row.prs do
				if pr.state == "OPEN" and (not covered(pr.reviewThreads)
					or (pr.reviewDecision == "CHANGES_REQUESTED" and not covered(pr.latestReviews))) then evidenceComplete = false end
			end
		end
		local fact = { item = item, row = row, outcome = outcome, decision = decision }
		if row and decision.publication and decision.publication ~= "" and safeUrl(decision.publicationUrl) then
			table.insert(result.publications, fact)
		end
		return fact
	end
	for _, item in baseline.items do
		known[item.id] = true
		local row = index.byId[item.id]
		local fact = entry(item, row)
		table.insert(result.original, fact)
		if not row then table.insert(result.missing, fact)
		elseif row.batch ~= selected then table.insert(result.moved, fact) end
		if fact.decision.condition and fact.decision.condition ~= "" and fact.decision.condition ~= item.condition then
			table.insert(result.changed, fact)
		end
	end
	local additions = {}
	for _, row in index.issues do
		local issue = row.issue
		if not known[issue.id] and row.batch == selected and not baseline.initialScope[issue.id] then additions[issue.id] = issue end
	end
	for id, decision in decisions do
		if not known[id] and decision.item then additions[id] = decision.item end
	end
	for _, issue in ordered(additions) do
		local row = index.byId[issue.id]
		local fact = entry(issue, row)
		table.insert(result.additions, fact)
		if not row and fact.decision.added then table.insert(result.missing, fact) end
	end
	result.complete, result.evidenceComplete = complete and evidenceComplete and #result.missing == 0, evidenceComplete
	return result
end

local scopeFields = {
	{ "users", "目标用户" }, { "goal", "可观察结果" }, { "limits", "非目标／投入边界" }, { "owner", "计划原文中的决策人" },
	{ "dependencies", "主要依赖" },
}

function batch.new(ctx: any): any
	local controller = {}
	local repo = ctx.repo
	local repoName = repo.host .. "/" .. repo.owner .. "/" .. repo.name
	local fd = runtime.repoKey(repo) == "github.com/zerx-lab/fluxdown"
	local prefs: any = { bySource = {}, byBatch = {}, knownBatches = {} }
	local snapshot: any = nil
	local index = collect(nil, nil, fd)
	local scanBusy, prefsBusy = false, true
	local scanError: string? = nil
	local storageError: string? = nil
	local notice: string? = nil
	local previewSource: string? = nil
	local evidence: string? = nil
	local baseline: any = nil
	local revisions: { any } = {}
	local baselineBusy, baselineReady = false, false
	local revisionRead = 0
	local plan: any = nil
	local planPreview = false
	local correction = false
	local conflict: any = nil
	local scopeOpen = false
	local editor: any = nil
	local report = false
	local reportPage = 1
	local reportItem: string? = nil
	local picksOpen = false
	local decisionSets: any = {}
	local prefWriting, prefDirty = false, false

	local function draw() if ctx.alive() then ctx.render() end end
	local function selectedBatch(): string? return prefs.bySource[prefs.source or ""] end
	local function prefGroup(): any
		local id = (prefs.source or "") .. ":" .. (selectedBatch() or "")
		if not prefs.byBatch[id] then prefs.byBatch[id] = { queue = "all", page = 1 } end
		return prefs.byBatch[id]
	end
	local function decisions(): any
		local key = (prefs.source or "") .. ":" .. (selectedBatch() or "")
		if not decisionSets[key] then decisionSets[key] = {} end
		return decisionSets[key]
	end
	local function savePrefs()
		prefDirty = true
		if prefWriting or prefsBusy or not ctx.alive() then return end
		prefDirty, prefWriting = false, true
		ctx.store("batch-prefs", "write", prefs, function(_, err)
			prefWriting = false
			if not ctx.alive() then return end
			if err then storageError = "不能保存回顾偏好：" .. err; draw() end
			if prefDirty then savePrefs() end
		end)
	end
	local function batchChoice(id: string): any
		local known = prefs.knownBatches[prefs.source or ""]
		return index.byBatch[id] or (known and known[id])
	end
	local function choiceLabel(): string
		local id = selectedBatch()
		local choice = if id then batchChoice(id) else nil
		return if choice then choice.label elseif baseline then baseline.batchLabel elseif id then id else "未选择"
	end
	local function scanScope(): string
		local prefix = if scanBusy then "扫描中（若显示旧事实，不可作完整结算）" elseif not snapshot then "未取得扫描数据"
			elseif snapshot.complete and index.linksComplete then "Issue／PR 列表及显式关联扫描完整" else "部分扫描"
		return prefix .. " · 已读 " .. #index.issues .. " 条 Issue、" .. index.prCount .. " 条 PR"
			.. (if scanError then " · " .. scanError elseif snapshot and not index.linksComplete then " · PR 关闭引用覆盖不全" else "")
			.. (if snapshot and type(snapshot.observedAt) == "string" then " · 扫描开始 " .. snapshot.observedAt else "")
	end
	local function complete(): boolean
		return not scanBusy and snapshot ~= nil and snapshot.complete == true and index.linksComplete and not scanError
	end
	local function readBaseline(onReady: (() -> ())?)
		revisionRead += 1
		local request = revisionRead
		local source, id = prefs.source, selectedBatch()
		local key = if source and id then keyFor(source, id) else nil
		baseline, revisions, baselineReady, baselineBusy = nil, {}, not id, key ~= nil
		if not key or not snapshot or not ctx.alive() then
			baselineBusy = false
			if id and not key then storageError = "当前批次身份无法用作本机基线键。" end
			return
		end
		local function read(revision: number, previous: any)
			ctx.store(key .. revision, "read", nil, function(record, err)
				if not ctx.alive() or request ~= revisionRead then return end
				if not err and record ~= nil and validBaseline(record, snapshot, repo.host, source, id, revision, previous) then
					table.insert(revisions, record)
					read(revision + 1, record)
					return
				end
				baseline, baselineBusy = previous, false
				if err or record ~= nil then
					storageError = "无法核对本机基线：" .. (if type(err) == "string" then err else "记录版本、身份或内容不符。")
				else baselineReady = true end
				if onReady then onReady() end
				draw()
			end)
		end
		read(1, nil)
	end
	local function refresh()
		if scanBusy or baselineBusy or not ctx.alive() then return end
		scanBusy, scanError = true, nil
		ctx.fetch(function(current, err)
			if not ctx.alive() then return end
			local old = snapshot
			scanBusy, snapshot, scanError = false, current, err or (current and current.error)
			index = collect(snapshot, prefs.source, fd)
			local switched = old and current and (old.repoId ~= current.repoId or old.viewer ~= current.viewer)
			if switched then
				plan, planPreview, conflict, correction, decisionSets, evidence, editor, report = nil, false, nil, false, {}, nil, nil, false
			end
			if current and not prefsBusy and (not old or switched or (not plan and not conflict)) then readBaseline() end
			draw()
		end)
		draw()
	end
	controller.refresh = refresh

	local function visible(): { any }
		local group, id = prefGroup(), selectedBatch()
		local rows: { any } = {}
		for _, row in index.issues do
			if (row.batch == id or (group.queue == "all" and not row.batch)) and (group.queue == "all" or row.flags[group.queue]) then
				table.insert(rows, row)
			end
		end
		return rows
	end
	local function select(row: any, page: number?)
		local group = prefGroup()
		group.selected = row.issue.id
		if page then group.page = page end
		savePrefs()
	end
	local function selectedRow(rows: { any }): any
		local group = prefGroup()
		for _, row in rows do if row.issue.id == group.selected then return row end end
		return rows[((group.page or 1) - 1) * PAGE + 1] or rows[1]
	end
	local function setSource(source: string)
		prefs.source, previewSource, evidence, plan, planPreview, conflict, correction, scopeOpen, report = source, nil, nil, nil, false, nil, false, false, false
		index = collect(snapshot, source, fd)
		savePrefs()
		readBaseline()
	end
	local function chooseBatch(choice: any)
		local id, source = choice.key, prefs.source
		prefs.bySource[source] = id
		if not prefs.knownBatches[source] then prefs.knownBatches[source] = {} end
		prefs.knownBatches[source][id] = { key = id, label = choice.label, url = choice.url }
		evidence, plan, planPreview, conflict, correction, report, picksOpen = nil, nil, false, nil, false, false, false
		savePrefs()
		readBaseline()
	end
	local function planUrl(value: any): boolean
		if not safeUrl(value) then return false end
		local prefix = "https://" .. repoName:lower() .. "/"
		return value:lower():sub(1, #prefix) == prefix
	end
	local function startPlan(replace: boolean)
		if not selectedBatch() or not baselineReady or baselineBusy or not snapshot then return end
		if baseline and not replace then scopeOpen = true; return end
		if replace and not baseline then return end
		correction, planPreview, conflict, report = replace, false, nil, false
		plan = { source = "", version = "", scope = {}, candidates = {}, acknowledged = false, correctionReason = "" }
		if baseline then
			plan.source, plan.version, plan.scope = baseline.source, baseline.version, table.clone(baseline.scope)
			for _, item in baseline.items do plan.candidates[item.id] = table.clone(item) end
		elseif prefs.source == "milestone" then
			local current = index.byBatch[selectedBatch()]
			if current and planUrl(current.url) then plan.source = current.url end
		end
	end
	local function addPlan(row: any)
		local issue = row.issue
		if not plan.candidates[issue.id] then
			plan.candidates[issue.id] = { id = issue.id, number = issue.number, url = issue.url, condition = "", confirmed = false }
		end
		planPreview, plan.acknowledged = false, false
	end
	local function checkPlan(): string?
		if not planUrl(plan.source) or plan.version == "" then return "请输入本仓库计划出处的 HTTPS 链接与可核对的来源版本。" end
		if not plan.scope.goal or plan.scope.goal == "" or not plan.scope.owner or plan.scope.owner == "" then
			return "原计划缺可观察目标或明确决策人；只能盘点。"
		end
		if correction then
			if plan.correctionReason == "" then return "显式更正须记录原因。" end
			for _, record in revisions do
				if plan.source == record.source and plan.version == record.version then return "更正须引用新来源或版本；同一来源版本不重复冻结。" end
			end
		end
		local count = 0
		for _, item in plan.candidates do
			if item.confirmed and item.condition ~= "" then count += 1 end
		end
		return if count == 0 then "至少逐项确认一条有原始接受条件的承诺；候选不会计入分母。" else nil
	end
	local function freeze()
		if not ctx.alive() or not snapshot or not selectedBatch() or not plan or not planPreview or not plan.acknowledged
			or not baselineReady or baselineBusy or not complete() then return end
		local problem = checkPlan()
		if problem then notice = problem; return end
		local source, id = prefs.source, selectedBatch() :: string
		local prefix = keyFor(source, id)
		if not prefix then return end
		local revision = if baseline then baseline.revision + 1 else 1
		local items = {}
		for _, item in ordered(plan.candidates) do
			if item.confirmed then table.insert(items, { id = item.id, number = item.number, url = item.url, condition = item.condition }) end
		end
		local initialScope = if baseline then table.clone(baseline.initialScope) else {}
		if not baseline then
			for _, row in index.issues do if row.batch == id then initialScope[row.issue.id] = true end end
		end
		for _, item in plan.candidates do initialScope[item.id] = true end
		local choice = index.byBatch[id]
		local record = {
			id = source .. ":" .. id .. ":" .. revision, revision = revision, supersedes = if baseline then baseline.id else nil,
			host = repo.host, repoId = snapshot.repoId, mapping = source, batch = id, batchLabel = choiceLabel(),
			batchUrl = if choice and safeUrl(choice.url) then choice.url elseif baseline then baseline.batchUrl else nil,
			source = plan.source, version = plan.version, scope = table.clone(plan.scope), items = items, initialScope = initialScope,
			confirmedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), confirmedBy = snapshot.viewer,
			correctionReason = if correction then plan.correctionReason else nil,
		}
		local request = revisionRead
		baselineBusy, storageError, notice = true, nil, nil
		ctx.store(prefix .. revision, "create", record, function(result, err)
			if not ctx.alive() or request ~= revisionRead then return end
			if result == true and not err then
				baseline, baselineBusy, plan, planPreview, correction, conflict, scopeOpen = record, false, nil, false, false, nil, true
				table.insert(revisions, record)
				notice = "已冻结本机基线 " .. record.id .. "；未写 GitHub。"
			else
				readBaseline(function()
					if baseline and baseline.revision >= revision then
						conflict = record
						notice = "另一面板已保存该版本；下方是已保存版本与本次预览的差异。未覆盖任何记录。"
					else notice = "基线未保存：" .. (err or "存储未返回成功确认。") end
				end)
			end
			draw()
		end)
	end
	local function changeEditor(label: string, value: any, apply: (string) -> ())
		local initial = if type(value) == "string" then value else ""
		editor = { label = label, text = initial, caret = #initial + 1, apply = apply }
		ctx.cx:frame({ { "focus", "main.batch-editor.input" } })
	end
	local function closeEditor(apply: boolean)
		local current = editor
		if not current then return end
		editor = nil
		local clear: {any} = { "focus", tern.json.null }
		ctx.cx:frame({ clear })
		if apply then current.apply(runtime.trim(current.text)) end
	end

	local function rowLabel(row: any): string return "#" .. row.issue.number .. " " .. row.issue.title end
	local function sourceText(record: any): string return record.source .. " · 版本依据：" .. record.version end
	local function resultLabel(fact: any, addition: boolean): string
		if not fact.row then return "未决：当前扫描无法按稳定 ID 读回" end
		if addition and not (fact.decision.added and safeUrl(fact.decision.additionUrl)) then return "待确认范围差异（未计为承诺）" end
		if fact.outcome == "pending" then return "未决：" .. (if safeUrl(fact.decision.evidence) and fact.decision.result and fact.decision.result ~= "" then fact.decision.result else "缺可核对的结算依据") end
		return outcomes[fact.outcome]
	end
	local function comparison(): any
		return if baseline and selectedBatch() then compare(index, selectedBatch(), baseline, complete() and baselineReady, decisions()) else nil
	end
	local function markdown(summary: any): string
		local selected = selectedBatch()
		local choice = if selected then index.byBatch[selected] else nil
		local lines = {
			"# " .. md(repoName) .. " · " .. md(choiceLabel()) .. " · "
				.. (if not summary then (if complete() and baselineReady then "盘点草稿" else "部分盘点草稿")
					elseif summary.complete then "结算草稿（完整扫描范围）" else "部分结算草稿"),
			"", "- 比较时间：" .. os.date("!%Y-%m-%dT%H:%M:%SZ"), "- 扫描范围：" .. md(scanScope()),
			"- 批次来源：" .. (if prefs.source == "milestone" then link("GitHub milestone", (choice and choice.url) or (baseline and baseline.batchUrl)) else "已确认的标题标记映射"),
			"- 本机草稿；复制不代表批准、发布或修改 GitHub，请先核对所引来源的可见性。", "",
		}
		if not summary then
			table.insert(lines, if baselineBusy or not baselineReady then "仅盘点：基线尚不可核对，不计算兑现率。" else "仅盘点：无基线，不计算兑现率。")
			for _, row in index.issues do
				if row.batch == selected then table.insert(lines, "- " .. link(rowLabel(row), row.issue.url) .. " — " .. md(row.reason)) end
			end
			return table.concat(lines, "\n")
		end
		table.insert(lines, "- 基线：" .. md(baseline.id) .. "（" .. md(baseline.confirmedAt) .. "，本机核对者 " .. md(baseline.confirmedBy) .. "）")
		table.insert(lines, "- 开批依据：" .. link("原计划", baseline.source) .. " · 版本 " .. md(baseline.version))
		if baseline.supersedes then table.insert(lines, "- 更正所替代基线：" .. md(baseline.supersedes) .. " · " .. md(baseline.correctionReason)) end
		for _, field in scopeFields do table.insert(lines, "- " .. field[2] .. "：" .. md(baseline.scope[field[1]] or "未知")) end
		if not summary.complete then
			table.insert(lines, "\n> 覆盖不足：不能作为全批结算。"
				.. (if #summary.missing > 0 then " 有 " .. #summary.missing .. " 个承诺项无法读回。" else "")
				.. (if not summary.evidenceComplete then " 关联的开放 PR 有未读完的审查记录或线程。" else ""))
		end
		local function factLine(fact: any, addition: boolean)
			local item, row, decision = fact.item, fact.row, fact.decision
			local issue = if row then row.issue else item
			local label = if row then rowLabel(row) else "#" .. item.number
			table.insert(lines, "- " .. link(label, issue.url) .. " — " .. md(resultLabel(fact, addition)))
			if not addition then table.insert(lines, "  - 原接受条件：" .. md(item.condition)) end
			if addition and decision.condition and decision.condition ~= "" then table.insert(lines, "  - 新增接受条件：" .. md(decision.condition)) end
			if addition and safeUrl(decision.additionUrl) then table.insert(lines, "  - " .. link("新增决定出处", decision.additionUrl)) end
			if row then
				if safeUrl(decision.evidence) then table.insert(lines, "  - " .. link("结算依据", decision.evidence) .. "：" .. md(decision.result or "未记录实际结果")) end
				if decision.environment and decision.environment ~= "" then table.insert(lines, "  - 环境与版本：" .. md(decision.environment)) end
				table.insert(lines, "  - GitHub Issue 状态：" .. md(issue.state) .. "（不代表验收）")
				for _, pr in row.prs do
					table.insert(lines, "  - " .. link("PR #" .. pr.number, pr.url) .. "：" .. md(table.concat(prFacts(pr), " · ")))
					for _, review in nodes(pr.latestReviews) do
						if review.state == "CHANGES_REQUESTED" then
							table.insert(lines, "    - " .. link("修改请求", review.url) .. "："
								.. (if onCurrentHead(pr, review) then "当前 head" else "旧版本或 head 未确认"))
						end
					end
				end
			end
		end
		table.insert(lines, "\n## 原承诺（固定分母 " .. #summary.original .. "）")
		for _, status in outcomeOrder do
			table.insert(lines, "\n### " .. outcomes[status])
			for _, fact in summary.original do if fact.outcome == status then factLine(fact, false) end end
		end
		table.insert(lines, "\n## 中途新增及候选范围差异（不进入原承诺分母）")
		for _, fact in summary.additions do factLine(fact, true) end
		table.insert(lines, "\n## 移出及条件变化")
		for _, fact in summary.moved do
			local decision = fact.decision
			table.insert(lines, "- " .. link(rowLabel(fact.row), fact.row.issue.url) .. "：当前批次 " .. md(fact.row.batch or "未映射")
				.. "；" .. (if safeUrl(decision.moveUrl) then link("负责人变更出处", decision.moveUrl) else "发现范围差异，待确认"))
		end
		for _, fact in summary.changed do
			local d = fact.decision
			table.insert(lines, "- " .. link("#" .. fact.item.number, (if fact.row then fact.row.issue else fact.item).url)
				.. "：原条件「" .. md(fact.item.condition) .. "」→ 当前条件「" .. md(d.condition) .. "」；"
				.. (if safeUrl(d.conditionUrl) and d.conditionOwner and d.conditionOwner ~= "" then link("变更批准出处", d.conditionUrl) .. "（" .. md(d.conditionOwner) .. "）" else "待确认批准人与出处"))
		end
		table.insert(lines, "\n## 发布依据（不推定其他平台可用）")
		for _, fact in summary.publications do
			table.insert(lines, "- " .. link("#" .. fact.item.number, fact.row.issue.url) .. "：" .. md(fact.decision.publication) .. " · " .. link("制品／发布出处", fact.decision.publicationUrl))
		end
		if #summary.publications == 0 then table.insert(lines, "- 未提供可核对发布依据。") end
		table.insert(lines, "\n## 复盘与后续\n- 遗留事项需由负责人在原计划位置确认。延期不自动计入下批承诺。")
		return table.concat(lines, "\n")
	end

	local function evidenceView(row: any): Node
		local issue = row.issue
		local labels, assignees = {}, {}
		for _, tag in nodes(issue.labels) do table.insert(labels, tag.name) end
		for _, person in nodes(issue.assignees) do table.insert(assignees, person.login) end
		local milestone = issue.milestone
		local fields: { Node } = {
			text(rowLabel(row), "strong"), text("Issue 出处：" .. issue.url), text("GitHub 状态：" .. issue.state),
			button("查看 GitHub Issue 出处", "issue-source", tostring(issue.number), false, not safeUrl(issue.url)),
			text("标题原始标记：" .. table.concat(titleMarks(issue.title), "、")), text("标签原值（已读）：" .. table.concat(labels, "、")),
			text("指派（已读）：" .. table.concat(assignees, "、")),
		}
		if type(milestone) == "table" then table.insert(fields, text("Milestone：" .. tostring(milestone.title) .. " · " .. tostring(milestone.url))) end
		if #row.prs == 0 then table.insert(fields, text(if complete() then "未见 GitHub 显式关闭引用。" else "已读范围未见显式关联；其余未知。")) end
		for _, pr in row.prs do
			table.insert(fields, text(pr.url .. " · " .. table.concat(prFacts(pr), " · ")))
			table.insert(fields, ui.row({ button("处理 PR #" .. pr.number, "open-pr", issue.number .. ":" .. pr.number),
				button("查看 GitHub PR 出处", "pr-source", issue.number .. ":" .. pr.number, false, not safeUrl(pr.url)) }))
			for i, review in nodes(pr.latestReviews) do
				if review.state == "CHANGES_REQUESTED" then
					local who = if type(review.author) == "table" then review.author.login else "未知"
					local commit = if type(review.commit) == "table" then review.commit.oid else "未知"
					table.insert(fields, text("修改请求 · " .. tostring(who) .. " · " .. tostring(review.submittedAt or "时间未知")
						.. " · " .. tostring(commit) .. (if onCurrentHead(pr, review) then "（当前 head）" else "（旧版本或 head 未确认）")))
					if safeUrl(review.url) then table.insert(fields, button("查看审查出处", "review-source", issue.number .. ":" .. pr.number .. ":" .. i)) end
				end
			end
		end
		local original = nil
		if baseline then for _, item in baseline.items do if item.id == issue.id then original = item; break end end end
		if original then table.insert(fields, text("原接受条件：" .. original.condition .. " · " .. sourceText(baseline))) end
		local d = decisions()[issue.id]
		if d then
			if d.result then table.insert(fields, text("实际结果：" .. d.result)) end
			if d.environment then table.insert(fields, text("环境与版本：" .. d.environment)) end
			if safeUrl(d.evidence) then
				table.insert(fields, text("验收／决定出处：" .. d.evidence))
				table.insert(fields, button("查看验收／决定出处", "decision-source", tostring(issue.number)))
			end
		end
		table.insert(fields, button("收起依据", "close-evidence"))
		return ui.card("依据", fields, { key = "batch-evidence-card" })
	end

	local function field(label: string, value: any, key: string): Node
		return button(label .. "：" .. (if value and value ~= "" then value else "未填写"), "edit", key)
	end
	local function conflictView(): Node
		local messages: { Node } = { text("已保存：" .. sourceText(baseline)), text("本次预览：" .. sourceText(conflict)) }
		for _, fieldInfo in scopeFields do
			local key = fieldInfo[1]
			if baseline.scope[key] ~= conflict.scope[key] then
				table.insert(messages, text(fieldInfo[2] .. "：已保存「" .. tostring(baseline.scope[key] or "未记录") .. "」，本次「" .. tostring(conflict.scope[key] or "未记录") .. "」"))
			end
		end
		local candidate = {}
		for _, item in conflict.items do candidate[item.id] = item end
		for _, item in baseline.items do
			local draft = candidate[item.id]
			if not draft then table.insert(messages, text("#" .. item.number .. " 仅在已保存版本"))
			elseif item.condition ~= draft.condition then table.insert(messages, text("#" .. item.number .. " 条件：已保存「" .. item.condition .. "」，本次「" .. draft.condition .. "」")) end
			candidate[item.id] = nil
		end
		for _, item in ordered(candidate) do table.insert(messages, text("#" .. item.number .. " 仅在本次预览")) end
		table.insert(messages, button("保留已保存基线", "cancel-plan"))
		return ui.card("基线保存冲突", messages, { key = "batch-conflict" })
	end

	local function planView(): Node
		local controls: { Node } = {
			text("从已有计划逐项引用事实；此处只冻结比较快照，不批准或编辑团队计划。"),
			field("计划来源链接", plan.source, "source"), field("版本／修订依据", plan.version, "version"),
		}
		if planUrl(plan.source) then table.insert(controls, button("打开原计划核对", "plan-source")) end
		for _, info in scopeFields do table.insert(controls, field(info[2], plan.scope[info[1]], "scope:" .. info[1])) end
		if correction then table.insert(controls, field("显式更正原因", plan.correctionReason, "correctionReason")) end
		if not planPreview then
			table.insert(controls, button("从计划按 Issue 编号添加候选…", "edit", "add-number"))
			table.insert(controls, text("也可用列表里的「加入计划预览」。只按明确引用，不从计划自由文本推定承诺。"))
		end
		for _, item in ordered(plan.candidates) do
			local row = index.byId[item.id]
			table.insert(controls, text((if item.confirmed then "承诺 · " else "候选（不计分母） · ")
				.. (if row then rowLabel(row) else "#" .. item.number) .. " · " .. tostring(item.url or "出处未知")))
			if planPreview then table.insert(controls, text("原接受条件：" .. (if item.condition == "" then "未填写" else item.condition)))
			else
				local number = tostring(item.number)
				table.insert(controls, field("原接受条件", item.condition, "condition:" .. number))
				table.insert(controls, ui.row({ button(if item.confirmed then "改回候选" else "确认此项有承诺", "confirm-item", number, item.confirmed, item.condition == ""),
					button("移出预览", "remove-item", number) }))
			end
		end
		if planPreview then
			local problem = checkPlan()
			if problem then table.insert(controls, text(problem, "warning")) end
			if not complete() then table.insert(controls, text("扫描覆盖不足，不能冻结本次范围。", "warning")) end
			table.insert(controls, button("我已核对原计划版本、范围与逐项承诺", "acknowledge", nil, plan.acknowledged, problem ~= nil or baselineBusy))
			table.insert(controls, ui.row({ button("冻结本机基线", "freeze", nil, false, problem ~= nil or not plan.acknowledged or not complete() or baselineBusy),
				button("返回编辑", "edit-plan", nil, false, baselineBusy), button("取消", "cancel-plan", nil, false, baselineBusy) }))
		else table.insert(controls, ui.row({ button("预览范围与承诺", "preview-plan"), button("取消", "cancel-plan") })) end
		return ui.card(if correction then "更正（保留旧基线）" else "计划与初始范围", controls, { key = "batch-plan-card" })
	end

	local decisionFields = {
		{ "evidence", "验收／决定记录链接" }, { "result", "实际结果／延期或取消理由" }, { "environment", "环境、构建及版本（验收必填）" },
		{ "condition", "当前接受条件" }, { "conditionUrl", "条件变更批准链接" }, { "conditionOwner", "条件变更批准人" },
		{ "moveUrl", "移出决定出处" }, { "additionUrl", "新增决定出处" }, { "publication", "实际发布渠道、平台和制品" },
		{ "publicationUrl", "发布／制品出处" },
	}
	local function reportView(): Node
		local summary = comparison()
		local fields: { Node } = { text(scanScope()), button("复制 Markdown 草稿", "copy"), button("收起草稿", "close-report") }
		if not summary then
			table.insert(fields, text("仅盘点：没有可用基线；不计算兑现率。"))
			return ui.card("盘点草稿", fields, { key = "batch-report" })
		end
		table.insert(fields, text("基线 " .. baseline.id .. " · " .. sourceText(baseline)))
		if not summary.complete then
			table.insert(fields, text("只能输出部分草稿；不会作为全批结算。找不回的承诺项：" .. #summary.missing
				.. (if not summary.evidenceComplete then " · 关联 PR 审查记录或线程覆盖不足" else ""), "warning"))
		end
		table.insert(fields, button("按编号引用计划中的新增项…", "edit", "add-settlement"))
		local stats: { string } = {}
		for _, outcome in outcomeOrder do
			local count = 0
			for _, fact in summary.original do if fact.outcome == outcome then count += 1 end end
			table.insert(stats, outcomes[outcome] .. " " .. count)
		end
		table.insert(fields, text("原承诺 " .. #summary.original .. "：" .. table.concat(stats, " · ")))
		table.insert(fields, text("新增与待确认差异 " .. #summary.additions .. " · 移出 " .. #summary.moved .. " · 条件变化 " .. #summary.changed))
		local total = #summary.original + #summary.additions
		local page = math.clamp(reportPage, 1, math.max(1, math.ceil(total / PAGE)))
		for i = (page - 1) * PAGE + 1, math.min(page * PAGE, total) do
			local addition = i > #summary.original
			local fact = if addition then summary.additions[i - #summary.original] else summary.original[i]
			local item, row, d = fact.item, fact.row, fact.decision
			local number = tostring(item.number)
			table.insert(fields, text((if addition then "新增范围 · " else "原承诺 · ") .. (if row then rowLabel(row) else "#" .. number) .. " — " .. resultLabel(fact, addition), "strong"))
			if not addition then table.insert(fields, text("原接受条件：" .. item.condition)) end
			if not row then
				table.insert(fields, text("来源：" .. tostring(item.url or "未知")))
			else
				table.insert(fields, text("来源：" .. row.issue.url .. " · 当前批次 " .. tostring(row.batch or "未映射") .. " · " .. row.issue.state))
				table.insert(fields, ui.row({ button("打开 Issue", "open-issue", number), button("依据", "evidence", number),
					button("引用结算证据", "report-item", number, reportItem == row.issue.id) }))
				if evidence == row.issue.id then table.insert(fields, evidenceView(row)) end
				if reportItem == row.issue.id then
					local choices: { Node } = {}
					for _, status in outcomeOrder do table.insert(choices, button(outcomes[status], "outcome", number .. ":" .. status, (d.outcome or "pending") == status)) end
					chunks(fields, choices, 2)
					for _, info in decisionFields do
						local key = info[1]
						if (key ~= "additionUrl" or addition) and (key ~= "moveUrl" or row.batch ~= selectedBatch()) then
							table.insert(fields, field(info[2], d[key], "decision:" .. number .. ":" .. key))
						end
					end
					if addition then table.insert(fields, button("确认原计划已批准新增", "confirm-addition", number, d.added == true, not safeUrl(d.additionUrl))) end
				end
			end
		end
		if total > PAGE then
			table.insert(fields, ui.row({ button("上一页", "report-prev", nil, false, page <= 1), text(tostring(page)),
				button("下一页", "report-next", nil, false, page * PAGE >= total) }))
		end
		return ui.card(if summary.complete then "结算草稿（完整扫描范围）" else "部分结算草稿", fields, { key = "batch-report" })
	end

	function controller.view(): { Node }
		local result: { Node } = {
			text(repoName .. " · 批次回顾", "strong"), text(scanScope(), if complete() then "muted" else "warning"),
			ui.row({ button("刷新扫描", "refresh", nil, false, scanBusy or baselineBusy), button("选择批次来源", "mapping") }),
		}
		if storageError then table.insert(result, text(storageError, "warning")) end
		if notice then table.insert(result, text(notice, "accent")) end
		if editor then
			local length = 0
			for i, code in utf8.codes(editor.text) do if i >= editor.caret then break end; length += if code > 0xFFFF then 2 else 1 end
			table.insert(result, ui.card("", { text(editor.label, "strong"), ui.node("input", { key = "input", text = editor.text, cursor = length }),
				ui.row({ button("应用 ↵", "apply-editor"), button("取消", "cancel-editor") }) }, { key = "batch-editor" }))
		end
		if prefsBusy then table.insert(result, text("正在读取本仓库的回顾偏好…")); return result end
		if not prefs.source and not previewSource then previewSource = "milestone" end
		if previewSource then
			local mapped, unmatched = 0, 0
			table.insert(result, ui.row({ button("原生 milestone", "preview-mapping", "milestone", previewSource == "milestone"),
				button("标题标记映射", "preview-mapping", "title", previewSource == "title") }))
			table.insert(result, text(if previewSource == "milestone" then "按原生 milestone 稳定 ID 归类，不使用标题。" else
				"仅读标题开头连续闭合的【标记】；恰有一个不同的纯数字值（最多 24 位）才归入对应批次。"))
			if previewSource == "title" and fd then
				local names = {}
				for phase in phases do table.insert(names, phase) end
				table.sort(names)
				table.insert(result, text("FD 精确阶段映射：" .. table.concat(names, "、")))
			end
			local matching: { Node } = {}
			local other: { Node } = {}
			for _, row in index.issues do
				local key, label = membership(row.issue, previewSource)
				if key and mapped < 3 then table.insert(matching, text("命中：" .. rowLabel(row) .. " → " .. (label or key))); mapped += 1 end
				if not key and unmatched < 3 then table.insert(other, text("未匹配：" .. rowLabel(row))); unmatched += 1 end
				if mapped >= 3 and unmatched >= 3 then break end
			end
			for _, node in matching do table.insert(result, node) end
			for _, node in other do table.insert(result, node) end
			if mapped == 0 then table.insert(result, text("已读范围暂无命中样例。")) end
			if unmatched == 0 then table.insert(result, text("已读范围暂无未匹配样例。")) end
			table.insert(result, button("确认此仓库使用此来源", "confirm-mapping", previewSource, false, baselineBusy or not snapshot))
			table.insert(result, text("Esc 返回任务浏览；不使用批次不影响普通浏览。"))
			return result
		end
		local selected = selectedBatch()
		local choice = if selected then batchChoice(selected) else nil
		local group = prefGroup()
		table.insert(result, ui.row({ button("批次：" .. choiceLabel(), "toggle-picks", nil, picksOpen), button("范围与目标", "scope", nil, scopeOpen) }))
		table.insert(result, text(if baselineBusy then "正在核对本机基线…" elseif baseline then "基线 " .. baseline.id
			.. (if baselineReady then " · 本机已冻结" else " · 版本未完整核对") elseif not baselineReady then "仅盘点 · 基线状态未知" else "仅盘点 · 无基线"))
		if picksOpen or not selected then
			local choices = {}
			local known = prefs.knownBatches[prefs.source] or {}
			for _, entry in index.batches do table.insert(choices, button(entry.label, "pick", entry.key, entry.key == selected, baselineBusy)) end
			local previous: { any } = {}
			for id, entry in known do if not index.byBatch[id] then table.insert(previous, entry) end end
			table.sort(previous, function(a, b) return a.label < b.label or (a.label == b.label and a.key < b.key) end)
			for _, entry in previous do
				table.insert(choices, button(entry.label .. "（上次记录）", "pick", entry.key, entry.key == selected, baselineBusy))
			end
			chunks(result, choices, if ctx.cx.cols >= 75 then 4 else 2)
			if #choices == 0 then table.insert(result, text("已读范围暂无可选批次。")) end
		end
		if scopeOpen then
			local scope: { Node } = { text("批次来源：" .. (if prefs.source == "milestone" then "GitHub milestone" else "已确认标题数字标记")) }
			if choice and safeUrl(choice.url) then
				table.insert(scope, text("范围出处：" .. choice.url))
				table.insert(scope, button("查看 milestone", "milestone-source"))
			end
			if baseline then
				table.insert(scope, text("开批依据：" .. sourceText(baseline)))
				table.insert(scope, button("查看开批出处", "baseline-source", tostring(baseline.revision)))
				for _, info in scopeFields do table.insert(scope, text(info[2] .. "：" .. (baseline.scope[info[1]] or "未知"))) end
				if baseline.supersedes then table.insert(scope, text("替代 " .. baseline.supersedes .. "：" .. baseline.correctionReason)) end
				for _, record in revisions do
					if record.id ~= baseline.id then table.insert(scope, text("保留旧版 " .. record.id .. " · " .. sourceText(record) .. " · 原承诺 " .. #record.items .. " 项")) end
					if record.id ~= baseline.id then table.insert(scope, button("查看旧版出处", "baseline-source", tostring(record.revision))) end
				end
				table.insert(scope, button("显式更正基线…", "correct", nil, false, plan ~= nil or baselineBusy or not baselineReady))
			else table.insert(scope, text("尚无已核对的目标、非目标或决策人；标有批次不等于承诺。")) end
			table.insert(result, ui.card("范围与目标", scope, { key = "batch-scope" }))
		end
		if report then table.insert(result, reportView()); return result end
		local queueButtons = {}
		for _, queue in queues do table.insert(queueButtons, button(queue[2], "queue", queue[1], group.queue == queue[1])) end
		chunks(result, queueButtons, if ctx.cx.cols >= 75 then 4 else 2)
		local rows = visible()
		local active = selectedRow(rows)
		local page = math.clamp(group.page or 1, 1, math.max(1, math.ceil(#rows / PAGE)))
		for i, row in rows do if row == active then page = math.ceil(i / PAGE); break end end
		if #rows == 0 then table.insert(result, text(if complete() then "该队列没有符合条件的已读事项。" else "尚未在已读范围看到匹配事项。"))
		else table.insert(result, text((if complete() then "队列事项（按 Issue 去重）：" else "队列已读事项（部分）：") .. #rows
			.. (if group.queue == "all" and selected then " · 包括未映射事项" else ""))) end
		for i = (page - 1) * PAGE + 1, math.min(page * PAGE, #rows) do
			local row = rows[i]
			local number = tostring(row.issue.number)
			local rowFields: { Node } = { button(rowLabel(row), "open-issue", number, row == active), text(row.reason),
				button("依据", "evidence", number, evidence == row.issue.id) }
			if plan and not planPreview and not plan.candidates[row.issue.id] then table.insert(rowFields, button("加入计划预览", "add-plan", number)) end
			if evidence == row.issue.id and not report then table.insert(rowFields, evidenceView(row)) end
			table.insert(result, ui.node("col", { key = "batch-row-" .. number }, rowFields))
		end
		if #rows > PAGE then table.insert(result, ui.row({ button("上一页", "prev", nil, false, page <= 1), text(tostring(page)),
			button("下一页", "next", nil, false, page * PAGE >= #rows) })) end
		if selected then
			table.insert(result, ui.row({ button("记录开批基线", "plan", nil, false, baselineBusy or not baselineReady or plan ~= nil),
				button("比较并生成结算草稿", "report", nil, report, baselineBusy) }))
		end
		if conflict then table.insert(result, conflictView()) elseif plan then table.insert(result, planView()) end
		return result
	end

	local function decisionFor(row: any): any
		local records, id = decisions(), row.issue.id
		if not records[id] then records[id] = {} end
		return records[id]
	end
	local function editField(value: string)
		if value == "add-settlement" and report and baseline then
			changeEditor("原计划另行记录的新增 Issue 编号", "", function(input)
				local row = index.byNumber[tonumber(input)]
				if not row then notice = "本次扫描未读到此事项，不能确认新增。"; return end
				for _, item in baseline.items do
					if item.id == row.issue.id then notice = "此项已是原承诺，不能同时计为新增。"; return end
				end
				local d = decisionFor(row)
				d.item = { id = row.issue.id, number = row.issue.number, url = row.issue.url }
				reportItem = row.issue.id
				local result = comparison()
				for i, fact in result.additions do
					if fact.item.id == row.issue.id then reportPage = math.ceil((#result.original + i) / PAGE); break end
				end
			end)
			return
		end
		local number, key = value:match("^decision:(%d+):(%w+)$")
		if number and report then
			local row = index.byNumber[tonumber(number)]
			if not row then return end
			for _, info in decisionFields do
				if key and info[1] == key then
					local d = decisionFor(row)
					changeEditor(info[2], d[key], function(input)
						if key == "evidence" or key:sub(-3) == "Url" then
							if input ~= "" and not safeUrl(input) then notice = "请输入可引用的 HTTPS 出处，不要粘贴原始日志。"; return end
						end
						d[key] = input
						if key == "additionUrl" then d.added = false end
					end)
					return
				end
			end
		end
		if not plan or baselineBusy or conflict then return end
		local target: any, fieldKey: string, label: string = plan, value, value
		local scopeKey = value:match("^scope:(%w+)$")
		local issueNumber = value:match("^condition:(%d+)$")
		if scopeKey then
			target, fieldKey = plan.scope, scopeKey
			for _, info in scopeFields do if info[1] == scopeKey then label = info[2]; break end end
		elseif issueNumber then
			local row = index.byNumber[tonumber(issueNumber)]
			target = if row then plan.candidates[row.issue.id] else nil
			if not target then
				for _, item in plan.candidates do if item.number == tonumber(issueNumber) then target = item; break end end
			end
			if not target then return end
			fieldKey, label = "condition", "原计划的接受条件"
		elseif value == "add-number" then
			changeEditor("原计划引用的 Issue 编号", "", function(input)
				local row = index.byNumber[tonumber(input)]
				if row then addPlan(row) else notice = "已读范围没有此编号；刷新或确认原件后重试。" end
			end)
			return
		elseif value == "source" then label = "本仓库已有计划的 HTTPS 链接"
		elseif value == "version" then label = "可核对版本（如不可变提交或计划修订时间）"
		elseif value == "correctionReason" then label = "更正原因与决定依据"
		else return end
		changeEditor(label, target[fieldKey], function(input)
			target[fieldKey] = input
			if fieldKey == "condition" then target.confirmed = false end
			planPreview, plan.acknowledged = false, false
		end)
	end
	function controller.event(action: string, value: string?)
		if not ctx.alive() then return end
		notice = nil
		local row = index.byNumber[tonumber(value) or 0]
		if action == "refresh" and not baselineBusy then refresh()
		elseif action == "mapping" and not baselineBusy then previewSource = prefs.source or "milestone"
		elseif action == "preview-mapping" and (value == "title" or value == "milestone") then previewSource = value
		elseif action == "confirm-mapping" and not baselineBusy and snapshot and (value == "title" or value == "milestone") and value == previewSource then setSource(value)
		elseif action == "toggle-picks" then picksOpen = not picksOpen
		elseif action == "pick" and prefs.source and value and not baselineBusy then
			local choice = batchChoice(value)
			if choice then chooseBatch(choice) end
		elseif action == "scope" then scopeOpen = not scopeOpen
		elseif action == "milestone-source" and selectedBatch() then
			local choice = batchChoice(selectedBatch() :: string)
			if choice and safeUrl(choice.url) then ctx.cx:open(choice.url) end
		elseif action == "baseline-source" then
			local record = revisions[tonumber(value) or 0]
			if record and planUrl(record.source) then ctx.cx:open(record.source) end
		elseif action == "plan-source" and plan then
			if planUrl(plan.source) then ctx.cx:open(plan.source) end
		elseif action == "issue-source" and row and evidence == row.issue.id then
			if safeUrl(row.issue.url) then ctx.cx:open(row.issue.url) end
		elseif action == "decision-source" and row and evidence == row.issue.id then
			local d = decisions()[row.issue.id]
			if d and safeUrl(d.evidence) then ctx.cx:open(d.evidence) end
		elseif action == "queue" then
			for _, queue in queues do
				if queue[1] == value then local group = prefGroup(); group.queue, group.page, evidence = value, 1, nil; savePrefs(); break end
			end
		elseif action == "prev" or action == "next" then
			local group = prefGroup()
			local rows = visible()
			local page = math.clamp((group.page or 1) + (if action == "prev" then -1 else 1), 1, math.max(1, math.ceil(#rows / PAGE)))
			local first = rows[(page - 1) * PAGE + 1]
			if first then select(first, page) end
			evidence = nil
		elseif action == "evidence" and row then
			if not report then select(row) end
			evidence = if evidence == row.issue.id then nil else row.issue.id
		elseif action == "close-evidence" then evidence = nil
		elseif action == "open-issue" and row then
			if not report then select(row) end
			ctx.open("issue", row.issue.number)
		elseif (action == "open-pr" or action == "pr-source") and value then
			local issueNumber, prNumber = value:match("^(%d+):(%d+)$")
			local issueRow = index.byNumber[tonumber(issueNumber) or 0]
			if issueRow and evidence == issueRow.issue.id then
				for _, pr in issueRow.prs do
					if pr.number == tonumber(prNumber) then
						if action == "open-pr" then ctx.open("pr", pr.number)
						elseif safeUrl(pr.url) then ctx.cx:open(pr.url) end
						break
					end
				end
			end
		elseif action == "review-source" and value then
			local issueNumber, prNumber, reviewIndex = value:match("^(%d+):(%d+):(%d+)$")
			local issueRow = index.byNumber[tonumber(issueNumber) or 0]
			if issueRow and evidence == issueRow.issue.id then
				for _, pr in issueRow.prs do
					if pr.number == tonumber(prNumber) then
						local review = nodes(pr.latestReviews)[tonumber(reviewIndex) or 0]
						if review and review.state == "CHANGES_REQUESTED" and safeUrl(review.url) then ctx.cx:open(review.url) end
						break
					end
				end
			end
		elseif action == "plan" then startPlan(false)
		elseif action == "correct" then startPlan(true)
		elseif action == "cancel-plan" and not baselineBusy then plan, planPreview, correction, conflict = nil, false, false, nil
		elseif action == "add-plan" and row and plan and not planPreview and not conflict then addPlan(row)
		elseif (action == "confirm-item" or action == "remove-item") and plan and not planPreview and not conflict then
			for id, item in plan.candidates do
				if item.number == tonumber(value) then
					if action == "remove-item" then plan.candidates[id] = nil elseif item.condition ~= "" then item.confirmed = not item.confirmed end
					break
				end
			end
		elseif action == "preview-plan" and plan and not conflict then planPreview, plan.acknowledged = true, false
		elseif action == "edit-plan" and plan and not baselineBusy then planPreview, plan.acknowledged = false, false
		elseif action == "acknowledge" and plan and planPreview and not baselineBusy and not conflict and not checkPlan() then plan.acknowledged = not plan.acknowledged
		elseif action == "freeze" and not conflict then freeze()
		elseif action == "edit" and value then editField(value)
		elseif action == "apply-editor" then closeEditor(true)
		elseif action == "cancel-editor" then closeEditor(false)
		elseif action == "report" and selectedBatch() and not baselineBusy then report, reportPage, evidence = true, 1, nil
		elseif action == "report-item" and row and report then reportItem = if reportItem == row.issue.id then nil else row.issue.id
		elseif action == "close-report" then report, evidence = false, nil
		elseif action == "report-prev" then reportPage, evidence = math.max(1, reportPage - 1), nil
		elseif action == "report-next" then reportPage, evidence = reportPage + 1, nil
		elseif action == "outcome" and value and report then
			local number, status = value:match("^(%d+):(%a+)$")
			local hit = index.byNumber[tonumber(number) or 0]
			if hit and status and outcomes[status] then decisionFor(hit).outcome = status end
		elseif action == "confirm-addition" and row and report then
			local d = decisionFor(row)
			if safeUrl(d.additionUrl) then
				d.added = not d.added
				d.item = { id = row.issue.id, number = row.issue.number, url = row.issue.url }
			end
		elseif action == "copy" and report and not baselineBusy then
			ctx.cx:copy(markdown(comparison()))
			notice = "已复制本机 Markdown 草稿；未写 GitHub。"
		end
		draw()
	end

	function controller.key(key: Key): boolean
		if not ctx.alive() then return false end
		if editor then
			if key.name == "escape" then closeEditor(false)
			elseif key.name == "enter" then closeEditor(true)
			elseif key.ctrl or key.meta or key.alt then return false
			else
				local str, caret = editor.text, editor.caret
				if key.name == "left" then editor.caret = utf8.offset(str, -1, caret) or 1
				elseif key.name == "right" then editor.caret = utf8.offset(str, 2, caret) or #str + 1
				elseif key.name == "home" then editor.caret = 1
				elseif key.name == "end" then editor.caret = #str + 1
				elseif key.name == "backspace" or key.name == "delete" then
					local first = if key.name == "backspace" then utf8.offset(str, -1, caret) or caret else caret
					local last = if key.name == "delete" then utf8.offset(str, 2, caret) or #str + 1 else caret
					editor.text, editor.caret = str:sub(1, first - 1) .. str:sub(last), first
				elseif key.text and key.text ~= "" then
					local input = key.text:gsub("[%c]", " ")
					if #str + #input <= 2048 and utf8.len(input) then editor.text, editor.caret = str:sub(1, caret - 1) .. input .. str:sub(caret), caret + #input end
				else return false end
			end
		elseif key.name == "escape" and evidence then evidence = nil
		elseif key.name == "escape" and previewSource and prefs.source then previewSource = nil
		elseif key.name == "escape" and report then report = false
		elseif key.name == "escape" and plan and not baselineBusy then plan, planPreview, correction, conflict = nil, false, false, nil
		elseif key.name == "enter" and not previewSource and not report then
			local row = selectedRow(visible())
			if not row then return false end
			select(row)
			ctx.open("issue", row.issue.number)
		elseif (key.name == "up" or key.name == "down") and not previewSource and not report then
			local rows = visible()
			if #rows == 0 then return false end
			local current = selectedRow(rows)
			for i, row in rows do
				if row == current then
					local nextIndex = math.clamp(i + (if key.name == "up" then -1 else 1), 1, #rows)
					select(rows[nextIndex], math.ceil(nextIndex / PAGE)); evidence = nil; break
				end
			end
		else return false end
		draw()
		return true
	end

	tern.timer(0, function()
		if not ctx.alive() then return end
		ctx.store("batch-prefs", "read", nil, function(stored, err)
			if not ctx.alive() then return end
			prefsBusy = false
			if err then storageError = "不能读取仓库回顾偏好：" .. err end
			if type(stored) == "table" then
				if stored.source == "milestone" or stored.source == "title" then prefs.source = stored.source end
				if type(stored.bySource) == "table" then prefs.bySource = stored.bySource end
				if type(stored.byBatch) == "table" then prefs.byBatch = stored.byBatch end
				if type(stored.knownBatches) == "table" then prefs.knownBatches = stored.knownBatches end
			end
			refresh()
		end)
	end)
	return controller
end

return batch
