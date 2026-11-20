--!strict

local runtime = require("./runtime")
local ui = tern.ui

local verification = {}
local outcomes: { [string]: string } = { pass = "指定范围通过", fail = "指定范围失败", limited = "验证受限" }
local relationships: { [string]: string } = { self = "作者自测", independent = "独立复测", unknown = "独立性未确认" }
local provenances: { [string]: string } = { localTest = "本机记录", public = "公开证据摘录（手工登记）" }
local builds: { [string]: string } = { localBuild = "本机构建", pr = "PR head", release = "已发布版本" }
local fields = {
	{ "symptom", "具体症状" }, { "condition", "原接受条件" }, { "conditionSource", "接受条件来源（评论链接或可定位出处）" },
	{ "environment", "验证环境（平台、版本与关键配置）" }, { "version", "候选版本／构建标识" },
	{ "channel", "发布渠道" }, { "artifact", "制品标识" }, { "changes", "制品对应的修复变更" },
	{ "steps", "输入、步骤与触发条件" }, { "expected", "预期结果" }, { "actual", "实际观察" },
	{ "control", "旧版对照结果，或无法对照的原因" }, { "attempts", "尝试次数（无法试验可填 0）" },
	{ "limits", "限制或未覆盖范围" }, { "author", "公开复测者" }, { "observed", "公开证据的观察日期／时间" },
	{ "evidence", "证据链接或简短出处（不贴原始日志）" },
}
local releaseFields: { [string]: boolean } = { channel = true, artifact = true, changes = true }
local publicFields: { [string]: boolean } = { author = true, observed = true }
local labels: { [string]: string } = {}
for _, field in fields do labels[field[1]] = field[2] end

type Values = { [string]: string? }
type Record = {
	schema: number, issueId: string, outcome: string, relationship: string, provenance: string, build: string,
	verifier: string, observedAt: string, recordedAt: number, fields: Values,
}
type Data = { bookmarked: boolean, records: {Record} }
type Draft = { fields: Values, build: string?, outcome: string?, provenance: string?, relationship: string?, reuse: string? }
type Edit = { field: string, text: string, caret: number }

local RECORD_KEY = "verify-records"

local function bookmarkKeyFor(issue: any): string?
	local id = issue.id
	if type(id) ~= "string" or id == "" then return nil end
	local key = id:gsub("[^A-Za-z0-9-]", function(char) return ("_%02x"):format(char:byte()) end)
	if #key > 164 then return nil end
	return "verify-bookmark-" .. key
end

local requiredFields = { "symptom", "condition", "conditionSource", "environment", "version", "steps", "expected", "control", "attempts" }

local function journal(ctx: any, done: ({Record}?, string?) -> ())
	if not ctx.alive() then return end
	ctx.store(RECORD_KEY, "list", nil, function(items: any, err: string?)
		if not ctx.alive() then return end
		if err or (items ~= nil and type(items) ~= "table") then done(nil, err or "验收历史格式无法识别。"); return end
		local records: {Record} = {}
		for _, item in items or {} do
			if type(item) ~= "table" or item.schema ~= 1 or type(item.issueId) ~= "string" or item.issueId == ""
				or type(item.recordedAt) ~= "number" or type(item.observedAt) ~= "string"
				or type(item.verifier) ~= "string" or type(item.fields) ~= "table"
				or not (outcomes[item.outcome] and relationships[item.relationship] and provenances[item.provenance] and builds[item.build]) then
				done(nil, "验收历史包含无法识别的记录。"); return
			end
			for _, field in fields do
				local value = item.fields[field[1]]
				if value ~= nil and (type(value) ~= "string" or not utf8.len(value)) then
					done(nil, "验收历史包含无法识别的字段。"); return
				end
			end
			for _, name in requiredFields do
				if not item.fields[name] or item.fields[name] == "" then done(nil, "验收历史缺少必需字段。"); return end
			end
			table.insert(records, item)
		end
		table.sort(records, function(a, b) return a.recordedAt > b.recordedAt end)
		done(records, nil)
	end)
end

local function load(ctx: any, issue: any, done: (Data?, string?) -> ())
	local bookmarkKey = bookmarkKeyFor(issue)
	if not bookmarkKey then done(nil, "缺少可定位的 GitHub Issue ID，无法读写个人验收数据。"); return end
	if not ctx.alive() then return end
	ctx.store(bookmarkKey, "read", nil, function(bookmark: any, err: string?)
		if not ctx.alive() then return end
		if err then done(nil, err); return end
		if bookmark ~= nil and (type(bookmark) ~= "table" or bookmark.schema ~= 1 or bookmark.issueId ~= issue.id) then
			done(nil, "个人书签格式无法识别。"); return
		end
		journal(ctx, function(all, listError)
			if not all then done(nil, listError); return end
			local records: {Record} = {}
			for _, item in all do if item.issueId == issue.id then table.insert(records, item) end end
			done({ bookmarked = bookmark ~= nil, records = records }, nil)
		end)
	end)
end

local function summarize(records: {Record}, bookmarked: boolean?)
	local scopes = {}
	local summary = { bookmarked = bookmarked, count = #records, passed = 0, failed = 0, limited = 0,
		selfPassed = 0, independentPassed = 0, scopes = scopes }
	local seen: { [string]: { time: number, outcomes: {[string]: boolean} } } = {}
	for _, record in records do
		local f = record.fields
		local key = tern.json.encode({ f.symptom, f.condition, f.conditionSource, f.environment, f.steps, f.expected, record.build, f.version,
			f.channel or "", f.artifact or "", f.changes or "", record.relationship, record.provenance })
		local latest = seen[key]
		if not latest then
			latest = { time = record.recordedAt, outcomes = {} }
			seen[key] = latest
		end
		-- Concurrent observations with the same timestamp must not hide a conflicting outcome.
		if latest.time == record.recordedAt and not latest.outcomes[record.outcome] then
			latest.outcomes[record.outcome] = true
			table.insert(scopes, { symptom = f.symptom, condition = f.condition, conditionSource = f.conditionSource,
				environment = f.environment, steps = f.steps, expected = f.expected,
				build = record.build, version = f.version, outcome = record.outcome,
				channel = f.channel, artifact = f.artifact, changes = f.changes,
				relationship = record.relationship, provenance = record.provenance, observedAt = record.observedAt })
			if record.outcome == "pass" then
				summary.passed += 1
				if record.relationship == "self" then summary.selfPassed += 1 end
				if record.relationship == "independent" then summary.independentPassed += 1 end
			elseif record.outcome == "fail" then summary.failed += 1
			else summary.limited += 1 end
		end
	end
	return summary
end

function verification.read(ctx: any, issue: any, done: (any?, string?) -> ())
	load(ctx, issue, function(data, err)
		if not data then done(nil, err); return end
		done(summarize(data.records, data.bookmarked), nil)
	end)
end

function verification.index(ctx: any, done: (any?, string?) -> ())
	journal(ctx, function(records, err)
		if not records then done(nil, err); return end
		local issues: {[string]: {Record}} = {}
		for _, record in records do
			local items = issues[record.issueId]
			if not items then items = {}; issues[record.issueId] = items end
			table.insert(items, record)
		end
		local summaries = {}
		for issueId, items in issues do summaries[issueId] = summarize(items) end
		done(summaries, nil)
	end)
end

local function button(label: string, action: string, active: boolean?, disabled: boolean?): Node
	return ui.button(label, { key = action, size = "sm", on = active, disabled = disabled, actions = { click = "verify:" .. action } })
end

local function text(label: string, tone: string?): Node
	return ui.text({ ui.span(label, tone or "muted") })
end

local function validate(draft: Draft, data: Data): string?
	if not draft.build or not draft.outcome or not draft.provenance or not draft.relationship then
		return "须选择构建类型、证据来源、复测者关系和结论。"
	end
	for _, name in requiredFields do
		if not draft.fields[name] then return "请填写：" .. labels[name] .. "。" end
	end
	local attempts = draft.fields.attempts or ""
	if not attempts:match("^%d+$") or #attempts > 9 then return "尝试次数须为非负整数。" end
	if draft.outcome ~= "limited" and (not draft.fields.actual or tonumber(attempts) == 0) then return "通过或失败须有实际试验及观察结果。" end
	if draft.outcome == "limited" and not draft.fields.limits then return "请注明无法验证的具体条件。" end
	if draft.provenance == "public" and (not draft.fields.evidence or not draft.fields.author or not draft.fields.observed) then
		return "公开证据须注明复测者、观察时间和可定位出处。"
	end
	if draft.build == "pr" then
		local version = draft.fields.version or ""
		if #version ~= 40 or not version:match("^%x+$") then return "PR head 请填写完整的 40 位提交 SHA。" end
	end
	if draft.build == "release" then
		for _, name in { "channel", "artifact", "changes" } do
			if not draft.fields[name] then return "发布验证须填写：" .. labels[name] .. "。" end
		end
	end
	if not draft.reuse then
		for _, record in data.records do
			if (record.fields.symptom or ""):lower() == (draft.fields.symptom or ""):lower() then
				return "此症状已存在，请从历史中选中它再新增证据。"
			end
		end
	end
	return nil
end

local function safeSummary(record: Record): string
	-- Free text, identities and URLs may be private even after pattern-based redaction.
	return table.concat({ "### 复测摘要", "", "- 结论：" .. outcomes[record.outcome],
		"- 构建类型：" .. builds[record.build], "- 证据：" .. provenances[record.provenance] .. " · " .. relationships[record.relationship],
		"", "只涉及此次测试的症状和范围，不代表整个 Issue 已解决、应关闭或已有团队验收决定。",
		"已省略私有标识、环境、版本、观察和证据链接；分享前请补充确认可公开的复测范围。" }, "\n")
end

function verification.new(ctx: any, issue: any)
	local data: Data? = nil
	local busy, showSummary = false, false
	local message: string? = nil
	local problem: string? = nil
	local draft: Draft? = nil
	local edit: Edit? = nil
	local symptom: string? = nil
	local record: Record? = nil
	local page, symptomPage = 1, 1
	local pageSize = 6
	local bookmarkKey = bookmarkKeyFor(issue)

	local function reload()
		if not ctx.alive() then return end
		busy, problem = true, nil
		load(ctx, issue, function(result, err)
			busy, data, problem = false, result, err
			ctx.render()
		end)
	end

	local function add(previous: Record?)
		local values: Values = {}
		if previous then
			for _, name in { "symptom", "condition", "conditionSource", "environment", "steps", "expected" } do values[name] = previous.fields[name] end
		end
		draft, edit, problem, message = { fields = values, reuse = if previous then previous.fields.symptom else nil }, nil, nil, nil
	end

	local function finishEdit()
		if not edit or not draft then return end
		local value = runtime.trim(edit.text)
		draft.fields[edit.field] = if value == "" then nil else value
		edit = nil
	end

	local function save(current: Draft, saved: Data)
		local err = validate(current, saved)
		if err then problem = err; return end
		if not bookmarkKey then return end
		busy = true
		ctx.identity(function(identity: any, identityError: string?)
			if not ctx.alive() then return end
			if identityError or type(identity) ~= "table" or type(identity.viewer) ~= "string" or identity.viewer == "" then
				busy, problem = false, identityError or "无法确认存储账号。"
				ctx.render(); return
			end
			local values = table.clone(current.fields)
			if current.build ~= "release" then for name in releaseFields do values[name] = nil end end
			if current.provenance ~= "public" then for name in publicFields do values[name] = nil end end
			if current.build == "pr" then values.version = (values.version or ""):lower() end
			local savedRecord: Record = { schema = 1, issueId = issue.id, outcome = assert(current.outcome), relationship = assert(current.relationship),
				provenance = assert(current.provenance), build = assert(current.build), fields = values, recordedAt = tern.now(),
				verifier = values.author or identity.viewer, observedAt = values.observed or os.date("!%Y-%m-%d %H:%M:%S UTC") }
			ctx.store(RECORD_KEY, "append", savedRecord, function(_: any, writeError: string?)
				if not ctx.alive() then return end
				busy, problem = false, writeError
				if not writeError then
					draft, symptom, record, page, showSummary = nil, values.symptom, savedRecord, 1, false
					message = "已添加本机历史，未写入 GitHub。"
					reload()
				end
				ctx.render()
			end)
		end)
	end

	local function listed(): {Record}
		local all: {Record} = {}
		local seen: { [string]: boolean } = {}
		if data then
			for _, item in data.records do
				local name = item.fields.symptom or ""
				if (symptom and name == symptom) or (not symptom and not seen[name]) then
					table.insert(all, item)
					seen[name] = true
				end
			end
		end
		return all
	end

	local function renderChoices(nodes: {Node}, key: string, choices: {string}, names: {[string]: string}, active: string?)
		local buttons = {}
		for _, choice in choices do table.insert(buttons, button(names[choice], key .. "=" .. choice, active == choice, busy)) end
		table.insert(nodes, ui.row(buttons))
	end

	local function view(): {Node}
		local nodes: {Node} = { text("#" .. tostring(issue.number) .. " · 个人验收与书签", "strong"),
			text("本机结论仅适用于明确选定的症状、条件与构建，不代表整条 Issue 已解决。") }
		if problem then table.insert(nodes, text(problem, "error")) end
		if message then table.insert(nodes, text(message, "accent")) end
		if busy then table.insert(nodes, ui.progress(nil, "正在访问个人数据…")) end
		local saved = data
		if not saved then
			if not busy and bookmarkKey then table.insert(nodes, button("重新读取", "refresh")) end
			return nodes
		end
		local current = draft
		if current then
			local editing = edit
			if editing then
				local caret = 0
				for index, code in utf8.codes(editing.text) do
					if index >= editing.caret then break end
					caret += if code > 0xFFFF then 2 else 1
				end
				table.insert(nodes, text(labels[editing.field], "strong"))
				table.insert(nodes, ui.node("input", { key = "verify_input", text = editing.text, cursor = caret }))
				table.insert(nodes, ui.row({ button("应用 ↵", "apply"), button("取消修改", "dismiss") }))
				return nodes
			end
			table.insert(nodes, ui.row({ button("保存新记录", "save", false, busy), button("取消新增", "cancel", false, busy) }))
			if current.reuse then table.insert(nodes, text("当前症状：" .. current.reuse, "strong")) end
			renderChoices(nodes, "outcome", { "pass", "fail", "limited" }, outcomes, current.outcome)
			renderChoices(nodes, "provenance", { "localTest", "public" }, provenances, current.provenance)
			renderChoices(nodes, "relationship", { "self", "independent", "unknown" }, relationships, current.relationship)
			renderChoices(nodes, "build", { "localBuild", "pr", "release" }, builds, current.build)
			for _, field in fields do
				local name, label = field[1], field[2]
				if (name ~= "symptom" or not current.reuse) and (not releaseFields[name] or current.build == "release")
					and (not publicFields[name] or current.provenance == "public") then
					table.insert(nodes, button(label .. (if current.fields[name] then " · 已填" else "…"), "field=" .. name, false, busy))
				end
			end
			return nodes
		end
		table.insert(nodes, ui.row({ button(if saved.bookmarked then "我在看 ✓ · 撤销" else "我在看 · 本机书签", "bookmark", saved.bookmarked, busy),
			button("返回原事项调查", "investigate", false, busy), button("刷新个人记录", "refresh", false, busy) }))
		if not symptom then
			table.insert(nodes, button("新增症状及验证证据…", "new", false, busy))
			if #saved.records == 0 then table.insert(nodes, text("尚无本机复测记录；不推断接手、修复或结案。")) end
		else
			table.insert(nodes, text("症状：" .. symptom, "strong"))
			table.insert(nodes, ui.row({ button("全部症状", "symptoms"), button("为当前症状添加证据…", "new", false, busy) }))
		end
		local all = listed()
		local index = if symptom then page else symptomPage
		local start = (index - 1) * pageSize + 1
		local last = math.min(#all, start + pageSize - 1)
		if #all > pageSize then
			table.insert(nodes, ui.row({ button("上一页", "prev", false, index == 1), button("下一页", "next", false, last == #all),
				text(start .. "–" .. last .. " / " .. #all) }))
		end
		for i = start, last do
			local item = all[i]
			local label = if symptom then item.observedAt .. " · " .. outcomes[item.outcome] .. " · " .. (item.fields.version or "")
				else item.fields.symptom or ""
			table.insert(nodes, button(label, "select=" .. i, item == record))
		end
		local selected = record
		if selected then
			table.insert(nodes, text(outcomes[selected.outcome] .. " · " .. builds[selected.build] .. " · " .. relationships[selected.relationship], "strong"))
			table.insert(nodes, text("证据来源：" .. provenances[selected.provenance] .. " · 复测者：" .. selected.verifier .. " · " .. selected.observedAt))
			for _, field in fields do
				local name, label = field[1], field[2]
				local value = selected.fields[name]
				if value and name ~= "symptom" and not publicFields[name] then table.insert(nodes, text(label .. "：" .. value)) end
			end
			table.insert(nodes, button(if showSummary then "收起分享摘要" else "预览脱敏分享摘要…", "summary", showSummary))
			if showSummary then
				for line in safeSummary(selected):gmatch("[^\n]+") do table.insert(nodes, text(line)) end
				table.insert(nodes, button("复制脱敏摘要", "copy"))
			end
		end
		return nodes
	end

	local function event(action: string, value: string?)
		if busy or not ctx.alive() then return end
		if action == "refresh" then reload(); return end
		local saved = data
		if not saved then return end
		problem, message = nil, nil
		local current = draft
		if current then
			if edit then
				if action == "apply" then finishEdit() elseif action == "dismiss" then edit = nil end
			elseif action == "cancel" then draft = nil
			elseif action == "field" and value and labels[value] and (value ~= "symptom" or not current.reuse) then
				local initial = current.fields[value] or ""
				edit = { field = value :: string, text = initial, caret = #initial + 1 }
				ctx.cx:frame({ { "focus", "main.verify_input" } })
			elseif action == "outcome" and value and outcomes[value] then current.outcome = value
			elseif action == "provenance" and value and provenances[value] then current.provenance = value
			elseif action == "relationship" and value and relationships[value] then current.relationship = value
			elseif action == "build" and value and builds[value] then current.build = value
			elseif action == "save" then save(current, saved) end
		elseif action == "bookmark" and bookmarkKey then
			busy = true
			ctx.store(bookmarkKey, if saved.bookmarked then "remove" else "write", { schema = 1, issueId = issue.id }, function(_: any, err: string?)
				if not ctx.alive() then return end
				busy, problem = false, err
				if not err then reload() end
				ctx.render()
			end)
		elseif action == "investigate" and type(issue.number) == "number" then ctx.open("issue", issue.number)
		elseif action == "new" then add(record)
		elseif action == "symptoms" then symptom, record, showSummary = nil, nil, false
		elseif action == "select" then
			local selected = listed()[tonumber(value) or 0]
			if selected then
				if not symptom then symptom, page = selected.fields.symptom, 1 end
				record, showSummary = selected, false
			end
		elseif action == "prev" or action == "next" then
			local index = (if symptom then page else symptomPage) + (if action == "prev" then -1 else 1)
			if index >= 1 and (index - 1) * pageSize < #listed() then
				if symptom then page = index else symptomPage = index end
			end
		elseif action == "summary" and record then showSummary = not showSummary
		elseif action == "copy" and record and showSummary then
			ctx.cx:copy(safeSummary(record))
			message = "已复制脱敏摘要；未向 GitHub 发送。"
		end
		ctx.render()
	end

	local function key(keyInfo: Key): boolean
		local editing = edit
		if not editing or not ctx.alive() or keyInfo.ctrl or keyInfo.meta or keyInfo.alt then return false end
		local value, caret = editing.text, editing.caret
		if keyInfo.name == "enter" then finishEdit()
		elseif keyInfo.name == "escape" then edit = nil
		elseif keyInfo.name == "left" then editing.caret = utf8.offset(value, -1, caret) or 1
		elseif keyInfo.name == "right" then editing.caret = utf8.offset(value, 2, caret) or #value + 1
		elseif keyInfo.name == "home" then editing.caret = 1
		elseif keyInfo.name == "end" then editing.caret = #value + 1
		elseif keyInfo.name == "backspace" or keyInfo.name == "delete" then
			local from = if keyInfo.name == "backspace" then utf8.offset(value, -1, caret) or caret else caret
			local to = if keyInfo.name == "delete" then utf8.offset(value, 2, caret) or #value + 1 else caret
			editing.text, editing.caret = value:sub(1, from - 1) .. value:sub(to), from
		elseif keyInfo.text and keyInfo.text ~= "" then
			local incoming = keyInfo.text:gsub("%c", " ")
			if not utf8.len(incoming) or #value + #incoming > 1024 then return true end
			editing.text, editing.caret = value:sub(1, caret - 1) .. incoming .. value:sub(caret), caret + #incoming
		else return false end
		ctx.render()
		return true
	end

	busy = true
	tern.timer(0, reload)
	return { view = view, event = event, key = key }
end

return verification
