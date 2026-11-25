#!/usr/bin/env node
/**
 * 有界、只读的游戏进程试验证据采集，不启动/停止应用、不清空 hilog、不修改设备配置。
 * 先确认设备时间，再启动日志流与进程快照；只有日志流收到字节才打印 READY。
 * 原始游戏日志可能含账号信息，只保存在显式本地目录，不能提交或自动上传。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import readline from 'node:readline';

const [sn, destination, durationText = '120'] = process.argv.slice(2);
const duration = Number(durationText);
if (!sn || !destination || !Number.isInteger(duration) || duration < 5 || duration > 300) {
  throw new Error('用法: capture-runtime-process.mjs <device-id> <local-output-directory> [seconds 5..300]');
}
const directory = path.resolve(destination);
fs.mkdirSync(directory, { recursive: true });
// JIT 对照只采集设备时间、进程与日志。沿用维护机 SDK 的默认位置，也支持指定 SDK 根目录。
const sdk = process.env.DEVECO_SDK_HOME || 'D:/Huawei/command-line-tools/sdk';
const hdc = path.join(sdk, 'default/openharmony/toolchains', process.platform === 'win32' ? 'hdc.exe' : 'hdc');
function deviceShell(command) {
  const result = spawnSync(hdc, ['-t', sn, 'shell', command], { encoding: 'utf8', timeout: 10000, windowsHide: true });
  if (result.error && result.error.code !== 'ETIMEDOUT') throw result.error;
  return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '',
    timedOut: result.error?.code === 'ETIMEDOUT' };
}
const deviceTime = deviceShell('date +%Y-%m-%dT%H:%M:%S').stdout.trim();
if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$/.test(deviceTime)) throw new Error('设备时间不可解析: ' + deviceTime);
const anchor = deviceTime.replace('T', ' ');
const summary = { schema: 1, deviceTime, hostStart: new Date().toISOString(), duration,
  bytesReceived: 0, retainedLines: 0, observationFailures: 0, samples: [], ended: '',
  scope: 'read-only bounded capture; unavailable observations are not process death; no rendering verdict' };
const sink = fs.createWriteStream(path.join(directory, 'app-hilog.log'), { flags: 'wx' });
const child = spawn(hdc, ['-t', sn, 'shell', 'hilog -v year -v zone -v msec'],
  { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
let ready = false;
let finished = false;
child.stdout.on('data', chunk => {
  summary.bytesReceived += chunk.length;
  if (!ready) { ready = true; console.log('READY deviceTime=' + deviceTime + ' (hilog bytes observed)'); }
});
const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
lines.on('line', line => {
  const time = line.match(/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d/);
  if (!time || time[0] < anchor || !/com\.amcl\.launcher|GameAbility|GameProcess|MC_LAUNCHER|JVM_LAUNCHER/.test(line)) return;
  summary.retainedLines++;
  sink.write(line + '\n');
});
child.stderr.on('data', chunk => { summary.lastCollectorError = String(chunk).slice(-1000); });
child.on('error', error => { summary.lastCollectorError = error.message; finish('collector-error'); });

// 只保留 AMCL 的 PID/PPID/进程名称，不收集其他应用的进程或窗口信息。
function sample() {
  const result = deviceShell('ps -A -o PID,PPID,NAME');
  // hdc 对设备断开也可能返回状态 0，因此必须看到本命令的完整表头；未知不能记成空进程。
  // 不保存其他应用的进程信息，失败只留有界命令错误，足以区分连接故障与目标已退出。
  if (result.status !== 0 || result.timedOut || !/^\s*PID\s+PPID\s+NAME\s*$/m.test(result.stdout)) {
    summary.observationFailures++;
    summary.samples.push({ at: new Date().toISOString(), available: false, processes: null,
      error: (result.stdout + result.stderr).trim().slice(0, 256) });
    console.log('PROCESS_SAMPLE_UNAVAILABLE retainedLines=' + summary.retainedLines);
    return;
  }
  const processes = result.stdout.split(/\r?\n/).filter(line => /com\.amcl\.launcher(?::game)?\s*$/.test(line));
  summary.samples.push({ at: new Date().toISOString(), available: true, processes });
  console.log('PROCESS_SAMPLE ' + JSON.stringify(processes) + ' retainedLines=' + summary.retainedLines);
}
function finish(reason) {
  if (finished) return;
  finished = true;
  clearInterval(timer);
  clearTimeout(deadline);
  lines.close();
  // 仅终止本脚本启动的 hdc 日志客户端，不终止设备应用或共享 hdc server。
  child.kill();
  summary.ended = reason === 'duration-complete' && summary.observationFailures > 0
    ? 'observation-incomplete' : reason;
  summary.hostEnd = new Date().toISOString();
  sink.end(() => {
    fs.writeFileSync(path.join(directory, 'process-capture.json'), JSON.stringify(summary, null, 2) + '\n');
    console.log('CAPTURE_SAVED ' + directory);
  });
}
const timer = setInterval(sample, 2000);
const deadline = setTimeout(() => finish(ready ? 'duration-complete' : 'no-stream-data'), duration * 1000);
process.on('SIGINT', () => finish('interrupted'));
process.on('SIGTERM', () => finish('interrupted'));
sample();
