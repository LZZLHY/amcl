/**
 * 布局表达式的有限算术解释器，仅用于导入坐标。
 * 只支持数字、已提供的变量、括号和四则运算；不执行JavaScript、不调用函数、不访问对象。
 * 未知变量、除零、超长表达式或过深括号返回undefined，由导入预览明确报告降级。
 */
export function evaluateLayoutExpression(expression: string, variables: Record<string, number>): number | undefined {
  if (expression.length>512) return undefined
  let text: string = expression
  for (const key of Object.keys(variables)) text=text.split('${'+key+'}').join(String(variables[key]))
  text=text.replace(new RegExp('\\s','g'),'')
  const reader = new LayoutExpressionReader(text)
  return reader.read()
}

class LayoutExpressionReader {
  private text: string
  private position: number = 0
  constructor(text: string) { this.text=text }
  /** 必须消耗整个字符串，不能接受合法前缀后夹带任意字符。 */
  read(): number | undefined {
    const value: number = this.sum(0)
    return this.position===this.text.length && Number.isFinite(value) ? value : undefined
  }
  /** 加减最低优先级；每次循环都消费运算符，非法右项由最终有限数校验拒绝。 */
  private sum(depth: number): number {
    let value: number = this.product(depth)
    while (this.position<this.text.length) {
      const op: string = this.text[this.position]
      if (op!=='+' && op!=='-') break
      this.position++
      const right: number = this.product(depth)
      value=op==='+' ? value+right : value-right
    }
    return value
  }
  /** 乘除在同一优先级，除零不抛出系统异常而返回不可接受的NaN。 */
  private product(depth: number): number {
    let value: number = this.factor(depth)
    while (this.position<this.text.length) {
      const op: string = this.text[this.position]
      if (op!=='*' && op!=='/') break
      this.position++
      const right: number = this.factor(depth)
      value=op==='*' ? value*right : (right===0 ? NaN : value/right)
    }
    return value
  }
  /** 有界处理括号/单目符号/数字；未知名字或函数没有执行入口。 */
  private factor(depth: number): number {
    if (depth>16 || this.position>=this.text.length) return NaN
    const char: string = this.text[this.position]
    if (char==='+' || char==='-') {
      this.position++
      const value: number = this.factor(depth+1)
      return char==='-' ? -value : value
    }
    if (char==='(') {
      this.position++
      const value: number = this.sum(depth+1)
      if (this.text[this.position]!==')') return NaN
      this.position++
      return value
    }
    const match: RegExpMatchArray | null = this.text.substring(this.position).match(new RegExp('^(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)'))
    if (match===null) return NaN
    this.position+=match[0].length
    return Number(match[0])
  }
}
