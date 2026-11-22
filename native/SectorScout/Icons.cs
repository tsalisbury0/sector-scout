using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace SectorScout;

/// <summary>
/// The card header glyphs, drawn rather than shipped as images: a lattice
/// tower beside the technology badge and a tilted receiver beside the voice
/// path, both at the weight of the labels they sit with and crisp at any DPI.
/// </summary>
public static class Icons
{
    private const double Box = 14;

    /// <summary>A lattice tower under two signal arcs. 4G and 5G both radiate, so the ink says which.</summary>
    public static FrameworkElement Radio(Brush ink)
    {
        var canvas = NewCanvas();
        const double mid = Box / 2;
        var apex = Box * 0.40;
        var foot = Box * 0.943;
        var half = Box * 0.214;
        foreach (var radius in new[] { Box * 0.136, Box * 0.243 })
        {
            canvas.Children.Add(Stroke(Arc(mid, apex, radius, 205, 335), ink, 1.2));
        }
        canvas.Children.Add(Stroke(Segment(mid, apex, mid - half, foot), ink, 1.2));
        canvas.Children.Add(Stroke(Segment(mid, apex, mid + half, foot), ink, 1.2));
        canvas.Children.Add(Stroke(Segment(mid - half, foot, mid + half, foot), ink, 1.2));
        canvas.Children.Add(Stroke(
            Segment(mid - Box * 0.119, Box * 0.70, mid + Box * 0.119, Box * 0.70), ink, 1.2));
        return canvas;
    }

    /// <summary>A receiver, tilted like a handset at rest, with a cup at each end.</summary>
    public static FrameworkElement Voice(Brush ink)
    {
        var canvas = NewCanvas();
        const double mid = Box / 2;
        var radius = Box * 0.271;
        var tilt = -38 * Math.PI / 180;

        var samples = new List<Point>();
        for (var step = 0; step < 14; step++)
        {
            var angle = (25 + step * 10) * Math.PI / 180;
            var x = radius * Math.Cos(angle);
            var y = radius * Math.Sin(angle);
            samples.Add(new Point(
                mid + x * Math.Cos(tilt) - y * Math.Sin(tilt),
                mid + x * Math.Sin(tilt) + y * Math.Cos(tilt)));
        }

        var figure = new PathFigure
        {
            StartPoint = samples[0],
            IsClosed = false,
            IsFilled = false,
        };
        figure.Segments.Add(new PolyLineSegment(samples.Skip(1), true));
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        canvas.Children.Add(Stroke(geometry, ink, 2.2));

        var dot = Box * 0.107;
        foreach (var ear in new[] { samples[0], samples[^1] })
        {
            var cup = new Ellipse { Width = dot * 2, Height = dot * 2, Fill = ink };
            Canvas.SetLeft(cup, ear.X - dot);
            Canvas.SetTop(cup, ear.Y - dot);
            canvas.Children.Add(cup);
        }
        return canvas;
    }

    private static Canvas NewCanvas() => new()
    {
        Width = Box,
        Height = Box,
        Background = Brushes.Transparent,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static Path Stroke(Geometry geometry, Brush ink, double thickness) => new()
    {
        Data = geometry,
        Stroke = ink,
        StrokeThickness = thickness,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static LineGeometry Segment(double x1, double y1, double x2, double y2) =>
        new(new Point(x1, y1), new Point(x2, y2));

    /// <summary>
    /// An open arc, swept clockwise in screen coordinates, so 25–155 draws the
    /// bottom half and 205–335 the top.
    /// </summary>
    private static PathGeometry Arc(double cx, double cy, double radius, double from, double to)
    {
        static Point On(double cx, double cy, double radius, double degrees) => new(
            cx + radius * Math.Cos(degrees * Math.PI / 180),
            cy + radius * Math.Sin(degrees * Math.PI / 180));

        var figure = new PathFigure
        {
            StartPoint = On(cx, cy, radius, from),
            IsClosed = false,
            IsFilled = false,
        };
        figure.Segments.Add(new ArcSegment(
            On(cx, cy, radius, to),
            new Size(radius, radius),
            0,
            Math.Abs(to - from) > 180,
            SweepDirection.Clockwise,
            true));
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }
}
