package com.haowang.wristnote;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.FileOutputStream;
import java.util.List;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public final class WatchRecorderTest {
    @Rule
    public final TemporaryFolder temp = new TemporaryFolder();

    @Test
    public void cleanupStaleTempsReportsDeletedRecorderTempsOnly() throws Exception {
        File mono = write("wristnote-1.m4a", 3);
        File dual = write("wristnote-dual-2.m4a", 5);
        File other = write("preview-a1.m4a", 7);

        WatchRecorder.CleanupReport report = WatchRecorder.cleanupStaleTemps(temp.getRoot());

        assertTrue(report.hasStaleTemps());
        assertEquals(2, report.files);
        assertEquals(2, report.deleted);
        assertEquals(0, report.failed);
        assertEquals(8L, report.bytes);
        assertFalse(mono.exists());
        assertFalse(dual.exists());
        assertTrue(other.exists());
    }

    @Test
    public void cleanupStaleTempsReturnsEmptyReportWhenNoTempsExist() {
        WatchRecorder.CleanupReport report = WatchRecorder.cleanupStaleTemps(temp.getRoot());

        assertFalse(report.hasStaleTemps());
        assertEquals("files=0 deleted=0 recovered=0 failed=0 bytes=0", report.detail());
    }

    @Test
    public void staleTempFilesIncludesMonoAndDualRecorderTempsOnly() throws Exception {
        File mono = write("wristnote-1700000000000-a.m4a", 3);
        File dual = write("wristnote-dual-1700000001000-b.m4a", 5);
        write("preview-a1.m4a", 7);

        List<File> stale = WatchRecorder.staleTempFiles(temp.getRoot());

        assertEquals(2, stale.size());
        assertTrue(stale.contains(mono));
        assertTrue(stale.contains(dual));
    }

    @Test
    public void estimateTempDurationUsesTimestampFromRecorderTempName() throws Exception {
        File mono = write("wristnote-1700000000000-a.m4a", 3);
        assertTrue(mono.setLastModified(1700000002000L));
        assertEquals(2500L, WatchRecorder.estimateTempDurationMs(mono, 1700000002500L));
    }

    @Test
    public void dualMicHealthDoesNotAbortForShortReadErrorBurst() {
        assertFalse(DualMicAacRecorder.shouldAbortCapture(2_000L, 0L, 49, 0L));
        assertFalse(DualMicAacRecorder.shouldAbortCapture(2_499L, 0L, 50, 0L));
    }

    @Test
    public void dualMicHealthAbortsSustainedReadStall() {
        assertTrue(DualMicAacRecorder.shouldAbortCapture(2_500L, 0L, 50, 0L));
    }

    @Test
    public void dualMicHealthAbortsExactZeroFlatline() {
        assertFalse(DualMicAacRecorder.shouldAbortCapture(1_000L, 900L, 0, 31_999L));
        assertTrue(DualMicAacRecorder.shouldAbortCapture(1_000L, 900L, 0, 32_000L));
    }

    private File write(String name, int bytes) throws Exception {
        File file = new File(temp.getRoot(), name);
        try (FileOutputStream out = new FileOutputStream(file)) {
            for (int i = 0; i < bytes; i++) {
                out.write(i);
            }
        }
        return file;
    }
}
