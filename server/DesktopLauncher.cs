using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

internal sealed class DesktopLauncher : Form
{
    private const string HealthUrl = "https://127.0.0.1:8787/health";
    private static readonly string Config = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PrivateNAS");
    private readonly Label status = new Label();
    private readonly Button start = new Button();
    private readonly TextBox username = new TextBox();
    private readonly TextBox password = new TextBox();
    private readonly FlowLayoutPanel setup = new FlowLayoutPanel();
    private readonly TextBox details = new TextBox();
    private readonly Timer timer = new Timer();
    private bool checking;
    private bool launching;

    [STAThread]
    private static void Main(string[] args)
    {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 1 && args[0] == "--check") {
            using (var process = RunPortable("--check", true)) {
                process.WaitForExit();
                Environment.ExitCode = process.ExitCode;
            }
            return;
        }
        if (args.Length == 1 && args[0] == "--firewall") {
            using (RunPortable("--firewall", false)) { }
            return;
        }
        Application.Run(new DesktopLauncher());
    }

    private static Process RunPortable(string mode, bool hidden)
    {
        byte[] payload;
        using (var resource = typeof(DesktopLauncher).Assembly.GetManifestResourceStream("PrivateNAS.bat"))
        using (var output = new MemoryStream()) {
            resource.CopyTo(output);
            payload = output.ToArray();
        }
        string version;
        using (var sha = SHA256.Create()) version = BitConverter.ToString(sha.ComputeHash(payload)).Replace("-", "");
        var folder = Path.Combine(Config, "launcher");
        Directory.CreateDirectory(folder);
        var batch = Path.Combine(folder, version + ".bat");
        if (!File.Exists(batch)) File.WriteAllBytes(batch, payload);
        var info = new ProcessStartInfo {
            FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
            Arguments = "/d /s /c \"\"%PRIVATE_NAS_EXE_BATCH%\" " + mode + "\"",
            WorkingDirectory = folder,
            UseShellExecute = false, CreateNoWindow = hidden
        };
        info.EnvironmentVariables["PRIVATE_NAS_EXE_BATCH"] = batch;
        if (mode == "--gui") {
            info.RedirectStandardInput = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
        }
        return Process.Start(info);
    }

    private DesktopLauncher()
    {
        Text = "私人网盘";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(480, 370);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 11);

        var heading = new Label { Text = "私人网盘服务", Font = new Font(Font, FontStyle.Bold),
            AutoSize = true, Location = new Point(24, 24) };
        status.SetBounds(24, 65, 432, 65);
        status.Text = "正在检查服务…";
        start.Text = "启动服务";
        start.SetBounds(24, 310, 142, 36);
        start.Click += async (sender, args) => await StartServer();
        var folder = new Button { Text = "打开网盘文件夹" };
        folder.SetBounds(180, 310, 164, 36);
        folder.Click += (sender, args) => {
            string folderPath = Directory.Exists(@"E:\") ? @"E:\PrivateNAS" :
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PrivateNAS-Files");
            if (Directory.Exists(folderPath)) Process.Start("explorer.exe", "\"" + folderPath + "\"");
        };
        setup.SetBounds(24, 135, 432, 65);
        setup.WrapContents = true;
        setup.Controls.Add(new Label { Text = "网盘用户名", Width = 104 });
        username.Width = 300;
        setup.Controls.Add(username);
        setup.Controls.Add(new Label { Text = "网盘密码", Width = 104 });
        password.Width = 300;
        password.UseSystemPasswordChar = true;
        setup.Controls.Add(password);
        setup.Visible = !File.Exists(Path.Combine(Config, "account.json"));
        details.SetBounds(24, 205, 432, 85);
        details.Multiline = true;
        details.ReadOnly = true;
        details.ScrollBars = ScrollBars.Vertical;
        details.Visible = false;
        Controls.AddRange(new Control[] { heading, status, setup, details, start, folder });
        timer.Interval = 2500;
        timer.Tick += async (sender, args) => await RefreshStatus();
        Shown += async (sender, args) => {
            timer.Start();
            if (setup.Visible) await RefreshStatus();
            else await StartServer();
        };
        FormClosed += (sender, args) => timer.Dispose();
    }

    private async Task StartServer()
    {
        if (launching) return;
        if (setup.Visible && (string.IsNullOrWhiteSpace(username.Text) ||
            password.Text.Length < 8 || password.Text.Length > 12)) {
            status.Text = "请输入网盘用户名和 8–12 位密码。";
            return;
        }
        launching = true;
        start.Enabled = false;
        try {
            status.Text = "正在启动服务…";
            if (!await Task.Run((Func<bool>)IsOnline)) {
                using (var process = RunPortable("--gui", true)) {
                    var output = process.StandardOutput.ReadToEndAsync();
                    var errors = process.StandardError.ReadToEndAsync();
                    using (var input = process.StandardInput) {
                        if (setup.Visible) {
                            var bytes = Encoding.UTF8.GetBytes(username.Text.Trim() + "\n" + password.Text + "\n");
                            try { input.BaseStream.Write(bytes, 0, bytes.Length); }
                            finally { Array.Clear(bytes, 0, bytes.Length); password.Clear(); }
                        }
                    }
                    await Task.Run(() => process.WaitForExit());
                    string message = (await output + await errors).Trim();
                    if (!IsDisposed) {
                        details.Text = message;
                        setup.Visible = !File.Exists(Path.Combine(Config, "account.json"));
                        if (process.ExitCode != 0 && details.Text.Length == 0)
                            details.Text = "启动失败，请检查网盘配置。";
                        details.Visible = !string.IsNullOrWhiteSpace(details.Text);
                    }
                }
            }
        } catch (Exception error) {
            if (!IsDisposed) {
                details.Text = error.Message;
                details.Visible = true;
            }
        } finally {
            launching = false;
        }
        await RefreshStatus();
    }

    private async Task RefreshStatus()
    {
        if (launching || checking) return;
        checking = true;
        try {
            bool online = await Task.Run((Func<bool>)IsOnline);
            if (IsDisposed || launching) return;
            setup.Visible = !online && !File.Exists(Path.Combine(Config, "account.json"));
            status.Text = online ? "服务运行中\r\n关闭此窗口后，网盘仍在后台运行。" :
                setup.Visible ? "首次使用，请设置网盘账号后点击启动。" : "服务未运行";
            start.Enabled = !online;
        } finally { checking = false; }
    }

    private bool IsOnline()
    {
        try {
            var path = Path.Combine(Config, "server-cert.pem");
            string expected = File.Exists(path)
                ? Convert.ToBase64String(Convert.FromBase64String(File.ReadAllText(path)
                    .Replace("-----BEGIN CERTIFICATE-----", "").Replace("-----END CERTIFICATE-----", "")))
                : Convert.ToBase64String(File.ReadAllBytes(Path.Combine(Config, "portable.cer")));
            var request = (HttpWebRequest)WebRequest.Create(HealthUrl);
            request.Proxy = null;
            request.Timeout = 1200;
            request.ReadWriteTimeout = 1200;
            request.AllowAutoRedirect = false;
            request.ServerCertificateValidationCallback = (sender, certificate, chain, errors) =>
                certificate != null && Convert.ToBase64String(certificate.GetRawCertData()) == expected;
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var contents = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
                return response.StatusCode == HttpStatusCode.OK && contents.ReadToEnd() == "{\"ok\":true}";
            }
        } catch { return false; }
    }
}
