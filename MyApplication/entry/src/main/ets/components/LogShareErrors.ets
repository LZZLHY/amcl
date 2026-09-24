import { BusinessError } from '@kit.BasicServicesKit';

/** Transport errors have no HTTP status. Keep API codes separate from platform codes. */
export interface LogShareErrorResult {
  error: string;
  errorStage?: string;
  networkCode?: number;
  httpStatus?: number;
  apiCode?: string;
}

export class LogShareRequestError extends Error {
  stage: string;
  networkCode: number;
  httpStatus: number;
  apiCode: string;

  constructor(message: string, stage: string, networkCode: number = 0,
    httpStatus: number = 0, apiCode: string = '') {
    super(message);
    this.stage = stage;
    this.networkCode = networkCode;
    this.httpStatus = httpStatus;
    this.apiCode = apiCode;
  }
}

/** Only call at the HTTP request boundary, before parsing a response body. */
export function logShareTransportError(error: Error): LogShareRequestError {
  if (error instanceof LogShareRequestError) return error;
  const platform = error as BusinessError;
  const code = typeof platform.code === 'number' ? platform.code : 0;
  const message = error.message || '请求失败';
  return new LogShareRequestError('网络请求失败'
    + (code > 0 ? '（NetworkKit ' + code + '）' : '')
    + '，未收到 HTTP 响应：' + message, 'transport', code);
}

/** All UI callers already show error; structured fields also survive into diagnostics. */
export function setLogShareError(result: LogShareErrorResult, error: Error | LogShareRequestError): void {
  result.error = error.message || '未知错误';
  if (error instanceof LogShareRequestError) {
    result.errorStage = error.stage;
    if (error.networkCode > 0) result.networkCode = error.networkCode;
    if (error.httpStatus > 0) result.httpStatus = error.httpStatus;
    if (error.apiCode.length > 0) result.apiCode = error.apiCode;
  } else {
    result.errorStage = 'response';
  }
}
