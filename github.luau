--!strict

local runtime = require("./runtime")
type Repo = runtime.Repo
type Exec = runtime.Exec
export type Filters = { [string]: string }
export type Row = {
	number: number, title: string, state: string, updated: string, author: string, url: string,
	draft: boolean, base: string?, requested: boolean, threads: boolean, ci: string,
	mergeable: string?,
}

local github = {}

local function parseRemote(url: string): Repo?
	local host, path = url:match("^https?://([^/]+)/(.+)$")
	if not host then host, path = url:match("^ssh://[%w_.%-]+@([%w.%-]+):?%d*/(.+)$") end
	if not host then host, path = url:match("^ssh://([%w.%-]+):?%d*/(.+)$") end
	if not host then host, path = url:match("^[%w_.%-]+@([%w.%-]+):(.+)$") end
	if not host or not path or not host:match("^%w[%w.%-]*$") then return nil end
	path = path:gsub("/$", ""):gsub("%.git$", "")
	local owner, name = path:match("^([%w%-]+)/([%w_.%-]+)$")
	if not owner or not name or name:match("^%.%.?$") then return nil end
	if host:lower() == "ssh.github.com" then host = "github.com" end
	return { host = host:lower(), owner = owner, name = name }
end

function github.discover(exec: Exec, cwd: string, alive: () -> boolean, done: (string?, { Repo }, string?) -> ())
	exec({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(result, err)
		if not alive() then return end
		if not result or result.status ~= 0 then
			done(nil, {}, if result then "该目录不在 Git checkout 内。请选择本地仓库。" else runtime.failure(result, err))
			return
		end
		local checkout = result.stdout:gsub("\r?\n$", "")
		exec({ "git", "remote", "-v" }, { cwd = checkout }, function(remotes, remoteErr)
			if not alive() then return end
			if not remotes or remotes.status ~= 0 then done(checkout, {}, runtime.failure(remotes, remoteErr)); return end
			local candidates: { Repo } = {}
			local seen: { [string]: boolean } = {}
			local function add(repo: Repo)
				local key = runtime.repoKey(repo)
				if not seen[key] then seen[key] = true; table.insert(candidates, repo) end
			end
			for line in remotes.stdout:gmatch("[^\n]+") do
				local url = line:match("^%S+%s+(%S+) %(%s*fetch%)%s*$")
				local candidate = if url then parseRemote(url) else nil
				if candidate then add(candidate) end
			end
			local pending = #candidates
			if pending == 0 then
				done(checkout, {}, "该 checkout 无可识别的 GitHub remote。设置 remote 或选择其他 checkout。")
				return
			end
			local discoveryError: string? = nil
			local failed: { [string]: boolean } = {}
			for index = 1, pending do
				local repo = candidates[index]
				exec({ "gh", "api", "--hostname", repo.host, "repos/" .. repo.owner .. "/" .. repo.name,
					"--jq", "{full_name,parent:.parent.full_name}" }, nil, function(raw, requestErr)
					if not alive() then return end
					local data, parseErr = runtime.json(raw, requestErr)
					if not data then
						discoveryError = parseErr
						failed[runtime.repoKey(repo)] = true
					else
						local parent = if type(data.parent) == "string" then parseRemote("https://" .. repo.host .. "/" .. data.parent) else nil
						if parent then add(parent) end
					end
					pending -= 1
					if pending == 0 then
						table.sort(candidates, function(a, b) return runtime.repoKey(a) < runtime.repoKey(b) end)
						done(checkout, candidates, if #candidates == 1 and failed[runtime.repoKey(candidates[1])] then discoveryError else nil)
					end
				end)
			end
		end)
	end)
end

local function who(value: string, viewer: string): string
	return if value:lower() == "@me" then viewer else value:gsub("^@", ""):lower()
end

local function ciStatus(item: any): string
	local node = item.commits and item.commits.nodes and item.commits.nodes[1]
	local commit = node and node.commit
	if not commit or not item.headRefOid or commit.oid ~= item.headRefOid then return "unknown" end
	local rollup = commit.statusCheckRollup
	if not rollup or (rollup.contexts and rollup.contexts.totalCount == 0) then return "none" end
	local status = rollup.state
	if status == "SUCCESS" then return "success" end
	if status == "FAILURE" or status == "ERROR" then return "failure" end
	if status == "PENDING" or status == "EXPECTED" then return "pending" end
	return "unknown"
end

local function includes(connection: any, matches: (any) -> boolean): boolean?
	if type(connection) ~= "table" or type(connection.nodes) ~= "table" then return nil end
	for _, entry in connection.nodes do
		if type(entry) == "table" and matches(entry) then return true end
	end
	if type(connection.pageInfo) == "table" and connection.pageInfo.hasNextPage == false then return false end
	return nil
end

local function unresolved(entry: any): boolean
	return entry.isResolved == false
end

function github.project(snapshot: any, kind: string, filters: Filters): ({ Row }, number)
	local pr = kind == "pr"
	local viewer = snapshot.viewer:lower()
	local number = if filters.number then tonumber(filters.number) else nil
	local author = if filters.author then who(filters.author, viewer) else nil
	local title = if filters.title then filters.title:lower() else nil
	local label = if filters.label then filters.label:lower() else nil
	local assignee = if filters.assignee then who(filters.assignee, viewer) else nil
	local function labelMatches(entry: any): boolean
		return type(entry.name) == "string" and entry.name:lower() == label
	end
	local function assigneeMatches(entry: any): boolean
		return type(entry.login) == "string" and entry.login:lower() == assignee
	end
	local function reviewerMatches(entry: any): boolean
		local reviewer = entry.requestedReviewer
		return type(reviewer) == "table" and type(reviewer.login) == "string" and reviewer.login:lower() == viewer
	end
	local rows: { Row } = {}
	local uncertain = 0
	for _, item in (if pr then snapshot.prs else snapshot.issues) do
		if filters.number and item.number ~= number then continue end
		if filters.state and item.state ~= filters.state then continue end
		local login = (item.author and item.author.login) or ""
		if author and login:lower() ~= author then continue end
		if title and not item.title:lower():find(title, 1, true) then continue end
		local draft = item.isDraft == true
		if pr then
			if filters.base and item.baseRefName ~= filters.base then continue end
			if filters.draft and draft ~= (filters.draft == "yes") then continue end
			if filters.review and (item.reviewDecision or "none") ~= filters.review then continue end
		end
		local ci = if pr then ciStatus(item) else "none"
		local mergeable = if pr and item.state == "OPEN" then
			(if item.mergeable == "MERGEABLE" or item.mergeable == "CONFLICTING" then item.mergeable else "UNKNOWN") else nil
		if filters.ci and ci ~= filters.ci and ci ~= "unknown" then continue end

		local unknown = filters.ci ~= nil and ci ~= filters.ci
		if label then
			local hasLabel = includes(item.labels, labelMatches)
			if hasLabel == false then continue end
			unknown = unknown or hasLabel == nil
		end
		if assignee then
			if pr then continue end
			local assigned = includes(item.assignees, assigneeMatches)
			if assigned == false then continue end
			unknown = unknown or assigned == nil
		end
		local requested = if pr then includes(item.reviewRequests, reviewerMatches) else false
		if filters.requested then
			if requested ~= nil and requested ~= (filters.requested == "yes") then continue end
			unknown = unknown or requested == nil
		end
		local threads = if pr then includes(item.reviewThreads, unresolved) else false
		if filters.threads then
			if threads ~= nil and threads ~= (filters.threads == "yes") then continue end
			unknown = unknown or threads == nil
		end
		if filters.actionable and threads ~= true and ci ~= "failure" and mergeable ~= "CONFLICTING" then
			local cannotHaveThreads = threads == false or (filters.threads ~= nil and filters.threads ~= "yes")
			if cannotHaveThreads and ci ~= "unknown" and mergeable ~= "UNKNOWN" then continue end
			unknown = true
		end
		if unknown then uncertain += 1; continue end
		local row: Row = {
			number = item.number, title = item.title, state = item.state, updated = item.updatedAt,
			author = login, url = item.url, draft = draft, base = item.baseRefName,
			requested = requested == true, threads = threads == true, ci = ci,
			mergeable = mergeable,
		}
		table.insert(rows, row)
	end
	table.sort(rows, function(a, b)
		if a.updated == b.updated then return a.number > b.number end
		return a.updated > b.updated
	end)
	return rows, uncertain
end

return github
