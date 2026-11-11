// joggo-setup.exe: download one pinned joggo release, check it, and run the installer's wizard.
//
// Built by setup/build.ps1, which fills in VERSION and ZIP_SHA256 for the release zip it makes
// from a tagged commit. The exe trusts nothing it downloads until the zip's SHA-256 matches the
// value compiled into it, so a signed joggo-setup.exe vouches for exactly one release and
// nothing else: a swapped asset, a truncated download or a tampered mirror all stop here.
//
// It runs no installer logic of its own. Everything after the download is install.ps1 -Wizard,
// the same path a person gets from a git clone, in this same console window.
//
// C# 5 on purpose: compiled by the csc.exe that ships with .NET Framework 4.8 in every
// Windows 10/11, so the exe needs no runtime installed first.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;

static class JoggoSetup
{
    const string VERSION = "@VERSION@";
    const string ZIP_SHA256 = "@ZIP_SHA256@";
    const string REPO = "telluric-dev/joggo";

    static int Main(string[] args)
    {
        foreach (var a in args)
        {
            if (a == "--version") { Console.WriteLine("joggo-setup " + VERSION); return 0; }
            if (a == "--help" || a == "-h" || a == "/?") { Usage(); return 0; }
        }

        Console.WriteLine("joggo " + VERSION + " setup");
        Console.WriteLine("  A self-hosted GitHub Actions runner for this Windows PC (WSL2).");
        Console.WriteLine("  Source: https://github.com/" + REPO);
        Console.WriteLine();

        string zipName = "joggo-" + VERSION + ".zip";
        string home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "joggo");
        string dest = Path.Combine(home, VERSION);
        string zipPath = Path.Combine(home, zipName);

        try
        {
            Directory.CreateDirectory(home);

            // A zip next to the exe is used instead of downloading (offline installs), but it is
            // held to the same hash: being local makes it no more trustworthy.
            string beside = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, zipName);
            if (File.Exists(beside))
            {
                Console.WriteLine("Using " + beside);
                File.Copy(beside, zipPath, true);
            }
            else
            {
                string url = "https://github.com/" + REPO + "/releases/download/v" + VERSION + "/" + zipName;
                Console.WriteLine("Downloading " + url);
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                try { using (var wc = new WebClient()) wc.DownloadFile(url, zipPath); }
                catch (WebException e) { return Fail("could not download " + url + " (" + e.Message + "). Check the network, or put " + zipName + " next to this exe."); }
            }

            string got = Sha256(zipPath);
            if (!string.Equals(got, ZIP_SHA256, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(zipPath);
                return Fail("the download does not match this release (SHA-256 " + got + ", expected " + ZIP_SHA256 + "). Nothing was installed.");
            }
            Console.WriteLine("Verified SHA-256 " + got);

            if (Directory.Exists(dest)) Directory.Delete(dest, true);
            ZipFile.ExtractToDirectory(zipPath, dest);
            File.Delete(zipPath);

            string installer = Path.Combine(dest, "install.ps1");
            if (!File.Exists(installer)) return Fail("install.ps1 is missing from the release zip.");

            Console.WriteLine("Extracted to " + dest);
            Console.WriteLine("Starting the installer wizard. It asks before changing anything.");
            Console.WriteLine();

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                // Bypass applies to this one process only; it does not change the machine policy.
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + installer + "\" -Wizard",
                WorkingDirectory = dest,
                UseShellExecute = false
            };
            using (var p = Process.Start(psi))
            {
                p.WaitForExit();
                Console.WriteLine();
                Console.WriteLine(p.ExitCode == 0
                    ? "joggo is installed. The files stay in " + dest + "."
                    : "The installer stopped with exit code " + p.ExitCode + ". Its messages above say why; you can re-run joggo-setup.exe.");
                Pause();
                return p.ExitCode;
            }
        }
        catch (Exception e)
        {
            return Fail(e.Message);
        }
    }

    static string Sha256(string path)
    {
        using (var sha = SHA256.Create())
        using (var f = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "").ToLowerInvariant();
    }

    static int Fail(string why)
    {
        Console.WriteLine();
        Console.WriteLine("joggo setup failed: " + why);
        Pause();
        return 1;
    }

    // A double-clicked exe closes its window the moment it exits; keep the result readable.
    static void Pause()
    {
        if (Console.IsInputRedirected) return;
        Console.WriteLine("Press Enter to close.");
        Console.ReadLine();
    }

    static void Usage()
    {
        Console.WriteLine("joggo-setup " + VERSION);
        Console.WriteLine("Downloads joggo " + VERSION + " from GitHub, verifies its SHA-256, extracts it to");
        Console.WriteLine("%LOCALAPPDATA%\\joggo\\" + VERSION + " and runs install.ps1 -Wizard.");
        Console.WriteLine("Put joggo-" + VERSION + ".zip next to this exe to install without downloading.");
    }
}
