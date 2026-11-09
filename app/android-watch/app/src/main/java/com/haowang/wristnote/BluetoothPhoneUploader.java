package com.haowang.wristnote;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.os.ParcelUuid;
import android.util.Log;

import org.json.JSONObject;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

final class BluetoothPhoneUploader {
    private static final String TAG = "WristNote";
    private static final String WANJI_BLE_ENDPOINT = "ble://wanji";
    private static final UUID WANJI_SERVICE_UUID =
            UUID.fromString("7E1A1000-AD67-4F51-98E4-65C8E60B9C01");
    private static final UUID WANJI_WRITE_UUID =
            UUID.fromString("7E1A1001-AD67-4F51-98E4-65C8E60B9C01");
    private static final int BLE_MAX_FRAME_BYTES = 160;
    private static final int BLE_MAX_PAYLOAD_BYTES = BLE_MAX_FRAME_BYTES - 1;
    private static final long SCAN_TIMEOUT_MS = 12_000L;
    private static final long BROAD_SCAN_TIMEOUT_MS = 10_000L;
    private static final long CONNECT_TIMEOUT_MS = 10_000L;
    private static final long WRITE_TIMEOUT_MS = 8_000L;

    static boolean isBluetoothPhoneEndpoint(String phoneBase) {
        return phoneBase != null && WANJI_BLE_ENDPOINT.equals(phoneBase.trim().toLowerCase());
    }

    static void upload(Context context, byte[] audio, long createdAt, String uploadId) throws Exception {
        if (context == null) {
            throw new IllegalStateException("bluetooth context missing");
        }
        if (audio == null || audio.length == 0) {
            throw new IllegalStateException("empty audio");
        }
        String phoneToken = BluetoothBindingStore.phoneToken(context);
        if (!BluetoothBindingStore.isValidToken(phoneToken)) {
            throw new IllegalStateException("phone not bound");
        }

        BluetoothAdapter adapter = bluetoothAdapter(context);
        BluetoothDevice device = findWanjiReceiver(context, adapter);
        GattSession session = new GattSession(context, device);
        try {
            BluetoothGattCharacteristic write = session.connectAndFindWriteCharacteristic();
            JSONObject header = new JSONObject();
            header.put("t", phoneToken);
            header.put("f", "wristnote-" + System.currentTimeMillis() + ".m4a");
            header.put("c", createdAt > 0 ? createdAt : System.currentTimeMillis());
            header.put("u", uploadId == null ? "" : uploadId);
            header.put("s", audio.length);
            writeFrame(session, write, 1, header.toString().getBytes(StandardCharsets.UTF_8));
            int offset = 0;
            while (offset < audio.length) {
                int end = Math.min(offset + BLE_MAX_PAYLOAD_BYTES, audio.length);
                byte[] chunk = new byte[end - offset];
                System.arraycopy(audio, offset, chunk, 0, chunk.length);
                writeFrame(session, write, 2, chunk);
                offset = end;
            }
            writeFrame(session, write, 3, new byte[0]);
            Log.i(TAG, "bluetooth phone upload ok bytes=" + audio.length + " uploadId=" + uploadId);
        } finally {
            session.close();
        }
    }

    private static BluetoothAdapter bluetoothAdapter(Context context) {
        BluetoothManager manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            throw new IllegalStateException("bluetooth unavailable");
        }
        return adapter;
    }

    private static BluetoothDevice findWanjiReceiver(Context context, BluetoothAdapter adapter) throws Exception {
        BluetoothLeScanner scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            throw new IllegalStateException("bluetooth scanner unavailable");
        }
        BluetoothDevice device = scanForWanjiReceiver(context, scanner, true, SCAN_TIMEOUT_MS);
        if (device != null) {
            return device;
        }
        Log.w(TAG, "bluetooth phone strict scan missed receiver; trying broad scan");
        device = scanForWanjiReceiver(context, scanner, false, BROAD_SCAN_TIMEOUT_MS);
        if (device == null) {
            throw new IllegalStateException("phone receiver not found");
        }
        return device;
    }

    private static BluetoothDevice scanForWanjiReceiver(Context context,
                                                        BluetoothLeScanner scanner,
                                                        boolean strictFilter,
                                                        long timeoutMs) throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        BluetoothDevice[] found = new BluetoothDevice[1];
        int[] seen = new int[1];
        ScanCallback callback = new ScanCallback() {
            @Override
            public void onScanResult(int callbackType, ScanResult result) {
                BluetoothDevice device = result == null ? null : result.getDevice();
                if (device == null) {
                    return;
                }
                if (!strictFilter && seen[0] < 12) {
                    seen[0]++;
                    Log.i(TAG, "bluetooth phone broad candidate " + describeResult(context, result));
                }
                if (strictFilter || matchesWanjiReceiver(context, result)) {
                    Log.i(TAG, "bluetooth phone receiver found strict=" + strictFilter
                            + " " + describeResult(context, result));
                    found[0] = device;
                    latch.countDown();
                }
            }

            @Override
            public void onScanFailed(int errorCode) {
                Log.w(TAG, "bluetooth phone scan failed code=" + errorCode);
                latch.countDown();
            }
        };
        ScanFilter filter = new ScanFilter.Builder()
                .setServiceUuid(new ParcelUuid(WANJI_SERVICE_UUID))
                .build();
        ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build();
        Log.i(TAG, "bluetooth phone scan start strict=" + strictFilter
                + " timeoutMs=" + timeoutMs
                + " boundName=" + BluetoothBindingStore.phoneName(context)
                + " boundAddress=" + shortAddress(BluetoothBindingStore.phoneAddress(context)));
        if (strictFilter) {
            scanner.startScan(Collections.singletonList(filter), settings, callback);
        } else {
            scanner.startScan(null, settings, callback);
        }
        try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS);
            if (found[0] == null) {
                Log.w(TAG, "bluetooth phone scan timeout strict=" + strictFilter + " seen=" + seen[0]);
            }
            return found[0];
        } finally {
            scanner.stopScan(callback);
        }
    }

    private static boolean matchesWanjiReceiver(Context context, ScanResult result) {
        ScanRecord record = result == null ? null : result.getScanRecord();
        if (record != null) {
            if (record.getServiceUuids() != null
                    && record.getServiceUuids().contains(new ParcelUuid(WANJI_SERVICE_UUID))) {
                return true;
            }
            String recordName = record.getDeviceName();
            if (recordName != null && recordName.toLowerCase().contains("wanji")) {
                return true;
            }
        }
        BluetoothDevice device = result == null ? null : result.getDevice();
        if (safeName(device).toLowerCase().contains("wanji")) {
            return true;
        }
        return BluetoothBindingStore.matchesPhoneDevice(context, device);
    }

    private static String describeResult(Context context, ScanResult result) {
        BluetoothDevice device = result == null ? null : result.getDevice();
        ScanRecord record = result == null ? null : result.getScanRecord();
        String services = "";
        if (record != null && record.getServiceUuids() != null) {
            services = " services=" + record.getServiceUuids();
        }
        String recordName = record == null || record.getDeviceName() == null
                ? ""
                : " recordName=" + record.getDeviceName();
        return "name=" + safeName(device)
                + " address=" + shortAddress(safeAddress(device))
                + recordName
                + services
                + " boundMatch=" + BluetoothBindingStore.matchesPhoneDevice(context, device)
                + " rssi=" + (result == null ? 0 : result.getRssi());
    }

    private static String safeName(BluetoothDevice device) {
        if (device == null) {
            return "";
        }
        try {
            String name = device.getName();
            return name == null ? "" : name;
        } catch (SecurityException ignored) {
            return "";
        }
    }

    private static String safeAddress(BluetoothDevice device) {
        if (device == null) {
            return "";
        }
        try {
            String address = device.getAddress();
            return address == null ? "" : address;
        } catch (SecurityException ignored) {
            return "";
        }
    }

    private static String shortAddress(String address) {
        if (address == null || address.length() < 5) {
            return "";
        }
        return "**" + address.substring(address.length() - 5);
    }

    private static void writeFrame(GattSession session,
                                   BluetoothGattCharacteristic characteristic,
                                   int frameType,
                                   byte[] payload) throws Exception {
        if (payload.length > BLE_MAX_PAYLOAD_BYTES) {
            throw new IllegalStateException("bluetooth frame too large");
        }
        ByteBuffer buffer = ByteBuffer.allocate(payload.length + 1);
        buffer.put((byte) frameType);
        buffer.put(payload);
        characteristic.setValue(buffer.array());
        session.write(characteristic);
    }

    private static final class GattSession {
        private final Context context;
        private final BluetoothDevice device;
        private BluetoothGatt gatt;
        private CountDownLatch connectLatch;
        private CountDownLatch serviceLatch;
        private CountDownLatch writeLatch;
        private int connectionState = BluetoothProfile.STATE_DISCONNECTED;
        private int lastWriteStatus = BluetoothGatt.GATT_FAILURE;

        GattSession(Context context, BluetoothDevice device) {
            this.context = context;
            this.device = device;
        }

        BluetoothGattCharacteristic connectAndFindWriteCharacteristic() throws Exception {
            connectLatch = new CountDownLatch(1);
            serviceLatch = new CountDownLatch(1);
            gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE);
            if (!connectLatch.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    || connectionState != BluetoothProfile.STATE_CONNECTED) {
                throw new IllegalStateException("bluetooth phone connect timeout");
            }
            if (!gatt.discoverServices()) {
                throw new IllegalStateException("bluetooth service discovery failed");
            }
            if (!serviceLatch.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                throw new IllegalStateException("bluetooth service discovery timeout");
            }
            BluetoothGattService service = gatt.getService(WANJI_SERVICE_UUID);
            BluetoothGattCharacteristic characteristic =
                    service == null ? null : service.getCharacteristic(WANJI_WRITE_UUID);
            if (characteristic == null) {
                throw new IllegalStateException("phone receiver service mismatch");
            }
            return characteristic;
        }

        void write(BluetoothGattCharacteristic characteristic) throws Exception {
            writeLatch = new CountDownLatch(1);
            lastWriteStatus = BluetoothGatt.GATT_FAILURE;
            if (!gatt.writeCharacteristic(characteristic)) {
                throw new IllegalStateException("bluetooth write rejected");
            }
            if (!writeLatch.await(WRITE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                throw new IllegalStateException("bluetooth write timeout");
            }
            if (lastWriteStatus != BluetoothGatt.GATT_SUCCESS) {
                throw new IllegalStateException("bluetooth write failed " + lastWriteStatus);
            }
        }

        void close() {
            if (gatt != null) {
                try {
                    gatt.disconnect();
                } catch (Exception ignored) {
                }
                try {
                    gatt.close();
                } catch (Exception ignored) {
                }
                gatt = null;
            }
        }

        private final BluetoothGattCallback callback = new BluetoothGattCallback() {
            @Override
            public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {
                connectionState = newState;
                if (connectLatch != null) {
                    connectLatch.countDown();
                }
            }

            @Override
            public void onServicesDiscovered(BluetoothGatt gatt, int status) {
                if (serviceLatch != null) {
                    serviceLatch.countDown();
                }
            }

            @Override
            public void onCharacteristicWrite(BluetoothGatt gatt,
                                              BluetoothGattCharacteristic characteristic,
                                              int status) {
                lastWriteStatus = status;
                if (writeLatch != null) {
                    writeLatch.countDown();
                }
            }
        };
    }
}
