package com.haowang.wristnote;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;
import java.util.zip.CRC32;

final class BluetoothWatchSyncAdvertiser {
    private static final String TAG = "WristNote";
    private static final UUID WANJI_WATCH_SYNC_SERVICE_UUID =
            UUID.fromString("7E1A2000-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID WANJI_WATCH_SYNC_COMMAND_UUID =
            UUID.fromString("7E1A2001-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID PULL_SERVICE_UUID =
            UUID.fromString("7E1A4400-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID PULL_QUEUE_UUID =
            UUID.fromString("7E1A4401-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID PULL_CONTROL_UUID =
            UUID.fromString("7E1A4402-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID PULL_DATA_UUID =
            UUID.fromString("7E1A4403-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID PULL_ACK_UUID =
            UUID.fromString("7E1A4404-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID CLIENT_CONFIG_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805F9B34FB");
    private static final int WANJI_MANUFACTURER_ID = 0xFFFF;
    private static final byte[] WANJI_AD_MARKER = new byte[] {'W', 'A', 'N', 'J', 'I'};
    private static final int DEFAULT_ATT_MTU = 23;
    private static final int IOS_EFFECTIVE_ATT_MTU = 247;
    private static final int MAX_CHUNK_BYTES = 512;
    private static final int STABLE_NOTIFY_PAYLOAD_BYTES = 192;
    private static final int DEFAULT_NOTIFY_CREDIT_BYTES = STABLE_NOTIFY_PAYLOAD_BYTES * 16;
    private static final int NOTIFY_HEADER_BYTES = 8;
    private static final int DATA_READ_WINDOW_BYTES = 16 * 1024;
    private static final int MAX_NOTIFY_RETRIES = 3;
    private static final long NOTIFY_RETRY_DELAY_MS = 35;
    private static final long NOTIFY_SENT_WATCHDOG_MS = 20_000;
    private static final long ADVERTISING_REFRESH_MS = 30_000;
    private static final long GATT_REBUILD_AFTER_DISCONNECT_MS = 700;
    private static final String PULL_ERROR_MISSING_AUDIO = "ble_missing_audio";
    private static final String PULL_ERROR_UNREADABLE_AUDIO = "ble_unreadable_audio";

    private final Handler main = new Handler(Looper.getMainLooper());
    private BluetoothManager manager;
    private BluetoothLeAdvertiser advertiser;
    private BluetoothGattServer server;
    private AdvertiseSettings advertiseSettings;
    private AdvertiseData advertiseData;
    private BluetoothGattService pendingPullService;
    private Context appContext;
    private AudioStore store;
    private Runnable onSync = () -> {};
    private Runnable onBound = () -> {};
    private BluetoothGattCharacteristic queueCharacteristic;
    private BluetoothGattCharacteristic controlCharacteristic;
    private BluetoothGattCharacteristic dataCharacteristic;
    private BluetoothGattCharacteristic ackCharacteristic;
    private android.bluetooth.BluetoothDevice notifyDevice;
    private byte[] selectedAudio;
    private AudioItem selectedItem;
    private String selectedId = "";
    private String queuedShortId = "";
    private String queuedFullId = "";
    private int selectedOffset;
    private byte[] dataReadWindow;
    private int dataReadWindowStart;
    private int currentMtu = DEFAULT_ATT_MTU;
    private boolean notifyEnabled;
    private boolean streaming;
    private boolean loadingSelectedAudio;
    private long connectedAtMs;
    private int notifyRetryCount;
    private int lastNotifyStart = -1;
    private int lastNotifyEnd = -1;
    private int notifyCreditEnd = -1;
    private Runnable notifySentWatchdog;
    private int lastControlLogOffset = -1;
    private int lastReadLogOffset = -1;
    private boolean syncServiceAdded;
    private boolean pullServiceAdded;
    private boolean advertising;
    private boolean advertiseStarting;
    private final Runnable restartAdvertising = this::restartAdvertising;
    private final Runnable refreshAdvertising = this::refreshAdvertising;
    private String pendingGattRebuildReason = "";
    private final Runnable rebuildGattServer = () -> {
        String reason = pendingGattRebuildReason.length() == 0
                ? "scheduled"
                : pendingGattRebuildReason;
        pendingGattRebuildReason = "";
        restartGattServer(reason);
    };

    void start(Context context, AudioStore audioStore, Runnable onSync, Runnable onBound) {
        appContext = context.getApplicationContext();
        store = audioStore;
        this.onSync = onSync == null ? () -> {} : onSync;
        this.onBound = onBound == null ? () -> {} : onBound;
        if (server != null) {
            if (!serverHasMergedServices()) {
                Log.w(TAG, "watch sync advertiser stale gatt server missing services; rebuilding");
                restartGattServer("stale_start");
                return;
            }
            ensureAdvertising();
            return;
        }
        manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            Log.w(TAG, "watch sync advertiser skipped bluetooth unavailable");
            return;
        }
        advertiser = adapter.getBluetoothLeAdvertiser();
        if (advertiser == null) {
            Log.w(TAG, "watch sync advertiser skipped advertiser unavailable");
            return;
        }
        server = manager.openGattServer(context, callback);
        if (server == null) {
            Log.w(TAG, "watch sync advertiser skipped gatt server unavailable");
            return;
        }
        BluetoothGattCharacteristic command = new BluetoothGattCharacteristic(
                WANJI_WATCH_SYNC_COMMAND_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE
                        | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE);
        BluetoothGattService service = new BluetoothGattService(
                WANJI_WATCH_SYNC_SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY);
        service.addCharacteristic(command);
        BluetoothGattService pullService = new BluetoothGattService(
                PULL_SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY);
        queueCharacteristic = new BluetoothGattCharacteristic(
                PULL_QUEUE_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ);
        controlCharacteristic = new BluetoothGattCharacteristic(
                PULL_CONTROL_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE
                        | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE);
        dataCharacteristic = new BluetoothGattCharacteristic(
                PULL_DATA_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ
                        | BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ);
        dataCharacteristic.addDescriptor(new BluetoothGattDescriptor(
                CLIENT_CONFIG_UUID,
                BluetoothGattDescriptor.PERMISSION_READ
                        | BluetoothGattDescriptor.PERMISSION_WRITE));
        Log.i(TAG, "watch pull merged build=uuid4400-v89-no-idle-gatt-rebuild service=" + PULL_SERVICE_UUID
                + " controlProps=" + controlCharacteristic.getProperties()
                + " dataProps=" + dataCharacteristic.getProperties()
                + " descriptors=" + dataCharacteristic.getDescriptors().size());
        pullService.addCharacteristic(queueCharacteristic);
        pullService.addCharacteristic(controlCharacteristic);
        pullService.addCharacteristic(dataCharacteristic);
        ackCharacteristic = new BluetoothGattCharacteristic(
                PULL_ACK_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE);
        pullService.addCharacteristic(ackCharacteristic);
        advertiseSettings = new AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build();
        advertiseData = new AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addManufacturerData(WANJI_MANUFACTURER_ID, WANJI_AD_MARKER)
                .build();
        syncServiceAdded = false;
        pullServiceAdded = false;
        pendingPullService = pullService;
        if (!server.addService(service)) {
            Log.w(TAG, "watch sync advertiser add service rejected");
            stop();
            return;
        }
    }

    void stop() {
        main.removeCallbacks(restartAdvertising);
        main.removeCallbacks(refreshAdvertising);
        main.removeCallbacks(rebuildGattServer);
        advertising = false;
        advertiseStarting = false;
        if (advertiser != null) {
            try {
                advertiser.stopAdvertising(advertiseCallback);
            } catch (Exception ignored) {
            }
            advertiser = null;
        }
        advertiseSettings = null;
        advertiseData = null;
        pendingPullService = null;
        syncServiceAdded = false;
        pullServiceAdded = false;
        if (server != null) {
            try {
                server.close();
            } catch (Exception ignored) {
            }
            server = null;
        }
        dataCharacteristic = null;
        queueCharacteristic = null;
        controlCharacteristic = null;
        ackCharacteristic = null;
        notifyDevice = null;
        selectedAudio = null;
        selectedItem = null;
        selectedId = "";
        queuedShortId = "";
        queuedFullId = "";
        selectedOffset = 0;
        dataReadWindow = null;
        dataReadWindowStart = 0;
        loadingSelectedAudio = false;
        currentMtu = DEFAULT_ATT_MTU;
        notifyEnabled = false;
        streaming = false;
        connectedAtMs = 0;
        notifyCreditEnd = -1;
        resetNotifyRetry();
    }

    private int maxReadPayloadBytes() {
        return Math.max(20, Math.min(MAX_CHUNK_BYTES, currentMtu - 1));
    }

    private int maxNotifyPayloadBytes() {
        int effectiveMtu = currentMtu > DEFAULT_ATT_MTU ? currentMtu : IOS_EFFECTIVE_ATT_MTU;
        int attPayload = Math.min(MAX_CHUNK_BYTES, effectiveMtu - 3 - NOTIFY_HEADER_BYTES);
        return Math.max(1, Math.min(STABLE_NOTIFY_PAYLOAD_BYTES, attPayload));
    }

    private byte[] sliceForRead(byte[] value, int offset) {
        if (value == null) {
            return new byte[0];
        }
        int safeOffset = Math.max(0, offset);
        if (safeOffset >= value.length) {
            return new byte[0];
        }
        int length = Math.min(maxReadPayloadBytes(), value.length - safeOffset);
        byte[] slice = new byte[length];
        System.arraycopy(value, safeOffset, slice, 0, length);
        return slice;
    }

    private byte[] queuePayload() {
        try {
            List<AudioItem> items = store == null ? java.util.Collections.emptyList() : store.load();
            boolean repaired = false;
            for (AudioItem item : items) {
                if (!AudioItem.PENDING.equals(item.state) && !AudioItem.FAILED.equals(item.state)) {
                    continue;
                }
                if (isUnrecoverablePullError(item)) {
                    continue;
                }
                if (store == null || !store.hasStoredAudio(item)) {
                    item.state = AudioItem.FAILED;
                    item.lastError = PULL_ERROR_MISSING_AUDIO;
                    item.attempts++;
                    repaired = true;
                    Log.w(TAG, "watch pull merged queue skipped missing audio id=" + item.id);
                    continue;
                }
                queuedShortId = shortPullId(item);
                queuedFullId = item.id;
                if (repaired) {
                    persistQueueRepair(items);
                }
                Log.i(TAG, "watch pull merged queue item id=" + item.id
                        + " shortId=" + queuedShortId
                        + " bytes=" + item.sizeBytes
                        + " mtu=" + currentMtu
                        + " notifyPayload=" + maxNotifyPayloadBytes());
                prewarmSelectedAudioForNotify(item);
                return queuePayloadForItem(item);
            }
            if (repaired) {
                persistQueueRepair(items);
            }
        } catch (Exception e) {
            Log.w(TAG, "watch pull merged queue failed " + e.getClass().getSimpleName());
        }
        queuedShortId = "";
        queuedFullId = "";
        return "{}".getBytes(StandardCharsets.UTF_8);
    }

    private byte[] queuePayloadForItem(AudioItem item) throws Exception {
        JSONObject payload = new JSONObject();
        payload.put("i", queuedShortId);
        payload.put("f", item.id);
        payload.put("s", Math.min(Integer.MAX_VALUE, item.sizeBytes));
        payload.put("createdAt", item.createdAt);
        payload.put("durationMs", item.durationMs);
        if (item.sha256 != null && item.sha256.length() > 0) {
            payload.put("sha256", item.sha256);
        }
        payload.put("mtu", currentMtu);
        payload.put("notifyPayload", maxNotifyPayloadBytes());
        byte[] richPayload = payload.toString().getBytes(StandardCharsets.UTF_8);
        if (richPayload.length <= maxReadPayloadBytes()) {
            return richPayload;
        }

        String compact = "q:" + queuedShortId + ":" + item.sizeBytes;
        Log.i(TAG, "watch pull merged queue meta compact fallback id=" + item.id
                + " richBytes=" + richPayload.length
                + " readPayload=" + maxReadPayloadBytes()
                + " compactBytes=" + compact.getBytes(StandardCharsets.UTF_8).length);
        return compact.getBytes(StandardCharsets.UTF_8);
    }

    private String shortPullId(AudioItem item) {
        CRC32 crc = new CRC32();
        crc.update(item.id.getBytes(StandardCharsets.UTF_8));
        String suffix = Long.toString(crc.getValue(), 36);
        if (suffix.length() > 8) {
            suffix = suffix.substring(suffix.length() - 8);
        }
        return "q" + suffix;
    }

    private void persistQueueRepair(List<AudioItem> items) {
        if (store == null) {
            return;
        }
        try {
            store.saveOrThrow(items);
        } catch (Exception e) {
            Log.w(TAG, "watch pull merged queue repair save failed " + e.getClass().getSimpleName());
        }
    }

    private boolean isUnrecoverablePullError(AudioItem item) {
        return PULL_ERROR_MISSING_AUDIO.equals(item.lastError)
                || PULL_ERROR_UNREADABLE_AUDIO.equals(item.lastError);
    }

    private void markPullItemUnreadable(String id, Exception cause) {
        if (store == null || id == null || id.length() == 0) {
            return;
        }
        try {
            List<AudioItem> items = store.load();
            for (AudioItem item : items) {
                if (item.id.equals(id)) {
                    item.state = AudioItem.FAILED;
                    item.lastError = PULL_ERROR_UNREADABLE_AUDIO;
                    item.attempts++;
                    store.saveOrThrow(items);
                    Log.w(TAG, "watch pull merged marked unreadable id=" + id
                            + " error=" + cause.getClass().getSimpleName());
                    return;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "watch pull merged unreadable mark failed id=" + id
                    + " error=" + e.getClass().getSimpleName());
        }
    }

    private int handlePullControl(byte[] value) {
        try {
            PullControlRequest request = parsePullControl(value);
            String token = request.token;
            if (!BluetoothBindingStore.isBound(appContext)
                    || !BluetoothBindingStore.phoneToken(appContext).equals(token)) {
                Log.w(TAG, "watch pull merged control rejected token mismatch");
                return BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION;
            }
            String id = request.id;
            String fullId = resolvePullId(id);
            int offset = Math.max(0, request.offset);
            boolean readMode = request.readMode;
            AudioItem item = findItem(fullId);
            if (item == null || store == null) {
                Log.w(TAG, "watch pull merged control rejected missing id=" + id
                        + " fullId=" + fullId);
                return BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH;
            }
            if (!fullId.equals(selectedId)) {
                selectedAudio = null;
                loadingSelectedAudio = false;
                selectedItem = item;
                selectedId = fullId;
                Log.i(TAG, "watch pull merged selected id=" + selectedId
                        + " requestedId=" + id
                        + " bytes=" + item.sizeBytes);
            } else if (selectedItem == null) {
                selectedItem = item;
            }
            int expectedSize = selectedAudio == null
                    ? (int) Math.min(Integer.MAX_VALUE, item.sizeBytes)
                    : selectedAudio.length;
            selectedOffset = Math.min(offset, expectedSize);
            notifyCreditEnd = readMode
                    ? -1
                    : Math.min(expectedSize, selectedOffset
                    + Math.max(maxNotifyPayloadBytes(), request.creditBytes));
            dataReadWindow = null;
            dataReadWindowStart = selectedOffset;
            resetNotifyRetry();
            cancelNotifySentWatchdog();
            if (selectedOffset == 0
                    || selectedOffset == expectedSize
                    || Math.abs(selectedOffset - lastControlLogOffset) >= MAX_CHUNK_BYTES * 128) {
                lastControlLogOffset = selectedOffset;
                Log.i(TAG, "watch pull merged control id=" + id + " offset=" + selectedOffset
                        + " creditEnd=" + notifyCreditEnd
                        + " total=" + expectedSize);
            }
            streaming = !readMode && notifyEnabled && notifyDevice != null;
            Log.i(TAG, "watch pull merged control mode id=" + id
                    + " readMode=" + readMode
                    + " notifyEnabled=" + notifyEnabled
                    + " hasNotifyDevice=" + (notifyDevice != null)
                    + " streaming=" + streaming
                    + " creditEnd=" + notifyCreditEnd
                    + " selectedAudioLoaded=" + (selectedAudio != null));
            if (readMode) {
                Log.i(TAG, "watch pull merged control read mode id=" + id
                        + " fullId=" + selectedId
                        + " offset=" + selectedOffset);
            }
            return BluetoothGatt.GATT_SUCCESS;
        } catch (Exception e) {
            Log.w(TAG, "watch pull merged control failed " + e.getClass().getSimpleName());
            return BluetoothGatt.GATT_FAILURE;
        }
    }

    private PullControlRequest parsePullControl(byte[] value) throws Exception {
        byte[] bytes = value == null ? new byte[0] : value;
        if (bytes.length >= 7 && (bytes[0] == 'r' || bytes[0] == 'n')) {
            int offset = ((bytes[1] & 0xFF) << 24)
                    | ((bytes[2] & 0xFF) << 16)
                    | ((bytes[3] & 0xFF) << 8)
                    | (bytes[4] & 0xFF);
            int idLength = bytes[5] & 0xFF;
            int tokenLength = bytes[6] & 0xFF;
            int idStart = 7;
            int tokenStart = idStart + idLength;
            if (tokenStart + tokenLength > bytes.length) {
                throw new IllegalArgumentException("control packet truncated");
            }
            PullControlRequest request = new PullControlRequest();
            request.id = new String(bytes, idStart, idLength, StandardCharsets.UTF_8);
            request.token = new String(bytes, tokenStart, tokenLength, StandardCharsets.UTF_8);
            request.offset = offset;
            request.readMode = bytes[0] == 'r';
            int creditStart = tokenStart + tokenLength;
            if (!request.readMode && creditStart + 4 <= bytes.length) {
                request.creditBytes = ((bytes[creditStart] & 0xFF) << 24)
                        | ((bytes[creditStart + 1] & 0xFF) << 16)
                        | ((bytes[creditStart + 2] & 0xFF) << 8)
                        | (bytes[creditStart + 3] & 0xFF);
            } else if (!request.readMode) {
                request.creditBytes = DEFAULT_NOTIFY_CREDIT_BYTES;
            }
            return request;
        }
        JSONObject json = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
        PullControlRequest request = new PullControlRequest();
        request.token = json.optString("t", "");
        request.id = json.optString("id", json.optString("i", ""));
        request.offset = json.optInt("o", 0);
        String mode = json.optString("m", "");
        request.readMode = "read".equals(mode) || "r".equals(mode);
        request.creditBytes = request.readMode
                ? 0
                : json.optInt("creditBytes", DEFAULT_NOTIFY_CREDIT_BYTES);
        return request;
    }

    private static final class PullControlRequest {
        String token = "";
        String id = "";
        int offset;
        int creditBytes;
        boolean readMode = true;
    }

    private int handlePullAck(byte[] value) {
        try {
            PullAckRequest request = parsePullAck(value);
            String token = request.token;
            String id = request.id;
            String fullId = resolvePullId(id);
            if (!BluetoothBindingStore.isBound(appContext)
                    || !BluetoothBindingStore.phoneToken(appContext).equals(token)) {
                Log.w(TAG, "watch pull merged ack rejected token mismatch");
                return BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION;
            }
            List<AudioItem> items = store == null ? java.util.Collections.emptyList() : store.load();
            for (AudioItem item : items) {
                if (item.id.equals(fullId)) {
                    item.state = AudioItem.SYNCED;
                    item.syncedAt = System.currentTimeMillis();
                    item.lastError = "";
                    item.syncKind = "ble-pull";
                    store.saveOrThrow(items);
                    selectedAudio = null;
                    selectedItem = null;
                    selectedId = "";
                    selectedOffset = 0;
                    dataReadWindow = null;
                    dataReadWindowStart = 0;
                    resetNotifyRetry();
                    lastControlLogOffset = -1;
                    lastReadLogOffset = -1;
                    streaming = false;
                    Log.i(TAG, "watch pull merged ack ok id=" + id + " fullId=" + fullId);
                    return BluetoothGatt.GATT_SUCCESS;
                }
            }
            Log.w(TAG, "watch pull merged ack missing id=" + id + " fullId=" + fullId);
            return BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH;
        } catch (Exception e) {
            Log.w(TAG, "watch pull merged ack failed " + e.getClass().getSimpleName());
            return BluetoothGatt.GATT_FAILURE;
        }
    }

    private PullAckRequest parsePullAck(byte[] value) throws Exception {
        byte[] bytes = value == null ? new byte[0] : value;
        if (bytes.length >= 3 && bytes[0] == 'a') {
            int idLength = bytes[1] & 0xFF;
            int tokenLength = bytes[2] & 0xFF;
            int idStart = 3;
            int tokenStart = idStart + idLength;
            if (tokenStart + tokenLength > bytes.length) {
                throw new IllegalArgumentException("ack packet truncated");
            }
            PullAckRequest request = new PullAckRequest();
            request.id = new String(bytes, idStart, idLength, StandardCharsets.UTF_8);
            request.token = new String(bytes, tokenStart, tokenLength, StandardCharsets.UTF_8);
            return request;
        }
        JSONObject json = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
        PullAckRequest request = new PullAckRequest();
        request.token = json.optString("t", "");
        request.id = json.optString("id", "");
        return request;
    }

    private static final class PullAckRequest {
        String token = "";
        String id = "";
    }

    private String resolvePullId(String id) {
        if (id != null && id.length() > 0 && id.equals(queuedShortId)
                && queuedFullId != null && queuedFullId.length() > 0) {
            return queuedFullId;
        }
        if (id == null || id.length() == 0) {
            return "";
        }
        if (!id.startsWith("q") || store == null) {
            return id;
        }
        String match = "";
        try {
            for (AudioItem item : store.load()) {
                if (AudioItem.SYNCED.equals(item.state)) {
                    continue;
                }
                if (shortPullId(item).equals(id)) {
                    if (match.length() > 0 && !match.equals(item.id)) {
                        Log.w(TAG, "watch pull merged short id collision shortId=" + id
                                + " first=" + match
                                + " second=" + item.id);
                        return "";
                    }
                    match = item.id;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "watch pull merged short id resolve failed shortId=" + id
                    + " error=" + e.getClass().getSimpleName());
            return "";
        }
        if (match.length() > 0) {
            Log.i(TAG, "watch pull merged short id resolved shortId=" + id
                    + " fullId=" + match);
            return match;
        }
        return id;
    }

    private AudioItem findItem(String id) {
        try {
            if (store == null) {
                return null;
            }
            for (AudioItem item : store.load()) {
                if (item.id.equals(id)) {
                    return item;
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    private byte[] dataPayload(int attOffset) {
        if (selectedAudio == null) {
            if (selectedItem == null || store == null) {
                return new byte[0];
            }
            try {
                selectedAudio = store.readAudio(selectedItem);
                loadingSelectedAudio = false;
                Log.i(TAG, "watch pull merged loaded audio id=" + selectedId
                        + " bytes=" + selectedAudio.length);
            } catch (Exception e) {
                markPullItemUnreadable(selectedId, e);
                selectedAudio = null;
                selectedItem = null;
                selectedId = "";
                selectedOffset = 0;
                dataReadWindow = null;
                dataReadWindowStart = 0;
                loadingSelectedAudio = false;
                streaming = false;
                resetNotifyRetry();
                Log.w(TAG, "watch pull merged data load failed " + e.getClass().getSimpleName());
                return new byte[0];
            }
        }
        if (attOffset == 0 || dataReadWindow == null) {
            int start = Math.min(selectedOffset, selectedAudio.length);
            int end = Math.min(start + DATA_READ_WINDOW_BYTES, selectedAudio.length);
            dataReadWindow = new byte[end - start];
            System.arraycopy(selectedAudio, start, dataReadWindow, 0, dataReadWindow.length);
            dataReadWindowStart = start;
            selectedOffset = end;
            if (start == 0 || end == selectedAudio.length || start % (DATA_READ_WINDOW_BYTES * 8) == 0) {
                lastReadLogOffset = start;
                Log.i(TAG, "watch pull merged data window id=" + selectedId + " offset=" + start
                        + " bytes=" + dataReadWindow.length + " total=" + selectedAudio.length);
            } else if (start < lastReadLogOffset) {
                lastReadLogOffset = start;
                Log.i(TAG, "watch pull merged data rewind id=" + selectedId + " offset=" + start
                        + " bytes=" + dataReadWindow.length + " total=" + selectedAudio.length);
            }
        }
        byte[] response = sliceForRead(dataReadWindow, attOffset);
        if (attOffset > 0 && response.length == 0) {
            Log.i(TAG, "watch pull merged data window complete id=" + selectedId
                    + " offset=" + dataReadWindowStart
                    + " bytes=" + (dataReadWindow == null ? 0 : dataReadWindow.length));
        }
        return response;
    }

    private void notifyNextChunk() {
        if (!streaming || server == null || notifyDevice == null
                || dataCharacteristic == null) {
            return;
        }
        if (selectedAudio == null) {
            loadSelectedAudioForNotify();
            return;
        }
        if (selectedOffset >= selectedAudio.length) {
            streaming = false;
            resetNotifyRetry();
            Log.i(TAG, "watch pull merged notify complete id=" + selectedId
                    + " total=" + selectedAudio.length);
            return;
        }
        if (notifyCreditEnd >= 0 && selectedOffset >= notifyCreditEnd) {
            streaming = false;
            cancelNotifySentWatchdog();
            Log.i(TAG, "watch pull merged notify credit exhausted id=" + selectedId
                    + " offset=" + selectedOffset
                    + " creditEnd=" + notifyCreditEnd
                    + " total=" + selectedAudio.length);
            return;
        }
        int start = selectedOffset;
        int end = Math.min(start + maxNotifyPayloadBytes(), selectedAudio.length);
        if (notifyCreditEnd >= 0) {
            end = Math.min(end, notifyCreditEnd);
        }
        byte[] chunk = new byte[end - start];
        System.arraycopy(selectedAudio, start, chunk, 0, chunk.length);
        byte[] frame = notifyFrame(start, chunk);
        dataCharacteristic.setValue(frame);
        boolean queued = server.notifyCharacteristicChanged(notifyDevice, dataCharacteristic, false);
        if (queued) {
            selectedOffset = end;
            lastNotifyStart = start;
            lastNotifyEnd = end;
            scheduleNotifySentWatchdog(start, end);
        }
        if (start == 0 || end == selectedAudio.length || start % (MAX_CHUNK_BYTES * 256) == 0) {
            Log.i(TAG, "watch pull merged notify id=" + selectedId + " offset=" + start
                    + " bytes=" + chunk.length + " frameBytes=" + frame.length
                    + " total=" + selectedAudio.length
                    + " mtu=" + currentMtu
                    + " creditEnd=" + notifyCreditEnd
                    + " queued=" + queued);
        }
        if (!queued) {
            Log.w(TAG, "watch pull merged notify rejected id=" + selectedId + " offset=" + start);
            retryNotifyChunk(start, "queue_rejected");
        }
    }

    private void loadSelectedAudioForNotify() {
        if (loadingSelectedAudio) {
            return;
        }
        if (selectedItem == null || store == null) {
            streaming = false;
            return;
        }
        loadingSelectedAudio = true;
        final AudioItem item = selectedItem;
        final String id = selectedId;
        Log.i(TAG, "watch pull merged notify load start id=" + id);
        new Thread(() -> {
            try {
                byte[] audio = store.readAudio(item);
                main.post(() -> {
                    loadingSelectedAudio = false;
                    if (!id.equals(selectedId) || selectedItem != item || !streaming) {
                        Log.i(TAG, "watch pull merged notify load discarded id=" + id);
                        return;
                    }
                    selectedAudio = audio;
                    Log.i(TAG, "watch pull merged notify load ok id=" + id
                            + " bytes=" + audio.length);
                    notifyNextChunk();
                });
            } catch (Exception e) {
                markPullItemUnreadable(id, e);
                main.post(() -> {
                    loadingSelectedAudio = false;
                    if (!id.equals(selectedId)) {
                        return;
                    }
                    selectedAudio = null;
                    selectedItem = null;
                    selectedId = "";
                    selectedOffset = 0;
                    dataReadWindow = null;
                    dataReadWindowStart = 0;
                    streaming = false;
                    resetNotifyRetry();
                    Log.w(TAG, "watch pull merged notify load failed " + e.getClass().getSimpleName());
                });
            }
        }, "wristnote-ble-notify-load").start();
    }

    private void prewarmSelectedAudioForNotify(AudioItem item) {
        if (item == null || store == null || loadingSelectedAudio) {
            return;
        }
        if (selectedAudio != null && item.id.equals(selectedId)) {
            return;
        }
        selectedItem = item;
        selectedId = item.id;
        selectedAudio = null;
        Log.i(TAG, "watch pull merged notify prewarm id=" + item.id
                + " bytes=" + item.sizeBytes);
        loadSelectedAudioForNotify();
    }

    private byte[] notifyFrame(int offset, byte[] payload) {
        byte[] frame = new byte[NOTIFY_HEADER_BYTES + payload.length];
        writeInt32(frame, 0, offset);
        writeInt32(frame, 4, payload.length);
        System.arraycopy(payload, 0, frame, NOTIFY_HEADER_BYTES, payload.length);
        return frame;
    }

    private void writeInt32(byte[] target, int offset, int value) {
        target[offset] = (byte) ((value >> 24) & 0xFF);
        target[offset + 1] = (byte) ((value >> 16) & 0xFF);
        target[offset + 2] = (byte) ((value >> 8) & 0xFF);
        target[offset + 3] = (byte) (value & 0xFF);
    }

    private void scheduleNotifyNextChunk(long delayMs) {
        main.postDelayed(this::notifyNextChunk, delayMs);
    }

    private void scheduleNotifySentWatchdog(int start, int end) {
        cancelNotifySentWatchdog();
        notifySentWatchdog = () -> {
            notifySentWatchdog = null;
            if (!streaming || selectedAudio == null || lastNotifyStart != start
                    || lastNotifyEnd != end || selectedOffset != end) {
                return;
            }
            Log.w(TAG, "watch pull merged notify sent timeout id=" + selectedId
                    + " start=" + start
                    + " end=" + end
                    + " selectedOffset=" + selectedOffset);
            streaming = false;
        };
        main.postDelayed(notifySentWatchdog, NOTIFY_SENT_WATCHDOG_MS);
    }

    private void cancelNotifySentWatchdog() {
        if (notifySentWatchdog != null) {
            main.removeCallbacks(notifySentWatchdog);
            notifySentWatchdog = null;
        }
    }

    private void retryNotifyChunk(int offset, String reason) {
        if (selectedAudio == null || offset < 0 || offset >= selectedAudio.length) {
            streaming = false;
            return;
        }
        if (notifyRetryCount >= MAX_NOTIFY_RETRIES) {
            streaming = false;
            Log.w(TAG, "watch pull merged notify retry exhausted id=" + selectedId
                    + " offset=" + offset + " reason=" + reason);
            return;
        }
        notifyRetryCount++;
        selectedOffset = offset;
        streaming = true;
        long delayMs = NOTIFY_RETRY_DELAY_MS * notifyRetryCount;
        Log.i(TAG, "watch pull merged notify retry id=" + selectedId
                + " offset=" + offset
                + " attempt=" + notifyRetryCount
                + " delayMs=" + delayMs
                + " reason=" + reason);
        scheduleNotifyNextChunk(delayMs);
    }

    private void resetNotifyRetry() {
        cancelNotifySentWatchdog();
        notifyRetryCount = 0;
        lastNotifyStart = -1;
        lastNotifyEnd = -1;
    }

    private final AdvertiseCallback advertiseCallback = new AdvertiseCallback() {
        @Override
        public void onStartSuccess(AdvertiseSettings settingsInEffect) {
            advertising = true;
            advertiseStarting = false;
            Log.i(TAG, "watch sync advertiser started");
            scheduleAdvertisingRefresh();
        }

        @Override
        public void onStartFailure(int errorCode) {
            advertising = false;
            advertiseStarting = false;
            Log.w(TAG, "watch sync advertiser failed code=" + errorCode);
            scheduleAdvertisingRestart(1500);
        }
    };

    private void ensureAdvertising() {
        if (!syncServiceAdded || !pullServiceAdded) {
            Log.i(TAG, "watch sync advertiser waiting services sync=" + syncServiceAdded
                    + " pull=" + pullServiceAdded);
            return;
        }
        if (!serverHasMergedServices()) {
            Log.w(TAG, "watch sync advertiser missing gatt services before advertising");
            restartGattServer("missing_services_before_advertising");
            return;
        }
        if (advertising || advertiseStarting || advertiser == null
                || advertiseSettings == null || advertiseData == null) {
            Log.i(TAG, "watch sync advertiser ensure skipped advertising=" + advertising
                    + " starting=" + advertiseStarting
                    + " advertiser=" + (advertiser != null));
            if (advertising) {
                scheduleAdvertisingRefresh();
            }
            return;
        }
        try {
            Log.i(TAG, "watch sync advertiser ensure start");
            advertiseStarting = true;
            advertiser.startAdvertising(advertiseSettings, advertiseData, advertiseCallback);
        } catch (Exception e) {
            advertising = false;
            advertiseStarting = false;
            Log.w(TAG, "watch sync advertiser ensure exception " + e.getClass().getSimpleName());
            scheduleAdvertisingRestart(1500);
        }
    }

    private void scheduleAdvertisingRestart(long delayMs) {
        if (advertiser == null || advertiseSettings == null || advertiseData == null) {
            return;
        }
        main.removeCallbacks(restartAdvertising);
        main.postDelayed(restartAdvertising, delayMs);
    }

    private void scheduleAdvertisingRefresh() {
        if (advertiser == null || advertiseSettings == null || advertiseData == null) {
            return;
        }
        main.removeCallbacks(refreshAdvertising);
        main.postDelayed(refreshAdvertising, ADVERTISING_REFRESH_MS);
    }

    private void restartAdvertising() {
        if (advertiser == null || advertiseSettings == null || advertiseData == null) {
            return;
        }
        try {
            advertiser.stopAdvertising(advertiseCallback);
        } catch (Exception ignored) {
        }
        advertising = false;
        advertiseStarting = false;
        ensureAdvertising();
    }

    private void refreshAdvertising() {
        if (advertiser == null || advertiseSettings == null || advertiseData == null) {
            return;
        }
        if (!serverHasMergedServices()) {
            Log.w(TAG, "watch sync advertiser refresh found missing gatt services");
            restartGattServer("missing_services_refresh");
            return;
        }
        if (notifyDevice != null || streaming) {
            Log.i(TAG, "watch sync advertiser refresh deferred connected=" + (notifyDevice != null)
                    + " streaming=" + streaming);
            scheduleAdvertisingRefresh();
            return;
        }
        if (!advertising && !advertiseStarting) {
            Log.i(TAG, "watch sync advertiser refresh ensure missing advertisement");
            ensureAdvertising();
            return;
        }
        Log.i(TAG, "watch sync advertiser refresh restart advertising only");
        scheduleAdvertisingRestart(0);
        scheduleAdvertisingRefresh();
    }

    private boolean serverHasMergedServices() {
        if (server == null) {
            return false;
        }
        try {
            BluetoothGattService syncService = server.getService(WANJI_WATCH_SYNC_SERVICE_UUID);
            BluetoothGattService pullService = server.getService(PULL_SERVICE_UUID);
            return syncService != null
                    && syncService.getCharacteristic(WANJI_WATCH_SYNC_COMMAND_UUID) != null
                    && pullService != null
                    && pullService.getCharacteristic(PULL_QUEUE_UUID) != null
                    && pullService.getCharacteristic(PULL_CONTROL_UUID) != null
                    && pullService.getCharacteristic(PULL_DATA_UUID) != null
                    && pullService.getCharacteristic(PULL_ACK_UUID) != null;
        } catch (Exception e) {
            Log.w(TAG, "watch sync advertiser service health check failed "
                    + e.getClass().getSimpleName());
            return false;
        }
    }

    private void restartGattServer(String reason) {
        Context context = appContext;
        AudioStore audioStore = store;
        Runnable syncCallback = onSync;
        Runnable boundCallback = onBound;
        Log.w(TAG, "watch sync advertiser rebuilding gatt server reason=" + reason);
        stop();
        if (context == null || audioStore == null) {
            Log.w(TAG, "watch sync advertiser rebuild skipped missing context/store");
            return;
        }
        start(context, audioStore, syncCallback, boundCallback);
    }

    private void scheduleGattServerRebuild(String reason, long delayMs) {
        if (appContext == null || store == null) {
            return;
        }
        pendingGattRebuildReason = reason == null ? "scheduled" : reason;
        main.removeCallbacks(rebuildGattServer);
        main.postDelayed(rebuildGattServer, Math.max(0L, delayMs));
    }

    private final BluetoothGattServerCallback callback = new BluetoothGattServerCallback() {
        @Override
        public void onServiceAdded(int status, BluetoothGattService service) {
            Log.i(TAG, "watch merged service added uuid=" + service.getUuid() + " status=" + status);
            if (status != BluetoothGatt.GATT_SUCCESS) {
                return;
            }
        if (WANJI_WATCH_SYNC_SERVICE_UUID.equals(service.getUuid())) {
            syncServiceAdded = true;
            addPendingPullServiceIfNeeded();
        } else if (PULL_SERVICE_UUID.equals(service.getUuid())) {
            pullServiceAdded = true;
        }
        ensureAdvertising();
    }

    private void addPendingPullServiceIfNeeded() {
        if (server == null || pendingPullService == null || pullServiceAdded) {
            return;
        }
        BluetoothGattService service = pendingPullService;
        pendingPullService = null;
        Log.i(TAG, "watch pull merged add pull service after sync service");
        if (!server.addService(service)) {
            Log.w(TAG, "watch pull merged service add rejected");
            stop();
        }
    }

        @Override
        public void onConnectionStateChange(android.bluetooth.BluetoothDevice device,
                                            int status,
                                            int newState) {
            Log.i(TAG, "watch sync connection state=" + newState + " status=" + status);
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                advertising = false;
                main.removeCallbacks(rebuildGattServer);
                notifyDevice = device;
                connectedAtMs = System.currentTimeMillis();
                currentMtu = DEFAULT_ATT_MTU;
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (notifyDevice != null && notifyDevice.equals(device)) {
                    notifyDevice = null;
                    connectedAtMs = 0;
                    notifyEnabled = false;
                    streaming = false;
                }
                selectedAudio = null;
                selectedItem = null;
                selectedId = "";
                selectedOffset = 0;
                dataReadWindow = null;
                dataReadWindowStart = 0;
                notifyCreditEnd = -1;
                resetNotifyRetry();
                lastControlLogOffset = -1;
                lastReadLogOffset = -1;
                scheduleGattServerRebuild("post_disconnect", GATT_REBUILD_AFTER_DISCONNECT_MS);
            }
        }

        @Override
        public void onMtuChanged(android.bluetooth.BluetoothDevice device, int mtu) {
            currentMtu = Math.max(DEFAULT_ATT_MTU, mtu);
            Log.i(TAG, "watch merged mtu changed mtu=" + currentMtu
                    + " maxReadPayload=" + maxReadPayloadBytes()
                    + " maxNotifyPayload=" + maxNotifyPayloadBytes());
        }

        @Override
        public void onCharacteristicReadRequest(android.bluetooth.BluetoothDevice device,
                                                int requestId,
                                                int offset,
                                                BluetoothGattCharacteristic characteristic) {
            byte[] responseValue;
            int response = BluetoothGatt.GATT_SUCCESS;
            UUID uuid = characteristic == null ? null : characteristic.getUuid();
            Log.i(TAG, "watch pull merged read request uuid=" + uuid
                    + " requestId=" + requestId
                    + " offset=" + offset);
            if (PULL_QUEUE_UUID.equals(uuid)) {
                byte[] payload = queuePayload();
                responseValue = sliceForRead(payload, offset);
                characteristic.setValue(payload);
                Log.i(TAG, "watch pull merged queue read offset=" + offset
                        + " bytes=" + responseValue.length
                        + " total=" + payload.length);
            } else if (PULL_DATA_UUID.equals(uuid)) {
                responseValue = dataPayload(offset);
                characteristic.setValue(dataReadWindow == null ? responseValue : dataReadWindow);
            } else {
                response = BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED;
                responseValue = new byte[0];
            }
            if (server != null) {
                server.sendResponse(device, requestId, response, offset, responseValue);
                Log.i(TAG, "watch pull merged read response uuid=" + uuid
                        + " requestId=" + requestId
                        + " status=" + response
                        + " offset=" + offset
                        + " bytes=" + responseValue.length);
            }
        }

        @Override
        public void onCharacteristicWriteRequest(android.bluetooth.BluetoothDevice device,
                                                 int requestId,
                                                 BluetoothGattCharacteristic characteristic,
                                                 boolean preparedWrite,
                                                 boolean responseNeeded,
                                                 int offset,
                                                 byte[] value) {
            int response = BluetoothGatt.GATT_SUCCESS;
            int length = value == null ? 0 : value.length;
            boolean pullControl = PULL_CONTROL_UUID.equals(characteristic.getUuid());
            Log.i(TAG, "watch merged write request uuid=" + characteristic.getUuid()
                    + " responseNeeded=" + responseNeeded
                    + " offset=" + offset
                    + " bytes=" + length);
            if (PULL_CONTROL_UUID.equals(characteristic.getUuid())) {
                response = handlePullControl(value);
            } else if (PULL_ACK_UUID.equals(characteristic.getUuid())) {
                response = handlePullAck(value);
            } else if (!WANJI_WATCH_SYNC_COMMAND_UUID.equals(characteristic.getUuid())) {
                response = BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED;
                Log.w(TAG, "watch merged write rejected characteristic mismatch");
            } else {
                String text = new String(value == null ? new byte[0] : value, StandardCharsets.UTF_8);
                if (text.startsWith("bind:")) {
                    String token = text.substring("bind:".length());
                    if (appContext != null && BluetoothBindingStore.savePhoneToken(appContext, token)) {
                        BluetoothBindingStore.savePhoneDevice(appContext, device);
                        Log.i(TAG, "watch bind command accepted");
                        main.post(onBound);
                    } else {
                        response = BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION;
                        Log.w(TAG, "watch bind command rejected");
                    }
                } else if (!BluetoothBindingStore.isBound(appContext)
                        || !("sync:" + BluetoothBindingStore.phoneToken(appContext)).equals(text)) {
                    response = BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION;
                    Log.w(TAG, "watch sync command rejected token mismatch");
                } else {
                    BluetoothBindingStore.savePhoneDevice(appContext, device);
                    Log.i(TAG, "watch sync command accepted");
                    main.post(onSync);
                }
            }
            if (responseNeeded && server != null) {
                server.sendResponse(device, requestId, response, offset, new byte[0]);
                Log.i(TAG, "watch merged write response uuid=" + characteristic.getUuid()
                        + " requestId=" + requestId
                        + " status=" + response);
            }
            if (pullControl && response == BluetoothGatt.GATT_SUCCESS
                    && notifyEnabled && notifyDevice != null && streaming) {
                Log.i(TAG, "watch pull merged notify first chunk scheduled id=" + selectedId
                        + " offset=" + selectedOffset
                        + " audioLoaded=" + (selectedAudio != null));
                scheduleNotifyNextChunk(0);
            }
        }

        @Override
        public void onDescriptorReadRequest(android.bluetooth.BluetoothDevice device,
                                            int requestId,
                                            int offset,
                                            BluetoothGattDescriptor descriptor) {
            if (!CLIENT_CONFIG_UUID.equals(descriptor.getUuid())) {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED,
                        offset, new byte[0]);
                return;
            }
            byte[] value = notifyEnabled
                    ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    : BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE;
            server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value);
        }

        @Override
        public void onDescriptorWriteRequest(android.bluetooth.BluetoothDevice device,
                                             int requestId,
                                             BluetoothGattDescriptor descriptor,
                                             boolean preparedWrite,
                                             boolean responseNeeded,
                                             int offset,
                                             byte[] value) {
            int response = BluetoothGatt.GATT_SUCCESS;
            if (!CLIENT_CONFIG_UUID.equals(descriptor.getUuid())) {
                response = BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED;
            } else {
                notifyEnabled = value != null
                        && value.length >= 2
                        && value[0] == BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE[0]
                        && value[1] == BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE[1];
                notifyDevice = notifyEnabled ? device : null;
                if (!notifyEnabled) {
                    streaming = false;
                    resetNotifyRetry();
                }
                Log.i(TAG, "watch pull merged notify enabled=" + notifyEnabled);
                if (notifyEnabled && selectedAudio != null && selectedOffset < selectedAudio.length) {
                    streaming = true;
                    scheduleNotifyNextChunk(0);
                } else if (notifyEnabled && streaming && selectedItem != null) {
                    Log.i(TAG, "watch pull merged notify descriptor ready; loading pending audio id="
                            + selectedId);
                    scheduleNotifyNextChunk(0);
                }
            }
            if (responseNeeded) {
                server.sendResponse(device, requestId, response, offset, new byte[0]);
            }
        }

        @Override
        public void onNotificationSent(android.bluetooth.BluetoothDevice device, int status) {
            int sentStart = lastNotifyStart;
            int sentEnd = lastNotifyEnd;
            cancelNotifySentWatchdog();
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "watch pull merged notify sent failed status=" + status);
                if (lastNotifyStart >= 0 && selectedOffset == lastNotifyEnd) {
                    retryNotifyChunk(lastNotifyStart, "sent_status_" + status);
                } else {
                    streaming = false;
                }
                return;
            }
            if (selectedAudio != null
                    && (sentStart == 0 || sentEnd >= selectedAudio.length
                    || sentStart % (MAX_CHUNK_BYTES * 128) == 0)) {
                Log.i(TAG, "watch pull merged notify sent ok id=" + selectedId
                        + " start=" + sentStart
                        + " end=" + sentEnd
                        + " total=" + selectedAudio.length);
            }
            resetNotifyRetry();
            scheduleNotifyNextChunk(0);
        }
    };
}
