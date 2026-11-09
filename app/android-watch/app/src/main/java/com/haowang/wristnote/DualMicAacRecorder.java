package com.haowang.wristnote;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.media.MediaRecorder;
import android.util.Log;

import java.io.File;
import java.nio.ByteBuffer;
import java.util.Locale;

final class DualMicAacRecorder {
    private static final String TAG = "DualMicAac";
    private static final int SAMPLE_RATE = 16000;
    private static final int BIT_RATE = 32000;
    private static final int BUFFER_SAMPLES = 1024;
    private static final int VAD_FRAME_SAMPLES = SAMPLE_RATE / 50;
    private static final long CODEC_TIMEOUT_US = 10_000L;
    private static final float HIGH_PASS_ALPHA = 0.965f;
    private static final int MODE_BOTTOM = -1;
    private static final int MODE_BACK = 1;
    private static final int SWITCH_TO_BACK_SAMPLES = SAMPLE_RATE / 2;
    private static final int SWITCH_TO_BOTTOM_SAMPLES = SAMPLE_RATE * 2;
    private static final int READ_ERROR_ABORT_COUNT = 50;
    private static final long CAPTURE_STALL_ABORT_MS = 2_500L;
    private static final long EXACT_ZERO_ABORT_SAMPLES = SAMPLE_RATE * 2L;

    private final Context context;
    private final VoiceCaptureOptions options;

    private AudioRecord bottomRecord;
    private AudioRecord backRecord;
    private AudioEffectChain bottomEffects;
    private AudioEffectChain backEffects;
    private MediaCodec codec;
    private MediaMuxer muxer;
    private File output;
    private Thread worker;
    private volatile boolean running;
    private volatile boolean endedUnexpectedly;
    private volatile Exception failure;
    private long startedAt;
    private long submittedSamples;
    private long pairedSamples;
    private long lastSubmittedAtMs;
    private int readErrors;
    private int consecutiveReadErrors;
    private int maxConsecutiveReadErrors;
    private long exactZeroRunSamples;
    private long maxExactZeroRunSamples;
    private int bottomChosen;
    private int backChosen;
    private int mixedChosen;
    private double bottomSq;
    private double backSq;
    private double selectedSq;
    private double cross;
    private int bottomPeakMax;
    private int backPeakMax;
    private int selectedPeakMax;
    private int currentMode = MODE_BOTTOM;
    private int pendingMode = MODE_BOTTOM;
    private int pendingSamples;
    private int switchCount;
    private long bottomClipSamples;
    private long backClipSamples;
    private long selectedClipSamples;
    private long selectedSamples;
    private long vadFrameSamples;
    private double vadFrameSq;
    private long vadTotalFrames;
    private long vadActiveFrames;
    private double vadNoiseDbfs = 120.0;
    private double vadActiveDbfs = -120.0;
    private long firstActiveSample = -1L;
    private long lastActiveSample = -1L;
    private boolean muxerStarted;
    private int trackIndex = -1;
    private String bottomRoute = "";
    private String backRoute = "";
    private String bottomEffectSummary = "";
    private String backEffectSummary = "";
    private float hpPrevInput;
    private float hpPrevOutput;

    DualMicAacRecorder(Context context) {
        this(context, VoiceCaptureOptions.defaults());
    }

    DualMicAacRecorder(Context context, VoiceCaptureOptions options) {
        this.context = context.getApplicationContext();
        this.options = options == null ? VoiceCaptureOptions.defaults() : options;
    }

    void start(File cacheDir) throws Exception {
        output = new File(cacheDir, "wristnote-dual-" + System.currentTimeMillis() + "-"
                + Long.toHexString(System.nanoTime()) + ".m4a");
        try {
            AudioDeviceInfo bottom = findBuiltinMic("bottom");
            AudioDeviceInfo back = findBuiltinMic("back");
            if (bottom == null || back == null) {
                throw new IllegalStateException("dual mic unavailable");
            }

            bottomRecord = createRecord(options.audioSource());
            backRecord = createRecord(options.audioSource());
            if (bottomRecord.getState() != AudioRecord.STATE_INITIALIZED
                    || backRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                throw new IllegalStateException("dual AudioRecord init failed");
            }
            if (!bottomRecord.setPreferredDevice(bottom) || !backRecord.setPreferredDevice(back)) {
                throw new IllegalStateException("dual preferred device rejected");
            }
            bottomEffects = AudioEffectChain.create(bottomRecord.getAudioSessionId(), options);
            backEffects = AudioEffectChain.create(backRecord.getAudioSessionId(), options);
            bottomEffectSummary = bottomEffects.summary();
            backEffectSummary = backEffects.summary();

            bottomRecord.startRecording();
            backRecord.startRecording();
            if (!isRoutedTo(bottomRecord, "bottom") || !isRoutedTo(backRecord, "back")) {
                Log.w(TAG, "dual route not confirmed, continuing with signal gate bottom="
                        + deviceName(bottomRecord.getRoutedDevice()) + " back="
                        + deviceName(backRecord.getRoutedDevice()));
            }
            bottomRoute = deviceName(bottomRecord.getRoutedDevice());
            backRoute = deviceName(backRecord.getRoutedDevice());

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            MediaFormat format = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1);
            format.setInteger(MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, BUFFER_SAMPLES * 2);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            muxer = new MediaMuxer(output.getAbsolutePath(),
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            codec.start();

            running = true;
            startedAt = System.currentTimeMillis();
            lastSubmittedAtMs = startedAt;
            worker = new Thread(this::recordLoop, "DualMicAacRecorder");
            worker.start();
            Log.i(TAG, "dual start bottom=" + deviceName(bottomRecord.getRoutedDevice())
                    + " back=" + deviceName(backRecord.getRoutedDevice())
                    + " " + options.report());
        } catch (Exception e) {
            release();
            deleteOutput();
            throw e;
        }
    }

    WatchRecorder.Recording stop() throws Exception {
        running = false;
        Thread thread = worker;
        if (thread != null) {
            thread.join(8000);
            if (thread.isAlive()) {
                failure = new IllegalStateException("dual recorder stop timeout");
                thread.interrupt();
            }
        }
        long durationMs = audioDurationMs();
        bottomRoute = deviceName(bottomRecord == null ? null : bottomRecord.getRoutedDevice());
        backRoute = deviceName(backRecord == null ? null : backRecord.getRoutedDevice());
        release();
        if (output == null || !output.isFile() || output.length() <= 0) {
            deleteOutput();
            if (failure != null) {
                throw failure;
            }
            throw new IllegalStateException("dual recorder empty output");
        }
        String finalStats = stats();
        if (failure != null) {
            Log.w(TAG, "dual stop preserving partial output " + failure.getClass().getSimpleName());
        }
        Log.i(TAG, "dual stop " + finalStats);
        File file = output;
        output = null;
        return new WatchRecorder.Recording(file, durationMs, "dual_mic_aac", finalStats);
    }

    boolean isRecording() {
        return running;
    }

    long elapsedMs() {
        return startedAt == 0 ? 0 : Math.max(0, System.currentTimeMillis() - startedAt);
    }

    private long audioDurationMs() {
        if (submittedSamples > 0) {
            return submittedSamples * 1000L / SAMPLE_RATE;
        }
        return startedAt == 0 ? 0 : Math.max(0, System.currentTimeMillis() - startedAt);
    }

    void discardTemp() {
        running = false;
        Thread thread = worker;
        if (thread != null) {
            try {
                thread.join(1500);
            } catch (Exception ignored) {
            }
        }
        release();
        deleteOutput();
    }

    private void recordLoop() {
        boolean eosQueued = false;
        try {
            short[] bottomBuffer = new short[BUFFER_SAMPLES];
            short[] backBuffer = new short[BUFFER_SAMPLES];
            while (running) {
                int bottomRead = bottomRecord.read(bottomBuffer, 0, bottomBuffer.length);
                int backRead = backRecord.read(backBuffer, 0, backBuffer.length);
                if (bottomRead <= 0 || backRead <= 0) {
                    registerReadError();
                    drainEncoder(false);
                    abortIfCaptureUnhealthy("read_error");
                    continue;
                }
                consecutiveReadErrors = 0;
                int paired = Math.min(bottomRead, backRead);
                queuePcm(bottomBuffer, backBuffer, paired);
                drainEncoder(false);
                abortIfCaptureUnhealthy("capture_stall");
            }
            queueEndOfStream();
            eosQueued = true;
            drainEncoder(true);
        } catch (Exception e) {
            failure = e;
            endedUnexpectedly = true;
            running = false;
            Log.w(TAG, "dual recorder ended unexpectedly " + e.getClass().getSimpleName());
            if (!eosQueued) {
                try {
                    queueEndOfStream();
                    drainEncoder(true);
                } catch (Exception ignored) {
                }
            }
        }
    }

    private void queuePcm(short[] bottomBuffer, short[] backBuffer, int paired) throws Exception {
        int inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US);
        if (inputIndex < 0) {
            registerReadError();
            return;
        }
        ByteBuffer input = codec.getInputBuffer(inputIndex);
        if (input == null) {
            registerReadError();
            codec.queueInputBuffer(inputIndex, 0, 0, presentationUs(), 0);
            return;
        }
        input.clear();
        int capacitySamples = input.remaining() / 2;
        int count = Math.min(paired, capacitySamples);
        double blockBottomSq = 0;
        double blockBackSq = 0;
        int bottomPeak = 0;
        int backPeak = 0;
        for (int i = 0; i < count; i++) {
            int bottom = bottomBuffer[i];
            int back = backBuffer[i];
            blockBottomSq += bottom * (double) bottom;
            blockBackSq += back * (double) back;
            bottomPeak = Math.max(bottomPeak, Math.abs(bottom));
            backPeak = Math.max(backPeak, Math.abs(back));
        }
        updateFlatlineRun(bottomPeak, backPeak, count);
        abortIfCaptureUnhealthy("flatline");
        double bottomRms = count == 0 ? 0 : Math.sqrt(blockBottomSq / count);
        double backRms = count == 0 ? 0 : Math.sqrt(blockBackSq / count);
        int mode = chooseMode(bottomRms, backRms, bottomPeak, backPeak, count);
        if (mode == MODE_BOTTOM) {
            bottomChosen++;
        } else if (mode == MODE_BACK) {
            backChosen++;
        } else {
            mixedChosen++;
        }

        for (int i = 0; i < count; i++) {
            short bottom = bottomBuffer[i];
            short back = backBuffer[i];
            short sample;
            if (mode == MODE_BOTTOM) {
                sample = bottom;
            } else if (mode == MODE_BACK) {
                sample = back;
            } else {
                sample = clampToShort((bottom + back) / 2);
            }
            sample = highPass(sample);
            addSelectedStats(sample);
            input.put((byte) (sample & 0xff));
            input.put((byte) ((sample >> 8) & 0xff));
            bottomSq += bottom * (double) bottom;
            backSq += back * (double) back;
            cross += bottom * (double) back;
            bottomPeakMax = Math.max(bottomPeakMax, Math.abs(bottom));
            backPeakMax = Math.max(backPeakMax, Math.abs(back));
            if (Math.abs(bottom) >= 32700) {
                bottomClipSamples++;
            }
            if (Math.abs(back) >= 32700) {
                backClipSamples++;
            }
        }
        long pts = presentationUs();
        submittedSamples += count;
        lastSubmittedAtMs = System.currentTimeMillis();
        pairedSamples += count;
        codec.queueInputBuffer(inputIndex, 0, count * 2, pts, 0);
    }

    private void registerReadError() {
        readErrors++;
        consecutiveReadErrors++;
        maxConsecutiveReadErrors = Math.max(maxConsecutiveReadErrors, consecutiveReadErrors);
    }

    private void updateFlatlineRun(int bottomPeak, int backPeak, int samples) {
        if (bottomPeak == 0 && backPeak == 0) {
            exactZeroRunSamples += Math.max(0, samples);
        } else {
            exactZeroRunSamples = 0L;
        }
        maxExactZeroRunSamples = Math.max(maxExactZeroRunSamples, exactZeroRunSamples);
    }

    private void abortIfCaptureUnhealthy(String reason) {
        long now = System.currentTimeMillis();
        if (!shouldAbortCapture(now, lastSubmittedAtMs, consecutiveReadErrors, exactZeroRunSamples)) {
            return;
        }
        throw new IllegalStateException(reason
                + " consecutiveReadErrors=" + consecutiveReadErrors
                + " stallMs=" + Math.max(0L, now - lastSubmittedAtMs)
                + " exactZeroMs=" + exactZeroRunSamples * 1000L / SAMPLE_RATE);
    }

    static boolean shouldAbortCapture(long nowMs, long lastSubmittedAtMs,
            int consecutiveReadErrors, long exactZeroRunSamples) {
        long stallMs = Math.max(0L, nowMs - lastSubmittedAtMs);
        return exactZeroRunSamples >= EXACT_ZERO_ABORT_SAMPLES
                || (consecutiveReadErrors >= READ_ERROR_ABORT_COUNT
                && stallMs >= CAPTURE_STALL_ABORT_MS);
    }

    private int chooseMode(double bottomRms, double backRms, int bottomPeak, int backPeak,
            int samples) {
        boolean bottomSilent = bottomRms < 1 && backRms >= 1;
        boolean backSilent = backRms < 1 && bottomRms >= 1;
        boolean bottomClipped = bottomPeak > 30_000 && backPeak < 28_000;
        boolean backClipped = backPeak > 30_000 && bottomPeak < 28_000;
        if (bottomSilent || bottomClipped) {
            return switchNow(MODE_BACK);
        }
        if (backSilent || backClipped) {
            return switchNow(MODE_BOTTOM);
        }

        boolean bottomClearlyNoisy = bottomRms > Math.max(600.0, backRms * 4.0)
                && bottomPeak > backPeak * 2;
        if (currentMode == MODE_BOTTOM && bottomClearlyNoisy) {
            return switchAfter(MODE_BACK, samples, SWITCH_TO_BACK_SAMPLES);
        }

        boolean bottomHealthy = bottomRms >= 1 && bottomPeak < 28_000;
        if (currentMode == MODE_BACK && bottomHealthy && !bottomClearlyNoisy) {
            return switchAfter(MODE_BOTTOM, samples, SWITCH_TO_BOTTOM_SAMPLES);
        }
        clearPending();
        return currentMode;
    }

    private int switchNow(int mode) {
        clearPending();
        if (currentMode != mode) {
            currentMode = mode;
            switchCount++;
        }
        return currentMode;
    }

    private int switchAfter(int mode, int samples, int requiredSamples) {
        if (pendingMode != mode) {
            pendingMode = mode;
            pendingSamples = 0;
        }
        pendingSamples += Math.max(0, samples);
        if (pendingSamples >= requiredSamples) {
            return switchNow(mode);
        }
        return currentMode;
    }

    private void clearPending() {
        pendingMode = currentMode;
        pendingSamples = 0;
    }

    private short highPass(short sample) {
        float input = sample;
        float output = HIGH_PASS_ALPHA * (hpPrevOutput + input - hpPrevInput);
        hpPrevInput = input;
        hpPrevOutput = output;
        return clampToShort(Math.round(output));
    }

    private void addSelectedStats(short sample) {
        int abs = Math.abs(sample);
        selectedSq += sample * (double) sample;
        selectedPeakMax = Math.max(selectedPeakMax, abs);
        if (abs >= 32700) {
            selectedClipSamples++;
        }
        selectedSamples++;
        addVadSample(sample);
    }

    private void addVadSample(short sample) {
        vadFrameSq += sample * (double) sample;
        vadFrameSamples++;
        if (vadFrameSamples >= VAD_FRAME_SAMPLES) {
            finishVadFrame();
        }
    }

    private void finishVadFrame() {
        if (vadFrameSamples <= 0) {
            return;
        }
        double rms = Math.sqrt(vadFrameSq / vadFrameSamples);
        double frameDbfs = dbfs(rms);
        vadTotalFrames++;
        vadNoiseDbfs = Math.min(vadNoiseDbfs, frameDbfs);
        double activeThreshold = Math.max(-50.0, vadNoiseDbfs + 6.0);
        if (frameDbfs >= activeThreshold) {
            vadActiveFrames++;
            vadActiveDbfs = Math.max(vadActiveDbfs, frameDbfs);
            long frameEndSample = selectedSamples;
            long frameStartSample = Math.max(0L, frameEndSample - vadFrameSamples);
            if (firstActiveSample < 0) {
                firstActiveSample = frameStartSample;
            }
            lastActiveSample = frameEndSample;
        }
        vadFrameSamples = 0;
        vadFrameSq = 0;
    }

    private void queueEndOfStream() throws Exception {
        int inputIndex;
        do {
            inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US);
            drainEncoder(false);
        } while (inputIndex < 0);
        codec.queueInputBuffer(inputIndex, 0, 0, presentationUs(),
                MediaCodec.BUFFER_FLAG_END_OF_STREAM);
    }

    private void drainEncoder(boolean waitForEos) throws Exception {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (true) {
            int outputIndex = codec.dequeueOutputBuffer(info, waitForEos ? CODEC_TIMEOUT_US : 0);
            if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!waitForEos) {
                    return;
                }
                continue;
            }
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (muxerStarted) {
                    throw new IllegalStateException("encoder format changed twice");
                }
                trackIndex = muxer.addTrack(codec.getOutputFormat());
                muxer.start();
                muxerStarted = true;
                continue;
            }
            if (outputIndex < 0) {
                continue;
            }
            ByteBuffer outputBuffer = codec.getOutputBuffer(outputIndex);
            if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                info.size = 0;
            }
            if (outputBuffer != null && info.size > 0) {
                if (!muxerStarted) {
                    throw new IllegalStateException("muxer not started");
                }
                outputBuffer.position(info.offset);
                outputBuffer.limit(info.offset + info.size);
                muxer.writeSampleData(trackIndex, outputBuffer, info);
            }
            boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
            codec.releaseOutputBuffer(outputIndex, false);
            if (eos) {
                return;
            }
            if (!waitForEos) {
                return;
            }
        }
    }

    private long presentationUs() {
        return submittedSamples * 1_000_000L / SAMPLE_RATE;
    }

    private AudioDeviceInfo findBuiltinMic(String address) {
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (manager == null) {
            return null;
        }
        for (AudioDeviceInfo device : manager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_MIC
                    && address.equals(device.getAddress())) {
                return device;
            }
        }
        return null;
    }

    private AudioRecord createRecord(int source) {
        int minBytes = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        int bufferBytes = Math.max(minBytes * 4, BUFFER_SAMPLES * 4);
        return new AudioRecord(source, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferBytes);
    }

    private boolean isRoutedTo(AudioRecord record, String address) {
        AudioDeviceInfo routed = record.getRoutedDevice();
        return routed != null && routed.getType() == AudioDeviceInfo.TYPE_BUILTIN_MIC
                && address.equals(routed.getAddress());
    }

    private String stats() {
        finishVadFrame();
        double bottomRms = pairedSamples == 0 ? 0 : Math.sqrt(bottomSq / pairedSamples);
        double backRms = pairedSamples == 0 ? 0 : Math.sqrt(backSq / pairedSamples);
        double selectedRms = selectedSamples == 0 ? 0 : Math.sqrt(selectedSq / selectedSamples);
        double corr = (bottomSq == 0 || backSq == 0) ? 0
                : cross / Math.sqrt(bottomSq * backSq);
        double activeRatio = vadTotalFrames == 0 ? 0 : vadActiveFrames / (double) vadTotalFrames;
        double noiseDbfs = vadNoiseDbfs == 120.0 ? -120.0 : vadNoiseDbfs;
        double snrDb = vadActiveFrames == 0 ? 0 : vadActiveDbfs - noiseDbfs;
        long firstActiveMs = firstActiveSample < 0 ? -1 : firstActiveSample * 1000L / SAMPLE_RATE;
        long lastActiveMs = lastActiveSample < 0 ? -1 : lastActiveSample * 1000L / SAMPLE_RATE;
        return String.format(Locale.US,
                "%s bottomEffects=%s backEffects=%s "
                        + "samples=%d bottomRms=%.1f bottomDbfs=%.1f bottomPeak=%d bottomClipPct=%.4f "
                        + "backRms=%.1f backDbfs=%.1f backPeak=%d backClipPct=%.4f "
                        + "selectedRms=%.1f selectedDbfs=%.1f selectedPeak=%d selectedClipPct=%.4f "
                        + "selectedNoiseDbfs=%.1f selectedActiveDbfs=%.1f selectedSnrDb=%.1f "
                        + "activeRatio=%.3f firstActiveMs=%d lastActiveMs=%d "
                        + "corr=%.3f readErrors=%d unexpectedStop=%s failure=%s "
                        + "maxConsecutiveReadErrors=%d maxExactZeroMs=%d "
                        + "switches=%d mix=%d bottom=%d back=%d bytes=%d "
                        + "bottomRoute=%s backRoute=%s",
                options.report(), bottomEffectSummary, backEffectSummary,
                pairedSamples,
                bottomRms, dbfs(bottomRms), bottomPeakMax, percent(bottomClipSamples, pairedSamples),
                backRms, dbfs(backRms), backPeakMax, percent(backClipSamples, pairedSamples),
                selectedRms, dbfs(selectedRms), selectedPeakMax, percent(selectedClipSamples, selectedSamples),
                noiseDbfs, vadActiveDbfs, snrDb, activeRatio, firstActiveMs, lastActiveMs,
                corr, readErrors, endedUnexpectedly, failureSummary(),
                maxConsecutiveReadErrors, maxExactZeroRunSamples * 1000L / SAMPLE_RATE,
                switchCount, mixedChosen,
                bottomChosen, backChosen, output == null ? 0 : output.length(),
                bottomRoute, backRoute);
    }

    private String failureSummary() {
        if (failure == null) {
            return "none";
        }
        String message = failure.getMessage();
        if (message == null || message.isEmpty()) {
            return failure.getClass().getSimpleName();
        }
        return (failure.getClass().getSimpleName() + ":" + message).replace(' ', '_');
    }

    private static double dbfs(double value) {
        if (value <= 0) {
            return -120.0;
        }
        return 20.0 * Math.log10(value / 32768.0);
    }

    private static double percent(long count, long total) {
        if (total <= 0) {
            return 0;
        }
        return 100.0 * count / total;
    }

    private static short clampToShort(int value) {
        if (value > Short.MAX_VALUE) {
            return Short.MAX_VALUE;
        }
        if (value < Short.MIN_VALUE) {
            return Short.MIN_VALUE;
        }
        return (short) value;
    }

    private static String deviceName(AudioDeviceInfo device) {
        if (device == null) {
            return "null";
        }
        return "type=" + device.getType() + ":" + device.getAddress() + "#" + device.getId();
    }

    private void release() {
        if (bottomEffects != null) {
            try {
                bottomEffects.release();
            } catch (Exception ignored) {
            }
            bottomEffects = null;
        }
        if (backEffects != null) {
            try {
                backEffects.release();
            } catch (Exception ignored) {
            }
            backEffects = null;
        }
        if (bottomRecord != null) {
            try {
                bottomRecord.stop();
            } catch (Exception ignored) {
            }
            try {
                bottomRecord.release();
            } catch (Exception ignored) {
            }
            bottomRecord = null;
        }
        if (backRecord != null) {
            try {
                backRecord.stop();
            } catch (Exception ignored) {
            }
            try {
                backRecord.release();
            } catch (Exception ignored) {
            }
            backRecord = null;
        }
        if (codec != null) {
            try {
                codec.stop();
            } catch (Exception ignored) {
            }
            try {
                codec.release();
            } catch (Exception ignored) {
            }
            codec = null;
        }
        if (muxer != null) {
            try {
                if (muxerStarted) {
                    muxer.stop();
                }
            } catch (Exception ignored) {
            }
            try {
                muxer.release();
            } catch (Exception ignored) {
            }
            muxer = null;
            muxerStarted = false;
        }
        running = false;
    }

    private void deleteOutput() {
        if (output != null) {
            //noinspection ResultOfMethodCallIgnored
            output.delete();
            output = null;
        }
    }
}
