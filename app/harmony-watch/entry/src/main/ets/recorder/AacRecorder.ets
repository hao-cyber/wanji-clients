import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export function withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
  return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
    const timer = setTimeout(() => {
      reject(new Error('ERROR: timeout after ' + ms + 'ms: ' + tag));
    }, ms);
    p.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }, (e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/**
 * AVRecorder AAC 录音器（32kbps 单声道 16kHz，m4a 容器）。
 * 相比 WavRecorder（PCM 1.9MB/min）流量降 ~8x（0.24MB/min），
 * voice-poc 按 ftyp magic 识别 mp4，字节 ASR 已实测可转（2026-06-13 curl 验证）。
 * 录音先落 temp 目录，stop() 返回文件路径，由 AudioQueue 接管后再清理。
 */
export class AacRecording {
  path: string = '';
  durationMs: number = 0;
  sizeBytes: number = 0;
}

export class AacRecorder {
  static readonly MAX_MS = 5 * 60 * 1000;

  // 启动时清扫崩溃残留的录音临时文件（隐私敏感，不留过夜）
  static sweepTemp(tempDir: string): void {
    try {
      const files = fs.listFileSync(tempDir);
      for (const f of files) {
        if (f.startsWith('wanji-') && f.endsWith('.m4a')) {
          try {
            fs.unlinkSync(tempDir + '/' + f);
          } catch (e) {
            // 单个删除失败不阻断
          }
        }
      }
    } catch (e) {
      // 目录不可读则跳过
    }
  }

  private recorder: media.AVRecorder | null = null;
  private starting: boolean = false;
  private startPromise: Promise<void> | null = null;
  private stopPromise: Promise<AacRecording> | null = null;
  private filePath: string = '';
  private fileFd: number = -1;
  private startedAt: number = 0;

  isRecording(): boolean {
    return this.recorder !== null || this.starting;
  }

  recordedMs(): number {
    if (this.startedAt === 0) {
      return 0;
    }
    return Date.now() - this.startedAt;
  }

  async start(tempDir: string): Promise<void> {
    if (this.recorder || this.starting) {
      return;
    }
    this.starting = true;
    this.startPromise = this.doStart(tempDir);
    try {
      await this.startPromise;
    } finally {
      this.startPromise = null;
      this.starting = false;
    }
  }

  private async doStart(tempDir: string): Promise<void> {
    this.filePath = tempDir + '/wanji-' + Date.now() + '.m4a';
    const file = fs.openSync(this.filePath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    this.fileFd = file.fd;

    let recorder: media.AVRecorder | null = null;
    try {
      recorder = await media.createAVRecorder();
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: {
          audioBitrate: 32000,
          audioChannels: 1,
          audioCodec: media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 16000,
          fileFormat: media.ContainerFormatType.CFT_MPEG_4A
        },
        url: 'fd://' + this.fileFd
      };
      await recorder.prepare(config);
      await recorder.start();
    } catch (e) {
      // 启动失败：释放半开资源（fd/临时文件/recorder），不留泄漏
      if (recorder !== null) {
        try {
          await recorder.release();
        } catch (e2) {
          // 已尽力释放
        }
      }
      try {
        fs.closeSync(this.fileFd);
      } catch (e2) {
        // fd 可能未真正打开
      }
      try {
        fs.unlinkSync(this.filePath);
      } catch (e2) {
        // 删除失败留给系统清理 temp
      }
      this.fileFd = -1;
      throw new Error('ERROR: recorder start failed: ' + JSON.stringify(e));
    }
    this.recorder = recorder;
    this.startedAt = Date.now();
  }

  // 并发调用 join 同一个 stopPromise；先 join 进行中的 start，防 teardown 竞态（同 WavRecorder）
  async stop(keepFile: boolean = true): Promise<AacRecording> {
    if (this.startPromise) {
      try {
        await this.startPromise;
      } catch (e) {
        // start 失败则无可停
      }
    }
    if (this.stopPromise) {
      return this.stopPromise;
    }
    const recorder = this.recorder;
    if (!recorder) {
      throw new Error('ERROR: not recording');
    }
    this.stopPromise = this.doStop(recorder, keepFile);
    try {
      return await this.stopPromise;
    } finally {
      this.stopPromise = null;
    }
  }

  private async doStop(recorder: media.AVRecorder, keepFile: boolean): Promise<AacRecording> {
    const durationMs = this.recordedMs();
    try {
      // stop 卡死会把 UI 永远困在转写态——超时强制走释放路径
      await withTimeout(recorder.stop(), 8000, 'avrecorder.stop');
    } finally {
      try {
        await recorder.release();
      } catch (e) {
        // release 失败不阻断读文件
      }
      this.recorder = null;
      this.startedAt = 0;
    }
    return this.finishFile(keepFile, durationMs);
  }

  private finishFile(keepFile: boolean, durationMs: number): AacRecording {
    const result = new AacRecording();
    try {
      const stat = fs.statSync(this.filePath);
      result.path = this.filePath;
      result.durationMs = durationMs;
      result.sizeBytes = stat.size;
    } finally {
      try {
        if (this.fileFd >= 0) {
          fs.closeSync(this.fileFd);
        }
      } catch (e) {
        // 写入 fd 可能已被 AVRecorder 关闭
      }
      this.fileFd = -1;
      if (!keepFile) {
        try {
          fs.unlinkSync(this.filePath);
        } catch (e) {
          // 删除失败留给系统清理 temp
        }
      }
    }
    return result;
  }
}
