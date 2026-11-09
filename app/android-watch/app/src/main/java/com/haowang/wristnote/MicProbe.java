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
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

final class MicProbe {
    private static final String TAG = "MicProbe";
    private static final int SAMPLE_RATE = 16000;
    private static final int TEST_MS = 900;

    private MicProbe() {
    }

    static void run(Context context) {
        StringBuilder report = new StringBuilder();
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (manager == null) {
            line(report, "audio manager unavailable");
            writeReport(context, report);
            return;
        }

        AudioDeviceInfo[] devices = manager.getDevices(AudioManager.GET_DEVICES_INPUTS);
        line(report, "input device count=" + devices.length);
        List<AudioDeviceInfo> builtIns = new ArrayList<>();
        for (AudioDeviceInfo device : devices) {
            line(report, "device id=" + device.getId()
                    + " type=" + typeName(device.getType())
                    + " product=" + device.getProductName()
                    + " address=" + device.getAddress()
                    + " channels=" + Arrays.toString(device.getChannelCounts())
                    + " channelMasks=" + Arrays.toString(device.getChannelMasks())
                    + " channelIndexMasks=" + Arrays.toString(device.getChannelIndexMasks())
                    + " sampleRates=" + Arrays.toString(device.getSampleRates()));
            if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_MIC) {
                builtIns.add(device);
            }
        }

        int[] sources = new int[]{
                MediaRecorder.AudioSource.MIC,
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                MediaRecorder.AudioSource.CAMCORDER
        };
        for (int source : sources) {
            probe(report, source, sourceName(source) + ":default", null, 1);
            probe(report, source, sourceName(source) + ":default", null, 2);
            for (AudioDeviceInfo device : builtIns) {
                String label = sourceName(source) + ":" + typeName(device.getType()) + ":"
                        + device.getAddress() + "#" + device.getId();
                probe(report, source, label, device, 1);
                probe(report, source, label, device, 2);
            }
            probeConcurrent(report, source, builtIns);
        }
        line(report, "probe done");
        writeReport(context, report);
    }

    private static void probeConcurrent(StringBuilder report, int source, List<AudioDeviceInfo> devices) {
        AudioDeviceInfo bottom = null;
        AudioDeviceInfo back = null;
        for (AudioDeviceInfo device : devices) {
            if ("bottom".equals(device.getAddress())) {
                bottom = device;
            } else if ("back".equals(device.getAddress())) {
                back = device;
            }
        }
        if (bottom == null || back == null) {
            line(report, "concurrent skip source=" + sourceName(source)
                    + " bottom=" + deviceName(bottom) + " back=" + deviceName(back));
            return;
        }
        line(report, "concurrent start source=" + sourceName(source));
        AudioRecord bottomRecord = null;
        AudioRecord backRecord = null;
        try {
            bottomRecord = createRecord(source, 1);
            backRecord = createRecord(source, 1);
            boolean bottomAccepted = bottomRecord.setPreferredDevice(bottom);
            boolean backAccepted = backRecord.setPreferredDevice(back);
            bottomRecord.startRecording();
            backRecord.startRecording();
            short[] bottomBuffer = new short[1024];
            short[] backBuffer = new short[1024];
            long deadline = System.currentTimeMillis() + TEST_MS;
            double bottomSq = 0;
            double backSq = 0;
            double cross = 0;
            double absDiff = 0;
            long bottomSamples = 0;
            long backSamples = 0;
            long pairedSamples = 0;
            while (System.currentTimeMillis() < deadline) {
                int bottomRead = bottomRecord.read(bottomBuffer, 0, bottomBuffer.length);
                int backRead = backRecord.read(backBuffer, 0, backBuffer.length);
                if (bottomRead > 0) {
                    bottomSamples += bottomRead;
                    for (int i = 0; i < bottomRead; i++) {
                        bottomSq += bottomBuffer[i] * (double) bottomBuffer[i];
                    }
                }
                if (backRead > 0) {
                    backSamples += backRead;
                    for (int i = 0; i < backRead; i++) {
                        backSq += backBuffer[i] * (double) backBuffer[i];
                    }
                }
                int paired = Math.min(Math.max(0, bottomRead), Math.max(0, backRead));
                for (int i = 0; i < paired; i++) {
                    double bottomValue = bottomBuffer[i];
                    double backValue = backBuffer[i];
                    cross += bottomValue * backValue;
                    absDiff += Math.abs(bottomValue - backValue);
                    pairedSamples++;
                }
            }
            stopQuietly(bottomRecord);
            stopQuietly(backRecord);
            double bottomRms = bottomSamples == 0 ? 0 : Math.sqrt(bottomSq / bottomSamples);
            double backRms = backSamples == 0 ? 0 : Math.sqrt(backSq / backSamples);
            double corr = (bottomSq == 0 || backSq == 0) ? 0
                    : cross / Math.sqrt(bottomSq * backSq);
            double diff = pairedSamples == 0 ? 0 : absDiff / pairedSamples;
            line(report, String.format(Locale.US,
                    "concurrent result source=%s bottomAccepted=%s backAccepted=%s bottomRouted=%s backRouted=%s bottomSamples=%d backSamples=%d bottomRms=%.1f backRms=%.1f corr=%.3f absDiff=%.1f",
                    sourceName(source), bottomAccepted, backAccepted,
                    deviceName(bottomRecord.getRoutedDevice()), deviceName(backRecord.getRoutedDevice()),
                    bottomSamples, backSamples, bottomRms, backRms, corr, diff));
        } catch (Exception e) {
            line(report, "concurrent failed source=" + sourceName(source)
                    + " error=" + e.getClass().getSimpleName() + ":" + e.getMessage());
        } finally {
            releaseQuietly(bottomRecord);
            releaseQuietly(backRecord);
        }
    }

    private static void probe(StringBuilder report, int source, String label,
                              AudioDeviceInfo preferred, int channels) {
        line(report, "probe start label=" + label + " channels=" + channels);
        int channelConfig = channels == 2
                ? AudioFormat.CHANNEL_IN_STEREO
                : AudioFormat.CHANNEL_IN_MONO;
        int minBytes = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, channelConfig, AudioFormat.ENCODING_PCM_16BIT);
        if (minBytes <= 0) {
            line(report, "probe unsupported label=" + label + " channels=" + channels
                    + " minBytes=" + minBytes);
            return;
        }
        int bufferBytes = Math.max(minBytes * 2, SAMPLE_RATE * channels);
        AudioRecord record = null;
        try {
            record = new AudioRecord(source, SAMPLE_RATE, channelConfig,
                    AudioFormat.ENCODING_PCM_16BIT, bufferBytes);
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                line(report, "probe init failed label=" + label + " channels=" + channels
                        + " state=" + record.getState());
                return;
            }
            boolean preferredAccepted = preferred == null || record.setPreferredDevice(preferred);
            record.startRecording();
            AudioDeviceInfo routed = record.getRoutedDevice();

            short[] buffer = new short[Math.max(512, bufferBytes / 2)];
            long deadline = System.currentTimeMillis() + TEST_MS;
            long samples = 0;
            long frames = 0;
            double sumSq = 0;
            double leftSq = 0;
            double rightSq = 0;
            double cross = 0;
            double absDiff = 0;
            double leftAbs = 0;
            double rightAbs = 0;
            while (System.currentTimeMillis() < deadline) {
                int read = record.read(buffer, 0, buffer.length);
                if (read <= 0) {
                    continue;
                }
                samples += read;
                for (int i = 0; i < read; i++) {
                    double v = buffer[i];
                    sumSq += v * v;
                }
                if (channels == 2) {
                    for (int i = 0; i + 1 < read; i += 2) {
                        double left = buffer[i];
                        double right = buffer[i + 1];
                        frames++;
                        leftSq += left * left;
                        rightSq += right * right;
                        cross += left * right;
                        absDiff += Math.abs(left - right);
                        leftAbs += Math.abs(left);
                        rightAbs += Math.abs(right);
                    }
                }
            }
            record.stop();
            AudioDeviceInfo finalRouted = record.getRoutedDevice();
            double rms = samples == 0 ? 0 : Math.sqrt(sumSq / samples);
            String stereo = "";
            if (channels == 2 && frames > 0) {
                double leftRms = Math.sqrt(leftSq / frames);
                double rightRms = Math.sqrt(rightSq / frames);
                double corr = (leftSq == 0 || rightSq == 0) ? 0
                        : cross / Math.sqrt(leftSq * rightSq);
                double diff = absDiff / frames;
                stereo = String.format(Locale.US,
                        " leftRms=%.1f rightRms=%.1f corr=%.3f absDiff=%.1f leftAbs=%.1f rightAbs=%.1f",
                        leftRms, rightRms, corr, diff, leftAbs / frames, rightAbs / frames);
            }
            line(report, String.format(Locale.US,
                    "probe result label=%s channels=%d preferredAccepted=%s routed=%s finalRouted=%s samples=%d rms=%.1f%s",
                    label, channels, preferredAccepted, deviceName(routed), deviceName(finalRouted),
                    samples, rms, stereo));
        } catch (Exception e) {
            line(report, "probe failed label=" + label + " channels=" + channels
                    + " error=" + e.getClass().getSimpleName() + ":" + e.getMessage());
        } finally {
            if (record != null) {
                releaseQuietly(record);
            }
        }
    }

    private static AudioRecord createRecord(int source, int channels) {
        int channelConfig = channels == 2
                ? AudioFormat.CHANNEL_IN_STEREO
                : AudioFormat.CHANNEL_IN_MONO;
        int minBytes = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, channelConfig, AudioFormat.ENCODING_PCM_16BIT);
        int bufferBytes = Math.max(minBytes * 2, SAMPLE_RATE * channels);
        return new AudioRecord(source, SAMPLE_RATE, channelConfig,
                AudioFormat.ENCODING_PCM_16BIT, bufferBytes);
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

    private static String deviceName(AudioDeviceInfo device) {
        if (device == null) {
            return "null";
        }
        return typeName(device.getType()) + ":" + device.getAddress() + "#" + device.getId();
    }

    private static String typeName(int type) {
        if (type == AudioDeviceInfo.TYPE_BUILTIN_MIC) {
            return "BUILTIN_MIC";
        }
        if (type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
            return "BT_SCO";
        }
        if (type == AudioDeviceInfo.TYPE_TELEPHONY) {
            return "TELEPHONY";
        }
        if (type == AudioDeviceInfo.TYPE_FM_TUNER) {
            return "FM_TUNER";
        }
        return "TYPE_" + type;
    }

    private static String sourceName(int source) {
        if (source == MediaRecorder.AudioSource.MIC) {
            return "MIC";
        }
        if (source == MediaRecorder.AudioSource.VOICE_RECOGNITION) {
            return "VOICE_RECOGNITION";
        }
        if (source == MediaRecorder.AudioSource.CAMCORDER) {
            return "CAMCORDER";
        }
        return "SRC_" + source;
    }

    private static void line(StringBuilder report, String message) {
        Log.i(TAG, message);
        report.append(message).append('\n');
    }

    private static void writeReport(Context context, StringBuilder report) {
        File file = new File(context.getFilesDir(), "mic_probe.txt");
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(report.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            Log.w(TAG, "write report failed " + e.getClass().getSimpleName());
        }
    }
}
