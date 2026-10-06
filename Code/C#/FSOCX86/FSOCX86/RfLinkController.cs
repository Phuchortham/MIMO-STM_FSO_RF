using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;

namespace RfProof
{
    public sealed class LinkController : IDisposable
    {
        private sealed class Incoming { public int Index; public string Line; public bool Fault; }
        private readonly IEndpoint[] ports;
        private readonly DeviceState[] devices;
        private readonly ConcurrentQueue<Incoming> queue = new ConcurrentQueue<Incoming>();
        private readonly Func<DateTime> clock;
        private readonly List<LogEntry> log = new List<LogEntry>();
        private uint id = BitConverter.ToUInt32(Guid.NewGuid().ToByteArray(), 0);
        private int overflow;
        private DateTime connectedAt, actionAt, keepaliveAt;
        private bool finished, wasRunning;
        public DeviceState Receiver { get { return devices[0]; } }
        public DeviceState Sender { get { return devices[1]; } }
        public LinkPhase Phase { get; private set; }
        public bool Connected { get; private set; }
        public bool DesiredEnabled { get; private set; }
        public uint Run { get; private set; }
        public RunConfig Config { get; private set; }
        public string Problem { get; private set; }
        public ReceivedSample LastSample { get; private set; }
        public bool Ready { get { return Connected && Phase != LinkPhase.Fault && Receiver.Fresh(clock()) && Sender.Fresh(clock()); } }
        public bool Pending { get { return Receiver.PendingId != 0 || Sender.PendingId != 0; } }
        public bool CanStart { get { return Ready && Phase == LinkPhase.Off && !Pending && !Receiver.Enabled && !Sender.Enabled; } }
        public bool Running { get { return Ready && DesiredEnabled && Phase == LinkPhase.Running && Receiver.Active && Sender.Active && Receiver.Run == Run && Sender.Run == Run; } }
        public bool CanEdit { get { return Phase == LinkPhase.Disconnected || Phase == LinkPhase.Off || Phase == LinkPhase.Fault; } }
        public IReadOnlyList<LogEntry> Logs { get { return log.AsReadOnly(); } }
        public event Action<LogEntry> Logged;
        public event Action<RunStats> Measurement;
        public event Action<ReceivedSample> SampleReceived;
        public string Status
        {
            get
            {
                switch (Phase)
                {
                    case LinkPhase.Disconnected: return "Disconnected — select two USB ports";
                    case LinkPhase.Identifying: return "Identifying continuous firmware (v2)…";
                    case LinkPhase.Off: return "OFF — confirmed by both ESP32s";
                    case LinkPhase.ArmingReceiver: return "Preparing receiver…";
                    case LinkPhase.StartingSender: return "Starting continuous RF stream…";
                    case LinkPhase.Running: return "ON — continuous 1 Mbps stream";
                    case LinkPhase.StoppingSender: return "Stopping transmitter…";
                    case LinkPhase.Draining: return "Transmitter OFF — collecting final receiver counts…";
                    case LinkPhase.StoppingReceiver: return "Confirming receiver OFF…";
                    default: return "Control fault — reconnect before restarting";
                }
            }
        }
        public LinkController(IEndpoint receiver, IEndpoint sender, Func<DateTime> clock = null)
        {
            ports = new[] { receiver, sender }; devices = new[] { new DeviceState("AP"), new DeviceState("STA") };
            this.clock = clock ?? (() => DateTime.UtcNow);
            for (int i = 0; i < 2; ++i)
            {
                int index = i;
                ports[i].Line += value => Enqueue(index, value, false);
                ports[i].Fault += value => Enqueue(index, value, true);
            }
        }
        private void Enqueue(int index, string value, bool fault)
        {
            if (queue.Count >= 1000) { Interlocked.Exchange(ref overflow, 1); return; }
            queue.Enqueue(new Incoming { Index = index, Line = value, Fault = fault });
        }
        private uint Next() { if (++id == 0) id = 1; return id; }
        public void Note(string text) { Log("GUI", text); }
        private void Log(string source, string message)
        {
            var e = new LogEntry { Time = clock().ToLocalTime(), Source = source, Message = message };
            if (log.Count >= 1000) log.RemoveAt(0); log.Add(e); Logged?.Invoke(e);
        }
        private void Send(int index, string line)
        {
            if (!Connected) return;
            try { ports[index].Send(line); } catch (Exception ex) { Enqueue(index, ex.Message, true); }
        }
        private void Request(int index, bool enable)
        {
            var d = devices[index]; if (!d.Verified) return;
            d.PendingId = Next(); d.PendingValue = enable; d.Retries = 0; d.PendingAt = clock();
            d.PendingCommand = enable ? Config.StartCommand(d.PendingId, Run) : "STOP|" + Wire.N(d.PendingId);
            Send(index, d.PendingCommand);
        }
        public void Connect(string receiver, string sender)
        {
            if (String.IsNullOrWhiteSpace(receiver) || String.IsNullOrWhiteSpace(sender) || receiver.Equals(sender, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Select two different USB ports.");
            Disconnect(); Incoming old; while (queue.TryDequeue(out old)) { }
            overflow = 0; Problem = null; Run = 0; Config = null; LastSample = null;
            devices[0] = new DeviceState("AP") { Port = receiver }; devices[1] = new DeviceState("STA") { Port = sender };
            try { ports[0].Open(receiver); ports[1].Open(sender); } catch { ports[0].Close(); ports[1].Close(); throw; }
            Connected = true; Phase = LinkPhase.Identifying; connectedAt = keepaliveAt = clock();
            for (int i = 0; i < 2; ++i) { devices[i].LastHello = clock(); Send(i, "HELLO"); }
            Log("GUI", "USB open at 115200 baud. Identifying firmware v2; forwarding remains OFF.");
        }
        public void Start(RunConfig config)
        {
            if (!CanStart) throw new InvalidOperationException("Wait for both firmware identities and OFF acknowledgements.");
            Config = config ?? throw new ArgumentNullException(nameof(config)); Run = Next(); finished = wasRunning = false; LastSample = null;
            Receiver.Stats = Sender.Stats = null;
            DesiredEnabled = true; Phase = LinkPhase.ArmingReceiver; actionAt = clock(); Request(0, true);
            Log("GUI", "Continuous " + config.Label + " at fixed 1 Mbps requested. No timed stop.");
        }
        public void Stop()
        {
            if (!Connected || Phase == LinkPhase.Fault) return;
            wasRunning = wasRunning || Phase == LinkPhase.Running || Sender.Active;
            DesiredEnabled = false; actionAt = clock(); Request(1, false);
            if (wasRunning) Phase = LinkPhase.StoppingSender;
            else { Request(0, false); Phase = LinkPhase.StoppingReceiver; }
            Log("GUI", "Stop requested. The transmitter stops first; the receiver collects final packet counts.");
        }
        private void Fault(string reason)
        {
            if (Phase == LinkPhase.Fault) return;
            Problem = reason; DesiredEnabled = false; Phase = LinkPhase.Fault; Request(1, false); Request(0, false);
            Log("SAFETY", reason + " OFF requested on both boards; keepalive leases stopped.");
        }
        private void Advance()
        {
            if (Phase == LinkPhase.Identifying && Ready && !Pending && !Receiver.Enabled && !Sender.Enabled) Phase = LinkPhase.Off;
            if (Phase == LinkPhase.StartingSender && Ready && !Pending && Receiver.Enabled && Sender.Enabled && Receiver.Active && Sender.Active && Receiver.Run == Run && Sender.Run == Run)
            { Phase = LinkPhase.Running; wasRunning = true; Log("RF", "Continuous stream is running on both boards."); }
            if (Phase == LinkPhase.StoppingSender && Sender.PendingId == 0 && !Sender.Enabled) Phase = LinkPhase.Draining;
            if (Phase == LinkPhase.Draining && finished && Receiver.Stats != null && Receiver.Stats.Run == Run && Receiver.Stats.Final)
            { Phase = LinkPhase.StoppingReceiver; Request(0, false); }
            if (Phase == LinkPhase.StoppingReceiver && !Pending && !Receiver.Enabled && !Sender.Enabled)
            { Phase = LinkPhase.Off; wasRunning = false; Log("GUI", "OFF confirmed by both boards. Final counts remain visible."); }
        }
        public void Pump()
        {
            Incoming item;
            if (Interlocked.Exchange(ref overflow, 0) != 0 && Connected) Fault("Serial event queue overflow.");
            for (int count = 0; count < 300 && queue.TryDequeue(out item); count++)
            {
                if (!Connected) continue;
                if (item.Fault) { Log("USB", item.Line); Problem = item.Line; Disconnect(); continue; }
                Handle(item.Index, item.Line); Advance();
            }
            if (!Connected) return;
            DateTime now = clock();
            if (Phase == LinkPhase.Identifying && (now - connectedAt).TotalSeconds > 10) Fault("No matching continuous firmware reply. Upload the v2 sketches, or check the COM-port assignment.");
            if (DesiredEnabled && !Ready) Fault("Board status timed out.");
            if ((Phase == LinkPhase.ArmingReceiver || Phase == LinkPhase.StartingSender) && (now - actionAt).TotalSeconds > 15) Fault("The continuous stream did not start.");
            if ((Phase == LinkPhase.StoppingSender || Phase == LinkPhase.Draining || Phase == LinkPhase.StoppingReceiver) && (now - actionAt).TotalSeconds > 7) Fault("Final stop/report timed out; latest counts may be partial.");
            for (int i = 0; i < 2; ++i)
            {
                var d = devices[i];
                if (!d.Verified && Phase != LinkPhase.Fault && (now - d.LastHello).TotalSeconds >= 2) { d.LastHello = now; Send(i, "HELLO"); }
                if (d.PendingId != 0 && (now - d.PendingAt).TotalMilliseconds >= 650)
                {
                    if (++d.Retries > 3) { d.PendingId = 0; Fault("Control acknowledgement timed out on " + d.Role + "."); }
                    else { d.PendingAt = now; Send(i, d.PendingCommand); }
                }
            }
            if (Phase != LinkPhase.Fault && (now - keepaliveAt).TotalMilliseconds >= 800)
            {
                keepaliveAt = now; for (int i = 0; i < 2; ++i) if (devices[i].Verified) Send(i, "KEEPALIVE");
            }
            Advance();
        }
        private void Handle(int index, string line)
        {
            if (String.IsNullOrEmpty(line) || line.Length > 1024) return;
            string[] p = line.Split('|'); var d = devices[index]; uint id, run;
            if (p[0] == "HELLO" && p.Length == 5)
            {
                if (p[1] != "2" || p[2] != d.Role || p[3] != "1000000") { Fault("Wrong firmware/role on " + d.Port + ". Use continuous-v2 AP on receiver and STA on sender."); return; }
                string identity = d.Role + " " + p[4];
                if (d.Verified && d.Identity == identity) return;
                if (d.Verified) Fault(d.Role + " restarted. A new run must be started manually.");
                d.Verified = true; d.Identity = identity; d.LastState = DateTime.MinValue; d.Enabled = false;
                Request(index, false); Log(d.Role, "Identified " + p[4] + "; requesting OFF."); return;
            }
            if (!d.Verified) return;
            if (p[0] == "ACK" && p.Length == 4 && Wire.U32(p[1], out id) && Wire.Bit(p[2]) && Wire.U32(p[3], out run))
            {
                bool value = p[2] == "1";
                if (id != d.PendingId || value != d.PendingValue || (value && run != Run)) return;
                d.PendingId = 0; d.Enabled = value; d.Run = run; Log(d.Role, value ? "ON acknowledged." : "OFF acknowledged.");
                if (index == 0 && value && DesiredEnabled && Phase == LinkPhase.ArmingReceiver)
                { Phase = LinkPhase.StartingSender; Request(1, true); }
                return;
            }
            if (p[0] == "STATE" && p.Length == 9)
            {
                int rssi;
                if (p[1] != d.Role || !Wire.Bit(p[2]) || !Wire.Bit(p[3]) || !Wire.Bit(p[4]) || p[5] != "1000000" || !Wire.U32(p[6], out run) || !Wire.Bit(p[7]) || !Int32.TryParse(p[8], NumberStyles.Integer, CultureInfo.InvariantCulture, out rssi)) return;
                d.Enabled = p[2] == "1"; d.Wifi = p[3] == "1"; d.Peer = p[4] == "1"; d.Run = run; d.Active = p[7] == "1"; d.Rssi = rssi; d.LastState = clock();
                if (DesiredEnabled && Phase == LinkPhase.Running && (!d.Enabled || !d.Active || run != Run)) Fault(d.Role + " stopped or changed run unexpectedly.");
                if (Phase == LinkPhase.Off && d.Enabled) Fault(d.Role + " unexpectedly reported ON.");
                return;
            }
            if (p[0] == "STATS")
            {
                RunStats stats;
                if (!RunStats.TryParse(p, out stats) || stats.Role != d.Role || stats.Run != Run || Run == 0) return;
                d.Stats = stats; if (index == 0) Measurement?.Invoke(stats); return;
            }
            if (p[0] == "SAMPLE" && p.Length == 5 && index == 0 && Wire.U32(p[1], out run) && run == Run && Config != null)
            {
                uint mode; ulong offset; byte[] bytes;
                if (!Wire.U32(p[2], out mode) || mode != (uint)Config.Mode || !Wire.U64(p[3], out offset) || !Wire.HexBytes(p[4], out bytes)) return;
                LastSample = new ReceivedSample { Run = run, Mode = Config.Mode, Offset = offset, Bytes = bytes }; SampleReceived?.Invoke(LastSample); return;
            }
            if (p[0] == "FINISHED" && p.Length == 2 && index == 1 && Wire.U32(p[1], out run) && run == Run)
            { finished = true; Log("RF", "Final receiver report acknowledged by sender."); return; }
            if (p[0] == "ERROR" && p.Length == 3) { Fault(d.Role + ": " + p[2]); return; }
            if (p[0] == "EVENT" && p.Length == 2) { Log(d.Role, p[1]); if (DesiredEnabled && p[1] == "LEASE_EXPIRED") Fault(d.Role + " forwarding lease expired."); }
        }
        public void Disconnect()
        {
            if (Connected) { for (int i = 1; i >= 0; --i) if (devices[i].Verified) Send(i, "STOP|" + Wire.N(Next())); Log("GUI", "OFF requested; ports released. Firmware leases expire without keepalives."); }
            Connected = DesiredEnabled = false; Phase = LinkPhase.Disconnected;
            for (int i = 0; i < 2; ++i) { ports[i].Close(); devices[i].Verified = false; devices[i].PendingId = 0; devices[i].Enabled = false; }
        }
        public void Dispose() { Disconnect(); foreach (var p in ports) p.Dispose(); }
    }
}
