package com.haowang.wristnote;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public final class DiagnosticsExportReceiver extends BroadcastReceiver {
    private static final String TAG = "DiagnosticsExport";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) {
            return;
        }
        if (RecordingDiagnosticsExporter.ACTION_REQUEUE_BLE_PULL.equals(intent.getAction())) {
            try {
                String ids = intent.getStringExtra("ids");
                int changed = RecordingDiagnosticsExporter.requeueBlePull(context, ids);
                RecordingEventLog.record(context, "ble_requeue_ok", "changed=" + changed);
                Log.i(TAG, "recording diagnostics requeue changed=" + changed);
            } catch (Exception e) {
                RecordingEventLog.record(context, "ble_requeue_failed",
                        "error=" + e.getClass().getSimpleName());
                Log.w(TAG, "recording diagnostics requeue failed " + e.getClass().getSimpleName());
            }
            return;
        }
        if (RecordingDiagnosticsExporter.ACTION_MARK_BLE_UNREADABLE.equals(intent.getAction())) {
            try {
                String ids = intent.getStringExtra("ids");
                int changed = RecordingDiagnosticsExporter.markBleUnreadable(context, ids);
                RecordingEventLog.record(context, "ble_unreadable_mark_ok", "changed=" + changed);
                Log.i(TAG, "recording diagnostics mark unreadable changed=" + changed);
            } catch (Exception e) {
                RecordingEventLog.record(context, "ble_unreadable_mark_failed",
                        "error=" + e.getClass().getSimpleName());
                Log.w(TAG, "recording diagnostics mark unreadable failed " + e.getClass().getSimpleName());
            }
            return;
        }
        if (!RecordingDiagnosticsExporter.ACTION_EXPORT.equals(intent.getAction())) {
            return;
        }
        try {
            String path = RecordingDiagnosticsExporter.export(context).getAbsolutePath();
            RecordingEventLog.record(context, "diagnostics_export_ok", "path=" + path);
            Log.i(TAG, "recording diagnostics exported path=" + path);
        } catch (Exception e) {
            RecordingEventLog.record(context, "diagnostics_export_failed",
                    "error=" + e.getClass().getSimpleName());
            Log.w(TAG, "recording diagnostics export failed " + e.getClass().getSimpleName());
        }
    }
}
