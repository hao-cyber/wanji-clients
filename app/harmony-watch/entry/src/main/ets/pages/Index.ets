import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AacRecorder, withTimeout } from '../recorder/AacRecorder';
import { AudioItem, AudioQueueStore, QueueStats } from '../recorder/AudioQueue';
import { vibrateRecordStart, vibrateRecordStop } from '../recorder/Haptics';
import { startRecordingBgTask, stopRecordingBgTask } from '../recorder/BgTask';
import { uploadAudio, forwardTranscript, AsrResult, uploadTargetLabel } from '../net/Uploader';
import { isValidPhoneToken } from '../net/BluetoothUploader';
import { WatchSyncAdvertiser } from '../net/WatchSyncAdvertiser';
import { Palette } from './Palette';

const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
const BLUETOOTH_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';
const PRIVACY_CONSENT_VERSION: number = 1;

PersistentStorage.persistProp('wanjiPrivacyConsentVersion', 0);
PersistentStorage.persistProp('wanjiPhoneToken', '');

enum UiState {
  Idle,
  Starting,
  Recording,
  Uploading,
  Result,
  Error
}

class HistoryItem {
  text: string = '';
  durS: number = 0;
  auto: boolean = false;
}

@Entry
@Component
struct Index {
  @State uiState: UiState = UiState.Idle;
  @State statusNote: string = '';
  @State resultText: string = '';
  @State resultMeta: string = '';
  @State elapsedMs: number = 0;
  @State history: HistoryItem[] = [];
  @State queueItems: AudioItem[] = [];
  @State permissionDenied: boolean = false;
  @State bluetoothPermissionDenied: boolean = false;
  @State showPrivacy: boolean = false;
  @StorageLink('wanjiPrivacyConsentVersion') privacyConsentVersion: number = 0;
  @StorageLink('wanjiPhoneToken') phoneToken: string = '';
  // 下键按下时 EntryAbility.onNewWant 更新此值 → 物理键路由（开录/停止/重试）
  @StorageProp('toggleSeq') @Watch('onToggleSeq') toggleSeq: number = 0;

  private recorder: AacRecorder = new AacRecorder();
  private timerId: number | null = null;
  private busy: boolean = false;
  private autoStarted: boolean = false;
  private disappeared: boolean = false;
  private store: AudioQueueStore | null = null;
  private currentItemId: string = '';
  private lastNotice: string | null = null;
  private lastDurS: number = 0;
  private bgStartPromise: Promise<boolean> | null = null;
  private suppressClickUntil: number = 0;
  // 页面销毁后递增，in-flight 上传返回时校验，防止改写已死页面状态
  private uploadGen: number = 0;
  private autoSyncTimerId: number | null = null;
  private autoSyncInFlight: boolean = false;
  private autoSyncBackoffMs: number = 5000;
  private watchSyncAdvertiser: WatchSyncAdvertiser = new WatchSyncAdvertiser();
  private servicesActivated: boolean = false;
  private pairingUntil: number = 0;

  onToggleSeq(): void {
    if (this.privacyConsentVersion < PRIVACY_CONSENT_VERSION) {
      this.showPrivacy = true;
      return;
    }
    this.onPrimaryAction();
  }

  // 物理键和主按钮共用的状态路由
  private onPrimaryAction(): void {
    if (this.privacyConsentVersion < PRIVACY_CONSENT_VERSION) {
      this.showPrivacy = true;
      return;
    }
    if (this.busy) {
      return;
    }
    if (this.uiState === UiState.Recording) {
      this.stopAndUpload(null);
    } else if (this.uiState === UiState.Error) {
      this.retryUpload();
    } else if (this.uiState === UiState.Uploading) {
      // 转写中忽略输入，保持平静
    } else {
      this.startRecording();
    }
  }

  // 申请麦克风权限；被拒后再次调用会重新发起申请（H9 恢复路径）
  private async ensurePermission(): Promise<boolean> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const res = await atManager.requestPermissionsFromUser(ctx, [MIC_PERMISSION]);
      this.permissionDenied = res.authResults[0] !== 0;
    } catch (e) {
      this.permissionDenied = true;
    }
    return !this.permissionDenied;
  }

  private usesBluetoothPhone(): boolean {
    return isValidPhoneToken(this.phoneToken);
  }

  private async ensureBluetoothPermission(): Promise<boolean> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const res = await atManager.requestPermissionsFromUser(ctx, [BLUETOOTH_PERMISSION]);
      this.bluetoothPermissionDenied = res.authResults[0] !== 0;
    } catch (e) {
      this.bluetoothPermissionDenied = true;
    }
    return !this.bluetoothPermissionDenied;
  }

  async aboutToAppear(): Promise<void> {
    this.disappeared = false;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new AudioQueueStore(ctx.filesDir);
    this.refreshQueue();
    AacRecorder.sweepTemp(ctx.tempDir);
    if (this.privacyConsentVersion < PRIVACY_CONSENT_VERSION) {
      this.showPrivacy = true;
      return;
    }
    await this.activateServices(true);
  }

  private async activateServices(autoStart: boolean): Promise<void> {
    if (!this.servicesActivated) {
      this.servicesActivated = true;
      this.scheduleAutoSync(1200);
      this.startWatchSyncAdvertiser();
    }
    if (!await this.ensurePermission()) {
      return;
    }
    if (autoStart && !this.autoStarted && this.uiState === UiState.Idle) {
      this.autoStarted = true;
      this.startRecording();
    }
  }

  private acceptPrivacy(): void {
    this.privacyConsentVersion = PRIVACY_CONSENT_VERSION;
    this.showPrivacy = false;
    this.activateServices(false).then(() => {}).catch(() => {});
  }

  aboutToDisappear(): void {
    this.disappeared = true;
    this.uploadGen++;
    this.clearAutoSyncTimer();
    this.watchSyncAdvertiser.stop();
    this.servicesActivated = false;
    this.clearTimer();
    this.setKeepScreenOn(false).then(() => {}).catch(() => {});
    if (this.recorder.isRecording()) {
      // 页面销毁兜底释放麦克风，结果丢弃
      this.recorder.stop(false).then(() => {}).catch(() => {});
      this.stopBgTaskJoined();
    }
  }

  // 等待进行中的 bg task 启动完成后再停止，避免快停快起的乱序
  private stopBgTaskJoined(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const pending = this.bgStartPromise;
    this.bgStartPromise = null;
    if (pending) {
      pending.then(() => stopRecordingBgTask(ctx)).catch(() => stopRecordingBgTask(ctx));
    } else {
      stopRecordingBgTask(ctx);
    }
  }

  private clearTimer(): void {
    if (this.timerId !== null) {
      clearInterval(this.timerId);
      this.timerId = null;
    }
  }

  private clearAutoSyncTimer(): void {
    if (this.autoSyncTimerId !== null) {
      clearTimeout(this.autoSyncTimerId);
      this.autoSyncTimerId = null;
    }
  }

  private async setKeepScreenOn(on: boolean): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowKeepScreenOn(on);
    } catch (e) {
      // 屏幕常亮失败不阻断录音
    }
  }

  private async startRecording(): Promise<void> {
    if (this.busy || this.recorder.isRecording()) {
      return;
    }
    this.busy = true;
    this.uiState = UiState.Starting;
    this.statusNote = this.permissionDenied ? '等待麦克风权限' : '正在启动麦克风';
    try {
      if (this.permissionDenied && !await this.ensurePermission()) {
        this.uiState = UiState.Idle;
        this.statusNote = '';
        return;
      }
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.recorder.start(ctx.tempDir);
      // start 期间页面已销毁：释放麦克风后退出
      if (this.disappeared) {
        this.recorder.stop(false).then(() => {}).catch(() => {});
        return;
      }
      this.uiState = UiState.Recording;
      this.statusNote = '';
      this.elapsedMs = 0;
      vibrateRecordStart();
      this.timerId = setInterval(() => {
        this.elapsedMs = this.recorder.recordedMs();
        if (this.elapsedMs >= AacRecorder.MAX_MS) {
          this.stopAndUpload('已达5分钟');
        }
      }, 1000);
      this.busy = false;
      this.bgStartPromise = startRecordingBgTask(ctx);
      this.monitorBackgroundStart(ctx, this.bgStartPromise).then(() => {}).catch(() => {});
    } catch (e) {
      this.uiState = UiState.Error;
      this.statusNote = '启动失败';
      console.error('ERROR: recorder start failed: ' + JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  // 后台录音保护慢或挂起时，只兜底常亮屏幕；不能阻塞已进入录音态后的停止入口。
  private async monitorBackgroundStart(ctx: common.UIAbilityContext, pending: Promise<boolean>): Promise<void> {
    let bgOk = false;
    try {
      bgOk = await withTimeout(pending, 3000, 'bgtask.start');
    } catch (e) {
      bgOk = false;
    }
    if (this.bgStartPromise !== pending || this.disappeared || !this.recorder.isRecording()) {
      return;
    }
    if (!bgOk) {
      await this.setKeepScreenOn(true);
    }
  }

  private async stopAndUpload(notice: string | null): Promise<void> {
    // 以 recorder 为状态真相（uiState 是 UI 投影，极端时序下可能短暂失配）
    if (this.busy || !this.recorder.isRecording()) {
      return;
    }
    this.busy = true;
    this.clearTimer();
    vibrateRecordStop();
    this.stopBgTaskJoined();
    await this.setKeepScreenOn(false);
    this.lastNotice = notice;
    this.uiState = UiState.Uploading;
    this.statusNote = notice ?? '';
    // 从 recorder 实时取时长（elapsedMs 是秒级 timer 快照，可能滞后 ~1s）
    const durS = Math.round(this.recorder.recordedMs() / 1000);
    try {
      const recording = await this.recorder.stop(true);
      const items = this.queueStore().load();
      const item = this.queueStore().storeRecording(recording, durS, notice !== null, items);
      this.queueItems = items.slice(0);
      this.currentItemId = item.id;
      this.lastDurS = durS;
      if (this.usesBluetoothPhone()) {
        this.uiState = UiState.Idle;
        this.statusNote = '已保存，靠近手机会自动传';
        this.scheduleAutoSync(0);
      } else {
        await this.doUploadItem(item.id, true);
      }
    } catch (e) {
      this.uiState = UiState.Error;
      console.error('ERROR: stop/upload failed: ' + JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  // 长按丢弃：停止录音不上传，回到待机（深思熟虑的逃生口，800ms 长按 + 单脉冲反馈）
  private async discardRecording(): Promise<void> {
    if (this.busy || !this.recorder.isRecording()) {
      return;
    }
    this.busy = true;
    this.clearTimer();
    this.stopBgTaskJoined();
    await this.setKeepScreenOn(false);
    try {
      await this.recorder.stop(false);
    } catch (e) {
      console.error('ERROR: discard stop failed: ' + JSON.stringify(e));
    } finally {
      this.currentItemId = '';
      this.lastNotice = null;
      this.uiState = UiState.Idle;
      this.statusNote = '';
      this.elapsedMs = 0;
      this.busy = false;
    }
  }

  private async retryUpload(): Promise<void> {
    if (this.busy) {
      return;
    }
    const item = this.queueStore().findUploadCandidate(this.queueStore().load(), this.currentItemId);
    if (item === null) {
      this.uiState = UiState.Idle;
      this.statusNote = '';
      return;
    }
    this.busy = true;
    this.currentItemId = item.id;
    this.uiState = UiState.Uploading;
    this.statusNote = this.lastNotice ?? '';
    try {
      await this.doUploadItem(item.id, true);
    } catch (e) {
      this.uiState = UiState.Error;
      console.error('ERROR: retry upload failed: ' + JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  private async doUploadItem(itemId: string, surfaceUi: boolean = true): Promise<void> {
    const gen = this.uploadGen;
    const store = this.queueStore();
    let items = store.load();
    let item = this.findItem(items, itemId);
    if (item === null) {
      throw new Error('ERROR: queued audio missing');
    }
    item.state = 'syncing';
    item.attempts++;
    item.lastError = '';
    store.save(items);
    this.queueItems = items.slice(0);

    try {
      if (this.usesBluetoothPhone()) {
        this.statusNote = '等待蓝牙权限';
        if (!await this.ensureBluetoothPermission()) {
          throw new Error('ERROR: 请允许蓝牙权限后重试');
        }
        this.statusNote = '蓝牙传手机';
      }
      const r: AsrResult = await uploadAudio(store.readAudio(item), item.createdAt, item.id, this.phoneToken);
      items = store.load();
      const done = this.findItem(items, itemId);
      if (done !== null) {
        store.removeItem(items, done);
      }
      this.queueItems = store.load();
      this.currentItemId = '';
      this.lastNotice = null;
      this.lastDurS = 0;

      // 上传期间页面已销毁：本地文件已清理，结果不再改写死页面状态、不转发
      if (gen !== this.uploadGen) {
        return;
      }
      this.resultText = r.text;
      const auto = item.auto;
      this.resultMeta = (auto ? '自动停止 · ' : '') + (item.durS > 0 ? this.fmtTime(item.durS * 1000) : '')
        + (r.kind === 'task' ? ' · 已入纪要' : '')
        + (r.kind === 'phone' ? ' · 已传手机' : '');
      const hist = new HistoryItem();
      hist.text = r.text;
      hist.durS = item.durS;
      hist.auto = auto;
      this.history = [hist, ...this.history].slice(0, 5);
      if (surfaceUi) {
        this.uiState = UiState.Result;
      } else {
        this.statusNote = '已自动传到手机';
      }
      if (r.kind !== 'task' && r.kind !== 'phone') {
        forwardTranscript(r.text).then(() => {}).catch(() => {});
      }
    } catch (e) {
      items = store.load();
      const failed = this.findItem(items, itemId);
      if (failed !== null) {
        failed.state = 'failed';
        failed.lastError = store.shortError(e);
        store.save(items);
        this.queueItems = items.slice(0);
        if (surfaceUi) {
          this.currentItemId = failed.id;
          this.statusNote = failed.lastError;
        } else {
          this.statusNote = '等待手机腕记';
        }
      }
      throw new Error('ERROR: upload queued audio failed: ' + JSON.stringify(e));
    }
  }

  private scheduleAutoSync(delayMs: number): void {
    if (!this.usesBluetoothPhone() || this.disappeared) {
      return;
    }
    this.clearAutoSyncTimer();
    this.autoSyncTimerId = setTimeout(() => {
      this.autoSyncTimerId = null;
      this.runAutoSync().then(() => {}).catch(() => {});
    }, Math.max(0, delayMs));
  }

  private async runAutoSync(): Promise<void> {
    if (this.autoSyncInFlight || !this.usesBluetoothPhone() || this.disappeared) {
      return;
    }
    if (this.busy || this.recorder.isRecording()) {
      if (this.queueStore().findUploadCandidate(this.queueStore().load(), '') !== null) {
        this.scheduleAutoSync(5000);
      }
      return;
    }
    const item = this.queueStore().findUploadCandidate(this.queueStore().load(), '');
    if (item === null) {
      this.autoSyncBackoffMs = 5000;
      this.refreshQueue();
      return;
    }
    this.autoSyncInFlight = true;
    this.statusNote = '自动蓝牙传手机';
    try {
      await this.doUploadItem(item.id, false);
      this.autoSyncBackoffMs = 5000;
    } catch (e) {
      this.autoSyncBackoffMs = Math.min(this.autoSyncBackoffMs * 2, 60000);
    } finally {
      this.autoSyncInFlight = false;
      this.refreshQueue();
    }
    if (this.queueStore().findUploadCandidate(this.queueStore().load(), '') !== null) {
      this.scheduleAutoSync(this.autoSyncBackoffMs);
    }
  }

  private startWatchSyncAdvertiser(): void {
    this.ensureBluetoothPermission().then((ok: boolean) => {
      if (!ok || this.disappeared) {
        return;
      }
      this.watchSyncAdvertiser.start(() => {
        this.handlePhoneSyncRequest();
      }, () => {
        return this.phoneToken;
      }, () => {
        return Date.now() < this.pairingUntil;
      }, (token: string) => {
        this.phoneToken = token;
        this.pairingUntil = 0;
        this.statusNote = '已绑定手机';
        this.scheduleAutoSync(600);
      });
    }).catch(() => {});
  }

  private beginPairing(): void {
    if (this.privacyConsentVersion < PRIVACY_CONSENT_VERSION) {
      this.showPrivacy = true;
      return;
    }
    this.pairingUntil = Date.now() + 60000;
    this.statusNote = '请在手机腕记点“绑定手表”';
    this.startWatchSyncAdvertiser();
  }

  private handlePhoneSyncRequest(): void {
    if (!this.usesBluetoothPhone() || this.disappeared) {
      return;
    }
    this.statusNote = '手机已连接，准备传输';
    if (this.busy || this.recorder.isRecording()) {
      this.scheduleAutoSync(3000);
      return;
    }
    this.scheduleAutoSync(0);
  }

  private queueStore(): AudioQueueStore {
    if (this.store === null) {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = new AudioQueueStore(ctx.filesDir);
    }
    return this.store;
  }

  private refreshQueue(): void {
    this.queueItems = this.queueStore().load();
  }

  private findItem(items: AudioItem[], id: string): AudioItem | null {
    for (let i = 0; i < items.length; i++) {
      if (items[i].id === id) {
        return items[i];
      }
    }
    return null;
  }

  private queueNotice(): string {
    const stats: QueueStats = this.queueStore().stats(this.queueItems);
    if (stats.failed > 0) {
      return this.usesBluetoothPhone() ? '等待手机 ' + stats.failed + ' 条' : '待重试 ' + stats.failed + ' 条';
    }
    if (stats.pending > 0 || stats.syncing > 0) {
      return this.usesBluetoothPhone() ? '自动传输 ' + (stats.pending + stats.syncing) + ' 条' : '待同步 ' + (stats.pending + stats.syncing) + ' 条';
    }
    return '';
  }

  private queueHasRetry(): boolean {
    const stats: QueueStats = this.queueStore().stats(this.queueItems);
    return stats.failed + stats.pending > 0;
  }

  private fmtBytes(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return Math.round(bytes / 1024 / 1024) + 'MB';
    }
    return Math.round(bytes / 1024) + 'KB';
  }

  private fmtDate(ts: number): string {
    const d = new Date(ts);
    const h = d.getHours();
    const m = d.getMinutes();
    return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
  }

  private retryQueueFromIdle(): void {
    if (!this.queueHasRetry() || this.busy || this.recorder.isRecording()) {
      return;
    }
    if (this.usesBluetoothPhone()) {
      this.statusNote = '正在找手机腕记';
    }
    this.retryUpload();
  }

  private confirmDeleteQueuedAudio(item: AudioItem): void {
    if (this.busy || this.recorder.isRecording()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除这段录音？',
      message: '删除后无法恢复。未同步到手机的音频也会一并删除。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Palette.ERROR,
        action: () => {
          try {
            const items = this.queueStore().load();
            const target = items.find((candidate: AudioItem) => candidate.id === item.id);
            if (target !== undefined) {
              this.queueStore().removeItem(items, target);
            }
            this.queueItems = this.queueStore().load();
            this.statusNote = '录音已删除';
          } catch (e) {
            this.statusNote = '删除失败，录音仍保留';
          }
        }
      }
    });
  }

  private finishResultFromHistory(item: HistoryItem): void {
    this.resultText = item.text;
    this.resultMeta = (item.auto ? '自动停止 · ' : '') + (item.durS > 0 ? this.fmtTime(item.durS * 1000) : '');
    this.uiState = UiState.Result;
  }

  private fmtTime(ms: number): string {
    const s = Math.round(ms / 1000);
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return m + ':' + (sec < 10 ? '0' : '') + sec;
  }

  @Builder
  PrivacyView() {
    Column() {
      Text('开始使用腕记')
        .fontSize(22)
        .fontColor(Palette.INK)
        .margin({ top: 20, bottom: 10 })
      Text('请先了解录音与数据处理方式')
        .fontSize(14)
        .fontColor(Palette.MUTED)
        .margin({ bottom: 18 })
      Text('腕记仅在你开始录音时使用麦克风。录音先保存在手表本地；通过蓝牙传到你已绑定的手机并确认接收后，手表才会删除对应副本。')
        .fontSize(14)
        .lineHeight(20)
        .fontColor(Palette.INK)
        .width('100%')
      Text('手机可按你的操作将录音发送到腕记私有服务，用于转写和生成纪要。腕记不含广告，不进行跨应用追踪，也不出售个人信息。')
        .fontSize(14)
        .lineHeight(20)
        .fontColor(Palette.INK)
        .width('100%')
        .margin({ top: 12 })
      Text('录音前请确保已获得参与者同意。你可以在待同步列表长按录音并确认删除。')
        .fontSize(14)
        .lineHeight(20)
        .fontColor(Palette.WARN)
        .width('100%')
        .margin({ top: 12, bottom: 18 })
      if (this.privacyConsentVersion < PRIVACY_CONSENT_VERSION) {
        Button('同意并继续')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontColor(Palette.INK)
          .backgroundColor(Palette.JADE_DARK)
          .onClick(() => {
            this.acceptPrivacy();
          })
      } else {
        Button('返回')
          .width(112)
          .height(42)
          .fontSize(15)
          .fontColor(Palette.INK)
          .backgroundColor(Palette.JADE_DARK)
          .onClick(() => {
            this.showPrivacy = false;
          })
      }
      Text('完整版：wanji-api.memtrix.dev/privacy')
        .fontSize(11)
        .fontColor(Palette.DIM)
        .margin({ top: 14, bottom: 24 })
    }
    .width('100%')
    .padding({ left: 36, right: 36 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  IdleView() {
    Column() {
      Text('腕记')
        .fontSize(16)
        .fontColor(Palette.MUTED)
      Button('录音')
        .width(148)
        .height(148)
        .type(ButtonType.Circle)
        .fontSize(20)
        .fontColor(Palette.INK)
        .backgroundColor(Palette.JADE_DARK)
        .margin({ top: 34, bottom: 30 })
        .onClick(() => {
          this.onPrimaryAction();
        })
      Text(this.idleHintText())
        .fontSize(13)
        .fontColor((this.permissionDenied || this.bluetoothPermissionDenied) ? Palette.WARN : Palette.DIM)
      Button(this.usesBluetoothPhone() ? '重新绑定' : '绑定手机')
        .width(112)
        .height(36)
        .fontSize(13)
        .fontColor(this.usesBluetoothPhone() ? Palette.MUTED : Palette.INK)
        .backgroundColor(this.usesBluetoothPhone() ? Color.Transparent : Palette.JADE_DARK)
        .margin({ top: 10 })
        .onClick(() => {
          this.beginPairing();
        })
      if (this.queueNotice() !== '') {
        Text(this.queueNotice())
          .fontSize(12)
          .fontColor(Palette.WARN)
          .margin({ top: 8 })
          .onClick(() => {
            this.retryQueueFromIdle();
          })
      }
      if (this.usesBluetoothPhone() && this.queueHasRetry()) {
        Button('传到手机')
          .width(118)
          .height(36)
          .fontSize(14)
          .fontColor(Palette.INK)
          .backgroundColor(Palette.JADE_DARK)
          .margin({ top: 8 })
          .enabled(!this.busy && !this.recorder.isRecording())
          .onClick(() => {
            this.retryQueueFromIdle();
          })
      }
      if (this.history.length > 0) {
        Text('上滑看历史')
          .fontSize(12)
          .fontColor(Palette.DIM)
          .margin({ top: 8 })
      }
      Button('隐私说明')
        .height(36)
        .fontSize(12)
        .fontColor(Palette.MUTED)
        .backgroundColor(Color.Transparent)
        .margin({ top: 8 })
        .onClick(() => {
          this.showPrivacy = true;
        })
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  StartingView() {
    Column() {
      Text(this.statusNote !== '' ? this.statusNote : '正在启动麦克风')
        .fontSize(16)
        .fontColor(Palette.MUTED)
      Column() {
        LoadingProgress()
          .width(58)
          .height(58)
          .color(Palette.JADE)
        Text('请保持手表靠近声源')
          .fontSize(13)
          .fontColor(Palette.DIM)
          .margin({ top: 14 })
      }
      .margin({ top: 26, bottom: 24 })
      Text('启动后自动开始计时')
        .fontSize(13)
        .fontColor(Palette.DIM)
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  RecordingView() {
    Column() {
      Text('录音中')
        .fontSize(16)
        .fontColor(Palette.RECORD)
      Stack() {
        Progress({ value: this.elapsedMs, total: AacRecorder.MAX_MS, type: ProgressType.Ring })
          .width(220)
          .height(220)
          .color(Palette.RECORD)
          .backgroundColor(Palette.RECORD_DARK)
          .style({ strokeWidth: 6 })
        // 仅内圈可点（150px），防止整环误触；长按丢弃是更高门槛的破坏性操作
        Column() {
          Text(this.fmtTime(this.elapsedMs))
            .fontSize(46)
            .fontColor(Palette.INK)
          Text('轻点停止 · 长按丢弃')
            .fontSize(13)
            .fontColor(Palette.MUTED)
            .margin({ top: 4 })
        }
        .width(150)
        .height(150)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          // 长按松手可能补发 click：1s 抑制窗，防止"丢弃完立即误开新录音"
          if (Date.now() < this.suppressClickUntil) {
            return;
          }
          this.onPrimaryAction();
        })
        .gesture(LongPressGesture({ duration: 800 })
          .onAction(() => {
            this.suppressClickUntil = Date.now() + 1000;
            this.discardRecording();
          })
          // 抑制窗以松手时刻为准——长按超过 1s 再松手，识别点设的窗已过期
          .onActionEnd(() => {
            this.suppressClickUntil = Date.now() + 600;
          })
          .onActionCancel(() => {
            this.suppressClickUntil = Date.now() + 600;
          }))
      }
      .margin({ top: 14, bottom: 14 })
      Text(this.elapsedMs >= 270000 ? '即将自动停止' : '5:00 自动停止')
        .fontSize(13)
        .fontColor(this.elapsedMs >= 270000 ? Palette.WARN : Palette.DIM)
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  UploadingView() {
    Column() {
      Text(this.statusNote !== '' ? this.statusNote : uploadTargetLabel())
        .fontSize(16)
        .fontColor(this.statusNote !== '' ? Palette.WARN : Palette.MUTED)
      Column() {
        LoadingProgress()
          .width(64)
          .height(64)
          .color(Palette.JADE)
        Text('音频已保存')
          .fontSize(13)
          .fontColor(Palette.MUTED)
          .margin({ top: 14 })
      }
      .margin({ top: 24, bottom: 24 })
      Text('请稍候')
        .fontSize(13)
        .fontColor(Palette.DIM)
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ResultView() {
    Column() {
      Text('转写完成')
        .fontSize(15)
        .fontColor(Palette.JADE)
      if (this.resultMeta !== '') {
        Text(this.resultMeta)
          .fontSize(12)
          .fontColor(Palette.MUTED)
          .margin({ top: 2 })
      }
      Text(this.resultText)
        .fontSize(17)
        .lineHeight(24)
        .fontColor(Palette.INK)
        .textAlign(TextAlign.Start)
        .width('100%')
        .margin({ top: 14, bottom: 18 })
      Button('再录')
        .width(104)
        .height(104)
        .type(ButtonType.Circle)
        .fontSize(19)
        .fontColor(Palette.INK)
        .backgroundColor(Palette.JADE_DARK)
        .onClick(() => {
          this.onPrimaryAction();
        })
      Text('上滑看历史')
        .fontSize(12)
        .fontColor(Palette.DIM)
        .margin({ top: 10 })
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ErrorView() {
    Column() {
      Text(this.statusNote !== '' ? this.statusNote : '转写失败')
        .fontSize(16)
        .fontColor(Palette.ERROR)
      Stack() {
        Circle()
          .width(172)
          .height(172)
          .fill(Palette.RECORD_DARK)
        Column() {
          Text('可重试')
            .fontSize(28)
            .fontColor(Palette.INK)
          Text(this.queueHasRetry() ? '音频已保留' : '请重新录音')
            .fontSize(13)
            .fontColor(Palette.MUTED)
            .margin({ top: 4 })
        }
      }
      .margin({ top: 18, bottom: 18 })
      .onClick(() => {
        this.onPrimaryAction();
      })
      Text(this.queueHasRetry() ? '轻点重试' : '轻点重录')
        .fontSize(13)
        .fontColor(Palette.DIM)
    }
    .alignItems(HorizontalAlign.Center)
  }

  private idleHintText(): string {
    if (this.permissionDenied) {
      return '请在设置中允许麦克风';
    }
    if (this.bluetoothPermissionDenied) {
      return '请允许蓝牙，之后会自动传';
    }
    if (!this.usesBluetoothPhone()) {
      return this.pairingUntil > Date.now() ? '等待手机完成绑定' : '可先录音，绑定后自动传';
    }
    return '录完自动传到手机';
  }

  @Builder
  HistorySection() {
    Column() {
      Text('最近记录')
        .fontSize(17)
        .fontColor(Palette.INK)
        .margin({ top: 26, bottom: 8 })
      ForEach(this.history, (item: HistoryItem, idx: number) => {
        Column() {
          Text(item.text)
            .fontSize(15)
            .fontColor(Palette.INK)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text((item.auto ? '自动停止 · ' : '') + (item.durS > 0 ? this.fmtTime(item.durS * 1000) : ''))
            .fontSize(12)
            .fontColor(Palette.MUTED)
            .margin({ top: 2 })
            .width('100%')
        }
        .width('100%')
        .constraintSize({ minHeight: 64 })
        .justifyContent(FlexAlign.Center)
        .padding({ top: 10, bottom: 10 })
        .border({ width: { bottom: idx < this.history.length - 1 ? 1 : 0 }, color: Palette.SEPARATOR })
        .onClick(() => {
          // 仅静止态可打开历史详情，防止从录音/上传态逃逸导致状态机脱轨
          if (this.uiState !== UiState.Idle && this.uiState !== UiState.Result) {
            return;
          }
          this.finishResultFromHistory(item);
        })
      }, (item: HistoryItem, idx: number) => idx + '-' + item.text.slice(0, 8))
    }
    .width('100%')
    .padding({ left: 36, right: 36 })
  }

  @Builder
  QueueSection() {
    Column() {
      Text('待同步')
        .fontSize(17)
        .fontColor(Palette.INK)
        .margin({ top: 26, bottom: 8 })
      ForEach(this.queueItems, (item: AudioItem, idx: number) => {
        Column() {
          Text((this.usesBluetoothPhone() ? (item.state === 'failed' ? '等待手机' : '自动传输') : '等待绑定') + ' · ' + this.fmtTime(item.durS * 1000))
            .fontSize(15)
            .fontColor(Palette.INK)
            .width('100%')
          Text(this.fmtDate(item.createdAt) + ' · ' + this.fmtBytes(item.sizeBytes)
            + (item.lastError !== '' ? ' · ' + item.lastError : ''))
            .fontSize(12)
            .fontColor(item.state === 'failed' ? Palette.WARN : Palette.MUTED)
            .margin({ top: 2 })
            .width('100%')
          if (this.usesBluetoothPhone()) {
            Text('轻点传到手机')
              .fontSize(12)
              .fontColor(Palette.JADE)
              .margin({ top: 4 })
              .width('100%')
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 60 })
        .justifyContent(FlexAlign.Center)
        .padding({ top: 10, bottom: 10 })
        .border({ width: { bottom: idx < this.queueItems.length - 1 ? 1 : 0 }, color: Palette.SEPARATOR })
        .onClick(() => {
          if (this.uiState !== UiState.Idle && this.uiState !== UiState.Result && this.uiState !== UiState.Error) {
            return;
          }
          this.currentItemId = item.id;
          this.retryUpload();
        })
        .gesture(LongPressGesture({ duration: 800 })
          .onAction(() => {
            this.confirmDeleteQueuedAudio(item);
          }))
      }, (item: AudioItem) => item.id)
    }
    .width('100%')
    .padding({ left: 36, right: 36 })
  }

  build() {
    Scroll() {
      Column() {
        if (this.showPrivacy) {
          this.PrivacyView()
        } else {
        Column() {
          if (this.uiState === UiState.Starting) {
            this.StartingView()
          } else if (this.uiState === UiState.Recording) {
            this.RecordingView()
          } else if (this.uiState === UiState.Uploading) {
            this.UploadingView()
          } else if (this.uiState === UiState.Result) {
            this.ResultView()
          } else if (this.uiState === UiState.Error) {
            this.ErrorView()
          } else {
            this.IdleView()
          }
        }
        .constraintSize({ minHeight: 420 })
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .padding({ left: 48, right: 48, top: 36, bottom: 20 })

        if (this.history.length > 0 &&
          (this.uiState === UiState.Idle || this.uiState === UiState.Result)) {
          this.HistorySection()
        }
        if (this.queueItems.length > 0 &&
          (this.uiState === UiState.Idle || this.uiState === UiState.Result || this.uiState === UiState.Error)) {
          this.QueueSection()
        }
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }
}
