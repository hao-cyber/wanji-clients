package com.haowang.wristnote;

import android.content.Context;
import android.media.MediaRecorder;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.List;

final class WatchRecorder {
    private static final String TAG = "WatchRecorder";

    private DualMicAacRecorder dualRecorder;
    private MediaRecorder recorder;
    private File output;
    private FileOutputStream outputStream;
    private long startedAt;
    private String mode = "";
    private String fallbackReason = "";
    private VoiceCaptureOptions options = VoiceCaptureOptions.defaults();

    void start(Context context, File cacheDir) throws Exception {
        start(context, cacheDir, VoiceCaptureOptions.defaults());
    }

    void start(Context context, File cacheDir, VoiceCaptureOptions captureOptions) throws Exception {
        options = captureOptions == null ? VoiceCaptureOptions.defaults() : captureOptions;
        try {
            dualRecorder = new DualMicAacRecorder(context, options);
            dualRecorder.start(cacheDir);
            startedAt = System.currentTimeMillis();
            mode = "dual_mic_aac";
            return;
        } catch (Exception e) {
            fallbackReason = e.getClass().getSimpleName() + ":" + e.getMessage();
            Log.w(TAG, "dual start failed, fallback mono " + fallbackReason);
            if (dualRecorder != null) {
                dualRecorder.discardTemp();
                dualRecorder = null;
            }
        }
        startMono(cacheDir);
    }

    private void startMono(File cacheDir) throws Exception {
        output = new File(cacheDir, "wristnote-" + System.currentTimeMillis() + "-"
                + Long.toHexString(System.nanoTime()) + ".m4a");
        outputStream = new FileOutputStream(output);
        recorder = new MediaRecorder();
        recorder.setAudioSource(options.audioSource());
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
        recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
        recorder.setAudioChannels(1);
        recorder.setAudioSamplingRate(16000);
        recorder.setAudioEncodingBitRate(32000);
        recorder.setOutputFile(outputStream.getFD());
        try {
            recorder.prepare();
            recorder.start();
            startedAt = System.currentTimeMillis();
            mode = "mono_media_recorder";
        } catch (Exception e) {
            discardTemp();
            throw e;
        }
    }

    Recording stop() throws Exception {
        if (dualRecorder != null) {
            try {
                return dualRecorder.stop();
            } finally {
                dualRecorder = null;
                startedAt = 0;
                mode = "";
                fallbackReason = "";
                options = VoiceCaptureOptions.defaults();
            }
        }
        File file = output;
        long durationMs = Math.max(0, System.currentTimeMillis() - startedAt);
        try {
            recorder.stop();
            return new Recording(file, durationMs, mode, monoStats());
        } catch (Exception e) {
            if (file != null) {
                //noinspection ResultOfMethodCallIgnored
                file.delete();
            }
            throw e;
        } finally {
            releaseOnly();
            output = null;
            startedAt = 0;
            mode = "";
            fallbackReason = "";
            options = VoiceCaptureOptions.defaults();
        }
    }

    boolean isRecording() {
        return recorder != null || (dualRecorder != null && dualRecorder.isRecording());
    }

    long elapsedMs() {
        return startedAt == 0 ? 0 : Math.max(0, System.currentTimeMillis() - startedAt);
    }

    void discardTemp() {
        if (dualRecorder != null) {
            dualRecorder.discardTemp();
            dualRecorder = null;
        }
        releaseOnly();
        if (output != null) {
            //noinspection ResultOfMethodCallIgnored
            output.delete();
            output = null;
        }
        startedAt = 0;
        mode = "";
        fallbackReason = "";
        options = VoiceCaptureOptions.defaults();
    }

    private String monoStats() {
        String reason = fallbackReason == null ? "" : fallbackReason.replace(' ', '_');
        return options.report() + " fallback=" + reason + " effects=media_recorder_unsupported";
    }

    static CleanupReport cleanupStaleTemps(File cacheDir) {
        CleanupReport report = new CleanupReport();
        for (File file : staleTempFiles(cacheDir)) {
            report.files++;
            report.bytes += Math.max(0L, file.length());
            if (file.delete()) {
                report.deleted++;
            } else {
                report.failed++;
            }
        }
        return report;
    }

    static List<File> staleTempFiles(File cacheDir) {
        List<File> result = new ArrayList<>();
        File[] files = cacheDir.listFiles();
        if (files == null) {
            return result;
        }
        for (File file : files) {
            if (isRecorderTemp(file)) {
                result.add(file);
            }
        }
        return result;
    }

    static boolean isRecorderTemp(File file) {
        if (file == null || !file.isFile()) {
            return false;
        }
        String name = file.getName();
        return name.endsWith(".m4a")
                && (name.startsWith("wristnote-") || name.startsWith("wristnote-dual-"));
    }

    static long estimateTempDurationMs(File file, long nowMs) {
        long startedAt = tempStartedAtMs(file == null ? "" : file.getName());
        if (startedAt <= 0L) {
            return 0L;
        }
        long endedAt = file == null ? 0L : Math.max(file.lastModified(), nowMs);
        return Math.max(0L, endedAt - startedAt);
    }

    private static long tempStartedAtMs(String name) {
        String prefix;
        if (name.startsWith("wristnote-dual-")) {
            prefix = "wristnote-dual-";
        } else if (name.startsWith("wristnote-")) {
            prefix = "wristnote-";
        } else {
            return 0L;
        }
        int start = prefix.length();
        int end = name.indexOf('-', start);
        if (end <= start) {
            return 0L;
        }
        try {
            return Long.parseLong(name.substring(start, end));
        } catch (Exception ignored) {
            return 0L;
        }
    }

    private void releaseOnly() {
        if (recorder != null) {
            try {
                recorder.release();
            } catch (Exception ignored) {
            }
            recorder = null;
        }
        if (outputStream != null) {
            try {
                outputStream.close();
            } catch (Exception ignored) {
            }
            outputStream = null;
        }
    }

    static final class Recording {
        final File file;
        final long durationMs;
        final String mode;
        final String stats;

        Recording(File file, long durationMs, String mode, String stats) {
            this.file = file;
            this.durationMs = durationMs;
            this.mode = mode;
            this.stats = stats;
        }
    }

    static final class CleanupReport {
        int files;
        int deleted;
        int recovered;
        int failed;
        long bytes;

        boolean hasStaleTemps() {
            return files > 0;
        }

        String detail() {
            return "files=" + files
                    + " deleted=" + deleted
                    + " recovered=" + recovered
                    + " failed=" + failed
                    + " bytes=" + bytes;
        }
    }
}
