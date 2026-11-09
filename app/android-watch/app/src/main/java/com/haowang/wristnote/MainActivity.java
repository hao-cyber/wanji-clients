package com.haowang.wristnote;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.content.pm.PackageManager;
import android.content.pm.ActivityInfo;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.view.ViewGroup;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final String TAG = "WristNote";
    static final String ACTION_TOGGLE_RECORDING =
            "com.haowang.wristnote.action.TOGGLE_RECORDING";
    static final String ACTION_SHOW_DIAL =
            "com.haowang.wristnote.action.SHOW_DIAL";
    private static final int REQ_RECORD_AUDIO = 10;
    private static final int REQ_BLUETOOTH = 11;
    private static final long MAX_RECORD_MS = 8L * 60L * 60L * 1000L;
    private static final int LONG_PRESS_MS = 360;
    private static final int LIBRARY_TRIPLE_TAP_MS = 900;
    private static final int MAX_LIBRARY_ITEMS = 20;
    private static final int LIBRARY_ROW_HEIGHT = 156;
    private static final int LIBRARY_ROW_GAP = 0;
    private static final int ITEM_ACTION_TOUCH_SIZE = 78;
    private static final int ITEM_ACTION_GAP = 14;
    private static final long ITEM_DELETE_DEBOUNCE_MS = 700;
    private static final String RECOVERED_TEMP_ERROR = "recovered_temp_process_interrupted";
    private static final String VOLUME_STATE_PREFIX = "音量 ";
    private static final String DELETE_BLOCKED_STATE = "暂不可删";

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final List<AudioItem> items = new ArrayList<>();
    private final VoiceUploader uploader = new VoiceUploader();
    private final BluetoothWatchSyncAdvertiser watchSyncAdvertiser = new BluetoothWatchSyncAdvertiser();
    private final SimpleDateFormat rowTimeFormat = new SimpleDateFormat("MM/dd HH:mm", Locale.US);

    private AudioStore store;
    private Haptics haptics;
    private AudioManager audioManager;

    private TextView status;
    private TextView timer;
    private TextView summary;
    private TextView detail;
    private TextView primary;
    private TextView sync;
    private TextView clear;
    private FrameLayout rootView;
    private RecordDialView dial;
    private LinearLayout libraryPanel;
    private FrameLayout itemPanel;
    private ScrollView historyScroll;
    private LinearLayout historyList;
    private TimeBadgeView itemBadge;
    private TextView itemTime;
    private TextView itemDuration;
    private TextView itemMeta;
    private TextView feedbackToast;
    private PlaybackProgressRingView playbackProgress;
    private IconButtonView playAction;
    private IconButtonView uploadAction;
    private IconButtonView deleteAction;
    private IconButtonView backAction;
    private View hitLayer;
    private AudioItem focusedItem;
    private AudioItem selectedItem;
    private AudioItem playingItem;
    private AudioItem preparingItem;
    private MediaPlayer player;
    private File playbackFile;
    private int playbackGeneration;
    private boolean libraryOpen;
    private String postDeleteState;
    private boolean snappingHistory;
    private boolean historyTouching;
    private boolean resetLibraryScroll;
    private int appliedDisplayRotation = -1;
    private long lastDeleteActionAtElapsedRealtime;
    private String lastDeleteActionItemId = "";

    private boolean uploading;
    private boolean debugForceUploadFailure;
    private boolean keyLongHandled;
    private int keyDownCode = KeyEvent.KEYCODE_UNKNOWN;
    private int idleKeyTapCount;
    private long lastIdleKeyTapAt;
    private long debugCheckpointSegmentMs;
    private long checkpointSmokeStopAtElapsedRealtime;
    private long logicalRecordingStartedAtElapsedRealtime;
    private boolean checkpointSmokeRunning;
    private File checkpointSmokeReportFile;
    private boolean captureRecoverySmokeRunning;
    private File captureRecoverySmokeReportFile;
    private String currentRenderState = "";
    private final Set<String> checkpointSmokeExistingItemIds = new HashSet<>();

    private final Runnable keyLongPress = () -> {
        keyLongHandled = true;
        resetIdleKeyTaps();
        onControlLongPress();
    };

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (!RecordingSession.isRecording()) {
                return;
            }
            if (!RecordingSession.isCapturing()) {
                handleUnexpectedCaptureStop();
                return;
            }
            long totalElapsedMs = logicalRecordingElapsedMs();
            if (totalElapsedMs >= MAX_RECORD_MS) {
                stopAndStore();
                return;
            }
            if (RecordingCheckpointPolicy.shouldRotate(
                    RecordingSession.elapsedMs(), MAX_RECORD_MS, checkpointSegmentMs(),
                    recordingRemainingMs(totalElapsedMs))) {
                rotateRecordingSegment();
                return;
            }
            RecordingSession.heartbeat(MainActivity.this);
            main.postDelayed(this, PowerPolicy.recordingLimitCheckMs());
        }
    };

    private final Runnable clearTransientFeedback = () -> render(libraryOpen ? "库" : "");

    private final Runnable snapHistory = this::snapHistoryToFocused;

    private final Runnable resetIdleKeyTapCount = this::resetIdleKeyTaps;

    private final Runnable playbackTick = new Runnable() {
        @Override
        public void run() {
            updatePlaybackProgress();
            if (player != null) {
                main.postDelayed(this, PowerPolicy.playbackProgressFrameMs());
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "onCreate");
        lockOrientation();
        enterFullScreen();
        store = new AudioStore(this);
        haptics = new Haptics(this, main);
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        buildUi();
        applyStableVisualRotation();
        synchronized (items) {
            items.clear();
            items.addAll(store.load());
            boolean changed = restoreInterruptedSyncs(items);
            if (changed) {
                store.save(items);
            }
            recoverPendingRecordings(items);
        }
        recoverInterruptedRecordingSession();
        restoreLogicalRecordingClock();
        if (!RecordingSession.isRecording()) {
            WatchRecorder.CleanupReport cleanup = recoverStaleRecorderTemps();
            if (cleanup.hasStaleTemps()) {
                Log.w(TAG, "stale recorder temp recovery " + cleanup.detail());
                RecordingEventLog.record(this, "stale_temp_recovery", cleanup.detail());
            }
        }
        recordLaunchIntent("create", getIntent());
        handleDebugSeed(getIntent());
        handleDebugUi(getIntent());
        handleMicProbe(getIntent());
        handleDualMicSample(getIntent());
        handleRecordSmoke(getIntent());
        handleRecordSessionSmoke(getIntent());
        handleRecordCheckpointSmoke(getIntent());
        handleCaptureRecoverySmoke(getIntent());
        handleOfflineQueueSmoke(getIntent());
        boolean handledShortcut = handleRecordingShortcutLaunch(getIntent(), true);
        if (!handledShortcut) {
            if (isLauncherIntent(getIntent())) {
                openLibraryFromAppEntry();
            } else {
                returnToDial(false);
                render("就绪");
            }
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
        }
        ensureBluetoothPermissions();
        startWatchSyncAdvertiser();
        startWatchPullServer();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (dial != null) {
            dial.setActive(true);
        }
        lockOrientation();
        enterFullScreen();
        applyStableVisualRotation();
        if (!libraryOpen) {
            returnToDial(true);
        }
        if (player != null) {
            main.removeCallbacks(playbackTick);
            main.postDelayed(playbackTick, PowerPolicy.playbackProgressFrameMs());
        }
        if (RecordingSession.isRecording()) {
            main.removeCallbacks(tick);
            main.post(tick);
        }
        startWatchSyncAdvertiser();
        startWatchPullServer();
        render(libraryOpen ? "库" : "");
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (dial != null) {
            dial.setActive(false);
        }
        cancelPendingPlayback();
        stopPlayback(true);
        main.removeCallbacks(keyLongPress);
        keyDownCode = KeyEvent.KEYCODE_UNKNOWN;
        keyLongHandled = false;
        main.removeCallbacks(playbackTick);
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        lockOrientation();
        enterFullScreen();
        applyStableVisualRotation();
        Log.i(TAG, "configuration locked orientation=" + newConfig.orientation);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_BLUETOOTH) {
            startWatchSyncAdvertiser();
            startWatchPullServer();
        }
    }

    private boolean restoreInterruptedSyncs(List<AudioItem> localItems) {
        boolean changed = false;
        for (AudioItem item : localItems) {
            if (AudioItem.SYNCING.equals(item.state)) {
                item.state = AudioItem.FAILED;
                item.lastError = "interrupted";
                changed = true;
            }
        }
        return changed;
    }

    private void recoverPendingRecordings(List<AudioItem> localItems) {
        List<PendingRecordingJournal.PendingRecording> pending =
                PendingRecordingJournal.load(this);
        for (PendingRecordingJournal.PendingRecording recording : pending) {
            try {
                if (!containsItemIdLocked(recording.id, localItems)) {
                    AudioItem item = store.store(recording);
                    localItems.add(0, item);
                    store.saveOrThrow(localItems);
                    Log.i(TAG, "pending recording recovered id=" + item.id
                            + " bytes=" + item.sizeBytes);
                    RecordingEventLog.record(this, "pending_recovered",
                            "id=" + item.id + " bytes=" + item.sizeBytes
                                    + " durationMs=" + item.durationMs);
                } else {
                    Log.i(TAG, "pending recording already indexed id=" + recording.id);
                    RecordingEventLog.record(this, "pending_already_indexed",
                            "id=" + recording.id);
                }
                PendingRecordingJournal.complete(recording);
            } catch (Exception e) {
                Log.w(TAG, "pending recording recover failed id=" + recording.id
                        + " " + e.getClass().getSimpleName());
                RecordingEventLog.record(this, "pending_recover_failed",
                        "id=" + recording.id + " error=" + e.getClass().getSimpleName());
            }
        }
    }

    private WatchRecorder.CleanupReport recoverStaleRecorderTemps() {
        WatchRecorder.CleanupReport report = new WatchRecorder.CleanupReport();
        long nowMs = System.currentTimeMillis();
        for (File file : WatchRecorder.staleTempFiles(getCacheDir())) {
            long bytes = Math.max(0L, file.length());
            report.files++;
            report.bytes += bytes;
            if (bytes <= 0L) {
                if (file.delete()) {
                    report.deleted++;
                } else {
                    report.failed++;
                }
                continue;
            }
            if (!Mp4AudioValidator.isCompleteMp4(file)) {
                if (file.delete()) {
                    report.deleted++;
                } else {
                    report.failed++;
                }
                RecordingEventLog.record(this, "stale_temp_recover_invalid",
                        "file=" + file.getName()
                                + " bytes=" + bytes
                                + " reason=incomplete_mp4");
                continue;
            }
            try {
                AudioItem item = store.store(
                        file, WatchRecorder.estimateTempDurationMs(file, nowMs), new ArrayList<>());
                item.state = AudioItem.FAILED;
                item.lastError = RECOVERED_TEMP_ERROR;
                synchronized (items) {
                    if (!containsItemIdLocked(item.id, items)) {
                        items.add(0, item);
                    }
                    store.saveOrThrow(items);
                }
                report.recovered++;
                if (file.delete()) {
                    report.deleted++;
                } else {
                    report.failed++;
                }
                RecordingEventLog.record(this, "stale_temp_recovered",
                        "id=" + item.id
                                + " file=" + file.getName()
                                + " bytes=" + item.sizeBytes
                                + " durationMs=" + item.durationMs);
            } catch (Exception e) {
                report.failed++;
                RecordingEventLog.record(this, "stale_temp_recover_failed",
                        "file=" + file.getName()
                                + " bytes=" + bytes
                                + " error=" + e.getClass().getSimpleName()
                                + " message=" + shortError(e));
            }
        }
        return report;
    }

    private void recoverInterruptedRecordingSession() {
        if (RecordingSession.isRecording()) {
            return;
        }
        ActiveRecordingJournal.State active = ActiveRecordingJournal.active(this);
        if (active == null) {
            return;
        }
        boolean marked = ActiveRecordingJournal.markInterruptedIfActive(
                this, System.currentTimeMillis(), "activity_start_no_runtime_session");
        RecordingEventLog.record(this, "previous_recording_interrupted",
                "id=" + active.id
                        + " startedAt=" + active.startedAt
                        + " lastHeartbeatAt=" + active.lastHeartbeatAt
                        + " elapsedMs=" + active.elapsedMs
                        + " marked=" + marked);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            lockOrientation();
            enterFullScreen();
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        Log.i(TAG, "onNewIntent recording=" + RecordingSession.isRecording() + " uploading=" + uploading);
        restoreLogicalRecordingClock();
        recordLaunchIntent("new_intent", intent);
        handleDebugSeed(intent);
        handleDebugUi(intent);
        handleMicProbe(intent);
        handleDualMicSample(intent);
        handleRecordSmoke(intent);
        handleRecordSessionSmoke(intent);
        handleRecordCheckpointSmoke(intent);
        handleCaptureRecoverySmoke(intent);
        handleOfflineQueueSmoke(intent);
        if (handleRecordingShortcutLaunch(intent, false)) {
            return;
        }
        if (isLauncherIntent(intent)) {
            openLibraryFromAppEntry();
        }
        render(libraryOpen ? "库" : "");
    }

    private boolean handleRecordingShortcutLaunch(Intent intent, boolean freshCreate) {
        if (!shouldToggleRecordingFromLaunch(intent, freshCreate)) {
            return false;
        }
        String source;
        if (ACTION_TOGGLE_RECORDING.equals(intent.getAction())) {
            source = "record_shortcut_activity";
        } else {
            source = "unknown";
        }
        boolean wasLibraryOpen = libraryOpen;
        boolean hadSelectedItem = selectedItem != null;
        RecordingEventLog.record(this, "recording_shortcut_launch",
                "source=" + source
                        + " recording=" + RecordingSession.isRecording()
                        + " freshCreate=" + freshCreate
                        + " libraryOpen=" + wasLibraryOpen
                        + " itemSelected=" + hadSelectedItem
                        + " uiReset=true");
        returnToDial(true);
        ControlKeyPolicy.LongAction action =
                ControlKeyPolicy.shortcutLaunch(RecordingSession.isRecording());
        if (action == ControlKeyPolicy.LongAction.STOP_RECORDING) {
            stopAndStore(true, false, "launcher_shortcut");
        } else {
            startRecording(true, "launcher_shortcut");
        }
        return true;
    }

    private void recordLaunchIntent(String phase, Intent intent) {
        if (intent == null) {
            RecordingEventLog.record(this, "activity_launch_intent", "phase=" + phase + " action=null");
            return;
        }
        String action = intent.getAction() == null ? "null" : intent.getAction();
        String categories = intent.getCategories() == null ? "none" : intent.getCategories().toString();
        String component = intent.getComponent() == null ? "null" : intent.getComponent().flattenToShortString();
        RecordingEventLog.record(this, "activity_launch_intent",
                "phase=" + phase
                        + " action=" + action
                        + " categories=" + categories.replace(' ', '_')
                        + " flags=0x" + Integer.toHexString(intent.getFlags())
                        + " component=" + component);
    }

    private boolean shouldToggleRecordingFromLaunch(Intent intent, boolean freshCreate) {
        if (intent == null) {
            return false;
        }
        boolean suppressedLaunch = ACTION_SHOW_DIAL.equals(intent.getAction())
                || hasDebugLaunchExtras(intent);
        if (ACTION_TOGGLE_RECORDING.equals(intent.getAction())) {
            return ControlKeyPolicy.shouldToggleFromLaunch(true, suppressedLaunch);
        }
        return ControlKeyPolicy.shouldToggleFromLaunch(false, suppressedLaunch);
    }

    private boolean isLauncherIntent(Intent intent) {
        return intent != null
                && Intent.ACTION_MAIN.equals(intent.getAction())
                && intent.hasCategory(Intent.CATEGORY_LAUNCHER);
    }

    private boolean hasDebugLaunchExtras(Intent intent) {
        if (intent == null) {
            return false;
        }
        return intent.getBooleanExtra("seedUi", false)
                || intent.getBooleanExtra("squareUiAudit", false)
                || intent.getBooleanExtra("openFirstItem", false)
                || intent.getBooleanExtra("playFirstItem", false)
                || intent.getBooleanExtra("recordSmoke", false)
                || intent.getBooleanExtra("sessionSmoke", false)
                || intent.getBooleanExtra("checkpointSmoke", false)
                || intent.getBooleanExtra("captureRecoverySmoke", false)
                || intent.getBooleanExtra("offlineQueueSmoke", false)
                || intent.getBooleanExtra("micProbe", false)
                || intent.getBooleanExtra("dualMicSample", false);
    }

    private void handleRecordSmoke(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("recordSmoke", false)) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "record smoke skipped: RECORD_AUDIO not granted");
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return;
        }
        int requestedMs = intent.getIntExtra("durationMs", 5000);
        int maxSmokeMs = intent.getBooleanExtra("allowLongSmoke", false)
                ? (int) Math.min(MAX_RECORD_MS, Integer.MAX_VALUE)
                : 30_000;
        int durationMs = Math.max(1000, Math.min(maxSmokeMs, requestedMs));
        VoiceCaptureOptions options = VoiceCaptureOptions.fromIntent(intent);
        io.execute(() -> runRecordSmoke(durationMs, options));
    }

    private void runRecordSmoke(int durationMs, VoiceCaptureOptions options) {
        File dir = new File(getFilesDir(), "record_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File outFile = new File(dir, "latest.m4a");
        File reportFile = new File(dir, "latest-report.txt");
        //noinspection ResultOfMethodCallIgnored
        outFile.delete();
        //noinspection ResultOfMethodCallIgnored
        reportFile.delete();
        StringBuilder report = new StringBuilder();
        WatchRecorder smoke = new WatchRecorder();
        WatchRecorder.Recording recording = null;
        try {
            report.append("requested=").append(options.report()).append('\n');
            smoke.start(this, getCacheDir(), options);
            Thread.sleep(durationMs);
            recording = smoke.stop();
            copyFile(recording.file, outFile);
            report.append("durationMs=").append(recording.durationMs).append('\n');
            report.append("mode=").append(recording.mode).append('\n');
            report.append("stats=").append(recording.stats).append('\n');
            report.append("bytes=").append(outFile.length()).append('\n');
            report.append("file=").append(outFile.getAbsolutePath()).append('\n');
            report.append("done\n");
            Log.i(TAG, "record smoke done mode=" + recording.mode + " bytes=" + outFile.length());
        } catch (Exception e) {
            smoke.discardTemp();
            report.append("failed ").append(e.getClass().getSimpleName())
                    .append(':').append(e.getMessage()).append('\n');
            Log.w(TAG, "record smoke failed " + e.getClass().getSimpleName());
        } finally {
            if (recording != null && recording.file != null) {
                //noinspection ResultOfMethodCallIgnored
                recording.file.delete();
            }
            try (FileOutputStream out = new FileOutputStream(reportFile)) {
                out.write(report.toString().getBytes(StandardCharsets.UTF_8));
            } catch (Exception e) {
                Log.w(TAG, "record smoke report failed " + e.getClass().getSimpleName());
            }
        }
    }

    private void handleRecordSessionSmoke(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("sessionSmoke", false)) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "session smoke skipped: RECORD_AUDIO not granted");
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return;
        }
        int requestedMs = intent.getIntExtra("durationMs", 8000);
        int maxSmokeMs = intent.getBooleanExtra("allowLongSmoke", false)
                ? (int) Math.min(MAX_RECORD_MS, Integer.MAX_VALUE)
                : 30_000;
        int durationMs = Math.max(1000, Math.min(maxSmokeMs, requestedMs));
        io.execute(() -> runRecordSessionSmoke(durationMs));
    }

    private void runRecordSessionSmoke(int durationMs) {
        File dir = new File(getFilesDir(), "record_session_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File outFile = new File(dir, "latest.m4a");
        File reportFile = new File(dir, "latest-report.txt");
        //noinspection ResultOfMethodCallIgnored
        outFile.delete();
        //noinspection ResultOfMethodCallIgnored
        reportFile.delete();
        StringBuilder report = new StringBuilder();
        RecordingSession.Result result = null;
        try {
            report.append("requestedMs=").append(durationMs).append('\n');
            RecordingSession.start(this);
            Thread.sleep(durationMs / 2L);
            RecordingSession.addMarker();
            Thread.sleep(Math.max(0, durationMs - durationMs / 2L));
            result = RecordingSession.stop(this);
            WatchRecorder.Recording recording = result.recording;
            copyFile(recording.file, outFile);
            report.append("durationMs=").append(recording.durationMs).append('\n');
            report.append("mode=").append(recording.mode).append('\n');
            report.append("stats=").append(recording.stats).append('\n');
            report.append("markers=").append(result.markers.size()).append('\n');
            report.append("bytes=").append(outFile.length()).append('\n');
            report.append("file=").append(outFile.getAbsolutePath()).append('\n');
            report.append("done\n");
            Log.i(TAG, "session smoke done mode=" + recording.mode + " bytes=" + outFile.length());
        } catch (Exception e) {
            RecordingSession.discard(this);
            report.append("failed ").append(e.getClass().getSimpleName())
                    .append(':').append(e.getMessage()).append('\n');
            Log.w(TAG, "session smoke failed " + e.getClass().getSimpleName());
        } finally {
            if (result != null && result.recording != null && result.recording.file != null) {
                //noinspection ResultOfMethodCallIgnored
                result.recording.file.delete();
            }
            try (FileOutputStream out = new FileOutputStream(reportFile)) {
                out.write(report.toString().getBytes(StandardCharsets.UTF_8));
            } catch (Exception e) {
                Log.w(TAG, "session smoke report failed " + e.getClass().getSimpleName());
            }
        }
    }

    private void handleRecordCheckpointSmoke(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("checkpointSmoke", false)) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "checkpoint smoke skipped: RECORD_AUDIO not granted");
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return;
        }
        if (RecordingSession.isRecording()) {
            writeCheckpointSmokeFailure("already_recording");
            return;
        }
        int durationMs = Math.max(6_000, Math.min(120_000,
                intent.getIntExtra("durationMs", 14_000)));
        int requestedSegmentMs = intent.getIntExtra("checkpointSegmentMs", 4_000);
        int segmentMs = Math.max(2_000, Math.min(durationMs - 2_000, requestedSegmentMs));
        File dir = new File(getFilesDir(), "record_checkpoint_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        checkpointSmokeReportFile = new File(dir, "latest-report.txt");
        //noinspection ResultOfMethodCallIgnored
        checkpointSmokeReportFile.delete();
        synchronized (items) {
            checkpointSmokeExistingItemIds.clear();
            for (AudioItem item : items) {
                checkpointSmokeExistingItemIds.add(item.id);
            }
        }
        debugCheckpointSegmentMs = segmentMs;
        checkpointSmokeStopAtElapsedRealtime = SystemClock.elapsedRealtime() + durationMs;
        checkpointSmokeRunning = true;
        RecordingEventLog.record(this, "checkpoint_smoke_start",
                "durationMs=" + durationMs + " segmentMs=" + segmentMs);
        if (!startRecording(false, "checkpoint_smoke")) {
            finishRecordCheckpointSmoke(durationMs, segmentMs, "start_failed");
            return;
        }
        main.postDelayed(() -> finishRecordCheckpointSmoke(durationMs, segmentMs, "done"),
                durationMs);
    }

    private void handleCaptureRecoverySmoke(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("captureRecoverySmoke", false)) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "capture recovery smoke skipped: RECORD_AUDIO not granted");
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return;
        }
        if (RecordingSession.isRecording()) {
            writeCaptureRecoverySmokeFailure("already_recording");
            return;
        }
        int durationMs = Math.max(6_000, Math.min(30_000,
                intent.getIntExtra("durationMs", 10_000)));
        int forceAfterMs = Math.max(1_500, Math.min(durationMs - 2_000,
                intent.getIntExtra("forceAfterMs", 2_500)));
        File dir = new File(getFilesDir(), "capture_recovery_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        captureRecoverySmokeReportFile = new File(dir, "latest-report.txt");
        //noinspection ResultOfMethodCallIgnored
        captureRecoverySmokeReportFile.delete();
        synchronized (items) {
            checkpointSmokeExistingItemIds.clear();
            for (AudioItem item : items) {
                checkpointSmokeExistingItemIds.add(item.id);
            }
        }
        captureRecoverySmokeRunning = true;
        RecordingEventLog.record(this, "capture_recovery_smoke_start",
                "durationMs=" + durationMs + " forceAfterMs=" + forceAfterMs);
        if (!startRecording(false, "capture_recovery_smoke")) {
            finishCaptureRecoverySmoke(durationMs, forceAfterMs, "start_failed");
            return;
        }
        main.postDelayed(() -> {
            if (!captureRecoverySmokeRunning || !RecordingSession.isRecording()) {
                return;
            }
            RecordingSession.debugForceCaptureStoppedForTest(MainActivity.this);
            main.post(tick);
        }, forceAfterMs);
        main.postDelayed(() -> finishCaptureRecoverySmoke(durationMs, forceAfterMs, "done"),
                durationMs);
    }

    private void finishCaptureRecoverySmoke(int durationMs, int forceAfterMs, String status) {
        if (!captureRecoverySmokeRunning) {
            return;
        }
        if (RecordingSession.isRecording()) {
            stopAndStore(false, false, "capture_recovery_smoke_end");
        }
        RecordingEventLog.record(this, "capture_recovery_smoke_finish", "status=" + status);
        main.postDelayed(() -> writeCaptureRecoverySmokeReport(durationMs, forceAfterMs, status), 5_000L);
    }

    private void writeCaptureRecoverySmokeFailure(String status) {
        File dir = new File(getFilesDir(), "capture_recovery_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        captureRecoverySmokeReportFile = new File(dir, "latest-report.txt");
        captureRecoverySmokeRunning = false;
        try (FileOutputStream out = new FileOutputStream(captureRecoverySmokeReportFile)) {
            out.write(("status=" + status + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            Log.w(TAG, "capture recovery smoke failure report failed " + e.getClass().getSimpleName());
        }
    }

    private long checkpointSegmentMs() {
        if (BuildConfig.DEBUG && debugCheckpointSegmentMs > 0L) {
            return debugCheckpointSegmentMs;
        }
        return RecordingCheckpointPolicy.SEGMENT_MS;
    }

    private long checkpointSmokeRemainingMs() {
        if (!BuildConfig.DEBUG || !checkpointSmokeRunning || checkpointSmokeStopAtElapsedRealtime <= 0L) {
            return Long.MAX_VALUE;
        }
        return Math.max(0L, checkpointSmokeStopAtElapsedRealtime - SystemClock.elapsedRealtime());
    }

    private long logicalRecordingElapsedMs() {
        if (!RecordingSession.isRecording() || logicalRecordingStartedAtElapsedRealtime <= 0L) {
            return RecordingSession.elapsedMs();
        }
        return Math.max(0L, SystemClock.elapsedRealtime() - logicalRecordingStartedAtElapsedRealtime);
    }

    private void restoreLogicalRecordingClock() {
        if (!RecordingSession.isRecording()) {
            logicalRecordingStartedAtElapsedRealtime = 0L;
            return;
        }
        if (logicalRecordingStartedAtElapsedRealtime <= 0L) {
            logicalRecordingStartedAtElapsedRealtime =
                    SystemClock.elapsedRealtime() - RecordingSession.elapsedMs();
            RecordingEventLog.record(this, "logical_recording_clock_restored",
                    "elapsedMs=" + RecordingSession.elapsedMs());
        }
    }

    private long recordingRemainingMs(long totalElapsedMs) {
        long hardLimitRemainingMs = Math.max(0L, MAX_RECORD_MS - totalElapsedMs);
        return Math.min(hardLimitRemainingMs, checkpointSmokeRemainingMs());
    }

    private void finishRecordCheckpointSmoke(int durationMs, int segmentMs, String status) {
        if (!checkpointSmokeRunning) {
            return;
        }
        if (RecordingSession.isRecording()) {
            stopAndStore(false, false, "checkpoint_smoke_end");
        }
        RecordingEventLog.record(this, "checkpoint_smoke_finish", "status=" + status);
        main.postDelayed(() -> writeCheckpointSmokeReport(durationMs, segmentMs, status), 5_000L);
    }

    private void writeCheckpointSmokeFailure(String status) {
        File dir = new File(getFilesDir(), "record_checkpoint_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        checkpointSmokeReportFile = new File(dir, "latest-report.txt");
        checkpointSmokeRunning = false;
        debugCheckpointSegmentMs = 0L;
        checkpointSmokeStopAtElapsedRealtime = 0L;
        try (FileOutputStream out = new FileOutputStream(checkpointSmokeReportFile)) {
            out.write(("status=" + status + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            Log.w(TAG, "checkpoint smoke failure report failed " + e.getClass().getSimpleName());
        }
    }

    private void writeCheckpointSmokeReport(int durationMs, int segmentMs, String status) {
        File reportFile = checkpointSmokeReportFile;
        checkpointSmokeRunning = false;
        debugCheckpointSegmentMs = 0L;
        checkpointSmokeStopAtElapsedRealtime = 0L;
        checkpointSmokeReportFile = null;
        if (reportFile == null) {
            return;
        }
        try {
            String events = readText(RecordingEventLog.file(this));
            int cleanedItems = cleanupCheckpointSmokeItems();
            StringBuilder report = new StringBuilder();
            report.append("status=").append(status).append('\n');
            report.append("durationMs=").append(durationMs).append('\n');
            report.append("checkpointSegmentMs=").append(segmentMs).append('\n');
            report.append("rotateStart=").append(count(events, "record_segment_rotate_start")).append('\n');
            report.append("restartOk=").append(count(events, "record_segment_rotate_restart_ok")).append('\n');
            report.append("restartFailed=").append(count(events, "record_segment_rotate_restart_failed")).append('\n');
            report.append("storeOk=").append(count(events, "store_ok")).append('\n');
            report.append("storeFailed=").append(count(events, "store_failed")).append('\n');
            report.append("recording=").append(RecordingSession.isRecording()).append('\n');
            report.append("capturing=").append(RecordingSession.isCapturing()).append('\n');
            report.append("cleanedItems=").append(cleanedItems).append('\n');
            try (FileOutputStream out = new FileOutputStream(reportFile)) {
                out.write(report.toString().getBytes(StandardCharsets.UTF_8));
                out.getFD().sync();
            }
            Log.i(TAG, "checkpoint smoke report written " + reportFile.getAbsolutePath());
        } catch (Exception e) {
            Log.w(TAG, "checkpoint smoke report failed " + e.getClass().getSimpleName());
        }
    }

    private void writeCaptureRecoverySmokeReport(int durationMs, int forceAfterMs, String status) {
        File reportFile = captureRecoverySmokeReportFile;
        captureRecoverySmokeRunning = false;
        captureRecoverySmokeReportFile = null;
        if (reportFile == null) {
            return;
        }
        try {
            String events = readText(RecordingEventLog.file(this));
            int cleanedItems = cleanupCheckpointSmokeItems();
            StringBuilder report = new StringBuilder();
            report.append("status=").append(status).append('\n');
            report.append("durationMs=").append(durationMs).append('\n');
            report.append("forceAfterMs=").append(forceAfterMs).append('\n');
            report.append("forcedStop=").append(count(events, "capture_recovery_smoke_forced_stop")).append('\n');
            report.append("captureStopped=").append(count(events, "capture_stopped_unexpectedly")).append('\n');
            report.append("recoveryOk=").append(count(events, "capture_recovery_restart_ok")
                    + count(events, "foreground_capture_recovery_restart_ok")).append('\n');
            report.append("recoveryFailed=").append(count(events, "capture_recovery_restart_failed")
                    + count(events, "foreground_capture_recovery_restart_failed")).append('\n');
            report.append("storeOk=").append(count(events, "store_ok")).append('\n');
            report.append("storeFailed=").append(count(events, "store_failed")).append('\n');
            report.append("recording=").append(RecordingSession.isRecording()).append('\n');
            report.append("capturing=").append(RecordingSession.isCapturing()).append('\n');
            report.append("cleanedItems=").append(cleanedItems).append('\n');
            try (FileOutputStream out = new FileOutputStream(reportFile)) {
                out.write(report.toString().getBytes(StandardCharsets.UTF_8));
                out.getFD().sync();
            }
            Log.i(TAG, "capture recovery smoke report written " + reportFile.getAbsolutePath());
        } catch (Exception e) {
            Log.w(TAG, "capture recovery smoke report failed " + e.getClass().getSimpleName());
        }
    }

    private int cleanupCheckpointSmokeItems() {
        int deleted = 0;
        List<AudioItem> snapshot;
        synchronized (items) {
            snapshot = new ArrayList<>(items);
        }
        for (AudioItem item : snapshot) {
            if (checkpointSmokeExistingItemIds.contains(item.id)) {
                continue;
            }
            synchronized (items) {
                deleted += store.deleteItem(items, item);
            }
        }
        checkpointSmokeExistingItemIds.clear();
        return deleted;
    }

    private void copyFile(File source, File target) throws Exception {
        try (FileInputStream in = new FileInputStream(source);
             FileOutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) >= 0) {
                out.write(buffer, 0, read);
            }
        }
    }

    private String readText(File source) throws Exception {
        StringBuilder result = new StringBuilder();
        try (FileInputStream in = new FileInputStream(source)) {
            byte[] buffer = new byte[4096];
            int read;
            while ((read = in.read(buffer)) >= 0) {
                result.append(new String(buffer, 0, read, StandardCharsets.UTF_8));
            }
        }
        return result.toString();
    }

    private int count(String text, String token) {
        int total = 0;
        int offset = 0;
        while (true) {
            int found = text.indexOf(token, offset);
            if (found < 0) {
                return total;
            }
            total++;
            offset = found + token.length();
        }
    }

    private void handleDualMicSample(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("dualMicSample", false)) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "dual mic sample skipped: RECORD_AUDIO not granted");
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return;
        }
        int durationMs = intent.getIntExtra("durationMs", 10_000);
        io.execute(() -> DualMicSample.run(this, durationMs));
    }

    private void handleMicProbe(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("micProbe", false)) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "mic probe skipped: RECORD_AUDIO not granted");
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return;
        }
        io.execute(() -> MicProbe.run(this));
    }

    private void handleDebugSeed(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("seedUi", false)) {
            return;
        }
        synchronized (items) {
            store.deleteAll(items);
            long now = System.currentTimeMillis();
            for (int i = 0; i < 10; i++) {
                File file = new File(getCacheDir(), "ui-seed-" + i + ".m4a");
                try (FileOutputStream out = new FileOutputStream(file)) {
                    out.write(new byte[]{0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32});
                    List<Long> seedMarkers = new ArrayList<>();
                    if (i % 3 == 0) {
                        seedMarkers.add(8000L);
                        seedMarkers.add(18000L);
                    }
                    AudioItem item = store.store(file, (35 + i * 17) * 1000L, seedMarkers);
                    item.createdAt = now - i * 6L * 60L * 60L * 1000L;
                    if (i % 5 == 1) {
                        item.state = AudioItem.FAILED;
                    } else if (i % 5 == 2) {
                        item.state = AudioItem.SYNCED;
                    }
                    items.add(item);
                } catch (Exception e) {
                    Log.w(TAG, "debug seed failed " + e.getClass().getSimpleName());
                } finally {
                    //noinspection ResultOfMethodCallIgnored
                    file.delete();
                }
            }
            store.save(items);
        }
    }

    private void handleDebugUi(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null) {
            return;
        }
        boolean openFirst = intent.getBooleanExtra("openFirstItem", false);
        boolean playFirst = intent.getBooleanExtra("playFirstItem", false);
        if (!openFirst && !playFirst) {
            return;
        }
        main.postDelayed(() -> {
            AudioItem item;
            synchronized (items) {
                item = items.isEmpty() ? null : items.get(0);
            }
            if (item == null || RecordingSession.isRecording()) {
                Log.i(TAG, "debug ui skipped item=" + (item != null));
                return;
            }
            libraryOpen = true;
            selectedItem = item;
            focusedItem = item;
            render("库");
            if (playFirst) {
                main.postDelayed(() -> togglePlayback(item), 250);
            }
        }, 250);
    }

    private void handleOfflineQueueSmoke(Intent intent) {
        if (!BuildConfig.DEBUG || intent == null || !intent.getBooleanExtra("offlineQueueSmoke", false)) {
            return;
        }
        if (RecordingSession.isRecording()) {
            writeOfflineQueueSmokeReport("already_recording", "");
            return;
        }
        if (uploading) {
            writeOfflineQueueSmokeReport("already_uploading", "");
            return;
        }
        synchronized (items) {
            store.deleteAll(items);
        }
        File file = new File(getCacheDir(), "offline-queue-smoke.m4a");
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(new byte[]{0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32});
            AudioItem item = store.store(file, 12_000L, new ArrayList<>());
            item.createdAt = System.currentTimeMillis();
            synchronized (items) {
                items.add(0, item);
                store.saveOrThrow(items);
            }
            RecordingEventLog.record(this, "offline_queue_smoke_seed",
                    "id=" + item.id + " bytes=" + item.sizeBytes);
        } catch (Exception e) {
            writeOfflineQueueSmokeReport("seed_failed", e.getClass().getSimpleName());
            return;
        } finally {
            //noinspection ResultOfMethodCallIgnored
            file.delete();
        }
        debugForceUploadFailure = true;
        RecordingEventLog.record(this, "offline_queue_smoke_start", "forceUploadFailure=true");
        syncPending();
        main.postDelayed(() -> {
            debugForceUploadFailure = false;
            writeOfflineQueueSmokeReport("done", "");
        }, 5_000L);
    }

    private void writeOfflineQueueSmokeReport(String status, String error) {
        File dir = new File(getFilesDir(), "offline_queue_smoke");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File report = new File(dir, "latest-report.txt");
        int pending = 0;
        int failed = 0;
        int syncing = 0;
        int synced = 0;
        int total;
        long bytes;
        int attempts = 0;
        String firstState = "";
        synchronized (items) {
            total = items.size();
            bytes = store.localBytes(items);
            for (AudioItem item : items) {
                if (firstState.length() == 0) {
                    firstState = item.state;
                    attempts = item.attempts;
                }
                if (AudioItem.PENDING.equals(item.state)) {
                    pending++;
                } else if (AudioItem.FAILED.equals(item.state)) {
                    failed++;
                } else if (AudioItem.SYNCING.equals(item.state)) {
                    syncing++;
                } else if (AudioItem.SYNCED.equals(item.state)) {
                    synced++;
                }
            }
        }
        File queueDir = new File(getFilesDir(), "queue");
        File[] queueFiles = queueDir.listFiles();
        int encryptedFiles = 0;
        if (queueFiles != null) {
            for (File queueFile : queueFiles) {
                if (queueFile.getName().endsWith(".m4a.enc") && queueFile.length() > 0) {
                    encryptedFiles++;
                }
            }
        }
        try (FileOutputStream out = new FileOutputStream(report)) {
            String text = "status=" + status + "\n"
                    + "error=" + error + "\n"
                    + "items=" + total + "\n"
                    + "pending=" + pending + "\n"
                    + "failed=" + failed + "\n"
                    + "syncing=" + syncing + "\n"
                    + "synced=" + synced + "\n"
                    + "localBytes=" + bytes + "\n"
                    + "encryptedFiles=" + encryptedFiles + "\n"
                    + "firstState=" + firstState + "\n"
                    + "attempts=" + attempts + "\n"
                    + "uploading=" + uploading + "\n";
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        } catch (Exception e) {
            Log.w(TAG, "offline queue smoke report failed " + e.getClass().getSimpleName());
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        Log.i(TAG, "onDestroy recording=" + RecordingSession.isRecording() + " uploading=" + uploading);
        main.removeCallbacksAndMessages(null);
        watchSyncAdvertiser.stop();
        stopPlayback(true);
        io.shutdownNow();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int code = event.getKeyCode();
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            Log.i(TAG, "key down code=" + code);
        }
        if (isPlaybackVolumeKey(code) && isPlaybackVolumeContext()) {
            if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                adjustPlaybackVolume(code == KeyEvent.KEYCODE_VOLUME_UP ? 1 : -1, "key");
            }
            return true;
        }
        if (!isControlKey(code)) {
            return super.dispatchKeyEvent(event);
        }
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            keyDownCode = code;
            keyLongHandled = false;
            main.postDelayed(keyLongPress, LONG_PRESS_MS);
            return true;
        }
        if (event.getAction() == KeyEvent.ACTION_UP) {
            main.removeCallbacks(keyLongPress);
            if (!keyLongHandled && keyDownCode == code) {
                onControlShortPress();
            }
            keyDownCode = KeyEvent.KEYCODE_UNKNOWN;
            return true;
        }
        return true;
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent event) {
        if (event.getAction() == MotionEvent.ACTION_SCROLL
                && event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)
                && isPlaybackVolumeContext()) {
            float scroll = event.getAxisValue(MotionEvent.AXIS_SCROLL);
            if (scroll != 0f) {
                adjustPlaybackVolume(scroll > 0f ? 1 : -1, "rotary");
                return true;
            }
        }
        return super.onGenericMotionEvent(event);
    }

    private boolean isPlaybackVolumeKey(int code) {
        return code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN;
    }

    private boolean isPlaybackVolumeContext() {
        return libraryOpen && selectedItem != null && !RecordingSession.isRecording();
    }

    private void adjustPlaybackVolume(int direction, String source) {
        if (audioManager == null || direction == 0) {
            return;
        }
        int adjustment = direction > 0 ? AudioManager.ADJUST_RAISE : AudioManager.ADJUST_LOWER;
        try {
            int before = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
            audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, adjustment, 0);
            int current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
            int max = Math.max(1, audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
            if (current == before) {
                return;
            }
            Log.i(TAG, "playback volume source=" + source + " value=" + current + "/" + max);
            RecordingEventLog.record(this, "playback_volume_changed",
                    "source=" + source + " value=" + current + " max=" + max);
            render(VOLUME_STATE_PREFIX + current + "/" + max);
        } catch (Exception e) {
            Log.w(TAG, "playback volume failed " + e.getClass().getSimpleName());
        }
    }

    private boolean isControlKey(int code) {
        return code == KeyEvent.KEYCODE_STEM_PRIMARY
                || code == KeyEvent.KEYCODE_STEM_1
                || code == KeyEvent.KEYCODE_STEM_2
                || code == 265;
    }

    private void onControlLongPress() {
        Log.i(TAG, "control long recording=" + RecordingSession.isRecording() + " uploading=" + uploading);
        ControlKeyPolicy.LongAction action = ControlKeyPolicy.longPress(
                RecordingSession.isRecording(), uploading, libraryOpen);
        if (action == ControlKeyPolicy.LongAction.IGNORE) {
            return;
        }
        if (action == ControlKeyPolicy.LongAction.STOP_RECORDING) {
            stopAndStore();
        } else {
            startRecording();
        }
    }

    private void onControlShortPress() {
        Log.i(TAG, "control short recording=" + RecordingSession.isRecording());
        ControlKeyPolicy.ShortAction action = ControlKeyPolicy.shortPress(
                RecordingSession.isRecording(), libraryOpen, selectedItem != null);
        if (action == ControlKeyPolicy.ShortAction.TOGGLE_PLAYBACK) {
            togglePlayback(selectedItem);
            return;
        }
        if (action == ControlKeyPolicy.ShortAction.OPEN_CENTER_ITEM) {
            AudioItem item = currentLibraryItem();
            if (item == null) {
                haptics.error();
            } else {
                openItem(item);
            }
            return;
        }
        if (action == ControlKeyPolicy.ShortAction.IDLE_TAP) {
            handleIdleKeyTap();
            return;
        }
        resetIdleKeyTaps();
        RecordingSession.addMarker();
        RecordingEventLog.record(this, "marker_added",
                "id=" + RecordingSession.sessionId()
                        + " count=" + RecordingSession.markers().size()
                        + " elapsedMs=" + RecordingSession.elapsedMs());
        haptics.tap();
        render("已标记");
    }

    private void handleIdleKeyTap() {
        long now = System.currentTimeMillis();
        if (now - lastIdleKeyTapAt > LIBRARY_TRIPLE_TAP_MS) {
            idleKeyTapCount = 0;
        }
        lastIdleKeyTapAt = now;
        idleKeyTapCount++;
        main.removeCallbacks(resetIdleKeyTapCount);
        ControlKeyPolicy.ShortAction tapAction = ControlKeyPolicy.idleTapAction(idleKeyTapCount);
        if (tapAction == ControlKeyPolicy.ShortAction.OPEN_LIBRARY) {
            resetIdleKeyTaps();
            openLibraryFromControlKey();
            return;
        }
        haptics.tap();
        render("");
        main.postDelayed(resetIdleKeyTapCount, LIBRARY_TRIPLE_TAP_MS);
    }

    private void resetIdleKeyTaps() {
        idleKeyTapCount = 0;
        lastIdleKeyTapAt = 0;
        main.removeCallbacks(resetIdleKeyTapCount);
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        rootView = root;
        root.setBackgroundColor(Color.rgb(8, 9, 11));
        hitLayer = new View(this);
        hitLayer.setBackgroundColor(Color.TRANSPARENT);
        hitLayer.setClickable(true);
        hitLayer.setOnClickListener(v -> {
            if (ControlKeyPolicy.touchFaceTap() == ControlKeyPolicy.TouchAction.ABSORB) {
                return;
            }
        });
        hitLayer.setOnLongClickListener(v -> {
            return ControlKeyPolicy.touchFaceLongPress() == ControlKeyPolicy.TouchAction.ABSORB;
        });

        dial = new RecordDialView(this);
        root.addView(dial, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        libraryPanel = new LinearLayout(this);
        libraryPanel.setOrientation(LinearLayout.VERTICAL);
        libraryPanel.setGravity(Gravity.CENTER);
        libraryPanel.setPadding(0, 0, 0, 0);
        libraryPanel.setVisibility(View.GONE);

        status = label(14, Color.rgb(230, 232, 235));
        timer = label(1, Color.TRANSPARENT);
        summary = label(12, Color.rgb(154, 160, 166));
        detail = label(11, Color.rgb(112, 118, 125));
        timer.setVisibility(View.GONE);
        summary.setMaxLines(2);
        detail.setMaxLines(2);

        primary = button("", false);

        sync = button("同步", false);
        sync.setOnClickListener(v -> {
            show("手机拉取");
            RecordingEventLog.record(this, "sync_button_pull_mode", "bluetooth=true");
        });

        clear = button("清理", false);
        clear.setOnClickListener(v -> deleteSynced());
        clear.setOnLongClickListener(v -> {
            deleteAll();
            return true;
        });

        int wide = LinearLayout.LayoutParams.MATCH_PARENT;
        historyScroll = new ScrollView(this);
        historyScroll.setFillViewport(false);
        historyScroll.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        historyScroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        historyScroll.setVerticalScrollBarEnabled(false);
        historyScroll.setOnTouchListener((v, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                historyTouching = true;
                main.removeCallbacks(snapHistory);
            } else if (event.getAction() == MotionEvent.ACTION_UP
                    || event.getAction() == MotionEvent.ACTION_CANCEL) {
                historyTouching = false;
                main.removeCallbacks(snapHistory);
                main.postDelayed(snapHistory, 140);
            }
            return false;
        });
        historyScroll.setOnScrollChangeListener((v, scrollX, scrollY, oldScrollX, oldScrollY) -> {
            updateHistoryFocusAndScale();
            if (!historyTouching && !snappingHistory
                    && libraryOpen && selectedItem == null && !RecordingSession.isRecording()) {
                main.removeCallbacks(snapHistory);
                main.postDelayed(snapHistory, 220);
            }
        });
        historyList = new LinearLayout(this);
        historyList.setOrientation(LinearLayout.VERTICAL);
        historyList.setPadding(0, 0, 0, 0);
        historyScroll.addView(historyList, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT));
        libraryPanel.addView(historyScroll, new LinearLayout.LayoutParams(wide, LinearLayout.LayoutParams.MATCH_PARENT));
        root.addView(libraryPanel, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        itemPanel = buildItemPanel();
        root.addView(itemPanel, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        feedbackToast = label(12, Color.rgb(226, 216, 188));
        feedbackToast.setIncludeFontPadding(false);
        feedbackToast.setVisibility(View.GONE);
        FrameLayout.LayoutParams feedbackParams = new FrameLayout.LayoutParams(220, 24,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        feedbackParams.setMargins(0, 0, 0, 48);
        root.addView(feedbackToast, feedbackParams);

        root.addView(hitLayer, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);
        applyStableVisualRotation();
    }

    private void openLibraryFromControlKey() {
        if (RecordingSession.isRecording()) {
            return;
        }
        openLibrary(false);
        haptics.pattern(2);
    }

    private void openLibraryFromAppEntry() {
        openLibrary(true);
    }

    private void openLibrary(boolean stopPreview) {
        if (RecordingSession.isRecording()) {
            return;
        }
        if (stopPreview) {
            cancelPendingPlayback();
            stopPlayback(true);
        }
        libraryOpen = true;
        focusedItem = null;
        resetLibraryScroll = true;
        selectedItem = null;
        render("库");
    }

    private void returnToDial(boolean stopPreview) {
        if (RecordingSession.isRecording()) {
            return;
        }
        if (stopPreview) {
            cancelPendingPlayback();
            stopPlayback(true);
        }
        libraryOpen = false;
        selectedItem = null;
    }

    private TextView label(int sp, int color) {
        TextView view = new TextView(this);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setGravity(Gravity.CENTER);
        return view;
    }

    private FrameLayout buildItemPanel() {
        FrameLayout panel = new FrameLayout(this);
        panel.setPadding(0, 0, 0, 0);
        panel.setVisibility(View.GONE);

        playbackProgress = new PlaybackProgressRingView(this);
        panel.addView(playbackProgress, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER));

        itemBadge = new TimeBadgeView(this);
        itemBadge.setVisibility(View.GONE);

        itemTime = label(14, Color.rgb(222, 206, 168));
        itemTime.setIncludeFontPadding(false);
        FrameLayout.LayoutParams timeParams = new FrameLayout.LayoutParams(224, 26,
                Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        timeParams.setMargins(0, 118, 0, 0);
        panel.addView(itemTime, timeParams);

        itemDuration = label(17, Color.rgb(248, 244, 232));
        itemDuration.setIncludeFontPadding(true);
        itemDuration.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        FrameLayout.LayoutParams durationParams = new FrameLayout.LayoutParams(196, 42,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        durationParams.setMargins(0, 0, 0, 158);
        panel.addView(itemDuration, durationParams);

        itemMeta = label(12, Color.rgb(128, 134, 142));
        itemMeta.setIncludeFontPadding(false);
        FrameLayout.LayoutParams metaParams = new FrameLayout.LayoutParams(220, 24,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        metaParams.setMargins(0, 0, 0, 54);
        panel.addView(itemMeta, metaParams);

        playAction = actionButton(IconButtonView.PLAY, true);
        uploadAction = actionButton(IconButtonView.UPLOAD, false);
        deleteAction = actionButton(IconButtonView.DELETE, false);
        backAction = actionButton(IconButtonView.BACK, false);
        panel.addView(playAction, actionParams(96, Gravity.CENTER, 0, 0, 0, 18));

        LinearLayout bottomActions = new LinearLayout(this);
        bottomActions.setGravity(Gravity.CENTER);
        bottomActions.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams secondary = new LinearLayout.LayoutParams(
                ITEM_ACTION_TOUCH_SIZE, ITEM_ACTION_TOUCH_SIZE);
        secondary.setMargins(0, 0, ITEM_ACTION_GAP, 0);
        bottomActions.addView(uploadAction, secondary);
        LinearLayout.LayoutParams middle = new LinearLayout.LayoutParams(
                ITEM_ACTION_TOUCH_SIZE, ITEM_ACTION_TOUCH_SIZE);
        middle.setMargins(0, 0, ITEM_ACTION_GAP, 0);
        bottomActions.addView(backAction, middle);
        bottomActions.addView(deleteAction, new LinearLayout.LayoutParams(
                ITEM_ACTION_TOUCH_SIZE, ITEM_ACTION_TOUCH_SIZE));
        FrameLayout.LayoutParams bottomParams = new FrameLayout.LayoutParams(
                ITEM_ACTION_TOUCH_SIZE * 3 + ITEM_ACTION_GAP * 2,
                ITEM_ACTION_TOUCH_SIZE,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        bottomParams.setMargins(0, 0, 0, 82);
        panel.addView(bottomActions, bottomParams);

        playAction.setOnClickListener(v -> togglePlayback(selectedItem));
        uploadAction.setOnClickListener(v -> syncSelectedOrPending());
        deleteAction.setOnClickListener(v -> confirmOrDeleteSelected("click"));
        deleteAction.setOnTouchListener(this::handleDeleteActionTouch);
        backAction.setOnClickListener(v -> closeItem());
        return panel;
    }

    private boolean handleDeleteActionTouch(View view, MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            view.setPressed(true);
            return true;
        }
        if (action == MotionEvent.ACTION_UP) {
            view.setPressed(false);
            boolean inside = isInsideActionTouch(view, event);
            RecordingEventLog.record(this, "delete_action_touch",
                    "source=touch phase=up inside=" + inside + " hasItem=" + (selectedItem != null));
            if (inside) {
                confirmOrDeleteSelected("touch_up");
            }
            return true;
        }
        if (action == MotionEvent.ACTION_CANCEL) {
            view.setPressed(false);
            RecordingEventLog.record(this, "delete_action_touch",
                    "source=touch phase=cancel inside=false hasItem=" + (selectedItem != null));
            return true;
        }
        return true;
    }

    private boolean isInsideActionTouch(View view, MotionEvent event) {
        float tolerance = 24f;
        return event.getX() >= -tolerance
                && event.getY() >= -tolerance
                && event.getX() <= view.getWidth() + tolerance
                && event.getY() <= view.getHeight() + tolerance;
    }

    private FrameLayout.LayoutParams orbitParams(int gravity, int left, int top, int right, int bottom) {
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(60, 60, gravity);
        params.setMargins(left, top, right, bottom);
        return params;
    }

    private FrameLayout.LayoutParams actionParams(int size, int gravity, int left, int top, int right, int bottom) {
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(size, size, gravity);
        params.setMargins(left, top, right, bottom);
        return params;
    }

    private IconButtonView actionButton(int icon, boolean prominent) {
        IconButtonView view = new IconButtonView(this);
        view.setIcon(icon);
        view.setProminent(prominent);
        view.setClickable(true);
        view.setFocusable(false);
        view.setBackgroundColor(Color.TRANSPARENT);
        return view;
    }

    private TextView button(String text, boolean prominent) {
        TextView view = label(prominent ? 17 : 13, prominent ? Color.rgb(245, 245, 247) : Color.rgb(197, 202, 208));
        view.setText(text);
        view.setIncludeFontPadding(false);
        view.setClickable(true);
        view.setFocusable(true);
        view.setMinHeight(0);
        view.setPadding(0, 0, 0, 0);
        styleButton(view, prominent, true);
        return view;
    }

    private void startRecording() {
        startRecording(true, "manual");
    }

    private boolean startRecording(boolean userVisible, String reason) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            RecordingEventLog.record(this, "record_start_blocked",
                    "reason=permission request=" + reason);
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_RECORD_AUDIO);
            return false;
        }
        synchronized (items) {
            long localBytes = store.localBytes(items);
            if (localBytes >= AudioStore.MAX_LOCAL_BYTES) {
                RecordingEventLog.record(this, "record_start_blocked",
                        "reason=local_full bytes=" + localBytes
                                + " max=" + AudioStore.MAX_LOCAL_BYTES
                                + " request=" + reason);
                fail("本地已满");
                return false;
            }
        }
        long freeBytes = store.freeBytes();
        long requiredBytes = RecordingStoragePolicy.requiredFreeBytes(MAX_RECORD_MS);
        if (!RecordingStoragePolicy.hasRoomForRecording(freeBytes, MAX_RECORD_MS)) {
            Log.w(TAG, "record start blocked low storage free=" + freeBytes
                    + " required=" + requiredBytes);
            RecordingEventLog.record(this, "record_start_blocked",
                    "reason=low_storage free=" + freeBytes + " required=" + requiredBytes
                            + " request=" + reason);
            fail("空间不足");
            return false;
        }
        try {
            stopPlayback(true);
            cancelPendingPlayback();
            RecordingSession.start(this);
            if (!"segment_rotate".equals(reason) || logicalRecordingStartedAtElapsedRealtime <= 0L) {
                logicalRecordingStartedAtElapsedRealtime = SystemClock.elapsedRealtime();
            }
            libraryOpen = false;
            selectedItem = null;
            Log.i(TAG, "record start");
            RecordingEventLog.record(this, "record_start_ok",
                    "id=" + RecordingSession.sessionId()
                            + " request=" + reason
                            + " free=" + freeBytes + " required=" + requiredBytes);
            if (userVisible) {
                haptics.pattern(2);
            }
            render("");
            main.post(tick);
            return true;
        } catch (Exception e) {
            Log.w(TAG, "record start failed " + e.getClass().getSimpleName());
            RecordingEventLog.record(this, "record_start_failed",
                    "request=" + reason
                            + " error=" + e.getClass().getSimpleName()
                            + " message=" + shortError(e));
            RecordingSession.discard(this);
            logicalRecordingStartedAtElapsedRealtime = 0L;
            fail("未开始");
            return false;
        }
    }

    private void stopAndStore() {
        stopAndStore(true, false, "manual");
    }

    private void rotateRecordingSegment() {
        RecordingEventLog.record(this, "record_segment_rotate_start",
                "id=" + RecordingSession.sessionId()
                        + " elapsedMs=" + RecordingSession.elapsedMs()
                        + " totalElapsedMs=" + logicalRecordingElapsedMs());
        stopAndStore(false, true, "segment_rotate");
    }

    private void stopAndStore(boolean userVisible, boolean restartAfterPrepare, String reason) {
        stopAndStore(userVisible, restartAfterPrepare, reason, "segment_rotate",
                "record_segment_rotate_restart_ok", "record_segment_rotate_restart_failed");
    }

    private void stopAndStore(boolean userVisible, boolean restartAfterPrepare, String reason,
            String restartRequest, String restartOkEvent, String restartFailedEvent) {
        if (!restartAfterPrepare) {
            logicalRecordingStartedAtElapsedRealtime = 0L;
        }
        RecordingSession.Result result;
        try {
            result = RecordingSession.stop(this, restartAfterPrepare, reason);
            WatchRecorder.Recording recording = result.recording;
            Log.i(TAG, "record stop durationMs=" + recording.durationMs
                    + " mode=" + recording.mode + " stats=" + recording.stats);
        } catch (Exception e) {
            Log.w(TAG, "record stop failed " + e.getClass().getSimpleName());
            RecordingEventLog.record(this, "record_stop_failed",
                    "reason=" + reason
                            + " error=" + e.getClass().getSimpleName()
                            + " message=" + shortError(e));
            RecordingSession.discard(this);
            logicalRecordingStartedAtElapsedRealtime = 0L;
            fail("未保存");
            return;
        }
        main.removeCallbacks(tick);
        if (userVisible) {
            haptics.pattern(3);
            render("已存");
        }
        WatchRecorder.Recording recording = result.recording;
        List<Long> savedMarkers = result.markers;
        PendingRecordingJournal.PendingRecording pending;
        try {
            pending = PendingRecordingJournal.prepare(this, recording, savedMarkers);
            RecordingEventLog.record(this, "pending_prepared",
                    "session=" + result.sessionId
                            + " reason=" + reason
                            + " id=" + pending.id
                            + " bytes=" + pending.audioFile.length()
                            + " durationMs=" + pending.durationMs
                            + " markers=" + pending.markersMs.size());
        } catch (Exception e) {
            Log.w(TAG, "pending recording prepare failed " + e.getClass().getSimpleName());
            RecordingEventLog.record(this, "pending_prepare_failed",
                    "session=" + result.sessionId
                            + " reason=" + reason
                            + " error=" + e.getClass().getSimpleName()
                            + " message=" + shortError(e));
            if (recording.file != null) {
                //noinspection ResultOfMethodCallIgnored
                recording.file.delete();
            }
            if (restartAfterPrepare) {
                logicalRecordingStartedAtElapsedRealtime = 0L;
                RecordingSession.releaseRetainedResources(this, "pending_prepare_failed");
            }
            show("未保存");
            return;
        }
        if (restartAfterPrepare) {
            boolean restarted = startRecording(false, restartRequest);
            RecordingEventLog.record(this, restarted
                            ? restartOkEvent
                            : restartFailedEvent,
                    "previousSession=" + result.sessionId
                            + " pending=" + pending.id
                            + " request=" + restartRequest);
            if (!restarted) {
                logicalRecordingStartedAtElapsedRealtime = 0L;
                RecordingSession.releaseRetainedResources(this, restartFailedEvent);
            }
        }
        io.execute(() -> {
            try {
                AudioItem item = store.store(pending);
                synchronized (items) {
                    if (!containsItemIdLocked(item.id, items)) {
                        items.add(0, item);
                    }
                    store.saveOrThrow(items);
                }
                PendingRecordingJournal.complete(pending);
                Log.i(TAG, "store ok bytes=" + item.sizeBytes + " markers=" + item.markersMs.size());
                RecordingEventLog.record(MainActivity.this, "store_ok",
                        "session=" + result.sessionId
                                + " reason=" + reason
                                + " id=" + item.id
                                + " bytes=" + item.sizeBytes
                                + " durationMs=" + item.durationMs
                                + " markers=" + item.markersMs.size());
                if (userVisible) {
                    show("已存");
                }
                scheduleBluetoothSyncAfterStore();
            } catch (Exception e) {
                Log.w(TAG, "store failed " + e.getClass().getSimpleName());
                RecordingEventLog.record(MainActivity.this, "store_failed",
                        "session=" + result.sessionId
                                + " reason=" + reason
                                + " id=" + pending.id
                                + " error=" + e.getClass().getSimpleName()
                                + " message=" + shortError(e));
                if (userVisible || !RecordingSession.isRecording()) {
                    show("未保存");
                }
            }
        });
    }

    private void handleUnexpectedCaptureStop() {
        if (!RecordingSession.tryBeginCaptureRecovery(this, "activity_tick")) {
            return;
        }
        Log.w(TAG, "record capture stopped unexpectedly, storing partial and retrying capture");
        try {
            RecordingEventLog.record(this, "capture_stopped_unexpectedly",
                    "id=" + RecordingSession.sessionId()
                            + " elapsedMs=" + RecordingSession.elapsedMs()
                            + " totalElapsedMs=" + logicalRecordingElapsedMs());
            stopAndStore(false, true, "unexpected_capture_stop",
                    "unexpected_capture_restart",
                    "capture_recovery_restart_ok",
                    "capture_recovery_restart_failed");
        } finally {
            RecordingSession.finishCaptureRecovery(this, "activity_tick");
        }
    }

    private void syncPending() {
        if (uploading) {
            return;
        }
        if (!usesBluetoothPhone()) {
            Log.i(TAG, "sync skipped bluetooth disabled");
            RecordingEventLog.record(this, "sync_skipped", "reason=bluetooth_disabled");
            render("");
            return;
        }
        if (!BluetoothBindingStore.isBound(this)) {
            Log.i(TAG, "sync skipped phone not bound");
            RecordingEventLog.record(this, "sync_skipped", "reason=phone_not_bound");
            render("未绑定");
            return;
        }
        uploading = true;
        Log.i(TAG, "sync start");
        RecordingEventLog.record(this, "sync_start", "scope=all");
        show("同步中");
        io.execute(() -> {
            int changed = 0;
            try {
                List<AudioItem> snapshot;
                synchronized (items) {
                    snapshot = new ArrayList<>(items);
                }
                for (AudioItem item : snapshot) {
                    if (isRecoveredTempItem(item)) {
                        RecordingEventLog.record(MainActivity.this, "sync_item_skipped",
                                "id=" + item.id + " reason=recovered_temp_manual_review");
                        continue;
                    }
                    synchronized (items) {
                        if (!containsItemLocked(item)
                                || (!AudioItem.PENDING.equals(item.state) && !AudioItem.FAILED.equals(item.state))) {
                            continue;
                        }
                        item.state = AudioItem.SYNCING;
                        item.attempts++;
                        store.save(items);
                    }
                    try {
                        VoiceUploader.UploadResult result = uploadAudioForSync(item);
                        synchronized (items) {
                            if (!containsItemLocked(item)) {
                                Log.i(TAG, "sync item ignored after delete id=" + item.id);
                                continue;
                            }
                            item.state = AudioItem.SYNCED;
                            item.syncedAt = System.currentTimeMillis();
                            item.lastError = "";
                            item.syncKind = result.kind;
                            item.taskId = result.taskId;
                            item.conversationId = result.conversationId;
                            changed++;
                            store.save(items);
                        }
                        Log.i(TAG, "sync item ok kind=" + result.kind + " task=" + result.taskId
                                + " attempts=" + item.attempts + " bytes=" + item.sizeBytes);
                        RecordingEventLog.record(MainActivity.this, "sync_item_ok",
                                "id=" + item.id
                                        + " kind=" + result.kind
                                        + " attempts=" + item.attempts
                                        + " bytes=" + item.sizeBytes);
                    } catch (Exception e) {
                        synchronized (items) {
                            if (!containsItemLocked(item)) {
                                Log.i(TAG, "sync item failure ignored after delete id=" + item.id);
                                continue;
                            }
                            item.state = AudioItem.FAILED;
                            item.lastError = shortError(e);
                            store.save(items);
                        }
                        Log.w(TAG, "sync item failed attempts=" + item.attempts + " error=" + item.lastError);
                        RecordingEventLog.record(MainActivity.this, "sync_item_failed",
                                "id=" + item.id
                                        + " attempts=" + item.attempts
                                        + " error=" + item.lastError);
                    }
                }
                int finalChanged = changed;
                main.post(() -> {
                    uploading = false;
                    render(finalChanged > 0 ? "已同步" : "");
                });
            } catch (Exception e) {
                RecordingEventLog.record(MainActivity.this, "sync_failed",
                        "scope=all error=" + e.getClass().getSimpleName()
                                + " message=" + shortError(e));
                main.post(() -> {
                    uploading = false;
                    render(libraryOpen ? "未同步" : "");
                });
            }
        });
    }

    private boolean isRecoveredTempItem(AudioItem item) {
        return item != null && RECOVERED_TEMP_ERROR.equals(item.lastError);
    }

    private void deleteSynced() {
        stopPlayback(true);
        cancelPendingPlayback();
        int deleted;
        synchronized (items) {
            deleted = store.deleteSynced(items);
        }
        Log.i(TAG, "delete synced count=" + deleted);
        render("已清理");
    }

    private void deleteAll() {
        stopPlayback(true);
        cancelPendingPlayback();
        focusedItem = null;
        selectedItem = null;
        int deleted;
        synchronized (items) {
            deleted = store.deleteAll(items);
        }
        Log.i(TAG, "delete all count=" + deleted);
        haptics.error();
        render("已清空");
    }

    private void deleteItem(AudioItem item) {
        stopPlayback(true);
        cancelPendingPlayback();
        selectedItem = null;
        int deleted;
        synchronized (items) {
            deleted = store.deleteItem(items, item);
            if (focusedItem == item) {
                focusedItem = items.isEmpty() ? null : items.get(0);
            }
        }
        Log.i(TAG, "delete item count=" + deleted);
        RecordingEventLog.record(this, "delete_item_done",
                "id=" + item.id + " deleted=" + deleted);
        haptics.pattern(2);
        String state = postDeleteState == null ? "库" : postDeleteState;
        postDeleteState = null;
        render(state);
    }

    private boolean containsItemLocked(AudioItem target) {
        for (AudioItem item : items) {
            if (item == target || item.id.equals(target.id)) {
                return true;
            }
        }
        return false;
    }

    private boolean containsItemIdLocked(String id, List<AudioItem> localItems) {
        for (AudioItem item : localItems) {
            if (item.id.equals(id)) {
                return true;
            }
        }
        return false;
    }

    private void fail(String message) {
        uploading = false;
        haptics.error();
        render(message);
    }

    private void show(String state) {
        main.post(() -> render(state));
    }

    private void lockOrientation() {
        if (BuildConfig.DEBUG && getIntent() != null
                && getIntent().getBooleanExtra("squareUiAudit", false)) {
            setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED);
            return;
        }
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
    }

    private void applyStableVisualRotation() {
        if (rootView == null) {
            return;
        }
        int displayRotation = getWindowManager().getDefaultDisplay().getRotation();
        float rootRotation;
        switch (displayRotation) {
            case Surface.ROTATION_90:
                rootRotation = -90f;
                break;
            case Surface.ROTATION_180:
                rootRotation = 180f;
                break;
            case Surface.ROTATION_270:
                rootRotation = 90f;
                break;
            case Surface.ROTATION_0:
            default:
                rootRotation = 0f;
                break;
        }
        if (appliedDisplayRotation == displayRotation && rootView.getRotation() == rootRotation) {
            return;
        }
        appliedDisplayRotation = displayRotation;
        rootView.setPivotX(rootView.getWidth() > 0 ? rootView.getWidth() / 2f : 233f);
        rootView.setPivotY(rootView.getHeight() > 0 ? rootView.getHeight() / 2f : 233f);
        rootView.setRotation(rootRotation);
        RecordingEventLog.record(this, "visual_rotation_applied",
                "displayRotation=" + displayRotation + " rootRotation=" + rootRotation);
        Log.i(TAG, "visual rotation display=" + displayRotation + " root=" + rootRotation);
    }

    private void enterFullScreen() {
        Window window = getWindow();
        window.setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
        window.getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    }

    private void render(String state) {
        if (status == null) {
            return;
        }
        currentRenderState = state == null ? "" : state;
        boolean recording = RecordingSession.isRecording();
        int pending = 0;
        int synced = 0;
        int failed = 0;
        long bytes;
        AudioItem latest = null;
        List<AudioItem> snapshot;
        synchronized (items) {
            for (AudioItem item : items) {
                if (AudioItem.SYNCED.equals(item.state)) {
                    synced++;
                } else if (AudioItem.FAILED.equals(item.state)) {
                    failed++;
                } else {
                    pending++;
                }
            }
            bytes = store.localBytes(items);
            if (!items.isEmpty()) {
                latest = items.get(0);
            }
            snapshot = new ArrayList<>(items);
        }

        dial.setRecording(recording, System.currentTimeMillis() - logicalRecordingElapsedMs(),
                RecordingSession.markers());

        boolean showLibrary = libraryOpen && !recording;
        if (selectedItem != null && !snapshot.contains(selectedItem)) {
            selectedItem = null;
        }
        boolean showItem = showLibrary && selectedItem != null;
        dial.setVisibility(showLibrary ? View.GONE : View.VISIBLE);
        libraryPanel.setVisibility(showLibrary && !showItem ? View.VISIBLE : View.GONE);
        itemPanel.setVisibility(showItem ? View.VISIBLE : View.GONE);
        hitLayer.setVisibility(showLibrary ? View.GONE : View.VISIBLE);
        renderFeedbackToast(showItem);
        status.setText("");
        timer.setText("");
        int total = pending + synced + failed;
        summary.setText("");
        renderHistory(showLibrary && !showItem, snapshot);
        renderSelectedItem(showItem ? selectedItem : null);
        detail.setText("");
        primary.setText("");
        primary.setAlpha(showLibrary ? 1.0f : 0.02f);
        primary.setEnabled(false);
        sync.setEnabled(!recording && !uploading && (pending + failed) > 0);
        clear.setEnabled(!recording && !uploading && total > 0);
        primary.setVisibility(View.INVISIBLE);
        sync.setVisibility(View.INVISIBLE);
        clear.setVisibility(View.INVISIBLE);
        styleButton(primary, false, primary.isEnabled());
        styleButton(sync, false, sync.isEnabled());
        styleButton(clear, false, clear.isEnabled());
    }

    private void renderFeedbackToast(boolean showItem) {
        main.removeCallbacks(clearTransientFeedback);
        if (feedbackToast == null) {
            return;
        }
        String feedback = feedbackText(currentRenderState);
        boolean showToast = feedback.length() > 0 && !showItem;
        feedbackToast.setText(showToast ? feedback : "");
        feedbackToast.setVisibility(showToast ? View.VISIBLE : View.GONE);
        if (showToast) {
            main.postDelayed(clearTransientFeedback, 1100L);
        }
    }

    private AudioItem currentLibraryItem() {
        updateHistoryFocusAndScale();
        return focusedItem;
    }

    private void startPlayback(AudioItem item) {
        stopPlayback(true);
        int generation = ++playbackGeneration;
        preparingItem = item;
        haptics.pattern(2);
        render("读取");
        long requestedAt = System.currentTimeMillis();
        io.execute(() -> {
            File file = new File(getCacheDir(), "preview-" + item.id + "-" + generation + ".m4a");
            try (FileOutputStream out = new FileOutputStream(file)) {
                out.write(store.readAudio(item));
                Log.i(TAG, "playback temp ready id=" + item.id + " ms="
                        + (System.currentTimeMillis() - requestedAt));
                main.post(() -> playPreparedFile(item, file, generation));
            } catch (Exception e) {
                //noinspection ResultOfMethodCallIgnored
                file.delete();
                Log.w(TAG, "playback prepare failed " + e.getClass().getSimpleName());
                main.post(() -> {
                    if (preparingItem == item) {
                        preparingItem = null;
                    }
                    haptics.error();
                    render("不可播");
                });
            }
        });
    }

    private void playPreparedFile(AudioItem item, File file, int generation) {
        if (generation != playbackGeneration || RecordingSession.isRecording()
                || !libraryOpen || selectedItem != item || !items.contains(item)) {
            //noinspection ResultOfMethodCallIgnored
            file.delete();
            return;
        }
        try {
            MediaPlayer next = new MediaPlayer();
            next.setOnPreparedListener(mp -> main.post(() -> {
                if (generation != playbackGeneration || RecordingSession.isRecording()
                        || !libraryOpen || selectedItem != item || !items.contains(item)
                        || player != mp) {
                    try {
                        mp.release();
                    } catch (Exception ignored) {
                    }
                    //noinspection ResultOfMethodCallIgnored
                    file.delete();
                    return;
                }
                preparingItem = null;
                playingItem = item;
                try {
                    mp.start();
                    updatePlaybackProgress();
                    main.removeCallbacks(playbackTick);
                    main.postDelayed(playbackTick, PowerPolicy.playbackProgressFrameMs());
                    Log.i(TAG, "playback start bytes=" + item.sizeBytes);
                    render("播放");
                } catch (Exception e) {
                    stopPlayback(true);
                    Log.w(TAG, "playback start failed " + e.getClass().getSimpleName() + " " + shortError(e));
                    haptics.error();
                    render("不可播");
                }
            }));
            try (FileInputStream in = new FileInputStream(file)) {
                next.setDataSource(in.getFD());
            }
            next.setOnCompletionListener(mp -> main.post(() -> {
                stopPlayback(true);
                render(libraryOpen ? "库" : "");
            }));
            next.setOnErrorListener((mp, what, extra) -> {
                main.post(() -> {
                    stopPlayback(true);
                    haptics.error();
                    Log.w(TAG, "playback media error what=" + what + " extra=" + extra);
                    render(libraryOpen ? "不可播" : "");
                });
                return true;
            });
            player = next;
            playbackFile = file;
            next.prepareAsync();
            Log.i(TAG, "playback prepare async id=" + item.id);
        } catch (Exception e) {
            //noinspection ResultOfMethodCallIgnored
            file.delete();
            if (preparingItem == item) {
                preparingItem = null;
            }
            Log.w(TAG, "playback failed " + e.getClass().getSimpleName() + " " + shortError(e));
            haptics.error();
            render("不可播");
        }
    }

    private void stopPlayback(boolean silent) {
        MediaPlayer old = player;
        player = null;
        playingItem = null;
        preparingItem = null;
        main.removeCallbacks(playbackTick);
        if (old != null) {
            try {
                old.stop();
            } catch (Exception ignored) {
            }
            try {
                old.release();
            } catch (Exception ignored) {
            }
        }
        if (playbackFile != null) {
            //noinspection ResultOfMethodCallIgnored
            playbackFile.delete();
            playbackFile = null;
        }
        updatePlaybackProgress();
        if (!silent) {
            render(libraryOpen ? "库" : "");
        }
    }

    private void cancelPendingPlayback() {
        playbackGeneration++;
    }

    private boolean isPlaying(AudioItem item) {
        return player != null && playingItem == item;
    }

    private VoiceUploader.UploadResult uploadAudioForSync(AudioItem item) throws Exception {
        if (BuildConfig.DEBUG && debugForceUploadFailure) {
            throw new IllegalStateException("forced offline queue smoke failure");
        }
        return uploader.upload(this, store.readAudio(item), item.createdAt, item.id);
    }

    private void updatePlaybackProgress() {
        if (playbackProgress == null) {
            return;
        }
        if (player == null || playingItem == null) {
            playbackProgress.setProgress(0f, preparingItem != null);
            return;
        }
        try {
            int duration = Math.max(1, player.getDuration());
            playbackProgress.setProgress(Math.min(1f, player.getCurrentPosition() / (float) duration), true);
        } catch (Exception e) {
            playbackProgress.setProgress(0f, false);
        }
    }

    private void renderHistory(boolean showLibrary, List<AudioItem> snapshot) {
        historyList.removeAllViews();
        if (!showLibrary) {
            main.removeCallbacks(snapHistory);
            return;
        }
        updateHistoryEdgePadding();
        if (snapshot.isEmpty()) {
            TextView empty = label(13, Color.rgb(112, 118, 125));
            empty.setText("空");
            historyList.addView(empty, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 42));
            focusedItem = null;
            return;
        }
        if (focusedItem == null || !snapshot.contains(focusedItem)) {
            focusedItem = snapshot.get(0);
        }
        int count = Math.min(MAX_LIBRARY_ITEMS, snapshot.size());
        for (int i = 0; i < count; i++) {
            AudioItem item = snapshot.get(i);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LIBRARY_ROW_HEIGHT);
            params.setMargins(0, i == 0 ? 0 : LIBRARY_ROW_GAP, 0, 0);
            historyList.addView(historyRow(item, isPlaying(item), item == focusedItem), params);
        }
        historyScroll.post(() -> {
            updateHistoryEdgePadding();
            if (resetLibraryScroll) {
                historyScroll.scrollTo(0, 0);
                resetLibraryScroll = false;
            }
            updateHistoryFocusAndScale();
            main.removeCallbacks(snapHistory);
            main.postDelayed(snapHistory, 80);
        });
    }

    private View historyRow(AudioItem item, boolean playing, boolean highlighted) {
        AudioRowView row = new AudioRowView(this);
        row.setItem(item, playing, highlighted);
        row.setTag(item);
        row.setClickable(true);
        row.setFocusable(false);
        row.setOnClickListener(v -> openItem(item));
        return row;
    }

    private void openItem(AudioItem item) {
        if (item == null || RecordingSession.isRecording()) {
            haptics.error();
            return;
        }
        focusedItem = item;
        selectedItem = item;
        haptics.tap();
        render("库");
    }

    private void closeItem() {
        selectedItem = null;
        haptics.tap();
        render("库");
    }

    private void togglePlayback(AudioItem item) {
        if (item == null || RecordingSession.isRecording()) {
            haptics.error();
            return;
        }
        if (isPlaying(item)) {
            Log.i(TAG, "playback stop requested id=" + item.id);
            stopPlayback(false);
            haptics.tap();
            return;
        }
        if (preparingItem == item) {
            Log.i(TAG, "playback prepare cancel requested id=" + item.id);
            cancelPendingPlayback();
            stopPlayback(false);
            haptics.tap();
            return;
        }
        Log.i(TAG, "playback requested id=" + item.id + " bytes=" + item.sizeBytes);
        focusedItem = item;
        selectedItem = item;
        startPlayback(item);
    }

    private void syncSelectedOrPending() {
        AudioItem item = selectedItem;
        if (item == null || RecordingSession.isRecording() || uploading) {
            haptics.error();
            return;
        }
        if (!usesBluetoothPhone() || !BluetoothBindingStore.isBound(this)) {
            haptics.error();
            Log.i(TAG, "sync selected skipped phone not bound");
            RecordingEventLog.record(this, "sync_skipped", "scope=selected reason=phone_not_bound");
            render("库");
            return;
        }
        if (AudioItem.SYNCED.equals(item.state)) {
            haptics.tap();
            render("库");
            return;
        }
        uploading = true;
        synchronized (items) {
            if (!containsItemLocked(item)) {
                uploading = false;
                haptics.error();
                render("库");
                return;
            }
            item.state = AudioItem.SYNCING;
            item.attempts++;
            store.save(items);
        }
        RecordingEventLog.record(this, "sync_start",
                "scope=selected id=" + item.id + " attempts=" + item.attempts);
        haptics.tap();
        render("库");
        io.execute(() -> {
            try {
                VoiceUploader.UploadResult result = uploadAudioForSync(item);
                synchronized (items) {
                    if (containsItemLocked(item)) {
                        item.state = AudioItem.SYNCED;
                        item.syncedAt = System.currentTimeMillis();
                        item.lastError = "";
                        item.syncKind = result.kind;
                        item.taskId = result.taskId;
                        item.conversationId = result.conversationId;
                        store.save(items);
                        Log.i(TAG, "sync selected ok kind=" + result.kind + " task=" + result.taskId
                                + " attempts=" + item.attempts + " bytes=" + item.sizeBytes);
                        RecordingEventLog.record(MainActivity.this, "sync_item_ok",
                                "scope=selected id=" + item.id
                                        + " kind=" + result.kind
                                        + " attempts=" + item.attempts
                                        + " bytes=" + item.sizeBytes);
                    } else {
                        Log.i(TAG, "sync selected ignored after delete id=" + item.id);
                    }
                }
            } catch (Exception e) {
                synchronized (items) {
                    if (containsItemLocked(item)) {
                        item.state = AudioItem.FAILED;
                        item.lastError = shortError(e);
                        store.save(items);
                        Log.w(TAG, "sync selected failed attempts=" + item.attempts + " error=" + item.lastError);
                        RecordingEventLog.record(MainActivity.this, "sync_item_failed",
                                "scope=selected id=" + item.id
                                        + " attempts=" + item.attempts
                                        + " error=" + item.lastError);
                    } else {
                        Log.i(TAG, "sync selected failure ignored after delete id=" + item.id);
                    }
                }
            }
            main.post(() -> {
                uploading = false;
                render("库");
            });
        });
    }

    private void confirmOrDeleteSelected(String source) {
        AudioItem item = selectedItem;
        String itemId = item == null ? "NA" : item.id;
        long now = SystemClock.elapsedRealtime();
        if (item != null
                && item.id.equals(lastDeleteActionItemId)
                && now - lastDeleteActionAtElapsedRealtime < ITEM_DELETE_DEBOUNCE_MS) {
            RecordingEventLog.record(this, "delete_action_debounced",
                    "source=" + source
                            + " deltaMs=" + (now - lastDeleteActionAtElapsedRealtime));
            return;
        }
        lastDeleteActionAtElapsedRealtime = now;
        lastDeleteActionItemId = itemId;
        if (item == null || !ItemActionPolicy.canDelete(RecordingSession.isRecording(), uploading, item.state)) {
            haptics.error();
            RecordingEventLog.record(this, "delete_item_blocked",
                    "source=" + source
                            + " hasItem=" + (item != null)
                            + " recording=" + RecordingSession.isRecording()
                            + " uploading=" + uploading
                            + " state=" + (item == null ? "NA" : item.state));
            render(DELETE_BLOCKED_STATE);
            return;
        }
        RecordingEventLog.record(this, "delete_item_request",
                "source=" + source + " id=" + item.id + " state=" + item.state);
        postDeleteState = "已删除";
        deleteItem(item);
    }

    private boolean usesBluetoothPhone() {
        return BluetoothPhoneUploader.isBluetoothPhoneEndpoint(BuildConfig.PHONE_BASE);
    }

    private void scheduleBluetoothSyncAfterStore() {
        if (BluetoothBindingStore.isBound(this)) {
            RecordingEventLog.record(this, "sync_deferred_to_phone_pull", "bluetooth=true");
        }
    }

    private void ensureBluetoothPermissions() {
        if (!usesBluetoothPhone() || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return;
        }
        List<String> missing = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.BLUETOOTH_SCAN);
        }
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.BLUETOOTH_CONNECT);
        }
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.BLUETOOTH_ADVERTISE);
        }
        if (!missing.isEmpty()) {
            requestPermissions(missing.toArray(new String[0]), REQ_BLUETOOTH);
        }
    }

    private void startWatchSyncAdvertiser() {
        if (!usesBluetoothPhone()) {
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                && (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
                || checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED)) {
            return;
        }
        try {
            watchSyncAdvertiser.start(this, store, this::handlePhoneSyncRequest, this::handlePhoneBound);
        } catch (Exception e) {
            Log.w(TAG, "watch sync advertiser start failed " + e.getClass().getSimpleName());
        }
    }

    private void startWatchPullServer() {
        // Pull service is hosted by BluetoothWatchSyncAdvertiser so iOS talks to one GATT server.
    }

    private void handlePhoneBound() {
        Log.i(TAG, "phone bound over bluetooth");
        RecordingEventLog.record(this, "phone_bound", "bluetooth=true");
        show("已绑定");
    }

    private void handlePhoneSyncRequest() {
        Log.i(TAG, "phone sync request accepted pull mode");
        RecordingEventLog.record(this, "phone_sync_request", "mode=pull");
        show("手机已连接");
    }

    private void renderSelectedItem(AudioItem item) {
        if (item == null || itemPanel == null) {
            return;
        }
        itemBadge.setTime(item.createdAt);
        itemTime.setText(dateTimeText(item));
        itemDuration.setText(formatDuration(item.durationMs));
        String feedback = itemFeedbackText();
        itemMeta.setText(feedback);
        itemMeta.setVisibility(feedback.length() == 0 ? View.GONE : View.VISIBLE);

        boolean canUpload = ItemActionPolicy.canUpload(RecordingSession.isRecording(), uploading, item.state);
        boolean canDelete = ItemActionPolicy.canDelete(RecordingSession.isRecording(), uploading, item.state);
        playAction.setIcon(preparingItem == item
                ? IconButtonView.LOADING
                : (isPlaying(item) ? IconButtonView.PAUSE : IconButtonView.PLAY));
        uploadAction.setIcon(AudioItem.SYNCING.equals(item.state) || uploading ? IconButtonView.LOADING : IconButtonView.UPLOAD);
        deleteAction.setIcon(IconButtonView.DELETE);
        backAction.setIcon(IconButtonView.BACK);
        styleActionButton(playAction, true, true, false);
        styleActionButton(uploadAction, false, canUpload, false);
        styleActionButton(deleteAction, false, canDelete, false);
        styleActionButton(backAction, false, true, false);
        uploadAction.setEnabled(canUpload);
        deleteAction.setEnabled(true);
        updatePlaybackProgress();
    }

    private String itemFeedbackText() {
        return feedbackText(currentRenderState);
    }

    private String feedbackText(String state) {
        if (state == null) {
            return "";
        }
        if ("已删除".equals(state)
                || DELETE_BLOCKED_STATE.equals(state)
                || state.startsWith(VOLUME_STATE_PREFIX)) {
            return state;
        }
        return "";
    }

    private void styleActionButton(IconButtonView view, boolean prominent, boolean enabled, boolean destructive) {
        view.setEnabled(enabled);
        view.setVisuallyEnabled(enabled);
        view.setProminent(prominent);
        view.setDestructive(destructive);
    }

    private void updateHistoryFocusAndScale() {
        if (historyScroll == null || historyList == null || historyList.getChildCount() == 0) {
            return;
        }
        float center = historyScroll.getScrollY() + historyScroll.getHeight() / 2f;
        float range = Math.max(1f, historyScroll.getHeight() * 0.42f);
        float bestDistance = Float.MAX_VALUE;
        AudioItem best = null;
        for (int i = 0; i < historyList.getChildCount(); i++) {
            View child = historyList.getChildAt(i);
            Object tag = child.getTag();
            float childCenter = child.getTop() + child.getHeight() / 2f;
            float distance = Math.abs(childCenter - center);
            float t = Math.min(1f, distance / range);
            float scale = 1.0f;
            child.setScaleX(scale);
            child.setScaleY(1.0f);
            child.setAlpha(Math.max(0.90f, 1.0f - t * 0.10f));
            child.setPadding(0, 0, 0, 0);
            if (distance < bestDistance && tag instanceof AudioItem) {
                bestDistance = distance;
                best = (AudioItem) tag;
            }
        }
        if (best != null && playingItem == null) {
            focusedItem = best;
        }
        for (int i = 0; i < historyList.getChildCount(); i++) {
            View child = historyList.getChildAt(i);
            Object tag = child.getTag();
            if (child instanceof AudioRowView && tag instanceof AudioItem) {
                AudioItem item = (AudioItem) tag;
                ((AudioRowView) child).setItem(item, isPlaying(item), item == focusedItem);
            }
        }
    }

    private void updateHistoryEdgePadding() {
        if (historyScroll == null || historyList == null) {
            return;
        }
        int viewport = historyScroll.getHeight();
        if (viewport <= 0) {
            return;
        }
        int vertical = Math.max(0, (viewport - LIBRARY_ROW_HEIGHT) / 2);
        if (historyList.getPaddingTop() == vertical && historyList.getPaddingBottom() == vertical) {
            return;
        }
        historyList.setPadding(
                historyList.getPaddingLeft(),
                vertical,
                historyList.getPaddingRight(),
                vertical);
    }

    private void snapHistoryToFocused() {
        if (!libraryOpen || selectedItem != null || RecordingSession.isRecording()
                || historyScroll == null || historyList == null || historyList.getChildCount() == 0) {
            return;
        }
        float center = historyScroll.getScrollY() + historyScroll.getHeight() / 2f;
        float bestDistance = Float.MAX_VALUE;
        View best = null;
        for (int i = 0; i < historyList.getChildCount(); i++) {
            View child = historyList.getChildAt(i);
            float childCenter = child.getTop() + child.getHeight() / 2f;
            float distance = Math.abs(childCenter - center);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = child;
            }
        }
        if (best == null || bestDistance < 3f) {
            return;
        }
        int target = Math.round(best.getTop() + best.getHeight() / 2f - historyScroll.getHeight() / 2f);
        int maxScroll = Math.max(0, historyList.getHeight() - historyScroll.getHeight());
        target = Math.max(0, Math.min(maxScroll, target));
        int finalTarget = target;
        snappingHistory = true;
        historyScroll.smoothScrollTo(0, target);
        main.postDelayed(() -> {
            historyScroll.scrollTo(0, finalTarget);
            snappingHistory = false;
            updateHistoryFocusAndScale();
        }, 320);
    }

    private String dateTimeText(AudioItem item) {
        long createdAt = item.createdAt > 0 ? item.createdAt : System.currentTimeMillis();
        return rowTimeFormat.format(new Date(createdAt));
    }

    private String itemMetaText(AudioItem item) {
        return "";
    }

    private void styleButton(TextView view, boolean prominent, boolean enabled) {
        view.setTextColor(enabled
                ? (prominent ? Color.rgb(245, 245, 247) : Color.rgb(197, 202, 208))
                : Color.rgb(86, 91, 98));
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(prominent ? 32 : 24);
        bg.setColor(prominent
                ? (enabled ? Color.rgb(36, 38, 43) : Color.rgb(24, 26, 30))
                : (enabled ? Color.rgb(18, 20, 24) : Color.rgb(12, 13, 15)));
        bg.setStroke(1, enabled
                ? (prominent ? Color.rgb(86, 94, 104) : Color.rgb(47, 51, 57))
                : Color.rgb(28, 31, 36));
        view.setBackground(bg);
    }

    private String formatDuration(long ms) {
        long seconds = Math.max(0, ms / 1000);
        return String.format(Locale.US, "%02d:%02d", seconds / 60, seconds % 60);
    }

    private String shortError(Exception e) {
        String msg = e.getMessage();
        if (msg == null || msg.length() == 0) {
            return e.getClass().getSimpleName();
        }
        return msg.length() > 80 ? msg.substring(0, 80) : msg;
    }
}
