using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;
using WindowsMonitoringAgent;

// Services start in C:\Windows\System32; load appsettings.json from the exe folder.
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings { Args = args, ContentRootPath = AppContext.BaseDirectory });
// Must match the service name created by deploy/install.ps1.
builder.Services.AddWindowsService(options => options.ServiceName = "OfficeMonitoringAgent");
builder.Logging.AddConsole();
builder.Services.Configure<AgentOptions>(builder.Configuration.GetSection("Agent"));
builder.Services.AddSingleton<SqliteStore>();
builder.Services.AddHttpClient("monitor", client => client.Timeout = TimeSpan.FromSeconds(20));
builder.Services.AddSingleton<FolderAgent>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<FolderAgent>());
builder.Services.AddHostedService<DeliveryAgent>();
builder.Services.AddHostedService<DfsrAgent>();
// Syncthing's GUI uses a self-signed certificate by default; accept it only for the local loopback API.
builder.Services.AddHttpClient("syncthing", client => client.Timeout = TimeSpan.FromSeconds(20))
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
    {
        ServerCertificateCustomValidationCallback = (request, _, _, errors) =>
            errors == System.Net.Security.SslPolicyErrors.None || request.RequestUri?.IsLoopback == true
    });
builder.Services.AddHostedService<SyncthingAgent>();
builder.Services.AddHostedService<TailscaleAgent>();
builder.Services.AddHostedService<ParityAgent>();
await builder.Build().RunAsync();
