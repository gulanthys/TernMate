--!strict

local runtime = require("./runtime")
local github = require("./github")
local sessions = require("./sessions")
local maintenance = require("./maintenance_data")
local issueSubmit = require("./issue_submit")
local ui = tern.ui

type Repo = runtime.Repo
type Filters = github.Filters
type Row = github.Row
type Identity = maintenance.Identity
type Prefs = { filters: Filters, selected: number?, position: number?, repoId: string?, viewerId: string? }
type Saved = { checkout: string?, repo: string?, kind: string,
	filtersByRepo: { [string]: { [string]: Prefs } }, maintenanceByRepo: { [string]: any }?, reviewMode: boolean? }
type Confirm = { number: number, identity: Identity, notice: sessions.Notice, serial: number }
type Editor = { key: string, text: string, caret: number, error: string? }
type Listing = { data: {rows: {Row}, uncertain: number}, position: number }
type Scope = { identity: Identity, snapshot: any?, baseline: any?, checked: number?, loading: boolean?, hydrated: boolean?,
	forceRefresh: boolean?, cancelSync: (() -> ())?,
	checkingRevision: boolean?, revisionError: string?, focusPending: boolean?,
	links: {[number]: string}?,
	issuesOpen: number?, prsOpen: number?, reviewOpen: number?,
	timer: TimerHandle?, errors: number?, error: string? }
type IdentityBinding = { identity: Identity? }
type ScopeCallback = (Scope?, string?) -> ()
type State = {
	saved: Saved, repo: Repo?, repos: { Repo }, source: string, generation: number, discovery: boolean,
	scopeError: string?, listing: Listing?, filtersOpen: boolean, field: string?, edit: Editor?,
	read: Scope?, identityWait: { ScopeCallback }?, verifying: boolean?, listError: string?,
	binding: IdentityBinding,
	opening: number?, progress: string?, taskError: string?, confirm: Confirm?,
	panel: any?,
}
type Choice = { string }
type Field = { key: string, title: string, choices: { Choice }? }
type Preset = { title: string, filters: Filters }

local ISSUE = "issue"
local PR = "pr"
local PAGE = 20
local EDIT_INPUT = "layer.editor.input"
local WORKSPACE = "main.workspace"
local RESULTS = WORKSPACE .. ".master.results"
local SYNC_MS = 300_000
local IDENTITY_CHANGED = "仓库或登录账号已变化；请刷新任务列表。"
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
		{ title = "全部状态", filters = {} },
	},
	[PR] = {
		{ title = "全部开放", filters = { state = "OPEN" } },
		{ title = "我提交的", filters = { state = "OPEN", author = "@me" } },
		{ title = "请求我审查", filters = { state = "OPEN", requested = "yes" } },
		{ title = "未解决线程", filters = { state = "OPEN", threads = "yes" } },
		{ title = "CI 失败", filters = { state = "OPEN", ci = "failure" } },
		{ title = "我的待处理 PR", filters = { state = "OPEN", author = "@me", actionable = "yes" } },
		{ title = "全部状态", filters = {} },
	},
}

local reviewPresets: { Preset } = {
	{ title = "全部待合并 PR", filters = {} },
	{ title = "请求我审查", filters = { requested = "yes" } },
	{ title = "未解决线程", filters = { threads = "yes" } },
	{ title = "CI 失败", filters = { ci = "failure" } },
}

local function kindFor(state: State): string
	return if state.saved.reviewMode then PR else state.saved.kind
end

local function presetsFor(state: State): { Preset }
	return if state.saved.reviewMode then reviewPresets else presets[state.saved.kind]
end

local function pref(state: State, repo: Repo): Prefs
	local key = runtime.repoKey(repo)
	local stored = state.saved.filtersByRepo[key]
	if not stored then stored = {}; state.saved.filtersByRepo[key] = stored end
	local kind = if state.saved.reviewMode then "review" else state.saved.kind
	if not stored[kind] then stored[kind] = { filters = if state.saved.reviewMode then {} else { state = "OPEN" } } end
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
	if previous and previous.cancelSync then previous.cancelSync() end
	state.read, state.listing, state.listError = nil, nil, err
	-- Retire the old storage capability, including callbacks from a closed panel.
	state.binding, state.panel = {}, nil
	state.identityWait, state.verifying = nil, nil
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
		else
			local bound = state.binding.identity
			if bound and not sameIdentity(bound, info) then
				invalidateScope(state, IDENTITY_CHANGED)
				scope = nil
			end
			state.binding.identity = info
			if not scope then
				scope = { identity = info }
				state.read = scope
			end
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
	local issues, prs, ready = 0, 0, 0
	for _, issue in snapshot.issues do if issue.state == "OPEN" then issues += 1 end end
	for _, pr in snapshot.prs do
		if pr.state == "OPEN" then
			prs += 1
			if pr.isDraft == false then ready += 1 end
		end
	end
	scope.issuesOpen, scope.prsOpen, scope.reviewOpen = issues, prs, ready
end

local function project(state: State, scope: Scope, preserve: boolean)
	local repo = state.repo
	if not repo or not scope.snapshot then return end
	local prefs = pref(state, repo)
	local filters = prefs.filters
	if state.saved.reviewMode then
		filters = table.clone(filters)
		filters.state, filters.draft = "OPEN", "no"
	end
	local rows, uncertain = github.project(scope.snapshot, kindFor(state), filters)
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
	state.listing = { data = { rows = rows, uncertain = uncertain }, position = position }
	state.generation += 1
end

local function copyRows(rows: {any}): {any}
	-- Tern's decoded JSON arrays have protected metatables.
	return table.move(rows, 1, #rows, 1, table.create(#rows))
end

local function synchronize(state: State, cx: BlockCx, repo: Repo, scope: Scope, forced: boolean?)
	if forced then scope.forceRefresh = true end
	if scope.loading then return end
	scope.loading, scope.error, scope.revisionError = true, nil, nil
	cx:render()
	if scope.timer then scope.timer:cancel(); scope.timer = nil end
	local function alive(): boolean return state.read == scope and state.repo == repo and runtime.alive(cx.pane) end
	local function schedule(delay: number)
		scope.timer = tern.timer(delay, function()
			scope.timer = nil
			if alive() then synchronize(state, cx, repo, scope) end
		end)
	end
	local function sync()
		scope.forceRefresh = nil
		local baseline = scope.baseline
		local visible = scope.snapshot
		local preview: any = nil
		local positions: {[string]: {[number]: number}?} = {}
		local pending: TimerHandle? = nil
		local function cancelPending()
			if pending then pending:cancel(); pending = nil end
		end
		local function stop()
			cancelPending()
			scope.cancelSync = nil
		end
		local function active(): boolean return scope.cancelSync == stop and alive() end
		scope.cancelSync = stop
		local function paint()
			-- Only the preview owns these arrays. Keep the complete mirror for
			-- subsequent scans, and recompute counts/links when publishing.
			install(scope, table.clone(preview))
			project(state, scope, true)
		end
		maintenance.sync(repo, scope.identity, baseline, active, function(snapshot, err, changedIdentity, changedRevision)
			if not active() then return end
			local hasPending = pending ~= nil
			stop()
			scope.loading = false
			if changedIdentity then invalidateScope(state, err); cx:render(); return end
			if changedRevision then
				if hasPending then paint() end
				scope.checked = nil
				synchronize(state, cx, repo, scope)
				return
			end
			scope.error = err
			if snapshot and snapshot.complete then
				local changed = scope.snapshot ~= snapshot
				scope.baseline = snapshot
				install(scope, snapshot)
				scope.checked, scope.errors = tern.now(), 0
				if changed or not state.listing then project(state, scope, true) end
			else
				if hasPending then paint() end
				scope.errors = math.min(3, (scope.errors or 0) + 1)
				if not scope.error then scope.error = "后台扫描未完成。" end
			end
			if scope.forceRefresh then
				synchronize(state, cx, repo, scope)
				return
			end
			cx:render()
			schedule(SYNC_MS * 2 ^ (scope.errors or 0))
		end, function(kind, updates)
			if not active() then return end
			if not preview then
				preview = {viewer = scope.identity.viewer, complete = false,
					issues = if visible then copyRows(visible.issues) else {},
					prs = if visible then copyRows(visible.prs) else {}}
			end
			local entries = preview[kind]
			local first = positions[kind] == nil
			local index: {[number]: number} = positions[kind] or {}
			if first then
				for position, item in entries do index[item.number] = position end
				positions[kind] = index
			end
			-- A page not yet seen is not a deletion. Replace only verified rows.
			for _, item in updates do
				local position = index[item.number] or (#entries + 1)
				index[item.number], entries[position] = position, item
			end
			if first then
				cancelPending()
				paint()
				cx:render()
			elseif not pending then
				pending = tern.timer(150, function()
					pending = nil
					if not active() then return end
					paint()
					cx:render()
				end)
			end
		end, if visible ~= baseline then visible else nil)
	end
	if scope.hydrated then sync(); return end
	maintenance.cached(repo, scope.identity, function(snapshot, cacheErr)
		if not alive() then return end
		local function hydrate(trusted: boolean)
			scope.hydrated, scope.focusPending = true, nil
			local checked = snapshot and snapshot.checkedEpoch
			local age = if type(checked) == "number" then (os.time() - checked) * 1000 else nil
			if trusted and not scope.forceRefresh and age and age >= 0 and age < SYNC_MS and not cacheErr then
				scope.loading, scope.checked = false, tern.now() - age
				cx:render()
				schedule(SYNC_MS - age)
				return
			end
			sync()
		end
		scope.error = cacheErr
		if snapshot then
			scope.baseline = snapshot
			install(scope, snapshot)
			project(state, scope, true)
			local function checkCache()
				local expected = snapshot.resultRevision
				if not scope.focusPending or scope.forceRefresh or not expected then
					hydrate(not scope.focusPending)
					return
				end
				scope.focusPending = nil
				maintenance.resultRevision(repo, scope.identity, function(revision)
					if not alive() then return end
					if revision ~= expected or scope.forceRefresh then hydrate(false)
					elseif scope.focusPending then checkCache()
					else hydrate(true) end
				end)
			end
			cx:render()
			checkCache()
		else
			hydrate(false)
		end
	end)
end

local function checkFocusedList(state: State, cx: BlockCx)
	local repo, scope = state.repo, state.read
	if scope and ((scope.loading and not scope.hydrated) or scope.checkingRevision) then
		scope.focusPending = true
		return
	end
	local baseline = scope and scope.baseline
	local expected = baseline and baseline.resultRevision
	if not repo or not scope or scope.loading or not expected then
		cx:render()
		return
	end
	scope.checkingRevision = true
	cx:render()
	maintenance.resultRevision(repo, scope.identity, function(revision, err)
		if state.read ~= scope or state.repo ~= repo or not runtime.alive(cx.pane) then return end
		local pending = scope.focusPending
		scope.checkingRevision, scope.focusPending = false, nil
		if not scope.loading and scope.baseline == baseline and baseline.resultRevision == expected then
			scope.revisionError = err
			if revision and revision ~= expected then
				scope.checked = nil
				synchronize(state, cx, repo, scope, true)
				return
			end
		end
		if pending and not scope.loading then
			checkFocusedList(state, cx)
			return
		end
		cx:render()
	end)
end

local function reload(state: State, cx: BlockCx, preserve: boolean, force: boolean?)
	local repo = state.repo
	if not repo then return end
	local scope = state.read
	if scope then
		if force then synchronize(state, cx, repo, scope, true) else project(state, scope, preserve) end
		return
	end
	if state.verifying and not force then return end
	state.verifying = true
	readScope(state, cx, repo, function(current, err)
		state.verifying, state.listError = false, err
		if current then synchronize(state, cx, repo, current, force) end
	end)
end

local function chooseRepo(state: State, cx: BlockCx, repo: Repo)
	invalidateScope(state, nil)
	state.repo, state.saved.repo = repo, runtime.repoKey(repo)
	state.scopeError, state.taskError, state.confirm, state.progress = nil, nil, nil, nil
	state.filtersOpen, state.field, state.edit = false, nil, nil
	reload(state, cx, true)
end

local function discover(state: State, cx: BlockCx, cwd: string)
	if state.discovery then return end
	invalidateScope(state, nil)
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
	if state.repo and state.read then
		local prefs = pref(state, state.repo)
		prefs.selected, prefs.position = row.number, index
		prefs.repoId, prefs.viewerId = state.read.identity.repoId, state.read.identity.viewerId
	end
end

local function openTask(state: State, cx: BlockCx, identity: Identity, kind: string, number: number, version: sessions.Version?, retained: boolean?)
	local repo, checkout = state.repo, state.saved.checkout
	local reviewing = state.saved.reviewMode == true
	if not repo or not checkout or state.opening or (kind ~= ISSUE and kind ~= PR) or (reviewing and kind ~= PR) then return end
	state.opening, state.confirm, state.taskError, state.progress = number, nil, nil, "准备任务 #" .. number .. "…"
	sessions.open(runtime.exec, { repo = repo, identity = identity, checkout = checkout, kind = kind, number = number, pane = cx.pane,
		version = version, retained = retained, review = reviewing },
		function(message)
			if not runtime.alive(cx.pane) then return end
			state.progress = message
			cx:render()
		end, function(message, err, notice)
			state.opening = nil
			if not runtime.alive(cx.pane) then return end
			state.progress, state.taskError = message, err
			if notice then
				state.generation += 1
				state.confirm = { number = number, identity = identity, notice = notice, serial = state.generation }
			end
			cx:render()
		end)
end

local function openRow(state: State, cx: BlockCx, number: number)
	local list, scope = state.listing, state.read
	if state.verifying or state.confirm or not list or not scope then return end
	for index, row in list.data.rows do
		if row.number == number then
			choosePosition(state, index)
			openTask(state, cx, scope.identity, kindFor(state), number)
			return
		end
	end
end



local function setMode(state: State, cx: BlockCx, mode: string?)
	local repo, checkout = state.repo, state.saved.checkout
	if not repo or not checkout or state.opening then return end
	state.panel, state.confirm, state.progress, state.taskError = nil, nil, nil, nil
	state.filtersOpen, state.field = false, nil
	if state.edit then
		state.edit = nil
		local clear: {any} = { "focus", tern.json.null }
		cx:frame({ clear })
	end
	if not mode then return end
	if not state.saved.maintenanceByRepo then state.saved.maintenanceByRepo = {} end
	local saved = state.saved.maintenanceByRepo :: { [string]: any }
	local repoKey = runtime.repoKey(repo)
	if not saved[repoKey] then saved[repoKey] = {} end
	-- Install the panel before constructing the controller; new() may start I/O.
	local panel: any = {}
	local binding = state.binding
	state.panel = panel
	local pinned: Identity? = nil
	local function alive(): boolean return state.panel == panel and runtime.alive(cx.pane) end
	local function issueCreated()
		if state.binding ~= binding or not runtime.alive(cx.pane) then return end
		local scope = state.read
		if scope then
			scope.checked = nil
			-- A scan started before creation may have already read the Issue page.
			if scope.cancelSync then
				scope.cancelSync()
				scope.loading = false
			end
		end
		reload(state, cx, true, true)
	end
	local function revoke(err: string?)
		if not alive() then return end
		invalidateScope(state, err or IDENTITY_CHANGED)
		cx:render()
	end
	local function identity(done: (any, string?) -> ())
		if not alive() then return end
		maintenance.identity(repo, function(info, err)
			if not alive() then return end
			local bound = binding.identity
			if bound and (not info or not sameIdentity(bound, info)) then
				revoke(err)
				return
			end
			if info then
				binding.identity = info
				pinned = pinned or info
			end
			done(info, err)
		end)
	end
	local ctx: any = {
		repo = repo, checkout = checkout, cx = cx, alive = alive, prefs = saved[repoKey],
		render = function() if alive() then cx:render() end end,
		open = function(kind: string, number: number)
			if alive() and pinned then openTask(state, cx, pinned, kind, number) end
		end,
		identity = identity,
		revoke = revoke,
		issueCreated = issueCreated,
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
	ctx.store = function(key: string, storeMode: string, value: any, done: (any, string?) -> ())
		if state.binding ~= binding or not pinned then return end
		-- An already dispatched operation is confined to the old partition.
		-- Do not run its continuation (or start further I/O) after revocation.
		maintenance.store(repo, pinned, key, storeMode, value, function(result, err)
			if state.binding == binding then done(result, err) end
		end)
	end
	ctx.createIssue = function(confirmed: Identity, slot: number, draft: any, title: string, body: string, labels: {string}?, done: (string?) -> ())
		if not alive() or state.binding ~= binding or not pinned or not sameIdentity(pinned, confirmed) then return end
		maintenance.createIssue(repo, confirmed, slot, draft, title, body, labels, function(outcome)
			if outcome == "created" then issueCreated() end
			if alive() then done(outcome) end
		end)
	end
	panel.controller = issueSubmit.new(ctx)
end

local function fieldFor(state: State, key: string): Field?
	if state.saved.reviewMode and (key == "state" or key == "draft") then return nil end
	for _, field in fields[kindFor(state)] do if field.key == key then return field end end
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
	cx:frame({ { "focus", EDIT_INPUT } })
end

local function search(state: State, cx: BlockCx, repo: Repo)
	setEditor(state, cx, "title", pref(state, repo).filters.title or "")
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
	if state.saved.reviewMode or kind == state.saved.kind or state.opening then return end
	state.saved.kind = kind
	state.field, state.progress, state.taskError, state.confirm = nil, nil, nil, nil
	if state.edit then dismissEditor(state, cx) end
	reload(state, cx, true)
end

local function setReviewMode(state: State, cx: BlockCx, review: boolean)
	if (state.saved.reviewMode == true) == review then return end
	state.saved.reviewMode = review
	state.field, state.progress, state.taskError, state.confirm = nil, nil, nil, nil
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

local function selectAdjacentPage(state: State, list: Listing, page: number)
	if page >= 1 and math.abs(page - pageAt(list)) == 1 then
		choosePosition(state, (page - 1) * PAGE + 1)
	end
end

local function navigation(state: State, offset: number)
	local list = state.listing
	if not list then return end
	local data = list.data
	if #data.rows == 0 then return end
	local target = math.max(1, list.position + offset)
	if target <= #data.rows then choosePosition(state, target)
	else choosePosition(state, #data.rows) end
end

local function button(label: string, action: string, active: boolean?, disabled: boolean?, variant: ("primary" | "quiet")?): Node
	return ui.button(label, { key = action, size = "sm", on = active, disabled = disabled, variant = variant, actions = { click = action } })
end

local function text(label: string, tone: string?): Node
	return ui.text({ ui.span(label, tone or "muted") })
end

local function wrapRow(nodes: { Node }, key: string?): Node
	return ui.node("row", { key = key, gap = "sm", wrap = true }, nodes)
end

local function dialog(key: string, title: string, body: { Node }, actions: { Node }): Node
	table.insert(body, ui.node("row", { key = "foot", justify = "end", gap = "sm", wrap = true }, actions))
	return ui.col({ ui.node("overlay", { key = key, head = title, modal = true, foot = "layer." .. key .. ".foot" }, body) })
end

local function fieldValue(field: Field, value: string): string
	if field.choices then
		for _, choice in field.choices do if choice[1] == value then return choice[2] end end
	end
	return value
end

local function editorView(edit: Editor, title: string): Node
	local items = { ui.node("input", { key = "input", text = edit.text, cursor = utf16Length(edit.text, edit.caret),
		placeholder = if edit.key == "checkout" then "/path/to/repo" else "留空移除此条件" }) }
	if edit.error then table.insert(items, text(edit.error, "error")) end
	return dialog("editor", title, items, { button("取消", "dismiss", nil, nil, "quiet"),
		button("应用 ↵", "apply", nil, nil, "primary") })
end

local function versionLabel(version: sessions.Version): string
	local head = version.head:sub(1, 12)
	if version.baseRef and version.baseSHA then return version.baseRef .. "@" .. version.baseSHA:sub(1, 12) .. " ← " .. head end
	return head
end

local function cancelVersion(state: State)
	state.confirm, state.taskError, state.progress = nil, nil, nil
end

local function taskDock(state: State, busy: boolean): { Node }
	local dock: { Node } = {}
	if state.progress then table.insert(dock, text(state.progress, if busy then "accent" else "muted")) end
	if state.taskError then table.insert(dock, text(state.taskError, "warning")) end
	if state.confirm then
		local notice = state.confirm.notice
		local choices = {}
		local serial = "=" .. state.confirm.serial
		if notice.retained then table.insert(choices, button("打开旧版本 " .. versionLabel(notice.retained), "previous" .. serial)) end
		table.insert(choices, button("打开新版本 " .. versionLabel(notice.current), "new_version" .. serial))
		table.insert(choices, button("取消 (Esc)", "cancel_version" .. serial))
		table.insert(dock, wrapRow(choices))
	end
	return dock
end

local function repoLabel(repo: Repo): string
	return repo.owner .. "/" .. repo.name
end

local function header(state: State, busy: boolean): Node
	local repo, panel = state.repo, state.panel
	local path = state.saved.checkout or state.source
	local identity = { ui.node("text", { truncate = "end", spans = {
		ui.span(if repo then repoLabel(repo) else "选择 GitHub 仓库", "title"),
		ui.span(if repo then "  " .. repo.host else "", "muted"),
	} }) }
	if path ~= "" then
		table.insert(identity, ui.node("text", { truncate = "middle", spans = { ui.span(path, "muted path") } }))
	end
	local controls: { Node } = {}
	if repo then
		local choices: { any } = {}
		if #state.repos > 1 then
			for index, candidate in state.repos do
				local label = repoLabel(candidate) .. (if candidate.host ~= "github.com" then " @ " .. candidate.host else "")
				table.insert(choices, { id = "repo=" .. index, label = label, radio = "repo", checked = repo == candidate })
			end
			table.insert(choices, "-")
		end
		table.insert(choices, { id = "checkout", label = "本地 checkout…" })
		table.insert(controls, ui.node("menu", { key = "repository", text = "仓库", caret = true, size = "sm",
			disabled = busy, align = "end", items = choices }))
	else
		table.insert(controls, button("本地 checkout…", "checkout", nil, busy or state.discovery))
	end
	if not panel or panel.controller.refresh then
		local disabled: boolean = busy or state.discovery or state.verifying == true
		table.insert(controls, ui.button(if repo then "刷新" else "重新探测", { key = "refresh", size = "sm", icon = "repeat",
			keys = { "r" }, disabled = disabled,
			actions = { click = "refresh" } }))
	end
	if repo and (panel or not state.saved.reviewMode) then
		table.insert(controls, if panel then button("返回任务列表", "close_submit", nil, busy)
			else button("新建 Issue", "new_issue", nil, busy, "primary"))
	end
	local switching = repo ~= nil and not panel
	local children = { ui.node("col", { key = "identity", grow = 1, basis = 0, gap = "xs" }, identity) }
	if switching then
		table.insert(children, ui.node("tabs", { key = "modes", variant = "segmented",
			active = if state.saved.reviewMode then "review" else "develop",
			items = { { id = "develop", label = "开发模式" }, { id = "review", label = "审核模式" } },
		}))
	end
	table.insert(children, ui.node("row", { key = "controls", gap = "sm", wrap = true, justify = "end",
		grow = if switching then 1 else nil, basis = if switching then 0 else nil,
		min = if switching then { w = "26ch" } else nil,
	}, controls))
	return ui.node("row", { key = "header", gap = "sm", justify = "between", align = "center", wrap = true }, children)
end


local function filterSummary(kind: string, filters: Filters, busy: boolean): ({ Node }, number)
	local chips = {}
	for _, field in fields[kind] do
		local value = filters[field.key]
		if not value then continue end
		local label = fieldValue(field, value)
		local cut = utf8.offset(label, 19)
		local action = "remove=" .. field.key
		table.insert(chips, ui.button(field.title .. "：" .. (if cut then label:sub(1, cut - 1) .. "…" else label) .. " ×", {
			key = action, size = "sm", variant = "quiet", title = "移除「" .. field.title .. "：" .. label .. "」",
			disabled = busy, actions = { click = action },
		}))
	end
	if filters.actionable then table.insert(chips, button("待处理信号 ×", "remove=actionable", nil, busy, "quiet")) end
	return chips, #chips
end

local function filtersView(state: State, kind: string, filters: Filters): Node
	local field = if state.field then fieldFor(state, state.field) else nil
	if field and field.choices then
		local options = { button("不限", "option=", not filters[field.key]) }
		for _, choice in field.choices do
			table.insert(options, button(choice[2], "option=" .. choice[1], filters[field.key] == choice[1]))
		end
		return dialog("filter", field.title, { wrapRow(options) }, { button("返回筛选", "filter_back") })
	end
	local controls = {}
	for _, candidate in fields[kind] do
		if state.saved.reviewMode and not fieldFor(state, candidate.key) then continue end
		local value = filters[candidate.key]
		table.insert(controls, button(candidate.title .. (if value then " ✓" else ""), "field=" .. candidate.key, value ~= nil))
	end
	return dialog("filter", "筛选 " .. (if kind == ISSUE then "Issues" else "PRs"),
		{ text("选择要编辑的条件。筛选作用于整个本地镜像，不限当前页。"), wrapRow(controls) },
		{ button("清空条件", "clear", nil, next(filters) == nil, "quiet"), button("完成", "filters") })
end

local function browseToolbar(state: State, kind: string, filters: Filters, busy: boolean): Node
	local shortcuts: { any } = {}
	for index, preset in presetsFor(state) do
		local active = true
		for key, value in preset.filters do if filters[key] ~= value then active = false; break end end
		if active then
			for key in filters do if not preset.filters[key] then active = false; break end end
		end
		table.insert(shortcuts, { id = "preset=" .. index, label = preset.title, radio = "preset", checked = active })
	end
	local chips, count = filterSummary(kind, filters, busy)
	local toolbar = wrapRow({
		ui.button("搜标题", { key = "search", size = "sm", icon = "search", keys = { "/" }, disabled = busy,
			actions = { click = "search" } }),
		button(if count > 0 then "筛选 · " .. count else "筛选", "filters", state.filtersOpen, busy),
		ui.node("menu", { key = "presets", text = "快捷筛选", caret = true, size = "sm", disabled = busy, items = shortcuts }),
	}, "toolbar")
	return ui.node("col", { key = "controls", gap = "xs" }, { toolbar, wrapRow(chips, "conditions") })
end

local function rowStatus(row: Row): string
	return if row.state == "MERGED" then "已合并" elseif row.state ~= "OPEN" then "已关闭" elseif row.draft then "草稿" else "开放"
end

local function listView(state: State, cx: BlockCx, repo: Repo, kind: string, filters: Filters, busy: boolean, current: boolean): Node
	local list, scope = state.listing, state.read
	local master: { Node } = {}
	local function column(): Node
		return ui.node("col", { key = "master", gap = "sm" }, master)
	end
	if not list then
		local err = state.listError or (scope and scope.error)
		if err then
			table.insert(master, ui.node("empty", { title = "任务列表不可用", text = err, tone = "error" }))
		else
			table.insert(master, ui.progress(nil, if state.verifying then "正在核对 GitHub 仓库和账号…"
				elseif scope and scope.hydrated then "正在同步 GitHub 列表…" else "正在读取本地镜像…"))
		end
		return column()
	end
	local data = list.data
	local total = #data.rows
	local syncError = scope and (scope.error or scope.revisionError)
	local syncStatus = if state.verifying then "正在核对账号 · 显示上次列表"
		elseif scope and scope.loading then "正在同步 · 已核对的条目会先更新"
		elseif scope and scope.checkingRevision then "正在核对本地提交结果"
		elseif syncError then "同步未确认 · 显示已知数据"
		elseif current then "本地镜像 · 已同步" else "本地镜像 · 覆盖未确认"
	table.insert(master, wrapRow({ text("任务列表", "strong"),
		ui.badge(syncStatus, if syncError then "warning" else "muted") }, "summary"))
	if syncError then table.insert(master, text(syncError, "warning")) end
	if data.uncertain > 0 then table.insert(master, text(data.uncertain .. " 项缺少筛选证据，无法确认是否匹配。", "warning")) end
	if total == 0 then
		local title = if current and data.uncertain == 0 then "没有匹配项" else "暂未找到匹配项"
		local hint = if not current then "列表覆盖尚未确认。" elseif data.uncertain > 0 then "部分任务仍缺少筛选证据。" else "调整筛选条件，查看其他任务。"
		table.insert(master, ui.node("empty", { title = title, text = hint }, {
			button("调整筛选", "filters", nil, busy),
		}))
		return column()
	end

	local selected = data.rows[list.position]
	local disabled = busy or state.verifying
	local localBadge = if kind == ISSUE and scope and state.saved.checkout then sessions.issueBadges(repo, scope.identity, state.saved.checkout) else nil
	local links = if kind == ISSUE and scope then scope.links else nil
	local page = pageAt(list)
	local rows: { Node } = {}
	for index = (page - 1) * PAGE + 1, math.min(page * PAGE, total) do
		local row = data.rows[index]
		local target = state.generation .. ":" .. row.number
		local status = { ui.span(rowStatus(row), "muted") }
		local function signal(label: string, tone: string)
			table.insert(status, ui.span(" · " .. label, tone))
		end
		if kind == PR then
			if row.mergeable == "CONFLICTING" then signal("合并冲突", "warning")
			elseif row.mergeable == "UNKNOWN" then signal("可合并性未知", "muted") end
			if row.ci ~= "none" then
				signal(ciNames[row.ci], if row.ci == "failure" then "error" elseif row.ci == "success" then "success" else "muted")
			end
			if row.threads then signal("未解决线程", "warning") end
			if row.requested then signal("请求我审查", "info") end
			if row.review == "CHANGES_REQUESTED" then signal("要求修改", "warning")
			elseif row.review == "APPROVED" then signal("已批准", "success")
			elseif row.review == "REVIEW_REQUIRED" then signal("需要审查", "info") end
		else
			if localBadge and localBadge(row.number) ~= "" then signal("本机处理中", "info") end
			if links and links[row.number] then signal(links[row.number], "muted") end
		end
		table.insert(rows, ui.node("item", { key = "n" .. row.number, title = row.title,
			label = { ui.span("#" .. row.number .. "  ", "mono muted"), ui.span(row.title) },
			value = status, disabled = disabled,
			actions = { click = "open=" .. target, menu = if not state.saved.reviewMode and kind == PR and row.state == "OPEN"
				then { { id = "push_command=" .. target, label = "复制推送命令", disabled = state.confirm ~= nil } } else nil } }))
	end
	table.insert(master, ui.node("list", { key = "results", selected = RESULTS .. ".n" .. selected.number,
		max = { lines = math.clamp(cx.rows - 12, 3, PAGE) }, filter = filters.title }, rows))

	return column()
end

local function countLabel(scope: Scope?, current: boolean, count: number?): string
	if count == nil then return "—" end
	if current then return tostring(count) end
	return (if scope and scope.snapshot and scope.snapshot.complete then "上次 " else "已找到 ") .. count
end

local function kindTabs(state: State, current: boolean): Node
	local scope = state.read
	local function label(title: string, count: number?): string
		return title .. " · " .. countLabel(scope, current, count)
	end
	return ui.node("tabs", { key = "kinds", active = state.saved.kind, items = {
		{ id = ISSUE, label = label("开放 Issue", scope and scope.issuesOpen) },
		{ id = PR, label = label("开放 PR", scope and scope.prsOpen) },
	} })
end

local function view(state: State, cx: BlockCx): BlockView
	local repo, edit, panel = state.repo, state.edit, state.panel
	local busy = state.opening ~= nil
	local main, dock = { header(state, busy) }, taskDock(state, busy)
	local layer: Node? = nil
	if edit and edit.key == "checkout" then layer = editorView(edit, "选择本地 checkout") end
	if not repo then
		if state.discovery then
			table.insert(main, ui.progress(nil, "正在识别 Git remote 和 fork 上游…"))
		elseif state.scopeError then
			table.insert(main, ui.node("empty", { title = "无法打开仓库", text = state.scopeError, tone = "error" }))
		elseif #state.repos > 0 then
			local choices = {}
			for index, candidate in state.repos do
				table.insert(choices, button(repoLabel(candidate) .. " @ " .. candidate.host, "repo=" .. index))
			end
			table.insert(main, text("选择此 checkout 对应的任务仓库。"))
			table.insert(main, wrapRow(choices))
		end
		return { main = ui.col(main), layer = layer }
	end

	if panel then
		for _, node in panel.controller.view() do table.insert(main, node) end
		return { main = ui.col(main), dock = ui.col(dock) }
	end

	local kind, filters = kindFor(state), pref(state, repo).filters
	local scope = state.read
	local current = not state.verifying and scope ~= nil and scope.snapshot ~= nil and scope.snapshot.complete == true
		and not scope.loading and not scope.error and not scope.checkingRevision and not scope.revisionError and fresh(scope.checked)
	if state.saved.reviewMode then
		local count = scope and scope.reviewOpen
		local suffix = countLabel(scope, current, count)
		table.insert(main, ui.node("text", { key = "review_queue", spans = {
			ui.span("待合并 PR · " .. suffix, "strong"), ui.span("   开放、非草稿 · 只读审核", "muted"),
		} }))
	else
		table.insert(main, kindTabs(state, current))
	end
	table.insert(main, browseToolbar(state, kind, filters, busy))
	table.insert(main, ui.node("col", { key = "workspace" }, { listView(state, cx, repo, kind, filters, busy, current) }))
	local list = state.listing
	if list and #list.data.rows > 0 then
		local page = pageAt(list)
		local total = #list.data.rows
		local complete = current and list.data.uncertain == 0
		local controls = ui.row({
			ui.button("‹", { key = "prev", title = "上一页", size = "sm", disabled = busy or page == 1,
				actions = { click = "page=" .. (page - 1) } }),
			ui.node("text", { key = "current", aria = "第 " .. page .. " 页", spans = { ui.span(tostring(page), "mono strong") } }),
			ui.button("›", { key = "next", title = "下一页", size = "sm", disabled = busy or page * PAGE >= total,
				actions = { click = "page=" .. (page + 1) } }),
		})
		table.insert(dock, ui.node("row", { key = "pager", justify = "end", gap = "sm", wrap = true }, {
			controls,
			text((if complete then "共 " else "已找到 ") .. total .. " 项"),
		}))
	end
	if not state.confirm and not busy then
		local spans = { ui.span("↑ ↓", "key"), ui.span(" 选择   ", "muted"),
			ui.span("← →", "key"), ui.span(" 翻页   ", "muted"),
			ui.span("Enter", "key"), ui.span(if state.saved.reviewMode then " 只读审核" else " 打开   ", "muted") }
		if not state.saved.reviewMode then
			table.insert(spans, ui.span("Tab", "key"))
			table.insert(spans, ui.span(" 切换 Issue / PR", "muted"))
		end
		local footer = { ui.node("text", { key = "shortcuts", spans = spans }) }
		table.insert(dock, ui.node("row", { key = "browse_footer", gap = "sm", justify = "between", wrap = true }, footer))
	end
	if edit and edit.key ~= "checkout" then
		local field = fieldFor(state, edit.key)
		layer = editorView(edit, if field then field.title else "筛选")
	elseif not layer then
		if state.filtersOpen then layer = filtersView(state, kind, filters) end
	end
	return { main = ui.col(main), dock = ui.col(dock), layer = layer }
end

local block: BlockDef<State> = {
	font = "sans",
	init = function(cx, args, saved)
		local prefs: Saved = if type(saved) == "table" and type(saved.filtersByRepo) == "table" then saved
			else { kind = ISSUE, filtersByRepo = {} }
		if prefs.kind ~= PR then prefs.kind = ISSUE end
		prefs.reviewMode = prefs.reviewMode == true
		if type(saved) == "table" then saved.layout, saved.trendCollapsed = nil, nil end
		local source = prefs.checkout or args[1] or cx.cwd or ""
		local state: State = { saved = prefs, repos = {}, source = source, generation = 0, discovery = false,
			filtersOpen = false, binding = {} }
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
		if state.filtersOpen then
			if key.name ~= "escape" then return false end
			if state.field then state.field = nil else state.filtersOpen = false end
			return true
		end
		if key.name == "escape" and state.confirm then cancelVersion(state); return true end
		local list = state.listing
		if key.name == "r" and not state.opening then
			if state.repo then reload(state, cx, true, true) elseif state.source ~= "" then discover(state, cx, state.source) end
		elseif key.name == "tab" and not state.saved.reviewMode then setKind(state, cx, if state.saved.kind == ISSUE then PR else ISSUE)
		elseif key.text == "/" and state.repo then search(state, cx, state.repo)
		elseif key.name == "up" then navigation(state, -1)
		elseif key.name == "down" then navigation(state, 1)
		elseif list and (key.name == "left" or key.name == "right") then
			selectAdjacentPage(state, list, pageAt(list) + (if key.name == "left" then -1 else 1))
		elseif key.name == "page_up" then navigation(state, -PAGE)
		elseif key.name == "page_down" then navigation(state, PAGE)
		elseif key.name == "enter" and list and list.data.rows[list.position] then
			openRow(state, cx, list.data.rows[list.position].number)
		else return false end
		return true
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" and state.edit and ev.id == EDIT_INPUT then
			cx:frame({ { "focus", EDIT_INPUT } }); return
		end
		if state.opening then return end
		local panel = state.panel
		local browsing = not panel and not state.edit and not state.filtersOpen
		local action, value
		if ev.ev == "action" then
			action, value = ev.act, ev.value
			-- Standalone menus send the row ID verbatim; node actions split on "=".
			if type(action) == "string" then
				if ev.id == "main.controls.toolbar.presets" then
					local index = action:match("^preset=(%d+)$")
					if index then action, value = "preset", index end
				elseif ev.id == "main.header.controls.repository" then
					local index = action:match("^repo=(%d+)$")
					if index then action, value = "repo", index end
				end
			end
		elseif ev.ev == "select" and ev.id == "main.header.modes" and browsing and state.repo then
			if ev.item == "develop" or ev.item == "review" then setReviewMode(state, cx, ev.item == "review") end
			return
		elseif ev.ev == "select" and ev.id == "main.kinds" and browsing then
			if state.repo and (ev.item == ISSUE or ev.item == PR) then setKind(state, cx, ev.item) end
			return
		else return end
		if type(action) ~= "string" then return end
		if action == "return_to_list" then checkFocusedList(state, cx); return end
		if action == "page" then
			local page, list = tonumber(value), state.listing
			if browsing and list and page then
				selectAdjacentPage(state, list, page)
			end
			return
		end
		if action == "new_version" or action == "previous" or action == "cancel_version" then
			local change = state.confirm
			if not change or tonumber(value) ~= change.serial then return end
			if action == "cancel_version" then cancelVersion(state); return end
			local notice = change.notice
			if action == "new_version" then
				openTask(state, cx, change.identity, PR, change.number, notice.current)
			elseif action == "previous" and notice.retained then
				openTask(state, cx, change.identity, PR, change.number, notice.retained, true)
			end
			return
		end
		if panel then
			local controller = panel.controller
			local prefix, command = action:match("^(%a+):(.+)$")
			if command and prefix == "submit" then
				controller.event(command, value)
			elseif action == "close_submit" then setMode(state, cx, nil)
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
		if action == "new_issue" and browsing and not state.saved.reviewMode then setMode(state, cx, "submit"); return end
		if action == "search" and browsing then search(state, cx, repo); return end
		if action == "push_command" then
			local checkout, scope = state.saved.checkout, state.read
			if not browsing or not scope or state.saved.reviewMode or state.verifying or state.confirm or state.saved.kind ~= PR or not list or not checkout
				or type(value) ~= "string" then return end
			local generation, number = value:match("^(%d+):(%d+)$")
			if tonumber(generation) ~= state.generation or not number then return end
			local selected: Row? = nil
			for _, row in list.data.rows do if row.number == tonumber(number) then selected = row; break end end
			if not selected or selected.state ~= "OPEN" then return end
			state.opening, state.confirm, state.taskError, state.progress = selected.number, nil, nil, "正在只读核对 PR 推送目标…"
			sessions.pushCommand(runtime.exec, repo, scope.identity, checkout, selected.number, function(command, target, err)
				state.opening = nil
				if not runtime.alive(cx.pane) then return end
				state.progress, state.taskError = nil, err
				if command and target then
					cx:copy(command)
					state.progress = "已复制，未执行。推送目标：" .. target
				end
				cx:render()
			end)
		elseif action == "open" and browsing then
			if type(value) ~= "string" then return end
			local generation, number = value:match("^(%d+):(%d+)$")
			if tonumber(generation) ~= state.generation or not number then return end
			openRow(state, cx, assert(tonumber(number)))
		elseif action == "filters" then
			state.filtersOpen = not state.filtersOpen
			if not state.filtersOpen then state.field = nil; dismissEditor(state, cx) end
		elseif action == "filter_back" then state.field = nil
		elseif action == "remove" and (value == "actionable" or fieldFor(state, value)) then
			changeFilter(state, cx, value, nil)
		elseif action == "clear" or action == "preset" then
			local preset = presetsFor(state)[tonumber(value) or 0]
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
