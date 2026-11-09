import { ble } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { isValidPhoneToken } from './BluetoothUploader';

const WANJI_WATCH_SYNC_SERVICE_UUID = '7E1A2000-AD67-4F51-98E4-65C8E60B9C01';
const WANJI_WATCH_SYNC_COMMAND_UUID = '7E1A2001-AD67-4F51-98E4-65C8E60B9C01';

export class WatchSyncAdvertiser {
  private server: ble.GattServer | null = null;
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private onSync: () => void = () => {};
  private currentToken: () => string = () => '';
  private canBind: () => boolean = () => false;
  private onBind: (token: string) => void = () => {};

  start(onSync: () => void,
        currentToken: () => string,
        canBind: () => boolean,
        onBind: (token: string) => void): void {
    this.onSync = onSync;
    this.currentToken = currentToken;
    this.canBind = canBind;
    this.onBind = onBind;
    if (this.server !== null) {
      return;
    }
    try {
      const server = ble.createGattServer();
      this.server = server;
      server.on('characteristicWrite', (request: ble.CharacteristicWriteRequest) => {
        this.handleWrite(request);
      });
      server.addService({
        serviceUuid: WANJI_WATCH_SYNC_SERVICE_UUID,
        isPrimary: true,
        characteristics: [{
          serviceUuid: WANJI_WATCH_SYNC_SERVICE_UUID,
          characteristicUuid: WANJI_WATCH_SYNC_COMMAND_UUID,
          characteristicValue: new ArrayBuffer(0),
          descriptors: [],
          properties: { write: true },
          permissions: { write: true }
        }]
      });
      ble.startAdvertising(
        { interval: 800, txPower: -7, connectable: true },
        {
          serviceUuids: [WANJI_WATCH_SYNC_SERVICE_UUID],
          manufactureData: [],
          serviceData: []
        }
      );
      console.info('INFO: watch sync advertiser started');
    } catch (e) {
      this.stop();
      console.error('ERROR: watch sync advertiser start failed: ' + JSON.stringify(e));
    }
  }

  stop(): void {
    const server = this.server;
    this.server = null;
    if (server === null) {
      return;
    }
    try {
      server.off('characteristicWrite');
    } catch (e) {
    }
    try {
      ble.stopAdvertising();
    } catch (e) {
    }
    try {
      server.removeService(WANJI_WATCH_SYNC_SERVICE_UUID);
    } catch (e) {
    }
    try {
      server.close();
    } catch (e) {
    }
  }

  private handleWrite(request: ble.CharacteristicWriteRequest): void {
    if (request.characteristicUuid.toLowerCase() !== WANJI_WATCH_SYNC_COMMAND_UUID.toLowerCase()) {
      console.warn('WARN: watch sync command rejected: characteristic mismatch');
      this.respond(request, 1);
      return;
    }
    const text = this.decoder.decodeToString(new Uint8Array(request.value));
    if (text.startsWith('bind:')) {
      const token = text.substring('bind:'.length);
      if (!this.canBind() || !isValidPhoneToken(token)) {
        console.warn('WARN: watch bind command rejected');
        this.respond(request, 5);
        return;
      }
      this.onBind(token);
      console.info('INFO: watch bind command accepted');
      this.respond(request, 0);
      return;
    }
    const token = this.currentToken();
    const expected = 'sync:' + token;
    if (!isValidPhoneToken(token) || text !== expected) {
      console.warn('WARN: watch sync command rejected: token mismatch');
      this.respond(request, 5);
      return;
    }
    console.info('INFO: watch sync command accepted');
    this.respond(request, 0);
    this.onSync();
  }

  private respond(request: ble.CharacteristicWriteRequest, status: number): void {
    if (!request.needRsp || this.server === null) {
      return;
    }
    try {
      this.server.sendResponse({
        deviceId: request.deviceId,
        transId: request.transId,
        status: status,
        offset: request.offset,
        value: new ArrayBuffer(0)
      });
    } catch (e) {
    }
  }
}
