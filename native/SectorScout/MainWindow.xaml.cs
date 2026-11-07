using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using SectorScout.Core;

namespace SectorScout;

/// <summary>
/// The native window: phones are polled every couple of seconds over the same
/// HTTP the phones share, and each one is drawn as a card, side by side.
/// </summary>
public partial class MainWindow : Window
{
    private static readonly Brush CardBrush = Brush("#FF111823");
    private static readonly Brush RowBrush = Brush("#FF0D1420");
    private static readonly Brush LineBrush = Brush("#FF1E293B");
    private static readonly Brush TextBrush = Brush("#FFF1F5F9");
    private static readonly Brush MutedBrush = Brush("#FF94A3B8");
    private static readonly Brush AccentBrush = Brush("#FF34D399");
    private static readonly Brush WarnBrush = Brush("#FFFBBF24");

    private static Brush Brush(string hex)
    {
        var brush = (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;
        brush.Freeze();
        return brush;
    }

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(4) };
    private readonly List<PhoneLink> _links = new();
    private readonly TestSource _source = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly BandTables _bands;

    public MainWindow()
    {
        InitializeComponent();
        _bands = LoadBands();
        Loaded += OnLoaded;
        Closed += OnClosed;
        AddButton.Click += (_, _) => AddPhone(AddressBox.Text);
        ClearButton.Click += (_, _) => { _links.Clear(); Render(); };
        AddressBox.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter) AddPhone(AddressBox.Text);
        };
    }

    private static BandTables LoadBands()
    {
        foreach (var path in new[]
                 {
                     System.IO.Path.Combine(AppContext.BaseDirectory, "bands.json"),
                     "bands.json",
                     System.IO.Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "bands.json"),
                 })
        {
            try
            {
                if (File.Exists(path)) return BandTables.Load(path);
            }
            catch (IOException)
            {
                // Try the next candidate rather than failing to start.
            }
        }
        return new BandTables();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _source.Start();
        SourceText.Text = _source.Running
            ? $"Test source on http://127.0.0.1:{TestSource.Port}/snapshot"
            : $"Test source off \u2014 port {TestSource.Port} is taken";
        _timer.Tick += async (_, _) => await PollAsync();
        _timer.Start();
        Render();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _timer.Stop();
        _source.Stop();
        _http.Dispose();
    }

    private void AddPhone(string input)
    {
        if (string.IsNullOrWhiteSpace(input)) return;
        var link = new PhoneLink(input);
        if (_links.Any(existing => existing.Address == link.Address)) return;
        _links.Add(link);
        AddressBox.Clear();
        Render();
        _ = PollAsync();
    }

    private async Task PollAsync()
    {
        if (_links.Count == 0) return;
        await Task.WhenAll(_links.Select(link => link.PollAsync(_http)));
        Render();
    }

    private void Render()
    {
        CardsHost.Children.Clear();

        if (_links.Count == 0)
        {
            CardsHost.Children.Add(new TextBlock
            {
                Text = "No phones yet. Type an address above \u2014 this PC answers on 127.0.0.1 "
                     + "so you can watch the test source first.",
                Foreground = MutedBrush,
                FontSize = 13,
                Margin = new Thickness(12),
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 520,
            });
        }
        else
        {
            foreach (var link in _links) CardsHost.Children.Add(BuildCard(link));
        }

        var answering = _links.Count(link => link.Error is null && link.Latest is not null);
        FooterText.Text =
            $"{answering}/{_links.Count} phones answering  \u00b7  " +
            $"test source {(_source.Running ? "on" : "off")}  \u00b7  " +
            $"bands {_bands.Lte.Count} LTE / {_bands.Nr.Count} NR";
    }

    private FrameworkElement BuildCard(PhoneLink link)
    {
        var stack = new StackPanel();

        var header = new DockPanel { LastChildFill = true };
        var title = new TextBlock
        {
            Text = link.Address,
            Foreground = TextBrush,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
        };
        var state = new TextBlock
        {
            Text = link.Error is not null ? "error" : link.Latest is null ? "waiting" : Labels.Age(link.LastOk),
            Foreground = link.Error is not null ? WarnBrush : MutedBrush,
            FontSize = 11.5,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        DockPanel.SetDock(state, Dock.Right);
        header.Children.Add(state);
        header.Children.Add(title);
        stack.Children.Add(header);

        if (link.Latest is { } snapshot)
        {
            stack.Children.Add(new TextBlock
            {
                Text = snapshot.DeviceModel ?? "unknown phone",
                Foreground = MutedBrush,
                FontSize = 11.5,
                Margin = new Thickness(0, 2, 0, 0),
            });
        }

        if (link.Error is { } error)
        {
            stack.Children.Add(new Border
            {
                Background = RowBrush,
                BorderBrush = WarnBrush,
                BorderThickness = new Thickness(2, 0, 0, 0),
                Padding = new Thickness(8, 6, 8, 6),
                Margin = new Thickness(0, 8, 0, 0),
                Child = new TextBlock
                {
                    Text = error,
                    Foreground = WarnBrush,
                    FontSize = 11.5,
                    TextWrapping = TextWrapping.Wrap,
                },
            });
        }

        if (link.Latest is { Sims.Count: > 0 } reading)
        {
            foreach (var sim in reading.Sims)
            {
                stack.Children.Add(BuildSim(sim, reading.Sims.Count > 1));
            }
        }
        else if (link.Error is null)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "asking\u2026",
                Foreground = MutedBrush,
                FontSize = 12,
                Margin = new Thickness(0, 10, 0, 0),
            });
        }

        return new Border
        {
            Width = 560,
            Margin = new Thickness(6),
            Padding = new Thickness(14, 12, 14, 12),
            CornerRadius = new CornerRadius(12),
            Background = CardBrush,
            BorderBrush = LineBrush,
            BorderThickness = new Thickness(1),
            Child = stack,
        };
    }

    private FrameworkElement BuildSim(SimReading sim, bool showSlot)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };

        var header = new DockPanel();
        var badge = new Border
        {
            Background = RowBrush,
            BorderBrush = LineBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(7, 2, 7, 2),
            Child = new TextBlock
            {
                Text = Labels.Technology(sim),
                Foreground = AccentBrush,
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
            },
        };
        DockPanel.SetDock(badge, Dock.Right);
        header.Children.Add(badge);

        // The voice path sits to the left of the technology badge, and is lit
        // only while a call is up, so it reads as what is in use rather than as
        // another static caption.
        var voice = Labels.Voice(sim);
        if (voice.Length > 0)
        {
            var path = new TextBlock
            {
                Text = voice,
                Foreground = sim.InCall ? AccentBrush : MutedBrush,
                FontSize = 12,
                FontWeight = FontWeights.Bold,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 12, 0),
            };
            DockPanel.SetDock(path, Dock.Right);
            header.Children.Add(path);
        }

        var carrier = new TextBlock
        {
            Text = (showSlot ? $"SIM {sim.SlotIndex + 1}  " : string.Empty) + (sim.CarrierName ?? "unknown network"),
            Foreground = TextBrush,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        header.Children.Add(carrier);
        stack.Children.Add(header);

        var anchor = sim.Cells.FirstOrDefault(c => c.IsLte && c.Registered)
                     ?? sim.Cells.FirstOrDefault(c => c.IsLte);
        var leg = sim.Cells.FirstOrDefault(c => c.IsNr && c.Registered)
                  ?? sim.Cells.FirstOrDefault(c => c.IsNr);

        if (anchor is not null)
        {
            stack.Children.Add(BuildCell("LTE", anchor, sim.Plmn));
        }
        if (leg is not null)
        {
            stack.Children.Add(BuildCell("5G NR", leg, sim.Plmn));
        }
        if (anchor is null && leg is null)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "no cells reported",
                Foreground = MutedBrush,
                FontSize = 12,
                Margin = new Thickness(0, 6, 0, 0),
            });
        }

        var neighbours = sim.Cells.Count(c => !c.Registered);
        if (neighbours > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"{neighbours} neighbour cell{(neighbours == 1 ? string.Empty : "s")}",
                Foreground = MutedBrush,
                FontSize = 11.5,
                Margin = new Thickness(0, 6, 0, 0),
            });
        }

        return stack;
    }

    private FrameworkElement BuildCell(string name, CellReading cell, string? simPlmn)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };

        var split = Radio.Split(cell.CellId, cell.IsNr, simPlmn ?? Labels.Plmn(cell));
        var identity = split is { } pair
            ? $"{(cell.IsNr ? "gNB" : "eNB")} {pair.first}  \u00b7  sector {pair.second}"
            : "drifting";

        var line = new DockPanel();
        var bars = new TextBlock
        {
            Text = $"{Radio.BarMeter(Radio.Bars(cell.Dbm))}  {(cell.Dbm is null ? "\u2014" : $"{cell.Dbm} dBm")}",
            Foreground = AccentBrush,
            FontFamily = new FontFamily("Consolas, Segoe UI"),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
        };
        DockPanel.SetDock(bars, Dock.Right);
        line.Children.Add(bars);
        line.Children.Add(new TextBlock
        {
            Text = $"{name}  \u00b7  {Labels.Band(cell)}",
            Foreground = TextBrush,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        stack.Children.Add(line);

        stack.Children.Add(Row("Cell", identity));
        stack.Children.Add(Row("Channel", cell.Arfcn is int arfcn && arfcn > 0 ? arfcn.ToString() : "\u2014"));
        stack.Children.Add(Row("Frequency", Frequencies(cell)));
        stack.Children.Add(Row("PLMN", Labels.Plmn(cell)));
        if (cell.Tac is int tac) stack.Children.Add(Row("TAC", tac.ToString()));
        if (cell.Pci is int pci) stack.Children.Add(Row("PCI", pci.ToString()));

        return stack;
    }

    private static FrameworkElement Row(string label, string value)
    {
        var row = new DockPanel { Margin = new Thickness(0, 1, 0, 0) };
        var name = new TextBlock
        {
            Text = label,
            Width = 84,
            Foreground = MutedBrush,
            FontSize = 11.5,
        };
        DockPanel.SetDock(name, Dock.Left);
        row.Children.Add(name);
        row.Children.Add(new TextBlock
        {
            Text = value,
            Foreground = TextBrush,
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
        });
        return row;
    }

    private string Frequencies(CellReading cell)
    {
        if (cell.Arfcn is not int arfcn || arfcn <= 0) return "\u2014";

        double? downlink;
        double? uplink;
        if (cell.IsNr)
        {
            var plan = cell.Bands.Select(_bands.NrPlan).FirstOrDefault(p => p is not null);
            downlink = Radio.NrDownlink(arfcn);
            uplink = plan is null ? null : Radio.NrUplink(plan, arfcn);
        }
        else
        {
            var plan = cell.Bands.Select(_bands.LtePlan).FirstOrDefault(p => p is not null);
            downlink = plan is null ? null : Radio.LteDownlink(plan, arfcn);
            uplink = plan is null ? null : Radio.LteUplink(plan, arfcn);
        }

        if (downlink is null) return "\u2014";
        if (uplink is null || Math.Abs(uplink.Value - downlink.Value) < 0.001)
            return $"{downlink:0.00} MHz";
        return $"{downlink:0.00} \u2193 / {uplink:0.00} \u2191 MHz";
    }
}
