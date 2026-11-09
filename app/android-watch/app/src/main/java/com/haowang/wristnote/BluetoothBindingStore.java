package com.haowang.wristnote;

import android.bluetooth.BluetoothDevice;
import android.content.Context;
import android.content.SharedPreferences;

final class BluetoothBindingStore {
    private static final String PREFS = "wristnote_bluetooth_binding";
    private static final String KEY_PHONE_TOKEN = "phone_token";
    private static final String KEY_PHONE_ADDRESS = "phone_address";
    private static final String KEY_PHONE_NAME = "phone_name";
    private static final String ALLOWED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.";

    private BluetoothBindingStore() {
    }

    static String phoneToken(Context context) {
        if (context == null) {
            return "";
        }
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PHONE_TOKEN, "");
    }

    static boolean isBound(Context context) {
        return isValidToken(phoneToken(context));
    }

    static boolean savePhoneToken(Context context, String token) {
        String normalized = token == null ? "" : token.trim();
        if (!isValidToken(normalized)
                || !BluetoothAccessPolicy.canAcceptBinding(phoneToken(context), normalized)) {
            return false;
        }
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        return prefs.edit().putString(KEY_PHONE_TOKEN, normalized).commit();
    }

    static void savePhoneDevice(Context context, BluetoothDevice device) {
        if (context == null || device == null) {
            return;
        }
        String address = safeAddress(device);
        String name = safeName(device);
        SharedPreferences.Editor editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit();
        if (!address.isEmpty()) {
            editor.putString(KEY_PHONE_ADDRESS, address);
        }
        if (!name.isEmpty()) {
            editor.putString(KEY_PHONE_NAME, name);
        }
        editor.apply();
    }

    static String phoneAddress(Context context) {
        if (context == null) {
            return "";
        }
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PHONE_ADDRESS, "");
    }

    static String phoneName(Context context) {
        if (context == null) {
            return "";
        }
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PHONE_NAME, "");
    }

    static boolean matchesPhoneDevice(Context context, BluetoothDevice device) {
        if (context == null || device == null) {
            return false;
        }
        String boundAddress = phoneAddress(context);
        String address = safeAddress(device);
        if (!boundAddress.isEmpty() && boundAddress.equalsIgnoreCase(address)) {
            return true;
        }
        String boundName = phoneName(context);
        String name = safeName(device);
        return !boundName.isEmpty() && !name.isEmpty() && boundName.equals(name);
    }

    static boolean isValidToken(String token) {
        if (token == null || token.length() < 6 || token.length() > 64) {
            return false;
        }
        for (int i = 0; i < token.length(); i++) {
            if (ALLOWED.indexOf(token.charAt(i)) < 0) {
                return false;
            }
        }
        return true;
    }

    private static String safeAddress(BluetoothDevice device) {
        try {
            String address = device.getAddress();
            return address == null ? "" : address;
        } catch (SecurityException ignored) {
            return "";
        }
    }

    private static String safeName(BluetoothDevice device) {
        try {
            String name = device.getName();
            return name == null ? "" : name;
        } catch (SecurityException ignored) {
            return "";
        }
    }
}
