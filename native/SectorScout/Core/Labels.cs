namespace SectorScout.Core;

/// <summary>How a band and a cell are named, matching the app's own labels.</summary>
public static class Labels
{
    public static string Band(CellReading cell)
    {
        var bands = cell.Bands.Where(b => b > 0).Distinct().ToList();
        if (bands.Count == 0) return cell.IsNr ? "n ?" : "B ?";
        return string.Join(", ", bands.Select(b => (cell.IsNr ? "n" : "B") + b));
    }

    public static string Technology(SimReading sim)
    {
        var cells = sim.Cells;
        var hasNr = cells.Any(c => c.IsNr && c.Registered);
        var hasLte = cells.Any(c => c.IsLte && c.Registered);
        if (hasNr) return hasLte ? "5G NSA" : "5G SA";
        var reported = sim.OverrideNetworkType ?? string.Empty;
        if (reported.Contains("ADVANCED_PRO", StringComparison.OrdinalIgnoreCase)) return "LTE+";
        if (cells.Count(c => c.IsLte && c.Registered) > 1) return "LTE+";
        return "LTE";
    }

    /// <summary>
    /// The path carrying voice, written the way carriers write it: VoLTE, VoNR,
    /// VoWiFi. A phone registers one at a time, so this names one — the header
    /// used to list every service the network offered, which read as if both
    /// VoLTE and VoWiFi were in use.
    /// </summary>
    public static string Voice(SimReading sim)
    {
        var active = sim.Ims?.Active?.ToLowerInvariant();
        return active switch
        {
            "volte" => "VoLTE",
            "vonr" => "VoNR",
            "vowifi" => "VoWiFi",
            "cs" => "CS",
            // No IMS answer: a call in progress is on a legacy path.
            _ => sim.InCall ? "CS" : string.Empty,
        };
    }

    public static string Plmn(CellReading cell) =>
        cell.Mcc is null || cell.Mnc is null ? "\u2014" : $"{cell.Mcc}-{cell.Mnc}";

    public static string Age(DateTime when)
    {
        var seconds = (DateTime.UtcNow - when).TotalSeconds;
        if (seconds < 1) return "now";
        if (seconds < 90) return $"{seconds:0}s ago";
        return $"{seconds / 60:0}m ago";
    }
}
