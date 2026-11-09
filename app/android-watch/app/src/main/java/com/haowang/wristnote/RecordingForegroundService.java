package com.haowang.wristnote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class RecordingForegroundService extends Service {
    private static final String TAG = "RecordingForeground";
    private static final String CHANNEL_ID = "recording";
    private static final int NOTIFICATION_ID = 1001;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService recoveryIo = Executors.newSingleThreadExecutor();
    private boolean heartbeatScheduled;

    private final Runnable serviceHeartbeat = new Runnable() {
        @Override
        public void run() {
            heartbeatScheduled = false;
            if (!RecordingSession.isRecording()) {
                return;
            }
            if (!RecordingSession.isCapturing()) {
                RecordingEventLog.record(RecordingForegroundService.this,
                        "foreground_service_recording_without_capture", state());
                recoverCaptureGap();
                return;
            }
            RecordingSession.heartbeat(RecordingForegroundService.this);
            RecordingEventLog.record(RecordingForegroundService.this,
                    "foreground_service_heartbeat", state());
            scheduleHeartbeat();
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        startForeground(NOTIFICATION_ID, notification());
        scheduleHeartbeat();
        Log.i(TAG, "foreground service start");
        RecordingEventLog.record(this, "foreground_service_create", state());
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, notification());
        scheduleHeartbeat();
        RecordingEventLog.record(this, "foreground_service_start",
                state() + " flags=" + flags + " startId=" + startId);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        boolean recording = RecordingSession.isRecording();
        Log.i(TAG, "foreground service destroy recording=" + recording);
        RecordingEventLog.record(this, recording
                        ? "foreground_service_destroyed_while_recording"
                        : "foreground_service_destroy",
                state());
        if (recording) {
            RecordingSession.ensureForeground(this, "service_destroyed_while_recording");
        }
        main.removeCallbacks(serviceHeartbeat);
        heartbeatScheduled = false;
        recoveryIo.shutdown();
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        RecordingEventLog.record(this, "foreground_service_task_removed", state());
        Log.i(TAG, "foreground service task removed recording=" + RecordingSession.isRecording());
        if (RecordingSession.isRecording()) {
            startForeground(NOTIFICATION_ID, notification());
            scheduleHeartbeat();
        }
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification notification() {
        ensureChannel();
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getString(R.string.notification_content_status))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build();
    }

    private void scheduleHeartbeat() {
        if (heartbeatScheduled) {
            return;
        }
        heartbeatScheduled = true;
        main.postDelayed(serviceHeartbeat, PowerPolicy.foregroundServiceHeartbeatMs());
    }

    private void recoverCaptureGap() {
        if (!RecordingSession.tryBeginCaptureRecovery(this, "foreground_service")) {
            scheduleHeartbeat();
            return;
        }
        recoveryIo.execute(() -> {
            boolean restarted = false;
            try {
                RecordingEventLog.record(RecordingForegroundService.this,
                        "foreground_capture_recovery_start", state());
                RecordingSession.Result result = RecordingSession.stop(
                        RecordingForegroundService.this, true, "foreground_capture_gap");
                PendingRecordingJournal.PendingRecording pending = PendingRecordingJournal.prepare(
                        RecordingForegroundService.this, result.recording, result.markers);
                RecordingEventLog.record(RecordingForegroundService.this,
                        "foreground_capture_recovery_pending",
                        "session=" + result.sessionId
                                + " id=" + pending.id
                                + " bytes=" + pending.audioFile.length()
                                + " durationMs=" + pending.durationMs);
                try {
                    RecordingSession.start(RecordingForegroundService.this);
                    restarted = true;
                    RecordingEventLog.record(RecordingForegroundService.this,
                            "foreground_capture_recovery_restart_ok",
                            "previousSession=" + result.sessionId + " pending=" + pending.id);
                } catch (Exception e) {
                    RecordingSession.releaseRetainedResources(RecordingForegroundService.this,
                            "foreground_capture_recovery_restart_failed");
                    RecordingEventLog.record(RecordingForegroundService.this,
                            "foreground_capture_recovery_restart_failed",
                            "previousSession=" + result.sessionId
                                    + " pending=" + pending.id
                                    + " error=" + e.getClass().getSimpleName());
                }
                storePendingRecording(result.sessionId, pending);
            } catch (Exception e) {
                Log.w(TAG, "foreground capture recovery failed " + e.getClass().getSimpleName());
                RecordingEventLog.record(RecordingForegroundService.this,
                        "foreground_capture_recovery_failed",
                        state() + " error=" + e.getClass().getSimpleName());
                if (!restarted) {
                    RecordingSession.discard(RecordingForegroundService.this);
                }
            } finally {
                RecordingSession.finishCaptureRecovery(
                        RecordingForegroundService.this, "foreground_service");
                scheduleHeartbeat();
            }
        });
    }

    private void storePendingRecording(String sessionId,
            PendingRecordingJournal.PendingRecording pending) {
        try {
            AudioStore store = new AudioStore(this);
            List<AudioItem> current = new ArrayList<>(store.load());
            AudioItem item = store.store(pending);
            if (!containsItemId(item.id, current)) {
                current.add(0, item);
            }
            store.saveOrThrow(current);
            PendingRecordingJournal.complete(pending);
            RecordingEventLog.record(this, "foreground_capture_recovery_store_ok",
                    "session=" + sessionId
                            + " id=" + item.id
                            + " bytes=" + item.sizeBytes
                            + " durationMs=" + item.durationMs);
        } catch (Exception e) {
            RecordingEventLog.record(this, "foreground_capture_recovery_store_failed",
                    "session=" + sessionId
                            + " id=" + pending.id
                            + " error=" + e.getClass().getSimpleName());
        }
    }

    private boolean containsItemId(String id, List<AudioItem> current) {
        for (AudioItem item : current) {
            if (item.id.equals(id)) {
                return true;
            }
        }
        return false;
    }

    private void ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) {
            return;
        }
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager == null) {
            return;
        }
        NotificationChannel existing = manager.getNotificationChannel(CHANNEL_ID);
        if (existing != null) {
            existing.setName(getString(R.string.notification_channel_status));
            existing.setShowBadge(false);
            manager.createNotificationChannel(existing);
            return;
        }
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, getString(R.string.notification_channel_status),
                NotificationManager.IMPORTANCE_LOW);
        channel.setShowBadge(false);
        manager.createNotificationChannel(channel);
    }

    private String state() {
        return "id=" + RecordingSession.sessionId()
                + " recording=" + RecordingSession.isRecording()
                + " capturing=" + RecordingSession.isCapturing()
                + " elapsedMs=" + RecordingSession.elapsedMs();
    }
}
