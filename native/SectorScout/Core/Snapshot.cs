using System.Text.Json;
using System.Text.Json.Serialization;

namespace SectorScout.Core;

/// <summary>One phone's reading, as the app serves it from /snapshot.</summary>
public sealed class Snapshot
{
    public bool PermissionGranted { get; init; }
    public bool LocationEnabled { get; init; }
    public string? DeviceModel { get; init; }
    public string? Timestamp { get; init; }
    public List<SimReading> Sims { get; init; } = new();

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        Converters = { new FlexibleLongConverter() },
    };

    public static Snapshot? Parse(string json) =>
        JsonSerializer.Deserialize<Snapshot>(json, Json);
}

public sealed class SimReading
{
    public int SlotIndex { get; init; }
    public long? SubscriptionId { get; init; }
    public string? CarrierName { get; init; }
    public bool IsDefault { get; init; }
    public string? SimState { get; init; }
    public string? NetworkTypeName { get; init; }
    public string? OverrideNetworkType { get; init; }
    public string? Plmn { get; init; }
    public string? CallState { get; init; }
    public int? VoiceNetworkType { get; init; }
    public ImsState? Ims { get; init; }
    public List<CellReading> Cells { get; init; } = new();

    public bool InCall => CallState is "ringing" or "offhook";
}

/// <summary>
/// IMS voice state for one subscription, as the phone reports it.
///
/// <see cref="Active"/> is the one path carrying voice — a phone registers a
/// single one — while the three flags say which services the network offers.
/// Null when the phone's IMS reader is unavailable, which is why they are not
/// used to name the path.
/// </summary>
public sealed class ImsState
{
    public bool Known { get; init; }
    public bool Volte { get; init; }
    public bool Vonr { get; init; }
    public bool Vowifi { get; init; }
    public string? Active { get; init; }
}

public sealed class CellReading
{
    public string? Type { get; init; }
    public bool Registered { get; init; }
    public long? CellId { get; init; }
    public int? Tac { get; init; }
    public int? Pci { get; init; }
    public string? Mcc { get; init; }
    public string? Mnc { get; init; }
    public int? Dbm { get; init; }
    public int? Level { get; init; }
    public int? Arfcn { get; init; }
    public List<int> Bands { get; init; } = new();
    public int? Rsrp { get; init; }
    public int? Rsrq { get; init; }
    public int? Sinr { get; init; }
    public int? TimingAdvance { get; init; }

    public bool IsNr => string.Equals(Type, "NR", StringComparison.OrdinalIgnoreCase);
    public bool IsLte => string.Equals(Type, "LTE", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// The modem sends cell identities as strings when they exceed 32 bits, and as
/// numbers otherwise, so both shapes have to read.
/// </summary>
public sealed class FlexibleLongConverter : JsonConverter<long?>
{
    public override long? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return null;
            case JsonTokenType.Number:
                return reader.TryGetInt64(out var number) ? number : null;
            case JsonTokenType.String:
                var text = reader.GetString();
                return long.TryParse(text, out var parsed) ? parsed : null;
            default:
                reader.Skip();
                return null;
        }
    }

    public override void Write(Utf8JsonWriter writer, long? value, JsonSerializerOptions options)
    {
        if (value is null) writer.WriteNullValue();
        else writer.WriteNumberValue(value.Value);
    }
}
