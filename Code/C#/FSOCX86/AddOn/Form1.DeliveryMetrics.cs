using System;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace FSOCX86
{
    public partial class Form1
    {
        private const uint DELIVERY_FIRMWARE = 0x4D333302U;
        private const long DELIVERY_READ_BUDGET_MS = 2000;
        private DeliveryMetricsCalculator deliveryCalculator;
        private string lastDeliveryAvailability;
        private DeliverySnapshot deliveryDiagnosticPrevious;
        private StringBuilder deliveryReadTrace;

        private void ResetDeliveryMetrics()
        {
            if (deliveryCalculator != null) deliveryCalculator.Reset();
            lastDeliveryAvailability = null;
            deliveryDiagnosticPrevious = null;
            deliveryReadTrace = null;
        }

        // Preserve the supplied Designer and the original six cell positions.
        // Names, not display indices, identify the five new measurement cells.
        private void AddMeasuredMimoRow(TxCounterSnapshot optical,
            string time, string mode, string ber1, string ber2, string aber, string rfBer)
        {
            int index = dgvMimoBer.Rows.Add(time, mode, ber1, ber2, aber, rfBer);
            DataGridViewRow row = dgvMimoBer.Rows[index];
            SetAllDeliveryCells(row, "Unavailable");
            try
            {
                // All five optical measurement cells use one validated delivery
                // snapshot interval. Legacy RX counters remain in their existing
                // diagnostic log; never mix those into this delivery table.
                DeliverySnapshot measured;
                string reason;
                if (!TryReadDeliverySnapshot(optical, out measured, out reason))
                {
                    if (deliveryCalculator != null) deliveryCalculator.Reset();
                    deliveryDiagnosticPrevious = null;
                    LogDeliveryAvailability(WithDeliveryReadTrace(reason), true);
                    return;
                }
                if (deliveryCalculator == null) deliveryCalculator = new DeliveryMetricsCalculator();
                DeliveryMetricsResult result = deliveryCalculator.Update(measured, true);
                LogDeliveryEvaluation(measured, result);
                if (!result.IsValid)
                {
                    string text = result.State == DeliveryMetricsState.Baseline ? "Measuring..." : "Unavailable";
                    SetAllDeliveryCells(row, text);
                    return;
                }
                SetDeliveryCell(row, "Rx1", FormatDeliveryNumber(result.Rx1Mbps, "0.000"));
                SetDeliveryCell(row, "Rx2", FormatDeliveryNumber(result.Rx2Mbps, "0.000"));

                // These counters observe the optical reconstruction path only.
                // RF runs a different packet protocol; never relabel optical
                // counts or configured 1 Mbps as measured RF output delivery.
                bool rfOwnsOutput = rfBackup != null && rfBackup.Requested;
                SetDeliveryCell(row, "OBER", rfOwnsOutput ? "Unavailable (RF)" :
                    FormatDeliveryNumber(result.OutputBer, "0.000E+00"));
                SetDeliveryCell(row, "Throughput", rfOwnsOutput ? "Unavailable (RF)" :
                    FormatDeliveryNumber(result.ReceiveThroughputMbps, "0.000000"));
                if (dgvMimoBer.Columns.Contains("Throughput"))
                    row.Cells["Throughput"].ToolTipText = DescribeReceiveThroughput(measured);
                SetDeliveryCell(row, "Delivery", rfOwnsOutput ? "Unavailable (RF)" :
                    FormatDeliveryNumber(result.DeliveryPercent, "0.000000"));
                LogDeliveryResult(measured, result, rfOwnsOutput);
            }
            catch (Exception ex)
            {
                if (deliveryCalculator != null) deliveryCalculator.Reset();
                SetAllDeliveryCells(row, "Unavailable");
                deliveryDiagnosticPrevious = null;
                LogDeliveryAvailability(WithDeliveryReadTrace("measurement read exception: " + ex.Message), true);
                // Optional telemetry cannot stop existing optical/RF polling.
            }
            finally
            {
                if (rfBackup != null && rfBackup.Requested)
                {
                    SetDeliveryCell(row, "OBER", "Unavailable (RF)");
                    SetDeliveryCell(row, "Throughput", "Unavailable (RF)");
                    SetDeliveryCell(row, "Delivery", "Unavailable (RF)");
                }
            }
        }

        private void LogDeliveryResult(DeliverySnapshot measured, DeliveryMetricsResult result, bool rfOwnsOutput)
        {
            string message = "DELIVERY FSO | epoch/mode=" + measured.EpochMode.ToString("X8") +
                    " token=" + measured.Token.ToString(CultureInfo.InvariantCulture) +
                    " wallTicks=" + measured.Ticks.ToString(CultureInfo.InvariantCulture) +
                    " retiredTicks=" + measured.RetiredTicks.ToString(CultureInfo.InvariantCulture) +
                    " expected=" + measured.ExpectedBlocks.ToString(CultureInfo.InvariantCulture) +
                    " complete=" + measured.CompleteBlocks.ToString(CultureInfo.InvariantCulture) +
                    " good=" + measured.GoodBlocks.ToString(CultureInfo.InvariantCulture) +
                    " comparedBits=" + measured.ComparedBits.ToString(CultureInfo.InvariantCulture) +
                    " errorBits=" + measured.ErrorBits.ToString(CultureInfo.InvariantCulture) +
                    " rx1LineBits=" + measured.Rx1LineBits.ToString(CultureInfo.InvariantCulture) +
                    " rx2LineBits=" + measured.Rx2LineBits.ToString(CultureInfo.InvariantCulture) +
                    " | source=R90-R114 coherent FPGA delivery bank" +
                    " | RX1=" + FormatDeliveryNumber(result.Rx1Mbps, "0.000") +
                    " Mbps RX2=" + FormatDeliveryNumber(result.Rx2Mbps, "0.000") +
                    " Mbps (R107-R110 / wall interval)" +
                    " | receiveThroughput=" + FormatDeliveryNumber(result.ReceiveThroughputMbps, "0.000000") +
                    " Mbps | throughput basis=" + DescribeReceiveThroughput(measured) +
                    " | goodput=" + FormatDeliveryNumber(result.GoodputMbps, "0.000000") +
                    " Mbps | delivery=" + FormatDeliveryNumber(result.DeliveryPercent, "0.000000") +
                    "% | outputBER=" + FormatDeliveryNumber(result.OutputBer, "0.000E+00") +
                    " | output basis=retired source cohorts; no legacy RX fallback" +
                    (rfOwnsOutput ? " | optical-only counters; RF owns displayed text" : "");
            if (ActiveMimoRun) AddMimoLog(message); else AddLog(message);
        }

        private static string DescribeReceiveThroughput(DeliverySnapshot measured)
        {
            const string units = " Mbps of counted optical line bits over the coherent FPGA wall interval; includes coding overhead and erroneous counted bits.";
            if (measured.Mode == 2)
                return "SMP: RX1 + RX2." + units;
            if (measured.Mode == 1)
                return "DIV: current snapshot-selected " + ((measured.Flags & 0x10U) != 0 ? "RX2" : "RX1") +
                    " lane's interval rate." + units +
                    " Includes time the lane was unselected; not frame-exact output throughput. Equal endpoint selections cannot reveal switch-and-return.";
            return "SISO: RX1." + units;
        }

        private void LogMeasuredSisoDelivery(TxCounterSnapshot optical)
        {
            // The Data-tab layout is unchanged. SISO receives the same measured
            // source-cohort audit in its existing log, without adding MIMO rows.
            try
            {
                DeliverySnapshot measured;
                string reason;
                if (!TryReadDeliverySnapshot(optical, out measured, out reason))
                {
                    if (deliveryCalculator != null) deliveryCalculator.Reset();
                    deliveryDiagnosticPrevious = null;
                    LogDeliveryAvailability(WithDeliveryReadTrace(reason), true);
                    return;
                }
                if (deliveryCalculator == null) deliveryCalculator = new DeliveryMetricsCalculator();
                DeliveryMetricsResult result = deliveryCalculator.Update(measured, true);
                LogDeliveryEvaluation(measured, result);
                if (result.IsValid) LogDeliveryResult(measured, result, false);
            }
            catch (Exception ex)
            {
                if (deliveryCalculator != null) deliveryCalculator.Reset();
                deliveryDiagnosticPrevious = null;
                LogDeliveryAvailability(WithDeliveryReadTrace("measurement read exception: " + ex.Message), true);
            }
        }

        private static string FormatDeliveryNumber(double? value, string format)
        {
            return value.HasValue ? value.Value.ToString(format, CultureInfo.InvariantCulture) : "N/A";
        }

        private void SetDeliveryCell(DataGridViewRow row, string name, string value)
        {
            // Legacy six-column offline fixtures are also supported. The actual
            // supplied Designer contains all eleven columns and is unchanged.
            if (dgvMimoBer.Columns.Contains(name)) row.Cells[name].Value = value;
        }

        private void SetAllDeliveryCells(DataGridViewRow row, string value)
        {
            foreach (string name in new[] { "Rx1", "Rx2", "OBER", "Throughput", "Delivery" })
                SetDeliveryCell(row, name, value);
        }

        private void LogDeliveryAvailability(string reason, bool repeat = false)
        {
            if (!repeat && lastDeliveryAvailability == reason) return;
            lastDeliveryAvailability = reason;
            string message = "DELIVERY | source=R90-R114 coherent FPGA delivery bank | " + reason;
            if (ActiveMimoRun) AddMimoLog(message);
            else AddLog(message);
        }

        private string WithDeliveryReadTrace(string reason)
        {
            return reason + (deliveryReadTrace == null || deliveryReadTrace.Length == 0 ? "" :
                " | reads: " + deliveryReadTrace.ToString());
        }

        private void LogDeliveryEvaluation(DeliverySnapshot sample, DeliveryMetricsResult result)
        {
            string reason = result.Reason;
            if (!result.IsValid)
                reason += " | previous={" + DescribeDeliverySnapshot(deliveryDiagnosticPrevious) +
                    "} | current={" + DescribeDeliverySnapshot(sample) + "}";
            LogDeliveryAvailability(reason, !result.IsValid);
            deliveryDiagnosticPrevious = sample.Copy();
        }

        private static string DescribeDeliverySnapshot(DeliverySnapshot sample)
        {
            if (sample == null) return "none";
            return String.Format(CultureInfo.InvariantCulture,
                "token=0x{0:X8} epoch/mode=0x{1:X8} flags=0x{2:X8} ticks={3} retiredTicks={4} " +
                "expected={5} complete={6} good={7} comparedBits={8} errorBits={9} rx1LineBits={10} rx2LineBits={11}",
                sample.Token, sample.EpochMode, sample.Flags, sample.Ticks, sample.RetiredTicks,
                sample.ExpectedBlocks, sample.CompleteBlocks, sample.GoodBlocks, sample.ComparedBits,
                sample.ErrorBits, sample.Rx1LineBits, sample.Rx2LineBits);
        }

        private bool TryReadDeliverySnapshot(TxCounterSnapshot optical,
            out DeliverySnapshot snapshot, out string reason)
        {
            snapshot = null;
            reason = "delivery telemetry unavailable; the matching V3.3.2 FPGA measurement image is required";
            deliveryReadTrace = new StringBuilder();
            Stopwatch readBudget = Stopwatch.StartNew();
            uint magic;
            if (!ReadDeliveryWord(90, out magic, readBudget, ref reason)) return false;
            if (magic != DELIVERY_FIRMWARE)
            { reason = String.Format(CultureInfo.InvariantCulture,
                "R90 delivery signature mismatch: actual=0x{0:X8}, expected=0x{1:X8}; V3.3.2 FPGA measurement image required; check the programmed image/readback",
                magic, DELIVERY_FIRMWARE); return false; }
            if (optical == null || !optical.HasModeEpoch)
            { reason = "optical run epoch unavailable"; return false; }
            uint requested, completed = 0;
            if (!ReadDeliveryWord(91, out requested, readBudget, ref reason)) return false;
            bool ready = false;
            for (int attempt = 0; attempt < 8; attempt++)
            {
                if (!ReadDeliveryWord(92, out completed, readBudget, ref reason)) return false;
                if (completed == requested) { ready = true; break; }
                Thread.Sleep(1);
            }
            if (!ready) { reason = String.Format(CultureInfo.InvariantCulture,
                "delivery snapshot timed out: R91 requested=0x{0:X8}, R92 completed=0x{1:X8}",
                requested, completed); return false; }
            uint[] words = new uint[22];
            for (int i = 0; i < words.Length; i++)
                if (!ReadDeliveryWord((byte)(93 + i), out words[i], readBudget, ref reason)) return false;
            uint finalToken, finalEpoch;
            if (!ReadDeliveryWord(92, out finalToken, readBudget, ref reason) ||
                !ReadDeliveryWord(93, out finalEpoch, readBudget, ref reason)) return false;
            if (finalToken != requested || finalEpoch != words[0] || words[0] != optical.ModeEpoch)
            { reason = String.Format(CultureInfo.InvariantCulture,
                "delivery snapshot token/run changed during read: R91 requested=0x{0:X8} R92 completed=0x{1:X8} " +
                "finalToken=0x{2:X8} R93 bankEpoch=0x{3:X8} finalEpoch=0x{4:X8} opticalEpoch=0x{5:X8}",
                requested, completed, finalToken, words[0], finalEpoch, optical.ModeEpoch); return false; }
            if ((words[1] & 3U) != 3U || (words[0] & 3U) > MIMO_MODE_SMP)
            { reason = String.Format(CultureInfo.InvariantCulture,
                "delivery measurement stopped or unsupported: R94 flags=0x{0:X8}, R93 epoch/mode=0x{1:X8}; " +
                "manual board-test use requires a new Start/reset", words[1], words[0]); return false; }
            if ((words[1] & 0x20U) == 0)
            { reason = String.Format(CultureInfo.InvariantCulture,
                "delivery measurement collecting the first complete source cohort: R94 flags=0x{0:X8}, " +
                "ticks={1}, expected={2}", words[1], JoinDeliveryWords(words[2], words[3]),
                JoinDeliveryWords(words[4], words[5])); return false; }
            if (words[18] != 250000000U || words[19] != 32U)
            { reason = String.Format(CultureInfo.InvariantCulture,
                "delivery clock/block format mismatch: R111 clock={0} Hz (expected 250000000), " +
                "R112 block={1} bytes (expected 32)", words[18], words[19]); return false; }
            snapshot = new DeliverySnapshot
            {
                Token = requested, EpochMode = words[0], Flags = words[1],
                Ticks = JoinDeliveryWords(words[2], words[3]),
                ExpectedBlocks = JoinDeliveryWords(words[4], words[5]),
                CompleteBlocks = JoinDeliveryWords(words[6], words[7]),
                GoodBlocks = JoinDeliveryWords(words[8], words[9]),
                ComparedBits = JoinDeliveryWords(words[10], words[11]),
                ErrorBits = JoinDeliveryWords(words[12], words[13]),
                Rx1LineBits = JoinDeliveryWords(words[14], words[15]),
                Rx2LineBits = JoinDeliveryWords(words[16], words[17]),
                RetiredTicks = JoinDeliveryWords(words[20], words[21])
            };
            reason = "coherent optical delivery snapshot";
            return true;
        }

        private bool ReadDeliveryWord(byte id, out uint word, Stopwatch budget, ref string reason)
        {
            word = 0;
            if (budget.ElapsedMilliseconds > DELIVERY_READ_BUDGET_MS)
            { reason = "R" + id.ToString(CultureInfo.InvariantCulture) +
                " delivery USB read exceeded the 2 s freshness budget"; return false; }
            // Native synchronous I/O cannot be cancelled here. Reject an old
            // bank as soon as the call returns, even if it reports success.
            bool success;
            try { success = ReadStatusWordRaw(id, out word); }
            catch (Exception ex)
            { reason = "R" + id.ToString(CultureInfo.InvariantCulture) + " USB status exception: " + ex.Message; return false; }
            if (deliveryReadTrace != null)
            {
                if (deliveryReadTrace.Length != 0) deliveryReadTrace.Append(" ");
                deliveryReadTrace.Append("R").Append(id.ToString(CultureInfo.InvariantCulture)).Append("=")
                    .Append(success ? "0x" + word.ToString("X8", CultureInfo.InvariantCulture) : "FAILED");
            }
            if (budget.ElapsedMilliseconds > DELIVERY_READ_BUDGET_MS)
            { reason = "R" + id.ToString(CultureInfo.InvariantCulture) +
                " delivery USB read exceeded the 2 s freshness budget"; return false; }
            if (!success)
                reason = "R" + id.ToString(CultureInfo.InvariantCulture) +
                    " USB status read/write failed; see Data log for FT601 status/byte count";
            return success;
        }

        private static ulong JoinDeliveryWords(uint low, uint high)
        { return ((ulong)high << 32) | low; }
    }
}
