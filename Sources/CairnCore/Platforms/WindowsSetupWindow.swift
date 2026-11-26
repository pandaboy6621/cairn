import Foundation

/// The Windows kit's window: `Cairn Setup.cmd` opens `Cairn Setup.ps1`, a checklist
/// built with what every Windows PC has (PowerShell and WPF), so there's nothing to
/// install. Ticked items go to `setup.ps1`, which does the work in a console window:
/// Preview first, then Set up, which stays off until a preview has been shown.
extension PlatformExport {
    /// One tick box: `key` is what `setup.ps1 -Skip` matches.
    struct WindowItem: Equatable {
        var key: String
        var text: String
    }

    var windowGroups: [(title: String, items: [WindowItem])] {
        var groups: [(String, [WindowItem])] = []
        groups.append(("Programs", winget.map { WindowItem(key: $0.id, text: $0.label) }))
        groups.append(("Settings", registry.map { WindowItem(key: $0.name, text: $0.label.isEmpty ? $0.name : $0.label) }))
        if !taskbar.isEmpty {
            groups.append(("Taskbar", [WindowItem(key: "taskbar", text: "Pin your Dock's apps: " + taskbar.joined(separator: ", "))]))
        }
        groups.append(("Config files", installedDotfiles.map { d in
            let target = d.target.replacingOccurrences(of: "/", with: "\\")
            return WindowItem(key: target, text: (d.kind == .ssh ? "SSH settings" : "Git settings") + " (\(target))")
        }))
        return groups.filter { !$0.1.isEmpty }
    }

    /// Double-click to open the window (a .ps1 opens in Notepad when double-clicked).
    func windowLauncher() -> String {
        [
            "@echo off",
            "rem Opens Cairn's setup window. Nothing changes until you click Set up.",
            #"start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Cairn Setup.ps1""#,
        ].joined(separator: "\r\n") + "\r\n"
    }

    func powershellWindow() -> String {
        var s = """
        # \(header)
        # A window for setup.ps1: tick what to set up, preview it, then set it up.
        # Open it with Cairn Setup.cmd.
        $ErrorActionPreference = 'Stop'
        $kit = $PSScriptRoot
        $groups = [ordered]@{

        """
        for g in windowGroups {
            s += "    \(ps(g.title)) = @(\n"
            s += g.items.map { "        @{ Key = \(ps($0.key)); Text = \(ps($0.text)) }" }.joined(separator: ",\n")
            s += "\n    )\n"
        }
        s += "}\n"
        s += "$heading = \(ps("Set up Windows like " + device.name))\n"
        s += "$backedUp = \(ps("From a backup of \(device.name) taken \(Self.day(backedUp)). Tick what you want, then Preview to see what would change. Nothing changes until you click Set up."))\n"
        s += """
        [xml]$xaml = @'
        <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                Title="Cairn" Width="580" Height="680" WindowStartupLocation="CenterScreen"
                FontFamily="Segoe UI" FontSize="14">
          <DockPanel Margin="20">
            <TextBlock Name="Heading" DockPanel.Dock="Top" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock Name="Intro" DockPanel.Dock="Top" Margin="0,6,0,10" TextWrapping="Wrap" Foreground="#555"/>
            <DockPanel DockPanel.Dock="Bottom" Margin="0,14,0,0" LastChildFill="False">
              <Button Name="Checklist" DockPanel.Dock="Left" Content="Open checklist" Padding="14,6"/>
              <Button Name="Apply" DockPanel.Dock="Right" Content="Set up" Padding="18,6" Margin="8,0,0,0" IsEnabled="False"/>
              <Button Name="Preview" DockPanel.Dock="Right" Content="Preview" Padding="18,6" IsDefault="True"/>
            </DockPanel>
            <TextBlock Name="Status" DockPanel.Dock="Bottom" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#555"/>
            <Border BorderBrush="#DDD" BorderThickness="1" CornerRadius="4">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="12,4">
                <StackPanel Name="Items"/>
              </ScrollViewer>
            </Border>
          </DockPanel>
        </Window>
        '@

        try {
            Add-Type -AssemblyName PresentationFramework
            $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
        } catch {
            # The console is hidden, so say it in a message box.
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.Popup("Couldn't open Cairn's window: $_`n`nRun setup.ps1 in PowerShell instead (see CHECKLIST.md).", 0, 'Cairn', 16)
            exit 1
        }
        $items = $window.FindName('Items')
        $preview = $window.FindName('Preview')
        $apply = $window.FindName('Apply')
        $status = $window.FindName('Status')
        $window.FindName('Heading').Text = $heading
        $window.FindName('Intro').Text = $backedUp

        # A TextBlock as the label: a plain string would turn _ into a keyboard shortcut.
        function New-Box([string]$text, [object]$tag, [string]$margin) {
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $text
            $label.TextWrapping = 'Wrap'
            $box = New-Object System.Windows.Controls.CheckBox
            $box.Content = $label
            $box.Tag = $tag
            $box.IsChecked = $true
            $box.Margin = $margin
            $box
        }
        # Changing what's ticked means previewing again before Set up.
        $changed = {
            $apply.IsEnabled = $false
            $status.Text = 'Preview to see what would change.'
        }
        $boxes = New-Object System.Collections.ArrayList
        foreach ($g in $groups.GetEnumerator()) {
            $members = New-Object System.Collections.ArrayList
            $all = New-Box "$($g.Key) ($(@($g.Value).Count))" $members '0,10,0,4'
            $all.FontWeight = 'SemiBold'
            [void]$items.Children.Add($all)
            foreach ($i in $g.Value) {
                $box = New-Box $i.Text $i.Key '24,3,0,3'
                $box.Add_Click($changed)
                [void]$items.Children.Add($box)
                [void]$members.Add($box)
                [void]$boxes.Add($box)
            }
            $all.Add_Click({ param($sender) foreach ($m in $sender.Tag) { $m.IsChecked = $sender.IsChecked }; & $changed })
        }

        function Start-Setup([bool]$really) {
            $list = Join-Path $env:TEMP 'cairn-skip.txt'
            $skip = @($boxes | Where-Object { -not $_.IsChecked } | ForEach-Object { [string]$_.Tag })
            [IO.File]::WriteAllLines($list, [string[]]$skip)
            $line = '-NoExit -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $kit 'setup.ps1') + '" -Skip "' + $list + '"'
            if ($really) { $line += ' -Apply' }
            Start-Process powershell -ArgumentList $line
        }

        $preview.Add_Click({
            Start-Setup $false
            $apply.IsEnabled = $true
            $status.Text = 'The preview is in the PowerShell window that just opened. If it looks right, click Set up.'
        })
        $apply.Add_Click({
            $n = @($boxes | Where-Object { $_.IsChecked }).Count
            $answer = [System.Windows.MessageBox]::Show(
                "Set up the $n ticked items now? This installs programs, changes settings and replaces config files (your old ones are kept as .before-cairn).",
                'Cairn', 'YesNo', 'Question')
            if ($answer -eq 'Yes') {
                Start-Setup $true
                $status.Text = 'Setting up in the PowerShell window that just opened. Windows may ask for permission a few times.'
            }
        })
        $window.FindName('Checklist').Add_Click({
            Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $kit 'CHECKLIST.md') + '"')
        })
        [void]$window.ShowDialog()

        """
        return s
    }
}
