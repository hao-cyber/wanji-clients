package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.view.View;

public final class IconButtonView extends View {
    static final int PLAY = 1;
    static final int PAUSE = 2;
    static final int UPLOAD = 3;
    static final int DELETE = 4;
    static final int BACK = 5;
    static final int LOADING = 6;

    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final RectF rect = new RectF();
    private int icon = PLAY;
    private boolean prominent;
    private boolean destructive;
    private boolean visuallyEnabled = true;

    public IconButtonView(Context context) {
        super(context);
    }

    public void setIcon(int value) {
        icon = value;
        invalidate();
    }

    public void setProminent(boolean value) {
        prominent = value;
        invalidate();
    }

    public void setDestructive(boolean value) {
        destructive = value;
        invalidate();
    }

    public void setVisuallyEnabled(boolean value) {
        visuallyEnabled = value;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float size = Math.min(getWidth(), getHeight());
        float cx = getWidth() / 2f;
        float cy = getHeight() / 2f;
        float radius = prominent ? size * 0.44f : size * 0.40f;
        boolean active = isEnabled() && visuallyEnabled;

        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new RadialGradient(cx - radius * 0.28f, cy - radius * 0.34f, radius * 1.35f,
                prominent
                        ? new int[]{0xff4a4437, 0xff161512, 0xff020202}
                        : new int[]{0xff25241f, 0xff0b0b0a, 0xff020202},
                new float[]{0f, 0.55f, 1f},
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, radius, paint);
        paint.setShader(null);

        paint.setShader(new LinearGradient(
                cx - radius, cy - radius,
                cx + radius * 0.42f, cy + radius * 0.72f,
                Color.argb(prominent ? 72 : 42, 255, 248, 230),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, radius * 0.96f, paint);
        paint.setShader(null);

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1.2f, size * 0.020f));
        if (!active) {
            paint.setColor(Color.argb(58, 154, 150, 140));
        } else if (destructive) {
            paint.setColor(Color.argb(190, 216, 180, 120));
        } else if (prominent) {
            paint.setColor(Color.argb(226, 222, 194, 132));
        } else {
            paint.setColor(Color.argb(130, 176, 162, 126));
        }
        canvas.drawCircle(cx, cy, radius - paint.getStrokeWidth() / 2f, paint);

        paint.setStrokeWidth(Math.max(0.65f, size * 0.010f));
        paint.setColor(Color.argb(prominent ? 172 : 110, 255, 249, 232));
        canvas.drawCircle(cx, cy, radius - Math.max(3.2f, size * 0.052f), paint);

        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setStrokeWidth(Math.max(2.4f, size * 0.043f));
        paint.setStyle(Paint.Style.STROKE);
        paint.setColor(active
                ? (destructive ? Color.rgb(255, 235, 214) : Color.rgb(248, 244, 232))
                : Color.rgb(92, 88, 78));

        if (icon == PLAY) {
            drawPlay(canvas, cx, cy, size);
        } else if (icon == PAUSE) {
            drawPause(canvas, cx, cy, size);
        } else if (icon == UPLOAD) {
            drawUpload(canvas, cx, cy, size);
        } else if (icon == DELETE) {
            drawDelete(canvas, cx, cy, size);
        } else if (icon == BACK) {
            drawBack(canvas, cx, cy, size);
        } else {
            drawLoading(canvas, cx, cy, size);
        }
    }

    private void drawPlay(Canvas canvas, float cx, float cy, float size) {
        path.reset();
        path.moveTo(cx - size * 0.095f, cy - size * 0.145f);
        path.lineTo(cx - size * 0.095f, cy + size * 0.145f);
        path.lineTo(cx + size * 0.155f, cy);
        path.close();
        paint.setStyle(Paint.Style.FILL);
        canvas.drawPath(path, paint);
    }

    private void drawPause(Canvas canvas, float cx, float cy, float size) {
        paint.setStyle(Paint.Style.FILL);
        float w = size * 0.055f;
        float h = size * 0.25f;
        rect.set(cx - size * 0.12f - w / 2f, cy - h / 2f, cx - size * 0.12f + w / 2f, cy + h / 2f);
        canvas.drawRoundRect(rect, w, w, paint);
        rect.set(cx + size * 0.12f - w / 2f, cy - h / 2f, cx + size * 0.12f + w / 2f, cy + h / 2f);
        canvas.drawRoundRect(rect, w, w, paint);
    }

    private void drawUpload(Canvas canvas, float cx, float cy, float size) {
        paint.setStyle(Paint.Style.STROKE);
        canvas.drawLine(cx, cy + size * 0.16f, cx, cy - size * 0.15f, paint);
        canvas.drawLine(cx, cy - size * 0.15f, cx - size * 0.115f, cy - size * 0.025f, paint);
        canvas.drawLine(cx, cy - size * 0.15f, cx + size * 0.115f, cy - size * 0.025f, paint);
        paint.setStrokeWidth(Math.max(1.8f, size * 0.03f));
        canvas.drawLine(cx - size * 0.16f, cy + size * 0.20f, cx + size * 0.16f, cy + size * 0.20f, paint);
    }

    private void drawDelete(Canvas canvas, float cx, float cy, float size) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1.8f, size * 0.032f));
        rect.set(cx - size * 0.105f, cy - size * 0.055f, cx + size * 0.105f, cy + size * 0.165f);
        canvas.drawRoundRect(rect, size * 0.025f, size * 0.025f, paint);
        canvas.drawLine(cx - size * 0.14f, cy - size * 0.115f, cx + size * 0.14f, cy - size * 0.115f, paint);
        canvas.drawLine(cx - size * 0.055f, cy - size * 0.155f, cx + size * 0.055f, cy - size * 0.155f, paint);
        canvas.drawLine(cx - size * 0.04f, cy - size * 0.005f, cx - size * 0.04f, cy + size * 0.115f, paint);
        canvas.drawLine(cx + size * 0.04f, cy - size * 0.005f, cx + size * 0.04f, cy + size * 0.115f, paint);
    }

    private void drawBack(Canvas canvas, float cx, float cy, float size) {
        paint.setStyle(Paint.Style.STROKE);
        canvas.drawLine(cx - size * 0.17f, cy, cx + size * 0.16f, cy, paint);
        canvas.drawLine(cx - size * 0.17f, cy, cx - size * 0.035f, cy - size * 0.13f, paint);
        canvas.drawLine(cx - size * 0.17f, cy, cx - size * 0.035f, cy + size * 0.13f, paint);
    }

    private void drawLoading(Canvas canvas, float cx, float cy, float size) {
        paint.setStyle(Paint.Style.FILL);
        for (int i = -1; i <= 1; i++) {
            canvas.drawCircle(cx + i * size * 0.105f, cy, size * 0.028f, paint);
        }
    }
}
