package com.haowang.wristnote;

import org.junit.Test;
import static org.junit.Assert.*;

public class BluetoothAccessPolicyTest {
    @Test public void unauthenticatedPeerCannotReadPrewarmedAudio() {
        BluetoothAccessPolicy policy = new BluetoothAccessPolicy();
        assertFalse(policy.canReadAudio("phone-a"));
        assertFalse(policy.authenticate("phone-a", "bound-token", "wrong-token"));
        assertFalse(policy.canReadAudio("phone-a"));
    }

    @Test public void authorizationIsBoundToTheAuthenticatedConnection() {
        BluetoothAccessPolicy policy = new BluetoothAccessPolicy();
        assertTrue(policy.authenticate("phone-a", "bound-token", "bound-token"));
        assertTrue(policy.canReadAudio("phone-a"));
        assertFalse(policy.canReadAudio("phone-b"));
        assertFalse(policy.canReadAudio(""));
    }

    @Test public void disconnectRequiresFreshAuthentication() {
        BluetoothAccessPolicy policy = new BluetoothAccessPolicy();
        policy.authenticate("phone-a", "bound-token", "bound-token");
        policy.disconnect("phone-a");
        assertFalse(policy.canReadAudio("phone-a"));
    }

    @Test public void stoppingTheServerRevokesAccess() {
        BluetoothAccessPolicy policy = new BluetoothAccessPolicy();
        policy.authenticate("phone-a", "bound-token", "bound-token");
        policy.clear();
        assertFalse(policy.canReadAudio("phone-a"));
    }

    @Test public void unboundWatchCannotAuthorizeAudio() {
        BluetoothAccessPolicy policy = new BluetoothAccessPolicy();
        assertFalse(policy.authenticate("phone-a", "", ""));
        assertFalse(policy.authenticate("", "bound-token", "bound-token"));
    }

    @Test public void remoteBindingCannotReplaceAnExistingCredential() {
        assertTrue(BluetoothAccessPolicy.canAcceptBinding("", "first-token"));
        assertTrue(BluetoothAccessPolicy.canAcceptBinding("bound-token", "bound-token"));
        assertFalse(BluetoothAccessPolicy.canAcceptBinding("bound-token", "attacker-token"));
    }
}
