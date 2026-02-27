# Who Changed That — SQL Server Version

**A Kovoco Inc tool** to audit changes on a single SQL Server object and identify who made changes and from where.

**Zero dependencies.** Just copy two files to your server and run.

## Quick Start

```powershell
# 1. Copy the folder to your SQL Server machine
# 2. Open PowerShell and run:
.\Start-WhoChangedThat.ps1
```

Your browser opens automatically to the UI. That's it.

## What's in the Box

| File | Purpose |
|------|---------|
| `Start-WhoChangedThat.ps1` | PowerShell script — runs a local HTTP server + all SQL Server operations |
| `index.html` | The browser-based UI — served by the PowerShell script |

**No Node.js, no npm, no Python, no installers.** Uses built-in .NET `System.Data.SqlClient` for SQL Server connectivity.

## Requirements

- **Windows Server** with **PowerShell 5.1+** (standard on Windows Server 2016+)
- **SQL Server 2016+** (Standard or Enterprise — Audit requires these editions)
- A SQL login with **sysadmin** or **ALTER ANY SERVER AUDIT** permission
- The audit file output path must exist on the SQL Server machine

## How It Works

1. **Connection** — Enter SQL Server credentials (SQL Authentication via .NET SqlClient)
2. **Select Object** — Pick a database and the specific object to audit
3. **Configure Audit** — Set the path for `.sqlaudit` files, then create the audit
4. **Audit Results** — View who changed what, from which IP, hostname, and application

The tool creates a **Server Audit** + **Database Audit Specification** scoped to your single object, capturing INSERT, UPDATE, DELETE, SELECT, EXECUTE, and schema changes (ALTER/DROP/CREATE).

## Options

```powershell
# Use a different port (default: 8642)
.\Start-WhoChangedThat.ps1 -Port 9000

# Don't auto-open the browser
.\Start-WhoChangedThat.ps1 -NoBrowser
```

## Cleanup

1. In the UI, go to **Configure Audit** → click **Stop & Remove Audit**
2. Delete the `.sqlaudit` files from the output directory if no longer needed
3. Press `Ctrl+C` in the PowerShell window to stop the server

## Troubleshooting

**"Could not start listener on port 8642"**
Run PowerShell as Administrator, or use a different port with `-Port 9000`.

**"Not connected to SQL Server"**
Make sure you've connected on the Connection page first.

**"Audit path does not exist"**
The path must exist on the SQL Server machine. Create the folder first.

**Fonts not loading**
The UI uses Google Fonts (Inter, Cabin, Nunito Sans, Roboto Slab). If the server has no internet access, the UI still works — it falls back to system fonts.

## License

MIT — Kovoco Inc
