using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.ServiceProcess;

namespace DonghaengSolution
{
    public sealed class CertificateBrokerService : ServiceBase
    {
        private Process child;

        public CertificateBrokerService()
        {
            ServiceName = "DonghaengCertificateBroker";
            CanStop = true;
            AutoLog = true;
        }

        protected override void OnStart(string[] args)
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string secretPath = Path.Combine(root, "control-token.dpapi");
            string serverPath = Path.Combine(root, "server.mjs");
            string nodePath = @"C:\Program Files\nodejs\node.exe";
            if (!File.Exists(secretPath) || !File.Exists(serverPath) || !File.Exists(nodePath))
                throw new InvalidOperationException("Required broker file is missing.");

            byte[] encrypted = File.ReadAllBytes(secretPath);
            byte[] token = null;
            try
            {
                token = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.LocalMachine);
                var start = new ProcessStartInfo(nodePath, "\"" + serverPath + "\"")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    WorkingDirectory = root
                };
                start.EnvironmentVariables["WORKER_CONTROL_TOKEN"] = Convert.ToBase64String(token);
                start.EnvironmentVariables["WORKER_HOST"] = "127.0.0.1";
                start.EnvironmentVariables["WORKER_PORT"] = "47821";
                child = new Process { StartInfo = start, EnableRaisingEvents = true };
                child.OutputDataReceived += delegate { };
                child.ErrorDataReceived += delegate { };
                if (!child.Start()) throw new InvalidOperationException("Node broker did not start.");
                child.BeginOutputReadLine();
                child.BeginErrorReadLine();
            }
            finally
            {
                Array.Clear(encrypted, 0, encrypted.Length);
                if (token != null) Array.Clear(token, 0, token.Length);
            }
        }

        protected override void OnStop()
        {
            if (child == null) return;
            try
            {
                if (!child.HasExited)
                {
                    child.Kill();
                    child.WaitForExit(5000);
                }
            }
            finally
            {
                child.Dispose();
                child = null;
            }
        }

        public static void Main()
        {
            ServiceBase.Run(new CertificateBrokerService());
        }
    }
}
