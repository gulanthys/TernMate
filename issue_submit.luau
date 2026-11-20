--!strict

local runtime = require("./runtime")
local ui = tern.ui

type Callback = (any, string?) -> ()
type Field = {
	kind: string, id: string, label: string, description: string?, placeholder: string?,
	value: string?, required: boolean?, options: {string}?, default: number?, render: string?,
}
type Form = { id: string, version: string, name: string, description: string?, prefix: string, fields: {Field}, labels: {string}, blank: boolean? }
type Draft = { form: string, version: string, title: string, fields: {[string]: string} }
type Editor = {field: string, text: string, caret: number, multiline: boolean, placeholder: string?}
local submit = {}

local repository = "repository(owner:$owner,name:$name)"
local repoArgs = "$owner:String!,$name:String!"
local identityFields = "id nameWithOwner url visibility hasIssuesEnabled isFork parent{id} defaultBranchRef{name target{oid}}"
local issueFields = "id number url title state createdAt author{login}"
local templateQuery = "query(" .. repoArgs .. [=[,$dir:String!,$root:String!,$dot:String!,$docs:String!){
 viewer{login}
 ]=] .. repository .. "{" .. identityFields .. [=[
 viewerPermission
 dir:object(expression:$dir){oid ... on Tree{entries{name mode object{oid ... on Blob{byteSize isBinary isTruncated text}}}}}
 root:object(expression:$root){oid}
 dot:object(expression:$dot){oid}
 docs:object(expression:$docs){oid}
 }}]=]

-- Parse untrusted YAML as data without aliases, custom tags, duplicate keys or multiple documents.
-- Ruby/Psych is a local parser, never a repo script; if unavailable, use GitHub's chooser.
local yamlParser = [=[
require 'json'
require 'yaml'
def check(n, depth = 0)
  raise ArgumentError if depth > 24 || n.tag || n.is_a?(Psych::Nodes::Alias)
  if n.is_a?(Psych::Nodes::Mapping)
    keys = n.children.each_slice(2).map do |pair|
      k = pair.first
      raise ArgumentError unless k.is_a?(Psych::Nodes::Scalar) && k.value != '<<'
      k.value
    end
    raise ArgumentError unless keys.uniq.size == keys.size
  end
  (n.children || []).each { |child| check(child, depth + 1) }
end
files = JSON.parse(STDIN.read)
puts JSON.generate(files.transform_values do |text|
  begin
    ast = Psych.parse_stream(text)
    raise ArgumentError unless ast.children.size == 1
    check(ast.children.first.root)
    parsed = YAML.safe_load(text)
    parsed.is_a?(Hash) ? parsed : nil
  rescue StandardError
    nil
  end
end)
]=]

local function object(value: any, keys: {[string]: boolean}): boolean
	if type(value) ~= "table" then return false end
	for key in value do if not keys[key] then return false end end
	return true
end

local function array(value: any, limit: number): boolean
	if type(value) ~= "table" or #value > limit then return false end
	local count = 0
	for k in value do
		if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > #value then return false end
		count += 1
	end
	return count == #value
end

local function optionalString(value: any, limit: number, multiline: boolean?): boolean
	if value == nil then return true end
	if type(value) ~= "string" or #value > limit or not utf8.len(value) then return false end
	return not (if multiline then value:find("[%z\1-\8\11-\31\127]") else value:find("%c"))
end

local readFormKeys = {name=true, description=true, title=true, labels=true, body=true}
local entryKeys = {type=true, id=true, attributes=true, validations=true}
local commonAttributes = {label=true, description=true, placeholder=true, value=true}
local textareaAttributes = {label=true, description=true, placeholder=true, value=true, render=true}
local dropdownAttributes = {label=true, description=true, options=true, default=true, multiple=true}
local function attachmentGuidance(text: string?): boolean
	local content = (text or ""):lower()
	return content:find("附件", 1, true) ~= nil or content:find("截图", 1, true) ~= nil
		or content:find("上传", 1, true) ~= nil or content:find("attachment", 1, true) ~= nil
		or content:find("screenshot", 1, true) ~= nil or content:find("%f[%a]upload") ~= nil
		or content:find("%f[%a]attach%f[%A]") ~= nil
end

local function readForm(id: string, version: string, value: any): Form?
	if not object(value, readFormKeys) or type(value.name) ~= "string" or not optionalString(value.name, 256)
		or not optionalString(value.description, 512) or not optionalString(value.title, 256)
		or not array(value.body, 50) or #value.body == 0 then return nil end
	if runtime.trim(value.name) == "" or attachmentGuidance(value.description) then return nil end
	local labels = value.labels or {}
	if not array(labels, 15) then return nil end
	local labelSet = {}
	for _, label in labels do
		-- gh's --label uses CSV parsing. Only exact, unambiguous names are allowed.
		if type(label) ~= "string" or not optionalString(label, 100) or label == "" or label ~= runtime.trim(label)
			or label:find('[,"]') or labelSet[label:lower()] then return nil end
		if label:lower() == "triaged" or label:lower():match("^roost:") then return nil end
		labelSet[label:lower()] = true
	end
	local fields: {Field} = {}
	local seenIds, seenLabels = {}, {}
	for _, item in value.body do
		if not object(item, entryKeys) then return nil end
		local kind, attrs, validation = item.type, item.attributes, item.validations
		if kind == "markdown" then
			if item.id ~= nil or validation ~= nil or not object(attrs, {value=true}) or type(attrs.value) ~= "string"
				or not optionalString(attrs.value, 16000, true) or attachmentGuidance(attrs.value) then return nil end
			local field: Field = { kind="markdown", id="", label="", value=attrs.value }
			table.insert(fields, field)
			continue
		end
		if kind ~= "input" and kind ~= "textarea" and kind ~= "dropdown" then return nil end
		if type(item.id) ~= "string" or not item.id:match("^[%w_-]+$") or seenIds[item.id] then return nil end
		seenIds[item.id] = true
		local keys = if kind == "input" then commonAttributes elseif kind == "textarea" then textareaAttributes else dropdownAttributes
		if not object(attrs, keys) or type(attrs.label) ~= "string" or not optionalString(attrs.label, 256)
			or runtime.trim(attrs.label) == "" or seenLabels[attrs.label] or not optionalString(attrs.description, 8192, true)
			or not optionalString(attrs.placeholder, 4096, kind == "textarea") or not optionalString(attrs.value, 16000, kind == "textarea") then return nil end
		seenLabels[attrs.label] = true
		if attachmentGuidance(attrs.label) or attachmentGuidance(attrs.description) or attachmentGuidance(attrs.placeholder) then return nil end
		if validation ~= nil and (not object(validation, {required=true})
			or (validation.required ~= nil and type(validation.required) ~= "boolean")) then return nil end
		local options, default = attrs.options, attrs.default
		if kind == "dropdown" then
			if attrs.multiple ~= nil and attrs.multiple ~= false then return nil end
			if not array(options, 50) or #options == 0 then return nil end
			local seen = {}
			for _, label in options do
				if type(label) ~= "string" or label == "" or not optionalString(label, 512) or seen[label] then return nil end
				seen[label] = true
			end
			if default ~= nil and (type(default) ~= "number" or default % 1 ~= 0 or default < 0 or default >= #options) then return nil end
		elseif attrs.render ~= nil and (type(attrs.render) ~= "string" or not attrs.render:match("^[%w_+.-]+$")) then return nil end
		local field: Field = {kind=kind :: string, id=item.id, label=attrs.label, description=attrs.description,
			placeholder=attrs.placeholder, value=attrs.value, required=validation and validation.required,
			options=options, default=default, render=attrs.render}
		table.insert(fields, field)
	end
	if next(seenIds) == nil then return nil end
	return {id=id, version=version, name=value.name, description=value.description, prefix=value.title or "", fields=fields, labels=labels}
end

local function path(repo: runtime.Repo): string
	return repo.owner .. "/" .. repo.name
end

local function repoUrl(repo: runtime.Repo): string
	return "https://" .. repo.host .. "/" .. path(repo)
end

local function numberInUrl(repo: runtime.Repo, url: any): number?
	if type(url) ~= "string" or url:find("[%c%s]") then return nil end
	local base = url:gsub("[?#].*$", ""):gsub("/$", "")
	local prefix, digits = base:match("^(https://.+)/issues/([1-9][0-9]*)$")
	if not prefix or prefix:lower() ~= repoUrl(repo):lower() or not digits or #digits > 9 then return nil end
	return tonumber(digits)
end

local function matchesIdentity(repo: runtime.Repo, identity: any, data: any): boolean
	local r = data.repository
	return type(r) == "table" and r.id == identity.repoId and type(r.nameWithOwner) == "string"
		and r.nameWithOwner:lower() == path(repo):lower() and type(data.viewer) == "table" and data.viewer.login == identity.viewer
end

local function graphql(ctx: any, query: string, vars: {[string]: any}, done: Callback)
	vars.owner, vars.name = ctx.repo.owner, ctx.repo.name
	runtime.exec({"gh", "api", "graphql", "--hostname", ctx.repo.host, "--method", "POST", "--input", "-"},
		{stdin=tern.json.encode({query=query, variables=vars})}, function(raw, err)
			local value, why = runtime.json(raw, err)
			if not value or type(value.data) ~= "table" or (type(value.errors) == "table" and #value.errors > 0) then
				done(nil, why or "GitHub 返回了不完整的查询结果。")
			else done(value.data, nil) end
		end)
end

local function freshIdentity(ctx: any, done: Callback)
	ctx.identity(function(info: any, err: string?)
		if not info or type(info.webUrl) ~= "string" or info.webUrl:lower() ~= repoUrl(ctx.repo):lower()
			or not ({PUBLIC=true, PRIVATE=true, INTERNAL=true})[info.visibility] or type(info.hasIssues) ~= "boolean"
			or type(info.isFork) ~= "boolean" then
			done(nil, err or "无法核对 GitHub 主机、仓库及可见性。")
		else done(info, nil) end
	end)
end

local function eligibleLabels(ctx: any, identity: any, forms: {Form}, canTriage: boolean, done: Callback)
	local names, keys, declarations, selections = {}, {}, {}, {}
	if canTriage then
		for _, form in forms do
			for _, name in form.labels do
				if keys[name] then continue end
				local key = "l" .. (#names + 1)
				keys[name] = key
				table.insert(names, name)
				table.insert(declarations, ",$" .. key .. ":String!")
				table.insert(selections, key .. ":label(name:$" .. key .. "){id name}")
			end
		end
	end
	if #names == 0 or #names > 60 then done({}, nil); return end
	local vars: {[string]: any} = {}
	for _, name in names do vars[keys[name]] = name end
	graphql(ctx, "query(" .. repoArgs .. table.concat(declarations) .. "){viewer{login} " .. repository
		.. "{id nameWithOwner viewerPermission " .. table.concat(selections, " ") .. "}}", vars, function(data, err)
			if not data or not matchesIdentity(ctx.repo, identity, data) then done(nil, err or "标签核对时仓库或账号已变化。"); return end
			local labels = {}
			if ({ADMIN=true, MAINTAIN=true, WRITE=true, TRIAGE=true})[data.repository.viewerPermission] then
				for _, name in names do
					local label = data.repository[keys[name]]
					if type(label) == "table" and label.name == name and type(label.id) == "string" then labels[name] = label.id end
				end
			end
			done(labels, nil)
		end)
end

local function inspect(ctx: any, identity: any, done: Callback)
	if not identity.hasIssues then done(nil, "目标仓库未启用 Issues。保留本地草稿，不提交。"); return end
	local branch = identity.defaultBranch
	if type(branch) ~= "string" then done(nil, "无法核对默认分支；请使用 GitHub 原生入口。"); return end
	local ref = "refs/heads/" .. branch .. ":"
	graphql(ctx, templateQuery, {dir=ref .. ".github/ISSUE_TEMPLATE", root=ref .. "ISSUE_TEMPLATE.md",
		dot=ref .. ".github/ISSUE_TEMPLATE.md", docs=ref .. "docs/ISSUE_TEMPLATE.md"}, function(data, err)
		if not ctx.alive() then return end
		if not data or not matchesIdentity(ctx.repo, identity, data) then done(nil, err or "模板读取期间仓库或账号已变化。"); return end
		local r = data.repository
		if r.hasIssuesEnabled ~= true or r.visibility ~= identity.visibility or r.isFork ~= identity.isFork
			or type(r.defaultBranchRef) ~= "table" or r.defaultBranchRef.name ~= branch then
			done(nil, "模板读取期间目标仓库设置已变化。"); return
		end
		local menu: any = {forms={}, native={}, contacts={}, branch=branch, parentId=if type(r.parent) == "table" then r.parent.id else nil}
		local legacy = type(r.root) == "table" or type(r.dot) == "table" or type(r.docs) == "table"
		if legacy then table.insert(menu.native, "此仓库有旧式 Markdown 模板；请在 GitHub 查看。") end
		local dir = r.dir
		if type(dir) ~= "table" or type(dir.entries) ~= "table" or type(dir.oid) ~= "string" then
			table.insert(menu.native, "没有可确认的仓库级表单配置；可能使用上游默认入口。")
			done(menu, nil); return
		end
		local sources, versions, entries = {}, {}, {}
		local configExists, alternateConfig, unreadable, total = false, false, false, 0
		for _, item in dir.entries do
			if type(item) ~= "table" or type(item.name) ~= "string" then unreadable = true; continue end
			local name = item.name
			if name:lower() == "config.yml" or name:lower() == "config.yaml" then
				configExists = true
				if name ~= "config.yml" then alternateConfig = true end
			end
			if name == "config.yml" or name:lower():match("%.ya?ml$") then
				local blob = item.object
				if (item.mode == 33188 or item.mode == 33261) and type(blob) == "table" and type(blob.text) == "string" and type(blob.oid) == "string"
					and blob.isBinary == false and blob.isTruncated == false and blob.byteSize == #blob.text and #blob.text <= 65536 then
					total += #blob.text
					sources[name], versions[name] = blob.text, blob.oid
					table.insert(entries, name)
				else
					unreadable = true
					table.insert(menu.native, name .. "：无法完整读取；使用 GitHub 原生入口。")
				end
			elseif name:lower():match("%.md$") then
				table.insert(menu.native, name .. "：Markdown 模板在 GitHub 填写。")
			elseif item.mode == 40960 or item.mode == 57344 then
				unreadable = true
			end
		end
		if #entries > 50 or total > 262144 then done(nil, "模板过多或超出读取上限；请使用 GitHub 原生入口。"); return end
		if #entries == 0 then
			table.insert(menu.native, "未确认空白入口；使用 GitHub 原生入口。")
			done(menu, nil); return
		end
		table.sort(entries)
		-- Do not run with the checkout as cwd or inherit Ruby code-loading overrides.
		runtime.exec({"/usr/bin/ruby", "-e", yamlParser}, {stdin=tern.json.encode(sources), cwd="/", env={RUBYOPT="", RUBYLIB="", BUNDLE_GEMFILE="", GEM_HOME="", GEM_PATH=""}}, function(raw, parserError)
			if not ctx.alive() then return end
			local parsed = runtime.json(raw, parserError)
			if not parsed then done(nil, "本机无法可靠解析模板 YAML；请使用 GitHub 原生入口。"); return end
			local config = parsed["config.yml"]
			if configExists and (alternateConfig or not object(config, {blank_issues_enabled=true, contact_links=true})
				or (config.blank_issues_enabled ~= nil and type(config.blank_issues_enabled) ~= "boolean")
				or (config.contact_links ~= nil and not array(config.contact_links, 30))) then
				table.insert(menu.native, "无法等价呈现仓库的模板配置；请使用 GitHub 原生入口。")
				done(menu, nil); return
			end
			if configExists then
				for _, contact in config.contact_links or {} do
					if not object(contact, {name=true, url=true, about=true}) or type(contact.name) ~= "string"
						or not optionalString(contact.name, 512) or type(contact.about) ~= "string" or not optionalString(contact.about, 2048, true)
						or type(contact.url) ~= "string" or not optionalString(contact.url, 2048) then
						table.insert(menu.native, "联系渠道含有无法验证的配置；请使用 GitHub 原生入口。")
						done(menu, nil); return
					end
					table.insert(menu.contacts, contact)
				end
			end
			local forms: {Form} = {}
			local scopeVersion = branch .. "\n" .. dir.oid .. "\n" .. (menu.parentId or "")
			for _, name in entries do
				if name == "config.yml" then continue end
				local form = readForm(name, scopeVersion .. "\n" .. versions[name], parsed[name])
				if form then table.insert(forms, form)
				else table.insert(menu.native, name .. "：存在本地编辑器不支持的字段或管理操作；请在 GitHub 填写。") end
			end
			local permission = r.viewerPermission
			eligibleLabels(ctx, identity, forms, ({ADMIN=true, MAINTAIN=true, WRITE=true, TRIAGE=true})[permission] == true, function(labelIds, labelError)
				if not ctx.alive() then return end
				for _, form in forms do
					local ids = {}
					for _, label in form.labels do if labelIds and labelIds[label] then table.insert(ids, labelIds[label]) end end
					if #ids == #form.labels then
						form.version ..= "\n" .. table.concat(ids, ",")
						table.insert(menu.forms, form)
					else table.insert(menu.native, form.name .. "：无法按模板安全应用标签；请在 GitHub 填写。") end
				end
				if labelError then table.insert(menu.native, labelError) end
				if not legacy and not unreadable and configExists and config.blank_issues_enabled == true then
					table.insert(menu.forms, {id="blank", version=scopeVersion, name="空白 Issue", prefix="", fields={}, labels={}, blank=true})
				elseif configExists and config.blank_issues_enabled == false then
					table.insert(menu.native, "仓库已禁用空白 Issue。")
				end
				done(menu, nil)
			end)
		end)
	end)
end

local function fieldValue(draft: Draft, field: Field): string
	return draft.fields[field.id] or (if field.options and field.default ~= nil then field.options[field.default + 1] else field.value) or ""
end

local function payload(draft: Draft, form: Form): (string?, string?, string?)
	local suffix = runtime.trim(draft.title)
	local title = form.prefix .. suffix
	if suffix == "" or not optionalString(title, 256) then return nil, nil, "填写有效的标题（最多 256 字节，不含换行）。" end
	if form.blank then return title, draft.fields.body or "", nil end
	local sections = {}
	for _, field in form.fields do
		if field.kind == "markdown" then continue end
		local answer = fieldValue(draft, field)
		local empty = runtime.trim(answer) == ""
		if field.required and empty then return nil, nil, "请填写必填项：「" .. field.label .. "」。" end
		if field.options and answer ~= "" and not table.find(field.options, answer) then
			return nil, nil, "请选择模板列出的选项：「" .. field.label .. "」。"
		end
		if empty then answer = "_No response_"
		elseif field.render then
			local len = 3
			for run in answer:gmatch("`+") do len = math.max(len, #run + 1) end
			local fence = string.rep("`", len)
			answer = fence .. field.render .. "\n" .. answer .. "\n" .. fence
		end
		table.insert(sections, "### " .. field.label .. "\n\n" .. answer)
	end
	local body = table.concat(sections, "\n\n")
	if #body > 60000 then return nil, nil, "正文超出本地 Issue 编辑器限制。" end
	return title, body, nil
end

local function receiptIssue(ctx: any, identity: any, url: string, done: Callback)
	local number = numberInUrl(ctx.repo, url)
	if not number then done(nil, "只接受当前目标仓库的 HTTPS Issue URL（不是 PR）。"); return end
	graphql(ctx, "query(" .. repoArgs .. ",$number:Int!){viewer{login} " .. repository
		.. "{id nameWithOwner issueOrPullRequest(number:$number){__typename ... on Issue{" .. issueFields .. "}}}}", {number=number}, function(data, err)
			if not data or not matchesIdentity(ctx.repo, identity, data) then done(nil, err or "回查期间仓库或账号已变化。"); return end
			local i = data.repository.issueOrPullRequest
			if type(i) ~= "table" or i.__typename ~= "Issue" or i.number ~= number or numberInUrl(ctx.repo, i.url) ~= number
				or type(i.id) ~= "string" or type(i.title) ~= "string" or type(i.createdAt) ~= "string"
				or (i.state ~= "OPEN" and i.state ~= "CLOSED") then
				done(nil, "未能确认此链接是目标仓库内的 Issue。")
			else done({id=i.id, number=i.number, url=i.url, title=i.title, state=i.state,
				author=if type(i.author)=="table" then i.author.login else nil, createdAt=i.createdAt}, nil) end
		end)
end

local function duplicates(ctx: any, identity: any, words: string, done: Callback)
	-- Only a single literal title phrase crosses the network, not the draft or ad hoc qualifiers.
	if #words > 200 or words:find('["\\%c]') then done(nil, "标题关键词最多 200 字节，不能包含引号、反斜杠或控制字符。"); return end
	local phrase = 'repo:' .. path(ctx.repo) .. ' is:issue in:title "' .. words .. '"'
	graphql(ctx, "query(" .. repoArgs .. ",$phrase:String!){viewer{login} " .. repository
		.. "{id nameWithOwner} search(query:$phrase,type:ISSUE,first:30){issueCount pageInfo{hasNextPage} nodes{ ... on Issue {"
		.. issueFields .. " repository{id} } }}}", {phrase=phrase}, function(data, err)
			local result = data and data.search
			if not data or not matchesIdentity(ctx.repo, identity, data) or type(result) ~= "table" or type(result.nodes) ~= "table"
				or type(result.pageInfo) ~= "table" or type(result.pageInfo.hasNextPage) ~= "boolean" then
				done(nil, err or "没有获得完整的标题搜索响应。"); return
			end
			local found = {}
			for _, issue in result.nodes do
				if type(issue) == "table" and type(issue.repository) == "table" and issue.repository.id == identity.repoId
					and numberInUrl(ctx.repo, issue.url) == issue.number and type(issue.number) == "number"
					and type(issue.title) == "string" and (issue.state == "OPEN" or issue.state == "CLOSED") then table.insert(found, issue) end
			end
			done({rows=found, partial=result.pageInfo.hasNextPage or #found ~= #result.nodes}, nil)
		end)
end

local function matchesAttempt(issue: any, attempt: any): boolean
	return issue.title == attempt.title and type(issue.author) == "string" and issue.author:lower() == attempt.viewer:lower()
		and type(issue.createdAt) == "string" and issue.createdAt >= attempt.after and issue.createdAt <= attempt.before
end

local function reconcile(ctx: any, identity: any, attempt: any, done: Callback)
	local found, seen = {}, {}
	local function page(after: string?)
		if not ctx.alive() then return end
		graphql(ctx, "query(" .. repoArgs .. ",$cursor:String){viewer{login} " .. repository
			.. "{id nameWithOwner issues(first:50,after:$cursor,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{"
			.. issueFields .. "}}}}", {cursor=after}, function(data, err)
				if not ctx.alive() then return end
				local list = data and type(data.repository) == "table" and data.repository.issues
				if not data or not matchesIdentity(ctx.repo, identity, data) or type(list) ~= "table"
					or type(list.nodes) ~= "table" or type(list.pageInfo) ~= "table" or type(list.pageInfo.hasNextPage) ~= "boolean" then
					done(nil, err or "无法完整核对提交回执。"); return
				end
				for _, issue in list.nodes do
					if type(issue) ~= "table" or type(issue.createdAt) ~= "string" or type(issue.id) ~= "string" or seen[issue.id] then
						done(nil, "Issue 列表发生变化，无法确认本次核对。"); return
					end
					seen[issue.id] = true
					if issue.createdAt < attempt.after then done(found, nil); return end
					local author = if type(issue.author) == "table" then issue.author.login else nil
					if matchesAttempt({title=issue.title, author=author, createdAt=issue.createdAt}, attempt)
						and type(issue.number) == "number" and numberInUrl(ctx.repo, issue.url) == issue.number then table.insert(found, issue) end
				end
				if not list.pageInfo.hasNextPage then done(found, nil); return end
				local cursor = list.pageInfo.endCursor
				if type(cursor) ~= "string" or seen[cursor] then done(nil, "回执扫描游标缺失或重复。"); return end
				seen[cursor] = true
				tern.timer(0, function() page(cursor) end)
			end)
	end
	page(nil)
end

local function text(value: string, tone: string?): Node
	return ui.text({ui.span(value, tone or "muted")})
end

local function button(label: string, action: string, value: (string | number)?, disabled: boolean?): Node
	local id = "submit:" .. action .. (if value ~= nil then "=" .. tostring(value) else "")
	return ui.button(label, {key=id, size="sm", disabled=disabled, actions={click=id}})
end

local function iso(timestamp: number): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp) :: string
end

local function rejected(raw: runtime.Result?): boolean
	-- Everything not known to precede a successful create is ambiguous, even nonzero exits.
	if not raw or raw.timed_out or raw.status == 0 or runtime.trim(raw.stdout) ~= "" then return false end
	local msg = runtime.trim(raw.stderr):lower()
	return msg:match("^graphql: title can't be blank %(createissue%)$") ~= nil
		or msg:match("^graphql: title is too long %(createissue%)$") ~= nil
		or msg:match("^could not create issue: graphql: title can't be blank %(createissue%)$") ~= nil
		or msg:match("^could not create issue: graphql: title is too long %(createissue%)$") ~= nil
		or msg == "title can't be blank"
		or msg:match("^the '[%w_.%/-]+' repository has disabled issues$") ~= nil
end

local function sameDraft(a: any, b: Draft): boolean
	if type(a) ~= "table" or a.form ~= b.form or a.version ~= b.version or a.title ~= b.title or type(a.fields) ~= "table" then return false end
	for k, v in a.fields do if b.fields[k] ~= v then return false end end
	for k, v in b.fields do if a.fields[k] ~= v then return false end end
	return true
end

function submit.new(ctx: any)
	local identity, menu, attempt, result, candidate = nil :: any, nil :: any, nil :: any, nil :: any, nil :: string?
	local draft: Draft? = nil
	local editor: Editor? = nil
	local preview: any = nil
	local slot, serial = 1, 0
	local busy, problem, note = nil :: string?, nil :: string?, nil :: string?
	local mode = "load"
	local keywords = ""
	local searchSerial = 0
	local matches, reconciliation = nil :: any, nil :: any
	local selectedIssue: any = nil
	local templateChoice: Form? = nil
	local controller = {}

	local function store(part: string, op: string, value: any, done: Callback)
		ctx.store("submit-" .. part .. "-" .. slot, op, value, done)
	end

	local function render()
		if ctx.alive() then ctx.render() end
	end

	local function finish(err: string?)
		busy, problem = nil, err
		render()
	end

	local function work(label: string)
		busy, problem, note = label, nil, nil
		render()
	end

	local function getForm(id: string?): Form?
		if not menu then return nil end
		for _, form in menu.forms do if form.id == id then return form end end
		return nil
	end

	local function currentForm(): Form?
		local current = draft
		if not current then return nil end
		local form = getForm(current.form)
		return if form and form.version == current.version then form else nil
	end

	local function clearEditor()
		editor = nil
		local clear: {any} = {"focus", tern.json.null}
		if ctx.alive() then ctx.cx:frame({clear}) end
	end

	local function resetTransient()
		preview, matches, reconciliation, selectedIssue, templateChoice = nil, nil, nil, nil, nil
		keywords = ""
		clearEditor()
	end

	local function loadLocal()
		-- Monotone slots retain the outcome of every attempt. Never reuse a slot or release its lock.
		local function readSlot()
			if not ctx.alive() then return end
			store("next", "read", nil, function(nextSlot, nextErr)
				if not ctx.alive() then return end
				if nextErr then finish(nextErr); return end
				if nextSlot then
					if nextSlot.to ~= slot + 1 then finish("草稿记录不连续，无法继续。"); return end
					slot += 1
					tern.timer(0, readSlot)
					return
				end
				store("lock", "read", nil, function(lock, lockErr)
					if not ctx.alive() then return end
					if lockErr then finish(lockErr); return end
					attempt, result, candidate, draft = lock, nil, nil, nil
					local function readDraft()
						store("draft", "read", nil, function(value, draftErr)
							if not ctx.alive() then return end
							if draftErr then finish(draftErr); return end
							if value and (type(value.form) ~= "string" or type(value.version) ~= "string"
								or type(value.title) ~= "string" or type(value.fields) ~= "table") then
								finish("本地草稿无法读取；未尝试发送。"); return
							end
							draft = value
							mode = if result and result.kind == "rejected" then "rejected"
								elseif lock and lock.kind == "discard" then "discarded"
								elseif lock then "pending"
								elseif draft then "resume" else "edit"
							finish(nil)
						end)
					end
					if not lock or lock.kind == "discard" then readDraft(); return end
					if lock.kind == "external" and type(lock.issue) == "table" then
						result, mode = {kind="receipt", issue=lock.issue}, "receipt"
						finish(nil); return
					end
					if lock.kind ~= "attempt" or type(lock.title) ~= "string" or type(lock.time) ~= "number"
						or type(lock.viewer) ~= "string" or type(lock.after) ~= "string" or type(lock.before) ~= "string" then
						finish("本地提交锁无法读取；不会重新发送。"); return
					end
					store("result", "read", nil, function(savedResult, resultErr)
						if not ctx.alive() then return end
						if resultErr then finish(resultErr); return end
						result = savedResult
						if result and result.kind == "receipt" then mode = "receipt"; finish(nil); return end
						if result and result.kind == "rejected" then readDraft(); return end
						if result then finish("本地提交回执无法读取；不会重新发送。"); return end
						store("candidate", "read", nil, function(savedCandidate, candidateErr)
							if not ctx.alive() then return end
							if candidateErr then finish(candidateErr); return end
							candidate = if savedCandidate then savedCandidate.url else nil
							mode = "pending"
							finish(nil)
						end)
					end)
				end)
			end)
		end
		readSlot()
	end

	local function refresh()
		resetTransient()
		mode, menu, slot = "load", nil, 1
		work("正在核对 GitHub 身份和本地草稿…")
		freshIdentity(ctx, function(info, err)
			if not ctx.alive() then return end
			if not info then identity = nil; finish(err); return end
			identity = info
			inspect(ctx, info, function(discovered, inspectErr)
				if not ctx.alive() then return end
				menu = discovered
				loadLocal()
				if inspectErr then
					-- Local records and verified receipts remain available even when templates cannot be read.
					note = inspectErr
					render()
				end
			end)
		end)
	end

	local function saveDraft(nextDraft: Draft, onDone: (() -> ())?)
		work("正在保存私有草稿…")
		store("lock", "read", nil, function(lock, lockErr)
			if not ctx.alive() then return end
			if lockErr then finish(lockErr); return end
			if lock then refresh(); return end
			store("draft", "write", nextDraft, function(_, writeErr)
				if writeErr then finish(writeErr); return end
				store("lock", "read", nil, function(latest, latestErr)
					if latestErr then finish(latestErr); return end
					if latest and (latest.kind == "discard" or latest.kind == "external") then
						-- An older open panel must not restore a draft after another discards or links it.
						store("draft", "remove", nil, function(_, removeErr)
							if not ctx.alive() then return end
							if removeErr then finish(removeErr) else refresh() end
						end)
					elseif ctx.alive() then
						if latest then refresh(); return end
						draft = nextDraft
						preview = nil
						if onDone then onDone() end
						finish(nil)
					end
				end)
			end)
		end)
	end

	local function choose(form: Form)
		if not draft or draft.form == form.id then
			local old = draft
			saveDraft({form=form.id, version=form.version, title=if old then old.title else "",
				fields=if old then table.clone(old.fields) else {}}, function() templateChoice = nil end)
		else
			saveDraft({form=form.id, version=form.version, title=draft.title, fields={}}, function() templateChoice = nil end)
		end
	end

	local function nextSlot(seed: Draft?)
		work("正在打开下一份本地草稿…")
		local function advance()
			store("next", "create", {to=slot + 1}, function(_, err)
				if not ctx.alive() then return end
				if err then
					store("next", "read", nil, function(value, readErr)
						if not ctx.alive() then return end
						if value and value.to == slot + 1 then refresh() else finish(readErr or err) end
					end)
				else refresh() end
			end)
		end
		if seed then
			local key = "submit-draft-" .. (slot + 1)
			ctx.store(key, "create", seed, function(_: any, err: string?)
				if not ctx.alive() then return end
				if not err then advance(); return end
				-- A second panel may already have seeded the same successor.
				ctx.store(key, "read", nil, function(value: any, readErr: string?)
					if not ctx.alive() then return end
					if value and sameDraft(value, seed) then advance()
					else
						store("next", "read", nil, function(nextValue, nextErr)
							if not ctx.alive() then return end
							if nextValue and nextValue.to == slot + 1 then refresh() else finish(nextErr or readErr or err) end
						end)
					end
				end)
			end)
		else advance() end
	end

	local function discard()
		work("正在丢弃本地草稿…")
		local function remove()
			store("draft", "remove", nil, function(_, err)
				if not ctx.alive() then return end
				if err then finish(err); return end
				draft, mode = nil, "discarded"
				nextSlot(nil)
			end)
		end
		if attempt and attempt.kind == "discard" then remove(); return end
		store("lock", "create", {kind="discard"}, function(_, err)
			if err then if ctx.alive() then refresh() end; return end
			attempt = {kind="discard"}
			remove()
		end)
	end

	local function saveResult(value: any)
		store("result", "create", value, function(_, err)
			if not ctx.alive() then return end
			if err then
				-- An independently verified receipt may already have won the immutable result slot.
				store("result", "read", nil, function(existing, readErr)
					if not ctx.alive() then return end
					if existing then refresh() else mode = "pending"; finish(readErr or err) end
				end)
				return
			end
			result = value
			mode = if value.kind == "receipt" then "receipt" else "rejected"
			finish(nil)
		end)
	end

	local function verifyCandidate(url: string, manual: boolean)
		if not ctx.alive() then return end
		receiptIssue(ctx, identity, url, function(issue, err)
			if not issue then
				if ctx.alive() then mode = "pending"; finish(err or "无法回查回执。") end
				return
			end
			if manual and not matchesAttempt(issue, attempt) then
				finish("Issue 的作者、时间或标题不符合此提交，请核对其他原件。")
				return
			end
			saveResult({kind="receipt", issue=issue})
		end)
	end

	local function sendPrepared(approved: any)
		local now = os.time()
		local lock = {kind="attempt", title=approved.title, form=approved.form.id, version=approved.form.version,
			viewer=identity.viewer, time=now, after=iso(now - 90), before=iso(now + 600)}
		store("lock", "create", lock, function(_, lockErr)
			if lockErr then
				if ctx.alive() then
					store("lock", "read", nil, function(existing, readErr)
						if not ctx.alive() then return end
						if existing then refresh() else finish(readErr or lockErr) end
					end)
				end
				return
			end
			attempt, mode = lock, "pending"
			-- Only this callback can invoke `gh issue create`, and only after the exclusive write.
			store("draft", "read", nil, function(saved, readErr)
				if not ctx.alive() or readErr or not sameDraft(saved, approved.draft) then
					saveResult({kind="rejected", reason=readErr or (if ctx.alive()
						then "草稿在确认后已变化；没有创建。重新预览后再决定。"
						else "面板已关闭，未启动创建请求。")})
					return
				end
				busy = "正在创建一次 Issue…"
				render()
				local argv = {"gh", "issue", "create", "--repo", ctx.repo.host .. "/" .. path(ctx.repo),
					"--title", approved.title, "--body-file", "-"}
				for _, label in approved.form.labels do table.insert(argv, "--label=" .. label) end
				runtime.exec(argv, {stdin=approved.body, cwd="/", timeout_ms=30000}, function(raw, _)
					local url = if raw then runtime.trim(raw.stdout) else ""
					if numberInUrl(ctx.repo, url) then
						-- Persist the URL before attempting network verification, also after panel closure.
						store("candidate", "create", {url=url}, function(_, candidateErr)
							candidate = url
							if not ctx.alive() then return end
							if candidateErr then finish(candidateErr) else verifyCandidate(url, false) end
						end)
					elseif rejected(raw) then
						saveResult({kind="rejected", reason="GitHub 明确拒绝创建。请修改草稿或核对仓库设置。"})
					else
						finish("创建结果未知（可能已经成功）。核对回执，不要重新发送。")
					end
				end)
			end)
		end)
	end

	local function confirm(value: string?)
		local approved = preview
		if mode ~= "preview" or not approved or tonumber(value) ~= approved.serial or editor then return end
		-- Consume the displayed approval before starting any asynchronous work.
		preview, mode = nil, "edit"
		work("正在重新核对身份、模板、标签和本地草稿…")
		freshIdentity(ctx, function(info, err)
			if not ctx.alive() then return end
			if not info then finish(err); return end
			local same = info.repoId == identity.repoId and info.viewer == identity.viewer and info.visibility == identity.visibility
				and info.isFork == identity.isFork and info.hasIssues == true and info.webUrl == identity.webUrl
			identity = info
			if not same then menu = nil; finish("目标身份、权限或可见性已变化；旧确认失效。"); return end
			inspect(ctx, info, function(freshMenu, templateErr)
				if not ctx.alive() then return end
				menu = freshMenu
				local latest = getForm(approved.form.id)
				if not latest or latest.version ~= approved.form.version then
					finish(templateErr or "模板、默认分支或标签已变化；旧确认失效。"); return
				end
				store("draft", "read", nil, function(saved, readErr)
					if not ctx.alive() then return end
					if readErr then finish(readErr); return end
					if not sameDraft(saved, approved.draft) then
						mode, draft = if saved then "resume" else "edit", saved
						finish("本地草稿已在另一面板变化；请重新预览。"); return
					end
					sendPrepared(approved)
				end)
			end)
		end)
	end

	local function previewDraft()
		local form, current = currentForm(), draft
		if not form or not current or editor or not identity or not identity.hasIssues then return end
		local title, body, err = payload(current, form)
		if not title or body == nil then finish(err); return end
		serial += 1
		preview, mode, problem = {serial=serial, draft=current, title=title, body=body, form=form}, "preview", nil
		render()
	end

	local function fieldAt(value: string?): Field?
		local form, i = currentForm(), tonumber(value)
		return if form and i then form.fields[i] else nil
	end

	local function editField(field: string, value: string, multiline: boolean, placeholder: string?)
		editor = {field=field, text=value, caret=#value + 1, multiline=multiline, placeholder=placeholder}
		problem = nil
		render()
		ctx.cx:frame({{"focus", "main.submit-editor.submit-input"}})
	end

	local function applyEditor()
		local current, edit = draft, editor
		if not edit then return end
		local value = edit.text
		if edit.field == "@keywords" then
			keywords, matches = runtime.trim(value), nil
			searchSerial += 1
			clearEditor(); render(); return
		elseif edit.field == "@url" then
			local url = runtime.trim(value)
			if not numberInUrl(ctx.repo, url) then finish("请输入当前目标仓库的 HTTPS Issue URL。"); return end
			selectedIssue = nil
			clearEditor()
			work("正在只读核对 Issue 原件…")
			freshIdentity(ctx, function(info, err)
				if not ctx.alive() then return end
				if not info then finish(err); return end
				receiptIssue(ctx, info, url, function(issue, receiptErr)
					if not ctx.alive() then return end
					if issue and mode == "pending" and not matchesAttempt(issue, attempt) then
						finish("Issue 的作者、时间或标题不符合此提交，请核对其他原件。")
						return
					end
					selectedIssue = issue
					finish(receiptErr)
				end)
			end)
			return
		end
		if not current or not currentForm() or mode ~= "edit" then return end
		local nextDraft = table.clone(current)
		nextDraft.fields = table.clone(current.fields)
		if edit.field == "@title" then nextDraft.title = value else nextDraft.fields[edit.field] = value end
		saveDraft(nextDraft, clearEditor)
	end

	local function checkResult(showSearch: boolean)
		if not attempt or (showSearch and os.time() < attempt.time + 35) then
			finish("请求可能仍在进行。请稍等，刷新本地回执后再核对。"); return
		end
		work("正在只读核对提交回执…")
		freshIdentity(ctx, function(info, err)
			if not ctx.alive() then return end
			if not info then finish(err); return end
			if showSearch then
				reconciliation = nil
				reconcile(ctx, info, attempt, function(found, searchErr)
					if not ctx.alive() then return end
					reconciliation = found
					finish(searchErr)
				end)
			elseif candidate then verifyCandidate(candidate, false)
			else finish("尚无候选 URL。请按作者、时间和标题核对。") end
		end)
	end

	local function openNative()
		work("正在核对 GitHub 原生入口…")
		freshIdentity(ctx, function(info, err)
			if not ctx.alive() then return end
			if not info or not info.hasIssues then finish(err or "该仓库未启用 Issues。"); return end
			ctx.cx:open(repoUrl(ctx.repo) .. "/issues/new/choose")
			note = "网页在 GitHub 打开；没有提交。请核对浏览器登录账号及目标仓库，提交后可关联原件。"
			finish(nil)
		end)
	end

	local function bindExternal()
		local issue = selectedIssue
		if not issue then return end
		selectedIssue = nil
		work("正在保存已验证的原件…")
		store("lock", "create", {kind="external", issue=issue}, function(_, err)
			if err then
				if ctx.alive() then refresh() end
				return
			end
			store("draft", "remove", nil, function(_, removeErr)
				if not ctx.alive() then return end
				result, mode, draft = {kind="receipt", issue=issue}, "receipt", nil
				finish(removeErr)
			end)
		end)
	end

	function controller.event(action: string, value: string?)
		if not ctx.alive() or busy then return end
		if action == "refresh" then refresh(); return end
		if not identity or mode == "load" then return end
		if editor and action ~= "apply" and action ~= "cancel_edit" then return end
		if action == "apply" then applyEditor()
		elseif action == "cancel_edit" then clearEditor(); render()
		elseif action == "resume" and mode == "resume" then mode = "edit"; render()
		elseif action == "confirm" then confirm(value)
		elseif action == "back_edit" and mode == "preview" then preview, mode = nil, "edit"; render()
		elseif action == "discard_ask" and (mode == "resume" or mode == "edit") and draft then mode = "discard_confirm"; render()
		elseif action == "discard_cancel" and mode == "discard_confirm" then mode = "resume"; render()
		elseif action == "discard" and (mode == "discard_confirm" or mode == "discarded") then discard()
		elseif action == "next" and mode == "receipt" then nextSlot(nil)
		elseif action == "revise" and mode == "rejected" then nextSlot(draft)
		elseif action == "receipt_open" and mode == "receipt" and result and numberInUrl(ctx.repo, result.issue.url) then
			ctx.cx:open(result.issue.url)
		elseif action == "receipt_omp" and mode == "receipt" and result and numberInUrl(ctx.repo, result.issue.url) == result.issue.number then
			ctx.open("issue", result.issue.number)
		elseif mode == "pending" then
			if action == "verify" and candidate then checkResult(false)
			elseif action == "reconcile" then checkResult(true)
			elseif action == "reconcile_choose" then
				local number = tonumber(value)
				local issue = if selectedIssue and selectedIssue.number == number then selectedIssue else nil
				if not issue and reconciliation then
					for _, row in reconciliation do if row.number == number then issue = row; break end end
				end
				if issue then
					work("正在回查并保存选定的 Issue…")
					freshIdentity(ctx, function(info, err)
						if not ctx.alive() then return end
						if not info then finish(err); return end
						verifyCandidate(issue.url, true)
					end)
				end
			elseif action == "decline_external" then selectedIssue = nil; render()
			elseif action == "reconcile_url" and os.time() >= attempt.time + 35 then editField("@url", "", false, repoUrl(ctx.repo) .. "/issues/…") end
		elseif mode == "edit" or mode == "resume" then
			if action == "native" then openNative()
			elseif action == "external" then editField("@url", "", false, repoUrl(ctx.repo) .. "/issues/…")
			elseif action == "bind_external" and selectedIssue and tonumber(value) == selectedIssue.number then bindExternal()
			elseif action == "decline_external" then selectedIssue = nil; render()
			elseif mode == "edit" then
				if action == "select_form" and menu then
					local form = menu.forms[tonumber(value) or 0]
					if form and (not draft or draft.form ~= form.id or draft.version ~= form.version) then
						if draft then templateChoice = form; render() else choose(form) end
					end
				elseif action == "replace_form" and templateChoice then choose(templateChoice)
				elseif action == "keep_form" then templateChoice = nil; render()
				elseif action == "keywords" then editField("@keywords", keywords, false, "仅填写要发送的标题关键词")
				elseif action == "search" and keywords ~= "" and tonumber(value) == searchSerial then
					work("正在只读搜索目标仓库的标题…")
					freshIdentity(ctx, function(info, err)
						if not ctx.alive() then return end
						if not info then finish(err); return end
						duplicates(ctx, info, keywords, function(found, searchErr)
							if not ctx.alive() then return end
							matches = found
							finish(searchErr)
						end)
					end)
				elseif action == "search_open" and matches then
					local issue = matches.rows[tonumber(value) or 0]
					if issue and numberInUrl(ctx.repo, issue.url) then ctx.cx:open(issue.url) end
				elseif action == "preview" and not templateChoice then previewDraft()
				elseif currentForm() and draft and not templateChoice then
					local form, current = currentForm() :: Form, draft :: Draft
					if action == "title" then editField("@title", current.title, false, "Issue 标题")
					elseif action == "body" and form.blank then editField("body", current.fields.body or "", true, "正文")
					elseif action == "field" then
						local field = fieldAt(value)
						if field and (field.kind == "input" or field.kind == "textarea") then
							editField(field.id, fieldValue(current, field), field.kind == "textarea", field.placeholder)
						end
					elseif action == "option" then
						local fieldIndex, optionIndex = (value or ""):match("^(%d+):(%d+)$")
						local field, index = fieldAt(fieldIndex), tonumber(optionIndex)
						if field and field.options and index and ((index == 0 and not field.required) or field.options[index]) then
							local nextDraft = table.clone(current)
							nextDraft.fields = table.clone(current.fields)
							nextDraft.fields[field.id] = field.options[index] or ""
							saveDraft(nextDraft, nil)
						end
					end
				end
			end
		end
	end

	function controller.key(key: Key): boolean
		local edit = editor
		if not edit or busy then return false end
		if key.name == "escape" then clearEditor(); render(); return true end
		if (key.ctrl or key.meta) and key.name == "enter" then applyEditor(); return true end
		if key.ctrl or key.meta or key.alt then return false end
		local value, caret = edit.text, edit.caret
		if key.name == "left" then edit.caret = utf8.offset(value, -1, caret) or caret
		elseif key.name == "right" then edit.caret = utf8.offset(value, 2, caret) or #value + 1
		elseif key.name == "home" then edit.caret = 1
		elseif key.name == "end" then edit.caret = #value + 1
		elseif key.name == "backspace" or key.name == "delete" then
			local first = if key.name == "backspace" then utf8.offset(value, -1, caret) or caret else caret
			local last = if key.name == "delete" then utf8.offset(value, 2, caret) or #value + 1 else caret
			edit.text, edit.caret = value:sub(1, first - 1) .. value:sub(last), first
		elseif key.name == "enter" and not edit.multiline then applyEditor(); return true
		elseif key.name == "enter" or (key.text and key.text ~= "") then
			local incoming = if key.name == "enter" then "\n" else key.text or ""
			incoming = if edit.multiline then incoming:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[%z\1-\8\11-\31\127]", "") else incoming:gsub("%c", " ")
			local limit = if edit.multiline then 60000 else 4096
			if #value + #incoming <= limit and utf8.len(incoming) then
				edit.text, edit.caret = value:sub(1, caret - 1) .. incoming .. value:sub(caret), caret + #incoming
			else problem = "输入超出长度限制，或包含无效字符。" end
		else return false end
		render()
		return true
	end

	local function editorView(edit: Editor): Node
		-- The input widget is single-line. Keep full multiline text in Lua; show the caret's current line.
		local before, after = edit.text:sub(1, edit.caret - 1), edit.text:sub(edit.caret)
		local left = before:match("[^\n]*$") or ""
		local right = after:match("^[^\n]*") or ""
		local cursor = 0
		for _, code in utf8.codes(left) do cursor += if code > 0xFFFF then 2 else 1 end
		local nodes: {Node} = {}
		if edit.multiline then
			table.insert(nodes, text("多行正文 · Enter 换行；左右键可跨行；Ctrl/⌘+Enter 保存本地。"))
			if before ~= left then table.insert(nodes, text(before:sub(1, #before - #left))) end
		end
		table.insert(nodes, ui.node("input", {key="submit-input", text=left .. right, cursor=cursor, placeholder=edit.placeholder or "输入内容"}))
		if edit.multiline and after ~= right then table.insert(nodes, text(after:sub(#right + 2))) end
		table.insert(nodes, ui.row({button(if edit.field == "@url" then "验证 URL（只读）" elseif edit.field == "@keywords" then "保存关键词（不联网）" else "保存到本地", "apply", nil, busy ~= nil), button("取消本次编辑", "cancel_edit", nil, busy ~= nil)}))
		return ui.card("", nodes, {key="submit-editor"})
	end

	function controller.view(): {Node}
		local nodes: {Node} = {text("新建 / 关联 Issue", "strong")}
		local disabled = busy ~= nil
		local function add(label: string, action: string, value: (string | number)?)
			table.insert(nodes, button(label, action, value, disabled or editor ~= nil))
		end
		local info = identity
		if info then
			table.insert(nodes, text(ctx.repo.host .. "/" .. path(ctx.repo) .. " · @" .. info.viewer .. " · " .. info.visibility, "strong"))
			if info.isFork then
				local upstream = if type(info.parent) == "table" then info.parent.nameWithOwner else nil
				table.insert(nodes, text("当前目标是 fork；上游：" .. (upstream or "不可见") .. "。不会自动改投上游。"))
			else table.insert(nodes, text("当前目标不是 fork。")) end
		end
		if busy then table.insert(nodes, ui.progress(nil, busy)) end
		if problem then table.insert(nodes, text(problem, "error")) end
		if note then table.insert(nodes, text(note)) end
		if mode == "load" then
			add("重新读取身份和草稿", "refresh", nil)
		elseif mode == "preview" and preview then
			local p = preview
			table.insert(nodes, text("最终预览 · " .. p.form.name .. " · " .. menu.branch, "strong"))
			table.insert(nodes, text("模板版本：" .. p.form.version, "muted code"))
			table.insert(nodes, text(if #p.form.labels > 0 then "模板标签：" .. table.concat(p.form.labels, "、") else "模板标签：无"))
			table.insert(nodes, text("标题：" .. p.title, "strong"))
			table.insert(nodes, text("正文（原样）", "strong"))
			table.insert(nodes, text(if p.body == "" then "（空）" else p.body, "code"))
			table.insert(nodes, text("确认即在上方仓库创建一次。若涉及敏感材料，请返回编辑并改用仓库原生渠道。"))
			add("确认创建一次 Issue", "confirm", p.serial)
			add("取消确认，返回编辑", "back_edit", nil)
		elseif mode == "pending" and attempt then
			table.insert(nodes, text("结果待核对 · " .. attempt.title, "strong"))
			table.insert(nodes, text("尝试时间（UTC）：" .. iso(attempt.time) .. "；没有普通重试。零结果不代表未创建。"))
			if candidate then
				table.insert(nodes, text("未验证的 CLI 回执：" .. candidate, "muted code"))
				add("回查 CLI 回执 URL", "verify", nil)
			end
			add("刷新本地回执", "refresh", nil)
			add("按本仓库、作者、时间和标题只读寻找", "reconcile", nil)
			add("核对我找到的 Issue URL", "reconcile_url", nil)
			if selectedIssue then
				table.insert(nodes, text("已验证原件 #" .. selectedIssue.number .. " · " .. selectedIssue.title, "strong"))
				add("确认绑定 #" .. selectedIssue.number .. " 为回执", "reconcile_choose", selectedIssue.number)
				add("不绑定", "decline_external", nil)
			end
			if reconciliation then
				if #reconciliation == 0 then table.insert(nodes, text("本次扫描没有匹配；仍不得重新发送。")) end
				for _, issue in reconciliation do
					if selectedIssue and issue.number == selectedIssue.number then continue end
					table.insert(nodes, text("#" .. issue.number .. " · " .. issue.state .. " · " .. issue.createdAt .. " · " .. issue.title))
					add("确认绑定 #" .. issue.number .. " 为回执", "reconcile_choose", issue.number)
				end
			end
		elseif mode == "receipt" and result then
			local issue = result.issue
			table.insert(nodes, text("已关联回执 #" .. issue.number .. " · " .. issue.title, "strong"))
			table.insert(nodes, text(issue.url, "muted code"))
			local excluded = if ctx.receiptExcluded then ctx.receiptExcluded(issue) else nil
			if excluded then table.insert(nodes, text("当前筛选不显示此 Issue：" .. excluded .. "。返回时保留筛选。")) end
			add("查看原件", "receipt_open", nil)
			add("在 omp 分析", "receipt_omp", nil)
			table.insert(nodes, ui.button("返回列表", {key="submit-list", size="sm", actions={click="mode=browse"}}))
			add("开始一份新草稿", "next", nil)
		elseif mode == "rejected" and result then
			table.insert(nodes, text(result.reason or "请求没有创建 Issue。", "strong"))
			add("继续编辑原草稿（需重新预览和确认）", "revise", nil)
		elseif mode == "discard_confirm" or mode == "discarded" then
			table.insert(nodes, text("丢弃只删除本地草稿，不向 GitHub 发送请求。"))
			add("确认丢弃草稿", "discard", nil)
			if mode == "discard_confirm" then add("保留草稿", "discard_cancel", nil) end
		elseif mode == "edit" or mode == "resume" then
			if mode == "resume" then
				table.insert(nodes, text("有未提交的私有草稿：" .. (if draft and draft.title ~= "" then draft.title else "未命名"), "strong"))
				add("继续草稿", "resume", nil)
			end
			if draft then add("丢弃草稿…", "discard_ask", nil) end
			add("重新读取模板与本地记录", "refresh", nil)
			if info and info.hasIssues then add("打开 GitHub 原生模板 / 私密联系渠道", "native", nil) end
			add("关联已创建 Issue URL…", "external", nil)
			if selectedIssue then
				table.insert(nodes, text("已验证原件 #" .. selectedIssue.number .. " · " .. selectedIssue.title, "strong"))
				table.insert(nodes, text(selectedIssue.url, "muted code"))
				add("确认绑定原件（不创建）", "bind_external", selectedIssue.number)
				add("不绑定", "decline_external", nil)
			end
			if menu then
				for _, contact in menu.contacts do
					table.insert(nodes, text(contact.name .. " · " .. contact.about .. "（从 GitHub 原生入口选择）"))
				end
				for _, reason in menu.native do table.insert(nodes, text(reason)) end
			end
			if mode == "edit" then
				if menu then
					for i, form in menu.forms do
						add(form.name, "select_form", i)
						if form.description then table.insert(nodes, text(form.description)) end
					end
				end
				local current, form = draft, currentForm()
				if templateChoice then
					table.insert(nodes, text(if current and current.form == templateChoice.id
						then "模板版本已变；采用新版本并保留同名字段，重新检查必填项和枚举。"
						else "更换模板将清空表单字段，保留标题。", "strong"))
					add("确认选用 " .. templateChoice.name, "replace_form", nil)
					add("保留原草稿", "keep_form", nil)
				elseif current and form then
					table.insert(nodes, text("编辑 · " .. form.name .. " · " .. menu.branch, "strong"))
					add("编辑标题…", "title", nil)
					table.insert(nodes, text(form.prefix .. current.title))
					if form.blank then
						add("编辑正文…", "body", nil)
						table.insert(nodes, text(current.fields.body or ""))
					end
					for i, field in form.fields do
						if field.kind == "markdown" then table.insert(nodes, text(field.value or "")); continue end
						local label = field.label .. (if field.required then "（必填）" else "")
						local answer = fieldValue(current, field)
						table.insert(nodes, text(label, "strong"))
						if field.description then table.insert(nodes, text(field.description)) end
						if field.options then
							if not field.required then add((if answer == "" then "✓ " else "") .. "不选", "option", i .. ":0") end
							for j, option in field.options do add((if answer == option then "✓ " else "") .. option, "option", i .. ":" .. j) end
						else
							if answer ~= "" then table.insert(nodes, text(answer))
							elseif field.placeholder then table.insert(nodes, text(field.placeholder)) end
							add("编辑 " .. field.label .. "…", "field", i)
						end
					end
					add("预览最终提交…", "preview", nil)
				elseif current then
					table.insert(nodes, text("原模板不可用或版本已变化：保存的内容仍留在本地，不可直接提交。"))
					table.insert(nodes, text("标题：" .. current.title))
					local ids = {}
					for id in current.fields do table.insert(ids, id) end
					table.sort(ids)
					for _, id in ids do table.insert(nodes, text(id .. "：" .. current.fields[id])) end
				end
				table.insert(nodes, text("疑似重复不是提交限制。避免把敏感词、附件或日志放入搜索。"))
				add("输入可发送的标题关键词…", "keywords", nil)
				if keywords ~= "" then add("同意只读搜索「" .. keywords .. "」", "search", searchSerial) end
				if matches then
					if matches.partial then table.insert(nodes, text("仅展示首批搜索结果，不能据此排除重复。"))
					elseif #matches.rows == 0 then table.insert(nodes, text("当前搜索索引未返回候选，不代表没有重复。")) end
					for i, issue in matches.rows do add("#" .. issue.number .. " · " .. issue.state .. " · " .. issue.title, "search_open", i) end
				end
			end
		end
		if editor then table.insert(nodes, editorView(editor)) end
		return nodes
	end

	refresh()
	return controller
end

return submit
