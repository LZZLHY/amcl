/** 游戏内引导v3记录首次展示、重学请求与真实任务完成，独立小文件不污染布局或游戏选项。 */
import fs from '@ohos.file.fs'
import { BusinessError } from '@kit.BasicServicesKit'

interface LearningRecord { version: number; seen: boolean; requested: boolean; finished: boolean; completed: number[] }
export class TouchLearningStore {
  private path: string
  constructor(filesDir: string) { this.path=filesDir+'/touch-learning.json' }
  /** 旧模拟课堂的seen不代表学过游戏内引导；只介绍新版一次，主动关闭后不反复弹出。 */
  seen(): boolean { return this.read().seen }
  requested(): boolean { return this.read().requested }
  /** 缺文件说明尚未预约；未知读取故障或损坏文件不能解释为“未预约”再覆盖。 */
  strictRequested(): boolean {
    try {
      if (fs.statSync(this.path).size > 1024) throw new Error('引导记录过大');
      const v=JSON.parse(fs.readTextSync(this.path)) as LearningRecord;
      if (!v || v.version !== 3 || typeof v.seen !== 'boolean' || typeof v.requested !== 'boolean' ||
        typeof v.finished !== 'boolean' || !Array.isArray(v.completed) || v.completed.length > 6 ||
        v.completed.some((n:number):boolean=>!Number.isInteger(n) || n<0 || n>5)) throw new Error('引导记录损坏');
      return v.requested;
    } catch (error) { if ((error as BusinessError).code===13900002) return false; throw error as Error; }
  }
  request(): boolean { const value: LearningRecord={version:3,seen:false,requested:true,finished:false,completed:[]}; return this.write(value) }
  markSeen(): boolean { const value: LearningRecord=this.read(); value.seen=true; value.requested=false; return this.write(value) }
  markClosed(completed: boolean): boolean {
    const value: LearningRecord=this.read(); value.seen=true; value.requested=false; value.finished=completed; return this.write(value)
  }
  markLesson(lesson: number): boolean {
    if(!Number.isInteger(lesson) || lesson<0 || lesson>5) return false
    const value: LearningRecord=this.read()
    value.seen=true
    if(value.completed.indexOf(lesson)<0) value.completed.push(lesson)
    return this.write(value)
  }
  private read(): LearningRecord {
    const fallback: LearningRecord={version:3,seen:false,requested:false,finished:false,completed:[]}
    try {
      if(fs.statSync(this.path).size>1024) return fallback
      const value=JSON.parse(fs.readTextSync(this.path)) as LearningRecord
      if(value.version!==3 || typeof value.seen!=='boolean' || typeof value.requested!=='boolean' || typeof value.finished!=='boolean' ||
        !Array.isArray(value.completed) || value.completed.length>6 ||
        value.completed.some((lesson: number): boolean => !Number.isInteger(lesson) || lesson<0 || lesson>5)) return fallback
      return value
    } catch (_) { return fallback }
  }
  /** 写失败只影响下次提示；当前课程仍可关闭。所有内容有界，不记录手势轨迹或游戏数据。 */
  private write(record: LearningRecord): boolean {
    let file: fs.File | undefined=undefined
    try {
      file=fs.openSync(this.path,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC)
      const text: string=JSON.stringify(record)
      return fs.writeSync(file.fd,text)===text.length
    } catch (_) { return false }
    finally { if(file!==undefined) { try { fs.closeSync(file) } catch (_) { /* 写入异常不阻塞退出。 */ } } }
  }
}
