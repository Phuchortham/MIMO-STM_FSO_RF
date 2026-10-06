namespace FSOCX86
{
    partial class Form1
    {
        /// <summary>
        /// Required designer variable.
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary>
        /// Clean up any resources being used.
        /// </summary>
        /// <param name="disposing">true if managed resources should be disposed; otherwise, false.</param>
        protected override void Dispose(bool disposing)
        {
            if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
        }

        #region Windows Form Designer generated code

        /// <summary>
        /// Required method for Designer support - do not modify
        /// the contents of this method with the code editor.
        /// </summary>
        private void InitializeComponent()
        {
            System.ComponentModel.ComponentResourceManager resources = new System.ComponentModel.ComponentResourceManager(typeof(Form1));
            this.btnConnect = new System.Windows.Forms.Button();
            this.btnLedOn = new System.Windows.Forms.Button();
            this.btnLedOff = new System.Windows.Forms.Button();
            this.btnLedAA = new System.Windows.Forms.Button();
            this.btnLed55 = new System.Windows.Forms.Button();
            this.btnClose = new System.Windows.Forms.Button();
            this.lblStatus = new System.Windows.Forms.Label();
            this.tabMain = new System.Windows.Forms.TabControl();
            this.tabData = new System.Windows.Forms.TabPage();
            this.btnResetCSV = new System.Windows.Forms.Button();
            this.btnExportTable = new System.Windows.Forms.Button();
            this.dataGridView1 = new System.Windows.Forms.DataGridView();
            this.Time = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.Setting = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.BER = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.grpLinkQuality = new System.Windows.Forms.GroupBox();
            this.lblThroughput = new System.Windows.Forms.Label();
            this.lblRxBits = new System.Windows.Forms.Label();
            this.lblTotalBits = new System.Windows.Forms.Label();
            this.lblErrorBits = new System.Windows.Forms.Label();
            this.lblBER = new System.Windows.Forms.Label();
            this.Reset_data = new System.Windows.Forms.Button();
            this.label13 = new System.Windows.Forms.Label();
            this.label12 = new System.Windows.Forms.Label();
            this.label11 = new System.Windows.Forms.Label();
            this.label10 = new System.Windows.Forms.Label();
            this.label9 = new System.Windows.Forms.Label();
            this.grpUserText = new System.Windows.Forms.GroupBox();
            this.txtRxMessage = new System.Windows.Forms.RichTextBox();
            this.label8 = new System.Windows.Forms.Label();
            this.label7 = new System.Windows.Forms.Label();
            this.txtTxMessage = new System.Windows.Forms.TextBox();
            this.txtLog = new System.Windows.Forms.RichTextBox();
            this.grpSetting = new System.Windows.Forms.GroupBox();
            this.cmbMod = new System.Windows.Forms.ComboBox();
            this.cmbBitRate = new System.Windows.Forms.ComboBox();
            this.cmbCode = new System.Windows.Forms.ComboBox();
            this.cmbDataType = new System.Windows.Forms.ComboBox();
            this.label6 = new System.Windows.Forms.Label();
            this.label5 = new System.Windows.Forms.Label();
            this.label4 = new System.Windows.Forms.Label();
            this.label3 = new System.Windows.Forms.Label();
            this.grpUsb = new System.Windows.Forms.Panel();
            this.label2 = new System.Windows.Forms.Label();
            this.tabPageMimo = new System.Windows.Forms.TabPage();
            this.label19 = new System.Windows.Forms.Label();
            this.label14 = new System.Windows.Forms.Label();
            this.MMOtxtRxMessage = new System.Windows.Forms.RichTextBox();
            this.MIMOtxtTxMessage = new System.Windows.Forms.TextBox();
            this.btnMimoExportCsv = new System.Windows.Forms.Button();
            this.btnMimoResetCsv = new System.Windows.Forms.Button();
            this.txtMimoLog = new System.Windows.Forms.RichTextBox();
            this.grpMimoSettings = new System.Windows.Forms.GroupBox();
            this.cmbMimoModulation = new System.Windows.Forms.ComboBox();
            this.cmbMimoCoding = new System.Windows.Forms.ComboBox();
            this.chkRf1Mbps = new System.Windows.Forms.CheckBox();
            this.cmbMimoMode = new System.Windows.Forms.ComboBox();
            this.label22 = new System.Windows.Forms.Label();
            this.cmbMimoBitRate = new System.Windows.Forms.ComboBox();
            this.cmbMimoDataType = new System.Windows.Forms.ComboBox();
            this.label15 = new System.Windows.Forms.Label();
            this.label16 = new System.Windows.Forms.Label();
            this.label17 = new System.Windows.Forms.Label();
            this.label18 = new System.Windows.Forms.Label();
            this.dgvMimoBer = new System.Windows.Forms.DataGridView();
            this.pnlMimoUsb = new System.Windows.Forms.Panel();
            this.label1 = new System.Windows.Forms.Label();
            this.btnMimoConnect = new System.Windows.Forms.Button();
            this.btnMimoClose = new System.Windows.Forms.Button();
            this.lblMimoUsbStatus = new System.Windows.Forms.Label();
            this.lblTime = new System.Windows.Forms.Label();
            this.btnStartTX = new System.Windows.Forms.Button();
            this.btnStopTX = new System.Windows.Forms.Button();
            this.colMimoTime = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.colMimoMode = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.colFsoBer1 = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.colFsoBer2 = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.colFsoAber = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.colRfBer = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.Rx1 = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.Rx2 = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.OBER = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.Throughput = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.Delivery = new System.Windows.Forms.DataGridViewTextBoxColumn();
            this.tabMain.SuspendLayout();
            this.tabData.SuspendLayout();
            ((System.ComponentModel.ISupportInitialize)(this.dataGridView1)).BeginInit();
            this.grpLinkQuality.SuspendLayout();
            this.grpUserText.SuspendLayout();
            this.grpSetting.SuspendLayout();
            this.grpUsb.SuspendLayout();
            this.tabPageMimo.SuspendLayout();
            this.grpMimoSettings.SuspendLayout();
            ((System.ComponentModel.ISupportInitialize)(this.dgvMimoBer)).BeginInit();
            this.pnlMimoUsb.SuspendLayout();
            this.SuspendLayout();
            // 
            // btnConnect
            // 
            this.btnConnect.Location = new System.Drawing.Point(96, 7);
            this.btnConnect.Name = "btnConnect";
            this.btnConnect.Size = new System.Drawing.Size(75, 23);
            this.btnConnect.TabIndex = 0;
            this.btnConnect.Text = "Connect";
            this.btnConnect.UseVisualStyleBackColor = true;
            this.btnConnect.Click += new System.EventHandler(this.btnConnect_Click);
            // 
            // btnLedOn
            // 
            this.btnLedOn.Location = new System.Drawing.Point(113, 447);
            this.btnLedOn.Name = "btnLedOn";
            this.btnLedOn.Size = new System.Drawing.Size(75, 23);
            this.btnLedOn.TabIndex = 1;
            this.btnLedOn.Text = "LED ON";
            this.btnLedOn.UseVisualStyleBackColor = true;
            this.btnLedOn.Visible = false;
            this.btnLedOn.Click += new System.EventHandler(this.btnLedOn_Click);
            // 
            // btnLedOff
            // 
            this.btnLedOff.Location = new System.Drawing.Point(194, 447);
            this.btnLedOff.Name = "btnLedOff";
            this.btnLedOff.Size = new System.Drawing.Size(75, 23);
            this.btnLedOff.TabIndex = 2;
            this.btnLedOff.Text = "LED OFF";
            this.btnLedOff.UseVisualStyleBackColor = true;
            this.btnLedOff.Visible = false;
            this.btnLedOff.Click += new System.EventHandler(this.btnLedOff_Click);
            // 
            // btnLedAA
            // 
            this.btnLedAA.Location = new System.Drawing.Point(275, 447);
            this.btnLedAA.Name = "btnLedAA";
            this.btnLedAA.Size = new System.Drawing.Size(75, 23);
            this.btnLedAA.TabIndex = 3;
            this.btnLedAA.Text = "LED AA";
            this.btnLedAA.UseVisualStyleBackColor = true;
            this.btnLedAA.Visible = false;
            this.btnLedAA.Click += new System.EventHandler(this.btnLedAA_Click);
            // 
            // btnLed55
            // 
            this.btnLed55.Location = new System.Drawing.Point(356, 447);
            this.btnLed55.Name = "btnLed55";
            this.btnLed55.Size = new System.Drawing.Size(75, 23);
            this.btnLed55.TabIndex = 4;
            this.btnLed55.Text = "LED 55";
            this.btnLed55.UseVisualStyleBackColor = true;
            this.btnLed55.Visible = false;
            this.btnLed55.Click += new System.EventHandler(this.btnLed55_Click);
            // 
            // btnClose
            // 
            this.btnClose.Location = new System.Drawing.Point(177, 7);
            this.btnClose.Name = "btnClose";
            this.btnClose.Size = new System.Drawing.Size(76, 23);
            this.btnClose.TabIndex = 5;
            this.btnClose.Text = "Close";
            this.btnClose.UseVisualStyleBackColor = true;
            this.btnClose.Click += new System.EventHandler(this.btnClose_Click);
            // 
            // lblStatus
            // 
            this.lblStatus.AutoSize = true;
            this.lblStatus.Location = new System.Drawing.Point(13, 21);
            this.lblStatus.Name = "lblStatus";
            this.lblStatus.Size = new System.Drawing.Size(37, 13);
            this.lblStatus.TabIndex = 6;
            this.lblStatus.Text = "Status";
            // 
            // tabMain
            // 
            this.tabMain.Controls.Add(this.tabData);
            this.tabMain.Controls.Add(this.tabPageMimo);
            this.tabMain.Location = new System.Drawing.Point(12, 12);
            this.tabMain.Name = "tabMain";
            this.tabMain.SelectedIndex = 0;
            this.tabMain.Size = new System.Drawing.Size(711, 429);
            this.tabMain.TabIndex = 7;
            // 
            // tabData
            // 
            this.tabData.Controls.Add(this.btnResetCSV);
            this.tabData.Controls.Add(this.btnExportTable);
            this.tabData.Controls.Add(this.dataGridView1);
            this.tabData.Controls.Add(this.grpLinkQuality);
            this.tabData.Controls.Add(this.grpUserText);
            this.tabData.Controls.Add(this.txtLog);
            this.tabData.Controls.Add(this.grpSetting);
            this.tabData.Controls.Add(this.grpUsb);
            this.tabData.Location = new System.Drawing.Point(4, 22);
            this.tabData.Name = "tabData";
            this.tabData.Padding = new System.Windows.Forms.Padding(3);
            this.tabData.Size = new System.Drawing.Size(703, 403);
            this.tabData.TabIndex = 0;
            this.tabData.Text = "Data";
            this.tabData.UseVisualStyleBackColor = true;
            // 
            // btnResetCSV
            // 
            this.btnResetCSV.Location = new System.Drawing.Point(535, 194);
            this.btnResetCSV.Name = "btnResetCSV";
            this.btnResetCSV.Size = new System.Drawing.Size(75, 23);
            this.btnResetCSV.TabIndex = 15;
            this.btnResetCSV.Text = "RST CSV";
            this.btnResetCSV.UseVisualStyleBackColor = true;
            this.btnResetCSV.Click += new System.EventHandler(this.btnResetCSV_Click);
            // 
            // btnExportTable
            // 
            this.btnExportTable.Location = new System.Drawing.Point(616, 194);
            this.btnExportTable.Name = "btnExportTable";
            this.btnExportTable.Size = new System.Drawing.Size(75, 23);
            this.btnExportTable.TabIndex = 14;
            this.btnExportTable.Text = "Export CSV";
            this.btnExportTable.UseVisualStyleBackColor = true;
            this.btnExportTable.Click += new System.EventHandler(this.btnExportTable_Click);
            // 
            // dataGridView1
            // 
            this.dataGridView1.AllowUserToAddRows = false;
            this.dataGridView1.ColumnHeadersHeightSizeMode = System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode.AutoSize;
            this.dataGridView1.Columns.AddRange(new System.Windows.Forms.DataGridViewColumn[] {
            this.Time,
            this.Setting,
            this.BER});
            this.dataGridView1.Location = new System.Drawing.Point(302, 13);
            this.dataGridView1.Name = "dataGridView1";
            this.dataGridView1.ReadOnly = true;
            this.dataGridView1.Size = new System.Drawing.Size(389, 175);
            this.dataGridView1.TabIndex = 13;
            this.dataGridView1.CellContentClick += new System.Windows.Forms.DataGridViewCellEventHandler(this.dataGridView1_CellContentClick);
            // 
            // Time
            // 
            this.Time.Frozen = true;
            this.Time.HeaderText = "Time";
            this.Time.Name = "Time";
            this.Time.ReadOnly = true;
            // 
            // Setting
            // 
            this.Setting.Frozen = true;
            this.Setting.HeaderText = "Setting";
            this.Setting.Name = "Setting";
            this.Setting.ReadOnly = true;
            this.Setting.Width = 150;
            // 
            // BER
            // 
            this.BER.Frozen = true;
            this.BER.HeaderText = "BER";
            this.BER.Name = "BER";
            this.BER.ReadOnly = true;
            // 
            // grpLinkQuality
            // 
            this.grpLinkQuality.Controls.Add(this.lblThroughput);
            this.grpLinkQuality.Controls.Add(this.lblRxBits);
            this.grpLinkQuality.Controls.Add(this.lblTotalBits);
            this.grpLinkQuality.Controls.Add(this.lblErrorBits);
            this.grpLinkQuality.Controls.Add(this.lblBER);
            this.grpLinkQuality.Controls.Add(this.Reset_data);
            this.grpLinkQuality.Controls.Add(this.label13);
            this.grpLinkQuality.Controls.Add(this.label12);
            this.grpLinkQuality.Controls.Add(this.label11);
            this.grpLinkQuality.Controls.Add(this.label10);
            this.grpLinkQuality.Controls.Add(this.label9);
            this.grpLinkQuality.Location = new System.Drawing.Point(293, 223);
            this.grpLinkQuality.Name = "grpLinkQuality";
            this.grpLinkQuality.Size = new System.Drawing.Size(404, 91);
            this.grpLinkQuality.TabIndex = 12;
            this.grpLinkQuality.TabStop = false;
            this.grpLinkQuality.Text = "Link Quality";
            // 
            // lblThroughput
            // 
            this.lblThroughput.AutoSize = true;
            this.lblThroughput.Location = new System.Drawing.Point(302, 19);
            this.lblThroughput.Name = "lblThroughput";
            this.lblThroughput.Size = new System.Drawing.Size(63, 13);
            this.lblThroughput.TabIndex = 22;
            this.lblThroughput.Text = "0.000 Mbps";
            // 
            // lblRxBits
            // 
            this.lblRxBits.AutoSize = true;
            this.lblRxBits.Location = new System.Drawing.Point(71, 72);
            this.lblRxBits.Name = "lblRxBits";
            this.lblRxBits.Size = new System.Drawing.Size(13, 13);
            this.lblRxBits.TabIndex = 21;
            this.lblRxBits.Text = "0";
            // 
            // lblTotalBits
            // 
            this.lblTotalBits.AutoSize = true;
            this.lblTotalBits.Location = new System.Drawing.Point(71, 55);
            this.lblTotalBits.Name = "lblTotalBits";
            this.lblTotalBits.Size = new System.Drawing.Size(13, 13);
            this.lblTotalBits.TabIndex = 20;
            this.lblTotalBits.Text = "0";
            // 
            // lblErrorBits
            // 
            this.lblErrorBits.AutoSize = true;
            this.lblErrorBits.Location = new System.Drawing.Point(71, 37);
            this.lblErrorBits.Name = "lblErrorBits";
            this.lblErrorBits.Size = new System.Drawing.Size(13, 13);
            this.lblErrorBits.TabIndex = 19;
            this.lblErrorBits.Text = "0";
            // 
            // lblBER
            // 
            this.lblBER.AutoSize = true;
            this.lblBER.Location = new System.Drawing.Point(71, 19);
            this.lblBER.Name = "lblBER";
            this.lblBER.Size = new System.Drawing.Size(59, 13);
            this.lblBER.TabIndex = 18;
            this.lblBER.Text = "0.000E+00";
            // 
            // Reset_data
            // 
            this.Reset_data.Location = new System.Drawing.Point(323, 67);
            this.Reset_data.Name = "Reset_data";
            this.Reset_data.Size = new System.Drawing.Size(75, 23);
            this.Reset_data.TabIndex = 14;
            this.Reset_data.Text = "Reset";
            this.Reset_data.UseVisualStyleBackColor = true;
            this.Reset_data.Click += new System.EventHandler(this.Reset_data_Click);
            // 
            // label13
            // 
            this.label13.AutoSize = true;
            this.label13.Location = new System.Drawing.Point(219, 19);
            this.label13.Name = "label13";
            this.label13.Size = new System.Drawing.Size(77, 13);
            this.label13.TabIndex = 17;
            this.label13.Text = "Payload Rate :";
            // 
            // label12
            // 
            this.label12.AutoSize = true;
            this.label12.Location = new System.Drawing.Point(5, 72);
            this.label12.Name = "label12";
            this.label12.Size = new System.Drawing.Size(45, 13);
            this.label12.TabIndex = 16;
            this.label12.Text = "Rx bits :";
            // 
            // label11
            // 
            this.label11.AutoSize = true;
            this.label11.Location = new System.Drawing.Point(5, 55);
            this.label11.Name = "label11";
            this.label11.Size = new System.Drawing.Size(44, 13);
            this.label11.TabIndex = 15;
            this.label11.Text = "Tx bits :";
            // 
            // label10
            // 
            this.label10.AutoSize = true;
            this.label10.Location = new System.Drawing.Point(6, 37);
            this.label10.Name = "label10";
            this.label10.Size = new System.Drawing.Size(54, 13);
            this.label10.TabIndex = 14;
            this.label10.Text = "Error bits :";
            // 
            // label9
            // 
            this.label9.AutoSize = true;
            this.label9.Location = new System.Drawing.Point(6, 19);
            this.label9.Name = "label9";
            this.label9.Size = new System.Drawing.Size(35, 13);
            this.label9.TabIndex = 13;
            this.label9.Text = "BER :";
            // 
            // grpUserText
            // 
            this.grpUserText.Controls.Add(this.txtRxMessage);
            this.grpUserText.Controls.Add(this.label8);
            this.grpUserText.Controls.Add(this.label7);
            this.grpUserText.Controls.Add(this.txtTxMessage);
            this.grpUserText.Enabled = false;
            this.grpUserText.Location = new System.Drawing.Point(16, 223);
            this.grpUserText.Name = "grpUserText";
            this.grpUserText.Size = new System.Drawing.Size(271, 91);
            this.grpUserText.TabIndex = 11;
            this.grpUserText.TabStop = false;
            this.grpUserText.Text = "Text";
            // 
            // txtRxMessage
            // 
            this.txtRxMessage.Location = new System.Drawing.Point(81, 46);
            this.txtRxMessage.Name = "txtRxMessage";
            this.txtRxMessage.ReadOnly = true;
            this.txtRxMessage.Size = new System.Drawing.Size(184, 39);
            this.txtRxMessage.TabIndex = 12;
            this.txtRxMessage.Text = "";
            // 
            // label8
            // 
            this.label8.AutoSize = true;
            this.label8.Location = new System.Drawing.Point(6, 46);
            this.label8.Name = "label8";
            this.label8.Size = new System.Drawing.Size(39, 13);
            this.label8.TabIndex = 13;
            this.label8.Text = "Output";
            // 
            // label7
            // 
            this.label7.AutoSize = true;
            this.label7.Location = new System.Drawing.Point(6, 22);
            this.label7.Name = "label7";
            this.label7.Size = new System.Drawing.Size(31, 13);
            this.label7.TabIndex = 12;
            this.label7.Text = "Input";
            // 
            // txtTxMessage
            // 
            this.txtTxMessage.Location = new System.Drawing.Point(81, 19);
            this.txtTxMessage.Name = "txtTxMessage";
            this.txtTxMessage.Size = new System.Drawing.Size(184, 20);
            this.txtTxMessage.TabIndex = 0;
            // 
            // txtLog
            // 
            this.txtLog.Location = new System.Drawing.Point(16, 320);
            this.txtLog.Name = "txtLog";
            this.txtLog.ReadOnly = true;
            this.txtLog.ScrollBars = System.Windows.Forms.RichTextBoxScrollBars.Vertical;
            this.txtLog.Size = new System.Drawing.Size(681, 77);
            this.txtLog.TabIndex = 10;
            this.txtLog.Text = "Log";
            // 
            // grpSetting
            // 
            this.grpSetting.Controls.Add(this.cmbMod);
            this.grpSetting.Controls.Add(this.cmbBitRate);
            this.grpSetting.Controls.Add(this.cmbCode);
            this.grpSetting.Controls.Add(this.cmbDataType);
            this.grpSetting.Controls.Add(this.label6);
            this.grpSetting.Controls.Add(this.label5);
            this.grpSetting.Controls.Add(this.label4);
            this.grpSetting.Controls.Add(this.label3);
            this.grpSetting.Enabled = false;
            this.grpSetting.Location = new System.Drawing.Point(16, 52);
            this.grpSetting.Name = "grpSetting";
            this.grpSetting.Size = new System.Drawing.Size(271, 165);
            this.grpSetting.TabIndex = 9;
            this.grpSetting.TabStop = false;
            this.grpSetting.Text = "Setting";
            // 
            // cmbMod
            // 
            this.cmbMod.FormattingEnabled = true;
            this.cmbMod.Items.AddRange(new object[] {
            "OOK-NRZ",
            "OOK-RZ",
            "PWM",
            "PPM"});
            this.cmbMod.Location = new System.Drawing.Point(81, 96);
            this.cmbMod.Name = "cmbMod";
            this.cmbMod.Size = new System.Drawing.Size(156, 21);
            this.cmbMod.TabIndex = 14;
            // 
            // cmbBitRate
            // 
            this.cmbBitRate.FormattingEnabled = true;
            this.cmbBitRate.Items.AddRange(new object[] {
            "1 Mbps",
            "2 Mbps",
            "5 Mbps",
            "10 Mbps",
            "25 Mbps",
            "50 Mbps"});
            this.cmbBitRate.Location = new System.Drawing.Point(81, 131);
            this.cmbBitRate.Name = "cmbBitRate";
            this.cmbBitRate.Size = new System.Drawing.Size(156, 21);
            this.cmbBitRate.TabIndex = 13;
            // 
            // cmbCode
            // 
            this.cmbCode.FormattingEnabled = true;
            this.cmbCode.Items.AddRange(new object[] {
            "None",
            "CRC-8",
            "Repeat-3",
            "Hamming-7,4"});
            this.cmbCode.Location = new System.Drawing.Point(81, 59);
            this.cmbCode.Name = "cmbCode";
            this.cmbCode.Size = new System.Drawing.Size(156, 21);
            this.cmbCode.TabIndex = 12;
            // 
            // cmbDataType
            // 
            this.cmbDataType.FormattingEnabled = true;
            this.cmbDataType.Items.AddRange(new object[] {
            "PRBS7",
            "PRBS15",
            "ASCII \"S\"",
            "Counter",
            "User Text"});
            this.cmbDataType.Location = new System.Drawing.Point(81, 24);
            this.cmbDataType.Name = "cmbDataType";
            this.cmbDataType.Size = new System.Drawing.Size(156, 21);
            this.cmbDataType.TabIndex = 11;
            // 
            // label6
            // 
            this.label6.AutoSize = true;
            this.label6.Location = new System.Drawing.Point(6, 131);
            this.label6.Name = "label6";
            this.label6.Size = new System.Drawing.Size(45, 13);
            this.label6.TabIndex = 3;
            this.label6.Text = "Bit Rate";
            // 
            // label5
            // 
            this.label5.AutoSize = true;
            this.label5.Location = new System.Drawing.Point(4, 99);
            this.label5.Name = "label5";
            this.label5.Size = new System.Drawing.Size(59, 13);
            this.label5.TabIndex = 2;
            this.label5.Text = "Modulation";
            // 
            // label4
            // 
            this.label4.AutoSize = true;
            this.label4.Location = new System.Drawing.Point(4, 62);
            this.label4.Name = "label4";
            this.label4.Size = new System.Drawing.Size(40, 13);
            this.label4.TabIndex = 1;
            this.label4.Text = "Coding";
            // 
            // label3
            // 
            this.label3.AutoSize = true;
            this.label3.Location = new System.Drawing.Point(4, 27);
            this.label3.Name = "label3";
            this.label3.Size = new System.Drawing.Size(57, 13);
            this.label3.TabIndex = 0;
            this.label3.Text = "Data Type";
            // 
            // grpUsb
            // 
            this.grpUsb.BackColor = System.Drawing.Color.DarkGray;
            this.grpUsb.Controls.Add(this.label2);
            this.grpUsb.Controls.Add(this.btnConnect);
            this.grpUsb.Controls.Add(this.btnClose);
            this.grpUsb.Controls.Add(this.lblStatus);
            this.grpUsb.Location = new System.Drawing.Point(16, 6);
            this.grpUsb.Name = "grpUsb";
            this.grpUsb.Size = new System.Drawing.Size(271, 40);
            this.grpUsb.TabIndex = 7;
            // 
            // label2
            // 
            this.label2.AutoSize = true;
            this.label2.Font = new System.Drawing.Font("Microsoft Sans Serif", 8.25F, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Point, ((byte)(222)));
            this.label2.Location = new System.Drawing.Point(12, 8);
            this.label2.Name = "label2";
            this.label2.Size = new System.Drawing.Size(74, 13);
            this.label2.TabIndex = 9;
            this.label2.Text = "USB/FT601";
            // 
            // tabPageMimo
            // 
            this.tabPageMimo.Controls.Add(this.label19);
            this.tabPageMimo.Controls.Add(this.label14);
            this.tabPageMimo.Controls.Add(this.MMOtxtRxMessage);
            this.tabPageMimo.Controls.Add(this.MIMOtxtTxMessage);
            this.tabPageMimo.Controls.Add(this.btnMimoExportCsv);
            this.tabPageMimo.Controls.Add(this.btnMimoResetCsv);
            this.tabPageMimo.Controls.Add(this.txtMimoLog);
            this.tabPageMimo.Controls.Add(this.grpMimoSettings);
            this.tabPageMimo.Controls.Add(this.dgvMimoBer);
            this.tabPageMimo.Controls.Add(this.pnlMimoUsb);
            this.tabPageMimo.Location = new System.Drawing.Point(4, 22);
            this.tabPageMimo.Name = "tabPageMimo";
            this.tabPageMimo.Padding = new System.Windows.Forms.Padding(3);
            this.tabPageMimo.Size = new System.Drawing.Size(703, 403);
            this.tabPageMimo.TabIndex = 2;
            this.tabPageMimo.Text = "MIMO";
            this.tabPageMimo.UseVisualStyleBackColor = true;
            // 
            // label19
            // 
            this.label19.AutoSize = true;
            this.label19.Location = new System.Drawing.Point(468, 376);
            this.label19.Name = "label19";
            this.label19.Size = new System.Drawing.Size(39, 13);
            this.label19.TabIndex = 22;
            this.label19.Text = "Output";
            // 
            // label14
            // 
            this.label14.AutoSize = true;
            this.label14.Location = new System.Drawing.Point(265, 376);
            this.label14.Name = "label14";
            this.label14.Size = new System.Drawing.Size(31, 13);
            this.label14.TabIndex = 21;
            this.label14.Text = "Input";
            this.label14.Click += new System.EventHandler(this.label14_Click);
            // 
            // MMOtxtRxMessage
            // 
            this.MMOtxtRxMessage.Location = new System.Drawing.Point(513, 373);
            this.MMOtxtRxMessage.Name = "MMOtxtRxMessage";
            this.MMOtxtRxMessage.ReadOnly = true;
            this.MMOtxtRxMessage.Size = new System.Drawing.Size(184, 20);
            this.MMOtxtRxMessage.TabIndex = 20;
            this.MMOtxtRxMessage.Text = "";
            // 
            // MIMOtxtTxMessage
            // 
            this.MIMOtxtTxMessage.Location = new System.Drawing.Point(302, 373);
            this.MIMOtxtTxMessage.Name = "MIMOtxtTxMessage";
            this.MIMOtxtTxMessage.Size = new System.Drawing.Size(135, 20);
            this.MIMOtxtTxMessage.TabIndex = 19;
            // 
            // btnMimoExportCsv
            // 
            this.btnMimoExportCsv.Location = new System.Drawing.Point(622, 17);
            this.btnMimoExportCsv.Name = "btnMimoExportCsv";
            this.btnMimoExportCsv.Size = new System.Drawing.Size(75, 23);
            this.btnMimoExportCsv.TabIndex = 18;
            this.btnMimoExportCsv.Text = "Export CSV";
            this.btnMimoExportCsv.UseVisualStyleBackColor = true;
            this.btnMimoExportCsv.Click += new System.EventHandler(this.btnMimoExportCsv_Click);
            // 
            // btnMimoResetCsv
            // 
            this.btnMimoResetCsv.Location = new System.Drawing.Point(541, 17);
            this.btnMimoResetCsv.Name = "btnMimoResetCsv";
            this.btnMimoResetCsv.Size = new System.Drawing.Size(75, 23);
            this.btnMimoResetCsv.TabIndex = 17;
            this.btnMimoResetCsv.Text = "RST CSV";
            this.btnMimoResetCsv.UseVisualStyleBackColor = true;
            this.btnMimoResetCsv.Click += new System.EventHandler(this.btnMimoResetCsv_Click);
            // 
            // txtMimoLog
            // 
            this.txtMimoLog.Location = new System.Drawing.Point(265, 251);
            this.txtMimoLog.Name = "txtMimoLog";
            this.txtMimoLog.ReadOnly = true;
            this.txtMimoLog.ScrollBars = System.Windows.Forms.RichTextBoxScrollBars.Vertical;
            this.txtMimoLog.Size = new System.Drawing.Size(432, 113);
            this.txtMimoLog.TabIndex = 16;
            this.txtMimoLog.Text = "Log";
            // 
            // grpMimoSettings
            // 
            this.grpMimoSettings.Controls.Add(this.cmbMimoModulation);
            this.grpMimoSettings.Controls.Add(this.cmbMimoCoding);
            this.grpMimoSettings.Controls.Add(this.chkRf1Mbps);
            this.grpMimoSettings.Controls.Add(this.cmbMimoMode);
            this.grpMimoSettings.Controls.Add(this.label22);
            this.grpMimoSettings.Controls.Add(this.cmbMimoBitRate);
            this.grpMimoSettings.Controls.Add(this.cmbMimoDataType);
            this.grpMimoSettings.Controls.Add(this.label15);
            this.grpMimoSettings.Controls.Add(this.label16);
            this.grpMimoSettings.Controls.Add(this.label17);
            this.grpMimoSettings.Controls.Add(this.label18);
            this.grpMimoSettings.Enabled = false;
            this.grpMimoSettings.Location = new System.Drawing.Point(6, 247);
            this.grpMimoSettings.Name = "grpMimoSettings";
            this.grpMimoSettings.Size = new System.Drawing.Size(253, 150);
            this.grpMimoSettings.TabIndex = 15;
            this.grpMimoSettings.TabStop = false;
            this.grpMimoSettings.Text = "Mode";
            // 
            // cmbMimoModulation
            // 
            this.cmbMimoModulation.FormattingEnabled = true;
            this.cmbMimoModulation.Items.AddRange(new object[] {
            "OOK-NRZ",
            "OOK-RZ",
            "PWM",
            "PPM"});
            this.cmbMimoModulation.Location = new System.Drawing.Point(76, 96);
            this.cmbMimoModulation.Name = "cmbMimoModulation";
            this.cmbMimoModulation.Size = new System.Drawing.Size(156, 21);
            this.cmbMimoModulation.TabIndex = 23;
            // 
            // cmbMimoCoding
            // 
            this.cmbMimoCoding.FormattingEnabled = true;
            this.cmbMimoCoding.Items.AddRange(new object[] {
            "None",
            "CRC-8",
            "Repeat-3",
            "Hamming-7,4"});
            this.cmbMimoCoding.Location = new System.Drawing.Point(76, 69);
            this.cmbMimoCoding.Name = "cmbMimoCoding";
            this.cmbMimoCoding.Size = new System.Drawing.Size(156, 21);
            this.cmbMimoCoding.TabIndex = 22;
            // 
            // chkRf1Mbps
            // 
            this.chkRf1Mbps.AutoSize = true;
            this.chkRf1Mbps.Location = new System.Drawing.Point(172, 17);
            this.chkRf1Mbps.Name = "chkRf1Mbps";
            this.chkRf1Mbps.Size = new System.Drawing.Size(75, 17);
            this.chkRf1Mbps.TabIndex = 21;
            this.chkRf1Mbps.Text = "RF-1Mbps";
            this.chkRf1Mbps.UseVisualStyleBackColor = true;
            // 
            // cmbMimoMode
            // 
            this.cmbMimoMode.FormattingEnabled = true;
            this.cmbMimoMode.Items.AddRange(new object[] {
            "Spatial multiplexing",
            "Diversity"});
            this.cmbMimoMode.Location = new System.Drawing.Point(76, 15);
            this.cmbMimoMode.Name = "cmbMimoMode";
            this.cmbMimoMode.Size = new System.Drawing.Size(90, 21);
            this.cmbMimoMode.TabIndex = 20;
            // 
            // label22
            // 
            this.label22.AutoSize = true;
            this.label22.Location = new System.Drawing.Point(6, 19);
            this.label22.Name = "label22";
            this.label22.Size = new System.Drawing.Size(36, 13);
            this.label22.TabIndex = 19;
            this.label22.Text = "MIMO";
            // 
            // cmbMimoBitRate
            // 
            this.cmbMimoBitRate.FormattingEnabled = true;
            this.cmbMimoBitRate.Items.AddRange(new object[] {
            "1 Mbps",
            "2 Mbps",
            "5 Mbps",
            "10 Mbps",
            "25 Mbps",
            "50 Mbps"});
            this.cmbMimoBitRate.Location = new System.Drawing.Point(76, 122);
            this.cmbMimoBitRate.Name = "cmbMimoBitRate";
            this.cmbMimoBitRate.Size = new System.Drawing.Size(156, 21);
            this.cmbMimoBitRate.TabIndex = 13;
            // 
            // cmbMimoDataType
            // 
            this.cmbMimoDataType.FormattingEnabled = true;
            this.cmbMimoDataType.Items.AddRange(new object[] {
            "PRBS7",
            "PRBS15",
            "ASCII \"S\"",
            "Counter",
            "User Text"});
            this.cmbMimoDataType.Location = new System.Drawing.Point(76, 42);
            this.cmbMimoDataType.Name = "cmbMimoDataType";
            this.cmbMimoDataType.Size = new System.Drawing.Size(156, 21);
            this.cmbMimoDataType.TabIndex = 11;
            // 
            // label15
            // 
            this.label15.AutoSize = true;
            this.label15.Location = new System.Drawing.Point(6, 126);
            this.label15.Name = "label15";
            this.label15.Size = new System.Drawing.Size(45, 13);
            this.label15.TabIndex = 3;
            this.label15.Text = "Bit Rate";
            // 
            // label16
            // 
            this.label16.AutoSize = true;
            this.label16.Location = new System.Drawing.Point(5, 99);
            this.label16.Name = "label16";
            this.label16.Size = new System.Drawing.Size(59, 13);
            this.label16.TabIndex = 2;
            this.label16.Text = "Modulation";
            // 
            // label17
            // 
            this.label17.AutoSize = true;
            this.label17.Location = new System.Drawing.Point(6, 71);
            this.label17.Name = "label17";
            this.label17.Size = new System.Drawing.Size(40, 13);
            this.label17.TabIndex = 1;
            this.label17.Text = "Coding";
            // 
            // label18
            // 
            this.label18.AutoSize = true;
            this.label18.Location = new System.Drawing.Point(5, 43);
            this.label18.Name = "label18";
            this.label18.Size = new System.Drawing.Size(57, 13);
            this.label18.TabIndex = 0;
            this.label18.Text = "Data Type";
            // 
            // dgvMimoBer
            // 
            this.dgvMimoBer.AllowUserToAddRows = false;
            this.dgvMimoBer.ColumnHeadersHeightSizeMode = System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode.AutoSize;
            this.dgvMimoBer.Columns.AddRange(new System.Windows.Forms.DataGridViewColumn[] {
            this.colMimoTime,
            this.colMimoMode,
            this.colFsoBer1,
            this.colFsoBer2,
            this.colFsoAber,
            this.colRfBer,
            this.Rx1,
            this.Rx2,
            this.OBER,
            this.Throughput,
            this.Delivery});
            this.dgvMimoBer.Location = new System.Drawing.Point(6, 52);
            this.dgvMimoBer.Name = "dgvMimoBer";
            this.dgvMimoBer.ReadOnly = true;
            this.dgvMimoBer.Size = new System.Drawing.Size(691, 189);
            this.dgvMimoBer.TabIndex = 14;
            // 
            // pnlMimoUsb
            // 
            this.pnlMimoUsb.BackColor = System.Drawing.Color.DarkGray;
            this.pnlMimoUsb.Controls.Add(this.label1);
            this.pnlMimoUsb.Controls.Add(this.btnMimoConnect);
            this.pnlMimoUsb.Controls.Add(this.btnMimoClose);
            this.pnlMimoUsb.Controls.Add(this.lblMimoUsbStatus);
            this.pnlMimoUsb.Location = new System.Drawing.Point(6, 6);
            this.pnlMimoUsb.Name = "pnlMimoUsb";
            this.pnlMimoUsb.Size = new System.Drawing.Size(297, 40);
            this.pnlMimoUsb.TabIndex = 8;
            // 
            // label1
            // 
            this.label1.AutoSize = true;
            this.label1.Font = new System.Drawing.Font("Microsoft Sans Serif", 8.25F, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Point, ((byte)(222)));
            this.label1.Location = new System.Drawing.Point(12, 8);
            this.label1.Name = "label1";
            this.label1.Size = new System.Drawing.Size(74, 13);
            this.label1.TabIndex = 9;
            this.label1.Text = "USB/FT601";
            // 
            // btnMimoConnect
            // 
            this.btnMimoConnect.Location = new System.Drawing.Point(126, 8);
            this.btnMimoConnect.Name = "btnMimoConnect";
            this.btnMimoConnect.Size = new System.Drawing.Size(75, 23);
            this.btnMimoConnect.TabIndex = 0;
            this.btnMimoConnect.Text = "Connect";
            this.btnMimoConnect.UseVisualStyleBackColor = true;
            this.btnMimoConnect.Click += new System.EventHandler(this.btnMimoConnect_Click);
            // 
            // btnMimoClose
            // 
            this.btnMimoClose.Location = new System.Drawing.Point(207, 8);
            this.btnMimoClose.Name = "btnMimoClose";
            this.btnMimoClose.Size = new System.Drawing.Size(76, 23);
            this.btnMimoClose.TabIndex = 5;
            this.btnMimoClose.Text = "Close";
            this.btnMimoClose.UseVisualStyleBackColor = true;
            this.btnMimoClose.Click += new System.EventHandler(this.btnMimoClose_Click);
            // 
            // lblMimoUsbStatus
            // 
            this.lblMimoUsbStatus.AutoSize = true;
            this.lblMimoUsbStatus.Location = new System.Drawing.Point(13, 21);
            this.lblMimoUsbStatus.Name = "lblMimoUsbStatus";
            this.lblMimoUsbStatus.Size = new System.Drawing.Size(37, 13);
            this.lblMimoUsbStatus.TabIndex = 6;
            this.lblMimoUsbStatus.Text = "Status";
            // 
            // lblTime
            // 
            this.lblTime.AutoSize = true;
            this.lblTime.Location = new System.Drawing.Point(9, 452);
            this.lblTime.Name = "lblTime";
            this.lblTime.Size = new System.Drawing.Size(30, 13);
            this.lblTime.TabIndex = 8;
            this.lblTime.Text = "Time";
            // 
            // btnStartTX
            // 
            this.btnStartTX.Location = new System.Drawing.Point(563, 447);
            this.btnStartTX.Name = "btnStartTX";
            this.btnStartTX.Size = new System.Drawing.Size(75, 23);
            this.btnStartTX.TabIndex = 13;
            this.btnStartTX.Text = "Start";
            this.btnStartTX.UseVisualStyleBackColor = true;
            this.btnStartTX.Click += new System.EventHandler(this.btnStartTX_Click);
            // 
            // btnStopTX
            // 
            this.btnStopTX.Location = new System.Drawing.Point(644, 447);
            this.btnStopTX.Name = "btnStopTX";
            this.btnStopTX.Size = new System.Drawing.Size(75, 23);
            this.btnStopTX.TabIndex = 13;
            this.btnStopTX.Text = "Stop";
            this.btnStopTX.UseVisualStyleBackColor = true;
            this.btnStopTX.Click += new System.EventHandler(this.btnStopTX_Click);
            // 
            // colMimoTime
            // 
            this.colMimoTime.Frozen = true;
            this.colMimoTime.HeaderText = "Time";
            this.colMimoTime.Name = "colMimoTime";
            this.colMimoTime.ReadOnly = true;
            this.colMimoTime.Width = 50;
            // 
            // colMimoMode
            // 
            this.colMimoMode.Frozen = true;
            this.colMimoMode.HeaderText = "Mode";
            this.colMimoMode.Name = "colMimoMode";
            this.colMimoMode.ReadOnly = true;
            this.colMimoMode.Width = 50;
            // 
            // colFsoBer1
            // 
            this.colFsoBer1.Frozen = true;
            this.colFsoBer1.HeaderText = "FSO-BER1";
            this.colFsoBer1.Name = "colFsoBer1";
            this.colFsoBer1.ReadOnly = true;
            this.colFsoBer1.Width = 80;
            // 
            // colFsoBer2
            // 
            this.colFsoBer2.Frozen = true;
            this.colFsoBer2.HeaderText = "FSO-BER2";
            this.colFsoBer2.Name = "colFsoBer2";
            this.colFsoBer2.ReadOnly = true;
            this.colFsoBer2.Width = 80;
            // 
            // colFsoAber
            // 
            this.colFsoAber.Frozen = true;
            this.colFsoAber.HeaderText = "FSO-ABER";
            this.colFsoAber.Name = "colFsoAber";
            this.colFsoAber.ReadOnly = true;
            this.colFsoAber.Width = 50;
            // 
            // colRfBer
            // 
            this.colRfBer.Frozen = true;
            this.colRfBer.HeaderText = "RF-BER";
            this.colRfBer.Name = "colRfBer";
            this.colRfBer.ReadOnly = true;
            this.colRfBer.Width = 50;
            // 
            // Rx1
            // 
            this.Rx1.Frozen = true;
            this.Rx1.HeaderText = "Rx1";
            this.Rx1.Name = "Rx1";
            this.Rx1.ReadOnly = true;
            this.Rx1.Width = 50;
            // 
            // Rx2
            // 
            this.Rx2.Frozen = true;
            this.Rx2.HeaderText = "Rx2";
            this.Rx2.Name = "Rx2";
            this.Rx2.ReadOnly = true;
            this.Rx2.Width = 50;
            // 
            // OBER
            // 
            this.OBER.HeaderText = "OBER";
            this.OBER.Name = "OBER";
            this.OBER.ReadOnly = true;
            this.OBER.Width = 80;
            // 
            // Throughput
            // 
            this.Throughput.HeaderText = "Throughput";
            this.Throughput.Name = "Throughput";
            this.Throughput.ReadOnly = true;
            this.Throughput.Width = 80;
            // 
            // Delivery
            // 
            this.Delivery.HeaderText = "Delivery";
            this.Delivery.Name = "Delivery";
            this.Delivery.ReadOnly = true;
            this.Delivery.Width = 50;
            // 
            // Form1
            // 
            this.AutoScaleDimensions = new System.Drawing.SizeF(6F, 13F);
            this.AutoScaleMode = System.Windows.Forms.AutoScaleMode.Font;
            this.ClientSize = new System.Drawing.Size(735, 474);
            this.Controls.Add(this.btnStopTX);
            this.Controls.Add(this.btnStartTX);
            this.Controls.Add(this.lblTime);
            this.Controls.Add(this.tabMain);
            this.Controls.Add(this.btnLedAA);
            this.Controls.Add(this.btnLedOn);
            this.Controls.Add(this.btnLed55);
            this.Controls.Add(this.btnLedOff);
            this.Icon = ((System.Drawing.Icon)(resources.GetObject("$this.Icon")));
            this.Name = "Form1";
            this.Text = "Form1";
            this.FormClosing += new System.Windows.Forms.FormClosingEventHandler(this.Form1_FormClosing);
            this.tabMain.ResumeLayout(false);
            this.tabData.ResumeLayout(false);
            ((System.ComponentModel.ISupportInitialize)(this.dataGridView1)).EndInit();
            this.grpLinkQuality.ResumeLayout(false);
            this.grpLinkQuality.PerformLayout();
            this.grpUserText.ResumeLayout(false);
            this.grpUserText.PerformLayout();
            this.grpSetting.ResumeLayout(false);
            this.grpSetting.PerformLayout();
            this.grpUsb.ResumeLayout(false);
            this.grpUsb.PerformLayout();
            this.tabPageMimo.ResumeLayout(false);
            this.tabPageMimo.PerformLayout();
            this.grpMimoSettings.ResumeLayout(false);
            this.grpMimoSettings.PerformLayout();
            ((System.ComponentModel.ISupportInitialize)(this.dgvMimoBer)).EndInit();
            this.pnlMimoUsb.ResumeLayout(false);
            this.pnlMimoUsb.PerformLayout();
            this.ResumeLayout(false);
            this.PerformLayout();

        }

        #endregion

        private System.Windows.Forms.Button btnConnect;
        private System.Windows.Forms.Button btnLedOn;
        private System.Windows.Forms.Button btnLedOff;
        private System.Windows.Forms.Button btnLedAA;
        private System.Windows.Forms.Button btnLed55;
        private System.Windows.Forms.Button btnClose;
        private System.Windows.Forms.Label lblStatus;
        private System.Windows.Forms.TabControl tabMain;
        private System.Windows.Forms.TabPage tabData;
        private System.Windows.Forms.RichTextBox txtLog;
        private System.Windows.Forms.GroupBox grpSetting;
        private System.Windows.Forms.Panel grpUsb;
        private System.Windows.Forms.Label label2;
        private System.Windows.Forms.Label lblTime;
        private System.Windows.Forms.GroupBox grpLinkQuality;
        private System.Windows.Forms.Button Reset_data;
        private System.Windows.Forms.Label label13;
        private System.Windows.Forms.Label label12;
        private System.Windows.Forms.Label label11;
        private System.Windows.Forms.Label label10;
        private System.Windows.Forms.Label label9;
        private System.Windows.Forms.GroupBox grpUserText;
        private System.Windows.Forms.RichTextBox txtRxMessage;
        private System.Windows.Forms.Label label8;
        private System.Windows.Forms.Label label7;
        private System.Windows.Forms.TextBox txtTxMessage;
        private System.Windows.Forms.ComboBox cmbMod;
        private System.Windows.Forms.ComboBox cmbBitRate;
        private System.Windows.Forms.ComboBox cmbCode;
        private System.Windows.Forms.ComboBox cmbDataType;
        private System.Windows.Forms.Label label6;
        private System.Windows.Forms.Label label5;
        private System.Windows.Forms.Label label4;
        private System.Windows.Forms.Label label3;
        private System.Windows.Forms.Button btnStartTX;
        private System.Windows.Forms.Button btnStopTX;
        private System.Windows.Forms.Label lblThroughput;
        private System.Windows.Forms.Label lblRxBits;
        private System.Windows.Forms.Label lblTotalBits;
        private System.Windows.Forms.Label lblErrorBits;
        private System.Windows.Forms.Label lblBER;
        private System.Windows.Forms.DataGridView dataGridView1;
        private System.Windows.Forms.DataGridViewTextBoxColumn Time;
        private System.Windows.Forms.DataGridViewTextBoxColumn Setting;
        private System.Windows.Forms.DataGridViewTextBoxColumn BER;
        private System.Windows.Forms.Button btnExportTable;
        private System.Windows.Forms.Button btnResetCSV;
        private System.Windows.Forms.TabPage tabPageMimo;
        private System.Windows.Forms.GroupBox grpMimoSettings;
        private System.Windows.Forms.ComboBox cmbMimoMode;
        private System.Windows.Forms.Label label22;
        private System.Windows.Forms.ComboBox cmbMimoBitRate;
        private System.Windows.Forms.ComboBox cmbMimoDataType;
        private System.Windows.Forms.Label label15;
        private System.Windows.Forms.Label label16;
        private System.Windows.Forms.Label label17;
        private System.Windows.Forms.Label label18;
        private System.Windows.Forms.DataGridView dgvMimoBer;
        private System.Windows.Forms.Panel pnlMimoUsb;
        private System.Windows.Forms.Label label1;
        private System.Windows.Forms.Button btnMimoConnect;
        private System.Windows.Forms.Button btnMimoClose;
        private System.Windows.Forms.Label lblMimoUsbStatus;
        private System.Windows.Forms.RichTextBox txtMimoLog;
        private System.Windows.Forms.CheckBox chkRf1Mbps;
        private System.Windows.Forms.ComboBox cmbMimoModulation;
        private System.Windows.Forms.ComboBox cmbMimoCoding;
        private System.Windows.Forms.Button btnMimoExportCsv;
        private System.Windows.Forms.Button btnMimoResetCsv;
        private System.Windows.Forms.TextBox MIMOtxtTxMessage;
        private System.Windows.Forms.RichTextBox MMOtxtRxMessage;
        private System.Windows.Forms.Label label14;
        private System.Windows.Forms.Label label19;
        private System.Windows.Forms.DataGridViewTextBoxColumn colMimoTime;
        private System.Windows.Forms.DataGridViewTextBoxColumn colMimoMode;
        private System.Windows.Forms.DataGridViewTextBoxColumn colFsoBer1;
        private System.Windows.Forms.DataGridViewTextBoxColumn colFsoBer2;
        private System.Windows.Forms.DataGridViewTextBoxColumn colFsoAber;
        private System.Windows.Forms.DataGridViewTextBoxColumn colRfBer;
        private System.Windows.Forms.DataGridViewTextBoxColumn Rx1;
        private System.Windows.Forms.DataGridViewTextBoxColumn Rx2;
        private System.Windows.Forms.DataGridViewTextBoxColumn OBER;
        private System.Windows.Forms.DataGridViewTextBoxColumn Throughput;
        private System.Windows.Forms.DataGridViewTextBoxColumn Delivery;
    }
}

