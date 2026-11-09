package com.haowang.wristnote;

final class RecordingStoragePolicy {
    private static final long ESTIMATED_AAC_BYTES_PER_SECOND = 5000L;
    private static final long ENCRYPTED_COPY_FACTOR = 2L;
    private static final long HEADROOM_BYTES = 32L * 1024L * 1024L;

    private RecordingStoragePolicy() {
    }

    static long requiredFreeBytes(long maxRecordMs) {
        long seconds = Math.max(1L, (maxRecordMs + 999L) / 1000L);
        long estimatedRecording = seconds * ESTIMATED_AAC_BYTES_PER_SECOND;
        return estimatedRecording * ENCRYPTED_COPY_FACTOR + HEADROOM_BYTES;
    }

    static boolean hasRoomForRecording(long freeBytes, long maxRecordMs) {
        return freeBytes >= requiredFreeBytes(maxRecordMs);
    }
}
