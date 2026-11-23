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
    private readonly Button chooseFolder = new Button();
    private readonly TextBox rootPath = new TextBox();
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
        ClientSize = new Size(520, 438);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 11);

        var heading = new Label { Text = "私人网盘服务", Font = new Font(Font, FontStyle.Bold),
            AutoSize = true, Location = new Point(24, 24) };
        status.SetBounds(24, 62, 472, 48);
        status.Text = "正在检查服务…";
        start.Text = "启动服务";
        start.SetBounds(24, 376, 142, 36);
        start.Click += async (sender, args) => await StartServer();
        var folder = new Button { Text = "打开网盘文件夹" };
        folder.SetBounds(180, 376, 164, 36);
        folder.Click += (sender, args) => {
            string folderPath = rootPath.Text;
            if (Directory.Exists(folderPath)) Process.Start("explorer.exe", "\"" + folderPath + "\"");
            else ShowDetails("网盘目录不存在，请重新选择。");
        };
        var rootLabel = new Label { Text = "网盘目录", AutoSize = true, Location = new Point(24, 115) };
        rootPath.SetBounds(24, 143, 330, 32);
        rootPath.ReadOnly = true;
        rootPath.Text = ReadStorageRoot();
        chooseFolder.Text = "选择文件夹…";
        chooseFolder.SetBounds(366, 140, 130, 34);
        chooseFolder.Click += (sender, args) => ChooseStorageRoot();
        setup.SetBounds(24, 188, 472, 65);
        setup.WrapContents = true;
        setup.Controls.Add(new Label { Text = "网盘用户名", Width = 104 });
        username.Width = 300;
        setup.Controls.Add(username);
        setup.Controls.Add(new Label { Text = "网盘密码", Width = 104 });
        password.Width = 300;
        password.UseSystemPasswordChar = true;
        setup.Controls.Add(password);
        setup.Visible = !File.Exists(Path.Combine(Config, "account.json"));
        details.SetBounds(24, 262, 472, 92);
        details.Multiline = true;
        details.ReadOnly = true;
        details.ScrollBars = ScrollBars.Vertical;
        details.Visible = false;
        Controls.AddRange(new Control[] { heading, status, rootLabel, rootPath, chooseFolder, setup, details, start, folder });
        timer.Interval = 2500;
        timer.Tick += async (sender, args) => await RefreshStatus();
        Shown += async (sender, args) => {
            timer.Start();
            if (setup.Visible) await RefreshStatus();
            else await StartServer();
        };
        FormClosed += (sender, args) => timer.Dispose();
    }

    private static string RootSetting { get { return Path.Combine(Config, "storage-root.txt"); } }

    private static string ReadStorageRoot()
    {
        try {
            if (File.Exists(RootSetting)) {
                string selected = File.ReadAllText(RootSetting).Trim();
                if (!string.IsNullOrEmpty(selected)) return selected;
            }
        } catch (IOException) { }
        return Directory.Exists(@"E:\") ? @"E:\PrivateNAS" :
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PrivateNAS-Files");
    }

    private void ShowDetails(string message)
    {
        details.Text = message;
        details.Visible = true;
    }

    private void ChooseStorageRoot()
    {
        using (var picker = new FolderBrowserDialog {
            Description = "选择要作为网盘根目录的文件夹", SelectedPath = rootPath.Text, ShowNewFolderButton = true
        }) {
            if (picker.ShowDialog(this) != DialogResult.OK) return;
            try {
                string selected = Path.GetFullPath(picker.SelectedPath);
                if (string.Equals(selected, rootPath.Text, StringComparison.OrdinalIgnoreCase)) return;
                if (!Directory.Exists(selected)) throw new IOException("所选文件夹不存在。");
                string folderPrefix = selected.TrimEnd('\\') + "\\";
                string configPrefix = Config.TrimEnd('\\') + "\\";
                if (configPrefix.StartsWith(folderPrefix, StringComparison.OrdinalIgnoreCase) ||
                    folderPrefix.StartsWith(configPrefix, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("该目录与网盘配置目录重叠，请选择一个独立的文件夹。");
                if (MessageBox.Show(this, "将此目录作为手机端的网盘根目录？\r\n\r\n" + selected,
                    "切换网盘目录", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
                Directory.CreateDirectory(Config);
                string temp = Path.Combine(Config, Guid.NewGuid().ToString("N") + ".tmp");
                try {
                    File.WriteAllText(temp, selected, new UTF8Encoding(false));
                    if (File.Exists(RootSetting)) File.Replace(temp, RootSetting, null);
                    else File.Move(temp, RootSetting);
                } finally { if (File.Exists(temp)) File.Delete(temp); }
                rootPath.Text = selected;
                ShowDetails("网盘目录已保存。如果手机已连接，请重新登录。");
            } catch (Exception error) { ShowDetails(error.Message); }
        }
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
        chooseFolder.Enabled = false;
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
            if (!IsDisposed) chooseFolder.Enabled = true;
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
