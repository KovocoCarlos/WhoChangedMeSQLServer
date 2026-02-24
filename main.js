const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const sql = require('mssql');

let mainWindow;
let currentPool = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 900,
    minHeight: 600,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    },
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#0a0e17',
    show: false
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (currentPool) {
    currentPool.close().catch(() => {});
  }
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

// ─── IPC Handlers ──────────────────────────────────────────────────────────────

ipcMain.handle('test-connection', async (event, config) => {
  try {
    const pool = await new sql.ConnectionPool({
      server: config.server,
      port: parseInt(config.port) || 1433,
      database: config.database,
      user: config.username,
      password: config.password,
      options: {
        encrypt: config.encrypt || false,
        trustServerCertificate: config.trustCert || true
      },
      connectionTimeout: 10000
    }).connect();
    await pool.close();
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('connect', async (event, config) => {
  try {
    if (currentPool) {
      await currentPool.close().catch(() => {});
    }
    currentPool = await new sql.ConnectionPool({
      server: config.server,
      port: parseInt(config.port) || 1433,
      database: config.database,
      user: config.username,
      password: config.password,
      options: {
        encrypt: config.encrypt || false,
        trustServerCertificate: config.trustCert || true
      },
      connectionTimeout: 15000,
      requestTimeout: 30000
    }).connect();
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('disconnect', async () => {
  try {
    if (currentPool) {
      await currentPool.close();
      currentPool = null;
    }
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('get-databases', async () => {
  try {
    if (!currentPool) throw new Error('Not connected');
    const result = await currentPool.request().query(`
      SELECT name FROM sys.databases
      WHERE state_desc = 'ONLINE'
        AND name NOT IN ('master','tempdb','model','msdb')
      ORDER BY name
    `);
    return { success: true, data: result.recordset.map(r => r.name) };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('get-objects', async (event, database) => {
  try {
    if (!currentPool) throw new Error('Not connected');
    const result = await currentPool.request().query(`
      USE [${database}];
      SELECT
        s.name AS schema_name,
        o.name AS object_name,
        o.type_desc AS object_type,
        s.name + '.' + o.name AS full_name
      FROM sys.objects o
      JOIN sys.schemas s ON o.schema_id = s.schema_id
      WHERE o.type IN ('U','V','P','FN','IF','TF','TR')
        AND o.is_ms_shipped = 0
      ORDER BY o.type_desc, s.name, o.name
    `);
    return { success: true, data: result.recordset };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// Check if a server audit and database audit spec already exist for the target
ipcMain.handle('check-existing-audit', async (event, { database, schemaName, objectName }) => {
  try {
    if (!currentPool) throw new Error('Not connected');
    const auditName = `WCM_Audit_${database}_${schemaName}_${objectName}`;

    // Check for existing server audit
    const auditResult = await currentPool.request().query(`
      SELECT name, status_desc, log_file_path
      FROM sys.server_audits
      WHERE name = '${auditName}'
    `);

    if (auditResult.recordset.length > 0) {
      const audit = auditResult.recordset[0];
      // Check for database audit specification
      const specResult = await currentPool.request().query(`
        USE [${database}];
        SELECT name, is_state_enabled
        FROM sys.database_audit_specifications
        WHERE name = '${auditName}_Spec'
      `);
      return {
        success: true,
        exists: true,
        audit: audit,
        spec: specResult.recordset.length > 0 ? specResult.recordset[0] : null
      };
    }
    return { success: true, exists: false };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// Create the audit targeting a single object
ipcMain.handle('create-audit', async (event, { database, schemaName, objectName, auditFilePath }) => {
  try {
    if (!currentPool) throw new Error('Not connected');

    const auditName = `WCM_Audit_${database}_${schemaName}_${objectName}`;
    const specName = `${auditName}_Spec`;

    // Ensure the directory exists (SQL Server needs it)
    // The user must ensure the folder exists on the SQL Server machine

    // 1. Create server audit (file-based)
    await currentPool.request().query(`
      IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '${auditName}')
      BEGIN
        CREATE SERVER AUDIT [${auditName}]
        TO FILE (
          FILEPATH = '${auditFilePath.replace(/'/g, "''")}',
          MAXSIZE = 100 MB,
          MAX_ROLLOVER_FILES = 10,
          RESERVE_DISK_SPACE = OFF
        )
        WITH (
          QUEUE_DELAY = 1000,
          ON_FAILURE = CONTINUE
        );
      END
    `);

    // 2. Enable the server audit
    await currentPool.request().query(`
      IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '${auditName}' AND status_desc = 'STOPPED')
        ALTER SERVER AUDIT [${auditName}] WITH (STATE = ON);
    `);

    // 3. Create database audit specification for the specific object
    await currentPool.request().query(`
      USE [${database}];
      IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = '${specName}')
      BEGIN
        CREATE DATABASE AUDIT SPECIFICATION [${specName}]
        FOR SERVER AUDIT [${auditName}]
        ADD (SCHEMA_OBJECT_CHANGE_GROUP),
        ADD (INSERT ON OBJECT::[${schemaName}].[${objectName}] BY [public]),
        ADD (UPDATE ON OBJECT::[${schemaName}].[${objectName}] BY [public]),
        ADD (DELETE ON OBJECT::[${schemaName}].[${objectName}] BY [public]),
        ADD (SELECT ON OBJECT::[${schemaName}].[${objectName}] BY [public]),
        ADD (EXECUTE ON OBJECT::[${schemaName}].[${objectName}] BY [public])
        WITH (STATE = ON);
      END
    `);

    return { success: true, auditName, specName };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// Stop and remove the audit
ipcMain.handle('remove-audit', async (event, { database, schemaName, objectName }) => {
  try {
    if (!currentPool) throw new Error('Not connected');
    const auditName = `WCM_Audit_${database}_${schemaName}_${objectName}`;
    const specName = `${auditName}_Spec`;

    // Disable and drop database audit specification
    try {
      await currentPool.request().query(`
        USE [${database}];
        IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = '${specName}')
        BEGIN
          ALTER DATABASE AUDIT SPECIFICATION [${specName}] WITH (STATE = OFF);
          DROP DATABASE AUDIT SPECIFICATION [${specName}];
        END
      `);
    } catch (e) { /* spec may not exist */ }

    // Disable and drop server audit
    try {
      await currentPool.request().query(`
        IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '${auditName}')
        BEGIN
          ALTER SERVER AUDIT [${auditName}] WITH (STATE = OFF);
          DROP SERVER AUDIT [${auditName}];
        END
      `);
    } catch (e) { /* audit may not exist */ }

    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// Read audit file results
ipcMain.handle('read-audit', async (event, { database, schemaName, objectName, auditFilePath }) => {
  try {
    if (!currentPool) throw new Error('Not connected');
    const auditName = `WCM_Audit_${database}_${schemaName}_${objectName}`;

    // Use sys.fn_get_audit_file to read the audit log
    // Filter to only the object we care about
    const result = await currentPool.request().query(`
      SELECT
        event_time,
        action_id,
        CASE action_id
          WHEN 'IN' THEN 'INSERT'
          WHEN 'UP' THEN 'UPDATE'
          WHEN 'DL' THEN 'DELETE'
          WHEN 'SL' THEN 'SELECT'
          WHEN 'EX' THEN 'EXECUTE'
          WHEN 'AL' THEN 'ALTER'
          WHEN 'CR' THEN 'CREATE'
          WHEN 'DR' THEN 'DROP'
          ELSE action_id
        END AS action_name,
        succeeded,
        server_principal_name,
        database_principal_name,
        server_instance_name,
        database_name,
        schema_name,
        object_name,
        statement,
        client_ip,
        application_name,
        host_name,
        session_id,
        transaction_id,
        class_type
      FROM sys.fn_get_audit_file('${auditFilePath.replace(/'/g, "''")}\\*.sqlaudit', DEFAULT, DEFAULT)
      WHERE (
        (object_name = '${objectName}' AND schema_name = '${schemaName}')
        OR (
          class_type IN ('OB','SC')
          AND statement LIKE '%${objectName}%'
        )
      )
      ORDER BY event_time DESC
    `);

    return { success: true, data: result.recordset };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// Get audit status
ipcMain.handle('get-audit-status', async (event, { database, schemaName, objectName }) => {
  try {
    if (!currentPool) throw new Error('Not connected');
    const auditName = `WCM_Audit_${database}_${schemaName}_${objectName}`;

    const result = await currentPool.request().query(`
      SELECT
        sa.name AS audit_name,
        sa.status_desc AS audit_status,
        sa.log_file_path
      FROM sys.server_audits sa
      WHERE sa.name = '${auditName}'
    `);

    if (result.recordset.length === 0) {
      return { success: true, active: false };
    }

    const specResult = await currentPool.request().query(`
      USE [${database}];
      SELECT name, is_state_enabled
      FROM sys.database_audit_specifications
      WHERE name = '${auditName}_Spec'
    `);

    return {
      success: true,
      active: true,
      audit: result.recordset[0],
      spec: specResult.recordset.length > 0 ? specResult.recordset[0] : null
    };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// Select folder dialog
ipcMain.handle('select-folder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory'],
    title: 'Select Audit File Output Directory (Who Changed That)'
  });
  if (result.canceled) return { success: false };
  return { success: true, path: result.filePaths[0] };
});
