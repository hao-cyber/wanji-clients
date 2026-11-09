import { audio } from '@kit.AudioKit';

/**
 * 16kHz 单声道 S16LE PCM 录音器，stop() 返回完整 WAV（RIFF 头 + PCM）。
 * source 必须是 SOURCE_TYPE_MIC（原始采集）——禁止 VOICE_COMMUNICATION，
 * 通话链路的 3A 处理会把非佩戴者人声当噪声压掉，环境收音就废了。
 *
 * 整段 PCM 驻留内存（无落盘），上限 MAX_MS 防 OOM：
 * 16kHz*16bit ≈ 1.9MB/min，5 分钟 ≈ 9.6MB + buildWav 拷贝一份的瞬时峰值。
 * v1 改流式落盘后解除上限。
 */
export class WavRecorder {
  private static readonly SAMPLE_RATE = 16000;
  static readonly MAX_MS = 5 * 60 * 1000;
  private static readonly MAX_BYTES = WavRecorder.SAMPLE_RATE * 2 * (WavRecorder.MAX_MS / 1000);

  private capturer: audio.AudioCapturer | null = null;
  private starting: boolean = false;
  private startPromise: Promise<void> | null = null;
  private stopPromise: Promise<ArrayBuffer> | null = null;
  private chunks: ArrayBuffer[] = [];
  private totalBytes = 0;
  private capped = false;

  isRecording(): boolean {
    return this.capturer !== null || this.starting;
  }

  isCapped(): boolean {
    return this.capped;
  }

  recordedMs(): number {
    return Math.round(this.totalBytes / 2 / WavRecorder.SAMPLE_RATE * 1000);
  }

  async start(): Promise<void> {
    if (this.capturer || this.starting) {
      return;
    }
    this.starting = true;
    this.startPromise = this.doStart();
    try {
      await this.startPromise;
    } finally {
      this.startPromise = null;
      this.starting = false;
    }
  }

  private async doStart(): Promise<void> {
    this.chunks = [];
    this.totalBytes = 0;
    this.capped = false;

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };

    const capturer = await audio.createAudioCapturer({
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    });
    // readData 回调的 buffer 会被复用，必须拷贝
    capturer.on('readData', (buffer: ArrayBuffer) => {
      if (this.totalBytes + buffer.byteLength > WavRecorder.MAX_BYTES) {
        this.capped = true;
        return;
      }
      const copy = buffer.slice(0);
      this.chunks.push(copy);
      this.totalBytes += copy.byteLength;
    });
    await capturer.start();
    this.capturer = capturer;
  }

  // 并发调用（UI 停止键 + 页面销毁兜底）join 同一个 stopPromise，杜绝同一 capturer 被双重 stop/release。
  // 先 join 进行中的 start，避免"页面销毁时 start 尚未完成"导致 stop 抛错、麦克风泄漏
  async stop(): Promise<ArrayBuffer> {
    if (this.startPromise) {
      try {
        await this.startPromise;
      } catch (e) {
        // start 失败则无可停，下面 capturer 为 null 自然抛错
      }
    }
    if (this.stopPromise) {
      return this.stopPromise;
    }
    const capturer = this.capturer;
    if (!capturer) {
      throw new Error('ERROR: not recording');
    }
    this.stopPromise = this.doStop(capturer);
    try {
      return await this.stopPromise;
    } finally {
      this.stopPromise = null;
    }
  }

  private async doStop(capturer: audio.AudioCapturer): Promise<ArrayBuffer> {
    try {
      await capturer.stop();
    } finally {
      try {
        capturer.off('readData');
      } catch (e) {
        // off 失败不阻断释放
      }
      try {
        await capturer.release();
      } catch (e) {
        // release 失败无法挽回，继续返回已采集数据
      }
      this.capturer = null;
    }
    return this.buildWav();
  }

  private buildWav(): ArrayBuffer {
    const dataLen = this.totalBytes;
    const wav = new ArrayBuffer(44 + dataLen);
    const view = new DataView(wav);
    const writeStr = (offset: number, s: string): void => {
      for (let i = 0; i < s.length; i++) {
        view.setUint8(offset + i, s.charCodeAt(i));
      }
    };
    writeStr(0, 'RIFF');
    view.setUint32(4, 36 + dataLen, true);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    view.setUint32(16, 16, true);                            // fmt chunk size
    view.setUint16(20, 1, true);                             // PCM
    view.setUint16(22, 1, true);                             // mono
    view.setUint32(24, WavRecorder.SAMPLE_RATE, true);
    view.setUint32(28, WavRecorder.SAMPLE_RATE * 2, true);   // byte rate
    view.setUint16(32, 2, true);                             // block align
    view.setUint16(34, 16, true);                            // bits per sample
    writeStr(36, 'data');
    view.setUint32(40, dataLen, true);

    const out = new Uint8Array(wav);
    let offset = 44;
    for (const chunk of this.chunks) {
      out.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    this.chunks = [];
    this.totalBytes = 0;
    return wav;
  }
}
