package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.SweepGradient;
import android.view.View;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;

final class RecordDialView extends View {
    private static final int INK = 0xff030303;
    private static final int BLACK_LACQUER = 0xff080807;
    private static final int GOLD = 0xffd8bd83;
    private static final int DARK_GOLD = 0xff4f3c20;
    private static final int STEEL = 0xffeef0ef;
    private static final int SHADOW = 0xff000000;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF arc = new RectF();
    private final RectF assetDst = new RectF();
    private final Path roundClip = new Path();
    private final List<Long> markerMs = new ArrayList<>();
    private final Bitmap dialBase;
    private boolean active = true;
    private boolean recording;
    private long startedAt;

    RecordDialView(Context context) {
        super(context);
        dialBase = BitmapFactory.decodeResource(getResources(), R.drawable.watch_dial_luxury_base);
    }

    void setRecording(boolean recording, long startedAt, List<Long> markers) {
        this.recording = recording;
        this.startedAt = startedAt;
        markerMs.clear();
        markerMs.addAll(markers);
        invalidate();
    }

    void setActive(boolean active) {
        if (this.active == active) {
            return;
        }
        this.active = active;
        if (active) {
            invalidate();
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float w = getWidth();
        float h = getHeight();
        float cx = w / 2f;
        float cy = h / 2f;
        float radius = Math.min(w, h) * 0.5f + 12f;
        long elapsedMs = recording ? Math.max(0, System.currentTimeMillis() - startedAt) : 0;

        drawFace(canvas, cx, cy, radius);
        if (recording) {
            drawRecordingOverlay(canvas, cx, cy, radius, elapsedMs);
        }
        drawCenter(canvas, cx, cy, recording);
        if (active && isShown()) {
            postInvalidateDelayed(PowerPolicy.dialFrameDelayMs(recording));
        }
    }

    private void drawFace(Canvas canvas, float cx, float cy, float radius) {
        canvas.drawColor(INK);
        Calendar now = Calendar.getInstance();
        float second = now.get(Calendar.SECOND) + now.get(Calendar.MILLISECOND) / 1000f;
        float minute = now.get(Calendar.MINUTE) + second / 60f;
        float hour = now.get(Calendar.HOUR) + minute / 60f;

        if (!drawDialAsset(canvas, cx, cy, radius)) {
            drawLacquerBase(canvas, cx, cy, radius);
            drawGuilloche(canvas, cx, cy, radius);
            drawMetalBezels(canvas, cx, cy, radius);
            drawMinuteTicks(canvas, cx, cy, radius);
        }
        drawLuxuryHands(canvas, cx, cy, hour * 30f - 90f, minute * 6f - 90f, second * 6f - 90f, radius);
    }

    private boolean drawDialAsset(Canvas canvas, float cx, float cy, float radius) {
        if (dialBase == null || dialBase.isRecycled()) {
            return false;
        }
        canvas.drawColor(INK);
        int save = canvas.save();
        roundClip.reset();
        roundClip.addCircle(cx, cy, radius, Path.Direction.CW);
        canvas.clipPath(roundClip);
        assetDst.set(cx - radius, cy - radius, cx + radius, cy + radius);
        paint.setFilterBitmap(true);
        paint.setDither(true);
        paint.setAlpha(255);
        canvas.drawBitmap(dialBase, null, assetDst, paint);
        paint.setShader(null);
        canvas.restoreToCount(save);
        return true;
    }

    private void drawLacquerBase(Canvas canvas, float cx, float cy, float radius) {
        canvas.drawColor(INK);
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new RadialGradient(
                cx - radius * 0.20f, cy - radius * 0.32f, radius * 1.08f,
                new int[]{
                        0xff20201d,
                        BLACK_LACQUER,
                        0xff020202
                },
                new float[]{0f, 0.56f, 1f},
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, radius, paint);
        paint.setShader(null);

        paint.setShader(new LinearGradient(
                cx - radius * 0.75f, cy - radius,
                cx + radius * 0.52f, cy + radius * 0.86f,
                Color.argb(46, 255, 248, 232),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, radius * 0.91f, paint);
        paint.setShader(null);
    }

    private void drawGuilloche(Canvas canvas, float cx, float cy, float radius) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        float inner = radius * 0.58f;
        for (int i = 0; i < 72; i++) {
            double a = Math.toRadians(i * 5f);
            double b = Math.toRadians(i * 5f + 114f);
            float r1 = inner * (0.34f + 0.18f * pseudo01(i, 3));
            float r2 = inner * (0.88f + 0.08f * pseudo01(i, 7));
            paint.setStrokeWidth(0.42f);
            paint.setColor(Color.argb(i % 2 == 0 ? 34 : 18, 218, 204, 172));
            canvas.drawLine(
                    cx + (float) Math.cos(a) * r1,
                    cy + (float) Math.sin(a) * r1,
                    cx + (float) Math.cos(b) * r2,
                    cy + (float) Math.sin(b) * r2,
                    paint);
        }
        paint.setStrokeWidth(0.7f);
        paint.setColor(Color.argb(42, 224, 212, 184));
        canvas.drawCircle(cx, cy, radius * 0.59f, paint);
        paint.setColor(Color.argb(20, 255, 250, 232));
        canvas.drawCircle(cx, cy, radius * 0.43f, paint);
    }

    private void drawMetalBezels(Canvas canvas, float cx, float cy, float radius) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setShader(new SweepGradient(cx, cy,
                new int[]{
                        0xff1d1d1b,
                        0xfff7efd9,
                        0xff5f5137,
                        0xffffffff,
                        0xff27231b,
                        0xffd5bd86,
                        0xff1d1d1b
                },
                new float[]{0f, 0.12f, 0.28f, 0.46f, 0.65f, 0.82f, 1f}));
        paint.setStrokeWidth(3.0f);
        canvas.drawCircle(cx, cy, radius - 3.5f, paint);
        paint.setShader(null);

        paint.setStrokeWidth(0.9f);
        paint.setColor(Color.argb(138, 255, 250, 232));
        canvas.drawCircle(cx, cy, radius - 8f, paint);
        paint.setColor(Color.argb(96, 0, 0, 0));
        canvas.drawCircle(cx, cy, radius - 12f, paint);
        paint.setStrokeWidth(0.8f);
        paint.setColor(Color.argb(76, 211, 184, 124));
        canvas.drawCircle(cx, cy, radius * 0.68f, paint);
    }

    private void drawMinuteTicks(Canvas canvas, float cx, float cy, float radius) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.BUTT);
        for (int i = 0; i < 60; i++) {
            double a = Math.toRadians(i * 6f - 90f);
            boolean quarter = i % 15 == 0;
            boolean major = i % 5 == 0;
            float outer = radius - 17f;
            float inner = radius - (quarter ? 45f : major ? 34f : 24f);
            paint.setStrokeWidth(quarter ? 4.0f : major ? 2.4f : 0.85f);
            paint.setColor(quarter ? Color.argb(232, 255, 246, 222)
                    : major ? Color.argb(205, 222, 193, 132)
                    : Color.argb(106, 209, 197, 166));
            canvas.drawLine(
                    cx + (float) Math.cos(a) * inner,
                    cy + (float) Math.sin(a) * inner,
                    cx + (float) Math.cos(a) * outer,
                    cy + (float) Math.sin(a) * outer,
                    paint);
            if (major) {
                paint.setStrokeWidth(0.7f);
                paint.setColor(Color.argb(118, 255, 255, 250));
                canvas.drawLine(
                        cx + (float) Math.cos(a) * (inner + 2f),
                        cy + (float) Math.sin(a) * (inner + 2f),
                        cx + (float) Math.cos(a) * (outer - 2f),
                        cy + (float) Math.sin(a) * (outer - 2f),
                        paint);
            }
        }
    }

    private void drawRecordingOverlay(Canvas canvas, float cx, float cy, float radius, long elapsedMs) {
        float seconds = (elapsedMs % 60000L) / 1000f;
        int laps = (int) (elapsedMs / 60000L);
        float track = radius * 0.78f;
        float sweep = seconds * 6f;

        arc.set(cx - track, cy - track, cx + track, cy + track);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(1.6f);
        paint.setColor(Color.argb(192, 214, 183, 116));
        canvas.drawArc(arc, -90f, sweep, false, paint);

        double a = Math.toRadians(sweep - 90f);
        float outer = radius * 0.80f;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(238, 255, 240, 194));
        canvas.drawCircle(cx + (float) Math.cos(a) * outer, cy + (float) Math.sin(a) * outer, 3.8f, paint);
        drawLapMarks(canvas, cx, cy, radius, laps);
        drawMarkers(canvas, cx, cy, radius);
    }

    private void drawLapMarks(Canvas canvas, float cx, float cy, float radius, int laps) {
        int visible = Math.min(6, laps);
        if (visible <= 0) {
            return;
        }
        float y = cy + radius * 0.58f;
        float start = cx - (visible - 1) * 4.8f;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(112, 214, 183, 116));
        for (int i = 0; i < visible; i++) {
            canvas.drawCircle(start + i * 9.6f, y, 1.9f, paint);
        }
    }

    private void drawMarkers(Canvas canvas, float cx, float cy, float radius) {
        int start = Math.max(0, markerMs.size() - 12);
        for (int i = start; i < markerMs.size(); i++) {
            float second = (markerMs.get(i) % 60000L) / 1000f;
            double a = Math.toRadians(second * 6f - 90f);
            float r = radius * 0.88f;
            int alpha = 86 + (i - start + 1) * 10;
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeWidth(1.4f);
            paint.setColor(Color.argb(Math.min(165, alpha), 255, 227, 166));
            canvas.drawLine(
                    cx + (float) Math.cos(a) * (r - 5f),
                    cy + (float) Math.sin(a) * (r - 5f),
                    cx + (float) Math.cos(a) * (r + 3f),
                    cy + (float) Math.sin(a) * (r + 3f),
                    paint);
        }
    }

    private void drawCenter(Canvas canvas, float cx, float cy, boolean active) {
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new RadialGradient(cx - 2f, cy - 3f, active ? 12f : 10f,
                new int[]{0xfffff4d6, 0xff6c5634, 0xff090909},
                new float[]{0f, 0.45f, 1f},
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, active ? 8.7f : 7.2f, paint);
        paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.1f);
        paint.setColor(active ? Color.argb(220, 255, 246, 220) : Color.argb(160, 224, 207, 166));
        canvas.drawCircle(cx, cy, active ? 5.0f : 4.2f, paint);
    }

    private void drawLuxuryHands(Canvas canvas, float cx, float cy, float hourDegrees,
                                 float minuteDegrees, float secondDegrees, float radius) {
        drawMetalHand(canvas, cx, cy, hourDegrees, radius * 0.42f, 6.6f);
        drawMetalHand(canvas, cx, cy, minuteDegrees, radius * 0.70f, 4.2f);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(1.1f);
        paint.setColor(Color.argb(146, 218, 198, 150));
        double a = Math.toRadians(secondDegrees);
        canvas.drawLine(
                cx - (float) Math.cos(a) * radius * 0.12f,
                cy - (float) Math.sin(a) * radius * 0.12f,
                cx + (float) Math.cos(a) * radius * 0.62f,
                cy + (float) Math.sin(a) * radius * 0.62f,
                paint);
    }

    private void drawMetalHand(Canvas canvas, float cx, float cy, float degrees, float length, float stroke) {
        drawHand(canvas, cx + 1.4f, cy + 1.8f, degrees, length, stroke + 1.2f, Color.argb(118, 0, 0, 0));
        drawHand(canvas, cx, cy, degrees, length, stroke, Color.argb(245, 224, 202, 160));
        drawHand(canvas, cx, cy, degrees, length * 0.96f, Math.max(1.1f, stroke * 0.32f), Color.argb(235, 255, 252, 238));
    }

    private void drawHand(Canvas canvas, float cx, float cy, float degrees, float length, float stroke, int color) {
        double a = Math.toRadians(degrees);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(stroke);
        paint.setColor(color);
        canvas.drawLine(cx, cy,
                cx + (float) Math.cos(a) * length,
                cy + (float) Math.sin(a) * length,
                paint);
    }

    private void drawRecordingJewel(Canvas canvas, float cx, float cy, float radius) {
        float y = cy + radius * 0.76f;
        float outer = radius * 0.054f;
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new RadialGradient(cx - outer * 0.35f, y - outer * 0.42f, outer * 1.5f,
                new int[]{0xffffeee0, 0xffb28c42, 0xff19120a},
                new float[]{0f, 0.42f, 1f},
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, y, outer, paint);
        paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(0.8f);
        paint.setColor(Color.argb(180, 255, 239, 200));
        canvas.drawCircle(cx, y, outer, paint);
    }

    private float pseudo01(int index, int salt) {
        double value = Math.sin((index + 1) * 12.9898 + salt * 78.233) * 43758.5453;
        return (float) (value - Math.floor(value));
    }
}
