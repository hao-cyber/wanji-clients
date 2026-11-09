package com.haowang.wristnote;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

final class ActiveRecordingJournal {
    static final long MIN_HEARTBEAT_MS = 60_000L;

    private static final String ACTIVE_FILE = "active-recording.txt";
    private static final String INTERRUPTED_FILE = "last-interrupted-recording.txt";

    private ActiveRecordingJournal() {
    }

    static void start(Context context, String sessionId, long nowMs) throws Exception {
        write(activeFile(context), detail(sessionId, nowMs, nowMs, 0L, "active"));
    }

    static boolean heartbeat(Context context, String sessionId, long elapsedMs, long nowMs) {
        try {
            State state = read(activeFile(context));
            if (state == null || !sessionId.equals(state.id)) {
                return false;
            }
            if (nowMs - state.lastHeartbeatAt < MIN_HEARTBEAT_MS) {
                return false;
            }
            write(activeFile(context), detail(sessionId, state.startedAt, nowMs, elapsedMs, "active"));
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    static void clear(Context context) {
        //noinspection ResultOfMethodCallIgnored
        activeFile(context).delete();
    }

    static State active(Context context) {
        try {
            return read(activeFile(context));
        } catch (Exception ignored) {
            return null;
        }
    }

    static State lastInterrupted(Context context) {
        try {
            return read(interruptedFile(context));
        } catch (Exception ignored) {
            return null;
        }
    }

    static boolean markInterruptedIfActive(Context context, long detectedAtMs, String reason) {
        try {
            State state = read(activeFile(context));
            if (state == null) {
                return false;
            }
            String text = detail(state.id, state.startedAt, state.lastHeartbeatAt,
                    state.elapsedMs, "interrupted")
                    + "detectedAt=" + detectedAtMs + "\n"
                    + "reason=" + sanitize(reason) + "\n";
            write(interruptedFile(context), text);
            clear(context);
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    static String describe(State state) {
        if (state == null) {
            return "none\n";
        }
        return detail(state.id, state.startedAt, state.lastHeartbeatAt,
                state.elapsedMs, state.status);
    }

    static String sanitizeForTest(String value) {
        return sanitize(value);
    }

    private static String detail(String id, long startedAt, long lastHeartbeatAt,
            long elapsedMs, String status) {
        return String.format(Locale.US,
                "id=%s\nstartedAt=%d\nlastHeartbeatAt=%d\nelapsedMs=%d\nstatus=%s\n",
                sanitize(id), startedAt, lastHeartbeatAt, elapsedMs, sanitize(status));
    }

    private static State read(File file) throws Exception {
        if (!file.isFile()) {
            return null;
        }
        String text;
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] data = new byte[(int) file.length()];
            int offset = 0;
            while (offset < data.length) {
                int read = in.read(data, offset, data.length - offset);
                if (read < 0) {
                    break;
                }
                offset += read;
            }
            text = new String(data, StandardCharsets.UTF_8);
        }
        return new State(
                field(text, "id"),
                parseLong(field(text, "startedAt")),
                parseLong(field(text, "lastHeartbeatAt")),
                parseLong(field(text, "elapsedMs")),
                field(text, "status"));
    }

    private static String field(String text, String name) {
        String prefix = name + "=";
        String[] lines = text.split("\n");
        for (String line : lines) {
            if (line.startsWith(prefix)) {
                return line.substring(prefix.length());
            }
        }
        return "";
    }

    private static long parseLong(String value) {
        try {
            return Long.parseLong(value);
        } catch (Exception ignored) {
            return 0L;
        }
    }

    private static void write(File file, String text) throws Exception {
        File parent = file.getParentFile();
        if (parent != null) {
            //noinspection ResultOfMethodCallIgnored
            parent.mkdirs();
        }
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
    }

    private static String sanitize(String value) {
        if (value == null) {
            return "";
        }
        String safe = value.replace('\n', ' ')
                .replace('\r', ' ')
                .replace('\t', ' ');
        return safe.length() > 160 ? safe.substring(0, 160) : safe;
    }

    private static File activeFile(Context context) {
        return new File(dir(context.getApplicationContext()), ACTIVE_FILE);
    }

    private static File interruptedFile(Context context) {
        return new File(dir(context.getApplicationContext()), INTERRUPTED_FILE);
    }

    private static File dir(Context context) {
        return new File(context.getFilesDir(), "diagnostics");
    }

    static final class State {
        final String id;
        final long startedAt;
        final long lastHeartbeatAt;
        final long elapsedMs;
        final String status;

        State(String id, long startedAt, long lastHeartbeatAt, long elapsedMs, String status) {
            this.id = id;
            this.startedAt = startedAt;
            this.lastHeartbeatAt = lastHeartbeatAt;
            this.elapsedMs = elapsedMs;
            this.status = status;
        }
    }
}
