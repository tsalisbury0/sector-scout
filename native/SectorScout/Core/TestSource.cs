using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace SectorScout.Core;

/// <summary>
/// The phone's own /snapshot JSON, served on the same fixed port the phone
/// uses, so a handset can watch this PC to exercise badges, bands and layouts
/// without a modem. A plain TcpListener rather than HttpListener, which needs
/// a URL reservation on Windows.
/// </summary>
public sealed class TestSource
{
    public const int Port = 41729;

    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private readonly Random _drift = new();

    public bool Running { get; private set; }
    public string? Failure { get; private set; }

    public void Start()
    {
        try
        {
            _listener = new TcpListener(IPAddress.Loopback, Port);
            _listener.Start();
            _cts = new CancellationTokenSource();
            Running = true;
            _ = Task.Run(() => AcceptAsync(_cts.Token));
        }
        catch (SocketException error)
        {
            // The phone share, or another console, already holds the port.
            Running = false;
            Failure = error.Message;
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        _listener?.Stop();
        Running = false;
    }

    private async Task AcceptAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener!.AcceptTcpClientAsync(token);
            }
            catch
            {
                return;
            }
            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var buffer = new byte[4096];
                var read = await stream.ReadAsync(buffer);
                if (read <= 0) return;
                var request = Encoding.ASCII.GetString(buffer, 0, read);
                var path = request.Split(' ').ElementAtOrDefault(1) ?? "/";

                var body = path.StartsWith("/health", StringComparison.OrdinalIgnoreCase)
                    ? "{\"ok\":true}"
                    : JsonSerializer.Serialize(Payload(_drift.Next(-2, 3)));
                var bytes = Encoding.UTF8.GetBytes(body);
                var header =
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/json\r\n" +
                    $"Content-Length: {bytes.Length}\r\n" +
                    "Access-Control-Allow-Origin: *\r\n" +
                    "Connection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(header));
                await stream.WriteAsync(bytes);
            }
            catch
            {
                // A client that vanished mid-request is not worth reporting.
            }
        }
    }

    /// <summary>AT&amp;T LTE on band 2, drifting a couple of dB so the bars move.</summary>
    private static object Payload(int drift) => new
    {
        permissionGranted = true,
        locationEnabled = true,
        timestamp = DateTimeOffset.UtcNow.ToString("O"),
        deviceModel = "Sector Scout Desktop (test source)",
        cellCount = 1,
        sims = new object[]
        {
            new
            {
                slotIndex = 0,
                subscriptionId = 1L,
                carrierName = "AT&T",
                isDefault = true,
                simState = "READY",
                networkTypeName = "LTE",
                overrideNetworkType = "LTE_CA",
                plmn = "310-410",
                callState = "idle",
                voiceNetworkType = 13,
                ims = new
                {
                    known = true,
                    volte = true,
                    vonr = false,
                    vowifi = true,
                    active = "volte",
                },
                cells = new object[]
                {
                    new
                    {
                        type = "LTE",
                        registered = true,
                        cellId = (long?)62968329,
                        tac = 25601,
                        pci = 61,
                        mcc = "310",
                        mnc = "410",
                        dbm = -89 + drift,
                        level = 3,
                        arfcn = 700,
                        bands = new[] { 2 },
                        rsrp = (int?)null,
                        rsrq = (int?)null,
                        sinr = (int?)null,
                        timingAdvance = (int?)null,
                    },
                },
            },
        },
    };
}
