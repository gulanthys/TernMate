import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, link, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const plugin = fileURLToPath(new URL('..', import.meta.url));
const omp = process.env.OMP_BIN ?? 'omp';
const tools = ['ternmate_review_read', 'ternmate_review_files', 'ternmate_review_search'];

function run(args, task, env) {
	return new Promise((resolve, reject) => {
		const child = execFile(omp, args, { cwd: task, env, timeout: 45_000 }, (error, stdout, stderr) => {
			if (error && (error.killed || typeof error.code !== 'number')) { reject(error); return; }
			resolve({ status: error?.code ?? 0, stdout, stderr });
		});
		child.stdin.end();
	});
}

test('review tools are scoped and unavailable without trusted setup', async () => {
	const home = await mkdtemp(join(tmpdir(), 'ternmate-review-test-'));
	let server;
	try {
		const agent = join(home, 'agent');
		const task = join(home, 'task.fixture');
		const worktree = join(task, 'worktree');
		const secret = join(home, 'private', 'host.txt');
		const store = join(task, 'store.git');
		const route = 'app/posts/[slug]';
		const env = { HOME: home, PATH: process.env.PATH, TMPDIR: home, PI_CONFIG_DIR: '.omp', PI_CODING_AGENT_DIR: agent };
		await Promise.all([agent, join(home, 'private'), join(worktree, 'src'), join(worktree, route), join(task, 'session')]
			.map(path => mkdir(path, { recursive: true })));
		await Promise.all([
			writeFile(secret, 'MATCH_HOST_SECRET\n'),
			writeFile(join(worktree, '.git'), 'MATCH_GIT_METADATA\n'),
			writeFile(join(worktree, 'src', 'source.ts'), 'first\nconst value = "MATCH_ALLOWED_SOURCE";\n'),
			writeFile(join(worktree, route, 'page.tsx'), 'MATCH_LITERAL_ROUTE\n'),
			writeFile(join(task, 'review.diff'), 'fixed diff marker\n'),
			writeFile(join(task, 'materials.md'), 'fixed task evidence marker\n'),
			symlink(secret, join(worktree, 'external-file')),
			symlink(join(home, 'private'), join(worktree, 'external-directory')),
		]);
		const gitEnv = { ...env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
		execFileSync('/usr/bin/git', ['init', '--bare', '--template=', store], { cwd: task, env: gitEnv });
		await copyFile(join(store, 'config'), join(task, 'initial-git-config'));
		const gitWithInput = (input, ...args) => execFileSync('/usr/bin/git', [
			`--git-dir=${store}`, `--work-tree=${worktree}`, '-c', 'user.name=Review Fixture', '-c', 'user.email=fixture@example.test',
			'-c', 'core.hooksPath=/dev/null', ...args,
		], { cwd: worktree, env: gitEnv, encoding: 'utf8', input });
		const git = (...args) => gitWithInput(undefined, ...args);
		git('add', '--', 'app', 'src/source.ts', 'external-file', 'external-directory');
		git('commit', '-m', 'Fixture source');
		const first = git('rev-parse', 'HEAD').trim();
		git('update-index', '--add', '--cacheinfo', `160000,${first},submodule`);
		// Stage unsupported paths without requiring the host filesystem to represent them.
		const excluded = gitWithInput('MATCH_EXCLUDED_PATH\n', 'hash-object', '-w', '--stdin').trim();
		gitWithInput(Buffer.concat([
			Buffer.from(`100644 ${excluded}\tsrc/source.ts:2\0`),
			Buffer.from(`100644 ${excluded}\tsrc/not-utf8-`),
			Buffer.from([0xff, 0]),
		]), 'update-index', '-z', '--index-info');
		git('commit', '-m', 'Fixture gitlink and unsupported paths');
		const head = git('rev-parse', 'HEAD').trim();
		await link(secret, join(worktree, 'hardlink'));

		const calls = [
			[tools[0], { evidence: 'review.diff' }, 'fixed diff marker'],
			[tools[0], { evidence: 'materials.md' }, 'fixed task evidence marker'],
			[tools[0], { path: 'src/source.ts', start: 2, lines: 1 }, '2: const value ='],
			[tools[1], { query: '.ts' }, 'src/source.ts'],
			[tools[2], { query: 'MATCH_' }, 'src/source.ts:2:'],
			[tools[0], { path: `${route}/page.tsx` }, '1: MATCH_LITERAL_ROUTE'],
			[tools[1], { path: route, query: '[slug]' }, `${route}/page.tsx`],
			[tools[2], { path: route, query: 'MATCH_LITERAL_ROUTE' }, `${route}/page.tsx:1: MATCH_LITERAL_ROUTE`],
			[tools[2], { query: 'MATCH_EXCLUDED_PATH' }, /No matches.*Excluded 2 regular files/],
			[tools[0], { path: secret }, /plain relative/i],
			[tools[0], { path: '../materials.md' }, /plain relative/i],
			[tools[0], { path: 'xd://bash' }, /plain relative/i],
			[tools[0], { path: 'src/source.ts:2' }, /plain relative/i],
			[tools[0], { path: '.GiT' }, /plain relative/i],
			[tools[0], { path: 'external-file' }, /not accessible/i],
			[tools[0], { path: 'hardlink' }, /not accessible/i],
			[tools[0], { path: 'external-directory/host.txt' }, /not accessible/i],
			[tools[0], { path: 'submodule' }, /not accessible/i],
			[tools[1], { path: '**/src' }, /No matches.*Excluded 2 regular files/],
			[tools[2], { path: 'external-directory', query: 'MATCH_' }, /No matches/i],
			[tools[2], { path: '..', query: 'MATCH_' }, /plain relative/i],
		];
		const id = i => `review_${i}`;
		let requests = 0;
		let captured;
		let results = [];
		server = createServer(async (req, res) => {
			try {
				assert.equal(req.url, '/v1/chat/completions');
				let input = '';
				for await (const chunk of req) input += chunk;
				const body = JSON.parse(input);
				assert.deepEqual(body.tools.map(tool => tool.function.name).sort(), [...tools].sort());
				const i = requests++;
				if (i === 0) {
					// Neither evidence replacement nor a live worktree edit can change the snapshot.
					await rm(join(task, 'materials.md'));
					await symlink(secret, join(task, 'materials.md'));
					await writeFile(join(worktree, 'src', 'source.ts'), 'MATCH_DIRTY_WORKTREE\n');
				}
				results = body.messages.filter(message => message.role === 'tool');
				const send = (delta, finish_reason = null) => res.write(`data: ${JSON.stringify({
					id: 'review-response', object: 'chat.completion.chunk', created: 1, model: body.model,
					choices: [{ index: 0, delta, finish_reason }],
				})}\n\n`);
				res.setHeader('Content-Type', 'text/event-stream');
				send({ role: 'assistant' });
				if (i < calls.length) {
					const [name, args] = calls[i];
					send({ tool_calls: [{ index: 0, id: id(i), type: 'function', function: { name, arguments: JSON.stringify(args) } }] });
					send({}, 'tool_calls');
				} else {
					send({ content: 'Review fixture complete.' });
					send({}, 'stop');
				}
				res.end('data: [DONE]\n\n');
			} catch (error) {
				captured = error;
				res.writeHead(400).end('Review fixture failed');
			}
		});
		server.listen(0, '127.0.0.1');
		await once(server, 'listening');
		await writeFile(join(agent, 'models.yml'), `providers:
  review-fixture:
    baseUrl: http://127.0.0.1:${server.address().port}/v1
    api: openai-completions
    apiKey: local-review-fixture
    models:
      - id: review-test
        name: Review Test
        reasoning: false
        input: [text]
        contextWindow: 128000
        maxTokens: 2048
`);
		await writeFile(join(agent, 'config.yml'), `marketplace:\n  autoUpdate: 'off'\ntelemetry:\n  otlpExportEnabled: false\n`);
		const args = [
			`--cwd=${task}`, `--session-dir=${join(task, 'session')}`, `--config=${join(plugin, 'pr-safety.yml')}`,
			`--config=${join(plugin, 'review-safety.yml')}`, '--no-extensions', '--no-skills', '--no-rules',
			'--no-context-files', '--no-lsp', '--no-prewalk', '--system-prompt=', '--no-tools', `--tools=${tools.join(',')}`,
			`--ternmate-review-head=${head}`, '--model=review-fixture/review-test', '--offline', '--no-title', '--print',
		];
		const trusted = `--trusted-extension=${join(plugin, 'review-guard.ts')}`;
		const good = await run([...args, trusted, 'Review the fixture with the supplied tools.'], task, env);
		if (captured) throw captured;
		assert.equal(good.status, 0, good.stderr);
		assert.match(good.stdout, /Review fixture complete/);
		assert.equal(results.length, calls.length);
		for (const [i, [, , expectation]] of calls.entries()) {
			const message = results.find(item => item.tool_call_id === id(i));
			assert.ok(message, `Missing result ${i}`);
			const output = JSON.stringify(message.content);
			assert.doesNotMatch(output, /MATCH_HOST_SECRET|MATCH_GIT_METADATA|MATCH_DIRTY_WORKTREE|MATCH_EXCLUDED_PATH/);
			if (typeof expectation === 'string') assert.ok(output.includes(expectation), output);
			else assert.match(output, expectation);
		}

		const beforeFailures = requests;
		const badEvidence = await run([...args, trusted, 'Must not start a turn.'], task, env);
		assert.notEqual(badEvidence.status, 0);
		assert.match(badEvidence.stderr, /Missing fixed TernMate review file: materials\.md/);
		const missingGuard = await run([...args, `--trusted-extension=${join(task, 'missing.ts')}`, 'Must not start a turn.'], task, env);
		assert.notEqual(missingGuard.status, 0);
		assert.match(missingGuard.stderr, /Trusted extension/i);
		assert.equal(requests, beforeFailures);
	} finally {
		if (server?.listening) await new Promise(resolve => server.close(resolve));
		await rm(home, { recursive: true, force: true });
	}
});
