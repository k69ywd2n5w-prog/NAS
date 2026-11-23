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
        return Process.Start(info);
    }

    private DesktopLauncher()
    {
        Text = "私人网盘";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(440, 210);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 11);

        var heading = new Label { Text = "私人网盘服务", Font = new Font(Font, FontStyle.Bold),
            AutoSize = true, Location = new Point(24, 24) };
        status.SetBounds(24, 65, 392, 62);
        status.Text = "正在检查服务…";
        start.Text = "启动服务";
        start.SetBounds(24, 145, 142, 36);
        start.Click += async (sender, args) => await StartServer();
        var folder = new Button { Text = "打开网盘文件夹" };
        folder.SetBounds(180, 145, 164, 36);
        folder.Click += (sender, args) => {
            string folderPath = Directory.Exists(@"E:\") ? @"E:\PrivateNAS" :
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PrivateNAS-Files");
            if (Directory.Exists(folderPath)) Process.Start("explorer.exe", "\"" + folderPath + "\"");
        };
        Controls.AddRange(new Control[] { heading, status, start, folder });
        timer.Interval = 2500;
        timer.Tick += async (sender, args) => await RefreshStatus();
        Shown += async (sender, args) => { timer.Start(); await StartServer(); };
        FormClosed += (sender, args) => timer.Dispose();
    }

    private async Task StartServer()
    {
        if (launching) return;
        launching = true;
        start.Enabled = false;
        try {
            status.Text = "正在启动服务…";
            if (!await Task.Run((Func<bool>)IsOnline)) {
                using (var process = RunPortable("--exe", false)) {
                    for (int count = 0; count < 12 && !process.HasExited; count++) {
                        await Task.Delay(250);
                        if (await Task.Run((Func<bool>)IsOnline)) break;
                    }
                }
            }
        } catch (Exception error) {
            MessageBox.Show(error.Message, "启动网盘失败");
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
            status.Text = online ? "服务运行中\r\n如已打开网盘控制台，请保持它运行。" :
                "服务未运行\r\n若已打开网盘控制台，请按其中的提示操作。";
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
