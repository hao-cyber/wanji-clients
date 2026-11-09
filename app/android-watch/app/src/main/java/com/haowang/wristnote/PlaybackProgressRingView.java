package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.SweepGradient;
import android.view.View;

public final class PlaybackProgressRingView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF arc = new RectF();
    private final RectF assetDst = new RectF();
    private final Path roundClip = new Path();
    private Bitmap playbackBase;
    private float progress;
    private boolean active;

    public PlaybackProgressRingView(Context context) {
        super(context);
    }

    public void setProgress(float value, boolean active) {
        progress = Math.max(0f, Math.min(1f, value));
        this.active = active;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float size = Math.min(getWidth(), getHeight());
        float inset = Math.max(9f, size * 0.035f);
        arc.set(inset, inset, getWidth() - inset, getHeight() - inset);
        float cx = getWidth() / 2f;
        float cy = getHeight() / 2f;
        boolean assetDrawn = drawBaseAsset(canvas, cx, cy, size / 2f - 1f);

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(Math.max(4.0f, size * 0.016f));
        if (!assetDrawn) {
            paint.setShader(new SweepGradient(cx, cy,
                    new int[]{
                            Color.argb(active ? 112 : 78, 255, 248, 230),
                            Color.argb(active ? 42 : 30, 70, 62, 45),
                            Color.argb(active ? 145 : 96, 238, 218, 174),
                            Color.argb(active ? 50 : 34, 26, 24, 20),
                            Color.argb(active ? 112 : 78, 255, 248, 230)
                    },
                    new float[]{0f, 0.22f, 0.48f, 0.72f, 1f}));
            canvas.drawArc(arc, -90f, 360f, false, paint);
            paint.setShader(null);
        }

        if (!active) {
            if (!assetDrawn) {
                arc.inset(size * 0.030f, size * 0.030f);
                paint.setStrokeWidth(Math.max(0.9f, size * 0.004f));
                paint.setColor(Color.argb(44, 216, 190, 132));
                canvas.drawArc(arc, -52f, 248f, false, paint);
            }
            return;
        }
        paint.setStrokeWidth(Math.max(4.8f, size * 0.018f));
        paint.setShader(new SweepGradient(cx, cy,
                new int[]{0xfffff4d3, 0xffcaa464, 0xffffffff, 0xff8a6432, 0xfffff4d3},
                new float[]{0f, 0.28f, 0.50f, 0.76f, 1f}));
        float sweep = progress > 0f ? progress * 360f : 18f;
        canvas.drawArc(arc, -90f, sweep, false, paint);
        paint.setShader(null);

        double end = Math.toRadians(sweep - 90f);
        float radius = (arc.width() - paint.getStrokeWidth()) / 2f;
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.rgb(255, 249, 231));
        canvas.drawCircle(
                cx + (float) Math.cos(end) * radius,
                cy + (float) Math.sin(end) * radius,
                Math.max(4.0f, size * 0.014f),
                paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(0.9f);
        paint.setColor(Color.argb(180, 84, 62, 30));
        canvas.drawCircle(
                cx + (float) Math.cos(end) * radius,
                cy + (float) Math.sin(end) * radius,
                Math.max(4.0f, size * 0.014f),
                paint);
    }

    private boolean drawBaseAsset(Canvas canvas, float cx, float cy, float radius) {
        if (playbackBase == null) {
            playbackBase = BitmapFactory.decodeResource(getResources(), R.drawable.watch_playback_luxury_base_v2);
        }
        if (playbackBase == null || playbackBase.isRecycled()) {
            return false;
        }
        int save = canvas.save();
        roundClip.reset();
        roundClip.addCircle(cx, cy, radius, Path.Direction.CW);
        canvas.clipPath(roundClip);
        assetDst.set(cx - radius, cy - radius, cx + radius, cy + radius);
        paint.setFilterBitmap(true);
        paint.setDither(true);
        paint.setAlpha(255);
        canvas.drawBitmap(playbackBase, null, assetDst, paint);
        paint.setShader(null);
        canvas.restoreToCount(save);
        return true;
    }

}
