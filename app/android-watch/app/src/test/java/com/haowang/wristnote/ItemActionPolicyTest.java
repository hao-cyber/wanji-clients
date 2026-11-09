package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public final class ItemActionPolicyTest {
    @Test
    public void deleteIsUserControlledDuringBackgroundUpload() {
        assertTrue(ItemActionPolicy.canDelete(false, true, AudioItem.PENDING));
        assertTrue(ItemActionPolicy.canDelete(false, true, AudioItem.SYNCING));
        assertTrue(ItemActionPolicy.canDelete(false, false, AudioItem.SYNCED));
    }

    @Test
    public void deleteIsBlockedOnlyWhileRecording() {
        assertFalse(ItemActionPolicy.canDelete(true, false, AudioItem.PENDING));
        assertFalse(ItemActionPolicy.canDelete(true, true, AudioItem.SYNCING));
    }

    @Test
    public void uploadRemainsSerializedAndRetryOnly() {
        assertTrue(ItemActionPolicy.canUpload(false, false, AudioItem.PENDING));
        assertTrue(ItemActionPolicy.canUpload(false, false, AudioItem.FAILED));
        assertFalse(ItemActionPolicy.canUpload(false, true, AudioItem.PENDING));
        assertFalse(ItemActionPolicy.canUpload(false, false, AudioItem.SYNCING));
        assertFalse(ItemActionPolicy.canUpload(false, false, AudioItem.SYNCED));
        assertFalse(ItemActionPolicy.canUpload(true, false, AudioItem.PENDING));
    }
}
