package com.haowang.wristnote;

import android.content.Context;
import android.os.Handler;
import android.os.VibrationEffect;
import android.os.Vibrator;

final class Haptics {
    private final Context context;
    private final Handler handler;

    Haptics(Context context, Handler handler) {
        this.context = context;
        this.handler = handler;
    }

    void tap() {
        vibrate(45);
    }

    void error() {
        vibrate(160);
    }

    void pattern(int count) {
        for (int i = 0; i < count; i++) {
            handler.postDelayed(() -> vibrate(38), i * 130L);
        }
    }

    private void vibrate(long ms) {
        try {
            Vibrator vibrator = (Vibrator) context.getSystemService(Context.VIBRATOR_SERVICE);
            if (vibrator != null) {
                vibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE));
            }
        } catch (Exception ignored) {
        }
    }
}
