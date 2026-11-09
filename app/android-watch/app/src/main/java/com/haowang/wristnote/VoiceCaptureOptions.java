package com.haowang.wristnote;

import android.content.Intent;
import android.media.MediaRecorder;

import java.util.Locale;

final class VoiceCaptureOptions {
    private static final int DEFAULT_SOURCE = MediaRecorder.AudioSource.MIC;

    private final int audioSource;
    private final String sourceName;
    private final boolean noiseSuppressor;
    private final boolean automaticGainControl;
    private final boolean acousticEchoCanceler;
    private final String experiment;

    private VoiceCaptureOptions(
            int audioSource,
            String sourceName,
            boolean noiseSuppressor,
            boolean automaticGainControl,
            boolean acousticEchoCanceler,
            String experiment
    ) {
        this.audioSource = audioSource;
        this.sourceName = sourceName;
        this.noiseSuppressor = noiseSuppressor;
        this.automaticGainControl = automaticGainControl;
        this.acousticEchoCanceler = acousticEchoCanceler;
        this.experiment = sanitize(experiment);
    }

    static VoiceCaptureOptions defaults() {
        return new VoiceCaptureOptions(DEFAULT_SOURCE, sourceName(DEFAULT_SOURCE),
                false, false, false, "baseline");
    }

    static VoiceCaptureOptions fromIntent(Intent intent) {
        if (intent == null) {
            return defaults();
        }
        int source = intent.hasExtra("audioSourceId")
                ? intent.getIntExtra("audioSourceId", DEFAULT_SOURCE)
                : parseAudioSource(intent.getStringExtra("audioSource"));
        return new VoiceCaptureOptions(
                source,
                sourceName(source),
                intent.getBooleanExtra("enableNs", false),
                intent.getBooleanExtra("enableAgc", false),
                intent.getBooleanExtra("enableAec", false),
                intent.getStringExtra("voiceExperiment")
        );
    }

    int audioSource() {
        return audioSource;
    }

    boolean noiseSuppressor() {
        return noiseSuppressor;
    }

    boolean automaticGainControl() {
        return automaticGainControl;
    }

    boolean acousticEchoCanceler() {
        return acousticEchoCanceler;
    }

    boolean isDefault() {
        return audioSource == DEFAULT_SOURCE
                && !noiseSuppressor
                && !automaticGainControl
                && !acousticEchoCanceler;
    }

    String report() {
        return "experiment=" + experiment
                + " source=" + sourceName
                + " ns=" + bool(noiseSuppressor)
                + " agc=" + bool(automaticGainControl)
                + " aec=" + bool(acousticEchoCanceler);
    }

    private static int parseAudioSource(String value) {
        if (value == null || value.trim().isEmpty()) {
            return DEFAULT_SOURCE;
        }
        String normalized = value.trim().toUpperCase(Locale.US).replace('-', '_');
        if ("MIC".equals(normalized)) {
            return MediaRecorder.AudioSource.MIC;
        }
        if ("VOICE_RECOGNITION".equals(normalized) || "VOICE_RECOGNITION_SOURCE".equals(normalized)) {
            return MediaRecorder.AudioSource.VOICE_RECOGNITION;
        }
        if ("CAMCORDER".equals(normalized)) {
            return MediaRecorder.AudioSource.CAMCORDER;
        }
        try {
            return Integer.parseInt(normalized);
        } catch (NumberFormatException ignored) {
            return DEFAULT_SOURCE;
        }
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

    private static String sanitize(String value) {
        if (value == null || value.trim().isEmpty()) {
            return "baseline";
        }
        return value.trim().replaceAll("[^A-Za-z0-9_.-]", "_");
    }

    private static String bool(boolean value) {
        return value ? "1" : "0";
    }
}
