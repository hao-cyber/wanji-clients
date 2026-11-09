package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public final class RecordingCheckpointPolicyTest {
    @Test
    public void rotatesAtSegmentBoundaryBeforeHardLimit() {
        long maxRecordMs = 8L * 60L * 60L * 1000L;

        assertFalse(RecordingCheckpointPolicy.shouldRotate(
                RecordingCheckpointPolicy.SEGMENT_MS - 1L, maxRecordMs));
        assertTrue(RecordingCheckpointPolicy.shouldRotate(
                RecordingCheckpointPolicy.SEGMENT_MS, maxRecordMs));
    }

    @Test
    public void hardLimitTakesPriorityOverSegmentRotation() {
        long maxRecordMs = RecordingCheckpointPolicy.SEGMENT_MS;

        assertFalse(RecordingCheckpointPolicy.shouldRotate(maxRecordMs, maxRecordMs));
    }

    @Test
    public void debugSegmentCanExerciseRotationWithoutChangingProductionSegment() {
        long maxRecordMs = 60_000L;

        assertFalse(RecordingCheckpointPolicy.shouldRotate(3_999L, maxRecordMs, 4_000L));
        assertTrue(RecordingCheckpointPolicy.shouldRotate(4_000L, maxRecordMs, 4_000L));
        assertFalse(RecordingCheckpointPolicy.shouldRotate(4_000L, maxRecordMs, 0L));
    }

    @Test
    public void doesNotRotateWhenOnlyTinyTailWouldRemain() {
        long maxRecordMs = 60_000L;

        assertFalse(RecordingCheckpointPolicy.shouldRotate(
                4_000L, maxRecordMs, 4_000L,
                RecordingCheckpointPolicy.MIN_REMAINING_AFTER_ROTATE_MS));
        assertTrue(RecordingCheckpointPolicy.shouldRotate(
                4_000L, maxRecordMs, 4_000L,
                RecordingCheckpointPolicy.MIN_REMAINING_AFTER_ROTATE_MS + 1L));
    }
}
