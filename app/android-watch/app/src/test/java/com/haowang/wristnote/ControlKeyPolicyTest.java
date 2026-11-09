package com.haowang.wristnote;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public final class ControlKeyPolicyTest {
    @Test
    public void dialShortPressUsesIdleTapPolicy() {
        assertEquals(
                ControlKeyPolicy.ShortAction.IDLE_TAP,
                ControlKeyPolicy.shortPress(false, false, false));
    }

    @Test
    public void recordingShortPressAddsMarker() {
        assertEquals(
                ControlKeyPolicy.ShortAction.ADD_MARKER,
                ControlKeyPolicy.shortPress(true, false, false));
    }

    @Test
    public void tripleControlKeyTapOpensLibraryWithoutBlockingRecordingLongPress() {
        assertEquals(ControlKeyPolicy.ShortAction.IDLE_TAP, ControlKeyPolicy.idleTapAction(1));
        assertEquals(ControlKeyPolicy.ShortAction.IDLE_TAP, ControlKeyPolicy.idleTapAction(2));
        assertEquals(ControlKeyPolicy.ShortAction.OPEN_LIBRARY, ControlKeyPolicy.idleTapAction(3));
    }

    @Test
    public void libraryShortPressIsContextualOnlyInsideLibrary() {
        assertEquals(
                ControlKeyPolicy.ShortAction.OPEN_CENTER_ITEM,
                ControlKeyPolicy.shortPress(false, true, false));
        assertEquals(
                ControlKeyPolicy.ShortAction.TOGGLE_PLAYBACK,
                ControlKeyPolicy.shortPress(false, true, true));
    }

    @Test
    public void longPressKeepsRecordingAsPrimaryDialAction() {
        assertEquals(
                ControlKeyPolicy.LongAction.START_RECORDING,
                ControlKeyPolicy.longPress(false, false, false));
        assertEquals(
                ControlKeyPolicy.LongAction.STOP_RECORDING,
                ControlKeyPolicy.longPress(true, false, false));
    }

    @Test
    public void uploadingDoesNotBlockRecordingControl() {
        assertEquals(
                ControlKeyPolicy.LongAction.START_RECORDING,
                ControlKeyPolicy.longPress(false, true, false));
        assertEquals(
                ControlKeyPolicy.LongAction.STOP_RECORDING,
                ControlKeyPolicy.longPress(true, true, false));
    }

    @Test
    public void libraryLongPressStillStartsRecording() {
        assertEquals(
                ControlKeyPolicy.LongAction.START_RECORDING,
                ControlKeyPolicy.longPress(false, false, true));
    }

    @Test
    public void touchFaceNeverControlsRecording() {
        assertEquals(
                ControlKeyPolicy.TouchAction.ABSORB,
                ControlKeyPolicy.touchFaceTap());
        assertEquals(
                ControlKeyPolicy.TouchAction.ABSORB,
                ControlKeyPolicy.touchFaceLongPress());
    }

    @Test
    public void shortcutLaunchTogglesRecordingLikeLongPress() {
        assertEquals(
                ControlKeyPolicy.LongAction.START_RECORDING,
                ControlKeyPolicy.shortcutLaunch(false));
        assertEquals(
                ControlKeyPolicy.LongAction.STOP_RECORDING,
                ControlKeyPolicy.shortcutLaunch(true));
    }

    @Test
    public void appLauncherDoesNotToggleRecording() {
        assertEquals(false, ControlKeyPolicy.shouldToggleFromLaunch(false, false));
        assertEquals(false, ControlKeyPolicy.shouldToggleFromLaunch(false, true));
    }

    @Test
    public void explicitRecordingShortcutTogglesEvenWhenAppAlreadyExists() {
        assertEquals(true, ControlKeyPolicy.shouldToggleFromLaunch(true, false));
    }

    @Test
    public void explicitMainActivityAppEntryDoesNotToggleRecording() {
        assertEquals(false, ControlKeyPolicy.shouldToggleFromLaunch(false, false));
    }

    @Test
    public void suppressedVisualLaunchNeverTogglesRecording() {
        assertEquals(false, ControlKeyPolicy.shouldToggleFromLaunch(false, true));
        assertEquals(false, ControlKeyPolicy.shouldToggleFromLaunch(true, true));
    }
}
