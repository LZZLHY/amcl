import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import zlib from 'node:zlib';
import {createRequire} from 'node:module';

const require = createRequire(import.meta.url);
function loadTypeScript() {
  const candidates=[process.env.AMCL_TYPESCRIPT_PATH,
    process.env.DEVECO_SDK_HOME ? path.join(process.env.DEVECO_SDK_HOME,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript') : undefined,
    'D:/Huawei/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript','typescript'].filter(Boolean);
  for(const candidate of candidates){try{return require(candidate);}catch(error){if(error.code!=='MODULE_NOT_FOUND')throw error;}}
  throw new Error('TypeScript runtime unavailable; set AMCL_TYPESCRIPT_PATH to the SDK TypeScript package');
}
export const ts = loadTypeScript();
export const root = path.resolve(import.meta.dirname, '..');
const log = {info(){},warn(){},error(){},debug(){}};
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
  '@kit.ArkTS':{util:{TextDecoder:{create(encoding,options){const d=new TextDecoder(encoding,options);return {decodeToString:b=>d.decode(b)};}}}},
  '@kit.BasicServicesKit':{zlib:{ReturnStatus:{OK:0,STREAM_END:1},CompressFlushMode:{FINISH:4},async createZip(){
    let input,state;
    return {async inflateInit2(s,bits){if(bits!==-15)throw new Error('unexpected zlib mode');input=s.nextIn;return 0;},
      async inflate(s){const data=zlib.inflateRawSync(Buffer.from(input),{maxOutputLength:s.availableOut});new Uint8Array(s.nextOut).set(data);state={totalIn:input.byteLength,totalOut:data.length};return 1;},
      async getZStream(){return state;},async inflateEnd(){return 0;}};
  }}},
  '@kit.PerformanceAnalysisKit':{hilog:log},
  commons:{AppLogger:log,LOG_DOMAIN_DOWNLOAD:0},
};
export function loader(extra={}) {
  const cache=new Map();
  const load=relative=>{
    const filename=path.resolve(root,relative);if(cache.has(filename))return cache.get(filename);
    const source=fs.readFileSync(filename,'utf8');
    const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021},reportDiagnostics:true});
    const syntax=(output.diagnostics??[]).filter(d=>d.category===ts.DiagnosticCategory.Error);
    if(syntax.length)throw new Error(filename+': '+syntax.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('\n'));
    const mod={exports:{}};cache.set(filename,mod.exports);
    const requireLocal=name=>{
      if(name in extra)return extra[name];if(name in mocks)return mocks[name];
      if(name.startsWith('.'))return load(path.resolve(path.dirname(filename),name+'.ets'));
      throw new Error('Unexpected import '+name+' from '+filename);
    };
    vm.runInNewContext(output.outputText,{module:mod,exports:mod.exports,require:requireLocal,console,setTimeout,clearTimeout,setInterval,clearInterval,Observed:x=>x},{filename});
    cache.set(filename,mod.exports);return mod.exports;
  };return load;
}
