// Optional Windows diagnostic only. Captures the test process's unobscured
// client area from the desktop AFTER ReShade/presentation, never PrintWindow.
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace HugoNR {
    public sealed class WindowCheck {
        public bool Valid;
        public string Reason;
        public int X, Y, Width, Height;
        public long Handle;
    }
    public sealed class ImageDifference {
        public int Width, Height;
        public long Pixels, ChangedPixels, CentralPixels, CentralChangedPixels;
        public double MeanAbsoluteRgb, CentralMeanAbsoluteRgb;
        public string FirstSha256, SecondSha256;
        public bool FirstNonuniform, SecondNonuniform;
    }
    public static class ImageCapture {
        [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
        private delegate bool EnumProc(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr window, out RECT rectangle);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out RECT rectangle);
        [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr window, ref POINT point);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

        public static void ConfigureDpi() { SetProcessDPIAware(); }
        public static bool Activate(IntPtr window) { ShowWindow(window, 9); return SetForegroundWindow(window); }

        public static WindowCheck Check(IntPtr window, int processId) {
            WindowCheck result = new WindowCheck { Handle = window.ToInt64(), Reason = "window_unavailable" };
            if (window == IntPtr.Zero || !IsWindowVisible(window) || IsIconic(window)) return result;
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)processId) { result.Reason = "window_process_mismatch"; return result; }
            if (GetAncestor(GetForegroundWindow(), 2) != window) { result.Reason = "window_not_foreground"; return result; }
            RECT client;
            POINT origin = new POINT();
            if (!GetClientRect(window, out client) || !ClientToScreen(window, ref origin)) return result;
            result.X = origin.X; result.Y = origin.Y;
            result.Width = client.Right - client.Left; result.Height = client.Bottom - client.Top;
            if (result.Width < 640 || result.Height < 360) { result.Reason = "client_area_too_small"; return result; }
            Rectangle area = new Rectangle(result.X, result.Y, result.Width, result.Height);
            Rectangle desktop = new Rectangle(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79));
            if (!desktop.Contains(area)) { result.Reason = "client_area_off_desktop"; return result; }
            bool reached = false, covered = false;
            // EnumWindows visits top-level windows in Z order. Fail closed for
            // ANY visible overlapping window above the probe, including tools.
            EnumWindows(delegate(IntPtr other, IntPtr unused) {
                if (other == window) { reached = true; return false; }
                if (IsWindowVisible(other) && !IsIconic(other)) {
                    RECT bounds;
                    if (GetWindowRect(other, out bounds)) {
                        Rectangle rectangle = Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
                        if (rectangle.Width > 0 && rectangle.Height > 0 && area.IntersectsWith(rectangle)) { covered = true; return false; }
                    }
                }
                return true;
            }, IntPtr.Zero);
            if (covered || !reached) { result.Reason = "client_area_occluded"; return result; }
            result.Valid = true; result.Reason = "foreground_unoccluded_client";
            return result;
        }

        public static void ToggleNr(IntPtr window, int processId) {
            WindowCheck check = Check(window, processId);
            if (!check.Valid) throw new InvalidOperationException(check.Reason);
            keybd_event(119, 0, 0, UIntPtr.Zero); // F8: Uplift EnableKey, not all ReShade effects.
            try { System.Threading.Thread.Sleep(80); }
            finally { keybd_event(119, 0, 2, UIntPtr.Zero); }
        }

        public static WindowCheck Capture(IntPtr window, int processId, string output) {
            WindowCheck before = Check(window, processId);
            if (!before.Valid) throw new InvalidOperationException(before.Reason);
            using (Bitmap image = new Bitmap(before.Width, before.Height, PixelFormat.Format24bppRgb)) {
                using (Graphics graphics = Graphics.FromImage(image)) {
                    graphics.CopyFromScreen(before.X, before.Y, 0, 0, image.Size, CopyPixelOperation.SourceCopy);
                }
                WindowCheck after = Check(window, processId);
                if (!after.Valid || after.X != before.X || after.Y != before.Y || after.Width != before.Width || after.Height != before.Height)
                    throw new InvalidOperationException("window_changed_during_desktop_capture");
                image.Save(output, ImageFormat.Png);
            }
            return before;
        }

        private static byte[] Pixels(Bitmap source) {
            using (Bitmap rgb = new Bitmap(source.Width, source.Height, PixelFormat.Format24bppRgb)) {
                using (Graphics graphics = Graphics.FromImage(rgb)) graphics.DrawImageUnscaled(source, 0, 0);
                BitmapData data = rgb.LockBits(new Rectangle(0, 0, rgb.Width, rgb.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try {
                    byte[] packed = new byte[rgb.Width * rgb.Height * 3];
                    for (int row = 0; row < rgb.Height; ++row) Marshal.Copy(IntPtr.Add(data.Scan0, row * data.Stride), packed, row * rgb.Width * 3, rgb.Width * 3);
                    return packed;
                } finally { rgb.UnlockBits(data); }
            }
        }
        private static string Hash(byte[] bytes) {
            using (SHA256 algorithm = SHA256.Create()) return BitConverter.ToString(algorithm.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        public static ImageDifference CompareRgb(byte[] left, byte[] right, int width, int height) {
            return Calculate(left, right, width, height, new byte[left.Length]);
        }
        private static ImageDifference Calculate(byte[] left, byte[] right, int width, int height, byte[] difference) {
            if (width < 1 || height < 1 || left.Length != width * height * 3 || right.Length != left.Length) throw new ArgumentException("invalid_rgb_buffers");
            ImageDifference result = new ImageDifference { Width = width, Height = height, Pixels = (long)width * height, FirstSha256 = Hash(left), SecondSha256 = Hash(right) };
            long sum = 0, centralSum = 0;
            int x0 = width * 15 / 100, x1 = Math.Max(x0 + 1, width * 85 / 100), y0 = height * 15 / 100, y1 = Math.Max(y0 + 1, height * 85 / 100);
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                int index = (y * width + x) * 3, pixelMax = 0, pixelSum = 0;
                for (int channel = 0; channel < 3; ++channel) {
                    int at = index + channel, value = Math.Abs(left[at] - right[at]);
                    pixelMax = Math.Max(pixelMax, value); pixelSum += value;
                    difference[at] = (byte)Math.Min(255, value * 4);
                    result.FirstNonuniform |= Math.Abs(left[at] - left[channel]) > 16;
                    result.SecondNonuniform |= Math.Abs(right[at] - right[channel]) > 16;
                }
                sum += pixelSum;
                if (pixelMax > 3) ++result.ChangedPixels;
                if (x >= x0 && x < x1 && y >= y0 && y < y1) {
                    ++result.CentralPixels; centralSum += pixelSum;
                    if (pixelMax > 3) ++result.CentralChangedPixels;
                }
            }
            result.MeanAbsoluteRgb = sum / (result.Pixels * 3.0);
            result.CentralMeanAbsoluteRgb = centralSum / (result.CentralPixels * 3.0);
            return result;
        }
        public static ImageDifference Compare(string first, string second, string differencePath) {
            using (Bitmap a = new Bitmap(first)) using (Bitmap b = new Bitmap(second)) {
                if (a.Width != b.Width || a.Height != b.Height) throw new InvalidOperationException("desktop_capture_dimensions_changed");
                byte[] left = Pixels(a), right = Pixels(b), difference = new byte[left.Length];
                ImageDifference result = Calculate(left, right, a.Width, a.Height, difference);
                if (!String.IsNullOrEmpty(differencePath)) {
                    using (Bitmap picture = new Bitmap(a.Width, a.Height, PixelFormat.Format24bppRgb)) {
                        BitmapData data = picture.LockBits(new Rectangle(0, 0, a.Width, a.Height), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
                        try { for (int row = 0; row < a.Height; ++row) Marshal.Copy(difference, row * a.Width * 3, IntPtr.Add(data.Scan0, row * data.Stride), a.Width * 3); }
                        finally { picture.UnlockBits(data); }
                        picture.Save(differencePath, ImageFormat.Png);
                    }
                }
                return result;
            }
        }
    }
}
