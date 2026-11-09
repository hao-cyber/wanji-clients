import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def quoted_constant(source: str, name: str) -> str:
    match = re.search(rf"{re.escape(name)}\s*=\s*['\"]([^'\"]+)['\"]", source)
    assert match, f"missing constant {name}"
    return match.group(1).upper()


def test_harmony_and_ios_ble_contract_match():
    ios = read("app/wanji-ios/Wanji/AppSettings.swift")
    upload = read("app/harmony-watch/entry/src/main/ets/net/BluetoothUploader.ets")
    sync = read("app/harmony-watch/entry/src/main/ets/net/WatchSyncAdvertiser.ets")

    assert quoted_constant(upload, "WANJI_SERVICE_UUID") == quoted_constant(ios, "bleServiceUUID")
    assert quoted_constant(upload, "WANJI_WRITE_UUID") == quoted_constant(ios, "bleWriteCharacteristicUUID")
    assert quoted_constant(sync, "WANJI_WATCH_SYNC_SERVICE_UUID") == quoted_constant(ios, "watchSyncServiceUUID")
    assert quoted_constant(sync, "WANJI_WATCH_SYNC_COMMAND_UUID") == quoted_constant(
        ios, "watchSyncCommandCharacteristicUUID"
    )


def test_runtime_binding_contract_is_cross_client_and_not_compiled_secret():
    ios = read("app/wanji-ios/Wanji/BluetoothWatchSyncRequester.swift")
    harmony_sync = read("app/harmony-watch/entry/src/main/ets/net/WatchSyncAdvertiser.ets")
    harmony_upload = read("app/harmony-watch/entry/src/main/ets/net/Uploader.ets")

    assert '"bind:"' in ios
    assert "text.startsWith('bind:')" in harmony_sync
    assert "this.canBind()" in harmony_sync
    assert "isValidPhoneToken(token)" in harmony_sync
    assert "Secrets.PHONE_TOKEN" not in harmony_sync
    assert "Secrets.PHONE_TOKEN" not in harmony_upload


def test_ios_companion_has_harmony_push_compatibility_fallback():
    content = read("app/wanji-ios/Wanji/ContentView.swift")

    assert "@StateObject private var watchReceiver = BluetoothWatchReceiver()" in content
    assert "watchReceiver.onAudioReceived" in content
    assert "startHarmonyPushFallback" in content
    assert 'case "手表端版本需要更新", "手表录音服务不可用", "手表录音服务连接失败"' in content
    assert "watchSyncRequester.start()" in content


def test_harmony_release_requests_consent_before_sensitive_permissions():
    page = read("app/harmony-watch/entry/src/main/ets/pages/Index.ets")
    consent_gate = page.index("if (this.privacyConsentVersion < PRIVACY_CONSENT_VERSION)")
    activation = page.index("await this.activateServices(true)")
    assert consent_gate < activation
    assert "this.acceptPrivacy()" in page
    assert "隐私说明" in page
    assert "删除这段录音？" in page


def test_harmony_store_binary_is_ble_only():
    module = read("app/harmony-watch/entry/src/main/module.json5")
    uploader = read("app/harmony-watch/entry/src/main/ets/net/Uploader.ets")
    assert "ohos.permission.INTERNET" not in module
    assert "@kit.NetworkKit" not in uploader
    assert "uploadPhoneAudioBluetooth" in uploader


def test_harmony_release_versions_are_aligned():
    app_scope = json.loads(read("app/harmony-watch/AppScope/app.json5"))
    harmony_name = app_scope["app"]["versionName"]
    root_package = json.loads(read("app/harmony-watch/oh-package.json5"))
    entry_package = json.loads(read("app/harmony-watch/entry/oh-package.json5"))

    assert harmony_name == "1.0.0"
    assert app_scope["app"]["versionCode"] > 0
    assert root_package["version"] == harmony_name
    assert entry_package["version"] == harmony_name
