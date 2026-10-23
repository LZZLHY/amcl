import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';

const require = createRequire(import.meta.url);
function loadTypeScript() {
  const candidates=[process.env.AMCL_TYPESCRIPT_PATH,process.env.AMCL_ETS_TYPESCRIPT,
    process.env.DEVECO_SDK_HOME ? path.join(process.env.DEVECO_SDK_HOME,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript') : undefined,
    'D:/Huawei/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript','typescript'].filter(Boolean);
  for(const candidate of candidates){try{return require(candidate);}catch(error){if(error.code!=='MODULE_NOT_FOUND')throw error;}}
  throw new Error('TypeScript runtime unavailable; set AMCL_TYPESCRIPT_PATH to the SDK TypeScript package');
}
export const ts = loadTypeScript();
export const root = path.resolve(import.meta.dirname, '..');
const log = {info(){},warn(){},error(){},debug(){}};
/**
 * 仅替换Crypto Kit平台边界，SHA判据和调用顺序仍执行真实生产类。
 * Node摘要只消费Uint8Array有效视图；跨VM的typed array不能用本realm的instanceof拒绝。
 * 异步接口真正让出一轮事件循环；空DataBlob保留当前HCF的拒绝边界，不伪造成功。
 */
export const cryptoFramework = {
  createMd(algorithm) {
    const hash = crypto.createHash(algorithm.toLowerCase().replaceAll('-', ''));
    const update = blob => {
      const data = blob?.data;
      const valid = ArrayBuffer.isView(data) && Object.prototype.toString.call(data) === '[object Uint8Array]';
      if (!valid || data.byteLength === 0) {
        const error = new Error(valid ? 'HCF Md.Update rejects empty DataBlob' : 'Invalid digest DataBlob');
        error.code = valid ? 17630001 : 401;
        throw error;
      }
      hash.update(Buffer.from(data.buffer, data.byteOffset, data.byteLength));
    };
    return {
      updateSync: update,
      async update(blob) { await new Promise(resolve => setImmediate(resolve)); update(blob); },
      digestSync() { return { data: new Uint8Array(hash.digest()) }; },
      async digest() { await new Promise(resolve => setImmediate(resolve)); return { data: new Uint8Array(hash.digest()) }; },
    };
  },
};
export function productionPathPolicy() {
  const filename=path.join(root,'feature_core/src/main/ets/modloader/MavenUtils.ets');
  const source=ts.createSourceFile(filename,fs.readFileSync(filename,'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
  const names=['containsControlCharacter','safeBaseName','safeRelPath'];
  const selected=source.statements.filter(n=>(ts.isFunctionDeclaration(n)&&names.includes(n.name?.text))
    ||(ts.isVariableStatement(n)&&n.declarationList.declarations.every(d=>d.name.getText(source).startsWith('MAX_SAFE_'))));
  const text=selected.map(n=>n.getText(source)).join('\n');
  const js=ts.transpileModule(text,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  const mod={exports:{}};vm.runInNewContext(js,{module:mod,exports:mod.exports},{filename});return mod.exports;
}
export const fileIo = {
  OpenMode:{READ_ONLY:0,WRITE_ONLY:1,READ_WRITE:2,CREATE:fs.constants.O_CREAT,TRUNC:fs.constants.O_TRUNC},
  openSync(p,flags){return {fd:fs.openSync(p,flags)};},closeSync(file){fs.closeSync(typeof file==='number'?file:file.fd);},
  readSync(fd,b,opt){return fs.readSync(fd,new Uint8Array(b),0,opt.length,opt.offset);},
  writeSync(fd,data){return fs.writeSync(fd,typeof data==='string'?data:new Uint8Array(data));},
  statSync:fs.statSync,lstatSync:fs.lstatSync,readTextSync:p=>fs.readFileSync(p,'utf8'),
  listFileSync:fs.readdirSync,mkdirSync(p){fs.mkdirSync(p,{recursive:true});},
  renameSync:fs.renameSync,unlinkSync:fs.unlinkSync,copyFileSync:fs.copyFileSync,fsyncSync:fs.fsyncSync,
};
export const mocks = {
  '@kit.CoreFileKit':{fileIo},
  '@kit.CryptoArchitectureKit':{cryptoFramework},
  '@kit.ArkTS':{util:{TextEncoder:class {encodeInto(value){return new TextEncoder().encode(value);}},TextDecoder:{create(encoding,options){const d=new TextDecoder(encoding,options);return {decodeToString:b=>d.decode(b)};}}}},
  '@kit.BasicServicesKit':{zlib:{ReturnStatus:{OK:0,STREAM_END:1},CompressFlushMode:{FINISH:4},async createZip(){
    let input,state;
    return {async inflateInit2(s,bits){if(bits!==-15)throw new Error('unexpected zlib mode');input=s.nextIn;return 0;},
      async inflate(s){const data=zlib.inflateRawSync(Buffer.from(input),{maxOutputLength:s.availableOut});new Uint8Array(s.nextOut).set(data);state={totalIn:input.byteLength,totalOut:data.length};return 1;},
      async getZStream(){return state;},async inflateEnd(){return 0;}};
  }}},
  '@kit.PerformanceAnalysisKit':{hilog:log},
  commons:{AppLogger:log,LOG_DOMAIN_DOWNLOAD:0},
};
/** 可选调度端口仅控制宿主定时器；默认仍用真实时钟，不替换被测生产决策。 */
export function loader(extra={}, scheduling={}) {
  const cache=new Map();
  const load=relative=>{
    const filename=path.resolve(root,relative);if(cache.has(filename))return cache.get(filename);
    const source=fs.readFileSync(filename,'utf8');
    const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021},reportDiagnostics:true});
    const syntax=(output.diagnostics??[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
    if(syntax.length)throw new Error(filename+': '+syntax.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('\n'));
    const mod={exports:{}};cache.set(filename,mod.exports);
    const requireLocal=name=>{
      // 目录策略是生产函数，沿用每个用例注入的 IO；不复制整合包隔离规则。
      if(name==='commons')return {...mocks.commons,...load('commons/src/main/ets/utils/InstancePaths.ets'),...(extra.commons??{})};
      if(name in extra)return extra[name];if(name in mocks)return mocks[name];
      if(name.startsWith('.'))return load(path.resolve(path.dirname(filename),name+'.ets'));
      throw new Error('Unexpected import '+name+' from '+filename);
    };
    vm.runInNewContext(output.outputText,{module:mod,exports:mod.exports,require:requireLocal,console,setTimeout,clearTimeout,setInterval,clearInterval,
      ...scheduling,Observed:x=>x},{filename});
    cache.set(filename,mod.exports);return mod.exports;
  };return load;
}
