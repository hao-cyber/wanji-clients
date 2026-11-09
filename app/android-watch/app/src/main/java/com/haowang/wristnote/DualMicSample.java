package com.haowang.wristnote;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

final class DualMicSample {
    private static final String TAG = "DualMicSample";
    private static final int SAMPLE_RATE = 16000;
    private static final int BUFFER_SAMPLES = 1024;
    private static final int MAX_DURATION_MS = 30_000;

    private DualMicSample() {
    }

    static void run(Context context, int requestedDurationMs) {
        int durationMs = Math.max(1000, Math.min(MAX_DURATION_MS, requestedDurationMs));
        StringBuilder report = new StringBuilder();
        File dir = new File(context.getFilesDir(), "dual_mic");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File bottomFile = new File(dir, "latest-bottom.wav");
        File backFile = new File(dir, "latest-back.wav");
        File mixFile = new File(dir, "latest-mix.wav");
        File reportFile = new File(dir, "latest-report.txt");
        deleteQuietly(bottomFile);
        deleteQuietly(backFile);
        deleteQuietly(mixFile);
        deleteQuietly(reportFile);

        AudioRecord bottomRecord = null;
        AudioRecord backRecord = null;
        WavSink bottomSink = null;
        WavSink backSink = null;
        WavSink mixSink = null;
        try {
            AudioDeviceInfo bottomDevice = findBuiltinMic(context, "bottom");
            AudioDeviceInfo backDevice = findBuiltinMic(context, "back");
            if (bottomDevice == null || backDevice == null) {
                throw new IllegalStateException("missing bottom/back mic bottom="
                        + deviceName(bottomDevice) + " back=" + deviceName(backDevice));
            }
            line(report, "durationMs=" + durationMs);
            line(report, "bottomDevice=" + deviceName(bottomDevice));
            line(report, "backDevice=" + deviceName(backDevice));

            bottomRecord = createMonoRecord(MediaRecorder.AudioSource.MIC);
            backRecord = createMonoRecord(MediaRecorder.AudioSource.MIC);
            if (bottomRecord.getState() != AudioRecord.STATE_INITIALIZED
                    || backRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                throw new IllegalStateException("AudioRecord init failed bottomState="
                        + bottomRecord.getState() + " backState=" + backRecord.getState());
            }
            boolean bottomAccepted = bottomRecord.setPreferredDevice(bottomDevice);
            boolean backAccepted = backRecord.setPreferredDevice(backDevice);
            line(report, "preferred bottomAccepted=" + bottomAccepted
                    + " backAccepted=" + backAccepted);

            bottomSink = new WavSink(bottomFile);
            backSink = new WavSink(backFile);
            mixSink = new WavSink(mixFile);

            bottomRecord.startRecording();
            backRecord.startRecording();
            long start = System.currentTimeMillis();
            long deadline = start + durationMs;
            short[] bottomBuffer = new short[BUFFER_SAMPLES];
            short[] backBuffer = new short[BUFFER_SAMPLES];
            short[] bottomPaired = new short[BUFFER_SAMPLES];
            short[] backPaired = new short[BUFFER_SAMPLES];
            short[] mixPaired = new short[BUFFER_SAMPLES];

            long samples = 0;
            double bottomSq = 0;
            double backSq = 0;
            double cross = 0;
            double absDiff = 0;
            int readErrors = 0;
            while (System.currentTimeMillis() < deadline) {
                int bottomRead = bottomRecord.read(bottomBuffer, 0, bottomBuffer.length);
                int backRead = backRecord.read(backBuffer, 0, backBuffer.length);
                if (bottomRead <= 0 || backRead <= 0) {
                    readErrors++;
                    continue;
                }
                int paired = Math.min(bottomRead, backRead);
                for (int i = 0; i < paired; i++) {
                    short bottom = bottomBuffer[i];
                    short back = backBuffer[i];
                    bottomPaired[i] = bottom;
                    backPaired[i] = back;
                    mixPaired[i] = clampToShort((bottom + back) / 2);
                    bottomSq += bottom * (double) bottom;
                    backSq += back * (double) back;
                    cross += bottom * (double) back;
                    absDiff += Math.abs(bottom - back);
                }
                bottomSink.write(bottomPaired, paired);
                backSink.write(backPaired, paired);
                mixSink.write(mixPaired, paired);
                samples += paired;
            }

            stopQuietly(bottomRecord);
            stopQuietly(backRecord);
            AudioDeviceInfo bottomRouted = bottomRecord.getRoutedDevice();
            AudioDeviceInfo backRouted = backRecord.getRoutedDevice();
            bottomSink.close();
            backSink.close();
            mixSink.close();
            bottomSink = null;
            backSink = null;
            mixSink = null;

            double bottomRms = samples == 0 ? 0 : Math.sqrt(bottomSq / samples);
            double backRms = samples == 0 ? 0 : Math.sqrt(backSq / samples);
            double corr = (bottomSq == 0 || backSq == 0) ? 0
                    : cross / Math.sqrt(bottomSq * backSq);
            double diff = samples == 0 ? 0 : absDiff / samples;
            line(report, String.format(Locale.US,
                    "result samples=%d elapsedMs=%d bottomRms=%.1f backRms=%.1f corr=%.3f absDiff=%.1f readErrors=%d",
                    samples, System.currentTimeMillis() - start, bottomRms, backRms, corr, diff,
                    readErrors));
            line(report, "bottomRouted=" + deviceName(bottomRouted));
            line(report, "backRouted=" + deviceName(backRouted));
            line(report, "bottomFile=" + bottomFile.getAbsolutePath() + " bytes=" + bottomFile.length());
            line(report, "backFile=" + backFile.getAbsolutePath() + " bytes=" + backFile.length());
            line(report, "mixFile=" + mixFile.getAbsolutePath() + " bytes=" + mixFile.length());
            line(report, "done");
        } catch (Exception e) {
            line(report, "failed " + e.getClass().getSimpleName() + ":" + e.getMessage());
            closeQuietly(bottomSink);
            closeQuietly(backSink);
            closeQuietly(mixSink);
        } finally {
            releaseQuietly(bottomRecord);
            releaseQuietly(backRecord);
            writeReport(reportFile, report);
        }
    }

    private static AudioDeviceInfo findBuiltinMic(Context context, String address) {
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

    private static AudioRecord createMonoRecord(int source) {
        int minBytes = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        int bufferBytes = Math.max(minBytes * 4, BUFFER_SAMPLES * 4);
        return new AudioRecord(source, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, bufferBytes);
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

    private static void stopQuietly(AudioRecord record) {
        if (record == null) {
            return;
        }
        try {
            record.stop();
        } catch (Exception ignored) {
        }
    }

    private static void releaseQuietly(AudioRecord record) {
        if (record == null) {
            return;
        }
        try {
            record.release();
        } catch (Exception ignored) {
        }
    }

    private static void closeQuietly(WavSink sink) {
        if (sink == null) {
            return;
        }
        try {
            sink.close();
        } catch (Exception ignored) {
        }
    }

    private static void deleteQuietly(File file) {
        //noinspection ResultOfMethodCallIgnored
        file.delete();
    }

    private static void writeReport(File file, StringBuilder report) {
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(report.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            Log.w(TAG, "write report failed " + e.getClass().getSimpleName());
        }
    }

    private static void line(StringBuilder report, String message) {
        Log.i(TAG, message);
        report.append(message).append('\n');
    }

    private static final class WavSink {
        private final RandomAccessFile file;
        private int dataBytes;

        WavSink(File path) throws Exception {
            file = new RandomAccessFile(path, "rw");
            file.setLength(0);
            writeHeader(0);
        }

        void write(short[] samples, int length) throws Exception {
            byte[] bytes = new byte[length * 2];
            for (int i = 0; i < length; i++) {
                short sample = samples[i];
                bytes[i * 2] = (byte) (sample & 0xff);
                bytes[i * 2 + 1] = (byte) ((sample >> 8) & 0xff);
            }
            file.write(bytes);
            dataBytes += bytes.length;
        }

        void close() throws Exception {
            writeHeader(dataBytes);
            file.close();
        }

        private void writeHeader(int dataLength) throws Exception {
            file.seek(0);
            writeAscii("RIFF");
            writeIntLE(36 + dataLength);
            writeAscii("WAVE");
            writeAscii("fmt ");
            writeIntLE(16);
            writeShortLE(1);
            writeShortLE(1);
            writeIntLE(SAMPLE_RATE);
            writeIntLE(SAMPLE_RATE * 2);
            writeShortLE(2);
            writeShortLE(16);
            writeAscii("data");
            writeIntLE(dataLength);
            file.seek(44 + dataLength);
        }

        private void writeAscii(String value) throws Exception {
            file.write(value.getBytes(StandardCharsets.US_ASCII));
        }

        private void writeIntLE(int value) throws Exception {
            file.write(value & 0xff);
            file.write((value >> 8) & 0xff);
            file.write((value >> 16) & 0xff);
            file.write((value >> 24) & 0xff);
        }

        private void writeShortLE(int value) throws Exception {
            file.write(value & 0xff);
            file.write((value >> 8) & 0xff);
        }
    }
}
