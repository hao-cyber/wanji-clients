package com.haowang.wristnote;

final class BluetoothAccessPolicy {
    private String authenticatedPeer = "";

    static boolean canAcceptBinding(String currentToken, String candidateToken) {
        return currentToken.isEmpty() || currentToken.equals(candidateToken);
    }

    synchronized boolean authenticate(String peer, String expectedToken, String providedToken) {
        if (peer.isEmpty() || expectedToken.isEmpty() || !expectedToken.equals(providedToken)) {
            return false;
        }
        authenticatedPeer = peer;
        return true;
    }

    synchronized boolean canReadAudio(String peer) {
        return !peer.isEmpty() && peer.equals(authenticatedPeer);
    }

    synchronized void disconnect(String peer) {
        if (peer.equals(authenticatedPeer)) {
            clear();
        }
    }

    synchronized void clear() {
        authenticatedPeer = "";
    }
}
