using System;

namespace FSOCX86
{
    // A coherent FPGA snapshot. The transport validates the firmware version,
    // echoed request token and status flags before calling Update(..., true).
    public sealed class DeliverySnapshot
    {
        public uint Token;
        public uint EpochMode;
        public uint Flags;
        public ulong Ticks;
        public ulong RetiredTicks;
        public ulong ExpectedBlocks;
        public ulong CompleteBlocks;
        public ulong GoodBlocks;
        public ulong ComparedBits;
        public ulong ErrorBits;
        public ulong Rx1LineBits;
        public ulong Rx2LineBits;

        public int Mode { get { return (int)(EpochMode & 3U); } }
        public uint Epoch { get { return EpochMode >> 2; } }

        internal DeliverySnapshot Copy()
        {
            return (DeliverySnapshot)MemberwiseClone();
        }
    }

    public enum DeliveryMetricsState { Unavailable, Baseline, Valid }

    // Null means unavailable or undefined, never an invented zero. A valid
    // offered interval with no received payload has measured zero goodput and
    // delivery, while its output BER is undefined because no bits were checked.
    public sealed class DeliveryMetricsResult
    {
        public DeliveryMetricsState State { get; private set; }
        public string Reason { get; private set; }
        public int Mode { get; private set; }
        public uint Epoch { get; private set; }
        public bool IsValid { get { return State == DeliveryMetricsState.Valid; } }
        public double? OutputBer { get; private set; }
        public double? GoodputMbps { get; private set; }
        public double? DeliveryPercent { get; private set; }
        public double? Rx1Mbps { get; private set; }
        public double? Rx2Mbps { get; private set; }
        public double? ReceiveThroughputMbps { get; private set; }
        public double Seconds { get; private set; }
        public double WallSeconds { get; private set; }
        public ulong DeltaTicks { get; private set; }
        public ulong DeltaRetiredTicks { get; private set; }
        public ulong DeltaExpectedBlocks { get; private set; }
        public ulong DeltaCompleteBlocks { get; private set; }
        public ulong DeltaGoodBlocks { get; private set; }
        public ulong DeltaComparedBits { get; private set; }
        public ulong DeltaErrorBits { get; private set; }
        public ulong DeltaRx1LineBits { get; private set; }
        public ulong DeltaRx2LineBits { get; private set; }

        internal DeliveryMetricsResult(DeliveryMetricsState state, string reason,
            DeliverySnapshot sample)
        {
            State = state;
            Reason = reason;
            Mode = sample == null ? -1 : sample.Mode;
            Epoch = sample == null ? 0U : sample.Epoch;
        }

        internal DeliveryMetricsResult(DeliverySnapshot sample, ulong ticks,
            ulong retiredTicks, ulong expected, ulong complete, ulong good,
            ulong compared, ulong errors, ulong rx1, ulong rx2)
            : this(DeliveryMetricsState.Valid, "Measured FPGA interval.", sample)
        {
            DeltaTicks = ticks;
            DeltaRetiredTicks = retiredTicks;
            DeltaExpectedBlocks = expected;
            DeltaCompleteBlocks = complete;
            DeltaGoodBlocks = good;
            DeltaComparedBits = compared;
            DeltaErrorBits = errors;
            DeltaRx1LineBits = rx1;
            DeltaRx2LineBits = rx2;
            Seconds = retiredTicks / DeliveryMetricsCalculator.ClockFrequency;
            WallSeconds = ticks / DeliveryMetricsCalculator.ClockFrequency;
            OutputBer = compared == 0 ? (double?)null : errors / (double)compared;
            // Convert to double before multiplying: raw 64-bit counters can wrap,
            // but rate arithmetic must never overflow an integer intermediate.
            GoodputMbps = good * 256.0 / Seconds / 1000000.0;
            DeliveryPercent = expected == 0 ? (double?)null : good * 100.0 / expected;
            Rx1Mbps = rx1 / WallSeconds / 1000000.0;
            Rx2Mbps = rx2 / WallSeconds / 1000000.0;
            // SMP adds both measured line rates after conversion to double.
            // DIV uses the current snapshot's selected lane for the entire
            // interval, including time it may have been unselected. This is
            // a selected-lane interval rate, not frame-exact output throughput;
            // identical endpoint selections cannot reveal switch-and-return.
            ReceiveThroughputMbps = sample.Mode == 2 ? Rx1Mbps + Rx2Mbps :
                sample.Mode == 1 && (sample.Flags & 0x10U) != 0 ? Rx2Mbps : Rx1Mbps;
        }
    }

    public sealed class DeliveryMetricsCalculator
    {
        public const double ClockFrequency = 250000000.0;
        public const ulong MaximumRetirementLagTicks = 1250000UL; // 5 ms.
        private readonly double maxGapSeconds;
        private readonly double singleStreamMaxBitsPerSecond;
        private readonly double multiplexedMaxBitsPerSecond;
        private readonly double receiverMaxBitsPerSecond;
        private DeliverySnapshot previous;

        public DeliveryMetricsCalculator(double maxGapSeconds = 10.0,
            double singleStreamMaxBitsPerSecond = 50000000.0,
            double multiplexedMaxBitsPerSecond = 100000000.0,
            double receiverMaxBitsPerSecond = 50000000.0)
        {
            RequirePositiveFinite(maxGapSeconds, "maxGapSeconds");
            RequirePositiveFinite(singleStreamMaxBitsPerSecond, "singleStreamMaxBitsPerSecond");
            RequirePositiveFinite(multiplexedMaxBitsPerSecond, "multiplexedMaxBitsPerSecond");
            RequirePositiveFinite(receiverMaxBitsPerSecond, "receiverMaxBitsPerSecond");
            if (maxGapSeconds < 1.0 / ClockFrequency ||
                maxGapSeconds > (UInt64.MaxValue / ClockFrequency) / 2.0)
                throw new ArgumentOutOfRangeException("maxGapSeconds");
            if (Double.IsInfinity(maxGapSeconds * Math.Max(receiverMaxBitsPerSecond,
                Math.Max(singleStreamMaxBitsPerSecond, multiplexedMaxBitsPerSecond))))
                throw new ArgumentOutOfRangeException("maxGapSeconds", "Configured interval bounds overflow.");
            this.maxGapSeconds = maxGapSeconds;
            this.singleStreamMaxBitsPerSecond = singleStreamMaxBitsPerSecond;
            this.multiplexedMaxBitsPerSecond = multiplexedMaxBitsPerSecond;
            this.receiverMaxBitsPerSecond = receiverMaxBitsPerSecond;
        }

        public void Reset()
        {
            previous = null;
        }

        public DeliveryMetricsResult Update(DeliverySnapshot snapshot, bool snapshotValid)
        {
            if (!snapshotValid || snapshot == null)
                return Reject(snapshot, "FPGA snapshot unavailable or invalid.", false);
            if (snapshot.Mode > 2)
                return Reject(snapshot, "Unsupported FPGA mode.", false);

            // Unsigned differences also handle a real clock rollover, provided
            // the retirement timestamp remains within the bounded source lag.
            ulong lag = unchecked(snapshot.Ticks - snapshot.RetiredTicks);
            if (lag > MaximumRetirementLagTicks)
                return Reject(snapshot, "Retired-cohort timestamp is ahead of or too far behind the FPGA clock.", false);

            DeliverySnapshot current = snapshot.Copy();
            if (previous == null)
                return SetBaseline(current, "Waiting for a second coherent FPGA snapshot.");
            if (current.EpochMode != previous.EpochMode)
                return SetBaseline(current, "FPGA run epoch or mode changed; waiting for a new interval.");

            uint tokenAdvance = unchecked(current.Token - previous.Token);
            if (tokenAdvance == 0U || tokenAdvance >= 0x80000000U)
                return Reject(current, "Repeated or stale FPGA snapshot token.", false);

            ulong ticks = unchecked(current.Ticks - previous.Ticks);
            double wallSeconds = ticks / ClockFrequency;
            if (ticks == 0UL)
                return Reject(current, "FPGA clock did not advance; baseline restarted.", true);
            if (wallSeconds > maxGapSeconds)
                return Reject(current, "FPGA interval exceeds the maximum gap or the clock regressed; baseline restarted.", true);

            ulong retiredTicks = unchecked(current.RetiredTicks - previous.RetiredTicks);
            if (retiredTicks == 0UL || (double)retiredTicks > ticks + (double)MaximumRetirementLagTicks)
                return Reject(current, "Retired-cohort clock did not advance consistently; baseline restarted.", true);

            ulong expected = unchecked(current.ExpectedBlocks - previous.ExpectedBlocks);
            ulong complete = unchecked(current.CompleteBlocks - previous.CompleteBlocks);
            ulong good = unchecked(current.GoodBlocks - previous.GoodBlocks);
            ulong compared = unchecked(current.ComparedBits - previous.ComparedBits);
            ulong errors = unchecked(current.ErrorBits - previous.ErrorBits);
            ulong rx1 = unchecked(current.Rx1LineBits - previous.Rx1LineBits);
            ulong rx2 = unchecked(current.Rx2LineBits - previous.Rx2LineBits);
            double seconds = retiredTicks / ClockFrequency;
            double maxPayloadRate = current.Mode == 2 ? multiplexedMaxBitsPerSecond : singleStreamMaxBitsPerSecond;
            double maxBlocks = Math.Floor(maxPayloadRate * seconds / 256.0) + 4.0;
            double maxCompared = maxPayloadRate * seconds * 1.01 + 512.0;
            double maxLineBits = receiverMaxBitsPerSecond * wallSeconds * 1.01 + 512.0;

            // These are common retired source cohorts. Partial blocks, repeats,
            // duplicated receiver branches and line-code overhead add no blocks.
            // ComparedBits counts unique decoded positions in these same retired
            // cohorts, including partial blocks. It is measured, not inferred
            // from the number of complete blocks.
            if (good > complete || complete > expected || errors > compared)
                return Reject(current, "Inconsistent delivery or error counters; baseline restarted.", true);
            if ((double)expected > maxBlocks || (double)compared > maxCompared ||
                (double)rx1 > maxLineBits || (double)rx2 > maxLineBits)
                return Reject(current, "Counter jump exceeds physical rate bounds or a counter regressed; baseline restarted.", true);
            ulong wholeComparedBlocks = compared / 256UL;
            if (complete > wholeComparedBlocks || wholeComparedBlocks > expected ||
                (wholeComparedBlocks == expected && compared % 256UL != 0UL))
                return Reject(current, "Checked bits are inconsistent with the retired 32-byte cohorts; baseline restarted.", true);
            // The preceding quotient check guarantees good * 256 cannot
            // overflow. Every good block consumes 256 error-free checked bits.
            if (errors > compared - good * 256UL)
                return Reject(current, "Bit errors overlap payload reported as good; baseline restarted.", true);

            previous = current;
            return new DeliveryMetricsResult(current, ticks, retiredTicks, expected,
                complete, good, compared, errors, rx1, rx2);
        }

        private DeliveryMetricsResult SetBaseline(DeliverySnapshot snapshot, string reason)
        {
            previous = snapshot;
            return new DeliveryMetricsResult(DeliveryMetricsState.Baseline, reason, snapshot);
        }

        private DeliveryMetricsResult Reject(DeliverySnapshot snapshot, string reason, bool restart)
        {
            previous = restart && snapshot != null ? snapshot.Copy() : null;
            return new DeliveryMetricsResult(DeliveryMetricsState.Unavailable, reason, snapshot);
        }

        private static void RequirePositiveFinite(double value, string name)
        {
            if (Double.IsNaN(value) || Double.IsInfinity(value) || value <= 0.0)
                throw new ArgumentOutOfRangeException(name);
        }
    }
}
