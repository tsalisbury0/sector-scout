using System.IO;
using System.Text.Json;

namespace SectorScout.Core;

/// <summary>One band's channel window and duplex pair, from bands.json.</summary>
public sealed class BandPlan
{
    public int Band { get; init; }
    public int First { get; init; }
    public int Last { get; init; }
    public double DlLow { get; init; }
    public double UlLow { get; init; }
    public double UlHigh { get; init; }
    public string? Mode { get; init; }

    public bool IsTdd => string.Equals(Mode, "TDD", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// The same bands.json the phone app and the Python console read, so a band
/// cannot cost one of them a different frequency.
/// </summary>
public sealed class BandTables
{
    public List<BandPlan> Lte { get; } = new();
    public List<BandPlan> Nr { get; } = new();

    public static BandTables Load(string path)
    {
        var tables = new BandTables();
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        foreach (var (name, target) in new (string, List<BandPlan>)[]
                 { ("lte", tables.Lte), ("nr", tables.Nr) })
        {
            if (!document.RootElement.TryGetProperty(name, out var rows)) continue;
            foreach (var row in rows.EnumerateArray())
            {
                target.Add(new BandPlan
                {
                    Band = (int)Number(row, "band"),
                    First = (int)Number(row, "first"),
                    Last = (int)Number(row, "last"),
                    DlLow = Number(row, "dlLow"),
                    UlLow = Number(row, "ulLow"),
                    UlHigh = Number(row, "ulHigh"),
                    Mode = row.TryGetProperty("mode", out var mode) ? mode.GetString() : null,
                });
            }
        }
        return tables;
    }

    /// <summary>
    /// bands.json leaves a field null where a band has no uplink at all (29,
    /// 32, the supplemental downlinks), and a modem may omit one, so every
    /// number has to read as "absent" instead of throwing.
    /// </summary>
    private static double Number(JsonElement row, string name)
    {
        if (!row.TryGetProperty(name, out var value)) return 0;
        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetDouble(out var number) => number,
            JsonValueKind.String when double.TryParse(
                value.GetString(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var parsed) => parsed,
            _ => 0,
        };
    }

    public BandPlan? LtePlan(int band) => Lte.FirstOrDefault(p => p.Band == band);
    public BandPlan? NrPlan(int band) => Nr.FirstOrDefault(p => p.Band == band);
}

public static class Radio
{
    /// <summary>0-5 bars on the app's dBm scale; zero when the modem gave no level.</summary>
    public static int Bars(int? dbm) => dbm is null ? 0 : dbm.Value switch
    {
        >= -84 => 5,
        >= -94 => 4,
        >= -104 => 3,
        >= -114 => 2,
        >= -124 => 1,
        _ => 0,
    };

    public static string BarMeter(int bars) =>
        new string('\u2588', bars) + new string('\u2591', 5 - bars);

    /// <summary>LTE downlink: band low edge plus 0.1 MHz per channel step.</summary>
    public static double? LteDownlink(BandPlan plan, int arfcn) =>
        plan.DlLow + 0.1 * (arfcn - plan.First);

    public static double? LteUplink(BandPlan plan, int arfcn)
    {
        if (plan.UlLow <= 0) return null;          // downlink-only band (29, 32, ...)
        var raw = plan.UlLow + 0.1 * (arfcn - plan.First);
        return Math.Clamp(raw, plan.UlLow, plan.UlHigh);
    }

    /// <summary>The global NR-ARFCN raster, in MHz.</summary>
    public static double NrFrequency(int arfcn) => arfcn switch
    {
        < 600000 => arfcn * 0.005,
        < 2016667 => 3000.0 + (arfcn - 600000) * 0.015,
        _ => 24250.08 + (arfcn - 2016667) * 0.06,
    };

    public static double? NrDownlink(int arfcn) => arfcn > 0 ? NrFrequency(arfcn) : null;

    public static double? NrUplink(BandPlan plan, int arfcn)
    {
        if (arfcn <= 0) return null;
        var downlink = NrFrequency(arfcn);
        if (plan.IsTdd) return downlink;
        var spacing = plan.DlLow - plan.UlLow;
        if (Math.Abs(spacing) < 0.001) return downlink;
        return Math.Clamp(downlink - spacing, plan.UlLow, plan.UlHigh);
    }

    /// <summary>3GPP lets each operator choose its gNB ID length; the PLMN picks it.</summary>
    public static int GnbBits(string? plmn) => plmn switch
    {
        "310-410" or "310-150" or "310-170" or "310-380" or "313-100" => 26,
        "310-260" or "312-190" => 24,
        _ => 22,
    };

    public static (long first, long second)? Split(long? cellId, bool nr, string? plmn)
    {
        if (cellId is null) return null;
        if (!nr) return (cellId.Value >> 8, cellId.Value & 0xFF);
        var shift = 36 - GnbBits(plmn);
        return (cellId.Value >> shift, cellId.Value & ((1L << shift) - 1));
    }
}
