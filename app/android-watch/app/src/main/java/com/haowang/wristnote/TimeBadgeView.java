package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

import java.util.Calendar;

public final class TimeBadgeView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private long timeMs = System.currentTimeMillis();

    public TimeBadgeView(Context context) {
        super(context);
    }

    public void setTime(long value) {
        timeMs = value > 0 ? value : System.currentTimeMillis();
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        int width = getWidth();
        int height = getHeight();
        float size = Math.min(width, height);
        float cx = width / 2f;
        float cy = height / 2f;
        float radius = size * 0.42f;

        Calendar calendar = Calendar.getInstance();
        calendar.setTimeInMillis(timeMs);
        int weekIndex = calendar.get(Calendar.DAY_OF_WEEK) - 1;
        int hour = calendar.get(Calendar.HOUR_OF_DAY);
        boolean day = hour >= 6 && hour < 18;

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(Math.max(1.1f, size * 0.022f));
        paint.setColor(day ? Color.argb(185, 122, 220, 255) : Color.argb(185, 186, 158, 255));
        rect.set(cx - radius, cy - radius, cx + radius, cy + radius);
        canvas.drawOval(rect, paint);

        drawWeekDots(canvas, cx, cy, size, weekIndex, day);

        if (day) {
            drawSun(canvas, cx, cy - size * 0.06f, size * 0.16f);
        } else {
            drawMoon(canvas, cx, cy - size * 0.06f, size * 0.18f);
        }
    }

    private void drawSun(Canvas canvas, float cx, float cy, float radius) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1.3f, radius * 0.15f));
        paint.setColor(Color.rgb(255, 210, 118));
        canvas.drawCircle(cx, cy, radius * 0.70f, paint);
    }

    private void drawMoon(Canvas canvas, float cx, float cy, float radius) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1.4f, radius * 0.16f));
        paint.setColor(Color.rgb(238, 226, 168));
        rect.set(cx - radius * 0.72f, cy - radius * 0.78f, cx + radius * 0.80f, cy + radius * 0.76f);
        canvas.drawArc(rect, 92f, 210f, false, paint);
    }

    private void drawWeekDots(Canvas canvas, float cx, float cy, float size, int active, boolean day) {
        float startX = cx - size * 0.22f;
        float y = cy + size * 0.23f;
        for (int i = 0; i < 7; i++) {
            boolean selected = i == Math.max(0, Math.min(6, active));
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(selected
                    ? (day ? Color.rgb(122, 220, 255) : Color.rgb(202, 178, 255))
                    : Color.argb(58, 210, 218, 226));
            canvas.drawCircle(startX + i * size * 0.073f, y, selected ? size * 0.020f : size * 0.011f, paint);
        }
    }
}
