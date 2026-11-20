--!strict

local runtime = require("./runtime")
local github = require("./github")
local sessions = require("./sessions")
local ui = tern.ui

type Repo = runtime.Repo
type Filters = github.Filters
type Row = github.Row
type Prefs = { filters: Filters, selected: number?, position: number? }
type Saved = { checkout: string?, repo: string?, kind: string, filtersByRepo: { [string]: { [string]: Prefs } } }
type Confirm = { number: number, head: string, retained: string? }
type Editor = { key: string, text: string, caret: number, error: string? }
type Listing = {
	rows: { Row }, seen: { [number]: boolean }, cursor: string?, exhausted: boolean, loading: boolean,
	examined: number, uncertain: number, resetAt: string?, error: string?, target: number,
	position: number, restore: number?, restoreAt: number, jump: number?,
}
type State = {
	saved: Saved, repo: Repo?, repos: { Repo }, source: string, generation: number, discovery: boolean,
	scopeError: string?, listing: Listing?, filtersOpen: boolean, field: string?, edit: Editor?,
	lastRefresh: number?,
	opening: number?, progress: string?, taskError: string?, confirm: Confirm?,
}
type Choice = { string }
type Field = { key: string, title: string, choices: { Choice }? }
type Preset = { title: string, filters: Filters }

local ISSUE = "issue"
local PR = "pr"
local PAGE = 20
local states: { Choice } = { { "OPEN", "开放" }, { "CLOSED", "已关闭" } }
local prStates: { Choice } = { { "OPEN", "开放" }, { "MERGED", "已合并" }, { "CLOSED", "关闭未合并" } }
local ciNames: { [string]: string } = { none = "无检查", success = "CI 通过", pending = "CI 进行中", failure = "CI 失败", unknown = "CI 未知" }
local ciChoices: { Choice } = {}
for _, key in { "failure", "pending", "success", "none", "unknown" } do table.insert(ciChoices, { key, ciNames[key] }) end
local yesNo: { Choice } = { { "yes", "是" }, { "no", "否" } }
local numberField: Field = { key = "number", title = "编号" }
local titleField: Field = { key = "title", title = "标题关键词" }
local fields: { [string]: { Field } } = {
	[ISSUE] = {
		{ key = "state", title = "状态", choices = states }, { key = "assignee", title = "负责人" },
		{ key = "author", title = "作者" }, { key = "label", title = "标签" }, titleField, numberField,
	},
	[PR] = {
		{ key = "state", title = "状态", choices = prStates }, { key = "draft", title = "草稿", choices = yesNo },
		{ key = "author", title = "作者" }, { key = "base", title = "目标分支" }, { key = "label", title = "标签" }, titleField, numberField,
		{ key = "requested", title = "请求我审查", choices = yesNo }, { key = "threads", title = "未解决线程", choices = yesNo },
		{ key = "review", title = "审查结论", choices = { { "APPROVED", "已批准" }, { "CHANGES_REQUESTED", "要求修改" },
			{ "REVIEW_REQUIRED", "需要审查" }, { "none", "无结论" } } },
		{ key = "ci", title = "CI", choices = ciChoices },
	},
}
local presets: { [string]: { Preset } } = {
	[ISSUE] = {
		{ title = "全部开放", filters = { state = "OPEN" } },
		{ title = "分配给我", filters = { state = "OPEN", assignee = "@me" } },
		{ title = "我创建的", filters = { state = "OPEN", author = "@me" } },
	},
	[PR] = {
		{ title = "全部开放", filters = { state = "OPEN" } },
		{ title = "我提交的", filters = { state = "OPEN", author = "@me" } },
		{ title = "请求我审查", filters = { state = "OPEN", requested = "yes" } },
		{ title = "未解决线程", filters = { state = "OPEN", threads = "yes" } },
		{ title = "CI 失败", filters = { state = "OPEN", ci = "failure" } },
		{ title = "我的待处理 PR", filters = { state = "OPEN", author = "@me", actionable = "yes" } },
	},
}

local function pref(state: State, repo: Repo): Prefs
	local key = runtime.repoKey(repo)
	local stored = state.saved.filtersByRepo[key]
	if not stored then stored = {}; state.saved.filtersByRepo[key] = stored end
	local kind = state.saved.kind
	if not stored[kind] then stored[kind] = { filters = { state = "OPEN" } } end
	return stored[kind]
end

local function setPosition(prefs: Prefs, list: Listing, index: number)
	list.position = index
	local row = list.rows[index]
	prefs.selected = if row then row.number else nil
	prefs.position = if row then index else nil
end

local function reconcile(prefs: Prefs, list: Listing)
	if list.restore and list.seen[list.restore] then
		for index, row in list.rows do
			if row.number == list.restore then
				list.restore, list.restoreAt = nil, index
				setPosition(prefs, list, index)
				return
			end
		end
	end
	if not list.restore or list.exhausted then
		list.restore = nil
		setPosition(prefs, list, math.min(list.restoreAt, #list.rows))
	else
		list.position = math.min(list.restoreAt, #list.rows)
	end
end

local function scan(state: State, cx: BlockCx, repo: Repo, list: Listing)
	local generation, kind = state.generation, state.saved.kind
	local prefs = pref(state, repo)
	local function alive(): boolean
		return generation == state.generation and runtime.alive(cx.pane)
	end
	local function nextPage()
		if not alive() then return end
		github.list(runtime.exec, repo, kind, prefs.filters, list.cursor, alive, function(page, err)
			if not alive() then return end
			if not page then
				list.error, list.loading = err or "无法读取 GitHub 列表。", false
				cx:render(); return
			end
			list.cursor, list.exhausted = page.nextCursor, not page.nextCursor
			list.examined += page.examined
			list.uncertain += page.uncertain
			list.resetAt = page.resetAt or list.resetAt
			for _, row in page.rows do
				if not list.seen[row.number] then
					list.seen[row.number] = true
					table.insert(list.rows, row)
				end
			end
			if #page.rows > 0 then
				table.sort(list.rows, function(a, b)
					if a.updated ~= b.updated then return a.updated > b.updated end
					return a.number > b.number
				end)
			end
			reconcile(prefs, list)
			local jump = list.jump
			if jump and (jump <= #list.rows or list.exhausted) then
				list.jump, list.restore = nil, nil
				list.restoreAt = math.min(jump, #list.rows)
				setPosition(prefs, list, list.restoreAt)
			end
			list.loading = not list.exhausted and (#list.rows < list.target or list.restore ~= nil)
			cx:render()
			if list.loading then tern.timer(0, nextPage) end
		end)
	end
	list.loading, list.error = true, nil
	nextPage()
end

local function reload(state: State, cx: BlockCx, preserve: boolean)
	local repo = state.repo
	if not repo then return end
	state.lastRefresh = tern.now()
	state.generation += 1
	local prefs = pref(state, repo)
	if not preserve then prefs.selected, prefs.position = nil, nil end
	local position = prefs.position or 1
	local list: Listing = { rows = {}, seen = {}, exhausted = false, loading = false, examined = 0, uncertain = 0,
		position = 0, restore = prefs.selected, restoreAt = position, target = math.ceil(position / PAGE) * PAGE }
	state.listing = list
	scan(state, cx, repo, list)
end

local function chooseRepo(state: State, cx: BlockCx, repo: Repo)
	state.repo, state.saved.repo = repo, runtime.repoKey(repo)
	state.scopeError, state.taskError, state.confirm, state.progress = nil, nil, nil, nil
	state.filtersOpen, state.field, state.edit = false, nil, nil
	reload(state, cx, true)
end

local function discover(state: State, cx: BlockCx, cwd: string)
	state.generation += 1
	state.source, state.repo, state.repos, state.listing = cwd, nil, {}, nil
	state.discovery, state.scopeError, state.taskError, state.confirm, state.progress = true, nil, nil, nil, nil
	local generation = state.generation
	local function alive(): boolean return generation == state.generation and runtime.alive(cx.pane) end
	github.discover(runtime.exec, cwd, alive, function(checkout, repos, err)
		if not alive() then return end
		if checkout ~= state.saved.checkout then state.saved.repo = nil end
		state.saved.checkout = checkout
		state.discovery, state.repos, state.scopeError = false, repos, err
		if not err then
			for _, repo in repos do
				if runtime.repoKey(repo) == state.saved.repo or #repos == 1 then chooseRepo(state, cx, repo); break end
			end
		end
		cx:render()
	end)
end

local function requestMore(state: State, cx: BlockCx, target: number, jump: number?)
	local repo, list = state.repo, state.listing
	if not repo or not list or list.loading or list.exhausted then return end
	list.target = math.max(target, list.target)
	list.jump = jump or list.jump
	local p = pref(state, repo)
	list.restore, list.restoreAt = p.selected, p.position or 1
	scan(state, cx, repo, list)
end

local function choosePosition(state: State, index: number)
	local repo, list = state.repo, state.listing
	if not repo or not list or not list.rows[index] then return end
	list.restore, list.restoreAt = nil, index
	setPosition(pref(state, repo), list, index)
end

local function openRow(state: State, cx: BlockCx, number: number, version: string?, retained: boolean?)
	local repo, checkout, list = state.repo, state.saved.checkout, state.listing
	if not repo or not checkout or not list or state.opening then return end
	if version then
		if not state.confirm or state.confirm.number ~= number then return end
	else
		if not list.seen[number] then return end
		for index, row in list.rows do if row.number == number then choosePosition(state, index); break end end
	end
	state.opening, state.confirm, state.taskError, state.progress = number, nil, nil, "准备任务 #" .. number .. "…"
	sessions.open(runtime.exec, { repo = repo, checkout = checkout, kind = state.saved.kind, number = number, pane = cx.pane,
		version = version, retained = retained },
		function(message)
			if not runtime.alive(cx.pane) then return end
			state.progress = message
			cx:render()
		end, function(message, err, changedHead, retainedHead)
			state.opening = nil
			if not runtime.alive(cx.pane) then return end
			state.progress, state.taskError = message, err
			state.confirm = if changedHead then { number = number, head = changedHead, retained = retainedHead } else nil
			if message and not err then reload(state, cx, true) end
			cx:render()
		end)
end

local function fieldFor(state: State, key: string): Field?
	for _, field in fields[state.saved.kind] do if field.key == key then return field end end
	return nil
end

local function changeFilter(state: State, cx: BlockCx, key: string, value: string?)
	local repo = state.repo
	if not repo or state.opening then return end
	local filters = pref(state, repo).filters :: { [string]: string? }
	filters[key] = value
	state.field, state.edit, state.confirm, state.taskError, state.progress = nil, nil, nil, nil, nil
	reload(state, cx, false)
end

local function setEditor(state: State, cx: BlockCx, key: string, text: string)
	state.edit = { key = key, text = text, caret = #text + 1 }
	cx:frame({ { "focus", "main.editor.input" } })
end

local function dismissEditor(state: State, cx: BlockCx)
	state.edit = nil
	local clear: { any } = { "focus", tern.json.null }
	cx:frame({ clear })
end

local function submitEditor(state: State, cx: BlockCx)
	local edit = state.edit
	if not edit or state.opening then return end
	local value = runtime.trim(edit.text)
	if edit.key == "checkout" then
		if not value:match("^/") then edit.error = "请输入本机仓库的绝对路径。"; return end
		dismissEditor(state, cx)
		discover(state, cx, value)
		return
	end
	if edit.key == "number" and value ~= "" then
		local number = tonumber(value)
		if not value:match("^%d+$") or not number or number < 1 or number > 2147483647 then
			edit.error = "请输入 1–2147483647 的整数。"; return
		end
		value = tostring(number)
	end
	local key = edit.key
	dismissEditor(state, cx)
	changeFilter(state, cx, key, if value == "" then nil else value)
end

local function setKind(state: State, cx: BlockCx, kind: string)
	if kind == state.saved.kind or state.opening then return end
	state.saved.kind = kind
	state.field, state.progress, state.taskError, state.confirm = nil, nil, nil, nil
	if state.edit then dismissEditor(state, cx) end
	reload(state, cx, true)
end

local function utf16Length(text: string, caret: number): number
	local len = 0
	for index, code in utf8.codes(text) do
		if index >= caret then break end
		len += if code > 0xFFFF then 2 else 1
	end
	return len
end

local function editorKey(edit: Editor, key: Key): boolean
	if key.ctrl or key.meta or key.alt then return false end
	local text, caret = edit.text, edit.caret
	if key.name == "left" then
		edit.caret = utf8.offset(text, -1, caret) or 1
	elseif key.name == "right" then
		edit.caret = utf8.offset(text, 2, caret) or #text + 1
	elseif key.name == "home" then
		edit.caret = 1
	elseif key.name == "end" then
		edit.caret = #text + 1
	elseif key.name == "backspace" or key.name == "delete" then
		local from = if key.name == "backspace" then utf8.offset(text, -1, caret) or caret else caret
		local to = if key.name == "delete" then utf8.offset(text, 2, caret) or #text + 1 else caret
		edit.text, edit.caret = text:sub(1, from - 1) .. text:sub(to), from
	elseif key.text and key.text ~= "" then
		local incoming = key.text:gsub("[%c]", " ")
		if #text + #incoming > 4096 or not utf8.len(incoming) then return false end
		edit.text, edit.caret = text:sub(1, caret - 1) .. incoming .. text:sub(caret), caret + #incoming
	else return false end
	edit.error = nil
	return true
end

local function pageAt(list: Listing): number
	return math.ceil(math.max(1, list.position) / PAGE)
end

local function navigation(state: State, cx: BlockCx, offset: number)
	local list = state.listing
	if not list then return end
	if #list.rows == 0 then return end
	local target = math.max(1, list.position + offset)
	if target <= #list.rows then choosePosition(state, target)
	elseif list.exhausted then choosePosition(state, #list.rows)
	else requestMore(state, cx, math.ceil(target / PAGE) * PAGE, target) end
end

local function button(label: string, action: string, active: boolean?, disabled: boolean?): Node
	return ui.button(label, { key = action, size = "sm", on = active, disabled = disabled, actions = { click = action } })
end

local function text(label: string, tone: string?): Node
	return ui.text({ ui.span(label, tone or "muted") })
end

local function lines(parent: { Node }, nodes: { Node }, width: number)
	for start = 1, #nodes, width do
		local row = {}
		for index = start, math.min(start + width - 1, #nodes) do table.insert(row, nodes[index]) end
		table.insert(parent, ui.row(row))
	end
end

local function fieldValue(field: Field, value: string): string
	if field.choices then
		for _, choice in field.choices do if choice[1] == value then return choice[2] end end
	end
	return value
end

local function editorView(edit: Editor, title: string): Node
	local items = { text(title, "strong"), ui.node("input", { key = "input", text = edit.text,
		cursor = utf16Length(edit.text, edit.caret), placeholder = if edit.key == "checkout" then "/path/to/repo" else "输入筛选值" }),
		ui.row({ button("应用 ↵", "apply"), button("取消", "dismiss") }) }
	if edit.error then table.insert(items, text(edit.error, "error")) end
	return ui.card("", items, { key = "editor" })
end

local function view(state: State, cx: BlockCx): BlockView
	local repo, list, edit = state.repo, state.listing, state.edit
	local main: { Node } = {}
	local dock: { Node } = {}
	local busy = state.opening ~= nil
	local heading = if repo then repo.owner .. "/" .. repo.name else "选择 GitHub 仓库"
	table.insert(main, ui.text({ ui.span(heading, "strong"), ui.span(if repo then "  " .. repo.host else "", "muted") }))
	table.insert(main, text(state.saved.checkout or state.source, "muted code"))
	table.insert(main, ui.row({ button("本地 checkout…", "checkout", false, busy),
		button(if repo then "刷新" else "重新探测", "refresh", false, busy or state.discovery) }))
	if state.discovery then table.insert(main, ui.progress(nil, "正在识别 Git remote 和 fork 上游…")) end
	if state.scopeError then table.insert(main, text(state.scopeError, "error")) end
	if #state.repos > 1 or (not repo and #state.repos > 0 and not state.scopeError) then
		local choices = {}
		for index, candidate in state.repos do
			local label = candidate.owner .. "/" .. candidate.name .. (if candidate.host ~= "github.com" then " @ " .. candidate.host else "")
			table.insert(choices, button(label, "repo=" .. index, repo == candidate, busy))
		end
		lines(main, choices, if cx.cols >= 82 then 2 else 1)
	end
	if edit and edit.key == "checkout" then table.insert(main, editorView(edit, "选择本地 checkout")) end
	if not repo or not list then return { main = ui.col(main) } end
	local kind = state.saved.kind
	local filters = pref(state, repo).filters
	table.insert(main, ui.row({ button("Issues", "kind=issue", kind == ISSUE, busy), button("PRs", "kind=pr", kind == PR, busy),
		button("筛选…", "filters", state.filtersOpen, busy), button("清空", "clear", false, busy or next(filters) == nil) }))
	local shortcuts = {}
	for index, preset in presets[kind] do table.insert(shortcuts, button(preset.title, "preset=" .. index, false, busy)) end
	lines(main, shortcuts, if cx.cols >= 100 then 6 elseif cx.cols >= 65 then 3 else 2)
	local chips = {}
	for _, field in fields[kind] do
		local value = filters[field.key]
		if value then table.insert(chips, button(field.title .. "：" .. fieldValue(field, value) .. " ×", "remove=" .. field.key, true, busy)) end
	end
	if filters.actionable then table.insert(chips, button("未解决线程或 CI 失败 ×", "remove=actionable", true, busy)) end
	if #chips == 0 then table.insert(main, text("生效条件：无")) else lines(main, chips, if cx.cols >= 100 then 3 else 2) end
	if state.filtersOpen then
		local controls = {}
		for _, field in fields[kind] do table.insert(controls, button(field.title, "field=" .. field.key, state.field == field.key, busy)) end
		lines(main, controls, if cx.cols >= 100 then 6 elseif cx.cols >= 60 then 4 else 2)
	end
	local field = if state.field then fieldFor(state, state.field) else nil
	if field and field.choices then
		local options = { button("不限", "option=", not filters[field.key], busy) }
		for _, choice in field.choices do table.insert(options, button(choice[2], "option=" .. choice[1], filters[field.key] == choice[1], busy)) end
		lines(main, options, if cx.cols >= 82 then 4 else 2)
	elseif edit and edit.key ~= "checkout" then
		table.insert(main, editorView(edit, if field then field.title else "筛选"))
	end
	local page = pageAt(list)
	local first, last = (page - 1) * PAGE + 1, math.min(page * PAGE, #list.rows)
	local rows: { Node } = {}
	for index = first, last do
		local row = list.rows[index]
		local id = "n" .. row.number
		local details = { if row.state == "OPEN" then "开放" elseif row.state == "MERGED" then "已合并" else "已关闭" }
		if row.draft then table.insert(details, "草稿") end
		if row.threads then table.insert(details, "未解决线程") end
		if row.requested then table.insert(details, "请求我审查") end
		if kind == PR then table.insert(details, ciNames[row.ci]) end
		table.insert(rows, ui.node("item", { key = id, label = { ui.span("#" .. row.number .. "  ", "code muted"), ui.span(row.title) },
			detail = table.concat(details, " · "), value = if cx.cols >= 88 then row.author else nil,
			actions = { click = "open=" .. state.generation .. ":" .. row.number },
			tone = if row.ci == "failure" then "error" elseif row.threads then "warning" else nil }))
	end
	local selected = list.rows[list.position]
	if #rows > 0 then
		table.insert(main, ui.node("list", { key = "results", selected = if selected then "main.results.n" .. selected.number else nil,
			max = { lines = math.clamp(cx.rows - 12, 4, 15) }, filter = filters.title }, rows))
	end
	if list.loading then
		table.insert(main, ui.progress(nil, "正在扫描 GitHub… 已检查 " .. list.examined .. " 项，找到 " .. #list.rows .. " 项"))
	elseif list.error then
		table.insert(main, text((if list.examined > 0 then "部分结果：" else "查询失败：") .. list.error, "error"))
		if list.resetAt and list.error:find("限流", 1, true) then table.insert(main, text("GitHub 查询额度重置：" .. list.resetAt)) end
		table.insert(main, button("重试未完成的查询", "retry"))
	elseif list.exhausted and #rows == 0 and list.uncertain == 0 then
		table.insert(main, text("没有匹配项。"))
	end
	if list.uncertain > 0 then table.insert(main, text(list.uncertain .. " 项的 CI 证据未知，无法确认是否匹配。", "warning")) end
	if list.examined > 0 and #rows > 0 then
		table.insert(main, ui.row({ button("上一页", "prev", false, page <= 1), button("下一页", "next", false, list.loading or (list.exhausted and last == #list.rows)),
			text(first .. "–" .. last .. " / " .. #list.rows .. (if list.exhausted then "" else " 已找到 · 尚未扫完")) }))
	end
	if state.progress then table.insert(dock, text(state.progress, if busy then "accent" else "muted")) end
	if state.taskError then table.insert(dock, text(state.taskError, "warning")) end
	if state.confirm then
		local choices = {}
		if state.confirm.retained then table.insert(choices, button("保留并打开旧版本 " .. state.confirm.retained:sub(1, 8), "previous")) end
		table.insert(choices, button("打开新版本 " .. state.confirm.head:sub(1, 8), "new_version"))
		table.insert(dock, ui.row(choices))
	elseif not busy then
		table.insert(dock, text("↑↓ 选择 · Enter / 单击打开 · Tab 切换 · / 标题 · R 刷新"))
	end
	return { main = ui.col(main), dock = ui.col(dock) }
end

local block: BlockDef<State> = {
	font = "sans",
	init = function(cx, args, saved)
		local prefs: Saved = if type(saved) == "table" and type(saved.filtersByRepo) == "table" then saved
			else { kind = ISSUE, filtersByRepo = {} }
		if prefs.kind ~= PR then prefs.kind = ISSUE end
		local source = prefs.checkout or args[1] or cx.cwd or ""
		local state: State = { saved = prefs, repos = {}, source = source, generation = 0, discovery = false, filtersOpen = false }
		if source ~= "" then discover(state, cx, source) else state.scopeError = "请选择本地 Git checkout。" end
		return state
	end,
	save = function(state) return state.saved end,
	title = function(state) local repo = state.repo; return if repo then "TernMate · " .. repo.owner .. "/" .. repo.name else "TernMate" end,
	view = view,
	key = function(state, key, cx)
		local edit = state.edit
		if edit then
			if key.name == "enter" then submitEditor(state, cx); return true end
			if key.name == "escape" then dismissEditor(state, cx); state.field = nil; return true end
			return editorKey(edit, key)
		end
		if key.meta or key.ctrl or key.alt then return false end
		local list = state.listing
		if key.name == "r" and not state.opening then
			if state.repo then reload(state, cx, true) elseif state.source ~= "" then discover(state, cx, state.source) end
		elseif key.name == "tab" then setKind(state, cx, if state.saved.kind == ISSUE then PR else ISSUE)
		elseif key.text == "/" and state.repo and not state.opening then
			state.filtersOpen, state.field = true, "title"
			setEditor(state, cx, "title", pref(state, state.repo).filters.title or "")
		elseif key.name == "up" then navigation(state, cx, -1)
		elseif key.name == "down" then navigation(state, cx, 1)
		elseif key.name == "page_up" then navigation(state, cx, -PAGE)
		elseif key.name == "page_down" then navigation(state, cx, PAGE)
		elseif key.name == "enter" and list and list.rows[list.position] and not state.confirm then openRow(state, cx, list.rows[list.position].number)
		else return false end
		return true
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" and state.edit and ev.id == "main.editor.input" then
			cx:frame({ { "focus", ev.id } }); return
		end
		if ev.ev ~= "action" then return end
		local action, value = ev.act, ev.value
		if state.opening then return end
		local repo, list = state.repo, state.listing
		if action == "return_to_list" then
			local lastRefresh = state.lastRefresh or 0
			if list and not list.loading and not list.error and not state.edit and tern.now() - lastRefresh >= 1500 then
				reload(state, cx, true)
			end
			return
		end
		if action == "checkout" then setEditor(state, cx, "checkout", state.saved.checkout or state.source); return end
		if action == "apply" then submitEditor(state, cx); return end
		if action == "dismiss" then dismissEditor(state, cx); state.field = nil; return end
		if action == "repo" then
			local candidate = state.repos[tonumber(value) or 0]
			if candidate and candidate ~= repo then chooseRepo(state, cx, candidate) end
			return
		end
		if action == "refresh" then
			if repo then reload(state, cx, true) elseif state.source ~= "" then discover(state, cx, state.source) end
			return
		end
		if not repo or not list then return end
		if action == "open" then
			if type(value) ~= "string" then return end
			local generation, number = value:match("^(%d+):(%d+)$")
			if tonumber(generation) == state.generation and number then openRow(state, cx, assert(tonumber(number))) end
		elseif action == "new_version" or action == "previous" then
			local change = state.confirm
			if not change then return end
			if action == "new_version" then openRow(state, cx, change.number, change.head)
			elseif change.retained then openRow(state, cx, change.number, change.retained, true) end
		elseif action == "prev" or action == "next" then
			local nextPage = pageAt(list) + (if action == "prev" then -1 else 1)
			local first = (nextPage - 1) * PAGE + 1
			if nextPage > 0 and first <= #list.rows then choosePosition(state, first)
			elseif nextPage > 0 then requestMore(state, cx, nextPage * PAGE, first) end
		elseif action == "retry" then requestMore(state, cx, list.target)
		elseif action == "kind" and (value == ISSUE or value == PR) then setKind(state, cx, value)
		elseif action == "filters" then
			state.filtersOpen = not state.filtersOpen
			if not state.filtersOpen then state.field = nil; dismissEditor(state, cx) end
		elseif action == "remove" and (value == "actionable" or fieldFor(state, value)) then
			changeFilter(state, cx, value, nil)
		elseif action == "clear" or action == "preset" then
			local preset = presets[state.saved.kind][tonumber(value) or 0]
			if action == "preset" and not preset then return end
			pref(state, repo).filters = if preset then table.clone(preset.filters) else {}
			state.field, state.confirm, state.taskError, state.progress = nil, nil, nil, nil
			dismissEditor(state, cx)
			reload(state, cx, false)
		elseif action == "field" then
			local field = fieldFor(state, value)
			if not field then return end
			state.field = field.key
			if field.choices then dismissEditor(state, cx)
			else setEditor(state, cx, field.key, pref(state, repo).filters[field.key] or "") end
		elseif action == "option" and state.field then
			local field = fieldFor(state, state.field)
			if not field or not field.choices then return end
			if value == "" or value == nil then changeFilter(state, cx, field.key, nil); return end
			for _, choice in field.choices do
				if choice[1] == value then changeFilter(state, cx, field.key, value); return end
			end
		end
	end,
}

tern.block.define("workbench", block)
