// Explicitly loaded from TernMate, never from the PR checkout.
import { spawnSync } from "node:child_process";
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const EVIDENCE = ["materials.md", "review.diff"] as const;
const TOOL_NAMES = ["ternmate_review_read", "ternmate_review_files", "ternmate_review_search"] as const;
const MAX_READ = 1024 * 1024;
const MAX_TREE_BYTES = 16 * 1024 * 1024;
const MAX_SEARCH_FILES = 4000;
const MAX_SEARCH_BYTES = 32 * 1024 * 1024;
const MAX_RESULTS = 60;
const MAX_LINES = 200;
const MAX_COLUMNS = 1000;
const MAX_PARTS = 64;
const oidPattern = "(?:[0-9a-f]{40}|[0-9a-f]{64})";
const oid = new RegExp(`^${oidPattern}$`);
const treeEntry = new RegExp(`^100(?:644|755) blob (${oidPattern}) +([0-9]+)$`);
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
type Blob = { oid: string; size: number };

// Nothing passed by a model is interpreted by OMP's paths, a shell, or Git.
function validSegment(name: string): boolean {
	const folded = name.normalize("NFKC").toLowerCase().replace(/\p{Default_Ignorable_Code_Point}/gu, "");
	return folded !== "" && folded !== "." && folded !== ".." && folded !== ".git" &&
		!/[\\:\p{Cc}\p{Cs}]/u.test(name);
}

function validSourcePath(path: string): boolean {
	if (path.length > 4096) return false;
	const parts = path.split("/");
	return parts.length <= MAX_PARTS && parts.every(validSegment);
}

function sourcePath(path: string, allowRoot: boolean): string {
	if (allowRoot && path === ".") return "";
	if (validSourcePath(path)) return path;
	throw new Error("Use a plain relative source path without traversal, selectors, or URIs.");
}

function fixedFile(directory: string, name: string, maxBytes: number): Buffer {
	if (!constants.O_NOFOLLOW || !constants.O_NONBLOCK) throw new Error("Secure review file access is unavailable.");
	let fd: number;
	try {
		fd = openSync(join(directory, name), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
	} catch {
		throw new Error(`Missing fixed TernMate review file: ${name}`);
	}
	try {
		const data = rawText(fd, maxBytes);
		if (!data) throw new Error(`Unreadable fixed TernMate review file: ${name}`);
		return data;
	} finally {
		closeSync(fd);
	}
}

function pinnedSource(task: string, head: string) {
	const store = join(task, "store.git");
	if (!lstatSync(task).isDirectory() || !lstatSync(store).isDirectory() ||
		!fixedFile(task, "initial-git-config", 64 * 1024).equals(fixedFile(store, "config", 64 * 1024))) {
		throw new Error("The private PR object store is not in its original configuration.");
	}
	for (const path of ["objects/info/alternates", "objects/info/http-alternates", "config.worktree"]) {
		if (lstatSync(join(store, path), { throwIfNoEntry: false })) {
			throw new Error("The private PR object store is not self-contained.");
		}
	}

	// Only fixed plumbing commands, the launch-time OID, and manifest blob OIDs
	// cross this boundary. No model path, query, git config, or environment does.
	function git(args: string[], maxBuffer: number, input?: string): Buffer {
		const proc = spawnSync("/usr/bin/git", [
			"--no-replace-objects", "--no-optional-locks", "-c", "core.hooksPath=/dev/null",
			"-c", "core.fsmonitor=false", `--git-dir=${store}`, ...args,
		], {
			cwd: task, input, maxBuffer, timeout: 8000,
			env: {
				PATH: "/usr/bin:/bin", LC_ALL: "C", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
				GIT_ATTR_NOSYSTEM: "1", GIT_NO_LAZY_FETCH: "1", GIT_ALLOW_PROTOCOL: "",
				GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0",
			},
		});
		if (proc.error || proc.status !== 0) throw new Error("Cannot read the fixed PR snapshot within review limits.");
		return proc.stdout;
	}

	const files = new Map<string, Blob>();
	let excludedPaths = 0;
	// `ls-tree` yields committed paths and types; symlinks and gitlinks are never
	// followed. Live worktree files (including ignored and untracked) are not read.
	const tree = git(["ls-tree", "-rlz", "--full-tree", `${head}^{commit}`], MAX_TREE_BYTES);
	for (let start = 0; start < tree.length;) {
		const end = tree.indexOf(0, start);
		const tab = tree.indexOf(9, start);
		if (end < 0 || tab < 0 || tab >= end) throw new Error("Invalid fixed PR tree record.");
		const match = treeEntry.exec(tree.toString("ascii", start, tab));
		start = end + 1;
		if (!match) continue;
		const size = Number(match[2]);
		if (!Number.isSafeInteger(size)) throw new Error("Invalid fixed PR blob size.");
		let path: string;
		try {
			path = utf8.decode(tree.subarray(tab + 1, end));
		} catch {
			excludedPaths++;
			continue;
		}
		if (!validSourcePath(path)) {
			excludedPaths++;
			continue;
		}
		if (files.has(path)) throw new Error("Duplicate fixed PR file path.");
		files.set(path, { oid: match[1], size });
	}

	function* readBlobs(blobs: Blob[], bytes: number): Generator<Buffer> {
		if (!blobs.length) return;
		const output = git(["cat-file", "--batch"], bytes + blobs.length * 100,
			blobs.map(blob => blob.oid).join("\n") + "\n");
		let at = 0;
		for (const blob of blobs) {
			const newline = output.indexOf(10, at);
			const end = newline + 1 + blob.size;
			if (newline < 0 || output.toString("ascii", at, newline) !== `${blob.oid} blob ${blob.size}` ||
				output[end] !== 10) throw new Error("Invalid fixed PR blob response.");
			yield output.subarray(newline + 1, end);
			at = end + 1;
		}
		if (at !== output.length) throw new Error("Unexpected data in fixed PR blob response.");
	}
	return { files, excludedPaths, readBlobs };
}

function rawText(fd: number, maxBytes: number): Buffer | null {
	const stat = fstatSync(fd);
	// Hard links could expose a file from outside the task; do not read them.
	if (!stat.isFile() || stat.nlink !== 1 || stat.size > maxBytes) return null;
	const data = Buffer.allocUnsafe(stat.size + 1);
	let total = 0;
	while (total < data.length) {
		const count = readSync(fd, data, total, data.length - total, total);
		if (count === 0) break;
		total += count;
	}
	if (total !== stat.size || data.subarray(0, total).includes(0)) return null;
	return data.subarray(0, total);
}

function lineWindow(text: string, start: number, lines: number, column: number): string {
	if (!text) return "[Empty file.]";
	const source = text.split("\n");
	if (source[source.length - 1] === "") source.pop();
	const end = Math.min(start - 1 + lines, source.length);
	const out = [];
	for (let i = start - 1; i < end; i++) {
		const line = source[i];
		const next = column + MAX_COLUMNS;
		const chunk = line.slice(column - 1, next - 1);
		const more = line.length >= next ? ` [more: start=${i + 1}, lines=1, column=${next}]` : "";
		out.push(`${i + 1}: ${chunk}${more}`);
	}
	if (end < source.length) out.push(`[Showing ${start}–${end} of ${source.length} lines; request more by number.]`);
	return out.join("\n") || `[End of file; ${source.length} lines.]`;
}

function result(text: string) {
	return { content: [{ type: "text" as const, text }], details: {} };
}

export default function reviewGuard(omp: ExtensionAPI): void {
	omp.registerFlag("ternmate-review-head", { type: "string", description: "Fixed TernMate PR head" });
	// Extension factories run before extension CLI flags are populated. Bind to
	// the exact original argv, not a runtime cwd or any model-supplied value.
	const cwdArg = process.argv.filter(arg => arg.startsWith("--cwd="));
	const headArg = process.argv.filter(arg => arg.startsWith("--ternmate-review-head="));
	const task = cwdArg[0]?.slice("--cwd=".length);
	const head = headArg[0]?.slice("--ternmate-review-head=".length);
	if (cwdArg.length !== 1 || headArg.length !== 1 || !task || !isAbsolute(task) || !head || !oid.test(head)) {
		throw new Error("Missing fixed TernMate review task or head.");
	}
	const source = pinnedSource(task, head);
	// Snapshot only these exact files. A generated byte-bounded diff can end
	// in an incomplete UTF-8 code point, so decode the evidence with replacement.
	const evidence = new Map(EVIDENCE.map(name => [name, fixedFile(task, name, MAX_READ).toString("utf8")]));

	const z = omp.zod;
	omp.on("tool_call", ({ toolName }) => {
		if (!TOOL_NAMES.some(name => name === toolName)) {
			return { block: true, reason: "This TernMate review only permits the scoped review tools." };
		}
	});

	omp.registerTool({
		name: TOOL_NAMES[0],
		label: "Read PR evidence or source",
		description: "Read UTF-8 lines from a literal relative source path at the pinned PR head, or set evidence to review.diff or materials.md. No absolute paths, URIs, or selectors.",
		approval: "read",
		parameters: z.object({
			path: z.string().optional(),
			evidence: z.enum(EVIDENCE).optional(),
			start: z.number().int().min(1).max(MAX_READ).optional(),
			lines: z.number().int().min(1).max(MAX_LINES).optional(),
			column: z.number().int().min(1).max(MAX_READ).optional(),
		}),
		async execute(_id, { path, evidence: name, start = 1, lines = 120, column = 1 }) {
			if (column !== 1 && lines !== 1) throw new Error("Set lines=1 when reading from a later column.");
			if (name !== undefined) {
				if (path !== undefined) throw new Error("Supply exactly one of path or evidence.");
				const text = evidence.get(name);
				if (text === undefined) throw new Error("Unknown fixed review evidence.");
				return result(lineWindow(text, start, lines, column));
			}
			if (path === undefined) throw new Error("Supply exactly one of path or evidence.");
			const blob = source.files.get(sourcePath(path, false));
			if (!blob) throw new Error("Source file is not accessible in the fixed PR snapshot.");
			if (blob.size > MAX_READ) throw new Error("Source file exceeds the review read limit.");
			for (const data of source.readBlobs([blob], blob.size)) {
				if (!data.includes(0)) return result(lineWindow(utf8.decode(data), start, lines, column));
			}
			throw new Error("Source is not a readable UTF-8 file.");
		},
	});

	function search(path: string, query: string, contents: boolean, signal?: AbortSignal): string {
		const dir = sourcePath(path, true);
		const prefix = dir ? dir + "/" : "";
		const matches: string[] = [];
		const candidates: Blob[] = [];
		const paths: string[] = [];
		let bytes = 0;
		let skipped = 0;
		let limited = false;
		for (const [relative, blob] of source.files) {
			signal?.throwIfAborted();
			if (!relative.startsWith(prefix)) continue;
			if (!contents) {
				if (!relative.includes(query)) continue;
				if (matches.length === MAX_RESULTS) { limited = true; break; }
				matches.push(relative);
				continue;
			}
			if (blob.size > MAX_READ) { skipped++; continue; }
			if (bytes + blob.size > MAX_SEARCH_BYTES || candidates.length === MAX_SEARCH_FILES) { limited = true; break; }
			bytes += blob.size;
			candidates.push(blob);
			paths.push(relative);
		}
		let fileIndex = 0;
		searchLines: for (const data of source.readBlobs(candidates, bytes)) {
			const relative = paths[fileIndex++];
			signal?.throwIfAborted();
			if (data.includes(0)) { skipped++; continue; }
			let text: string;
			try { text = utf8.decode(data); } catch { skipped++; continue; }
			for (const [i, line] of text.split("\n").entries()) {
				const match = line.indexOf(query);
				if (match < 0) continue;
				if (matches.length === MAX_RESULTS) { limited = true; break searchLines; }
				const at = Math.max(0, match - 100);
				matches.push(`${relative}:${i + 1}: ${at ? "…" : ""}${line.slice(at, at + MAX_COLUMNS)}${at + MAX_COLUMNS < line.length ? "…" : ""}`);
			}
		}
		if (matches.length === 0) matches.push("No matches in the scanned fixed PR files.");
		if (limited) matches.push("[Scan reached a limit; narrow the starting directory or query.]");
		if (skipped) matches.push(`[Skipped ${skipped} oversized or non-text files.]`);
		if (source.excludedPaths) matches.push(`[Excluded ${source.excludedPaths} regular files with unsupported or invalid UTF-8 paths across the fixed PR snapshot.]`);
		return matches.join("\n");
	}

	omp.registerTool({
		name: TOOL_NAMES[1],
		label: "Find PR source files",
		description: "List tracked regular files at the pinned PR head below a literal relative directory (default .). Optional query is a literal, case-sensitive substring of the path, not a glob.",
		approval: "read",
		parameters: z.object({ path: z.string().optional(), query: z.string().max(256).optional() }),
		async execute(_id, { path = ".", query = "" }, signal) {
			return result(search(path, query, false, signal));
		},
	});
	omp.registerTool({
		name: TOOL_NAMES[2],
		label: "Search PR source",
		description: "Find a literal, case-sensitive substring in UTF-8 files at the pinned PR head below a literal relative directory (default .). Returns matching line numbers. No regex or glob matching.",
		approval: "read",
		parameters: z.object({ path: z.string().optional(), query: z.string().min(1).max(256) }),
		async execute(_id, { path = ".", query }, signal) {
			return result(search(path, query, true, signal));
		},
	});
}
