/**
 * 构建期准备公开共享的兼容签名模板，手机更新不再依赖下载第三方安装器。
 * 输入只允许固定公开原件；绝不读取build-profile、个人证书库、登录信息或设备保险库。
 * 生成文件不进Git，stdout只输出大小/摘要；个人签名材料仍只保存在用户本机保险库。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {assertExternalOutputPath} from './lib/workspace-paths.mjs';
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const base='https://raw.githubusercontent.com/likuai2010/auto-installer/690bcba65db1716cfbdfed587f66f20151be1939/flutter/hap_installer/assets/store/';

async function pinnedFile(directory,name,url,size,expected){
 const filename=path.join(directory,name);
 if(fs.existsSync(filename)){
  const bytes=fs.readFileSync(filename);if(bytes.length!==size||hash(bytes)!==expected)throw Error('Cached public template input changed: '+name);return filename;
 }
 const response=await fetch(url,{signal:AbortSignal.timeout(60000)});if(!response.ok||!response.body)throw Error('Public template source unavailable: '+name);
 const reader=response.body.getReader(),parts=[];let total=0;
 try{for(;;){const part=await reader.read();if(part.done)break;total+=part.value.byteLength;if(total>size)throw Error('Public template source exceeds pin');parts.push(Buffer.from(part.value));}}
 catch(error){await reader.cancel().catch(()=>{});throw error;}finally{reader.releaseLock();}
 const bytes=Buffer.concat(parts,total);if(total!==size||hash(bytes)!==expected)throw Error('Public template source pin mismatch: '+name);
 fs.writeFileSync(filename,bytes,{flag:'wx'});return filename;
}

export async function prepareSigningTemplates({root,build,java,classpath}){
 const directory=assertExternalOutputPath(path.join(build,'public-template-inputs'));fs.mkdirSync(directory,{recursive:true});
 const xiaobaiKey=await pinnedFile(directory,'xiaobai-default.pem',base+'key.pem',292,'615e57b759b49848c0538725f3e5add7b7165537e4f02edb62897528f2070aef');
 const xiaobaiCsr=await pinnedFile(directory,'xiaobai-default.csr',base+'xiaobai.csr',497,'6af37d3ed893f096d9e82b2e12f700726bad5104f0f3c3c5ccd210a1a20c6f42');
 let hokitPackage=process.env.AMCL_HOKIT_TEMPLATE_INPUT;
 if(hokitPackage){
  hokitPackage=path.resolve(hokitPackage);const bytes=fs.readFileSync(hokitPackage),digest=hash(bytes);
  if(!((bytes.length===23299388&&digest==='788cb81a52970839f552c5c31eed2ff890c62e310c2b280df9aa6ea694331041')||
       (bytes.length===10647922&&digest==='04f0556a9e2a819cbbea89283f7a9e610811183daef948579895846b53936ad1')))throw Error('Explicit public HoKit input pin mismatch');
 }else hokitPackage=await pinnedFile(directory,'HoKit-public-1.2.2.apk','https://www.sydxky.cn/download-hokit.php?platform=android',10647922,'04f0556a9e2a819cbbea89283f7a9e610811183daef948579895846b53936ad1');
 const request=path.join(directory,'request.json'),output=path.join(root,'entry/src/main/resources/rawfile/sideload/public-signing-templates.json');
 fs.writeFileSync(request,JSON.stringify({xiaobaiKey,xiaobaiCsr,hokitPackage}));
 // Java仅执行我们自己的解析/密码学代码，默认材料不通过argv或stdout传递。
 execFileSync(java,['-cp',classpath,'AmclSigningRunner','--prepare-default-templates',request,output],{stdio:'inherit',windowsHide:true});
 const bytes=fs.readFileSync(output);if(bytes.length>65536)throw Error('Generated template catalog too large');
 const receipt={schema:1,output,sha256:hash(bytes),bytes:bytes.length,publicInputsOnly:true,personalCredentialsRead:false,
  inputs:[xiaobaiKey,xiaobaiCsr,hokitPackage].map(filename=>({path:filename,sha256:hash(fs.readFileSync(filename))}))};
 fs.writeFileSync(path.join(directory,'provenance.json'),JSON.stringify(receipt,null,2));
 console.log('[signing-templates] verified public templates prepared, bytes='+bytes.length+', sha256='+receipt.sha256);
 return receipt;
}
