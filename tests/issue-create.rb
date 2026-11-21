# Run with /usr/bin/ruby tests/issue-create.rb; the fixture never reaches GitHub.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.expand_path('../issue-create.rb', __dir__)
STORE = File.expand_path('../maintenance-store.sh', __dir__)
HOST = 'github.example.test'
URL = "https://#{HOST}/org/project"
SCOPE = [HOST, 'repo-id', 'viewer-A'].map { |s| s.unpack1('H*') }.join('-')
DRAFT = { form: 'selected', version: 'main/version', fields: { body: 'approved body' }, title: 'approved title' }

def assert(value, message)
  raise message unless value
end

Dir.mktmpdir('ternmate-issue-test-') do |dir|
  gh = File.join(dir, 'gh')
  File.write(gh, <<~'FAKE')
    #!/usr/bin/ruby
    require 'json'
    dir = ENV.fetch('FIXTURE')
    profile = File.join(dir, 'profile')
    if ARGV == %w[auth token --hostname github.example.test]
      puts File.read(profile)
      exit
    end
    abort unless ARGV == %w[api graphql --hostname github.example.test --method POST --input -]
    token = ENV.fetch('GH_ENTERPRISE_TOKEN') { File.read(profile) }
    abort unless token == ENV['GH_TOKEN']
    account = token.delete_prefix('fixture-credential-')
    req = JSON.parse(STDIN.read)
    if req.fetch('query').include?('mutation')
      abort unless account == 'A' && File.read(profile) == 'fixture-credential-B'
      input = req.dig('variables', 'input')
      abort unless input == { 'repositoryId'=>'repo-id', 'title'=>'approved title', 'body'=>'approved body', 'labelIds'=>['label-id'] }
      File.open(File.join(dir, 'sent'), 'a') { |log| log.puts account }
      exit 1 if File.exist?(File.join(dir, 'lose-receipt'))
      puts JSON.generate(data: { createIssue: { issue: { id: 'issue-id', number: 7, title: input['title'], state: 'OPEN',
        createdAt: '2026-01-01T00:00:00Z', url: 'https://github.example.test/org/project/issues/7',
        repository: { id: 'repo-id' }, author: { id: 'viewer-A', login: 'alice' } } } })
    else
      abort unless req['variables'] == { 'owner'=>'org', 'name'=>'project' }
      # The ambient profile changes after verification but before the mutation.
      File.write(profile, 'fixture-credential-B')
      puts JSON.generate(data: { viewer: { id: "viewer-#{account}", login: account == 'A' ? 'alice' : 'bob' },
        repository: { id: 'repo-id', nameWithOwner: 'org/project', url: 'https://github.example.test/org/project',
          visibility: 'PRIVATE', isFork: false, hasIssuesEnabled: true } })
    end
  FAKE
  File.chmod(0o700, gh)
  env = { 'PATH' => "#{dir}:/usr/bin:/bin", 'FIXTURE' => dir }
  profile = File.join(dir, 'profile')
  sent = File.join(dir, 'sent')
  set_account = ->(account) { File.write(profile, "fixture-credential-#{account}") }
  record = lambda do |slot, part, action, value = nil|
    out, status = Open3.capture2('/bin/sh', STORE, dir, SCOPE, "submit-#{part}-#{slot}", action,
      stdin_data: JSON.generate(value), err: File::NULL)
    assert(status.success?, "store #{action} failed")
    JSON.parse(out)
  end
  request = lambda do |slot|
    value = { host: HOST, owner: 'org', name: 'project', slot: slot, draft: DRAFT,
      title: 'approved title', body: 'approved body', labelIds: ['label-id'],
      identity: { repoId: 'repo-id', viewerId: 'viewer-A', viewer: 'alice', webUrl: URL, visibility: 'PRIVATE', isFork: false } }
    out, err, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, dir, SCOPE, stdin_data: JSON.generate(value), chdir: '/')
    assert(status.success? && err.empty? && !out.include?('fixture-credential-'), 'helper exposed diagnostics or credential')
    out.strip
  end

  record.call(1, 'draft', 'write', DRAFT)
  set_account.call('B')
  assert(request.call(1) == 'identity_changed', 'different current credential accepted')
  assert(record.call(1, 'lock', 'read').nil? && !File.exist?(sent), 'identity mismatch acquired send gate')
  set_account.call('A')
  # Leave the durable record directory usable but make the mirror path unusable.
  File.write(File.join(dir, 'maintenance-mirror-v1'), 'not a directory')
  assert(request.call(1) == 'created', 'verified credential did not survive ambient profile switch')
  revision, revision_status = Open3.capture2('/bin/sh', STORE, dir, SCOPE, 'snapshot', 'mirror-revision')
  assert(revision_status.success? && revision.strip == 'r1', 'saved receipt did not advance the result version')
  receipt = record.call(1, 'result', 'read')
  assert(receipt.dig('issue', 'authorId') == 'viewer-A' && receipt.dig('issue', 'number') == 7, 'receipt is not tied to approved identity')
  assert(File.readlines(sent, chomp: true) == ['A'], 'issued under a different identity')

  record.call(2, 'draft', 'write', DRAFT.merge(title: 'other panel edit'))
  set_account.call('A')
  assert(request.call(2) == 'draft_changed' && record.call(2, 'lock', 'read').nil?, 'unsent draft not recoverable')

  record.call(3, 'draft', 'write', DRAFT)
  FileUtils.touch(File.join(dir, 'lose-receipt'))
  set_account.call('A')
  assert(request.call(3) == 'unknown' && record.call(3, 'lock', 'read')['kind'] == 'attempt', 'lost receipt not preserved')
  set_account.call('A')
  assert(request.call(3) == 'locked' && File.readlines(sent, chomp: true) == %w[A A], 'unknown mutation was repeated')
end
puts 'Pinned Issue identity, recoverable preflight failure, receipt, and unknown-send gate passed.'
