import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {appendFileSync} from 'node:fs';

// 仅联调使用：转发字节原样不变，只留协议版本、方法、结果类型，不留业务内容或凭据。
const [helper, endpoint, trace] = process.argv.slice(2);
if (!helper || !endpoint || !trace) process.exit(2);
const child = spawn(helper, [endpoint], {stdio: ['pipe', 'pipe', 'inherit']});
const requests = new Map();
const record = value => appendFileSync(trace, JSON.stringify(value) + '\n', {mode: 0o600});
createInterface({input: process.stdin}).on('line', line => {
    const value = JSON.parse(line);
    if (value.id !== undefined) requests.set(value.id, {method: value.method, tool: value.params?.name});
    record({direction: 'request', method: value.method, tool: value.params?.name, protocolVersion: value.params?.protocolVersion});
    child.stdin.write(line + '\n');
}).on('close', () => child.stdin.end());
createInterface({input: child.stdout}).on('line', line => {
    const value = JSON.parse(line);
    const request = requests.get(value.id);
    record({direction: 'response', ...request, protocolVersion: value.result?.protocolVersion,
        isError: value.result?.isError || Boolean(value.error), toolCount: value.result?.tools?.length});
    requests.delete(value.id);
    process.stdout.write(line + '\n');
});
child.on('exit', code => process.exit(code ?? 2));
child.on('error', () => process.exit(2));
process.on('SIGTERM', () => { child.kill(); process.exit(0); });
