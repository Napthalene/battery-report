using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Timers;

namespace BatteryService
{
    public sealed class BatteryServiceWindowsService : ServiceBase
    {
        private const string ServiceDisplayName = "BatteryService Power Estimator";
        private readonly Timer restartTimer;
        private readonly object syncRoot = new object();
        private Process childProcess;
        private string estimatorPath;
        private string configPath;
        private string projectRoot;
        private string serviceLogPath;
        private bool stopping;

        public BatteryServiceWindowsService()
        {
            ServiceName = "BatteryServicePowerEstimator";
            CanStop = true;
            CanShutdown = true;

            restartTimer = new Timer(30000);
            restartTimer.AutoReset = false;
            restartTimer.Elapsed += delegate { StartRunner(); };
        }

        public static void Main(string[] args)
        {
            if (Environment.UserInteractive)
            {
                using (var service = new BatteryServiceWindowsService())
                {
                    service.OnStart(args);
                    Console.WriteLine(ServiceDisplayName + " running. Press Enter to stop.");
                    Console.ReadLine();
                    service.OnStop();
                }

                return;
            }

            Run(new BatteryServiceWindowsService());
        }

        protected override void OnStart(string[] args)
        {
            stopping = false;
            projectRoot = ResolveProjectRoot(args);
            estimatorPath = args != null && args.Length > 0
                ? args[0]
                : Path.Combine(projectRoot, "scripts", "estimate-power-windows.ps1");
            configPath = args != null && args.Length > 1
                ? args[1]
                : Path.Combine(projectRoot, "config", "power-estimator.windows.json");

            var logsDirectory = Path.Combine(projectRoot, "logs");
            Directory.CreateDirectory(logsDirectory);
            serviceLogPath = Path.Combine(logsDirectory, "windows-service.log");

            Log("Service starting. ProjectRoot=" + projectRoot + " Estimator=" + estimatorPath + " Config=" + configPath);
            StartRunner();
        }

        protected override void OnStop()
        {
            stopping = true;
            restartTimer.Stop();
            Log("Service stopping.");
            StopRunner();
        }

        protected override void OnShutdown()
        {
            OnStop();
        }

        private string ResolveProjectRoot(string[] args)
        {
            if (args != null && args.Length > 2 && Directory.Exists(args[2]))
            {
                return Path.GetFullPath(args[2]);
            }

            var baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            var candidate = Path.GetFullPath(Path.Combine(baseDirectory, "..", ".."));
            if (File.Exists(Path.Combine(candidate, "scripts", "run-windows-estimator.cmd")))
            {
                return candidate;
            }

            return Directory.GetCurrentDirectory();
        }

        private void StartRunner()
        {
            lock (syncRoot)
            {
                if (stopping)
                {
                    return;
                }

                if (childProcess != null && !childProcess.HasExited)
                {
                    return;
                }

                if (!File.Exists(estimatorPath))
                {
                    Log("Estimator not found: " + estimatorPath);
                    ScheduleRestart();
                    return;
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                        "System32",
                        "WindowsPowerShell",
                        "v1.0",
                        "powershell.exe"),
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
                        estimatorPath +
                        "\" -ConfigPath \"" +
                        configPath +
                        "\" -DurationSeconds 0",
                    WorkingDirectory = projectRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                childProcess = new Process();
                childProcess.StartInfo = startInfo;
                childProcess.EnableRaisingEvents = true;
                childProcess.Exited += ChildProcessExited;
                childProcess.Start();
                Log("Started runner PID " + childProcess.Id);
            }
        }

        private void StopRunner()
        {
            Process processToStop;

            lock (syncRoot)
            {
                if (childProcess == null)
                {
                    return;
                }

                processToStop = childProcess;
                childProcess = null;
            }

            try
            {
                if (!processToStop.HasExited)
                {
                    processToStop.Kill();
                    processToStop.WaitForExit(10000);
                }
            }
            catch (Exception exception)
            {
                Log("Failed to stop runner: " + exception);
            }
            finally
            {
                processToStop.Dispose();
            }
        }

        private void ChildProcessExited(object sender, EventArgs e)
        {
            var exitCode = -1;
            try
            {
                exitCode = childProcess != null ? childProcess.ExitCode : -1;
            }
            catch
            {
            }

            Log("Runner exited with code " + exitCode);

            lock (syncRoot)
            {
                if (childProcess != null)
                {
                    childProcess.Dispose();
                    childProcess = null;
                }
            }

            if (!stopping)
            {
                ScheduleRestart();
            }
        }

        private void ScheduleRestart()
        {
            if (!stopping)
            {
                restartTimer.Stop();
                restartTimer.Start();
                Log("Runner restart scheduled.");
            }
        }

        private void Log(string message)
        {
            try
            {
                if (string.IsNullOrEmpty(serviceLogPath))
                {
                    return;
                }

                File.AppendAllText(
                    serviceLogPath,
                    DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}
