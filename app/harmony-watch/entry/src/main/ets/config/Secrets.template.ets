// Legacy development template only. The clients use runtime Bluetooth binding;
// no credentials file is needed for a public build.
export class Secrets {
  // 正式产品路径固定为蓝牙传到已绑定的 iPhone 腕记。
  static readonly PHONE_BASE: string = 'ble://wanji';
  static readonly PHONE_TOKEN: string = '';
}
