// Codec for Zero no Tsukaima PS2 archive compression.
// Header: [raw_size (4B LE)][step (4B LE)]
// Stream: per-chunk 1-byte instruction: high 3 bits = command, low 5 bits = length.
//   cmd 6: repeat next byte (length+2) times
//   cmd 7: literal (length+1) bytes
//   cmd 0-5: history-queue reference
using System;
using System.Collections.Generic;

public static class ZCodec {
    private static int[] _qcmd = new int[6];
    private static byte[][] _qpay = new byte[6][];

    private static void ResetQueue() {
        for (int q = 0; q < 6; q++) { _qcmd[q] = 6; _qpay[q] = new byte[] { 0 }; }
    }

    private static void UpdateQueue(int lv, int cmd, byte[] payload) {
        if (lv >= 5) { _qcmd[5] = _qcmd[4]; _qpay[5] = _qpay[4]; }
        if (lv >= 4) { _qcmd[4] = _qcmd[3]; _qpay[4] = _qpay[3]; }
        if (lv >= 3) { _qcmd[3] = _qcmd[2]; _qpay[3] = _qpay[2]; }
        if (lv >= 2) { _qcmd[2] = _qcmd[1]; _qpay[2] = _qpay[1]; }
        if (lv >= 1) { _qcmd[1] = _qcmd[0]; _qpay[1] = _qpay[0]; }
        _qcmd[0] = cmd; _qpay[0] = payload;
    }

    public static byte[] Decompress(byte[] data) {
        int rawSize = BitConverter.ToInt32(data, 0);
        int step = BitConverter.ToInt32(data, 4);
        var result = new List<byte>(rawSize);
        ResetQueue();
        int pos = 8;
        int size = rawSize;
        while (size > 0) {
            byte instruction = data[pos];
            int command = instruction >> 5;
            int length = instruction & 0x1F;
            pos += 1;
            if (command == 6) {
                var p = new byte[] { data[pos] };
                pos += 1;
                int n = length + 2;
                for (int i = 0; i < n; i++) result.Add(p[0]);
                size -= n;
                UpdateQueue(6, 6, p);
            } else if (command == 7) {
                int n = length + 1;
                var sub = new byte[n];
                Array.Copy(data, pos, sub, 0, n);
                pos += n;
                result.AddRange(sub);
                size -= n;
                UpdateQueue(7, 7, sub);
            } else {
                int refc = _qcmd[command];
                byte[] refp = _qpay[command];
                UpdateQueue(command, refc, refp);
                if (refc == 6) {
                    int n = length + 2;
                    for (int i = 0; i < n; i++) result.Add(refp[0]);
                    size -= n;
                } else {
                    int dp = length >> 2;
                    int dl = length & 3;
                    for (int i = dp; i < dp + dl + 1 && i < refp.Length; i++) result.Add(refp[i]);
                    size -= dl + 1;
                }
            }
        }
        byte[] stream = result.ToArray();
        return TransposeBack(stream, rawSize, step);
    }

    public static byte[] TransposeBack(byte[] stream, int size, int step) {
        var result = new byte[size];
        int j = size / step;
        int k = j * step;
        for (int i = 0; i < j; i++) {
            for (int m = 0; m < step; m++) {
                int idx = i + m * j;
                if (idx < k) result[i * step + m] = stream[idx];
            }
        }
        for (int idx = k; idx < size; idx++) result[idx] = stream[idx];
        return result;
    }

    public static byte[] ForwardTranspose(byte[] data, int step) {
        int size = data.Length;
        int j = size / step;
        int k = j * step;
        var stream = new byte[size];
        for (int i = 0; i < j; i++) {
            int b = i * step;
            for (int m = 0; m < step; m++) {
                int idx = i + m * j;
                if (idx < k) stream[idx] = data[b + m];
            }
        }
        for (int idx = k; idx < size; idx++) stream[idx] = data[idx];
        return stream;
    }

    public static byte[] CompressLz(byte[] stream) {
        var out_ = new List<byte>();
        int size = stream.Length;
        int pos = 0;
        while (pos < size) {
            int run = 1;
            while (pos + run < size && stream[pos + run] == stream[pos] && run < 33) run++;
            if (run >= 2) {
                int n = Math.Min(run, 33);
                out_.Add((byte)(0xC0 | (n - 2)));
                out_.Add(stream[pos]);
                pos += n;
            } else {
                int n = Math.Min(32, size - pos);
                out_.Add((byte)(0xE0 | (n - 1)));
                for (int i = 0; i < n; i++) out_.Add(stream[pos + i]);
                pos += n;
            }
        }
        return out_.ToArray();
    }

    public static byte[] Compress(byte[] data, int step) {
        byte[] stream = ForwardTranspose(data, step);
        byte[] body = CompressLz(stream);
        var out_ = new byte[8 + body.Length];
        Buffer.BlockCopy(BitConverter.GetBytes(data.Length), 0, out_, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(step), 0, out_, 4, 4);
        Buffer.BlockCopy(body, 0, out_, 8, body.Length);
        return out_;
    }
}
