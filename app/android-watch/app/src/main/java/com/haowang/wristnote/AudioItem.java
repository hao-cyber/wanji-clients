package com.haowang.wristnote;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

final class AudioItem {
    static final String PENDING = "pending";
    static final String SYNCING = "syncing";
    static final String SYNCED = "synced";
    static final String FAILED = "failed";

    String id;
    long createdAt;
    long durationMs;
    long sizeBytes;
    String state = PENDING;
    int attempts;
    long syncedAt;
    String lastError = "";
    String syncKind = "";
    long taskId;
    long conversationId;
    String sha256 = "";
    final List<Long> markersMs = new ArrayList<>();

    JSONObject toJson() throws Exception {
        JSONObject o = new JSONObject();
        o.put("id", id);
        o.put("createdAt", createdAt);
        o.put("durationMs", durationMs);
        o.put("sizeBytes", sizeBytes);
        o.put("state", state);
        o.put("attempts", attempts);
        o.put("syncedAt", syncedAt);
        o.put("lastError", lastError);
        o.put("syncKind", syncKind);
        o.put("taskId", taskId);
        o.put("conversationId", conversationId);
        o.put("sha256", sha256);
        JSONArray markers = new JSONArray();
        for (Long marker : markersMs) {
            markers.put(marker);
        }
        o.put("markersMs", markers);
        return o;
    }

    static AudioItem fromJson(JSONObject o) {
        AudioItem item = new AudioItem();
        item.id = o.optString("id", "");
        item.createdAt = o.optLong("createdAt", 0);
        item.durationMs = o.optLong("durationMs", 0);
        item.sizeBytes = o.optLong("sizeBytes", 0);
        item.state = o.optString("state", PENDING);
        item.attempts = o.optInt("attempts", 0);
        item.syncedAt = o.optLong("syncedAt", 0);
        item.lastError = o.optString("lastError", "");
        item.syncKind = o.optString("syncKind", "");
        item.taskId = o.optLong("taskId", 0);
        item.conversationId = o.optLong("conversationId", 0);
        item.sha256 = o.optString("sha256", "");
        JSONArray markers = o.optJSONArray("markersMs");
        if (markers != null) {
            for (int i = 0; i < markers.length(); i++) {
                item.markersMs.add(markers.optLong(i, 0));
            }
        }
        return item;
    }
}
