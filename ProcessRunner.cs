using System.Diagnostics;
namespace WindowsMonitoringAgent;
public sealed record ProcessOutput(int ExitCode, string StdOut, string StdErr);
public static class ProcessRunner
{
    // Arguments go through ArgumentList (no shell, no string concatenation) so config values cannot inject commands.
    public static async Task<ProcessOutput> RunAsync(string exe, IEnumerable<string> args, int timeoutSeconds, CancellationToken stop)
    {
        var info=new ProcessStartInfo(exe) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true };
        foreach(var a in args) info.ArgumentList.Add(a);
        using var proc=new Process { StartInfo=info };
        if(!proc.Start()) throw new InvalidOperationException("Could not launch "+exe);
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(stop);
        timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds,1,300)));
        var stdout=proc.StandardOutput.ReadToEndAsync();
        var stderr=proc.StandardError.ReadToEndAsync();
        try { await proc.WaitForExitAsync(timeout.Token); }
        catch(OperationCanceledException) { if(!proc.HasExited) proc.Kill(entireProcessTree:true); throw; }
        return new ProcessOutput(proc.ExitCode, await stdout, await stderr);
    }
}
