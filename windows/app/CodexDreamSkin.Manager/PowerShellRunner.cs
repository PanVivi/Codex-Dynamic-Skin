using System.Diagnostics;

namespace CodexDreamSkin.Manager;

internal sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
  public void ThrowIfFailed(string operation)
  {
    if (ExitCode == 0)
    {
      return;
    }

    var detail = string.IsNullOrWhiteSpace(StandardError) ? StandardOutput : StandardError;
    var suffix = string.IsNullOrWhiteSpace(detail) ? string.Empty : $"：{detail.Trim()}";
    throw new InvalidOperationException($"{operation}失败（{ExitCode}）{suffix}");
  }
}

internal sealed class PowerShellRunner
{
  private readonly RuntimeProvisioner _runtime;
  private readonly string _powershellPath;

  public PowerShellRunner(RuntimeProvisioner runtime)
  {
    _runtime = runtime;
    _powershellPath = Path.Combine(
      Environment.GetFolderPath(Environment.SpecialFolder.Windows),
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe");
    if (!File.Exists(_powershellPath))
    {
      throw new FileNotFoundException("找不到 Windows PowerShell 5.1。", _powershellPath);
    }
  }

  public async Task<ProcessResult> RunScriptAsync(
    string script,
    IEnumerable<string> arguments,
    CancellationToken cancellationToken = default,
    bool captureOutput = true)
  {
    var startInfo = new ProcessStartInfo
    {
      FileName = _powershellPath,
      WorkingDirectory = _runtime.PayloadRoot,
      UseShellExecute = false,
      CreateNoWindow = true,
    };
    if (captureOutput)
    {
      startInfo.RedirectStandardOutput = true;
      startInfo.RedirectStandardError = true;
      startInfo.StandardOutputEncoding = System.Text.Encoding.UTF8;
      startInfo.StandardErrorEncoding = System.Text.Encoding.UTF8;
    }
    startInfo.ArgumentList.Add("-NoProfile");
    startInfo.ArgumentList.Add("-ExecutionPolicy");
    startInfo.ArgumentList.Add("Bypass");
    startInfo.ArgumentList.Add("-File");
    startInfo.ArgumentList.Add(script);
    foreach (var argument in arguments)
    {
      startInfo.ArgumentList.Add(argument);
    }

    var nodeDirectory = Path.GetDirectoryName(_runtime.NodePath)!;
    startInfo.Environment["PATH"] = nodeDirectory + Path.PathSeparator +
      (startInfo.Environment.TryGetValue("PATH", out var path) ? path : Environment.GetEnvironmentVariable("PATH"));

    using var process = new Process { StartInfo = startInfo };
    process.Start();
    if (!captureOutput)
    {
      await process.WaitForExitAsync(cancellationToken);
      return new ProcessResult(process.ExitCode, string.Empty, string.Empty);
    }

    var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
    var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
    await process.WaitForExitAsync(cancellationToken);
    return new ProcessResult(
      process.ExitCode,
      await outputTask,
      await errorTask);
  }
}
