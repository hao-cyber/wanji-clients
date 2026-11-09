package com.haowang.wristnote;

import android.content.Context;

final class VoiceUploader {
    UploadResult upload(Context context, byte[] audio, long createdAt, String uploadId) throws Exception {
        if (audio.length == 0) {
            throw new IllegalStateException("empty audio");
        }
        if (!BluetoothPhoneUploader.isBluetoothPhoneEndpoint(BuildConfig.PHONE_BASE)) {
            throw new IllegalStateException("bluetooth phone not configured");
        }
        BluetoothPhoneUploader.upload(context, audio, createdAt, uploadId);
        UploadResult result = new UploadResult();
        result.kind = "phone";
        result.transcript = "";
        return result;
    }

    static final class UploadResult {
        String kind = "";
        String transcript = "";
        long taskId;
        long conversationId;
    }
}
