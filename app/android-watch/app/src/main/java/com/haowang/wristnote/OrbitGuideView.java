package com.haowang.wristnote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.view.View;

public final class OrbitGuideView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

    public OrbitGuideView(Context context) {
        super(context);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float width = getWidth();
        float height = getHeight();
        float cx = width / 2f;
        float cy = height / 2f;
        float radius = Math.min(width, height) * 0.31f;

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(0.9f);
        paint.setColor(Color.argb(28, 122, 220, 255));
        canvas.drawCircle(cx, cy, radius, paint);

        paint.setStrokeWidth(1.1f);
        paint.setColor(Color.argb(48, 245, 245, 247));
        canvas.drawLine(cx - radius * 0.10f, cy - radius, cx + radius * 0.10f, cy - radius, paint);
        canvas.drawLine(cx - radius * 0.10f, cy + radius, cx + radius * 0.10f, cy + radius, paint);
        canvas.drawLine(cx - radius, cy - radius * 0.10f, cx - radius, cy + radius * 0.10f, paint);
        canvas.drawLine(cx + radius, cy - radius * 0.10f, cx + radius, cy + radius * 0.10f, paint);

        paint.setStrokeWidth(0.6f);
        paint.setColor(Color.argb(18, 245, 245, 247));
        canvas.drawLine(cx, cy - radius * 0.72f, cx, cy - radius * 0.48f, paint);
        canvas.drawLine(cx, cy + radius * 0.48f, cx, cy + radius * 0.72f, paint);
        canvas.drawLine(cx - radius * 0.72f, cy, cx - radius * 0.48f, cy, paint);
        canvas.drawLine(cx + radius * 0.48f, cy, cx + radius * 0.72f, cy, paint);
    }
}
