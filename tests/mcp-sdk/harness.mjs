import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {access} from 'node:fs/promises';
import {join} from 'node:path';
import {homedir} from 'node:os';

export const auditDir = process.env.MCP_AUDIT_DIR || join(homedir(), 'pt-audit');
export async function startHost() {
    const executable = join(auditDir, 'McpSdkHost');
    await access(executable);
    const child = spawn(executable, [], {stdio: ['pipe', 'pipe', 'pipe'], cwd: '/private/tmp'});
    let nextId = 1;
    const waiters = new Map();
    let errors = '';
    child.stderr.on('data', data => { errors = (errors + data).slice(-8000); });
    const ready = new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('隔离宿主未就绪：' + errors)), 10000);
        child.once('error', reject);
        child.once('exit', code => { clearTimeout(timeout); reject(new Error(`隔离宿主提前退出 ${code}：${errors}`)); });
        createInterface({input: child.stdout}).on('line', line => {
            const value = JSON.parse(line);
            if (value.ready) { clearTimeout(timeout); resolve(value); }
            else if (waiters.has(value.id)) { waiters.get(value.id)(value); waiters.delete(value.id); }
        });
    });
    try {
        const info = await ready;
        return {
            endpoint: info.endpoint,
            command(command, values = {}) {
                const id = nextId++;
                return new Promise((resolve, reject) => {
                    const timeout = setTimeout(() => { waiters.delete(id); reject(new Error(`宿主命令超时：${command}`)); }, 10000);
                    waiters.set(id, value => { clearTimeout(timeout); value.ok ? resolve(value) : reject(new Error(`宿主命令失败：${command}`)); });
                    child.stdin.write(JSON.stringify({id, command, ...values}) + '\n');
                });
            },
            async close() {
                if (child.exitCode !== null) return;
                const ended = new Promise(resolve => child.once('exit', resolve));
                child.stdin.end();
                const timer = setTimeout(() => child.kill('SIGTERM'), 3000);
                await ended;
                clearTimeout(timer);
            }
        };
    } catch (error) { child.kill(); throw error; }
}
