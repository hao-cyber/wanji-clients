package com.haowang.wristnote;

final class ItemActionPolicy {
    private ItemActionPolicy() {
    }

    static boolean canUpload(boolean recording, boolean uploading, String state) {
        return !recording
                && !uploading
                && (AudioItem.PENDING.equals(state) || AudioItem.FAILED.equals(state));
    }

    static boolean canDelete(boolean recording, boolean uploading, String state) {
        return !recording;
    }
}
