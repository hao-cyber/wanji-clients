package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

public final class StateMarkView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private String state = AudioItem.PENDING;
    private boolean playing;

    public StateMarkView(Context context) {
        super(context);
    }

    public void setItemState(String value, boolean isPlaying) {
        state = value == null ? AudioItem.PENDING : value;
        playing = isPlaying;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float cx = getWidth() / 2f;
        float cy = getHeight() / 2f;
        if (playing) {
            drawRing(canvas, cx, cy, Color.rgb(122, 220, 255));
        } else if (AudioItem.FAILED.equals(state)) {
            drawPill(canvas, cx, cy, Color.rgb(255, 91, 84));
        } else if (AudioItem.SYNCED.equals(state)) {
            drawRing(canvas, cx, cy, Color.rgb(190, 156, 92));
        } else if (AudioItem.SYNCING.equals(state)) {
            drawRing(canvas, cx, cy, Color.rgb(255, 190, 90));
        } else {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.rgb(118, 126, 135));
            canvas.drawCircle(cx, cy, 3.8f, paint);
        }
    }

    private void drawRing(Canvas canvas, float cx, float cy, int color) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.2f);
        paint.setColor(color);
        canvas.drawCircle(cx, cy, 6.2f, paint);
    }

    private void drawPill(Canvas canvas, float cx, float cy, int color) {
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(color);
        rect.set(cx - 2.2f, cy - 9f, cx + 2.2f, cy + 9f);
        canvas.drawRoundRect(rect, 2.2f, 2.2f, paint);
    }
}
