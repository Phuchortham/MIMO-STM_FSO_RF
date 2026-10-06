using System;
using System.Globalization;
using System.Text;

namespace RfProof
{
    public enum SourceMode { PRBS7, PRBS15, AsciiS, Counter, UserText }
    public enum LinkPhase { Disconnected, Identifying, Off, ArmingReceiver, StartingSender, Running, StoppingSender, Draining, StoppingReceiver, Fault }
    public sealed class RunConfig
    {
        public SourceMode Mode { get; private set; }
        public string Text { get; private set; }
        public string Hex { get; private set; }
        public RunConfig(SourceMode mode, string text)
        {
            if (!Enum.IsDefined(typeof(SourceMode), mode)) throw new ArgumentException("Choose a supported data source.");
            Mode = mode; Text = text ?? ""; Hex = "-";
            if (mode == SourceMode.UserText)
            {
                byte[] bytes = Wire.Utf8.GetBytes(Text);
                if (bytes.Length == 0 || bytes.Length > 32) throw new ArgumentException("User Text must contain 1–32 UTF-8 bytes, matching the FPGA text-memory size.");
                Hex = BitConverter.ToString(bytes).Replace("-", "");
            }
        }
        public string StartCommand(uint id, uint run)
        { return "START|" + Wire.N(id) + "|" + Wire.N(run) + "|" + Wire.N((uint)Mode) + "|" + Hex; }
        public string Label { get { return Mode == SourceMode.AsciiS ? "ASCII S" : Mode == SourceMode.UserText ? "User Text" : Mode.ToString(); } }
    }
    public static class Wire
    {
        public const uint Rate = 1000000;
        public const ulong BitsPerPacket = 10000;
        public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        public static string N(uint value) { return value.ToString(CultureInfo.InvariantCulture); }
        public static bool U32(string s, out uint n) { return UInt32.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n); }
        public static bool U64(string s, out ulong n) { return UInt64.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n); }
        public static bool Bit(string s) { return s == "0" || s == "1"; }
        public static bool HexBytes(string s, out byte[] bytes)
        {
            bytes = null;
            if (String.IsNullOrEmpty(s) || s.Length % 2 != 0 || s.Length > 64) return false;
            foreach (char c in s) if (!Uri.IsHexDigit(c)) return false;
            bytes = new byte[s.Length / 2];
            for (int i = 0; i < bytes.Length; i++) bytes[i] = Byte.Parse(s.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return true;
        }
        public static string Csv(string text)
        {
            text = text ?? ""; string trimmed = text.TrimStart();
            if (trimmed.Length > 0 && "=+-@".IndexOf(trimmed[0]) >= 0) text = "'" + text;
            return "\"" + text.Replace("\"", "\"\"") + "\"";
        }
    }
    public sealed class RunStats
    {
        public string Role, Phase;
        public uint Run, TxBps, RxBps;
        public ulong ElapsedUs, Attempted, Accepted, Unique, ErrorBits, Duplicates, Reordered, Late, Malformed, Offered;
        public ulong RxBits { get { return Unique * Wire.BitsPerPacket; } }
        public ulong TxBits { get { return Accepted * Wire.BitsPerPacket; } }
        public ulong Missing { get { return Offered - Unique; } }
        public double? Loss { get { return Offered == 0 ? (double?)null : Missing * 100.0 / Offered; } }
        public double? Ber { get { return RxBits == 0 ? (double?)null : ErrorBits / (double)RxBits; } }
        public double AverageMbps { get { return ElapsedUs == 0 ? 0 : RxBits / (double)ElapsedUs; } }
        public bool Final { get { return Phase == "FINAL"; } }
        public static bool TryParse(string[] p, out RunStats result)
        {
            result = null; uint run;
            if (p.Length != 16 || p[0] != "STATS" || (p[1] != "AP" && p[1] != "STA") || !Wire.U32(p[2], out run)) return false;
            if (p[3] != "IDLE" && p[3] != "ARMED" && p[3] != "LIVE" && p[3] != "FINAL" && p[3] != "PARTIAL") return false;
            var v = new ulong[12];
            for (int i = 0; i < v.Length; i++) if (!Wire.U64(p[i + 4], out v[i])) return false;
            ulong limit = UInt64.MaxValue / Wire.BitsPerPacket;
            if (v[1] > limit || v[3] > limit || v[9] > limit || v[2] > v[1] || v[3] > v[9] || v[4] > v[3] * Wire.BitsPerPacket || v[10] > 100000000 || v[11] > 100000000) return false;
            if (p[3] == "FINAL" && (v[0] == 0 || (p[1] == "AP" && (v[3] > v[2] || v[9] != v[1])))) return false;
            result = new RunStats { Role = p[1], Run = run, Phase = p[3], ElapsedUs = v[0], Attempted = v[1], Accepted = v[2], Unique = v[3], ErrorBits = v[4],
                Duplicates = v[5], Reordered = v[6], Late = v[7], Malformed = v[8], Offered = v[9], TxBps = (uint)v[10], RxBps = (uint)v[11] };
            return true;
        }
    }
    public sealed class DeviceState
    {
        public string Role, Port, Identity = "Waiting for continuous firmware";
        public bool Verified, Enabled, Wifi, Peer, Active, PendingValue;
        public uint Run, PendingId;
        public int Rssi, Retries;
        public string PendingCommand;
        public DateTime LastState, LastHello, PendingAt;
        public RunStats Stats;
        public DeviceState(string role) { Role = role; }
        public bool Fresh(DateTime now) { return Verified && (now - LastState).TotalSeconds < 3; }
    }
    public sealed class ReceivedSample
    {
        public uint Run;
        public SourceMode Mode;
        public ulong Offset;
        public byte[] Bytes;
        public string Hex { get { return BitConverter.ToString(Bytes).Replace("-", " "); } }
        public string Display
        {
            get
            {
                if (Mode != SourceMode.UserText && Mode != SourceMode.AsciiS) return Hex;
                try { return Wire.Utf8.GetString(Bytes); }
                catch (DecoderFallbackException) { return "Invalid UTF-8 received — inspect the hex bytes."; }
            }
        }
    }
    public sealed class LogEntry
    {
        public DateTime Time; public string Source, Message;
        public override string ToString() { return Time.ToString("HH:mm:ss.fff") + "  [" + Source + "] " + Message; }
    }
}
