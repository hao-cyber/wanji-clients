package com.haowang.wristnote;

final class ControlKeyPolicy {
    enum ShortAction {
        IDLE_TAP,
        OPEN_LIBRARY,
        ADD_MARKER,
        OPEN_CENTER_ITEM,
        TOGGLE_PLAYBACK
    }

    enum LongAction {
        IGNORE,
        START_RECORDING,
        STOP_RECORDING
    }

    enum TouchAction {
        ABSORB
    }

    private ControlKeyPolicy() {
    }

    static ShortAction shortPress(boolean recording, boolean libraryOpen, boolean itemSelected) {
        if (recording) {
            return ShortAction.ADD_MARKER;
        }
        if (!libraryOpen) {
            return ShortAction.IDLE_TAP;
        }
        return itemSelected ? ShortAction.TOGGLE_PLAYBACK : ShortAction.OPEN_CENTER_ITEM;
    }

    static ShortAction idleTapAction(int tapCount) {
        return tapCount >= 3 ? ShortAction.OPEN_LIBRARY : ShortAction.IDLE_TAP;
    }

    static LongAction longPress(boolean recording, boolean uploading, boolean libraryOpen) {
        if (recording) {
            return LongAction.STOP_RECORDING;
        }
        return LongAction.START_RECORDING;
    }

    static LongAction shortcutLaunch(boolean recording) {
        if (recording) {
            return LongAction.STOP_RECORDING;
        }
        return LongAction.START_RECORDING;
    }

    static TouchAction touchFaceTap() {
        return TouchAction.ABSORB;
    }

    static TouchAction touchFaceLongPress() {
        return TouchAction.ABSORB;
    }

    static boolean shouldToggleFromLaunch(boolean explicitRecordingShortcut,
            boolean suppressedLaunch) {
        return explicitRecordingShortcut && !suppressedLaunch;
    }
}
