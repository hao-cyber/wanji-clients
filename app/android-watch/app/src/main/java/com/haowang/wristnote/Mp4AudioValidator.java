package com.haowang.wristnote;

import java.io.File;
import java.io.RandomAccessFile;

final class Mp4AudioValidator {
    private Mp4AudioValidator() {
    }

    static boolean isCompleteMp4(File file) {
        if (file == null || !file.isFile() || file.length() < 32L) {
            return false;
        }
        long length = file.length();
        boolean sawFtyp = false;
        boolean sawMdat = false;
        boolean sawMoov = false;
        try (RandomAccessFile in = new RandomAccessFile(file, "r")) {
            long offset = 0L;
            while (offset + 8L <= length) {
                in.seek(offset);
                long size32 = readUInt32(in);
                String type = readType(in);
                long header = 8L;
                long boxSize = size32;
                if (size32 == 1L) {
                    if (offset + 16L > length) {
                        return false;
                    }
                    boxSize = readUInt64(in);
                    header = 16L;
                } else if (size32 == 0L) {
                    return false;
                }
                if (boxSize < header || offset + boxSize > length) {
                    return false;
                }
                if ("ftyp".equals(type)) {
                    sawFtyp = true;
                } else if ("mdat".equals(type)) {
                    sawMdat = true;
                } else if ("moov".equals(type)) {
                    sawMoov = true;
                }
                offset += boxSize;
            }
        } catch (Exception ignored) {
            return false;
        }
        return sawFtyp && sawMdat && sawMoov;
    }

    private static long readUInt32(RandomAccessFile in) throws Exception {
        return in.readInt() & 0xffffffffL;
    }

    private static long readUInt64(RandomAccessFile in) throws Exception {
        long value = in.readLong();
        return value < 0L ? Long.MAX_VALUE : value;
    }

    private static String readType(RandomAccessFile in) throws Exception {
        byte[] bytes = new byte[4];
        in.readFully(bytes);
        return new String(bytes, java.nio.charset.StandardCharsets.US_ASCII);
    }
}
