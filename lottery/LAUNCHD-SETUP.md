# Setting Up Automated Jackpot Checking with launchd

This guide shows you how to schedule the jackpot checker to run automatically
every 4 hours on macOS using launchd.

## Quick Setup

Copy the plist file to your LaunchAgents directory and load it:

```bash
# Copy the plist file
cp net.chicks.lottery.jackpot-checker.plist ~/Library/LaunchAgents/

# Load the job
launchctl load ~/Library/LaunchAgents/net.chicks.lottery.jackpot-checker.plist

# Start it immediately (optional - RunAtLoad already does this)
launchctl start net.chicks.lottery.jackpot-checker
```

That's it! The checker will now run every 4 hours.

## Verifying It Works

Check if the job is loaded:

```bash
launchctl list | grep jackpot-checker
```

You should see output like:

```text
-    0    net.chicks.lottery.jackpot-checker
```

Check the logs:

```bash
tail -f lottery/jackpot-checker.log
```

## Managing the Job

### Stop the job

```bash
launchctl stop net.chicks.lottery.jackpot-checker
```

### Unload the job (disable it)

```bash
launchctl unload ~/Library/LaunchAgents/net.chicks.lottery.jackpot-checker.plist
```

### Reload after making changes

```bash
launchctl unload ~/Library/LaunchAgents/net.chicks.lottery.jackpot-checker.plist
cp net.chicks.lottery.jackpot-checker.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/net.chicks.lottery.jackpot-checker.plist
```

## Customizing the Schedule

The plist file uses `StartInterval` set to 14400 seconds (4 hours). To change
the frequency, edit the plist file:

```xml
<!-- Run every 4 hours (14400 seconds) -->
<key>StartInterval</key>
<integer>14400</integer>
```

Common intervals:

- Every hour: `3600`
- Every 2 hours: `7200`
- Every 6 hours: `21600`
- Every 12 hours: `43200`
- Daily: `86400`

### Alternative: Run at Specific Times

If you want to run at specific times instead of intervals, replace
`StartInterval` with `StartCalendarInterval`:

```xml
<!-- Run twice daily at 8 AM and 8 PM -->
<key>StartCalendarInterval</key>
<array>
    <dict>
        <key>Hour</key>
        <integer>8</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <dict>
        <key>Hour</key>
        <integer>20</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
</array>
```

## Log Files

The plist configuration creates two log files in the lottery directory:

- `jackpot-checker.log` - Standard output (successful runs)
- `jackpot-checker.err` - Error output (failures)

View recent activity:

```bash
tail -20 lottery/jackpot-checker.log
```

Check for errors:

```bash
tail -20 lottery/jackpot-checker.err
```

## Troubleshooting

### Job won't load

Check for syntax errors in the plist:

```bash
plutil -lint ~/Library/LaunchAgents/net.chicks.lottery.jackpot-checker.plist
```

### Job loads but doesn't run

1. Check the logs for errors
2. Verify the Go binary path is correct:

   ```bash
   which go
   ```

   If it's not at `/usr/local/bin/go`, update the plist file with the correct path.

3. Make sure the working directory path is correct
4. Check permissions on the lottery directory

### Missing Go binary error

The plist file assumes Go is installed at `/usr/local/bin/go`. If you installed
Go via Homebrew or in a different location, update the plist:

```bash
# Find your Go installation
which go

# Update the plist ProgramArguments with the correct path
```

## Why launchd Instead of Cron?

macOS uses launchd as its primary job scheduler. While cron still works, launchd
provides better integration with macOS including:

- Automatic restart on failure
- Better logging
- Runs even when not logged in
- More flexible scheduling options
- Resource management

## Notes

- The job runs with `Nice` priority 1, meaning it yields to other processes
- `RunAtLoad` is set to true, so it runs immediately when loaded
- The job doesn't keep alive - it runs, completes, and waits for the next interval
- Logs are appended, not rotated - you may want to clean them periodically

## Viewing Historical Data

After running for a while, check your collected data:

```bash
sqlite3 lottery/jackpots.db "
SELECT
  game,
  COUNT(*) as checks,
  MIN(jackpot/1000000) as min_millions,
  MAX(jackpot/1000000) as max_millions,
  AVG(jackpot/1000000) as avg_millions
FROM jackpots
GROUP BY game;
"
```

Or use Datasette for a nicer interface:

```bash
datasette lottery/jackpots.db -o
```
