using Cairn.Core;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Win32;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace Cairn.App;

/// Programs' real icons: from Windows' list of installed programs (the same one
/// Settings > Apps shows) and from installed app packages (Store apps). Read-only.
sealed class IconLoader
{
    readonly Dictionary<string, string> byName = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, ImageSource?> loaded = new(StringComparer.OrdinalIgnoreCase);

    /// Builds the name → icon file index. Slow-ish (registry and package list): run off the UI thread.
    public static IconLoader Build()
    {
        var index = new IconLoader();
        index.AddUninstallEntries();
        index.AddPackages();
        return index;
    }

    void Add(string? name, string? path)
    {
        if (string.IsNullOrWhiteSpace(name) || path is null) return;
        byName.TryAdd(name.Trim(), path);
        byName.TryAdd(ProgramNames.Clean(name), path);
    }

    void AddUninstallEntries()
    {
        const string uninstall = @"Software\Microsoft\Windows\CurrentVersion\Uninstall";
        var roots = new[]
        {
            (RegistryHive.CurrentUser, RegistryView.Default),
            (RegistryHive.LocalMachine, RegistryView.Registry64),
            (RegistryHive.LocalMachine, RegistryView.Registry32),
        };
        foreach (var (hive, view) in roots)
        {
            try
            {
                using var root = RegistryKey.OpenBaseKey(hive, view);
                using var key = root.OpenSubKey(uninstall);
                if (key is null) continue;
                foreach (var sub in key.GetSubKeyNames())
                {
                    try
                    {
                        using var entry = key.OpenSubKey(sub);
                        var path = AppIcons.FromDisplayIcon(entry?.GetValue("DisplayIcon") as string);
                        if (path is not null && File.Exists(path)) Add(entry?.GetValue("DisplayName") as string, path);
                    }
                    catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { }
                }
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { }
        }
    }

    void AddPackages()
    {
        try
        {
            foreach (var p in new Windows.Management.Deployment.PackageManager().FindPackagesForUser(""))
            {
                try
                {
                    if (p.IsFramework || p.IsResourcePackage || p.Logo is not { } logo) continue;
                    var path = logo.LocalPath;
                    var folder = Path.GetDirectoryName(path);
                    if (folder is null || !Directory.Exists(folder)) continue;
                    Add(p.DisplayName, AppIcons.PackageLogo(path, Directory.GetFiles(folder)));
                }
                catch (Exception) { /* a broken package shouldn't stop the rest */ }
            }
        }
        catch (Exception) { /* package list unavailable: letter tiles it is */ }
    }

    public string? Find(params string?[] names) =>
        names.Where(n => !string.IsNullOrWhiteSpace(n)).Select(n => byName.GetValueOrDefault(n!.Trim())).FirstOrDefault(p => p is not null);

    /// The icon as an image, or null if Windows can't draw it. Call on the UI thread.
    public async Task<ImageSource?> Load(string path)
    {
        if (loaded.TryGetValue(path, out var done)) return done;
        ImageSource? image = null;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            var ext = Path.GetExtension(path).ToLowerInvariant();
            var bitmap = new BitmapImage();
            if (ext is ".png" or ".ico")
            {
                using var stream = await file.OpenReadAsync();
                await bitmap.SetSourceAsync(stream);
            }
            else
            {
                // An .exe or .dll: the icon Explorer shows for it.
                using var thumb = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, 64, ThumbnailOptions.ResizeThumbnail);
                if (thumb is null) return loaded[path] = null;
                await bitmap.SetSourceAsync(thumb);
            }
            image = bitmap;
        }
        catch (Exception) { image = null; }
        return loaded[path] = image;
    }
}
