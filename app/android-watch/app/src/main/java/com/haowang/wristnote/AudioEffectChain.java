package com.haowang.wristnote;

import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.AutomaticGainControl;
import android.media.audiofx.NoiseSuppressor;

final class AudioEffectChain {
    private NoiseSuppressor noiseSuppressor;
    private AutomaticGainControl automaticGainControl;
    private AcousticEchoCanceler acousticEchoCanceler;
    private String summary = "ns=off,agc=off,aec=off";

    static AudioEffectChain create(int audioSessionId, VoiceCaptureOptions options) {
        AudioEffectChain chain = new AudioEffectChain();
        String ns = chain.setupNoiseSuppressor(audioSessionId, options.noiseSuppressor());
        String agc = chain.setupAutomaticGainControl(audioSessionId, options.automaticGainControl());
        String aec = chain.setupAcousticEchoCanceler(audioSessionId, options.acousticEchoCanceler());
        chain.summary = "ns=" + ns + ",agc=" + agc + ",aec=" + aec;
        return chain;
    }

    String summary() {
        return summary;
    }

    void release() {
        if (noiseSuppressor != null) {
            noiseSuppressor.release();
            noiseSuppressor = null;
        }
        if (automaticGainControl != null) {
            automaticGainControl.release();
            automaticGainControl = null;
        }
        if (acousticEchoCanceler != null) {
            acousticEchoCanceler.release();
            acousticEchoCanceler = null;
        }
    }

    private String setupNoiseSuppressor(int audioSessionId, boolean requested) {
        if (!requested) {
            return "off";
        }
        if (!NoiseSuppressor.isAvailable()) {
            return "unavailable";
        }
        try {
            noiseSuppressor = NoiseSuppressor.create(audioSessionId);
            return enable(noiseSuppressor);
        } catch (Exception e) {
            return "failed_" + e.getClass().getSimpleName();
        }
    }

    private String setupAutomaticGainControl(int audioSessionId, boolean requested) {
        if (!requested) {
            return "off";
        }
        if (!AutomaticGainControl.isAvailable()) {
            return "unavailable";
        }
        try {
            automaticGainControl = AutomaticGainControl.create(audioSessionId);
            return enable(automaticGainControl);
        } catch (Exception e) {
            return "failed_" + e.getClass().getSimpleName();
        }
    }

    private String setupAcousticEchoCanceler(int audioSessionId, boolean requested) {
        if (!requested) {
            return "off";
        }
        if (!AcousticEchoCanceler.isAvailable()) {
            return "unavailable";
        }
        try {
            acousticEchoCanceler = AcousticEchoCanceler.create(audioSessionId);
            return enable(acousticEchoCanceler);
        } catch (Exception e) {
            return "failed_" + e.getClass().getSimpleName();
        }
    }

    private static String enable(AudioEffect effect) {
        if (effect == null) {
            return "create_null";
        }
        int result = effect.setEnabled(true);
        boolean enabled;
        try {
            enabled = effect.getEnabled();
        } catch (Exception e) {
            return "set_" + result + "_get_failed";
        }
        return enabled ? "on" : "set_" + result + "_off";
    }
}
