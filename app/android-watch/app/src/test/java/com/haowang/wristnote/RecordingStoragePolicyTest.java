package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public final class RecordingStoragePolicyTest {
    @Test
    public void requiresEnoughSpaceForRecordingAndEncryptedCopy() {
        long eightHoursMs = 8L * 60L * 60L * 1000L;
        long required = RecordingStoragePolicy.requiredFreeBytes(eightHoursMs);

        assertTrue(required >= 300L * 1024L * 1024L);
        assertTrue(RecordingStoragePolicy.hasRoomForRecording(required, eightHoursMs));
        assertFalse(RecordingStoragePolicy.hasRoomForRecording(required - 1L, eightHoursMs));
    }

    @Test
    public void oneSecondMinimumStillKeepsHeadroom() {
        long required = RecordingStoragePolicy.requiredFreeBytes(0L);

        assertTrue(required > 32L * 1024L * 1024L);
    }
}
