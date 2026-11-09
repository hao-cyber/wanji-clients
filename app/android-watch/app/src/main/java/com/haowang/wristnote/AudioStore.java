package com.haowang.wristnote;

import android.content.Context;
import android.os.StatFs;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import org.json.JSONArray;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class AudioStore {
    static final int MAX_LOCAL_BYTES = 300 * 1024 * 1024;

    private static final String KEY_ALIAS = "wristnote_audio_key_v1";
    private final File queueDir;

    AudioStore(Context context) {
        queueDir = new File(context.getFilesDir(), "queue");
        //noinspection ResultOfMethodCallIgnored
        queueDir.mkdirs();
    }

    List<AudioItem> load() {
        List<AudioItem> result = new ArrayList<>();
        File file = indexFile();
        if (!file.isFile()) {
            return result;
        }
        try {
            JSONArray arr = new JSONArray(new String(readPlain(file), StandardCharsets.UTF_8));
            for (int i = 0; i < arr.length(); i++) {
                result.add(AudioItem.fromJson(arr.getJSONObject(i)));
            }
        } catch (Exception ignored) {
            result.clear();
        }
        return result;
    }

    void save(List<AudioItem> items) {
        File temp = new File(queueDir, "index.json.tmp");
        try {
            saveOrThrow(items);
        } catch (Exception ignored) {
            //noinspection ResultOfMethodCallIgnored
            temp.delete();
        }
    }

    void saveOrThrow(List<AudioItem> items) throws Exception {
        File target = indexFile();
        File temp = new File(queueDir, "index.json.tmp");
        JSONArray arr = new JSONArray();
        for (AudioItem item : items) {
            arr.put(item.toJson());
        }
        writePlain(temp, arr.toString().getBytes(StandardCharsets.UTF_8));
        if (!temp.renameTo(target)) {
            throw new IllegalStateException("index rename failed");
        }
    }

    AudioItem store(File plain, long durationMs, List<Long> markers) throws Exception {
        if (!Mp4AudioValidator.isCompleteMp4(plain)) {
            throw new IllegalStateException("incomplete mp4 audio");
        }
        AudioItem item = new AudioItem();
        item.id = "a" + System.currentTimeMillis() + "-" + Long.toHexString(System.nanoTime());
        item.createdAt = System.currentTimeMillis();
        item.durationMs = durationMs;
        item.sizeBytes = plain.length();
        item.state = AudioItem.PENDING;
        item.sha256 = sha256(plain);
        item.markersMs.addAll(markers);
        writeEncryptedFromFile(encryptedFile(item), plain);
        return item;
    }

    AudioItem store(PendingRecordingJournal.PendingRecording pending) throws Exception {
        if (!Mp4AudioValidator.isCompleteMp4(pending.audioFile)) {
            throw new IllegalStateException("incomplete mp4 audio");
        }
        AudioItem item = new AudioItem();
        item.id = pending.id;
        item.createdAt = pending.createdAt;
        item.durationMs = pending.durationMs;
        item.sizeBytes = pending.audioFile.length();
        item.state = AudioItem.PENDING;
        item.sha256 = sha256(pending.audioFile);
        item.markersMs.addAll(pending.markersMs);
        File encrypted = encryptedFile(item);
        if (!encrypted.isFile() || encrypted.length() == 0) {
            writeEncryptedFromFile(encrypted, pending.audioFile);
        }
        return item;
    }

    byte[] readAudio(AudioItem item) throws Exception {
        return decrypt(readPlain(encryptedFile(item)));
    }

    boolean hasStoredAudio(AudioItem item) {
        File file = encryptedFile(item);
        return file.isFile() && file.length() > 0;
    }

    long localBytes(List<AudioItem> items) {
        long total = 0;
        for (AudioItem item : items) {
            File file = encryptedFile(item);
            if (file.isFile()) {
                total += file.length();
            }
        }
        return total;
    }

    long freeBytes() {
        StatFs stat = new StatFs(queueDir.getAbsolutePath());
        return stat.getAvailableBytes();
    }

    int deleteSynced(List<AudioItem> items) {
        int deleted = 0;
        for (int i = items.size() - 1; i >= 0; i--) {
            AudioItem item = items.get(i);
            if (AudioItem.SYNCED.equals(item.state)) {
                //noinspection ResultOfMethodCallIgnored
                encryptedFile(item).delete();
                items.remove(i);
                deleted++;
            }
        }
        save(items);
        return deleted;
    }

    int deleteAll(List<AudioItem> items) {
        int deleted = items.size();
        for (AudioItem item : items) {
            //noinspection ResultOfMethodCallIgnored
            encryptedFile(item).delete();
        }
        items.clear();
        save(items);
        return deleted;
    }

    int deleteItem(List<AudioItem> items, AudioItem target) {
        for (int i = items.size() - 1; i >= 0; i--) {
            AudioItem item = items.get(i);
            if (item == target || item.id.equals(target.id)) {
                //noinspection ResultOfMethodCallIgnored
                encryptedFile(item).delete();
                items.remove(i);
                save(items);
                return 1;
            }
        }
        return 0;
    }

    private File indexFile() {
        return new File(queueDir, "index.json");
    }

    private File encryptedFile(AudioItem item) {
        return new File(queueDir, item.id + ".m4a.enc");
    }

    private String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (BufferedInputStream in = new BufferedInputStream(new FileInputStream(file))) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) {
                digest.update(buf, 0, n);
            }
        }
        byte[] bytes = digest.digest();
        StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            hex.append(String.format("%02x", b & 0xff));
        }
        return hex.toString();
    }

    private byte[] readPlain(File file) throws Exception {
        try (BufferedInputStream in = new BufferedInputStream(new FileInputStream(file));
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) {
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        }
    }

    private void writePlain(File file, byte[] bytes) throws Exception {
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(bytes);
            out.getFD().sync();
        }
    }

    private void writeEncryptedFromFile(File target, File plain) throws Exception {
        File temp = new File(target.getParentFile(), target.getName() + ".tmp");
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key());
            byte[] buffer = new byte[8192];
            try (BufferedInputStream in = new BufferedInputStream(new FileInputStream(plain));
                 FileOutputStream out = new FileOutputStream(temp)) {
                out.write(cipher.getIV());
                int read;
                while ((read = in.read(buffer)) != -1) {
                    byte[] encrypted = cipher.update(buffer, 0, read);
                    if (encrypted != null && encrypted.length > 0) {
                        out.write(encrypted);
                    }
                }
                byte[] finalBytes = cipher.doFinal();
                if (finalBytes != null && finalBytes.length > 0) {
                    out.write(finalBytes);
                }
                out.getFD().sync();
            }
            if (target.isFile() && !target.delete()) {
                throw new IllegalStateException("encrypted audio target delete failed");
            }
            if (!temp.renameTo(target)) {
                throw new IllegalStateException("encrypted audio rename failed");
            }
        } finally {
            //noinspection ResultOfMethodCallIgnored
            temp.delete();
        }
    }

    private byte[] decrypt(byte[] packed) throws Exception {
        byte[] iv = new byte[12];
        System.arraycopy(packed, 0, iv, 0, iv.length);
        byte[] cipherText = new byte[packed.length - iv.length];
        System.arraycopy(packed, iv.length, cipherText, 0, cipherText.length);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, iv));
        return cipher.doFinal(cipherText);
    }

    private SecretKey key() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (!keyStore.containsAlias(KEY_ALIAS)) {
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build());
            generator.generateKey();
        }
        return (SecretKey) keyStore.getKey(KEY_ALIAS, null);
    }
}
