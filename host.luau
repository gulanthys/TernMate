--!strict

local runtime = require("./runtime")
local github = require("./github")
local sessions = require("./sessions")
local maintenance = require("./maintenance_data")
local inbox = require("./inbox")
local batch = require("./batch")
local issueSubmit = require("./issue_submit")
local ui = tern.ui

type Repo = runtime.Repo
type Filters = github.Filters
type Row = github.Row
type Identity = maintenance.Identity
type Prefs = { filters: Filters, selected: number?, position: number?, repoId: string?, viewerId: string? }
type Saved = { checkout: string?, repo: string?, kind: string, filtersByRepo: { [string]: { [string]: Prefs } }, maintenanceByRepo: { [string]: any }? }
type Confirm = { kind: string, number: number, head: string, retained: string? }
type Editor = { key: string, text: string, caret: number, error: string? }
type Listing = { data: {rows: {Row}, uncertain: number}, position: number }
type Scope = { identity: Identity, snapshot: any?, checked: number?, loading: boolean?, hydrated: boolean?,
	links: {[number]: string}?,
	timer: TimerHandle?, errors: number?, error: string? }
type ScopeCallback = (Scope?, string?) -> ()
type State = {
	saved: Saved, repo: Repo?, repos: { Repo }, source: string, generation: number, discovery: boolean,
	scopeError: string?, listing: Listing?, filtersOpen: boolean, field: string?, edit: Editor?,
	read: Scope?, identityWait: { ScopeCallback }?, verifying: boolean?, listError: string?,
	opening: number?, progress: string?, taskError: string?, confirm: Confirm?,
	panel: any?, mode: string?,
}
type Choice = { string }
type Field = { key: string, title: string, choices: { Choice }? }
type Preset = { title: string, filters: Filters }

local ISSUE = "issue"
local PR = "pr"
local PAGE = 20
local SYNC_MS = 300_000
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

local function fresh(at: number?): boolean
	return at ~= nil and tern.now() - at < SYNC_MS
end

local function sameIdentity(a: Identity, b: Identity): boolean
	return a.repoId == b.repoId and a.viewerId == b.viewerId and a.viewer == b.viewer
end

local function invalidateScope(state: State, err: string?)
	local previous = state.read
	if previous and previous.timer then previous.timer:cancel() end
	state.read, state.listing, state.listError = nil, nil, err
	if previous and state.panel and state.panel.scope == previous then
		state.panel, state.mode = nil, nil
	end
end

-- Coalesce only concurrent read-side identity checks. Actions use their own live checks.
local function readScope(state: State, cx: BlockCx, repo: Repo, done: ScopeCallback)
	local pending = state.identityWait
	if pending then table.insert(pending, done); return end
	local waiters = { done }
	state.identityWait = waiters
	maintenance.identity(repo, function(info, err)
		if state.identityWait ~= waiters or state.repo ~= repo or not runtime.alive(cx.pane) then return end
		state.identityWait = nil
		local scope = state.read
		if not info then
			invalidateScope(state, err)
			scope = nil
		elseif not scope or not sameIdentity(scope.identity, info) then
			invalidateScope(state, "仓库或登录账号已变化；请刷新任务列表。")
			scope = { identity = info }
			state.read = scope
		end
		for _, callback in waiters do callback(scope, err) end
		cx:render()
	end)
end

-- GitHub numbers are only repository-local. Join on node ID so that a
-- cross-repository closing reference cannot mark an unrelated local Issue.
local function install(scope: Scope, snapshot: any)
	if scope.snapshot == snapshot and scope.links then return end
	local numbers: {[string]: number} = {}
	for _, issue in snapshot.issues do numbers[issue.id] = issue.number end
	local linked: {[number]: {string}} = {}
	for _, pr in snapshot.prs do
		local refs = pr.closingIssuesReferences
		if not refs or not refs.nodes then continue end
		for _, issue in refs.nodes do
			local number = numbers[issue.id]
			if not number then continue end
			local badges = linked[number] or {}
			linked[number] = badges
			local status = if pr.state == "MERGED" then "已合并" elseif pr.state == "OPEN" then "开放" else "已关闭"
			table.insert(badges, "PR #" .. pr.number .. " " .. status)
		end
	end
	local labels: {[number]: string} = {}
	for number, badges in linked do labels[number] = table.concat(badges, "、") end
	scope.snapshot, scope.links = snapshot, labels
end

local function project(state: State, scope: Scope, preserve: boolean)
	local repo = state.repo
	if not repo or not scope.snapshot then return end
	local prefs = pref(state, repo)
	local rows, uncertain = github.project(scope.snapshot, state.saved.kind, prefs.filters)
	local same = preserve and prefs.repoId == scope.identity.repoId and prefs.viewerId == scope.identity.viewerId
	local position = math.min(if same then prefs.position or 1 else 1, #rows)
	if same and prefs.selected then
		for i, row in rows do if row.number == prefs.selected then position = i; break end end
	end
	position = if #rows > 0 then math.max(1, position) else 0
	if scope.snapshot.complete then
		prefs.selected = if rows[position] then rows[position].number else nil
		prefs.position, prefs.repoId, prefs.viewerId = position, scope.identity.repoId, scope.identity.viewerId
	end
	state.listing = {data = {rows = rows, uncertain = uncertain}, position = position}
	state.generation += 1
end

local function notify(state: State, cx: BlockCx, scope: Scope)
	local panel = state.panel
	if panel and panel.scope == scope and panel.observe then panel.observe(scope.snapshot, scope.error) end
	cx:render()
end

local function synchronize(state: State, cx: BlockCx, repo: Repo, scope: Scope)
	if scope.loading then return end
	scope.loading = true
	if scope.timer then scope.timer:cancel(); scope.timer = nil end
	local function alive(): boolean return state.read == scope and state.repo == repo and runtime.alive(cx.pane) end
	local function schedule(delay: number)
		scope.timer = tern.timer(delay, function()
			scope.timer = nil
			if alive() then synchronize(state, cx, repo, scope) end
		end)
	end
	local function sync()
		maintenance.sync(repo, scope.identity, if scope.snapshot and scope.snapshot.complete then scope.snapshot else nil, alive, function(snapshot, err, changedIdentity)
			if not alive() then return end
			scope.loading = false
			if changedIdentity then invalidateScope(state, err); cx:render(); return end
			scope.error = err
			if snapshot and snapshot.complete then
				local changed = scope.snapshot ~= snapshot
				install(scope, snapshot)
				scope.checked, scope.errors = tern.now(), 0
				if changed or not state.listing then project(state, scope, true) end
			else
				scope.errors = math.min(3, (scope.errors or 0) + 1)
				if not scope.error then scope.error = "后台扫描未完成。" end
			end
			notify(state, cx, scope)
			schedule(SYNC_MS * 2 ^ (scope.errors or 0))
		end, function(partial)
			if not alive() or (scope.snapshot and scope.snapshot.complete) then return end
			install(scope, table.clone(partial))
			project(state, scope, true)
			notify(state, cx, scope)
		end)
	end
	if scope.hydrated then sync(); return end
	maintenance.cached(repo, scope.identity, function(snapshot, cacheErr)
		if not alive() then return end
		scope.hydrated = true
		scope.error = cacheErr
		if snapshot then
			install(scope, snapshot)
			project(state, scope, true)
			local age = if type(snapshot.checkedEpoch) == "number" then (os.time() - snapshot.checkedEpoch) * 1000 else nil
			if age and age >= 0 and age < SYNC_MS and not cacheErr then
				scope.loading, scope.checked = false, tern.now() - age
				notify(state, cx, scope)
				schedule(SYNC_MS - age)
				return
			end
			notify(state, cx, scope)
		end
		sync()
	end)
end

local function reload(state: State, cx: BlockCx, preserve: boolean, force: boolean?)
	local repo = state.repo
	if not repo then return end
	local scope = state.read
	if scope then
		if force then synchronize(state, cx, repo, scope) else project(state, scope, preserve) end
		return
	end
	if state.verifying then return end
	state.verifying = true
	readScope(state, cx, repo, function(current, err)
		state.verifying, state.listError = false, err
		if current then synchronize(state, cx, repo, current) end
	end)
end

local function chooseRepo(state: State, cx: BlockCx, repo: Repo)
	state.panel, state.mode = nil, nil
	invalidateScope(state, nil)
	state.identityWait, state.verifying = nil, nil
	state.repo, state.saved.repo = repo, runtime.repoKey(repo)
	state.scopeError, state.taskError, state.confirm, state.progress = nil, nil, nil, nil
	state.filtersOpen, state.field, state.edit = false, nil, nil
	reload(state, cx, true)
end

local function discover(state: State, cx: BlockCx, cwd: string)
	if state.discovery then return end
	state.panel, state.mode = nil, nil
	invalidateScope(state, nil)
	state.identityWait, state.verifying = nil, nil
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


local function choosePosition(state: State, index: number)
	local list = state.listing
	local row = list and list.data.rows[index]
	if not list or not row then return end
	list.position = index
	if state.repo then
		local prefs = pref(state, state.repo)
		prefs.selected, prefs.position = row.number, index
	end
end

local function openTask(state: State, cx: BlockCx, kind: string, number: number, version: string?, retained: boolean?)
	local repo, checkout = state.repo, state.saved.checkout
	if not repo or not checkout or state.opening or (kind ~= ISSUE and kind ~= PR) then return end
	state.opening, state.confirm, state.taskError, state.progress = number, nil, nil, "准备任务 #" .. number .. "…"
	sessions.open(runtime.exec, { repo = repo, checkout = checkout, kind = kind, number = number, pane = cx.pane,
		version = version, retained = retained },
		function(message)
			if not runtime.alive(cx.pane) then return end
			state.progress = message
			cx:render()
		end, function(message, err, changedHead, retainedHead)
			state.opening = nil
			if not runtime.alive(cx.pane) then return end
			state.progress, state.taskError = message, err
			state.confirm = if changedHead then { kind = kind, number = number, head = changedHead, retained = retainedHead } else nil
			cx:render()
		end)
end

local function openRow(state: State, cx: BlockCx, number: number)
	local list = state.listing
	if state.verifying or not list then return end
	for index, row in list.data.rows do
		if row.number == number then choosePosition(state, index); openTask(state, cx, state.saved.kind, number); return end
	end
end


local function setMode(state: State, cx: BlockCx, mode: string?)
	local repo, checkout = state.repo, state.saved.checkout
	if not repo or not checkout or state.opening then return end
	state.mode, state.panel, state.confirm, state.progress, state.taskError = mode, nil, nil, nil, nil
	if not mode then return end
	if state.edit then
		state.edit = nil
		local clear: {any} = { "focus", tern.json.null }
		cx:frame({ clear })
	end
	if not state.saved.maintenanceByRepo then state.saved.maintenanceByRepo = {} end
	local saved = state.saved.maintenanceByRepo :: { [string]: any }
	local repoKey = runtime.repoKey(repo)
	if not saved[repoKey] then saved[repoKey] = {} end
	-- Install the panel before constructing the controller; new() may start I/O.
	local panel: any = {}
	state.panel = panel
	local pinned: Identity? = nil
	local function alive(): boolean return state.panel == panel and runtime.alive(cx.pane) end
	local function pin(info: Identity?, err: string?, done: (any, string?) -> ())
		if not info then done(nil, err); return end
		if pinned and not sameIdentity(pinned, info) then
			done(nil, "仓库身份或登录账号已变化；请退出并重新进入。"); return
		end
		pinned = pinned or info
		done(info, nil)
	end
	local function identity(done: (any, string?) -> ())
		maintenance.identity(repo, function(info, err)
			local scope = state.read
			if alive() and scope and (not info or not sameIdentity(scope.identity, info)) then
				invalidateScope(state, err or "仓库或登录账号已变化；请刷新任务列表。")
			end
			pin(info, err, done)
		end)
	end
	local ctx: any = {
		repo = repo, checkout = checkout, cx = cx, alive = alive, prefs = saved[repoKey],
		issueBadges = function() return sessions.issueBadges(repo, checkout) end,
		render = function() if alive() then cx:render() end end,
		open = function(kind: string, number: number) if alive() then openTask(state, cx, kind, number) end end,
		identity = identity,
		receiptExcluded = function(issue: any): string?
			local issuePrefs = state.saved.filtersByRepo[repoKey]
			local filters: Filters = if issuePrefs and issuePrefs[ISSUE] then issuePrefs[ISSUE].filters else { state = "OPEN" }
			if state.saved.kind == PR then return "当前列表显示 PR。" end
			if filters.number and tonumber(filters.number) ~= issue.number then return "当前编号筛选不包含新 Issue。" end
			if filters.state and type(issue.state) == "string" and filters.state ~= issue.state:upper() then return "当前状态筛选不包含新 Issue。" end
			if filters.title and type(issue.title) == "string" and not issue.title:lower():find(filters.title:lower(), 1, true) then
				return "当前标题筛选不包含新 Issue。"
			end
			return nil
		end,
	}
	local function readPanelScope(done: ScopeCallback)
		local function attach(scope: Scope?, err: string?)
			if not alive() then return end
			if not scope then done(nil, err); return end
			pin(scope.identity, err, function(info, pinErr)
				if info then panel.scope = scope; done(scope, nil) else done(nil, pinErr) end
			end)
		end
		if state.read then attach(state.read, nil) else readScope(state, cx, repo, attach) end
	end
	ctx.fresh = function(snapshot: any): boolean
		local scope = state.read
		return scope ~= nil and panel.scope == scope and scope.snapshot == snapshot and not scope.loading and not scope.error and fresh(scope.checked)
	end
	ctx.fetch = function(force: boolean, done: (any, string?) -> (), progress: ((any) -> ())?)
		readPanelScope(function(scope, err)
			if not scope then done(nil, err); return end
			local observed, lastError, delivered = nil :: any, nil :: string?, false
			panel.observe = function(snapshot: any, scanError: string?)
				if not alive() then return end
				if snapshot and not snapshot.complete and scope.loading then
					if progress then progress(snapshot) end
				elseif not delivered or snapshot ~= observed or scanError ~= lastError then
					delivered, observed, lastError = true, snapshot, scanError
					done(snapshot, scanError)
				end
			end
			if force or not scope.hydrated then synchronize(state, cx, repo, scope) end
			if (not force and scope.snapshot) or not scope.loading then panel.observe(scope.snapshot, scope.error) end
		end)
	end
	ctx.store = function(key: string, storeMode: string, value: any, done: (any, string?) -> ())
		if pinned then maintenance.store(repo, pinned, key, storeMode, value, done)
		elseif mode == "batch" and storeMode == "read" then
			readPanelScope(function(scope, err)
				if scope then maintenance.store(repo, scope.identity, key, storeMode, value, done) else done(nil, err) end
			end)
		else
			identity(function(info, err)
				if info then maintenance.store(repo, info, key, storeMode, value, done) else done(nil, err) end
			end)
		end
	end
	panel.controller = if mode == "batch" then batch.new(ctx) elseif mode == "submit" then issueSubmit.new(ctx) else inbox.new(ctx)
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
	local data = list.data
	if #data.rows == 0 then return end
	local target = math.max(1, list.position + offset)
	if target <= #data.rows then choosePosition(state, target)
	else choosePosition(state, #data.rows) end
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

local function taskDock(state: State, busy: boolean): { Node }
	local dock: { Node } = {}
	if state.progress then table.insert(dock, text(state.progress, if busy then "accent" else "muted")) end
	if state.taskError then table.insert(dock, text(state.taskError, "warning")) end
	if state.confirm then
		local choices = {}
		if state.confirm.retained then table.insert(choices, button("保留并打开旧版本 " .. state.confirm.retained:sub(1, 8), "previous")) end
		table.insert(choices, button("打开新版本 " .. state.confirm.head:sub(1, 8), "new_version"))
		table.insert(dock, ui.row(choices))
	end
	return dock
end

local function view(state: State, cx: BlockCx): BlockView
	local repo, list, edit = state.repo, state.listing, state.edit
	local main: { Node } = {}
	local busy = state.opening ~= nil
	local heading = if repo then repo.owner .. "/" .. repo.name else "选择 GitHub 仓库"
	table.insert(main, ui.text({ ui.span(heading, "strong"), ui.span(if repo then "  " .. repo.host else "", "muted") }))
	table.insert(main, text(state.saved.checkout or state.source, "muted code"))
	table.insert(main, ui.row({ button("本地 checkout…", "checkout", false, busy),
		button(if repo then "刷新" else "重新探测", "refresh", false, busy or state.discovery) }))
	if state.discovery then table.insert(main, ui.progress(nil, "正在识别 Git remote 和 fork 上游…")) end
	if state.scopeError then
		table.insert(main, text(state.scopeError, "error"))
		if not state.saved.checkout then
			table.insert(main, text("请选择「本地 checkout…」，或从工作目录在目标仓库内的 Tern 面板打开。omp --cwd 不会设置 Tern 面板的目录。"))
		end
	end
	if #state.repos > 1 or (not repo and #state.repos > 0 and not state.scopeError) then
		local choices = {}
		for index, candidate in state.repos do
			local label = candidate.owner .. "/" .. candidate.name .. (if candidate.host ~= "github.com" then " @ " .. candidate.host else "")
			table.insert(choices, button(label, "repo=" .. index, repo == candidate, busy))
		end
		lines(main, choices, if cx.cols >= 82 then 2 else 1)
	end
	local panel = state.panel
	if repo then
		lines(main, {
			button("任务浏览", "mode=browse", not state.mode, busy),
			button("社区收件箱", "mode=inbox", state.mode == "inbox", busy),
			button("批次回顾", "mode=batch", state.mode == "batch", busy),
			button("新建 Issue", "mode=submit", state.mode == "submit", busy),
		}, if cx.cols >= 75 then 4 else 2)
	end
	if panel then
		for _, node in panel.controller.view() do table.insert(main, node) end
		return { main = ui.col(main), dock = ui.col(taskDock(state, busy)) }
	end
	if edit and edit.key == "checkout" then table.insert(main, editorView(edit, "选择本地 checkout")) end
	if not repo then return { main = ui.col(main) } end
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
	if filters.actionable then table.insert(chips, button("合并冲突、未解决线程或 CI 失败 ×", "remove=actionable", true, busy)) end
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
	if state.verifying then
		table.insert(main, ui.progress(nil, if list then "正在核对账号；下方为上次列表…" else "正在核对 GitHub 仓库和账号…"))
	elseif state.listError then
		table.insert(main, text(state.listError, "error"))
	end
	local scope = state.read
	if not list then
		if scope then table.insert(main, text(scope.error or "正在读取本地缓存并同步…", if scope.error then "error" else "muted")) end
		return { main = ui.col(main), dock = ui.col(taskDock(state, busy)) }
	end
	local data = list.data
	local current = scope ~= nil and not scope.loading and not scope.error and fresh(scope.checked)
	local page = pageAt(list)
	local first, last = (page - 1) * PAGE + 1, math.min(page * PAGE, #data.rows)
	local rows: { Node } = {}
	local badge = if kind == ISSUE and state.saved.checkout then sessions.issueBadges(repo, state.saved.checkout) else nil
	for index = first, last do
		local row = data.rows[index]
		local id = "n" .. row.number
		local details = { if row.state == "OPEN" then "开放" elseif row.state == "MERGED" then "已合并" else "已关闭" }
		if row.mergeable == "CONFLICTING" then table.insert(details, "合并冲突")
		elseif row.mergeable == "UNKNOWN" then table.insert(details, "可合并性未知") end
		local status = if badge then badge(row.number) else ""
		if status ~= "" then table.insert(details, 1, status) end
		local links = if kind == ISSUE and scope and scope.links then scope.links[row.number] else nil
		if links then table.insert(details, links) end
		if row.draft then table.insert(details, "草稿") end
		if row.threads then table.insert(details, "未解决线程") end
		if row.requested then table.insert(details, "请求我审查") end
		if kind == PR then table.insert(details, ciNames[row.ci]) end
		table.insert(rows, ui.node("item", { key = id, label = { ui.span("#" .. row.number .. "  ", "code muted"), ui.span(row.title) },
			detail = table.concat(details, " · "), value = if cx.cols >= 88 then row.author else nil,
			actions = { click = "open=" .. state.generation .. ":" .. row.number },
			tone = if row.ci == "failure" or row.mergeable == "CONFLICTING" then "error" elseif row.threads then "warning" else nil }))
	end
	local selected = data.rows[list.position]
	if #rows > 0 then
		table.insert(main, ui.node("list", { key = "results", selected = if selected then "main.results.n" .. selected.number else nil,
			max = { lines = math.clamp(cx.rows - 12, 4, 15) }, filter = filters.title }, rows))
	end
	if scope and scope.error then
		table.insert(main, text("本地镜像 · 同步提示：" .. scope.error, "warning"))
	elseif not current then
		table.insert(main, text("本地镜像 · 后台同步中或上次观察已过期；仅显示已读数据。", "muted"))
	elseif #rows == 0 and data.uncertain == 0 then
		table.insert(main, text("没有匹配项。"))
	else
		table.insert(main, text("本地镜像 · 每 5 分钟后台核对", "muted"))
	end
	if data.uncertain > 0 then table.insert(main, text(data.uncertain .. " 项缺少筛选证据，无法确认是否匹配。", "warning")) end
	if #rows > 0 then
		table.insert(main, ui.row({ button("上一页", "prev", false, page <= 1),
			button("下一页", "next", false, last == #data.rows),
			text(first .. "–" .. last .. " / " .. #data.rows
				.. (if current and data.uncertain == 0 then "" else " 已找到 · 覆盖未确认")) }))
	end
	local dock = taskDock(state, busy)
	if kind == PR and selected and selected.state == "OPEN" then
		table.insert(dock, button("复制推送命令", "push_command=" .. state.generation .. ":" .. selected.number, false, busy))
	end
	if not state.confirm and not busy then
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
		if state.opening then return false end
		local panel = state.panel
		if panel then
			local controller = panel.controller
			if controller.key and controller.key(key) then return true end
			if key.name == "escape" then setMode(state, cx, nil); return true end
			if key.name == "r" and not key.ctrl and not key.meta and not key.alt and controller.refresh then controller.refresh(); return true end
			return false
		end
		local edit = state.edit
		if edit then
			if key.name == "enter" then submitEditor(state, cx); return true end
			if key.name == "escape" then dismissEditor(state, cx); state.field = nil; return true end
			return editorKey(edit, key)
		end
		if key.meta or key.ctrl or key.alt then return false end
		local list = state.listing
		if key.name == "r" and not state.opening then
			if state.repo then reload(state, cx, true, true) elseif state.source ~= "" then discover(state, cx, state.source) end
		elseif key.name == "tab" then setKind(state, cx, if state.saved.kind == ISSUE then PR else ISSUE)
		elseif key.text == "/" and state.repo and not state.opening then
			state.filtersOpen, state.field = true, "title"
			setEditor(state, cx, "title", pref(state, state.repo).filters.title or "")
		elseif key.name == "up" then navigation(state, cx, -1)
		elseif key.name == "down" then navigation(state, cx, 1)
		elseif key.name == "page_up" then navigation(state, cx, -PAGE)
		elseif key.name == "page_down" then navigation(state, cx, PAGE)
		elseif key.name == "enter" and list and list.data.rows[list.position] and not state.confirm then
			openRow(state, cx, list.data.rows[list.position].number)
		else return false end
		return true
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" and state.edit and ev.id == "main.editor.input" then
			cx:frame({ { "focus", ev.id } }); return
		end
		if ev.ev ~= "action" then return end
		local action, value = ev.act, ev.value
		if state.opening or type(action) ~= "string" then return end
		local panel = state.panel
		if action == "mode" then
			if value == "browse" then
				if panel then setMode(state, cx, nil) end
			elseif (value == "inbox" or value == "batch" or value == "submit") and value ~= state.mode then
				setMode(state, cx, value)
			end
			return
		end
		if action == "new_version" or action == "previous" then
			local change = state.confirm
			if not change then return end
			if action == "new_version" then openTask(state, cx, change.kind, change.number, change.head)
			elseif change.retained then openTask(state, cx, change.kind, change.number, change.retained, true) end
			return
		end
		if panel then
			local controller = panel.controller
			local prefix, command = action:match("^(%a+):(.+)$")
			if command and (prefix == state.mode or (state.mode == "inbox" and prefix == "verify")) then
				controller.event(if prefix == "verify" then "verify:" .. command else command, value)
			elseif action == "checkout" then
				setMode(state, cx, nil)
				setEditor(state, cx, "checkout", state.saved.checkout or state.source)
			elseif action == "repo" then
				local candidate = state.repos[tonumber(value) or 0]
				if candidate and candidate ~= state.repo then chooseRepo(state, cx, candidate) end
			elseif action == "refresh" and controller.refresh then controller.refresh()
			end
			return
		end
		local repo, list = state.repo, state.listing
		if action == "return_to_list" then cx:render(); return end
		if action == "checkout" then setEditor(state, cx, "checkout", state.saved.checkout or state.source); return end
		if action == "apply" then submitEditor(state, cx); return end
		if action == "dismiss" then dismissEditor(state, cx); state.field = nil; return end
		if action == "repo" then
			local candidate = state.repos[tonumber(value) or 0]
			if candidate and candidate ~= repo then chooseRepo(state, cx, candidate) end
			return
		end
		if action == "refresh" then
			if repo then reload(state, cx, true, true) elseif state.source ~= "" then discover(state, cx, state.source) end
			return
		end
		if not repo then return end
		if action == "push_command" then
			local selected, checkout = list and list.data.rows[list.position], state.saved.checkout
			if state.saved.kind ~= PR or not selected or selected.state ~= "OPEN" or not checkout
				or value ~= state.generation .. ":" .. selected.number then return end
			state.opening, state.confirm, state.taskError, state.progress = selected.number, nil, nil, "正在只读核对 PR 推送目标…"
			sessions.pushCommand(runtime.exec, repo, checkout, selected.number, function(command, target, err)
				state.opening = nil
				if not runtime.alive(cx.pane) then return end
				state.progress, state.taskError = nil, err
				if command and target then
					cx:copy(command)
					state.progress = "已复制，未执行。推送目标：" .. target
				end
				cx:render()
			end)
		elseif action == "open" then
			if type(value) ~= "string" then return end
			local generation, number = value:match("^(%d+):(%d+)$")
			if tonumber(generation) == state.generation and number then openRow(state, cx, assert(tonumber(number))) end
		elseif action == "prev" or action == "next" then
			if not list then return end
			local nextPage = pageAt(list) + (if action == "prev" then -1 else 1)
			local first = (nextPage - 1) * PAGE + 1
			if nextPage > 0 and first <= #list.data.rows then choosePosition(state, first) end
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
