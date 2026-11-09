package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.view.View;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public final class AudioRowView extends View {
    private static Bitmap rowSkin;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private final RectF assetDst = new RectF();
    private final SimpleDateFormat timeFormat = new SimpleDateFormat("MM/dd HH:mm", Locale.US);
    private AudioItem item;
    private boolean playing;
    private boolean highlighted;

    public AudioRowView(Context context) {
        super(context);
        setWillNotDraw(false);
    }

    public void setItem(AudioItem value, boolean isPlaying) {
        setItem(value, isPlaying, isPlaying);
    }

    public void setItem(AudioItem value, boolean isPlaying, boolean isHighlighted) {
        item = value;
        playing = isPlaying;
        highlighted = isHighlighted;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (item == null) {
            return;
        }
        float width = getWidth();
        float height = getHeight();
        boolean active = playing || highlighted;
        rect.set(0f, -0.5f, width, height + 0.5f);

        if (!drawRowSkin(canvas, rect, active)) {
            paint.setStyle(Paint.Style.FILL);
            paint.setShader(new LinearGradient(
                    rect.left, rect.top,
                    rect.right, rect.bottom,
                    active ? 0xff29251c : 0xff1c1a15,
                    active ? 0xff090806 : 0xff070706,
                    Shader.TileMode.CLAMP));
            canvas.drawRect(rect, paint);
            paint.setShader(null);
            drawRowTexture(canvas, rect, active);
        }
        drawEdgeVignette(canvas, rect, active);

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.0f);
        paint.setColor(active ? Color.argb(172, 226, 196, 128) : Color.argb(86, 160, 142, 96));
        canvas.drawLine(34f, 0f, width - 34f, 0f, paint);
        paint.setColor(active ? Color.argb(112, 255, 246, 216) : Color.argb(54, 255, 246, 216));
        canvas.drawLine(42f, height - 1f, width - 42f, height - 1f, paint);

        float badgeCy = height / 2f;
        drawStatusBadge(canvas, 56f, badgeCy, Math.min(50f, height * 0.44f), active);

        float textX = 98f;
        long createdAt = item.createdAt > 0 ? item.createdAt : System.currentTimeMillis();

        paint.setStyle(Paint.Style.FILL);
        paint.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        paint.setTextAlign(Paint.Align.LEFT);
        paint.setTextSize(30f);
        paint.setColor(active ? Color.rgb(255, 248, 230) : Color.rgb(242, 240, 232));
        canvas.drawText(timeFormat.format(new Date(createdAt)), textX, badgeCy - 12f, paint);

        paint.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        paint.setTextAlign(Paint.Align.LEFT);
        paint.setTextSize(21f);
        paint.setColor(active ? Color.rgb(225, 205, 158) : Color.rgb(188, 184, 170));
        canvas.drawText(formatDuration(item.durationMs), textX, badgeCy + 26f, paint);

        drawStateRail(canvas, width - 54f, badgeCy, active);
    }

    private boolean drawRowSkin(Canvas canvas, RectF bounds, boolean active) {
        if (rowSkin == null) {
            rowSkin = BitmapFactory.decodeResource(getResources(), R.drawable.watch_list_row_luxury_skin);
        }
        if (rowSkin == null || rowSkin.isRecycled()) {
            return false;
        }
        paint.setFilterBitmap(true);
        paint.setDither(true);
        paint.setAlpha(active ? 255 : 218);
        assetDst.set(bounds);
        canvas.drawBitmap(rowSkin, null, assetDst, paint);
        paint.setAlpha(255);
        paint.setShader(null);
        return true;
    }

    private void drawRowTexture(Canvas canvas, RectF bounds, boolean strong) {
        int save = canvas.save();
        canvas.clipRect(bounds);
        float cx = bounds.left + bounds.width() * 0.74f;
        float cy = bounds.centerY();
        float radius = bounds.width() * 0.78f;
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        for (int i = 0; i < 16; i++) {
            float r = radius * (0.36f + i * 0.018f);
            float top = cy - r * 0.22f;
            float bottom = cy + r * 0.22f;
            paint.setStrokeWidth(0.36f);
            paint.setColor(Color.argb(strong ? 18 : 9, 226, 200, 142));
            canvas.drawArc(cx - r, top, cx + r, bottom, 188f, 144f, false, paint);
        }
        canvas.restoreToCount(save);
    }

    private void drawEdgeVignette(Canvas canvas, RectF bounds, boolean strong) {
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new LinearGradient(
                bounds.left, bounds.centerY(),
                bounds.left + bounds.width() * 0.22f, bounds.centerY(),
                Color.argb(strong ? 178 : 150, 0, 0, 0),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        canvas.drawRect(bounds.left, bounds.top, bounds.left + bounds.width() * 0.28f, bounds.bottom, paint);
        paint.setShader(new LinearGradient(
                bounds.right, bounds.centerY(),
                bounds.right - bounds.width() * 0.24f, bounds.centerY(),
                Color.argb(strong ? 205 : 176, 0, 0, 0),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        canvas.drawRect(bounds.right - bounds.width() * 0.34f, bounds.top, bounds.right, bounds.bottom, paint);
        paint.setShader(null);
    }

    private void drawStatusBadge(Canvas canvas, float cx, float cy, float size, boolean active) {
        int color = statusColor();
        float radius = size * 0.48f;
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new RadialGradient(cx - radius * 0.25f, cy - radius * 0.35f, radius * 1.2f,
                active ? new int[]{0xff4a422f, 0xff0b0a08, 0xff020202}
                        : new int[]{0xff36332a, 0xff080807, 0xff020202},
                new float[]{0f, 0.52f, 1f},
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, radius, paint);
        paint.setShader(null);

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.1f);
        paint.setColor(Color.argb(148, 214, 188, 128));
        canvas.drawCircle(cx, cy, radius - 1f, paint);

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.argb(playing ? 228 : 158, Color.red(color), Color.green(color), Color.blue(color)));
        float left = cx - radius * 0.34f;
        float step = radius * 0.17f;
        for (int i = 0; i < 5; i++) {
            float h = radius * (0.16f + (i % 3) * 0.075f);
            if (playing && i == 2) {
                h = radius * 0.42f;
            }
            rect.set(left + i * step - 1.1f, cy - h, left + i * step + 1.1f, cy + h);
            canvas.drawRoundRect(rect, 1.1f, 1.1f, paint);
        }
        paint.setColor(Color.argb(playing ? 230 : 150, 245, 235, 204));
        if (playing) {
            canvas.drawCircle(cx + radius * 0.46f, cy - radius * 0.44f, radius * 0.075f, paint);
        } else {
            canvas.drawCircle(cx + radius * 0.43f, cy - radius * 0.39f, radius * 0.055f, paint);
        }
    }

    private void drawStateRail(Canvas canvas, float x, float cy, boolean active) {
        int color = statusColor();
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new LinearGradient(
                x, cy - 30f, x, cy + 30f,
                Color.argb(active ? 230 : 130, Color.red(color), Color.green(color), Color.blue(color)),
                Color.argb(active ? 92 : 44, Color.red(color), Color.green(color), Color.blue(color)),
                Shader.TileMode.CLAMP));
        rect.set(x - 2.5f, cy - 27f, x + 2.5f, cy + 27f);
        canvas.drawRoundRect(rect, 2.5f, 2.5f, paint);
        paint.setShader(null);
    }

    private int statusColor() {
        if (playing) {
            return Color.rgb(236, 202, 133);
        }
        if (AudioItem.FAILED.equals(item.state)) {
            return Color.rgb(196, 162, 96);
        }
        if (AudioItem.SYNCED.equals(item.state)) {
            return Color.rgb(190, 178, 138);
        }
        if (AudioItem.SYNCING.equals(item.state)) {
            return Color.rgb(255, 190, 90);
        }
        return Color.rgb(166, 158, 138);
    }

    private String formatDuration(long ms) {
        long seconds = Math.max(0, ms / 1000);
        return String.format(Locale.US, "%02d:%02d", seconds / 60, seconds % 60);
    }
}
