package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

public final class RecordingEventLogTest {
    @Test
    public void sanitizeKeepsSingleLineDiagnostics() {
        assertEquals("a b c d", RecordingEventLog.sanitizeForTest("a\nb\rc\td"));
    }

    @Test
    public void sanitizeTruncatesLargeDetails() {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < 700; i++) {
            builder.append('x');
        }

        String sanitized = RecordingEventLog.sanitizeForTest(builder.toString());

        assertEquals(512, sanitized.length());
        assertFalse(sanitized.contains("\n"));
    }
}
