package com.haowang.wristnote;

final class RecordingCheckpointPolicy {
    static final long SEGMENT_MS = 30L * 60L * 1000L;
    static final long MIN_REMAINING_AFTER_ROTATE_MS = 2_000L;

    private RecordingCheckpointPolicy() {
    }

    static boolean shouldRotate(long elapsedMs, long maxRecordMs) {
        return shouldRotate(elapsedMs, maxRecordMs, SEGMENT_MS);
    }

    static boolean shouldRotate(long elapsedMs, long maxRecordMs, long segmentMs) {
        return shouldRotate(elapsedMs, maxRecordMs, segmentMs, Long.MAX_VALUE);
    }

    static boolean shouldRotate(long elapsedMs, long maxRecordMs, long segmentMs,
                                long totalRemainingMs) {
        return segmentMs > 0L
                && elapsedMs >= segmentMs
                && elapsedMs < maxRecordMs
                && totalRemainingMs > MIN_REMAINING_AFTER_ROTATE_MS;
    }
}
