import { ble, constant } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';

const WANJI_BLE_ENDPOINT = 'ble://wanji';
const WANJI_SERVICE_UUID = '7E1A1000-AD67-4F51-98E4-65C8E60B9C01';
const WANJI_WRITE_UUID = '7E1A1001-AD67-4F51-98E4-65C8E60B9C01';
const BLE_MAX_FRAME_BYTES = 160;
const BLE_MAX_PAYLOAD_BYTES = BLE_MAX_FRAME_BYTES - 1;
const BLE_CHUNK_BYTES = BLE_MAX_PAYLOAD_BYTES;
const BLE_SCAN_TIMEOUT_MS = 12000;
const BLE_CONNECT_TIMEOUT_MS = 10000;

export function isBluetoothPhoneEndpoint(phoneBase: string): boolean {
  return phoneBase.trim().toLowerCase() === WANJI_BLE_ENDPOINT;
}

export async function uploadPhoneAudioBluetooth(audioBuf: ArrayBuffer,
                                                createdAt: number,
                                                uploadId: string,
                                                phoneToken: string): Promise<void> {
  if (audioBuf.byteLength === 0) {
    throw new Error('ERROR: 录音为空，请重新录制');
  }
  if (!isValidPhoneToken(phoneToken)) {
    throw new Error('ERROR: 尚未绑定手机，请重新绑定');
  }

  const deviceId = await findWanjiReceiver();
  const client = ble.createGattClientDevice(deviceId);
  try {
    await connectGatt(client, deviceId);
    const characteristic = await findWriteCharacteristic(client);
    const filename = 'wanji-' + Date.now() + '.m4a';
    const header = JSON.stringify({
      t: phoneToken,
      f: filename,
      c: createdAt > 0 ? Math.round(createdAt) : Date.now(),
      u: uploadId,
      s: audioBuf.byteLength
    });
    const encoder = new util.TextEncoder();
    await writeFrame(client, characteristic, 1, arrayBufferFromBytes(encoder.encodeInto(header)),
      '蓝牙头信息过长，请重新生成较短 Token 后复制配置');

    let offset = 0;
    while (offset < audioBuf.byteLength) {
      const end = Math.min(offset + BLE_CHUNK_BYTES, audioBuf.byteLength);
      await writeFrame(client, characteristic, 2, audioBuf.slice(offset, end),
        '蓝牙分片过大，请更新两端腕记版本');
      offset = end;
    }
    await writeFrame(client, characteristic, 3, new ArrayBuffer(0),
      '蓝牙结束帧异常，请更新两端腕记版本');
  } finally {
    try {
      client.disconnect();
    } catch (e) {
    }
    try {
      client.close();
    } catch (e) {
    }
  }
}

export function isValidPhoneToken(token: string): boolean {
  if (token.length < 6 || token.length > 64) {
    return false;
  }
  const allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.';
  for (let i = 0; i < token.length; i++) {
    if (allowed.indexOf(token.charAt(i)) < 0) {
      return false;
    }
  }
  return true;
}

function arrayBufferFromBytes(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

async function findWanjiReceiver(): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    let finished = false;
    const stop = (): void => {
      try {
        ble.off('BLEDeviceFind', onFound);
      } catch (e) {
      }
      try {
        ble.stopBLEScan();
      } catch (e) {
      }
    };
    const finish = (deviceId: string): void => {
      if (finished) {
        return;
      }
      finished = true;
      stop();
      resolve(deviceId);
    };
    const fail = (message: string): void => {
      if (finished) {
        return;
      }
      finished = true;
      stop();
      reject(new Error(message));
    };
    const onFound = (results: Array<ble.ScanResult>): void => {
      for (let i = 0; i < results.length; i++) {
        const result = results[i];
        if (!result.connectable) {
          continue;
        }
        if (hasServiceUuid(result, WANJI_SERVICE_UUID)) {
          finish(result.deviceId);
          return;
        }
      }
    };

    try {
      ble.on('BLEDeviceFind', onFound);
      ble.startBLEScan([{ serviceUuid: WANJI_SERVICE_UUID }], {
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
      });
      setTimeout(() => fail('ERROR: 未找到手机腕记，请打开 iPhone 腕记并保持在前台'), BLE_SCAN_TIMEOUT_MS);
    } catch (e) {
      fail('ERROR: 蓝牙扫描失败，请确认手表蓝牙已开启');
    }
  });
}

function hasServiceUuid(result: ble.ScanResult, uuid: string): boolean {
  const target = uuid.toLowerCase();
  if (result.serviceUuids !== undefined) {
    for (let i = 0; i < result.serviceUuids.length; i++) {
      if (result.serviceUuids[i].toLowerCase() === target) {
        return true;
      }
    }
  }
  return result.deviceName === 'Wanji';
}

async function connectGatt(client: ble.GattClientDevice, deviceId: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let finished = false;
    const cleanup = (): void => {
      try {
        client.off('BLEConnectionStateChange', onState);
      } catch (e) {
      }
    };
    const done = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      cleanup();
      resolve();
    };
    const fail = (message: string): void => {
      if (finished) {
        return;
      }
      finished = true;
      cleanup();
      reject(new Error(message));
    };
    const onState = (state: ble.BLEConnectionChangeState): void => {
      if (state.deviceId !== deviceId) {
        return;
      }
      if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
        done();
      } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
        fail('ERROR: 蓝牙连接已断开，请靠近手机后重试');
      }
    };
    try {
      client.on('BLEConnectionStateChange', onState);
      client.connect();
      setTimeout(() => fail('ERROR: 蓝牙连接超时，请打开手机腕记后重试'), BLE_CONNECT_TIMEOUT_MS);
    } catch (e) {
      fail('ERROR: 蓝牙连接失败，请确认手机腕记蓝牙权限');
    }
  });
}

async function findWriteCharacteristic(client: ble.GattClientDevice): Promise<ble.BLECharacteristic> {
  const services = await client.getServices();
  for (let i = 0; i < services.length; i++) {
    const service = services[i];
    if (service.serviceUuid.toLowerCase() !== WANJI_SERVICE_UUID.toLowerCase()) {
      continue;
    }
    for (let j = 0; j < service.characteristics.length; j++) {
      const characteristic = service.characteristics[j];
      if (characteristic.characteristicUuid.toLowerCase() === WANJI_WRITE_UUID.toLowerCase()) {
        return characteristic;
      }
    }
  }
  throw new Error('ERROR: 手机腕记蓝牙服务不匹配，请更新两端版本');
}

async function writeFrame(client: ble.GattClientDevice,
                          characteristic: ble.BLECharacteristic,
                          frameType: number,
                          payload: ArrayBuffer,
                          oversizedMessage: string): Promise<void> {
  const body = new Uint8Array(payload);
  if (body.byteLength > BLE_MAX_PAYLOAD_BYTES) {
    throw new Error('ERROR: ' + oversizedMessage);
  }
  const frame = new ArrayBuffer(body.byteLength + 1);
  const out = new Uint8Array(frame);
  out[0] = frameType;
  out.set(body, 1);
  characteristic.characteristicValue = frame;
  await client.writeCharacteristicValue(characteristic, ble.GattWriteType.WRITE);
}
