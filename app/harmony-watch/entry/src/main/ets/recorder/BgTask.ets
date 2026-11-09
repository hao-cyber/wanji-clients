import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';

/**
 * 录音长时任务：申请 AUDIO_RECORDING 后台模式，息屏后录音不被系统挂起。
 * 失败不阻断录音（亮屏兜底仍在），只是息屏续录降级。
 */
export async function startRecordingBgTask(ctx: common.UIAbilityContext): Promise<boolean> {
  try {
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent = await wantAgent.getWantAgent(info);
    await backgroundTaskManager.startBackgroundRunning(ctx,
      backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent);
    return true;
  } catch (e) {
    return false;
  }
}

export async function stopRecordingBgTask(ctx: common.UIAbilityContext): Promise<void> {
  try {
    await backgroundTaskManager.stopBackgroundRunning(ctx);
  } catch (e) {
    // 任务可能未启动，忽略
  }
}
