import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {join} from 'node:path';
import {readFile} from 'node:fs/promises';
import {auditDir, startHost} from './harness.mjs';

// 测试只使用预先准备的本地依赖；这里绝不触发 npm/npx 或网络安装。
if (Number(process.versions.node.split('.')[0]) < 20) throw new Error('未运行：需要 Node >=20');
let Client, StdioClientTransport;
try {
    const metadata = JSON.parse(await readFile(new URL('./node_modules/@modelcontextprotocol/sdk/package.json', import.meta.url)));
    assert.equal(metadata.version, '1.29.0');
    ({Client} = await import('@modelcontextprotocol/sdk/client/index.js'));
    ({StdioClientTransport} = await import('@modelcontextprotocol/sdk/client/stdio.js'));
} catch (error) { throw new Error('未运行：缺少锁定的 SDK 1.29.0 本地依赖，请先单独准备依赖', {cause: error}); }

// SDK 仍负责生命周期及 AJV 输出校验；仅让 initialize 显式请求待验版本。
class VersionClient extends Client {
    async request(request, ...rest) {
        if (request.method === 'initialize') request = {...request, params: {...request.params, protocolVersion: this.requestedVersion}};
        const result = await super.request(request, ...rest);
        if (request.method === 'initialize') this.negotiatedVersion = result.protocolVersion;
        return result;
    }
}
let calls = 0;
for (const version of ['2025-11-25', '2025-06-18']) {
    const host = await startHost();
    let client;
    try {
        client = new VersionClient({name: 'pomodoro-sdk-audit', version: '1.0.0'});
        client.requestedVersion = version;
        await client.connect(new StdioClientTransport({command: join(auditDir, 'McpTestHelper'), args: [host.endpoint], cwd: '/private/tmp', stderr: 'pipe'}));
        assert.equal(client.negotiatedVersion, version);
        const list = await client.listTools();
        assert.equal(list.tools.length, 10);
        assert(list.tools.every(tool => tool.outputSchema && !('$schema' in tool.outputSchema)));
        const call = async (name, args = {}, errorCode) => {
            const result = await client.callTool({name: 'pomodoro_' + name, arguments: args});
            calls++;
            // 后续所有编号、令牌与会话只消费文本，证明旧式客户端也能完成写入闭环。
            const text = JSON.parse(result.content.find(item => item.type === 'text').text);
            if (errorCode) {
                assert.equal(result.isError, true);
                assert.equal(result.structuredContent, undefined);
                assert.equal(text.code, errorCode);
                assert.equal(text.retryable, false);
            } else {
                assert(!result.isError, JSON.stringify(text));
                assert.deepEqual(text, result.structuredContent);
            }
            return text;
        };
        await call('list_categories', {}, 'APP_UNAVAILABLE');
        await host.command('enable', {value: true});
        const status = await call('get_status');
        const session = status.app.app_session_id;
        assert(session);
        let args = {app_session_id: session, idempotency_key: randomUUID(), title: '隔离联调任务', date: '2026-09-18'};
        await call('create_task', args, 'PERMISSION_DENIED');
        await host.command('write', {value: true});
        const first = await call('create_task', args);
        assert(first.created_task_id > 0);
        const id = first.created_task_id;
        let task = first.task;
        const write = extra => ({task_id: id, app_session_id: session, expected_state_token: task.state_token, ...extra});
        // schema 的码点长度不能代替服务层的 UTF-16 上限；错误必须可被模型识别为参数问题。
        for (const fields of [{title: '   '}, {title: '😀'.repeat(60)}, {notes: '😀'.repeat(1500)}]) {
            await call('create_task', {...args, idempotency_key: randomUUID(), ...fields}, 'VALIDATION_ERROR');
            await call('update_task', write(fields), 'VALIDATION_ERROR');
        }
        const update = write({notes: '仅用于隔离验证', estimated_minutes: 45});
        task = (await call('update_task', update)).task;
        assert.equal((await call('update_task', update)).changed, false);
        await call('update_task', {...update, notes: '陈旧修改'}, 'STATE_CONFLICT');
        await call('update_task', write({notes: null}), 'VALIDATION_ERROR');
        task = (await call('reschedule_task', write({date: '2026-09-19'}))).task;
        task = (await call('set_task_completed', write({completed: true}))).task;
        const replay = await call('create_task', {...args, idempotency_key: args.idempotency_key.toUpperCase()});
        assert.equal(replay.created_task_id, id);
        assert.equal(replay.task.completed, true);
        assert.equal(replay.replayed, true);
        await call('create_task', {...args, title: '不同内容'}, 'IDEMPOTENCY_CONFLICT');
        await host.command('editing', {task_id: id});
        const busy = await call('set_task_completed', write({completed: true}), 'APP_BUSY');
        assert.equal(busy.details.blocks[0].reason, 'editing');
        assert.equal((await call('create_task', args)).created_task_id, id);
        await host.command('end');
        await host.command('pending', {task_id: id});
        await call('get_task', {task_id: id}, 'APP_BUSY');
        assert.equal((await call('create_task', args)).current_state, 'pending_delete');
        assert.equal((await call('list_tasks', {start_date: '2026-09-18', end_date: '2026-09-19'})).count, 0);
        await host.command('end');
        await call('list_categories');
        await call('list_knowledge_gaps', {status: 'unresolved', due_state: 'unscheduled'});
        await call('get_focus_summary', {start_date: '2026-09-18', end_date: '2026-09-19'});
        await host.command('delete', {task_id: id});
        assert.equal((await call('create_task', args)).current_state, 'deleted');
        await host.command('restore');
        await call('create_task', args, 'SESSION_EXPIRED');
        assert.notEqual((await call('get_status')).app.app_session_id, session);
        await host.command('write', {value: false});
        await host.command('enable', {value: false});
        assert.equal((await client.listTools()).tools.length, 10);
        console.log(`${version}：官方 SDK schema 校验、错误码、仅文本读写、重放、阻断与会话轮换通过`);
    } finally { await client?.close(); await host.close(); }
}
console.log(`SDK 1.29.0：两个协议版本，共 ${calls} 次工具调用通过。`);
