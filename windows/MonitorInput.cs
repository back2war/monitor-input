// Monitor input switcher over DDC/CI (VCP 0x60 "Input Source").
// Same mechanism ASUS DisplayWidget uses: dxva2.dll SetVCPFeature.
//
// Build (no SDK needed, uses the C# compiler shipped with Windows): build.cmd
//   monitor-input.exe       console CLI
//   monitor-input-tray.exe  tray app with global hotkeys (compiled with /define:TRAY)

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
#if TRAY
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Win32;
#endif

static class Native
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public int l, t, r, b;
        public int wl, wt, wr, wb;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitor(IntPtr h);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetCapabilitiesStringLength(IntPtr h, out uint len);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, byte[] buf, uint len);
}

class Monitor
{
    public int Index;
    public string Device;   // \\.\DISPLAY1
    public string HwId;     // e.g. AUS27AF (PnP id from EDID: manufacturer + product code)
    public IntPtr Handle;

    public const byte VcpInput = 0x60;

    public int? GetInput()
    {
        for (int i = 0; i < 5; i++)
        {
            uint cur, max;
            if (Native.GetVCPFeatureAndVCPFeatureReply(Handle, VcpInput, IntPtr.Zero, out cur, out max))
                return (int)(cur & 0xFF);   // some monitors put garbage in the high byte
            Thread.Sleep(100);
        }
        return null;
    }

    public bool SetInput(int value)
    {
        for (int i = 0; i < 3; i++)
        {
            if (Native.SetVCPFeature(Handle, VcpInput, (uint)value)) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    // Slow (hundreds of ms, many I2C transfers) and flaky on some monitors, so retry.
    public string GetCapabilities()
    {
        for (int i = 0; i < 3; i++)
        {
            Thread.Sleep(100);
            uint len;
            if (!Native.GetCapabilitiesStringLength(Handle, out len) || len == 0) continue;
            var buf = new byte[len];
            if (Native.CapabilitiesRequestAndCapabilitiesReply(Handle, buf, len))
                return Encoding.ASCII.GetString(buf).TrimEnd('\0');
        }
        return null;
    }

    // Enumerates all monitors; caller must Dispose the returned list.
    public static MonitorList All()
    {
        var list = new MonitorList();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, dc, r, d) =>
        {
            var mi = new Native.MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(Native.MONITORINFOEX));
            Native.GetMonitorInfo(h, ref mi);

            string hwid = "";
            var dd = new Native.DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(Native.DISPLAY_DEVICE));
            if (Native.EnumDisplayDevices(mi.szDevice, 0, ref dd, 0))
            {
                // DeviceID looks like MONITOR\AUS27AF\{...}
                var m = Regex.Match(dd.DeviceID ?? "", @"MONITOR\\([^\\]+)", RegexOptions.IgnoreCase);
                if (m.Success) hwid = m.Groups[1].Value;
            }

            uint n;
            if (Native.GetNumberOfPhysicalMonitorsFromHMONITOR(h, out n) && n > 0)
            {
                var arr = new Native.PHYSICAL_MONITOR[n];
                if (Native.GetPhysicalMonitorsFromHMONITOR(h, n, arr))
                    foreach (var pm in arr)
                        list.Add(new Monitor { Index = list.Count, Device = mi.szDevice, HwId = hwid, Handle = pm.hPhysicalMonitor });
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}

class MonitorList : List<Monitor>, IDisposable
{
    public void Dispose()
    {
        foreach (var m in this) Native.DestroyPhysicalMonitor(m.Handle);
        Clear();
    }

    // selector: "auto" (first ASUS monitor answering DDC, else first answering), index, or HwId substring.
    public Monitor Select(string selector)
    {
        selector = (selector ?? "auto").Trim();
        int idx;
        if (int.TryParse(selector, out idx)) return this.FirstOrDefault(m => m.Index == idx);
        if (!selector.Equals("auto", StringComparison.OrdinalIgnoreCase))
            return this.FirstOrDefault(m => m.HwId.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
        var responding = this.Where(m => m.GetInput() != null).ToList();
        return responding.FirstOrDefault(m => m.HwId.StartsWith("AUS", StringComparison.OrdinalIgnoreCase))
            ?? responding.FirstOrDefault();
    }
}

static class Inputs
{
    // MCCS values; ASUS DisplayWidget uses the same codes (see its ui/html/main.html).
    public static readonly Dictionary<string, int> Names = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
    {
        { "dvi", 0x03 },
        { "dp", 0x0F }, { "dp1", 0x0F }, { "dp2", 0x10 },
        { "hdmi", 0x11 }, { "hdmi1", 0x11 }, { "hdmi2", 0x12 },
        { "usbc", 0x13 }, { "usbc1", 0x13 }, { "usbc2", 0x14 },
        { "hdmi3", 0x53 }, { "hdmi4", 0x54 },
    };

    public static int Parse(string s)
    {
        s = s.Trim();
        int v;
        if (Names.TryGetValue(s, out v)) return v;
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase) &&
            int.TryParse(s.Substring(2), NumberStyles.HexNumber, null, out v)) return v;
        if (int.TryParse(s, out v)) return v;
        throw new ArgumentException("Unknown input: " + s);
    }

    public static string Name(int v)
    {
        var names = new[] { "dvi", "dp1", "dp2", "hdmi1", "hdmi2", "usbc1", "usbc2", "hdmi3", "hdmi4" };
        var n = names.FirstOrDefault(k => Names[k] == v);
        return (n ?? "?") + string.Format(" (0x{0:X2})", v);
    }

    public static string Label(int v)
    {
        switch (v)
        {
            case 0x03: return "DVI";
            case 0x0F: return "DisplayPort";
            case 0x10: return "DisplayPort 2";
            case 0x11: return "HDMI 1";
            case 0x12: return "HDMI 2";
            case 0x13: return "USB-C";
            case 0x14: return "USB-C 2";
            case 0x53: return "HDMI 3";
            case 0x54: return "HDMI 4";
            default: return string.Format("Input 0x{0:X2}", v);
        }
    }

    // "dp" -> switch to dp; "dp,hdmi1" -> cycle: go to the entry after the current one.
    public static int Resolve(string spec, Monitor mon)
    {
        var targets = spec.Split(',').Select(Parse).ToList();
        if (targets.Count == 1) return targets[0];
        int? cur = mon.GetInput();
        int pos = cur.HasValue ? targets.IndexOf(cur.Value) : -1;
        return targets[(pos + 1) % targets.Count];
    }
}

// Parsed MCCS capabilities string, e.g. "(prot(monitor)...model(PG32UQ)...vcp(... 60(11 12 0F) ...))".
class MonitorInfo
{
    public string Model;
    public List<int> Inputs = new List<int>();

    public static MonitorInfo FromCapabilities(string caps)
    {
        var info = new MonitorInfo();
        if (caps == null) return info;
        var model = Regex.Match(caps, @"model\(([^)]*)\)");
        if (model.Success) info.Model = model.Groups[1].Value;
        var inputs = Regex.Match(caps, @"\b60\(([0-9A-Fa-f ]*)\)");
        if (inputs.Success)
            info.Inputs = inputs.Groups[1].Value
                .Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(h => Convert.ToInt32(h, 16)).ToList();
        return info;
    }
}

static class Core
{
    public static string Switch(string spec, string selector)
    {
        using (var mons = Monitor.All())
        {
            var mon = mons.Select(selector);
            if (mon == null) throw new Exception("No DDC/CI monitor found (selector: " + selector + ")");
            int target = Inputs.Resolve(spec, mon);
            if (!mon.SetInput(target))
                throw new Exception("SetVCPFeature failed, error " + Marshal.GetLastWin32Error());
            return string.Format("Monitor {0} ({1}) -> {2}", mon.Index, mon.HwId, Inputs.Name(target));
        }
    }
}

#if !TRAY
static class Program
{
    static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || args[0] == "-h" || args[0] == "--help") { Usage(); return 0; }
            string selector = "auto";
            var rest = new List<string>();
            for (int i = 0; i < args.Length; i++)
            {
                if ((args[i] == "-m" || args[i] == "--monitor") && i + 1 < args.Length) selector = args[++i];
                else rest.Add(args[i]);
            }

            switch (rest[0].ToLowerInvariant())
            {
                case "list": List(); return 0;
                case "get":
                    using (var mons = Monitor.All())
                    {
                        var mon = mons.Select(selector);
                        int? v = mon == null ? null : mon.GetInput();
                        if (v == null) { Console.Error.WriteLine("Cannot read input source"); return 1; }
                        Console.WriteLine(Inputs.Name(v.Value));
                        return 0;
                    }
                case "set":
                    if (rest.Count < 2) { Usage(); return 2; }
                    Console.WriteLine(Core.Switch(rest[1], selector));
                    return 0;
                default:
                    // shorthand: monitor-input hdmi1
                    Console.WriteLine(Core.Switch(rest[0], selector));
                    return 0;
            }
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("Error: " + e.Message);
            return 1;
        }
    }

    static void List()
    {
        using (var mons = Monitor.All())
        {
            foreach (var m in mons)
            {
                Console.WriteLine("[{0}] {1}  {2}", m.Index, m.Device, m.HwId);
                int? cur = m.GetInput();
                Console.WriteLine("    current input: " + (cur.HasValue ? Inputs.Name(cur.Value) : "n/a (no DDC/CI reply)"));
                if (cur == null) continue;
                string caps = m.GetCapabilities();
                if (caps == null) { Console.WriteLine("    capabilities: n/a (monitor did not answer)"); continue; }
                var info = MonitorInfo.FromCapabilities(caps);
                if (info.Model != null) Console.WriteLine("    model: " + info.Model);
                if (info.Inputs.Count > 0)
                    Console.WriteLine("    advertised inputs: " + string.Join(", ", info.Inputs.Select(Inputs.Name)));
            }
            if (mons.Count == 0) Console.WriteLine("No monitors found");
        }
    }

    static void Usage()
    {
        Console.WriteLine(@"monitor-input - switch monitor input source via DDC/CI (VCP 0x60)

  monitor-input list                 show monitors, current and supported inputs
  monitor-input get                  print current input
  monitor-input set <input>          switch input
  monitor-input <input>              same as set
  monitor-input set dp,hdmi1         toggle/cycle between inputs

  -m, --monitor <sel>   auto (default) | index from 'list' | id substring (e.g. AUS27AF)

  inputs: dp, dp2, hdmi1, hdmi2, hdmi3, hdmi4, usbc, usbc2, dvi, or a raw value (17, 0x11)");
    }
}
#else
static class Program
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static void Main()
    {
        bool created;
        using (new Mutex(true, "MonitorInputTray", out created))
        {
            if (!created) return;
            SetProcessDPIAware();   // crisp text on scaled displays
            Application.EnableVisualStyles();
            Application.Run(new TrayContext());
        }
    }
}

class TrayContext : ApplicationContext
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    const int WM_SYSCOMMAND = 0x0112, SC_MONITORPOWER = 0xF170;

    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8, MOD_NOREPEAT = 0x4000;
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string AppName = "MonitorInputTray";

    readonly NotifyIcon icon;
    readonly HotkeyWindow window;
    readonly InputPicker picker;
    readonly string configPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "monitor-input.ini");
    readonly List<string> actions = new List<string>();
    string selector = "auto";

    public TrayContext()
    {
        window = new HotkeyWindow(id => Run(actions[id]));
        picker = new InputPicker(() => selector, SleepDisplays);
        icon = new NotifyIcon { Icon = LoadAppIcon(SystemInformation.SmallIconSize), Text = "Monitor input", Visible = true };
        icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) picker.Toggle(); };
        LoadConfig();
        picker.Warmup();
    }

    // app.ico is embedded by build.cmd; Icon(stream, size) picks the closest size (16/20/24/32... for the DPI).
    public static Icon LoadAppIcon(Size size)
    {
        using (var s = typeof(TrayContext).Assembly.GetManifestResourceStream("app.ico"))
            return s != null ? new Icon(s, size) : SystemIcons.Application;
    }

    void LoadConfig()
    {
        for (int i = 0; i < actions.Count; i++) UnregisterHotKey(window.Handle, i);
        actions.Clear();
        selector = "auto";

        if (!File.Exists(configPath))
            File.WriteAllText(configPath,
                "# hotkey = input   (input: dp, dp2, hdmi1, hdmi2, usbc, raw value, or a list to toggle: dp,hdmi1)\r\n" +
                "# monitor = auto | index | id substring (see: monitor-input.exe list)\r\n" +
                "monitor = auto\r\n" +
                "Ctrl+Alt+1 = dp\r\n" +
                "Ctrl+Alt+2 = hdmi1\r\n" +
                "Ctrl+Alt+3 = hdmi2\r\n");

        var menu = new ContextMenuStrip();
        var open = new ToolStripMenuItem("Choose input...");
        open.Font = new Font(open.Font, FontStyle.Bold);
        open.Click += (s, e) => picker.ShowAtCursor();
        menu.Items.Add(open);
        menu.Items.Add("Sleep display", null, (s, e) => SleepDisplays());
        menu.Items.Add(new ToolStripSeparator());
        var errors = new List<string>();
        foreach (var raw in File.ReadAllLines(configPath))
        {
            var line = raw.Split('#')[0].Trim();
            int eq = line.IndexOf('=');
            if (eq < 0) continue;
            string key = line.Substring(0, eq).Trim(), val = line.Substring(eq + 1).Trim();
            if (key.Equals("monitor", StringComparison.OrdinalIgnoreCase)) { selector = val; continue; }

            uint mods, vk;
            if (!ParseHotkey(key, out mods, out vk)) { errors.Add("bad hotkey: " + key); continue; }
            int id = actions.Count;
            actions.Add(val);
            if (!RegisterHotKey(window.Handle, id, mods | MOD_NOREPEAT, vk))
                errors.Add(key + " is already taken by another app");
            string action = val;
            menu.Items.Add(val + "\t" + key, null, (s, e) => Run(action));
        }

        menu.Items.Add(new ToolStripSeparator());
        var autostart = new ToolStripMenuItem("Start with Windows") { Checked = IsAutostart() };
        autostart.Click += (s, e) => { SetAutostart(!autostart.Checked); autostart.Checked = IsAutostart(); };
        menu.Items.Add(autostart);
        menu.Items.Add("Edit hotkeys...", null, (s, e) => System.Diagnostics.Process.Start("notepad.exe", "\"" + configPath + "\""));
        menu.Items.Add("Reload hotkeys", null, (s, e) => LoadConfig());
        menu.Items.Add("Exit", null, (s, e) => { icon.Visible = false; Application.Exit(); });
        icon.ContextMenuStrip = menu;

        if (errors.Count > 0) icon.ShowBalloonTip(5000, "Monitor input", string.Join("\n", errors), ToolTipIcon.Warning);
    }

    void Run(string spec)
    {
        // DDC/CI is slow (~50-100 ms per command); keep the UI thread free.
        ThreadPool.QueueUserWorkItem(_ =>
        {
            try { Core.Switch(spec, selector); }
            catch (Exception e) { icon.ShowBalloonTip(3000, "Monitor input", e.Message, ToolTipIcon.Error); }
        });
    }

    static bool ParseHotkey(string s, out uint mods, out uint vk)
    {
        mods = 0; vk = 0;
        foreach (var part in s.Split('+').Select(p => p.Trim()))
        {
            switch (part.ToLowerInvariant())
            {
                case "ctrl": case "control": mods |= MOD_CONTROL; continue;
                case "alt": mods |= MOD_ALT; continue;
                case "shift": mods |= MOD_SHIFT; continue;
                case "win": mods |= MOD_WIN; continue;
            }
            string k = part.Length == 1 && char.IsDigit(part[0]) ? "D" + part : part;
            Keys key;
            if (!Enum.TryParse(k, true, out key)) return false;
            vk = (uint)key;
        }
        return vk != 0;
    }

    static bool IsAutostart()
    {
        using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(AppName) != null;
    }

    static void SetAutostart(bool on)
    {
        using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
        {
            if (on) k.SetValue(AppName, "\"" + Application.ExecutablePath + "\"");
            else k.DeleteValue(AppName, false);
        }
    }

    // Turns the display(s) off right away (the PC keeps running), like the display sleep timer would.
    // SC_MONITORPOWER is handled by DefWindowProc of any window; posting it to our own hidden window avoids
    // a blocking HWND_BROADCAST. The short delay lets the click finish so the mouse-up doesn't wake the screen.
    void SleepDisplays()
    {
        IntPtr hwnd = window.Handle;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Thread.Sleep(500);
            PostMessage(hwnd, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)2);   // 2 = power off
        });
    }

    class HotkeyWindow : NativeWindow
    {
        readonly Action<int> onHotkey;
        public HotkeyWindow(Action<int> onHotkey) { this.onHotkey = onHotkey; CreateHandle(new CreateParams()); }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) onHotkey(m.WParam.ToInt32());   // WM_HOTKEY
            base.WndProc(ref m);
        }
    }
}

// Small popup above the tray: shows the monitor, its current input and one button per supported input.
class InputPicker : Form
{
    static readonly int[] FallbackInputs = { 0x0F, 0x11, 0x12 };

    readonly Func<string> getSelector;
    readonly Label title = new Label { AutoSize = true, Margin = new Padding(0, 0, 0, 8) };
    readonly FlowLayoutPanel buttons = new FlowLayoutPanel
    {
        FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, Margin = Padding.Empty
    };
    // Capabilities take about a second to read, so they are fetched once (Warmup) and cached per monitor id.
    readonly object sync = new object();
    MonitorInfo cachedInfo;
    string cachedId, cachedName;
    int? lastInput;
    DateTime hiddenAt;
    Point anchor;

    class Snapshot
    {
        public string Name, Error;
        public int? Current;
        public List<int> Inputs;
    }

    public InputPicker(Func<string> getSelector, Action sleepDisplays)
    {
        this.getSelector = getSelector;
        Text = "Monitor input";
        Icon = TrayContext.LoadAppIcon(SystemInformation.IconSize);
        Font = new Font("Segoe UI", 10f);
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);
        KeyPreview = true;

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true };
        layout.Controls.Add(title);
        layout.Controls.Add(buttons);

        // Separator + "Sleep display", same as the macOS popover; independent of DDC, so always shown.
        layout.Controls.Add(new Label { BorderStyle = BorderStyle.Fixed3D, AutoSize = false, Width = 220, Height = 2, Margin = new Padding(0, 4, 0, 8) });
        var sleep = new Button { Text = "Sleep display", Width = 220, Height = 38, Margin = Padding.Empty };
        sleep.Click += (s, e) => { HidePicker(); sleepDisplays(); };
        layout.Controls.Add(sleep);
        Controls.Add(layout);

        Deactivate += (s, e) => HidePicker();
        KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) HidePicker(); };
    }

    public void Toggle()
    {
        // Clicking the tray icon deactivates (and hides) the popup first; don't reopen it on that same click.
        if (Visible || (DateTime.Now - hiddenAt).TotalMilliseconds < 300) HidePicker();
        else ShowAtCursor();
    }

    // Reads the monitor name and supported inputs in the background right after startup.
    public void Warmup()
    {
        string selector = getSelector();
        ThreadPool.QueueUserWorkItem(_ => Read(selector));
    }

    public void ShowAtCursor()
    {
        anchor = Cursor.Position;
        // Show cached buttons immediately, then refresh the current input (~100 ms over DDC).
        Snapshot cached = null;
        lock (sync)
        {
            if (cachedInfo != null)
                cached = new Snapshot { Name = cachedName, Current = lastInput, Inputs = cachedInfo.Inputs };
        }
        if (cached != null) Render(cached);
        else { title.Text = "Reading monitor..."; buttons.Controls.Clear(); }

        Show();
        PlaceAtAnchor();
        Activate();

        string selector = getSelector();
        ThreadPool.QueueUserWorkItem(_ =>
        {
            var fresh = Read(selector);
            BeginInvoke(new Action(() => Render(fresh)));
        });
    }

    Snapshot Read(string selector)
    {
        var snap = new Snapshot();
        try
        {
            using (var mons = Monitor.All())
            {
                var mon = mons.Select(selector);
                if (mon == null) { snap.Error = "No DDC/CI monitor found"; return snap; }
                snap.Current = mon.GetInput();

                MonitorInfo info;
                lock (sync) info = cachedId == mon.HwId ? cachedInfo : null;
                if (info == null) info = MonitorInfo.FromCapabilities(mon.GetCapabilities());

                snap.Name = info.Model ?? mon.HwId;
                snap.Inputs = info.Inputs;
                lock (sync)
                {
                    cachedInfo = info;
                    cachedId = mon.HwId;
                    cachedName = snap.Name;
                    lastInput = snap.Current;
                }
            }
        }
        catch (Exception e) { snap.Error = e.Message; }
        return snap;
    }

    void Render(Snapshot snap)
    {
        Render(snap.Name, snap.Current, snap.Inputs, snap.Error);
    }

    void Render(string name, int? current, List<int> inputs, string error)
    {
        buttons.Controls.Clear();
        if (error != null) { title.Text = error; PlaceAtAnchor(); return; }

        title.Text = name + "  -  " + (current.HasValue ? Inputs.Label(current.Value) : "input unknown");
        var list = (inputs != null && inputs.Count > 0 ? inputs : FallbackInputs.ToList()).Distinct().OrderBy(v => v);
        foreach (int value in list)
        {
            bool active = current == value;
            var b = new Button
            {
                Text = (active ? "●  " : "") + Inputs.Label(value),
                Width = 220,
                Height = 38,
                Margin = new Padding(0, 0, 0, 4),
                Font = active ? new Font(Font, FontStyle.Bold) : Font,
            };
            int target = value;
            b.Click += (s, e) => Switch(target, name);
            buttons.Controls.Add(b);
        }
        PlaceAtAnchor();
    }

    void Switch(int target, string name)
    {
        foreach (Control c in buttons.Controls) c.Enabled = false;
        title.Text = "Switching to " + Inputs.Label(target) + "...";
        string selector = getSelector();
        ThreadPool.QueueUserWorkItem(_ =>
        {
            string error = null;
            try { Core.Switch(target.ToString(), selector); }
            catch (Exception e) { error = e.Message; }
            BeginInvoke(new Action(() =>
            {
                if (error == null)
                {
                    lock (sync) lastInput = target;
                    HidePicker();   // the picture usually leaves this PC anyway
                }
                else Render(name, null, null, error);
            }));
        });
    }

    // Centered horizontally on the click point, above it (below it when there is no room, e.g. a top taskbar),
    // kept inside the working area. Uses the point saved on open, since Render re-places it after a resize.
    void PlaceAtAnchor()
    {
        const int gap = 8;
        var area = Screen.FromPoint(anchor).WorkingArea;
        int x = anchor.X - Width / 2;
        int y = anchor.Y - Height - gap;
        if (y < area.Top) y = anchor.Y + gap;
        x = Math.Max(area.Left, Math.Min(x, area.Right - Width));
        y = Math.Max(area.Top, Math.Min(y, area.Bottom - Height));
        Location = new Point(x, y);
    }

    void HidePicker()
    {
        if (!Visible) return;
        Hide();
        hiddenAt = DateTime.Now;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; HidePicker(); }
        base.OnFormClosing(e);
    }
}
#endif
