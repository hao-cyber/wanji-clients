package com.haowang.wristnote;

import org.json.JSONObject;
import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public final class AudioItemTest {
    @Test
    public void fromJson_acceptsLegacyIndexWithoutSyncMetadata() throws Exception {
        JSONObject json = new JSONObject();
        json.put("id", "a1");
        json.put("createdAt", 123L);
        json.put("durationMs", 456L);
        json.put("sizeBytes", 789L);
        json.put("state", AudioItem.SYNCED);
        json.put("attempts", 2);
        json.put("syncedAt", 321L);
        json.put("lastError", "");

        AudioItem item = AudioItem.fromJson(json);

        assertEquals("a1", item.id);
        assertEquals(AudioItem.SYNCED, item.state);
        assertEquals("", item.syncKind);
        assertEquals(0L, item.taskId);
        assertEquals(0L, item.conversationId);
        assertTrue(item.markersMs.isEmpty());
    }

    @Test
    public void toJson_roundTripsTaskSyncMetadata() throws Exception {
        AudioItem item = new AudioItem();
        item.id = "a2";
        item.createdAt = 10L;
        item.durationMs = 20L;
        item.sizeBytes = 30L;
        item.state = AudioItem.SYNCED;
        item.syncKind = "task";
        item.taskId = 41L;
        item.conversationId = 42L;
        item.markersMs.add(100L);

        JSONObject json = item.toJson();
        assertTrue(!json.has("transcript"));
        AudioItem restored = AudioItem.fromJson(item.toJson());

        assertEquals("task", restored.syncKind);
        assertEquals(41L, restored.taskId);
        assertEquals(42L, restored.conversationId);
        assertEquals(1, restored.markersMs.size());
        assertEquals(Long.valueOf(100L), restored.markersMs.get(0));
    }
}
