import { vibrator } from '@kit.SensorServiceKit';

function pulse(ms: number): Promise<void> {
  return vibrator.startVibration({ type: 'time', duration: ms }, { usage: 'notification' });
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

/** 开始录音：短震两下（哒-哒） */
export async function vibrateRecordStart(): Promise<void> {
  try {
    await pulse(120);
    await sleep(250);
    await pulse(120);
  } catch (e) {
    // 震动失败不阻断录音
  }
}

/** 结束录音：长震一下（嗡—） */
export async function vibrateRecordStop(): Promise<void> {
  try {
    await pulse(400);
  } catch (e) {
    // 震动失败不阻断上传
  }
}
