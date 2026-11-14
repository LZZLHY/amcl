/** 执行生产 URL 映射：官方仅源、自动/镜像顺序及未知作者站点的字节保持分别验证。 */
import assert from 'node:assert/strict';
import { loader } from './mod-install-test-runtime.mjs';
const load=loader({});
const mr=load('mods/src/main/ets/ModrinthUrls.ets');
const cf=load('mods/src/main/ets/CurseForgeUrls.ets');
const pack=load('mods/src/main/ets/ModpackDownloadUrls.ets');
const official='https://cdn.modrinth.com/data/a/versions/b/file.jar?sig=A%2bb&x=2&x=1';
const mirror=mr.mirrorifyModrinthCdn(official);
const plain=value=>JSON.parse(JSON.stringify(value));
const cases=[];
/** 对生产模块的可观察输出断言；不在测试里重建来源排序或 URL 合成算法。 */
function check(name,actual,expected){assert.deepEqual(plain(actual),expected,name);cases.push(name);console.log('PASS '+name);}
for(const relay of [false,true]){
  check('MR explicit official wins gateway '+relay,mr.resolveModrinthSourcePreference('official',mr.ModrinthSourceMode.MCIM_FIRST,relay),mr.ModrinthSourceMode.OFFICIAL_ONLY);
  check('MR mirror saved preference follows gateway intent '+relay,mr.resolveModrinthSourcePreference('mcim',mr.ModrinthSourceMode.OFFICIAL_FIRST,relay),relay?mr.ModrinthSourceMode.OFFICIAL_ONLY:mr.ModrinthSourceMode.MCIM_FIRST);
  check('CF explicit official wins gateway '+relay,cf.resolveCurseForgeFileSourcePreference('official',relay),cf.CurseForgeFileSourceMode.OFFICIAL_ONLY);
  check('CF mirror saved preference follows gateway intent '+relay,cf.resolveCurseForgeFileSourcePreference('mcim',relay),relay?cf.CurseForgeFileSourceMode.OFFICIAL_ONLY:cf.CurseForgeFileSourceMode.MIRROR_FIRST);
}
check('automatic MR consumes its existing probe when no gateway',mr.resolveModrinthSourcePreference('auto',mr.ModrinthSourceMode.OFFICIAL_FIRST,false),mr.ModrinthSourceMode.OFFICIAL_FIRST);
check('automatic MR constrains official with enabled gateway',mr.resolveModrinthSourcePreference('auto',mr.ModrinthSourceMode.MCIM_FIRST,true),mr.ModrinthSourceMode.OFFICIAL_ONLY);
check('automatic CF constrains official with enabled gateway',cf.resolveCurseForgeFileSourcePreference('auto',true),cf.CurseForgeFileSourceMode.OFFICIAL_ONLY);
check('MR strict file keeps source and signed query',mr.buildFileDownloadUrls(official,mr.ModrinthSourceMode.OFFICIAL_ONLY),{primary:official,mirrors:[]});
check('MR strict metadata keeps API only',mr.buildProjectUrl('sodium',mr.ModrinthSourceMode.OFFICIAL_ONLY),{primary:'https://api.modrinth.com/v2/project/sodium',mirrors:[]});
check('MR automatic official priority retains fallback',mr.buildFileDownloadUrls(official,mr.ModrinthSourceMode.OFFICIAL_FIRST),{primary:official,mirrors:[mirror]});
check('MR mirror preference remains unchanged',mr.buildFileDownloadUrls(official,mr.ModrinthSourceMode.MCIM_FIRST),{primary:mirror,mirrors:[official]});
const cdn='https://edge.forgecdn.net/files/1234/567/a.jar?sig=B%2Bc';const cfMirror=cf.mirrorifyCurseForgeCdn(cdn);
const cfAlias='https://mediafilez.forgecdn.net/files/1234/567/a.jar?sig=B%2Bc';
check('CF strict file keeps exact primary and official alias',cf.buildCurseForgeFileDownloadUrls(cdn,cf.CurseForgeFileSourceMode.OFFICIAL_ONLY),{primary:cdn,mirrors:[cfAlias]});
check('CF strict does not label mirror input official',cf.buildCurseForgeFileDownloadUrls(cfMirror,cf.CurseForgeFileSourceMode.OFFICIAL_ONLY),{primary:'',mirrors:[]});
check('MR strict does not label mirror input official',mr.buildFileDownloadUrls(mirror,mr.ModrinthSourceMode.OFFICIAL_ONLY),{primary:'',mirrors:[]});
check('CF gateway compatible official priority',cf.buildCurseForgeFileDownloadUrls(cdn,cf.CurseForgeFileSourceMode.OFFICIAL_FIRST),{primary:cdn,mirrors:[cfMirror]});
check('CF legacy mirror default unchanged',cf.buildCurseForgeFileDownloadUrls(cdn),{primary:cfMirror,mirrors:[cdn]});
check('MR manifest strict does not synthesize mirror',pack.buildModpackDownloadUrls([official],true,true),[official]);
check('old recovered CF candidates constrained with official alias',pack.buildModpackDownloadUrls([cfMirror,cdn],false,true),[cdn,cfAlias]);
check('old recovered MR candidates constrained',pack.buildModpackDownloadUrls([mirror,official],true,true),[official]);
check('no silent expansion when only mirror remains',pack.buildModpackDownloadUrls([mirror],true,true),[]);
const author='https://mod.mcimirror.top.author.example/data/a.jar?secret=opaque';
check('authority prefix collision is not a mirror',pack.buildModpackDownloadUrls([author],true,true),[author]);
for(const disguised of ['https://MOD.MCIMIRROR.TOP.:443/files/a.jar','https://opaque@mod.mcimirror.top/files/a.jar']){
  check('recovered normalized mirror rejected '+disguised.split('/')[2],pack.buildModpackDownloadUrls([disguised,official],true,true),[official]);
}
const raw={id:1234567,fileName:'client [fabric].zip',downloadUrl:cfMirror,fileLength:4096,hashes:[]};
check('strict CF metadata mirror uses its exact file identity',cf.mapCurseForgeFile(raw,true,cf.CurseForgeFileSourceMode.OFFICIAL_ONLY).url,
  'https://edge.forgecdn.net/files/1234/567/client%20[fabric].zip');
check('non strict manifest still provides its old backup',pack.buildModpackDownloadUrls([official],true,false),[official,mirror]);
// 不通过 URL 解析重建预期值，直接比较路径与签名 query 原字节。
for(const url of ['http://edge.forgecdn.net/files/1/2/a.jar','https://edge.forgecdn.net:443/files/1/2/a.jar',
  'https://user@edge.forgecdn.net/files/1/2/a.jar','https://edge.forgecdn.net./files/1/2/a.jar',
  'https://edge.forgecdn.net.evil/files/1/2/a.jar','https://author.example/files/1/2/a.jar',
  'https://edge.forgecdn.net/FILES/1/2/a.jar','https://edge.forgecdn.net/files/1/2/a.jar#fragment',
  'https://edge.forgecdn.net/files/1/2/a.jar\n','https://mediafilez.forgecdn.net/files/1/2/a.jar'])
  check('no guessed alias '+JSON.stringify(url),cf.buildCurseForgeOfficialFileUrls(url),[url]);
const encoded='HTTPS://EDGE.FORGECDN.NET/files/7446/117/GT%20X%2bY%252F.zip?sig=A%2bb&x=2&x=1';
const encodedAlias='https://mediafilez.forgecdn.net/files/7446/117/GT%20X%2bY%252F.zip?sig=A%2bb&x=2&x=1';
check('scheme/host case keeps exact original and escaped path/query',cf.buildCurseForgeOfficialFileUrls(encoded),[encoded,encodedAlias]);
check('existing official alias deduplicated',pack.buildModpackDownloadUrls([cdn,cfAlias,cdn],false,true),[cdn,cfAlias]);
check('MR manifest does not gain CF synthesis',pack.buildModpackDownloadUrls([cdn],true,true),[cdn]);
check('non strict CF manifest unchanged',pack.buildModpackDownloadUrls([cdn],false,false),[cdn]);
console.log(JSON.stringify({passed:cases.length,cases}));
