/**
 * 启动器已有 JVM 文本语法的公共词法入口。设置预览与 LaunchProfileBuilder 共用，
 * 避免把引号内的普通属性内容误识别成分辨率 marker。只分词，不执行 shell、不展开变量；
 * 保留既有单/双引号和空白规则，未闭合引号沿用原解析器消费到文本末尾的行为。
 */
export function splitJvmArguments(raw: string): string[] {
  const result: string[] = [];
  let current: string = '';
  let inToken: boolean = false;
  let quote: string = '';
  for (let index: number = 0; index < raw.length; index++) {
    const value: string = raw.charAt(index);
    if (quote.length > 0) {
      if (value === quote) quote = '';
      else current += value;
    } else if (value === '"' || value === '\'') {
      quote = value;
      inToken = true;
    } else if (value === ' ' || value === '\t' || value === '\n' || value === '\r') {
      if (inToken) { result.push(current); current = ''; inToken = false; }
    } else {
      current += value;
      inToken = true;
    }
  }
  if (inToken) result.push(current);
  return result;
}
