/** 隔离平台无关的真实端口握手模块做宿主 TCP 验证，输出必须显式置于工程外。 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = process.argv[2] && path.resolve(process.argv[2]);
if (!output || output === root || output.startsWith(root + path.sep)) throw new Error('Provide an external host test build directory');
const core = path.join(root, 'entry/src/main/cpp/hdc/core');
const lock = fs.readFileSync(path.join(core,'Cargo.lock'),'utf8');
const version = name => {
  const found = new RegExp('name = "' + name + '"\\r?\\nversion = "([^"]+)"').exec(lock);
  if (!found) throw new Error('Missing locked dependency ' + name); return found[1];
};
fs.mkdirSync(path.join(output,'src'),{recursive:true});
const portable = name => name.replaceAll('\\','/');
fs.writeFileSync(path.join(output,'Cargo.toml'), `[package]\nname="amcl-local-probe-test"\nversion="0.1.0"\nedition="2021"\n[dependencies]\n` +
  `tokio={version="=${version('tokio')}",features=["full"]}\nrand="=${version('rand')}"\n` +
  `hdc-protocol={path="${portable(path.join(root,'prebuilt/hdc/muka-rust-hdc/crates/hdc-protocol'))}"}\n`);
fs.writeFileSync(path.join(output,'src/lib.rs'), `#[path="${portable(path.join(core,'src/local_probe.rs'))}"] mod probe;\n`);
execFileSync('cargo',['test','--manifest-path',path.join(output,'Cargo.toml'),'--offline'],{
  stdio:'inherit',env:{...process.env,CARGO_TARGET_DIR:path.join(output,'target')},
});
