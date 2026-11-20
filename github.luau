--!strict

local runtime = require("./runtime")
type Repo = runtime.Repo
type Exec = runtime.Exec
export type Filters = { [string]: string }
export type Row = {
	number: number, title: string, state: string, updated: string, author: string, url: string,
	draft: boolean, base: string?, requested: boolean, threads: boolean, ci: string,
}
export type Page = { rows: { Row }, nextCursor: string?, examined: number, uncertain: number, resetAt: string? }

local github = {}
local pageInfo = " pageInfo{hasNextPage endCursor} "
local baseFields = "id number title state updatedAt url author{login}"
local connections = {
	labels = "nodes{name}",
	assignees = "nodes{login}",
	reviewRequests = "nodes{requestedReviewer{... on User{login}}}",
	reviewThreads = "nodes{isResolved}",
}

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

local function graphql(exec: Exec, repo: Repo, query: string, variables: { [string]: any }, allowMissing: boolean,
	done: (any, string?) -> ())
	exec({ "gh", "api", "graphql", "--hostname", repo.host, "--method", "POST", "--input", "-", "--include" },
		{ stdin = tern.json.encode({ query = query, variables = variables }) }, function(raw, err)
			if not raw then done(nil, runtime.failure(raw, err)); return end
			local body = raw.stdout:match("\r?\n\r?\n(.+)")
			local value = if body then runtime.decode(body) else nil
			if allowMissing and value and value.data and value.data.repository and value.errors and #value.errors == 1 then
				local failure = value.errors[1]
				if failure.type == "NOT_FOUND" and failure.path and table.concat(failure.path, ".") == "repository.issueOrPullRequest" then
					done(value.data, nil); return
				end
			end
			if raw.status ~= 0 then done(nil, runtime.failure(raw, err)); return end
			if not value or type(value.data) ~= "table" or (value.errors and #value.errors > 0) then
				done(nil, "GitHub 返回了不完整的查询结果；不能确认筛选结果。")
				return
			end
			done(value.data, nil)
		end)
end

local function connection(name: string, size: number, cursor: string?): string
	return name .. "(first:" .. size .. (if cursor then ",after:" .. cursor else "") .. "){" .. connections[name] .. pageInfo .. "}"
end

local function fields(kind: string, filters: Filters): string
	local result = baseFields
	if filters.label then result ..= " " .. connection("labels", 15) end
	if kind == "issue" then
		if filters.assignee then result ..= " " .. connection("assignees", 15) end
	else
		result ..= " isDraft baseRefName reviewDecision headRefOid commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:1){totalCount}}}}}"
			.. " " .. connection("reviewRequests", 20) .. " " .. connection("reviewThreads", 20)
	end
	return result
end

local function who(value: string, viewer: string): string
	return if value:lower() == "@me" then viewer:lower() else value:gsub("^@", ""):lower()
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

type Match = { node: any, row: Row, hits: { [string]: boolean } }
type Pending = { match: Match, name: string, cursor: string }

function github.list(exec: Exec, repo: Repo, kind: string, filters: Filters, cursor: string?, alive: () -> boolean,
	done: (Page?, string?) -> ())
	local pr = kind == "pr"
	local typename = if pr then "PullRequest" else "Issue"
	local listField = if pr then "pullRequests" else "issues"
	local selectFields = fields(kind, filters)
	local variables: { [string]: any } = { owner = repo.owner, name = repo.name }
	local declarations = "$owner:String!,$name:String!"
	local selection: string
	if filters.number then
		declarations ..= ",$number:Int!"
		variables.number = tonumber(filters.number)
		selection = "issueOrPullRequest(number:$number){__typename ... on " .. typename .. "{" .. selectFields .. "}}"
	else
		declarations ..= ",$after:String"
		variables.after = cursor
		local arguments = "first:20,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}"
		if filters.state then arguments ..= ",states:[" .. filters.state .. "]" end
		if pr and filters.base then
			declarations ..= ",$base:String!"; variables.base = filters.base; arguments ..= ",baseRefName:$base"
		end
		selection = listField .. "(" .. arguments .. "){nodes{" .. selectFields .. "}" .. pageInfo .. "}"
	end
	local repoSelection = if filters.number then "nameWithOwner " .. selection else selection
	local query = "query(" .. declarations .. "){viewer{login} rateLimit{resetAt} repository(owner:$owner,name:$name){" .. repoSelection .. "}}"
	graphql(exec, repo, query, variables, filters.number ~= nil, function(data, err)
		if not alive() then return end
		if not data then done(nil, err); return end
		if not data.repository or not data.viewer or type(data.viewer.login) ~= "string" then
			done(nil, "无法验证仓库和当前 GitHub 账号。检查访问权限后重试。"); return
		end
		local viewer = data.viewer.login
		local nodes: { any }
		local nextCursor: string? = nil
		if filters.number then
			local node = data.repository.issueOrPullRequest
			nodes = if node and node.__typename == typename then { node } else {}
		else
			local page = data.repository[listField]
			if not page or not page.nodes or not page.pageInfo then done(nil, "GitHub 未返回完整分页信息。"); return end
			if page.pageInfo.hasNextPage then
				nextCursor = page.pageInfo.endCursor
				if not nextCursor or nextCursor == cursor then done(nil, "GitHub 列表游标缺失或未推进。"); return end
			end
			nodes = page.nodes
		end
		local matched: { Match } = {}
		local pending: { Pending } = {}
		local incomplete = false
		local function readConnection(match: Match, name: string, value: any, priorCursor: string?)
			if not value or not value.nodes or not value.pageInfo then incomplete = true; return end
			for _, entry in value.nodes do
				if type(entry) ~= "table" then continue end
				local hit = if name == "labels" then entry.name and entry.name:lower() == (filters.label or ""):lower()
					elseif name == "assignees" then entry.login and entry.login:lower() == who(filters.assignee or "", viewer)
					elseif name == "reviewRequests" then entry.requestedReviewer and entry.requestedReviewer.login
						and entry.requestedReviewer.login:lower() == viewer:lower()
					else entry.isResolved == false
				if hit then match.hits[name] = true; return end
			end
			if value.pageInfo.hasNextPage then
				local after = value.pageInfo.endCursor
				if type(after) ~= "string" or after == priorCursor or type(match.node.id) ~= "string" then incomplete = true; return end
				table.insert(pending, { match = match, name = name, cursor = after })
			end
		end
		for _, item in nodes do
			if type(item) ~= "table" or type(item.number) ~= "number" or type(item.title) ~= "string" then incomplete = true; continue end
			local author = (item.author and item.author.login) or ""
			if filters.state and filters.state ~= item.state then continue end
			if filters.author and author:lower() ~= who(filters.author, viewer) then continue end
			if filters.title and not item.title:lower():find(filters.title:lower(), 1, true) then continue end
			if pr then
				if filters.base and filters.base ~= item.baseRefName then continue end
				if filters.draft and (filters.draft == "yes") ~= (item.isDraft == true) then continue end
				if filters.review and filters.review ~= (item.reviewDecision or "none") then continue end
			end
			local row: Row = { number = item.number, title = item.title, state = item.state, updated = item.updatedAt,
				author = author, url = item.url, draft = item.isDraft == true, base = item.baseRefName,
				requested = false, threads = false, ci = if pr then ciStatus(item) else "none" }
			if filters.ci and row.ci ~= filters.ci and row.ci ~= "unknown" then continue end
			local match: Match = { node = item, row = row, hits = {} }
			table.insert(matched, match)
			if filters.label then readConnection(match, "labels", item.labels, nil) end
			if not pr and filters.assignee then readConnection(match, "assignees", item.assignees, nil) end
			if pr then
				readConnection(match, "reviewRequests", item.reviewRequests, nil)
				readConnection(match, "reviewThreads", item.reviewThreads, nil)
			end
		end
		local function finish()
			local rows: { Row } = {}
			local uncertain = 0
			for _, match in matched do
				local row, hits = match.row, match.hits
				if (filters.label and not hits.labels) or (filters.assignee and not hits.assignees) then continue end
				row.requested, row.threads = hits.reviewRequests == true, hits.reviewThreads == true
				if filters.requested and (filters.requested == "yes") ~= row.requested then continue end
				if filters.threads and (filters.threads == "yes") ~= row.threads then continue end
				if filters.ci and row.ci ~= filters.ci then uncertain += 1; continue end
				if filters.actionable and not row.threads and row.ci ~= "failure" then
					if row.ci == "unknown" then uncertain += 1 end
					continue
				end
				table.insert(rows, row)
			end
			done({ rows = rows, nextCursor = nextCursor, examined = #nodes, uncertain = uncertain,
				resetAt = data.rateLimit and data.rateLimit.resetAt }, nil)
		end
		local function more()
			if not alive() then return end
			if incomplete then done(nil, "GitHub 未返回完整的标签、负责人或审查分页信息。"); return end
			if #pending == 0 then finish(); return end
			local batch = pending
			pending = {}
			local args: { [string]: string } = {}
			local vars, selectors = {}, {}
			for index, entry in batch do
				local id, after = "id" .. index, "after" .. index
				args[id], args[after] = entry.match.node.id, entry.cursor
				table.insert(vars, "$" .. id .. ":ID!,$" .. after .. ":String!")
				table.insert(selectors, "n" .. index .. ":node(id:$" .. id .. "){... on " .. typename .. "{"
					.. connection(entry.name, 50, "$" .. after) .. "}}")
			end
			graphql(exec, repo, "query(" .. table.concat(vars, ",") .. "){" .. table.concat(selectors, " ") .. "}", args, false, function(extra, extraErr)
				if not alive() then return end
				if not extra then done(nil, extraErr); return end
				for index, entry in batch do
					local node = extra["n" .. index]
					readConnection(entry.match, entry.name, node and node[entry.name], entry.cursor)
				end
				more()
			end)
		end
		more()
	end)
end

return github
