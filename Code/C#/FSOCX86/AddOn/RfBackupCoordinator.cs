using System;
using System.Globalization;

namespace RfProof
{
    public enum RfOpticalMode { None, Diversity, SpatialMultiplexing }

    /// <summary>
    /// UI-thread policy for the existing continuous-v2 RF controller. Optical
    /// availability is supplied by the FSO interval parser, never inferred from
    /// an RF counter or from the transmitted text. This class owns no ports.
    /// </summary>
    public sealed class RfBackupCoordinator
    {
        private readonly LinkController controller;
        private readonly Func<DateTime> clock;
        private RunConfig config;
        private bool armed, sweeping;
        private RfOpticalMode opticalMode;
        private bool opticalObserved, opticalValid, rx1Available, rx2Available;
        private DateTime opticalAt;
        private int consecutiveDown;
        private bool stopRequired, faultLatched, wasConnected;
        private string faultReason;
        private uint baselineRun, sampleRun;
        private ulong baselineBits, baselineErrors;
        private bool hasBaseline;
        private double? intervalBer;
        private DateTime baselineAt, berAt, sampleAt;
        private byte[] sampleBytes = new byte[0];

        public RfBackupCoordinator(LinkController controller, Func<DateTime> clock = null)
        {
            if (controller == null) throw new ArgumentNullException(nameof(controller));
            this.controller = controller;
            this.clock = clock ?? (() => DateTime.UtcNow);
            wasConnected = controller.Connected;
            controller.Measurement += OnMeasurement;
            controller.SampleReceived += OnSample;
        }

        private bool SupportedOpticalMode
        {
            get { return opticalMode == RfOpticalMode.Diversity || opticalMode == RfOpticalMode.SpatialMultiplexing; }
        }

        private bool ContextAllowsRf { get { return armed && SupportedOpticalMode && !sweeping && config != null; } }

        private bool OpticalServiceAvailable
        {
            get
            {
                return opticalMode == RfOpticalMode.Diversity ? rx1Available || rx2Available :
                    opticalMode == RfOpticalMode.SpatialMultiplexing && rx1Available && rx2Available;
            }
        }
        private bool Fresh(DateTime at, double seconds)
        {
            double age = (clock() - at).TotalSeconds;
            return age >= 0 && age <= seconds;
        }

        public bool Requested
        {
            get
            {
                return ContextAllowsRf && !faultLatched && opticalObserved && opticalValid &&
                    Fresh(opticalAt, 3.0) && !OpticalServiceAvailable && consecutiveDown >= 2;
            }
        }

        public bool UsingRf { get { return Requested && controller.Running; } }

        /// <summary>Received-payload BER for the latest measured RF interval, not run-total or PHY BER.</summary>
        public string BerText
        {
            get
            {
                return UsingRf && hasBaseline && baselineRun == controller.Run && intervalBer.HasValue && Fresh(berAt, 2.5)
                    ? intervalBer.Value.ToString("0.000E+0", CultureInfo.InvariantCulture) : "N/A";
            }
        }

        /// <summary>A defensive copy of a real received sample, or an empty array when unavailable.</summary>
        public byte[] SampleBytes
        {
            get
            {
                return UsingRf && sampleRun == controller.Run && Fresh(sampleAt, 2.5)
                    ? (byte[])sampleBytes.Clone() : new byte[0];
            }
        }

        public string Status
        {
            get
            {
                if (faultLatched) return "RF fault — reconnect and rearm: " + faultReason;
                if (!armed) return "RF backup disarmed";
                if (sweeping) return "RF backup paused during sweep";
                if (!SupportedOpticalMode) return "RF backup standby — active DIV or SMP acquisition required";
                if (config == null) return "RF backup standby — configure the current data source";
                if (!opticalObserved) return "RF backup standby — waiting for valid FSO intervals";
                if (!opticalValid) return "FSO interval invalid — RF stop requested; recovery not confirmed";
                if (!Fresh(opticalAt, 3.0)) return "FSO telemetry stale — RF stop requested; recovery not confirmed";
                if (OpticalServiceAvailable) return "FSO available — RF standby / stopping";
                if (consecutiveDown < 2) return opticalMode == RfOpticalMode.SpatialMultiplexing
                    ? "Confirming an unavailable SMP lane" : "Confirming both FSO links unavailable";
                return controller.Status;
            }
        }

        public void ConfigureRun(RunConfig config)
        {
            if (config == null) throw new ArgumentNullException(nameof(config));
            this.config = config;
            InvalidateOptical();
        }

        public void SetContext(bool armed, bool diversityRunning, bool sweeping)
        {
            SetContext(armed, diversityRunning ? RfOpticalMode.Diversity : RfOpticalMode.None, sweeping);
        }

        public void SetContext(bool armed, RfOpticalMode mode, bool sweeping)
        {
            bool changed = this.armed != armed || opticalMode != mode || this.sweeping != sweeping;
            bool rearmed = !this.armed && armed;
            this.armed = armed;
            opticalMode = mode;
            this.sweeping = sweeping;
            if (rearmed) { faultLatched = false; faultReason = null; }
            if (changed) InvalidateOptical();
        }

        public void ObserveOptical(bool validInterval, bool rx1Available, bool rx2Available)
        {
            // Observations outside an eligible acquisition cannot arm a later run.
            if (!ContextAllowsRf) { InvalidateOptical(); return; }
            bool followsFreshValidPoll = opticalObserved && opticalValid && Fresh(opticalAt, 3.0);
            opticalObserved = true;
            opticalValid = validInterval;
            opticalAt = clock();
            this.rx1Available = rx1Available;
            this.rx2Available = rx2Available;
            if (!validInterval || OpticalServiceAvailable)
            {
                consecutiveDown = 0;
                RequireStop();
                ClearMeasurements();
            }
            else consecutiveDown = followsFreshValidPoll ? Math.Min(consecutiveDown + 1, 2) : 1;
        }

        public void Tick()
        {
            // Cancel receiver arming before its queued ACK can start the sender.
            // Once sender start was issued, first consume queued active state so
            // Stop can preserve the controller's final-count drainage exchange.
            if ((stopRequired || !Requested) && controller.Phase == LinkPhase.ArmingReceiver)
                controller.Stop();
            controller.Pump();
            if (controller.Phase == LinkPhase.Fault)
                LatchFault(String.IsNullOrEmpty(controller.Problem) ? "Controller fault" : controller.Problem);
            if (wasConnected && !controller.Connected && armed)
                LatchFault(String.IsNullOrEmpty(controller.Problem) ? "USB disconnected unexpectedly" : controller.Problem);
            wasConnected = controller.Connected;

            if (opticalObserved && opticalValid && !Fresh(opticalAt, 3.0))
            {
                consecutiveDown = 0;
                RequireStop();
                ClearMeasurements();
            }

            if (stopRequired || !Requested)
            {
                // Stop is an edge action: calling it repeatedly would renew its
                // timeout and replace control requests while final counts drain.
                if (NeedsStop()) controller.Stop();
                stopRequired = false;
                if (!Requested) ClearMeasurements();
                return;
            }

            if (controller.CanStart)
            {
                ClearMeasurements();
                controller.Start(config);
            }
        }

        private bool NeedsStop()
        {
            return controller.DesiredEnabled || controller.Phase == LinkPhase.ArmingReceiver ||
                controller.Phase == LinkPhase.StartingSender || controller.Phase == LinkPhase.Running;
        }

        private void RequireStop() { if (NeedsStop()) stopRequired = true; }

        private void InvalidateOptical()
        {
            RequireStop();
            opticalObserved = opticalValid = false;
            rx1Available = rx2Available = false;
            consecutiveDown = 0;
            ClearMeasurements();
        }

        private void LatchFault(string reason)
        {
            if (!faultLatched) faultReason = reason;
            faultLatched = true;
            consecutiveDown = 0;
            RequireStop();
            ClearMeasurements();
        }

        private void ClearMeasurements()
        {
            hasBaseline = false;
            baselineRun = sampleRun = 0;
            baselineBits = baselineErrors = 0;
            intervalBer = null;
            sampleBytes = new byte[0];
        }

        private void OnMeasurement(RunStats stats)
        {
            if (!Requested || stats == null || stats.Role != "AP" || stats.Run == 0 || stats.Run != controller.Run || stats.Phase != "LIVE")
            {
                hasBaseline = false;
                intervalBer = null;
                return;
            }
            ulong bits = stats.RxBits;
            intervalBer = null;
            if (hasBaseline && baselineRun == stats.Run && Fresh(baselineAt, 2.5) && bits >= baselineBits && stats.ErrorBits >= baselineErrors)
            {
                ulong addedBits = bits - baselineBits;
                ulong addedErrors = stats.ErrorBits - baselineErrors;
                if (addedBits > 0 && addedErrors <= addedBits)
                {
                    intervalBer = addedErrors / (double)addedBits;
                    berAt = clock();
                }
            }
            hasBaseline = true;
            baselineRun = stats.Run;
            baselineBits = bits;
            baselineErrors = stats.ErrorBits;
            baselineAt = clock();
        }

        private void OnSample(ReceivedSample sample)
        {
            if (!Requested || config == null || sample == null || sample.Run == 0 || sample.Run != controller.Run ||
                sample.Mode != config.Mode || sample.Bytes == null || sample.Bytes.Length == 0 || sample.Bytes.Length > 32) return;
            sampleRun = sample.Run;
            sampleAt = clock();
            sampleBytes = (byte[])sample.Bytes.Clone();
        }
    }
}
