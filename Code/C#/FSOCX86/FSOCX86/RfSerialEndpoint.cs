using System;
using System.IO;
using System.IO.Ports;
using System.Text;

namespace RfProof
{
    public interface IEndpoint : IDisposable
    {
        event Action<string> Line;
        event Action<string> Fault;
        bool IsOpen { get; }
        void Open(string port);
        void Send(string line);
        void Close();
    }

    public sealed class SerialEndpoint : IEndpoint
    {
        private readonly object gate = new object();
        private readonly StringBuilder buffer = new StringBuilder();
        private SerialPort port;
        private bool discarding;
        public event Action<string> Line;
        public event Action<string> Fault;
        public bool IsOpen { get { lock (gate) return port != null && port.IsOpen; } }

        public void Open(string name)
        {
            Close();
            lock (gate)
            {
                var candidate = new SerialPort(name, 115200, Parity.None, 8, StopBits.One)
                {
                    Handshake = Handshake.None, DtrEnable = false, RtsEnable = false,
                    Encoding = Encoding.ASCII, NewLine = "\n", ReadTimeout = 100, WriteTimeout = 300
                };
                try
                {
                    candidate.Open();
                    candidate.DiscardInBuffer();
                    port = candidate;
                    buffer.Clear();
                    discarding = false;
                    candidate.DataReceived += OnData;
                }
                catch { candidate.Dispose(); throw; }
            }
        }

        private void OnData(object sender, SerialDataReceivedEventArgs e)
        {
            var lines = new System.Collections.Generic.List<string>();
            string error = null;
            lock (gate)
            {
                if (!ReferenceEquals(sender, port) || port == null || !port.IsOpen) return;
                try
                {
                    foreach (char ch in port.ReadExisting())
                    {
                        if (ch == '\r') continue;
                        if (ch == '\n')
                        {
                            if (!discarding && buffer.Length > 0) lines.Add(buffer.ToString());
                            buffer.Clear(); discarding = false;
                        }
                        else if (!discarding)
                        {
                            if (buffer.Length >= 1024) { buffer.Clear(); discarding = true; }
                            else buffer.Append(ch);
                        }
                    }
                }
                catch (Exception ex) { error = ex.Message; }
            }
            foreach (string line in lines) Line?.Invoke(line);
            if (error != null) Fault?.Invoke(error);
        }

        public void Send(string line)
        {
            lock (gate)
            {
                if (port == null || !port.IsOpen) throw new InvalidOperationException("Serial port is not connected.");
                port.WriteLine(line);
            }
        }

        public void Close()
        {
            SerialPort old;
            lock (gate)
            {
                old = port; port = null; buffer.Clear();
                if (old != null) old.DataReceived -= OnData;
            }
            // Do not hold gate during Close: a finishing DataReceived callback may need it.
            if (old != null)
            {
                // A removed USB cable may make Close/Dispose throw. The endpoint is
                // already detached; still let the controller close the other board.
                try { old.Close(); }
                catch (IOException) { }
                catch (InvalidOperationException) { }
                finally
                {
                    try { old.Dispose(); }
                    catch (IOException) { }
                    catch (InvalidOperationException) { }
                }
            }
        }
        public void Dispose() { Close(); }
    }
}
