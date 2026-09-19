import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {auditDir, startHost} from './harness.mjs';

const version = execFileSync('claude', ['--version'], {encoding: 'utf8'}).trim();
const host = await startHost();
try {
    await host.command('enable', {value: true});
    await host.command('write', {value: true});
    const directory = dirname(host.endpoint);
    const traceFile = join(directory, 'trace.jsonl');
    const configFile = join(directory, 'client.json');
    const key = randomUUID();
    const command = process.execPath;
    const args = [fileURLToPath(new URL('./trace-helper.mjs', import.meta.url)), join(auditDir, 'McpTestHelper'), host.endpoint, traceFile];
    await writeFile(configFile, JSON.stringify({mcpServers: {pomodoro_audit: {type: 'stdio', command, args}}}), {mode: 0o600});
    const prompt = `这是获准执行的隔离 MCP 兼容测试，数据均为临时数据。仅调用 pomodoro_audit 工具，不使用任何其他工具。先查询状态取得真实会话，并查科目、本日任务、专注统计、未解决知识缺口（日期 2026-09-18）。然后创建标题“Claude隔离验收”的任务，日期2026-09-18，创建键${key}。用返回的真实编号和状态令牌修改备注为“兼容验证”、预计分钟为30，再改期到2026-09-19，再设为完成。每次使用最新状态令牌。最后按编号查询确认。需要实际执行全部10种工具，不能只描述计划；全部成功后用一句中文报告结果。`;
    const cliArgs = ['-p', prompt, '--output-format', 'json', '--no-session-persistence', '--strict-mcp-config',
        '--mcp-config', configFile, '--setting-sources', '', '--tools', '', '--allowedTools', 'mcp__pomodoro_audit__*',
        '--permission-mode', 'dontAsk', '--max-budget-usd', '2'];
    const output = await new Promise((resolve, reject) => {
        const child = spawn('claude', cliArgs, {cwd: directory, stdio: ['ignore', 'pipe', 'pipe']});
        let stdout = '', stderr = '';
        child.stdout.on('data', data => { stdout += data; });
        child.stderr.on('data', data => { stderr = (stderr + data).slice(-4000); });
        const timer = setTimeout(() => { child.kill(); reject(new Error('Claude Code 联调超过 180 秒')); }, 180000);
        child.on('error', reject);
        child.on('exit', code => { clearTimeout(timer); code === 0 ? resolve(stdout) : reject(new Error(`Claude Code 退出 ${code}：${stderr || stdout}`)); });
    });
    const result = JSON.parse(output);
    assert(!result.is_error, result.result || result.subtype);
    const trace = (await readFile(traceFile, 'utf8')).trim().split('\n').map(JSON.parse);
    const negotiation = trace.find(value => value.direction === 'response' && value.protocolVersion);
    assert(negotiation);
    const calls = trace.filter(value => value.direction === 'response' && value.method === 'tools/call');
    const expected = ['get_status', 'list_categories', 'list_tasks', 'get_task', 'get_focus_summary', 'list_knowledge_gaps',
        'create_task', 'update_task', 'reschedule_task', 'set_task_completed'].map(name => 'pomodoro_' + name);
    for (const name of expected) assert(calls.some(call => call.tool === name && !call.isError), `未成功调用 ${name}`);
    console.log(JSON.stringify({client: version, protocolVersion: negotiation.protocolVersion,
        successfulTools: expected.length, calls: calls.length, cost: result.total_cost_usd, result: result.result}, null, 2));
} finally { await host.close(); }
