using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Ports;
using System.Windows.Forms;
using RfProof;

namespace FSOCX86
{
    public partial class Form1
    {
        private LinkController rfLink;
        private RfBackupCoordinator rfBackup;
        private RunConfig rfRunConfig;
        private System.Windows.Forms.Timer rfPumpTimer;
        private ToolTip rfTip;
        private string rfReceiverPort = "COM4", rfSenderPort = "COM5";
        private string rfLastState;
        private bool rfSessionActive, rfTickBusy, rfDisposeStarted;
        private bool rfReleaseWhenOff, rfOwnedText, rfNeedsFreshFsoText;
        private TxCounterSnapshot rfPreviousOpticalSnapshot;

        private void InitializeRfBackup()
        {
            // Keep the existing checkbox clickable while its settings group is
            // disabled by Start. It stays in the same visual position.
            Point location = new Point(grpMimoSettings.Left + chkRf1Mbps.Left,
                grpMimoSettings.Top + chkRf1Mbps.Top);
            grpMimoSettings.Controls.Remove(chkRf1Mbps);
            tabPageMimo.Controls.Add(chkRf1Mbps);
            chkRf1Mbps.Location = location;
            chkRf1Mbps.BringToFront();
            chkRf1Mbps.Checked = false;
            chkRf1Mbps.Enabled = true;
            chkRf1Mbps.CheckedChanged += RfArmedChanged;

            var menu = new ContextMenuStrip(components);
            menu.Items.Add("RF USB ports...", null, delegate { ShowRfPortSettings(); });
            chkRf1Mbps.ContextMenuStrip = menu;
            rfTip = new ToolTip(components);
            colRfBer.ToolTipText = "Latest RF received-payload BER interval (not raw Wi-Fi BER). " +
                "N/A when OFF, stale, or no new received bits. Packet loss is separate in the MIMO log.";
            ReadRfPortSettings();
            UpdateRfTooltip();
            rfPumpTimer = new System.Windows.Forms.Timer(components);
            rfPumpTimer.Interval = 100;
            rfPumpTimer.Tick += delegate { TickRfBackup(); };
            rfPumpTimer.Start();
            Disposed += delegate { DisposeRfBackup(); };
        }

        private static string RfSettingsPath
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FSOCX86", "rf-backup-ports.txt"); }
        }

        private static bool IsRfPortName(string value)
        {
            uint number;
            return value != null && value.StartsWith("COM", StringComparison.OrdinalIgnoreCase) &&
                UInt32.TryParse(value.Substring(3), NumberStyles.None, CultureInfo.InvariantCulture, out number) && number > 0;
        }

        private void ReadRfPortSettings()
        {
            try
            {
                if (!File.Exists(RfSettingsPath)) return;
                string[] lines = File.ReadAllLines(RfSettingsPath);
                if (lines.Length == 2 && IsRfPortName(lines[0]) && IsRfPortName(lines[1]) &&
                    !lines[0].Equals(lines[1], StringComparison.OrdinalIgnoreCase))
                { rfReceiverPort = lines[0]; rfSenderPort = lines[1]; }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        private void ShowRfPortSettings()
        {
            if (chkRf1Mbps.Checked || (rfLink != null && rfLink.Connected))
            {
                MessageBox.Show(this, "Untick RF-1Mbps and wait for RF OFF before changing ports.", "RF USB ports");
                return;
            }
            using (var dialog = new Form())
            {
                dialog.Text = "RF backup USB ports";
                dialog.ClientSize = new Size(360, 175);
                dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                dialog.MaximizeBox = dialog.MinimizeBox = false;
                dialog.StartPosition = FormStartPosition.CenterParent;
                var rx = new ComboBox { Left = 175, Top = 18, Width = 155, Text = rfReceiverPort };
                var tx = new ComboBox { Left = 175, Top = 53, Width = 155, Text = rfSenderPort };
                try { string[] ports = SerialPort.GetPortNames(); Array.Sort(ports); rx.Items.AddRange(ports); tx.Items.AddRange(ports); }
                catch (Exception ex) { AddMimoLog("RF port listing: " + ex.Message); }
                dialog.Controls.Add(new Label { Left = 18, Top = 22, Width = 150, Text = "Receiver B (AP):" });
                dialog.Controls.Add(new Label { Left = 18, Top = 57, Width = 150, Text = "Sender A (STA):" });
                dialog.Controls.Add(new Label { Left = 18, Top = 90, Width = 320, Height = 30,
                    Text = "115200 baud. Close the separate RF GUI first.\nSettings do not flash or reprogram the ESP32s." });
                dialog.Controls.Add(rx); dialog.Controls.Add(tx);
                var save = new Button { Left = 175, Top = 132, Text = "Save", Width = 75 };
                var cancel = new Button { Left = 255, Top = 132, Text = "Cancel", Width = 75, DialogResult = DialogResult.Cancel };
                save.Click += delegate
                {
                    string receiver = rx.Text.Trim().ToUpperInvariant(), sender = tx.Text.Trim().ToUpperInvariant();
                    if (!IsRfPortName(receiver) || !IsRfPortName(sender) || receiver == sender)
                    { MessageBox.Show(dialog, "Enter two different COM ports, e.g. receiver COM4 and sender COM5."); return; }
                    try
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(RfSettingsPath));
                        File.WriteAllLines(RfSettingsPath, new[] { receiver, sender });
                    }
                    catch (Exception ex) { MessageBox.Show(dialog, "Could not save ports: " + ex.Message); return; }
                    rfReceiverPort = receiver; rfSenderPort = sender;
                    dialog.DialogResult = DialogResult.OK;
                };
                dialog.Controls.Add(save); dialog.Controls.Add(cancel);
                dialog.AcceptButton = save; dialog.CancelButton = cancel;
                dialog.ShowDialog(this);
            }
            UpdateRfTooltip();
        }

        private void UpdateRfTooltip()
        {
            if (rfTip == null) return;
            // Keep the checkbox and right-click port settings; no hover popup.
            rfTip.SetToolTip(chkRf1Mbps, String.Empty);
            rfTip.Active = false;
        }

        private void RfArmedChanged(object sender, EventArgs e)
        {
            if (rfDisposeStarted) return;
            if (chkRf1Mbps.Checked)
            {
                if (rfReleaseWhenOff && rfLink != null && rfLink.Connected &&
                    rfLink.Phase != LinkPhase.Off && rfLink.Phase != LinkPhase.Fault)
                {
                    AddMimoLog("RF is still stopping. Wait for OFF before rearming.");
                    chkRf1Mbps.Checked = false;
                    return;
                }
                // Explicit rearm is the only reconnect/retry after a serial fault.
                if (rfLink != null) rfLink.Dispose();
                rfLink = new LinkController(new SerialEndpoint(), new SerialEndpoint());
                rfBackup = new RfBackupCoordinator(rfLink);
                rfLink.Logged += entry => { if (!rfDisposeStarted) AddMimoLog("RF " + entry.Source + " | " + entry.Message); };
                rfLink.Measurement += ReportRfMeasurement;
                rfReleaseWhenOff = false;
                rfPreviousOpticalSnapshot = null;
                if (rfRunConfig != null)
                {
                    rfBackup.ConfigureRun(rfRunConfig);
                    rfSessionActive = txRunning && ActiveMimoRun;
                }
                try
                {
                    rfLink.Connect(rfReceiverPort, rfSenderPort);
                    AddMimoLog("RF armed: confirming ESP32 identities and OFF. Optical TX keeps running during backup.");
                }
                catch (Exception ex)
                {
                    AddMimoLog("RF connection failed: " + ex.Message + ". Check ports / close the separate RF GUI, then re-tick RF-1Mbps.");
                    chkRf1Mbps.Checked = false;
                }
            }
            else
            {
                rfReleaseWhenOff = true;
                if (rfBackup != null) rfBackup.SetContext(false, false, false);
                AddMimoLog("RF disarmed. Requesting OFF; ports release after stop confirmation (or timeout).");
            }
            TickRfBackup();
        }

        internal static RunConfig CreateRfRunConfig(byte dataCommand, string text)
        {
            SourceMode mode;
            switch ((char)dataCommand)
            {
                case 'A': mode = SourceMode.PRBS7; break;
                case 'B': mode = SourceMode.PRBS15; break;
                case 'C': mode = SourceMode.AsciiS; break;
                case 'D': mode = SourceMode.Counter; break;
                case 'U': mode = SourceMode.UserText; break;
                default: throw new ArgumentException("Unsupported RF data source.");
            }
            return new RunConfig(mode, mode == SourceMode.UserText ? text : "");
        }

        private void BeginRfMimoSession(byte dataCommand, string runText)
        {
            rfRunConfig = CreateRfRunConfig(dataCommand, runText);
            rfSessionActive = true;
            rfNeedsFreshFsoText = false;
            rfPreviousOpticalSnapshot = null;
            if (rfBackup != null) rfBackup.ConfigureRun(rfRunConfig);
            TickRfBackup();
        }

        private void StopRfSession()
        {
            rfSessionActive = false;
            rfRunConfig = null;
            rfPreviousOpticalSnapshot = null;
            if (rfBackup != null) rfBackup.SetContext(chkRf1Mbps.Checked, false, false);
            TickRfBackup();
        }

        private void InvalidateRfOptical()
        {
            rfPreviousOpticalSnapshot = null;
            if (rfBackup != null) rfBackup.ObserveOptical(false, false, false);
            TickRfBackup();
        }

        private RfOpticalMode CurrentRfOpticalMode
        {
            get
            {
                if (!rfSessionActive || !txRunning || !isConnected || usb == null || !usb.IsOpen)
                    return RfOpticalMode.None;
                if (activeSmpRun && !activeDiversityRun) return RfOpticalMode.SpatialMultiplexing;
                if (activeDiversityRun && !activeSmpRun) return RfOpticalMode.Diversity;
                return RfOpticalMode.None;
            }
        }

        // A displayed N/A or zero BER is not a link-state signal. Use a coherent
        // same-run snapshot, supported mode, lock flags and newly checked bits.
        // This RF-only plausibility guard never changes optical BER arithmetic.
        private void ObserveRfSnapshot(TxCounterSnapshot snapshot,
            bool ready1, uint bits1, uint errors1, bool ready2, uint bits2, uint errors2)
        {
            if (rfBackup == null) return;
            TxCounterSnapshot previous = rfPreviousOpticalSnapshot;
            rfPreviousOpticalSnapshot = snapshot;
            TxTimingWindow timing;
            string reason;
            byte flags = (byte)(snapshot.Status >> 8);
            byte expectedMode = activeSmpRun ? MIMO_MODE_SMP : MIMO_MODE_DIVERSITY;
            bool valid = ready1 && ready2 && SameCounterRun(previous, snapshot) &&
                snapshot.HasModeEpoch && snapshot.ActiveMode == expectedMode &&
                (flags & 0x1D) == 0x15 &&
                ((flags & 0x40) != 0) == (expectedMode == MIMO_MODE_DIVERSITY) &&
                errors1 <= bits1 && errors2 <= bits2;
            if (valid && TxTimingWindow.TryCreate(previous, snapshot, out timing, out reason))
            {
                double span = (snapshot.ReadEnded - snapshot.ReadStarted) /
                    (double)System.Diagnostics.Stopwatch.Frequency;
                double maximumBits = TxTimingWindow.NominalMbps(snapshot.Status) * 1000000.0 *
                    (timing.Seconds + timing.HostTimingAllowance) * 1.25 + 65536.0;
                valid = timing.Seconds <= 3.0 && span <= 1.0 &&
                    bits1 <= maximumBits && bits2 <= maximumBits;
            }
            else valid = false;
            ObserveRfOptical(valid, (flags & 0x02) != 0 && bits1 > 0,
                (flags & 0x20) != 0 && bits2 > 0);
        }

        private void ObserveRfOptical(bool valid, bool link1Available, bool link2Available)
        {
            if (rfBackup == null) return;
            rfBackup.SetContext(chkRf1Mbps.Checked, CurrentRfOpticalMode, phaseSweepRunning);
            rfBackup.ObserveOptical(valid, link1Available, link2Available);
            TickRfBackup();
        }

        private string RfBerForRow()
        { return rfBackup == null ? (chkRf1Mbps.Checked ? "N/A" : "Disabled") : rfBackup.BerText; }

        private string RfOutputForRow(string selectedFso)
        {
            if (rfBackup != null && rfBackup.Requested)
                return rfBackup.UsingRf ? "RF 1Mbps" : "RF pending";
            return selectedFso;
        }

        private void TickRfBackup()
        {
            if (rfDisposeStarted || rfTickBusy || rfBackup == null || rfLink == null) return;
            rfTickBusy = true;
            try
            {
                rfBackup.SetContext(chkRf1Mbps.Checked, CurrentRfOpticalMode, phaseSweepRunning);
                rfBackup.Tick();
                if (rfReleaseWhenOff && (rfLink.Phase == LinkPhase.Off || rfLink.Phase == LinkPhase.Fault || !rfLink.Connected))
                { rfLink.Disconnect(); rfReleaseWhenOff = false; }
                if (rfLastState != rfBackup.Status)
                { rfLastState = rfBackup.Status; AddMimoLog("RF BACKUP | " + rfLastState); }
                bool owns = rfBackup.Requested && CurrentRfOpticalMode != RfOpticalMode.None;
                if (rfOwnedText && !owns)
                {
                    MMOtxtRxMessage.Clear();
                    rfNeedsFreshFsoText = true;
                    AddMimoLog("RF released Output. Reacquiring fresh FSO text using the V3.1 snapshot protocol.");
                }
                rfOwnedText = owns;
                if (owns) PresentRfText();
                UpdateRfTooltip();
            }
            catch (Exception ex)
            {
                // Preserve the fresh-DIV-bank barrier even on exceptional
                // release; the FPGA may still hold the pre-RF text block.
                if (rfOwnedText) rfNeedsFreshFsoText = true;
                AddMimoLog("RF control exception: " + ex.Message + ". RF OFF requested; untick/re-tick to retry.");
                rfLink.Disconnect();
                rfSessionActive = false;
                rfOwnedText = false;
                MMOtxtRxMessage.Clear();
            }
            finally { rfTickBusy = false; }
        }

        private void PresentRfText()
        {
            if (rfRunConfig == null || rfRunConfig.Mode != SourceMode.UserText) return;
            byte[] bytes = rfBackup.SampleBytes;
            MMOtxtRxMessage.Text = bytes.Length > 0 ? FormatVisibleReceivedText(bytes, bytes.Length) :
                (rfBackup.UsingRf ? "[RF: waiting for fresh received text]" : "[RF backup: " + rfBackup.Status + "]");
        }

        private bool TryPresentRfText()
        {
            if (rfBackup == null || !rfBackup.Requested || CurrentRfOpticalMode == RfOpticalMode.None)
                return false;
            PresentRfText();
            return true;
        }

        private void RefreshRfAwareDiversityText(TxCounterSnapshot snapshot)
        {
            if (!IsMimoFreeTextSelected() || TryPresentRfText()) return;
            uint? epoch = snapshot.HasModeEpoch ? (uint?)snapshot.ModeEpoch : null;
            if (rfNeedsFreshFsoText && GetTextLinkProblem(snapshot.Status, true) == null)
            {
                // R53 freezes the existing bank, THEN rearms capture. Discard
                // that first acknowledged bank; it can contain pre-RF bytes.
                // The second normal read below sees only the rearmed capture.
                // Never use the obsolete ID17 shortcut or reset TX/BER/tuning.
                byte[] discarded;
                string reason;
                if (!TryReadV23RxText(epoch, out discarded, out reason))
                {
                    MMOtxtRxMessage.Text = "[FSO: waiting for a fresh post-RF capture]";
                    AddMimoLog("RF return: discard/rearm pending | " + reason);
                    return;
                }
                rfNeedsFreshFsoText = false;
                AddMimoLog("RF return: discarded the pre-return DIV bank; reading fresh received bytes.");
            }
            // SMP bypasses this helper: its unchanged R39 reader already starts
            // a new capture, then verifies token/epoch and both paired lanes.
            ReadUserTextOutputWithStatus(MMOtxtRxMessage, snapshot.Status, true, epoch);
        }

        private void ReportRfMeasurement(RunStats stats)
        {
            if (rfDisposeStarted || rfBackup == null || !rfBackup.Requested || stats.Role != "AP") return;
            // Packet loss is never counted as received-payload BER or optical ABER.
            AddMimoLog("RF RX | run=" + stats.Run.ToString(CultureInfo.InvariantCulture) +
                " | received=" + stats.Unique.ToString("N0", CultureInfo.InvariantCulture) +
                " packets | loss(total)=" + (stats.Loss.HasValue ? stats.Loss.Value.ToString("0.000", CultureInfo.InvariantCulture) + "%" : "N/A") +
                " | interval payload BER=" + rfBackup.BerText + " | RX=" +
                (stats.RxBps / 1000000.0).ToString("0.000", CultureInfo.InvariantCulture) + " Mbps");
        }

        private void DisposeRfBackup()
        {
            if (rfDisposeStarted) return;
            rfDisposeStarted = true;
            rfSessionActive = false;
            rfOwnedText = false;
            if (rfBackup != null) rfBackup.SetContext(false, false, false);
            if (rfPumpTimer != null) { rfPumpTimer.Stop(); rfPumpTimer.Dispose(); }
            if (rfLink != null) rfLink.Dispose();
        }
    }
}
