// Decks Visuals for Windows: shows the visuals site full screen and feeds it the PC's own sound
// (everything playing: the Spotify app, YouTube, rekordbox) via WASAPI loopback. No browser, no sharing bar.
using System;
using System.Drawing;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using NAudio.Wave;

namespace DecksVisuals
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new MainForm());
        }
    }

    class MainForm : Form
    {
        const string SiteUrl = "https://jondik14.github.io/visuals-/";
        const string SiteHost = "jondik14.github.io";

        readonly WebView2 web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Black };
        WasapiLoopbackCapture capture;
        float[] pending = new float[8192];
        int pendingCount;
        bool triedOffline;
        FormWindowState prevState = FormWindowState.Normal;
        FormBorderStyle prevBorder = FormBorderStyle.Sizable;

        public MainForm()
        {
            Text = "Decks Visuals";
            BackColor = Color.Black;
            Width = 1280;
            Height = 800;
            StartPosition = FormStartPosition.CenterScreen;
            Controls.Add(web);
            Load += async (s, e) => await InitWeb();
            FormClosing += (s, e) => StopAudio();
        }

        async Task InitWeb()
        {
            var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DecksVisuals");
            try
            {
                var env = await CoreWebView2Environment.CreateAsync(null, dataDir);
                await web.EnsureCoreWebView2Async(env);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Decks Visuals needs Microsoft Edge WebView2, which comes with Windows 10 and 11. " +
                                "Install the WebView2 Runtime from Microsoft and try again.\n\n" + ex.Message, "Decks Visuals");
                Close();
                return;
            }
            var core = web.CoreWebView2;
            // The page talks to the Mac app through window.webkit; give it the same door here.
            await core.AddScriptToExecuteOnDocumentCreatedAsync(
                "window.webkit={messageHandlers:{decks:{postMessage:m=>window.chrome.webview.postMessage(JSON.stringify(m))}}};");
            core.WebMessageReceived += OnMessage;
            core.PermissionRequested += (s, e) =>
            {
                if (e.PermissionKind == CoreWebView2PermissionKind.Microphone && Uri.TryCreate(e.Uri, UriKind.Absolute, out var u) && u.Host == SiteHost)
                    e.State = CoreWebView2PermissionState.Allow;
            };
            core.ContainsFullScreenElementChanged += (s, e) => SetFullScreen(core.ContainsFullScreenElement);
            core.NavigationCompleted += (s, e) => { if (!e.IsSuccess && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled) LoadOffline(); };
            core.NewWindowRequested += (s, e) => e.Handled = true;   // the browser-only helper tab isn't needed here
            core.Navigate(SiteUrl);
        }

        void LoadOffline()
        {
            var file = Path.Combine(AppContext.BaseDirectory, "site", "index.html");
            if (triedOffline || !File.Exists(file)) return;
            triedOffline = true;
            web.CoreWebView2.Navigate(new Uri(file).AbsoluteUri);
        }

        void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            string cmd;
            try
            {
                using var doc = JsonDocument.Parse(e.TryGetWebMessageAsString());
                cmd = doc.RootElement.GetProperty("cmd").GetString();
            }
            catch { return; }
            if (cmd == "startAudio") StartAudio();
            else if (cmd == "fullscreen") SetFullScreen(FormBorderStyle != FormBorderStyle.None);
        }

        void StartAudio()
        {
            if (capture != null) { Js("window.__decksNativeReady&&__decksNativeReady()"); return; }
            try
            {
                var c = new WasapiLoopbackCapture();
                c.DataAvailable += OnData;
                c.RecordingStopped += (s, e) =>
                {
                    if (e.Exception != null)
                        UI(() => CallPage("__decksNativeError", "Stopped listening (" + e.Exception.Message + "). Click 'This computer's sound' to start again."));
                    UI(() => { capture?.Dispose(); capture = null; });
                };
                c.StartRecording();
                capture = c;
                Js("window.__decksNativeReady&&__decksNativeReady()");
            }
            catch (Exception ex)
            {
                capture = null;
                CallPage("__decksNativeError", "Couldn't listen to this PC's sound: " + ex.Message);
            }
        }

        void StopAudio()
        {
            try { capture?.StopRecording(); } catch { }
        }

        // Runs on the capture thread: mix to mono, send ~20 ms blocks to the page as base64 Float32.
        void OnData(object sender, WaveInEventArgs a)
        {
            var wf = (sender as WasapiLoopbackCapture)?.WaveFormat;
            if (wf == null || a.BytesRecorded == 0) return;
            int ch = Math.Max(1, wf.Channels), bytesPer = wf.BitsPerSample / 8;
            bool isFloat = wf.Encoding == WaveFormatEncoding.IeeeFloat || (wf.Encoding == WaveFormatEncoding.Extensible && wf.BitsPerSample == 32);
            if (!isFloat && bytesPer != 2) return;
            int frames = a.BytesRecorded / (bytesPer * ch);
            for (int i = 0; i < frames; i++)
            {
                float sum = 0;
                for (int c = 0; c < ch; c++)
                {
                    int o = (i * ch + c) * bytesPer;
                    sum += isFloat ? BitConverter.ToSingle(a.Buffer, o) : BitConverter.ToInt16(a.Buffer, o) / 32768f;
                }
                if (pendingCount == pending.Length) Array.Resize(ref pending, pending.Length * 2);
                pending[pendingCount++] = sum / ch;
            }
            if (pendingCount < 1024) return;
            var bytes = new byte[pendingCount * 4];
            Buffer.BlockCopy(pending, 0, bytes, 0, bytes.Length);
            pendingCount = 0;
            var js = "window.__decksPCM&&__decksPCM('" + Convert.ToBase64String(bytes) + "')";
            UI(() => Js(js));
        }

        void SetFullScreen(bool on)
        {
            if (on == (FormBorderStyle == FormBorderStyle.None)) return;
            if (on)
            {
                prevState = WindowState;
                prevBorder = FormBorderStyle;
                FormBorderStyle = FormBorderStyle.None;
                WindowState = FormWindowState.Normal;
                WindowState = FormWindowState.Maximized;
            }
            else
            {
                FormBorderStyle = prevBorder;
                WindowState = prevState;
            }
        }

        void UI(Action a)
        {
            if (IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(a); } catch (InvalidOperationException) { }
        }

        void Js(string script)
        {
            if (web.CoreWebView2 != null) _ = web.CoreWebView2.ExecuteScriptAsync(script);
        }

        void CallPage(string fn, string arg) => Js("window." + fn + "&&" + fn + "(" + JsonSerializer.Serialize(arg) + ")");
    }
}
