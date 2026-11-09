package com.haowang.wristnote;

import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.PowerManager;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;

final class RecordingSession {
    private static final String TAG = "RecordingSession";
    private static final Object LOCK = new Object();
    private static final List<Long> MARKERS = new ArrayList<>();

    private static WatchRecorder recorder;
    private static PowerManager.WakeLock wakeLock;
    private static String sessionId = "";
    private static long lastJournalHeartbeatAt;
    private static boolean debugForceCaptureStopped;
    private static boolean captureRecoveryInProgress;

    private RecordingSession() {
    }

    static void start(Context context) throws Exception {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            if (hasSessionLocked()) {
                return;
            }
            String nextSessionId = "s" + System.currentTimeMillis() + "-"
                    + Long.toHexString(System.nanoTime());
            startForeground(app);
            WatchRecorder next = new WatchRecorder();
            try {
                next.start(app, app.getCacheDir());
                recorder = next;
                sessionId = nextSessionId;
                debugForceCaptureStopped = false;
                MARKERS.clear();
                acquireWakeLock(app);
                lastJournalHeartbeatAt = System.currentTimeMillis();
                ActiveRecordingJournal.start(app, sessionId, lastJournalHeartbeatAt);
                Log.i(TAG, "recording session start");
                RecordingEventLog.record(app, "session_start", "id=" + sessionId);
            } catch (Exception e) {
                next.discardTemp();
                stopForeground(app);
                releaseWakeLock();
                ActiveRecordingJournal.clear(app);
                RecordingEventLog.record(app, "session_start_failed",
                        "id=" + nextSessionId + " error=" + e.getClass().getSimpleName());
                throw e;
            }
        }
    }

    static Result stop(Context context) throws Exception {
        return stop(context, false);
    }

    static Result stop(Context context, boolean keepRecordingResources) throws Exception {
        return stop(context, keepRecordingResources, keepRecordingResources ? "retained" : "normal");
    }

    static Result stop(Context context, boolean keepRecordingResources, String keepReason) throws Exception {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            if (!hasSessionLocked()) {
                throw new IllegalStateException("not recording");
            }
            WatchRecorder active = recorder;
            List<Long> savedMarkers = new ArrayList<>(MARKERS);
            String savedSessionId = sessionId;
            try {
                WatchRecorder.Recording recording = active.stop();
                RecordingEventLog.record(app, "session_stop", "id=" + savedSessionId
                        + " durationMs=" + recording.durationMs
                        + " mode=" + recording.mode
                        + " markers=" + savedMarkers.size()
                        + " stats=" + recording.stats);
                return new Result(savedSessionId, recording, savedMarkers);
            } catch (Exception e) {
                RecordingEventLog.record(app, "session_stop_failed",
                        "id=" + savedSessionId + " error=" + e.getClass().getSimpleName());
                throw e;
            } finally {
                ActiveRecordingJournal.clear(app);
                recorder = null;
                sessionId = "";
                debugForceCaptureStopped = false;
                MARKERS.clear();
                lastJournalHeartbeatAt = 0L;
                if (!keepRecordingResources) {
                    releaseWakeLock();
                    stopForeground(app);
                } else {
                    RecordingEventLog.record(app, "recording_resources_retained",
                            "reason=" + keepReason);
                }
                Log.i(TAG, "recording session stop");
            }
        }
    }

    static void releaseRetainedResources(Context context, String reason) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            if (hasSessionLocked()) {
                return;
            }
            releaseWakeLock();
            stopForeground(app);
            RecordingEventLog.record(app, "recording_resources_released", "reason=" + reason);
        }
    }

    static boolean ensureForeground(Context context, String reason) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            if (!hasSessionLocked()) {
                return false;
            }
            try {
                startForeground(app);
                RecordingEventLog.record(app, "foreground_service_restart_requested",
                        "reason=" + reason + " id=" + sessionId);
                return true;
            } catch (Exception e) {
                RecordingEventLog.record(app, "foreground_service_restart_request_failed",
                        "reason=" + reason
                                + " id=" + sessionId
                                + " error=" + e.getClass().getSimpleName());
                return false;
            }
        }
    }

    static void discard(Context context) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            String discardedSessionId = sessionId;
            if (recorder != null) {
                recorder.discardTemp();
                recorder = null;
            }
            sessionId = "";
            debugForceCaptureStopped = false;
            captureRecoveryInProgress = false;
            MARKERS.clear();
            lastJournalHeartbeatAt = 0L;
            ActiveRecordingJournal.clear(app);
            releaseWakeLock();
            stopForeground(app);
            Log.i(TAG, "recording session discard");
            RecordingEventLog.record(app, "session_discard", "id=" + discardedSessionId);
        }
    }

    static boolean isRecording() {
        synchronized (LOCK) {
            return hasSessionLocked();
        }
    }

    static boolean isCapturing() {
        synchronized (LOCK) {
            return recorder != null && !debugForceCaptureStopped && recorder.isRecording();
        }
    }

    static boolean tryBeginCaptureRecovery(Context context, String source) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            if (!hasSessionLocked() || captureRecoveryInProgress) {
                RecordingEventLog.record(app, "capture_recovery_claim_skipped",
                        "source=" + source
                                + " recording=" + hasSessionLocked()
                                + " inProgress=" + captureRecoveryInProgress);
                return false;
            }
            captureRecoveryInProgress = true;
            RecordingEventLog.record(app, "capture_recovery_claimed",
                    "source=" + source + " id=" + sessionId);
            return true;
        }
    }

    static void finishCaptureRecovery(Context context, String source) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            captureRecoveryInProgress = false;
            RecordingEventLog.record(app, "capture_recovery_claim_released",
                    "source=" + source + " recording=" + hasSessionLocked());
        }
    }

    static void debugForceCaptureStoppedForTest(Context context) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            debugForceCaptureStopped = true;
            RecordingEventLog.record(app, "capture_recovery_smoke_forced_stop",
                    "id=" + sessionId + " elapsedMs=" + (recorder == null ? 0 : recorder.elapsedMs()));
        }
    }

    static long elapsedMs() {
        synchronized (LOCK) {
            return recorder == null ? 0 : recorder.elapsedMs();
        }
    }

    static void addMarker() {
        synchronized (LOCK) {
            if (hasSessionLocked()) {
                MARKERS.add(recorder.elapsedMs());
            }
        }
    }

    static List<Long> markers() {
        synchronized (LOCK) {
            return new ArrayList<>(MARKERS);
        }
    }

    static String sessionId() {
        synchronized (LOCK) {
            return sessionId;
        }
    }

    static void heartbeat(Context context) {
        Context app = context.getApplicationContext();
        synchronized (LOCK) {
            if (!hasSessionLocked() || sessionId.length() == 0) {
                return;
            }
            long now = System.currentTimeMillis();
            if (now - lastJournalHeartbeatAt < ActiveRecordingJournal.MIN_HEARTBEAT_MS) {
                return;
            }
            if (ActiveRecordingJournal.heartbeat(app, sessionId, recorder.elapsedMs(), now)) {
                lastJournalHeartbeatAt = now;
                RecordingEventLog.record(app, "session_heartbeat",
                        "id=" + sessionId + " elapsedMs=" + recorder.elapsedMs());
            }
        }
    }

    private static boolean hasSessionLocked() {
        return recorder != null;
    }

    private static void acquireWakeLock(Context context) {
        if (wakeLock != null && wakeLock.isHeld()) {
            return;
        }
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (power == null) {
            Log.w(TAG, "wake lock skipped: no PowerManager");
            return;
        }
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WristNote:recording");
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire();
        Log.i(TAG, "wake lock acquired");
    }

    private static void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
            Log.i(TAG, "wake lock released");
        }
        wakeLock = null;
    }

    private static void startForeground(Context context) {
        Intent intent = new Intent(context, RecordingForegroundService.class);
        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    private static void stopForeground(Context context) {
        try {
            context.stopService(new Intent(context, RecordingForegroundService.class));
        } catch (Exception e) {
            Log.w(TAG, "foreground stop failed " + e.getClass().getSimpleName());
        }
    }

    static final class Result {
        final String sessionId;
        final WatchRecorder.Recording recording;
        final List<Long> markers;

        Result(String sessionId, WatchRecorder.Recording recording, List<Long> markers) {
            this.sessionId = sessionId;
            this.recording = recording;
            this.markers = markers;
        }
    }
}
