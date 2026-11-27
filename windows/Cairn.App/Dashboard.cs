using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace Cairn.App;

/// A circular status ring like the Mac app's: a thick arc for progress around a big
/// symbol or a percentage, an empty track when idle, or a dashed ring when off.
sealed class RingView : Grid
{
    readonly Ellipse track = new();
    readonly Microsoft.UI.Xaml.Shapes.Path arc = new() { StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    readonly FontIcon symbol = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock label = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold };
    readonly double size, thickness;

    public RingView(double size = 96, double thickness = 9)
    {
        this.size = size;
        this.thickness = thickness;
        Width = Height = size;
        track.StrokeThickness = arc.StrokeThickness = thickness;
        track.Margin = new Thickness(thickness / 2);
        symbol.FontSize = size * 0.3;
        label.FontSize = size * 0.21;
        Children.Add(track);
        Children.Add(arc);
        Children.Add(symbol);
        Children.Add(label);
    }

    /// `fraction` null: idle (empty track). `disabled`: a dashed grey ring.
    public void Set(Color tint, double? fraction, string? glyph = null, string? text = null, bool disabled = false)
    {
        var grey = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"];
        var color = new SolidColorBrush(tint);
        track.Stroke = disabled ? grey : new SolidColorBrush(Color.FromArgb(46, tint.R, tint.G, tint.B));
        track.StrokeThickness = disabled ? 3 : thickness;
        track.StrokeDashArray = disabled ? new DoubleCollection { 2, 2.5 } : null;
        arc.Stroke = color;
        arc.Data = disabled || fraction is null ? null : Arc(Math.Clamp(fraction.Value, 0.001, 1));
        symbol.Glyph = glyph ?? "";
        symbol.Foreground = disabled ? grey : color;
        symbol.Visibility = text is null && glyph is not null ? Visibility.Visible : Visibility.Collapsed;
        label.Text = text ?? "";
        label.Foreground = color;
        label.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    Geometry Arc(double fraction)
    {
        var r = (size - thickness) / 2;
        var c = size / 2;
        if (fraction >= 0.9999) return new EllipseGeometry { Center = new Point(c, c), RadiusX = r, RadiusY = r };
        var angle = fraction * 2 * Math.PI;
        var end = new Point(c + r * Math.Sin(angle), c - r * Math.Cos(angle));
        var figure = new PathFigure { StartPoint = new Point(c, c - r), IsClosed = false };
        figure.Segments.Add(new ArcSegment
        {
            Point = end, Size = new Size(r, r), IsLargeArc = fraction > 0.5, SweepDirection = SweepDirection.Clockwise,
        });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }
}

/// A Home card like the Mac app's: ring, title, coloured status, detail, a tinted main
/// button, a folder line at the bottom, and a "…" menu in the corner.
sealed class DashboardCard
{
    public Border Root { get; }
    public RingView Ring { get; } = new();
    public TextBlock Status { get; }
    public TextBlock Detail { get; }
    public Grid ActionsRow { get; } = new() { ColumnSpacing = 8 };
    public HyperlinkButton Footer { get; }
    public MenuFlyout Menu { get; } = new() { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
    public Color Tint { get; }

    public DashboardCard(string title, Color tint)
    {
        Tint = tint;
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        Status = new TextBlock
        {
            FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(tint), HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, TextAlignment = TextAlignment.Center,
        };
        Detail = new TextBlock
        {
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = secondary,
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            Height = 48, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var footerText = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis };
        var footerContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        footerContent.Children.Add(new FontIcon { Glyph = "", FontSize = 12 });
        footerContent.Children.Add(footerText);
        Footer = new HyperlinkButton
        {
            Content = footerContent, HorizontalAlignment = HorizontalAlignment.Center, Foreground = secondary, Padding = new Thickness(6, 2, 6, 2),
        };

        ActionsRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ActionsRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var stack = new StackPanel { Spacing = 14, HorizontalAlignment = HorizontalAlignment.Stretch };
        Ring.HorizontalAlignment = HorizontalAlignment.Center;
        Ring.Margin = new Thickness(0, 6, 0, 0);
        stack.Children.Add(Ring);
        var text = new StackPanel { Spacing = 4 };
        text.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], HorizontalAlignment = HorizontalAlignment.Center });
        text.Children.Add(Status);
        text.Children.Add(Detail);
        stack.Children.Add(text);
        stack.Children.Add(ActionsRow);
        stack.Children.Add(Footer);

        var more = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 14 }, Flyout = Menu, Padding = new Thickness(8),
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
        };
        ToolTipService.SetToolTip(more, $"More {title.ToLowerInvariant()} options");

        var grid = new Grid();
        grid.Children.Add(stack);
        grid.Children.Add(more);
        Root = new Border
        {
            Padding = new Thickness(18), CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1),
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            Background = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0), EndPoint = new Point(0, 1),
                GradientStops =
                {
                    new GradientStop { Color = Color.FromArgb(34, tint.R, tint.G, tint.B), Offset = 0 },
                    new GradientStop { Color = Color.FromArgb(8, tint.R, tint.G, tint.B), Offset = 1 },
                },
            },
            Child = grid,
        };
        FooterText = footerText;
    }

    public TextBlock FooterText { get; }

    /// Sets the main button (stretching) and an optional small one beside it.
    public void SetActions(Button main, Button? side = null)
    {
        ActionsRow.Children.Clear();
        main.HorizontalAlignment = HorizontalAlignment.Stretch;
        ActionsRow.Children.Add(main);
        if (side is not null) { Grid.SetColumn(side, 1); ActionsRow.Children.Add(side); }
    }

    /// A button filled with the card's colour, which keeps its colour on hover and press.
    public static Button Tinted(string text, string glyph, Color tint)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        content.Children.Add(new TextBlock { Text = text, FontWeight = FontWeights.SemiBold });
        var b = new Button { Content = content, Padding = new Thickness(12, 8, 12, 8), HorizontalContentAlignment = HorizontalAlignment.Center };
        Color Shade(double f) => Color.FromArgb(255, (byte)(tint.R * f), (byte)(tint.G * f), (byte)(tint.B * f));
        var white = new SolidColorBrush(Colors.White);
        b.Resources["ButtonBackground"] = new SolidColorBrush(tint);
        b.Resources["ButtonBackgroundPointerOver"] = new SolidColorBrush(Shade(0.9));
        b.Resources["ButtonBackgroundPressed"] = new SolidColorBrush(Shade(0.8));
        b.Resources["ButtonBackgroundDisabled"] = new SolidColorBrush(Color.FromArgb(90, tint.R, tint.G, tint.B));
        b.Resources["ButtonForeground"] = white;
        b.Resources["ButtonForegroundPointerOver"] = white;
        b.Resources["ButtonForegroundPressed"] = white;
        b.Resources["ButtonForegroundDisabled"] = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255));
        b.Resources["ButtonBorderBrush"] = new SolidColorBrush(Colors.Transparent);
        b.Resources["ButtonBorderBrushPointerOver"] = new SolidColorBrush(Colors.Transparent);
        b.Resources["ButtonBorderBrushPressed"] = new SolidColorBrush(Colors.Transparent);
        b.Resources["ButtonBorderBrushDisabled"] = new SolidColorBrush(Colors.Transparent);
        return b;
    }

    /// A small square button with just a symbol, beside the main one.
    public static Button Icon(string glyph, string tip)
    {
        var b = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Padding = new Thickness(11, 9, 11, 9) };
        ToolTipService.SetToolTip(b, tip);
        return b;
    }
}
