package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

public final class ActiveRecordingJournalTest {
    @Test
    public void sanitizeKeepsJournalSingleLine() {
        assertEquals("a b c", ActiveRecordingJournal.sanitizeForTest("a\nb\tc"));
    }

    @Test
    public void describeMissingStateIsExplicit() {
        assertEquals("none\n", ActiveRecordingJournal.describe(null));
    }

    @Test
    public void heartbeatIntervalIsConservative() {
        assertFalse(ActiveRecordingJournal.MIN_HEARTBEAT_MS < 60_000L);
    }
}
