# One invocation owns credential verification, the durable send gate, and the receipt.
# Never print the credential or forward gh diagnostics. The original account's
# transaction can finish even if the workbench panel is no longer attached.
require 'json'
require 'open3'
require 'time'

VERIFY = <<~GRAPHQL
  query($owner: String!, $name: String!) {
    viewer { id login }
    repository(owner: $owner, name: $name) { id nameWithOwner url visibility isFork hasIssuesEnabled }
  }
GRAPHQL
CREATE = <<~GRAPHQL
  mutation($input: CreateIssueInput!) {
    createIssue(input: $input) {
      issue { id number url title state createdAt repository { id } author { login ... on User { id } } }
    }
  }
GRAPHQL

def complete(outcome)
  puts outcome
  exit
end

def store(root, scope, slot, part, action, value = nil)
  Open3.capture2('/bin/sh', File.join(__dir__, 'maintenance-store.sh'), root, scope,
    "submit-#{part}-#{slot}", action, stdin_data: value.nil? ? '' : JSON.generate(value), err: File::NULL)
end

def graphql(gh, host, env, query, variables)
  out, status = Open3.capture2(env, gh, 'api', 'graphql', '--hostname', host, '--method', 'POST', '--input', '-',
    stdin_data: JSON.generate(query: query, variables: variables), err: File::NULL)
  [JSON.parse(out), status.success?]
rescue JSON::ParserError
  [nil, false]
end

def approved_draft?(root, scope, slot, draft)
  out, status = store(root, scope, slot, 'draft', 'read')
  status.success? ? JSON.parse(out) == draft : nil
rescue JSON::ParserError
  nil
end

send_gate = false
begin
  root, scope = ARGV
  request = JSON.parse(STDIN.read)
  slot = request.fetch('slot')
  host, owner, name = request.values_at('host', 'owner', 'name')
  expected = request.fetch('identity')
  draft = request.fetch('draft')
  title, body = request.values_at('title', 'body')
  labels = request.fetch('labelIds', [])
  raise ArgumentError unless root.start_with?('/') && slot.is_a?(Integer) && slot.positive? &&
    host.match?(/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/) && owner.match?(/\A[a-zA-Z0-9-]+\z/) && name.match?(/\A[a-zA-Z0-9_.-]+\z/) &&
    scope == [host.downcase, expected.fetch('repoId'), expected.fetch('viewerId')].map { |s| s.unpack1('H*') }.join('-') &&
    title.is_a?(String) && body.is_a?(String) && labels.is_a?(Array) && labels.all? { |id| id.is_a?(String) && !id.empty? }

  gh = ENV.fetch('PATH', '/usr/bin:/bin').split(':').concat(%w[/opt/homebrew/bin /usr/local/bin])
    .select { |dir| dir.start_with?('/') }.map { |dir| File.join(dir, 'gh') }.find { |file| File.file?(file) && File.executable?(file) }
  complete('auth_unavailable') unless gh
  env = { 'GH_PROMPT_DISABLED' => '1', 'GH_PAGER' => 'cat', 'GH_DEBUG' => '' }
  # Capture the host's active credential through a private pipe only. Override
  # both gh token families so a later profile switch cannot change the writer.
  token, status = Open3.capture2(env, gh, 'auth', 'token', '--hostname', host, err: File::NULL)
  token = token.chomp
  complete('auth_unavailable') unless status.success? && token.match?(/\A[!-~]+\z/)
  env.merge!('GH_TOKEN' => token, 'GH_ENTERPRISE_TOKEN' => token)

  response, ok = graphql(gh, host, env, VERIFY, owner: owner, name: name)
  data = response&.dig('data')
  complete('auth_unavailable') unless ok && data.is_a?(Hash) && !response['errors']
  viewer, repo = data.values_at('viewer', 'repository')
  complete('identity_changed') unless viewer&.dig('id') == expected['viewerId'] && viewer&.dig('login') == expected['viewer'] &&
    repo&.dig('id') == expected['repoId'] && repo['nameWithOwner']&.casecmp?("#{owner}/#{name}") &&
    repo['url'] == expected['webUrl'] && repo['visibility'] == expected['visibility'] &&
    repo['isFork'] == expected['isFork'] && repo['hasIssuesEnabled'] == true

  unchanged = approved_draft?(root, scope, slot, draft)
  complete('storage_error') if unchanged.nil?
  complete('draft_changed') unless unchanged
  now = Time.now
  attempt = { kind: 'attempt', title: title, form: draft.fetch('form'), version: draft.fetch('version'),
    viewerId: expected['viewerId'], time: now.to_i, after: (now - 90).utc.iso8601, before: (now + 600).utc.iso8601 }
  input = { repositoryId: expected['repoId'], title: title, body: body, labelIds: labels }

  # No durable attempt while the panel is doing asynchronous preparation.
  # After this exclusive gate the mutation may run; interruption is ambiguous.
  send_gate = true
  _, status = store(root, scope, slot, 'lock', 'create', attempt)
  unless status.success?
    out, status = store(root, scope, slot, 'lock', 'read')
    complete(status.success? && JSON.parse(out) ? 'locked' : 'storage_error')
  end
  unless approved_draft?(root, scope, slot, draft)
    _, status = store(root, scope, slot, 'result', 'create',
      { kind: 'rejected', reason: '确认后草稿已变化或不可核对；未发送创建请求。请重新预览。' })
    complete(status.success? ? 'recorded' : 'unknown')
  end
  response, = graphql(gh, host, env, CREATE, input: input)
  issue = response&.dig('data', 'createIssue', 'issue')
  number = issue&.dig('number')
  if number.is_a?(Integer) && number.positive? && issue['id'].is_a?(String) && issue['title'] == title &&
      issue['createdAt'].is_a?(String) && %w[OPEN CLOSED].include?(issue['state']) &&
      issue.dig('repository', 'id') == expected['repoId'] && issue.dig('author', 'id') == expected['viewerId'] &&
      issue['url'] == "#{expected['webUrl']}/issues/#{number}"
    receipt = issue.slice('id', 'number', 'url', 'title', 'state', 'createdAt')
    receipt['author'] = issue.dig('author', 'login')
    receipt['authorId'] = expected['viewerId']
    _, status = store(root, scope, slot, 'result', 'create', { kind: 'receipt', issue: receipt })
    complete(status.success? ? 'created' : 'unknown')
  end
  errors = response&.dig('errors')
  if !issue && errors.is_a?(Array) && errors.length == 1 && errors[0]['path'] == ['createIssue'] &&
      errors[0]['message'].to_s.match?(/\A(?:Title can't be blank|Title is too long)\.?\z/i)
    _, status = store(root, scope, slot, 'result', 'create', { kind: 'rejected', reason: 'GitHub 明确拒绝创建：标题无效。' })
    complete(status.success? ? 'recorded' : 'unknown')
  end
  complete('unknown')
rescue StandardError
  # Never propagate command arguments or remote responses to Tern's logs.
  complete(send_gate ? 'unknown' : 'storage_error')
end
