package com.haowang.wristnote;

import android.content.Context;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

final class RecordingEventLog {
    private static final String TAG = "RecordingEventLog";
    private static final int MAX_BYTES = 64 * 1024;
    private static final int KEEP_BYTES = 32 * 1024;
    private static final int MAX_DETAIL_CHARS = 512;

    private RecordingEventLog() {
    }

    static void record(Context context, String event, String detail) {
        try {
            write(context.getApplicationContext(), event, detail);
        } catch (Exception e) {
            Log.w(TAG, "event log write failed " + e.getClass().getSimpleName());
        }
    }

    static File file(Context context) {
        return new File(dir(context.getApplicationContext()), "recording-events.log");
    }

    static String sanitizeForTest(String value) {
        return sanitize(value);
    }

    private static synchronized void write(Context context, String event, String detail) throws Exception {
        File directory = dir(context);
        //noinspection ResultOfMethodCallIgnored
        directory.mkdirs();
        File target = new File(directory, "recording-events.log");
        String line = String.format(Locale.US, "%d %s %s\n",
                System.currentTimeMillis(), sanitize(event), sanitize(detail));
        byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
        try (FileOutputStream out = new FileOutputStream(target, true)) {
            out.write(bytes);
            out.getFD().sync();
        }
        trimIfNeeded(target);
    }

    private static void trimIfNeeded(File target) throws Exception {
        if (!target.isFile() || target.length() <= MAX_BYTES) {
            return;
        }
        byte[] data = readAll(target);
        int keep = Math.min(KEEP_BYTES, data.length);
        int start = data.length - keep;
        while (start < data.length && data[start] != '\n') {
            start++;
        }
        if (start < data.length) {
            start++;
        } else {
            start = data.length - keep;
        }
        File temp = new File(target.getParentFile(), target.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(temp)) {
            out.write(data, start, data.length - start);
            out.getFD().sync();
        }
        if (!temp.renameTo(target)) {
            throw new IllegalStateException("event log trim rename failed");
        }
    }

    private static byte[] readAll(File file) throws Exception {
        try (FileInputStream in = new FileInputStream(file);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            return out.toByteArray();
        }
    }

    private static String sanitize(String value) {
        if (value == null) {
            return "";
        }
        String safe = value.replace('\n', ' ')
                .replace('\r', ' ')
                .replace('\t', ' ');
        if (safe.length() > MAX_DETAIL_CHARS) {
            return safe.substring(0, MAX_DETAIL_CHARS);
        }
        return safe;
    }

    private static File dir(Context context) {
        return new File(context.getFilesDir(), "diagnostics");
    }
}
