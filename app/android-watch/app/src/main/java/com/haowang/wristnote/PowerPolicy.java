package com.haowang.wristnote;

final class PowerPolicy {
    static final long IDLE_DIAL_FRAME_MS = 1000L;
    static final long RECORDING_DIAL_FRAME_MS = 500L;
    static final long PLAYBACK_PROGRESS_FRAME_MS = 500L;
    static final long RECORDING_LIMIT_CHECK_MS = 5000L;
    static final long FOREGROUND_SERVICE_HEARTBEAT_MS = 60000L;

    private PowerPolicy() {
    }

    static long dialFrameDelayMs(boolean recording) {
        return recording ? RECORDING_DIAL_FRAME_MS : IDLE_DIAL_FRAME_MS;
    }

    static long playbackProgressFrameMs() {
        return PLAYBACK_PROGRESS_FRAME_MS;
    }

    static long recordingLimitCheckMs() {
        return RECORDING_LIMIT_CHECK_MS;
    }

    static long foregroundServiceHeartbeatMs() {
        return FOREGROUND_SERVICE_HEARTBEAT_MS;
    }
}
