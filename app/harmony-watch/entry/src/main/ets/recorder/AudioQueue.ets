import { fileIo as fs } from '@kit.CoreFileKit';
import { AacRecording } from './AacRecorder';

export const AUDIO_PENDING: string = 'pending';
export const AUDIO_SYNCING: string = 'syncing';
export const AUDIO_FAILED: string = 'failed';

const INDEX_FILE: string = 'wanji-queue-index.json';
const AUDIO_PREFIX: string = 'wanji-queue-';
const AUDIO_SUFFIX: string = '.m4a';

export class AudioItem {
  id: string = '';
  filePath: string = '';
  createdAt: number = 0;
  durS: number = 0;
  sizeBytes: number = 0;
  state: string = AUDIO_PENDING;
  attempts: number = 0;
  lastError: string = '';
  auto: boolean = false;
}

class AudioItemJson {
  id?: string;
  filePath?: string;
  createdAt?: number;
  durS?: number;
  sizeBytes?: number;
  state?: string;
  attempts?: number;
  lastError?: string;
  auto?: boolean;
}

export class QueueStats {
  pending: number = 0;
  failed: number = 0;
  syncing: number = 0;
  bytes: number = 0;

  total(): number {
    return this.pending + this.failed + this.syncing;
  }
}

export class AudioQueueStore {
  private filesDir: string;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  load(): AudioItem[] {
    let result: AudioItem[] = [];
    try {
      const raw = fs.readTextSync(this.indexPath());
      const rows = JSON.parse(raw) as AudioItemJson[];
      for (let i = 0; i < rows.length; i++) {
        const item = this.fromJson(rows[i]);
        if (item.id.length === 0 || item.filePath.length === 0) {
          continue;
        }
        if (!this.exists(item.filePath)) {
          continue;
        }
        if (item.state === AUDIO_SYNCING) {
          item.state = AUDIO_FAILED;
          item.lastError = '上传中断';
        }
        result.push(item);
      }
    } catch (e) {
      result = [];
    }
    const recovered = this.recoverOrphanAudioFiles(result);
    this.sortNewestFirst(result);
    if (recovered) {
      try {
        this.save(result);
      } catch (e2) {
        // 内存队列仍可显示和重试；下次保存成功后会重新落索引。
      }
    }
    return result;
  }

  save(items: AudioItem[]): void {
    const rows: AudioItemJson[] = [];
    for (let i = 0; i < items.length; i++) {
      rows.push(this.toJson(items[i]));
    }
    const tmp = this.indexPath() + '.tmp';
    let fd = -1;
    try {
      const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fd = file.fd;
      fs.writeSync(fd, JSON.stringify(rows));
      fs.closeSync(fd);
      fd = -1;
      fs.renameSync(tmp, this.indexPath());
    } catch (e) {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e2) {
        }
      }
      try {
        fs.unlinkSync(tmp);
      } catch (e3) {
      }
      throw new Error('ERROR: queue index save failed: ' + JSON.stringify(e));
    }
  }

  storeRecording(recording: AacRecording, durS: number, auto: boolean, items: AudioItem[]): AudioItem {
    const item = new AudioItem();
    item.id = 'a' + Date.now().toString() + '-' + Math.floor(Math.random() * 1000000).toString();
    item.createdAt = Date.now();
    item.durS = durS;
    item.auto = auto;
    item.filePath = this.audioPath(item.id);
    try {
      fs.moveFileSync(recording.path, item.filePath);
    } catch (e) {
      fs.copyFileSync(recording.path, item.filePath);
      try {
        fs.unlinkSync(recording.path);
      } catch (e2) {
      }
    }
    try {
      const stat = fs.statSync(item.filePath);
      item.sizeBytes = stat.size;
    } catch (e3) {
      item.sizeBytes = recording.sizeBytes;
    }
    item.state = AUDIO_PENDING;
    items.unshift(item);
    this.sortNewestFirst(items);
    this.save(items);
    return item;
  }

  readAudio(item: AudioItem): ArrayBuffer {
    const stat = fs.statSync(item.filePath);
    const buf = new ArrayBuffer(stat.size);
    const file = fs.openSync(item.filePath, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buf);
    } finally {
      fs.closeSync(file);
    }
    return buf;
  }

  removeItem(items: AudioItem[], target: AudioItem): void {
    for (let i = items.length - 1; i >= 0; i--) {
      if (items[i].id === target.id) {
        try {
          fs.unlinkSync(items[i].filePath);
        } catch (e) {
        }
        items.splice(i, 1);
      }
    }
    this.save(items);
  }

  stats(items: AudioItem[]): QueueStats {
    const stats = new QueueStats();
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.state === AUDIO_FAILED) {
        stats.failed++;
      } else if (item.state === AUDIO_SYNCING) {
        stats.syncing++;
      } else {
        stats.pending++;
      }
      stats.bytes += item.sizeBytes;
    }
    return stats;
  }

  findUploadCandidate(items: AudioItem[], preferId: string): AudioItem | null {
    if (preferId.length > 0) {
      for (let i = 0; i < items.length; i++) {
        if (items[i].id === preferId && (items[i].state === AUDIO_PENDING || items[i].state === AUDIO_FAILED)) {
          return items[i];
        }
      }
    }
    for (let j = 0; j < items.length; j++) {
      if (items[j].state === AUDIO_PENDING || items[j].state === AUDIO_FAILED) {
        return items[j];
      }
    }
    return null;
  }

  shortError(e: Object): string {
    let raw = '';
    if (e instanceof Error) {
      raw = e.message;
    }
    if (raw.length === 0) {
      raw = JSON.stringify(e);
    }
    if (raw.startsWith('ERROR: ')) {
      raw = raw.substring(7);
    }
    return raw.length > 32 ? raw.slice(0, 32) : raw;
  }

  private indexPath(): string {
    return this.filesDir + '/' + INDEX_FILE;
  }

  private audioPath(id: string): string {
    return this.filesDir + '/' + AUDIO_PREFIX + id + AUDIO_SUFFIX;
  }

  private recoverOrphanAudioFiles(items: AudioItem[]): boolean {
    let changed = false;
    let files: string[] = [];
    try {
      files = fs.listFileSync(this.filesDir);
    } catch (e) {
      return false;
    }

    for (let i = 0; i < files.length; i++) {
      const name = files[i];
      if (!name.startsWith(AUDIO_PREFIX) || !name.endsWith(AUDIO_SUFFIX)) {
        continue;
      }
      const path = this.filesDir + '/' + name;
      if (this.containsPath(items, path)) {
        continue;
      }

      const item = new AudioItem();
      item.id = name.slice(AUDIO_PREFIX.length, name.length - AUDIO_SUFFIX.length);
      item.filePath = path;
      item.createdAt = this.createdAtFromRecoveredId(item.id);
      item.state = AUDIO_FAILED;
      item.lastError = '队列索引已恢复';
      try {
        const stat = fs.statSync(path);
        item.sizeBytes = stat.size;
      } catch (e2) {
        item.sizeBytes = 0;
      }
      items.push(item);
      changed = true;
    }
    return changed;
  }

  private containsPath(items: AudioItem[], path: string): boolean {
    for (let i = 0; i < items.length; i++) {
      if (items[i].filePath === path) {
        return true;
      }
    }
    return false;
  }

  private createdAtFromRecoveredId(id: string): number {
    if (id.startsWith('a')) {
      const parts = id.slice(1).split('-');
      if (parts.length > 0) {
        const ts = Number(parts[0]);
        if (Number.isFinite(ts) && ts > 0) {
          return ts;
        }
      }
    }
    return Date.now();
  }

  private sortNewestFirst(items: AudioItem[]): void {
    items.sort((a: AudioItem, b: AudioItem): number => {
      if (a.createdAt === b.createdAt) {
        return a.id < b.id ? -1 : 1;
      }
      return b.createdAt - a.createdAt;
    });
  }

  private exists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  private toJson(item: AudioItem): AudioItemJson {
    const row = new AudioItemJson();
    row.id = item.id;
    row.filePath = item.filePath;
    row.createdAt = item.createdAt;
    row.durS = item.durS;
    row.sizeBytes = item.sizeBytes;
    row.state = item.state;
    row.attempts = item.attempts;
    row.lastError = item.lastError;
    row.auto = item.auto;
    return row;
  }

  private fromJson(row: AudioItemJson): AudioItem {
    const item = new AudioItem();
    item.id = typeof row.id === 'string' ? row.id : '';
    item.filePath = typeof row.filePath === 'string' ? row.filePath : '';
    item.createdAt = typeof row.createdAt === 'number' ? row.createdAt : 0;
    item.durS = typeof row.durS === 'number' ? row.durS : 0;
    item.sizeBytes = typeof row.sizeBytes === 'number' ? row.sizeBytes : 0;
    item.state = typeof row.state === 'string' ? row.state : AUDIO_PENDING;
    item.attempts = typeof row.attempts === 'number' ? row.attempts : 0;
    item.lastError = typeof row.lastError === 'string' ? row.lastError : '';
    item.auto = typeof row.auto === 'boolean' ? row.auto : false;
    return item;
  }
}
