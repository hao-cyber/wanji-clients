import { isValidPhoneToken, uploadPhoneAudioBluetooth } from './BluetoothUploader';

export interface AsrResult {
  text: string;
  ms: number;
  kind: string;
  taskId: number;
  conversationId: number;
}

/**
 * 正式产品路径固定为：手表本地保存 -> 蓝牙传 iPhone -> 手机按用户操作请求转写。
 * 手表不直接访问公网，也不持有 ASR 或纪要服务凭据。
 */
export function uploadTargetLabel(): string {
  return '传到手机';
}

export async function uploadAudio(audioBuf: ArrayBuffer,
                                  createdAt: number = 0,
                                  uploadId: string = '',
                                  phoneToken: string = ''): Promise<AsrResult> {
  if (!isValidPhoneToken(phoneToken)) {
    throw new Error('ERROR: 尚未绑定手机，请在手机腕记中完成连接');
  }
  const started = Date.now();
  await uploadPhoneAudioBluetooth(audioBuf, createdAt, uploadId, phoneToken);
  return {
    text: '已传到手机',
    ms: Date.now() - started,
    kind: 'phone',
    taskId: 0,
    conversationId: 0
  };
}

/**
 * 兼容既有页面调用。转写与纪要全部由手机端发起，手表不再转发文本。
 */
export async function forwardTranscript(text: string): Promise<void> {
  return;
}
