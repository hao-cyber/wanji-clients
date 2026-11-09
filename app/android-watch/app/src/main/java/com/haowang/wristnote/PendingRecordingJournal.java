package com.haowang.wristnote;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

final class PendingRecordingJournal {
    private static final String TAG = "PendingRecording";
    private static final String DIR_NAME = "pending_recordings";

    private PendingRecordingJournal() {
    }

    static PendingRecording prepare(Context context, WatchRecorder.Recording recording,
            List<Long> markers) throws Exception {
        if (!Mp4AudioValidator.isCompleteMp4(recording.file)) {
            throw new IllegalStateException("incomplete mp4 recording");
        }
        File dir = dir(context);
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        String id = "a" + System.currentTimeMillis() + "-" + Long.toHexString(System.nanoTime());
        long createdAt = System.currentTimeMillis();
        File audio = new File(dir, id + ".m4a");
        moveOrCopy(recording.file, audio);
        PendingRecording pending = new PendingRecording(
                id, createdAt, recording.durationMs, new ArrayList<>(markers),
                audio, journalFile(dir, id));
        writeJournal(pending);
        Log.i(TAG, "prepared id=" + id + " bytes=" + audio.length()
                + " markers=" + pending.markersMs.size());
        return pending;
    }

    static List<PendingRecording> load(Context context) {
        List<PendingRecording> result = new ArrayList<>();
        File directory = dir(context);
        File[] files = directory.listFiles();
        if (files == null) {
            return result;
        }
        Set<String> journalAudio = new HashSet<>();
        for (File file : files) {
            if (!file.getName().endsWith(".json")) {
                continue;
            }
            try {
                PendingRecording pending = readJournal(file);
                journalAudio.add(pending.audioFile.getName());
                if (pending.audioFile.isFile() && pending.audioFile.length() > 0) {
                    result.add(pending);
                } else {
                    Log.w(TAG, "drop journal with missing audio " + file.getName());
                    //noinspection ResultOfMethodCallIgnored
                    file.delete();
                }
            } catch (Exception e) {
                Log.w(TAG, "read failed " + file.getName() + " " + e.getClass().getSimpleName());
            }
        }
        for (File file : files) {
            if (file.getName().endsWith(".m4a") && !journalAudio.contains(file.getName())) {
                Log.w(TAG, "drop orphan audio " + file.getName());
                //noinspection ResultOfMethodCallIgnored
                file.delete();
            }
        }
        return result;
    }

    static void complete(PendingRecording pending) {
        if (pending == null) {
            return;
        }
        //noinspection ResultOfMethodCallIgnored
        pending.journalFile.delete();
        //noinspection ResultOfMethodCallIgnored
        pending.audioFile.delete();
        Log.i(TAG, "completed id=" + pending.id);
    }

    private static PendingRecording readJournal(File journal) throws Exception {
        String text = new String(readAll(journal), StandardCharsets.UTF_8);
        JSONObject obj = new JSONObject(text);
        File dir = journal.getParentFile();
        String id = obj.getString("id");
        JSONArray arr = obj.optJSONArray("markersMs");
        List<Long> markers = new ArrayList<>();
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                markers.add(arr.getLong(i));
            }
        }
        return new PendingRecording(
                id,
                obj.optLong("createdAt", System.currentTimeMillis()),
                obj.optLong("durationMs", 0L),
                markers,
                new File(dir, obj.optString("audio", id + ".m4a")),
                journal);
    }

    private static void writeJournal(PendingRecording pending) throws Exception {
        JSONObject obj = new JSONObject();
        obj.put("id", pending.id);
        obj.put("createdAt", pending.createdAt);
        obj.put("durationMs", pending.durationMs);
        obj.put("audio", pending.audioFile.getName());
        JSONArray arr = new JSONArray();
        for (Long marker : pending.markersMs) {
            arr.put(marker);
        }
        obj.put("markersMs", arr);
        byte[] bytes = obj.toString().getBytes(StandardCharsets.UTF_8);
        try (FileOutputStream out = new FileOutputStream(pending.journalFile)) {
            out.write(bytes);
            out.getFD().sync();
        }
    }

    private static void moveOrCopy(File source, File target) throws Exception {
        if (source.renameTo(target)) {
            return;
        }
        copyFile(source, target);
        //noinspection ResultOfMethodCallIgnored
        source.delete();
    }

    private static void copyFile(File source, File target) throws Exception {
        try (FileInputStream in = new FileInputStream(source);
             FileOutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) >= 0) {
                out.write(buffer, 0, read);
            }
            out.getFD().sync();
        }
    }

    private static byte[] readAll(File file) throws Exception {
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] data = new byte[(int) file.length()];
            int offset = 0;
            while (offset < data.length) {
                int read = in.read(data, offset, data.length - offset);
                if (read < 0) {
                    break;
                }
                offset += read;
            }
            return data;
        }
    }

    private static File dir(Context context) {
        return new File(context.getFilesDir(), DIR_NAME);
    }

    private static File journalFile(File dir, String id) {
        return new File(dir, id + ".json");
    }

    static final class PendingRecording {
        final String id;
        final long createdAt;
        final long durationMs;
        final List<Long> markersMs;
        final File audioFile;
        final File journalFile;

        PendingRecording(String id, long createdAt, long durationMs, List<Long> markersMs,
                File audioFile, File journalFile) {
            this.id = id;
            this.createdAt = createdAt;
            this.durationMs = durationMs;
            this.markersMs = markersMs;
            this.audioFile = audioFile;
            this.journalFile = journalFile;
        }
    }
}
