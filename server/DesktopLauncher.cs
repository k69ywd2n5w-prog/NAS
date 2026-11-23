using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

internal sealed class DesktopLauncher : Form
{
    private const string HealthUrl = "https://127.0.0.1:8787/health";
    private readonly string node;
    private readonly string server;
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
        var window = new DesktopLauncher();
        if (args.Length == 1 && args[0] == "--check") {
            Environment.ExitCode = window.IsOnline() ? 0 : 1;
            return;
        }
        Application.Run(window);
    }

    private DesktopLauncher()
    {
        using (var settings = new StreamReader(typeof(DesktopLauncher).Assembly.GetManifestResourceStream("paths.txt"))) {
            node = settings.ReadLine();
            server = settings.ReadLine();
        }
        Text = "私人网盘";
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
            if (Directory.Exists(@"E:\PrivateNAS")) Process.Start("explorer.exe", @"E:\PrivateNAS");
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
                using (var process = Process.Start(new ProcessStartInfo {
                    FileName = node, Arguments = "\"" + server + "\" --tls",
                    WorkingDirectory = Path.GetDirectoryName(server),
                    UseShellExecute = false, CreateNoWindow = true
                })) {
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
            status.Text = online ? "服务运行中\r\n关闭此窗口后，网盘仍在后台运行。" :
                "服务未运行\r\n请检查 E 盘和网盘证书后重试。";
            start.Enabled = !online;
        } finally { checking = false; }
    }

    private bool IsOnline()
    {
        try {
            string pem = File.ReadAllText(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"PrivateNAS\server-cert.pem"));
            string expected = Convert.ToBase64String(Convert.FromBase64String(
                pem.Replace("-----BEGIN CERTIFICATE-----", "").Replace("-----END CERTIFICATE-----", "")));
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
