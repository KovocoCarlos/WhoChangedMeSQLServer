# Who Changed Me — SQL Server Auditor

A desktop application that audits changes to a **single SQL Server object** using SQL Server Audit. It tracks *who* made changes and *from where* (IP, hostname, application).

![Electron](https://img.shields.io/badge/Electron-28-47848F?logo=electron)
![SQL Server](https://img.shields.io/badge/SQL%20Server-2016+-CC2927?logo=microsoftsqlserver)
![License](https://img.shields.io/badge/license-MIT-blue)

## Features

- **Connect** to any SQL Server instance with SQL authentication
- **Browse** databases and objects (tables, views, stored procedures, functions, triggers)
- **Create a targeted audit** on a single object — ignores everything else
- **Read audit results** with a focus on:
  - **Who** made the change (server/database principal)
  - **From where** (client IP, hostname, application name)
  - **What** they did (INSERT, UPDATE, DELETE, ALTER, SELECT, EXECUTE)
  - **Full SQL statement** that was executed
- **Filter** results by action type
- **Summary dashboard** with unique user count, source IPs, and most common action

## Prerequisites

- **Node.js** 18+ and **npm**
- **SQL Server** 2016 or later (Audit feature requires Standard or Enterprise edition)
- The SQL login used must have **sysadmin** or **ALTER ANY SERVER AUDIT** permission
- The audit file path must exist on the **SQL Server machine** (not your local machine, unless they're the same)

## Quick Start

```bash
# Clone or navigate to the repository
cd D:\GitHub\WhoChangedMeSQLServer

# Install dependencies
npm install

# Run the app
npm start
```

## How It Works

### Step 1: Connect
Enter your SQL Server credentials and connect. The app uses SQL Authentication via the `mssql` Node.js driver.

### Step 2: Select Object
Pick a database, then select the specific object (table, view, stored proc, etc.) you want to audit.

### Step 3: Configure Audit
Provide a path on the **SQL Server machine** where `.sqlaudit` files will be written. Click **Create & Start Audit**. This creates:

1. A **Server Audit** (`WCM_Audit_{db}_{schema}_{object}`) writing to the specified file path
2. A **Database Audit Specification** scoped to your chosen object, capturing:
   - `SCHEMA_OBJECT_CHANGE_GROUP` (ALTER/DROP/CREATE on the object)
   - `INSERT`, `UPDATE`, `DELETE`, `SELECT`, `EXECUTE` on the object

### Step 4: View Results
Navigate to **Audit Results** and click refresh. The app reads the `.sqlaudit` files using `sys.fn_get_audit_file()` and displays results filtered to your object only.

## Building for Distribution

```bash
# Windows installer
npm run build:win

# macOS
npm run build:mac

# Linux
npm run build:linux
```

Built binaries will appear in the `dist/` folder.

## Project Structure

```
WhoChangedMeSQLServer/
├── package.json
├── README.md
├── .gitignore
└── src/
    ├── main/
    │   ├── main.js          # Electron main process + SQL Server IPC handlers
    │   └── preload.js        # Secure bridge between renderer and main
    └── renderer/
        └── index.html        # Full UI (HTML + CSS + JS in single file)
```

## SQL Server Permissions Required

The login used to connect needs:

| Permission | Scope | Purpose |
|---|---|---|
| `ALTER ANY SERVER AUDIT` | Server | Create/manage the server audit |
| `ALTER ANY DATABASE AUDIT` | Database | Create the database audit specification |
| `VIEW SERVER STATE` | Server | Read audit file via `sys.fn_get_audit_file` |

Or simply use a login with the **sysadmin** server role.

## Troubleshooting

**"Cannot create audit — path does not exist"**
The file path must exist on the SQL Server machine. Create the folder there first.

**"Permission denied creating audit"**
Ensure your login has `ALTER ANY SERVER AUDIT` at the server level.

**"No results showing"**
- Verify the audit is running (check the Audit Config page)
- Make sure you're pointing to the correct audit file path
- Perform a change on the audited object and refresh

**"Cannot connect"**
- Verify SQL Server is accepting TCP/IP connections on the specified port
- Check that SQL Server Authentication is enabled (mixed mode)
- Ensure `Trust Server Certificate` is checked if using a self-signed cert

## Cleanup

To remove the audit when done:
1. Go to **Configure Audit** and click **Stop & Remove Audit**
2. Delete the `.sqlaudit` files from the output directory if no longer needed

## License

MIT
