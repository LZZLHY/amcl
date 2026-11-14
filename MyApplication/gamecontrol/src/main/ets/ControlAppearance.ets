/**
 * 按键外观的纯颜色运算。持久八位颜色固定为ArkUI #AARRGGBB，不能按网页#RRGGBBAA解释。
 * 整体透明、背景Alpha与RGB独立；本模块不订阅界面或输入，不创建平台资源。
 */
export class ControlRgba {
  red: number = 255
  green: number = 255
  blue: number = 255
  alpha: number = 1
}
export class ControlHsv {
  hue: number = 0
  saturation: number = 0
  value: number = 1
}

function colorBound(value: number, max: number = 1): number { return Math.max(0,Math.min(max,Number.isFinite(value)?value:0)) }

/** 支持既有十六进制与常用命名/RGB表示；无法识别的旧表达式只在用户明确改色时使用缺省色。 */
export function controlColorParts(source: string | undefined, fallback: string = '#FFFFFFFF'): ControlRgba {
  let text: string=(source ?? fallback).trim()
  // 明确列举历史常用命名色，避免以无结构对象字面量绕过ArkTS的静态对象约束。
  switch(text.toLowerCase()){
    case 'white':text='#FFFFFF';break
    case 'black':text='#000000';break
    case 'red':text='#FF0000';break
    case 'green':text='#008000';break
    case 'blue':text='#0000FF';break
    case 'transparent':text='#00000000';break
  }
  if(new RegExp('^#[0-9a-fA-F]{3}$').test(text))text='#'+text[1]+text[1]+text[2]+text[2]+text[3]+text[3]
  const color: ControlRgba=new ControlRgba()
  if(new RegExp('^#[0-9a-fA-F]{6}$').test(text)){
    color.red=parseInt(text.slice(1,3),16);color.green=parseInt(text.slice(3,5),16);color.blue=parseInt(text.slice(5,7),16);return color
  }
  if(new RegExp('^#[0-9a-fA-F]{8}$').test(text)){
    color.alpha=parseInt(text.slice(1,3),16)/255;color.red=parseInt(text.slice(3,5),16)
    color.green=parseInt(text.slice(5,7),16);color.blue=parseInt(text.slice(7,9),16);return color
  }
  const rgb: RegExpMatchArray | null=text.match(new RegExp('^rgba?\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)$','i'))
  if(rgb!==null){color.red=colorBound(Number(rgb[1]),255);color.green=colorBound(Number(rgb[2]),255);color.blue=colorBound(Number(rgb[3]),255);color.alpha=rgb[4]===undefined?1:colorBound(Number(rgb[4]));return color}
  return text===fallback?color:controlColorParts(fallback,'#FFFFFFFF')
}
function colorByte(value: number): string { return Math.round(colorBound(value,255)).toString(16).padStart(2,'0').toUpperCase() }
export function controlRgbHex(color: ControlRgba): string { return '#'+colorByte(color.red)+colorByte(color.green)+colorByte(color.blue) }
export function controlArgbHex(color: ControlRgba): string { return '#'+colorByte(color.alpha*255)+controlRgbHex(color).slice(1) }

/** 只更改Alpha，保留背景RGB；零值合法，不使用真假判断回退缺省。 */
export function controlColorWithAlpha(source: string | undefined, alpha: number, fallback: string='#30FFFFFF'): string {
  const value: ControlRgba=controlColorParts(source,fallback);value.alpha=colorBound(alpha);return controlArgbHex(value)
}
/** 改色只替换RGB，保持原透明度，使背景Alpha滑条不被调色器覆盖。 */
export function controlColorWithRgb(source: string | undefined, rgb: string, fallback: string): string {
  const value: ControlRgba=controlColorParts(rgb);value.alpha=controlColorParts(source,fallback).alpha;return controlArgbHex(value)
}
export function controlRgbToHsv(color: ControlRgba): ControlHsv {
  const red: number=color.red/255,green: number=color.green/255,blue: number=color.blue/255
  const max: number=Math.max(red,green,blue),min: number=Math.min(red,green,blue),delta: number=max-min
  const result: ControlHsv=new ControlHsv();result.value=max;result.saturation=max===0?0:delta/max
  if(delta===0)return result
  result.hue=max===red?60*((green-blue)/delta%6):max===green?60*((blue-red)/delta+2):60*((red-green)/delta+4)
  if(result.hue<0)result.hue+=360
  return result
}
export function controlHsvToRgb(hue: number,saturation: number,value: number): ControlRgba {
  const h: number=((hue%360)+360)%360/60,s: number=colorBound(saturation),v: number=colorBound(value)
  const chroma: number=v*s,second: number=chroma*(1-Math.abs(h%2-1)),offset: number=v-chroma
  const result: ControlRgba=new ControlRgba()
  const red: number=h<1?chroma:h<2?second:h<4?0:h<5?second:chroma
  const green: number=h<1?second:h<3?chroma:h<4?second:0
  const blue: number=h<2?0:h<3?second:h<5?chroma:second
  result.red=Math.round((red+offset)*255);result.green=Math.round((green+offset)*255);result.blue=Math.round((blue+offset)*255)
  return result
}
