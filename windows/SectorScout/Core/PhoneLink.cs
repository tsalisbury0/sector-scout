using System.Net.Http;

namespace SectorScout.Core;

/// <summary>One watched phone: its address, its latest reading, and how it is doing.</summary>
public sealed class PhoneLink
{
    public const int DefaultPort = 41729;

    public string Address { get; }
    public Snapshot? Latest { get; private set; }
    public string? Error { get; private set; }
    public DateTime LastOk { get; private set; }

    public PhoneLink(string address) => Address = Normalize(address);

    /// <summary>Accepts "10.1.1.47", "10.1.1.47:41729", or a full URL.</summary>
    public static string Normalize(string input)
    {
        var text = input.Trim();
        foreach (var scheme in new[] { "http://", "https://" })
        {
            if (text.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
                text = text[scheme.Length..];
        }
        text = text.TrimEnd('/');
        if (text.Contains('/')) text = text[..text.IndexOf('/')];
        if (text.Length == 0) return $"127.0.0.1:{DefaultPort}";
        return text.Contains(':') ? text : $"{text}:{DefaultPort}";
    }

    public string Url => $"http://{Address}/snapshot";

    public async Task PollAsync(HttpClient http)
    {
        try
        {
            var json = await http.GetStringAsync(Url);
            var parsed = Snapshot.Parse(json);
            if (parsed is null)
            {
                Error = "the phone answered with JSON this app could not read";
                return;
            }
            Latest = parsed;
            LastOk = DateTime.UtcNow;
            Error = null;
        }
        catch (TaskCanceledException)
        {
            Error = $"no answer from {Address} within 4 s";
        }
        catch (Exception error)
        {
            Error = error.Message;
        }
    }
}
