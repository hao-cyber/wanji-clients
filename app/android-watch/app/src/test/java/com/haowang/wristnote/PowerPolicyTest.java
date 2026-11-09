package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public final class PowerPolicyTest {
    @Test
    public void dialAnimationUsesLowRefreshRates() {
        assertEquals(1000L, PowerPolicy.dialFrameDelayMs(false));
        assertEquals(500L, PowerPolicy.dialFrameDelayMs(true));
    }

    @Test
    public void playbackProgressUsesLowRefreshRate() {
        assertEquals(500L, PowerPolicy.playbackProgressFrameMs());
    }

    @Test
    public void recordingLimitCheckUsesCoarseInterval() {
        assertEquals(5000L, PowerPolicy.recordingLimitCheckMs());
    }
}
