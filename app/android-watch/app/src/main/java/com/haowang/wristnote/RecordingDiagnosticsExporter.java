package com.haowang.wristnote;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;

final class RecordingDiagnosticsExporter {
    static final String ACTION_EXPORT =
            "com.haowang.wristnote.action.EXPORT_RECORDING_DIAGNOSTICS";
    static final String ACTION_REQUEUE_BLE_PULL =
            "com.haowang.wristnote.action.REQUEUE_BLE_PULL_RECORDINGS";
    static final String ACTION_MARK_BLE_UNREADABLE =
            "com.haowang.wristnote.action.MARK_BLE_UNREADABLE_RECORDINGS";
    static final String EXPORT_DIR = "diagnostics-export";

    private RecordingDiagnosticsExporter() {
    }

    static File export(Context context) throws Exception {
        Context app = context.getApplicationContext();
        RecordingEventLog.record(app, "diagnostics_export_snapshot", "phase=before_copy");
        File externalRoot = app.getExternalFilesDir(null);
        if (externalRoot == null) {
            throw new IllegalStateException("external files unavailable");
        }
        File exportDir = new File(externalRoot, EXPORT_DIR);
        recreateDir(exportDir);
        copyEventLog(app, exportDir);
        writeText(new File(exportDir, "session-state.txt"), sessionState(app));
        writeText(new File(exportDir, "active-recording.txt"),
                ActiveRecordingJournal.describe(ActiveRecordingJournal.active(app)));
        writeText(new File(exportDir, "last-interrupted-recording.txt"),
                ActiveRecordingJournal.describe(ActiveRecordingJournal.lastInterrupted(app)));
        writeText(new File(exportDir, "queue-state.txt"), queueState(app));
        writeText(new File(exportDir, "queue-items.txt"), queueItems(app));
        writeText(new File(exportDir, "pending-recordings.txt"), pendingState(app));
        writeText(new File(exportDir, "README.txt"),
                "WristNote recording diagnostics export. Audio files are not exported.\n");
        return exportDir;
    }

    static int requeueBlePull(Context context, String idsCsv) throws Exception {
        if (idsCsv == null || idsCsv.trim().isEmpty()) {
            return 0;
        }
        Context app = context.getApplicationContext();
        AudioStore store = new AudioStore(app);
        List<AudioItem> items = store.load();
        String[] requested = idsCsv.split(",");
        int changed = 0;
        for (String raw : requested) {
            String id = raw == null ? "" : raw.trim();
            if (id.isEmpty()) {
                continue;
            }
            for (AudioItem item : items) {
                if (!id.equals(item.id)) {
                    continue;
                }
                if (!store.hasStoredAudio(item)) {
                    RecordingEventLog.record(app, "ble_requeue_skipped",
                            "id=" + id + " reason=missing_audio");
                    break;
                }
                if (!AudioItem.PENDING.equals(item.state) && !AudioItem.FAILED.equals(item.state)) {
                    item.state = AudioItem.FAILED;
                    item.lastError = "ble_repull_requested";
                    changed++;
                    RecordingEventLog.record(app, "ble_requeue_requested",
                            "id=" + id + " bytes=" + item.sizeBytes);
                }
                break;
            }
        }
        if (changed > 0) {
            store.saveOrThrow(items);
        }
        return changed;
    }

    static int markBleUnreadable(Context context, String idsCsv) throws Exception {
        if (idsCsv == null || idsCsv.trim().isEmpty()) {
            return 0;
        }
        Context app = context.getApplicationContext();
        AudioStore store = new AudioStore(app);
        List<AudioItem> items = store.load();
        String[] requested = idsCsv.split(",");
        int changed = 0;
        for (String raw : requested) {
            String id = raw == null ? "" : raw.trim();
            if (id.isEmpty()) {
                continue;
            }
            for (AudioItem item : items) {
                if (!id.equals(item.id)) {
                    continue;
                }
                item.state = AudioItem.FAILED;
                item.lastError = "ble_unreadable_audio";
                changed++;
                RecordingEventLog.record(app, "ble_unreadable_marked",
                        "id=" + id + " bytes=" + item.sizeBytes);
                break;
            }
        }
        if (changed > 0) {
            store.saveOrThrow(items);
        }
        return changed;
    }

    private static String sessionState(Context context) {
        long generatedAt = System.currentTimeMillis();
        ActiveRecordingJournal.State active = ActiveRecordingJournal.active(context);
        long activeHeartbeatAgeMs = active == null || active.lastHeartbeatAt <= 0L
                ? -1L : Math.max(0L, generatedAt - active.lastHeartbeatAt);
        return String.format(Locale.US,
                "generatedAt=%d\nsessionId=%s\nrecording=%s\ncapturing=%s\nelapsedMs=%d\nmarkers=%d\n"
                        + "activeStatus=%s\nactiveLastHeartbeatAt=%d\nactiveHeartbeatAgeMs=%d\n",
                generatedAt,
                RecordingSession.sessionId(),
                RecordingSession.isRecording(),
                RecordingSession.isCapturing(),
                RecordingSession.elapsedMs(),
                RecordingSession.markers().size(),
                active == null ? "none" : active.status,
                active == null ? 0L : active.lastHeartbeatAt,
                activeHeartbeatAgeMs);
    }

    private static String queueState(Context context) {
        try {
            AudioStore store = new AudioStore(context);
            List<AudioItem> items = store.load();
            int pending = 0;
            int synced = 0;
            int failed = 0;
            long durationMs = 0;
            long sizeBytes = 0;
            StringBuilder out = new StringBuilder();
            out.append("items=").append(items.size()).append('\n');
            for (AudioItem item : items) {
                if (AudioItem.SYNCED.equals(item.state)) {
                    synced++;
                } else if (AudioItem.FAILED.equals(item.state)) {
                    failed++;
                } else {
                    pending++;
                }
                durationMs += item.durationMs;
                sizeBytes += item.sizeBytes;
            }
            out.append("pending=").append(pending).append('\n');
            out.append("synced=").append(synced).append('\n');
            out.append("failed=").append(failed).append('\n');
            out.append("durationMs=").append(durationMs).append('\n');
            out.append("sizeBytes=").append(sizeBytes).append('\n');
            out.append("localEncryptedBytes=").append(store.localBytes(items)).append('\n');
            out.append("freeBytes=").append(store.freeBytes()).append('\n');
            return out.toString();
        } catch (Exception e) {
            return "error=" + e.getClass().getSimpleName() + "\n";
        }
    }

    private static String queueItems(Context context) {
        try {
            AudioStore store = new AudioStore(context);
            List<AudioItem> items = store.load();
            StringBuilder out = new StringBuilder();
            out.append("items=").append(items.size()).append('\n');
            for (int i = 0; i < items.size(); i++) {
                AudioItem item = items.get(i);
                out.append(i)
                        .append(" id=").append(item.id)
                        .append(" state=").append(item.state)
                        .append(" syncKind=").append(item.syncKind)
                        .append(" bytes=").append(item.sizeBytes)
                        .append(" durationMs=").append(item.durationMs)
                        .append(" attempts=").append(item.attempts)
                        .append(" syncedAt=").append(item.syncedAt)
                        .append(" taskId=").append(item.taskId)
                        .append(" conversationId=").append(item.conversationId)
                        .append(" lastError=").append(item.lastError)
                        .append(" audioStored=").append(store.hasStoredAudio(item))
                        .append(" sha256=").append(item.sha256)
                        .append('\n');
            }
            return out.toString();
        } catch (Exception e) {
            return "error=" + e.getClass().getSimpleName() + "\n";
        }
    }

    private static String pendingState(Context context) {
        File dir = new File(context.getFilesDir(), "pending_recordings");
        File[] files = dir.listFiles();
        if (files == null || files.length == 0) {
            return "files=0\n";
        }
        StringBuilder out = new StringBuilder();
        out.append("files=").append(files.length).append('\n');
        for (File file : files) {
            out.append(file.getName())
                    .append(" bytes=").append(file.length())
                    .append(" modifiedAt=").append(file.lastModified())
                    .append('\n');
        }
        return out.toString();
    }

    private static void copyEventLog(Context context, File exportDir) throws Exception {
        File source = RecordingEventLog.file(context);
        File target = new File(exportDir, "recording-events.log");
        if (!source.isFile()) {
            writeText(target, "no recording events\n");
            return;
        }
        try (FileInputStream in = new FileInputStream(source);
             FileOutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[4096];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            out.getFD().sync();
        }
    }

    private static void recreateDir(File dir) {
        deleteContents(dir);
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
    }

    private static void deleteContents(File dir) {
        File[] files = dir.listFiles();
        if (files == null) {
            return;
        }
        for (File file : files) {
            if (file.isDirectory()) {
                deleteContents(file);
            }
            //noinspection ResultOfMethodCallIgnored
            file.delete();
        }
    }

    private static void writeText(File file, String text) throws Exception {
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
    }
}
