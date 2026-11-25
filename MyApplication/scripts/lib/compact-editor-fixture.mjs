/** 执行真实编辑器的字段、生命周期与业务方法；ArkUI声明另由接收器运行，存储可接生产Store。 */
import fs from 'node:fs';
import compiler from './ets-compiler.mjs';
import { makePureEtsLoader } from './load-pure-ets.mjs';
import { randomUUID } from 'node:crypto';

export function compactEditorFixture(profile, store = {getActiveProfile: () => profile}) {
  const load=makePureEtsLoader({'commons':{}});
  const model=load('gamecontrol/src/main/ets/ControlLayout.ets');
  const source=fs.readFileSync(new URL('../../entry/src/main/ets/components/LayoutEditor.ets',import.meta.url),'utf8');
  const ast=compiler.createSourceFile('LayoutEditor.ets',source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='LayoutEditor');
  const declarations=ast.statements.filter(n=>compiler.isClassDeclaration(n)||compiler.isVariableStatement(n)).map(n=>n.getText(ast));
  const fields=owner.members.filter(n=>n.initializer&&n.name).map(n=>n.name.getText(ast)+'='+n.initializer.getText(ast)+';');
  const lifecycle=['aboutToAppear','aboutToDisappear'];
  const methods=owner.members.filter(n=>n.body&&n.name&&
    (/^private\s/.test(n.getText(ast))||lifecycle.includes(n.name.getText(ast)))).map(n=>n.getText(ast));
  const skill=makePureEtsLoader({'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}}})('entry/src/main/ets/launcherskill/LayoutDraftAccess.ets');
  const bindings={...skill,...model,...load('gamecontrol/src/main/ets/ControlGroups.ets'),...load('gamecontrol/src/main/ets/ControlEditing.ets'),
    ...load('gamecontrol/src/main/ets/SecondaryControlGroups.ets'),...load('gamecontrol/src/main/ets/ControlAppearance.ets'),
    ...load('gamecontrol/src/main/ets/GlfwKeys.ets'),...load('gamecontrol/src/main/ets/LookPreferences.ets'),
    ...load('gamecontrol/src/main/ets/TouchPreferences.ets'),...load('gamecontrol/src/main/ets/LayoutEditSession.ets'),...load('gamecontrol/src/main/ets/GameGuiGeometry.ets'),
    ...load('entry/src/main/ets/components/TouchEditorTheme.ets'),...load('entry/src/main/ets/components/LayoutCatalogPaging.ets'),
    ...load('commons/src/main/ets/common/IconCatalog.ets'),cloneControlItem:model.cloneItem,
    getLayoutStore:()=>store,deviceInfo:{marketName:'host'},
    SliderChangeMode:{Begin:0,Moving:1,End:2,Click:3},hilog:{error(){},warn(){},info(){}}};
  const compiled=compiler.transpileModule(declarations.join('\n')+'\nclass Subject{'+fields.join('\n')+methods.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};new Function('module',...Object.keys(bindings),compiled)(module,...Object.values(bindings));
  const view=new module.exports();
  Object.assign(view,{screenWidth:800,screenHeight:360,editorMounted:true,editorReady:true,editorGeneration:1,panelX:290,panelY:8,
    getUIContext:()=>({showAlertDialog(){throw new Error('unexpected modal outside compact panel');}})});
  view.loadProfile(profile);
  return {view,model,load,modes:bindings.SliderChangeMode};
}
