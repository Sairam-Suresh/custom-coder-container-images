#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const args = process.argv.slice(2);
let workspaceFolder = null;
let configFile = null;
let configIndex = -1;

// Parse standard CLI arguments to locate the targeted workspace or config file
for (let i = 0; i < args.length; i++) {
    if (args[i] === '--workspace-folder' || args[i] === '-w') {
        workspaceFolder = args[i + 1];
    } else if (args[i] === '--config') {
        configFile = args[i + 1];
        configIndex = i;
    }
}

// If no explicit config was passed, resolve it dynamically based on the workspace path
if (!configFile && workspaceFolder) {
    const possiblePaths = [
        path.join(workspaceFolder, '.devcontainer/devcontainer.json'),
        path.join(workspaceFolder, '.devcontainer.json')
    ];
    for (const p of possiblePaths) {
        if (fs.existsSync(p)) {
            configFile = p;
            break;
        }
    }
}

let tempConfigFile = null;

if (configFile && fs.existsSync(configFile)) {
    try {
        const originalContent = fs.readFileSync(configFile, 'utf8');
        
        // Strip out single-line (//) and multi-line (/* */) comments securely
        let cleanContent = originalContent.replace(/\\"|"(?:\\"|[^"])*"|(\/\/.*|\/\*[\s\S]*?\*\/)/g, (m, g) => g ? "" : m);
        
        // Strip trailing commas to make standard JSON parsing bulletproof
        cleanContent = cleanContent.replace(/,(\s*[\]}])/g, '$1');
        
        const configJson = JSON.parse(cleanContent);

        // 1. Prevent VS Code / Devcontainer CLI from trying to remap the container's internal UID
        configJson.updateRemoteUserUID = false;

        // 2. Safely initialize runArgs array
        if (!configJson.runArgs) {
            configJson.runArgs = [];
        } else if (typeof configJson.runArgs === 'string') {
            configJson.runArgs = [configJson.runArgs];
        } else if (!Array.isArray(configJson.runArgs)) {
            configJson.runArgs = [];
        }

        // 3. Clear existing user namespace parameters to prevent duplicate arguments
        configJson.runArgs = configJson.runArgs.filter(arg => {
            if (typeof arg !== 'string') return false;
            return !arg.startsWith('--userns');
        });

        // 4. Force empty --userns= to prevent the rootless/rootful namespace crash
        configJson.runArgs.push('--userns=');

        // Write the dynamically modified JSON inside the same directory 
        // This ensures relative Dockerfiles and context directories resolve perfectly
        const configDir = path.dirname(configFile);
        tempConfigFile = path.join(configDir, '.devcontainer-temp-coder-override.json');
        fs.writeFileSync(tempConfigFile, JSON.stringify(configJson, null, 2), 'utf8');

        // Route the command line args to use our temporary modified config file
        if (configIndex !== -1) {
            args[configIndex + 1] = tempConfigFile;
        } else {
            args.push('--config', tempConfigFile);
        }
    } catch (err) {
        // Fallback: If we fail to parse, log a warning and run the original unmodified config
        console.error("[Coder Devcontainer Wrapper] Warning: Failed to parse/modify devcontainer.json:", err.message);
    }
}

// Function to clean up the temporary untracked file immediately on exit
function cleanup() {
    if (tempConfigFile && fs.existsSync(tempConfigFile)) {
        try {
            fs.unlinkSync(tempConfigFile);
        } catch (e) {
            // Ignore deletion errors (e.g. file already cleaned up)
        }
    }
}

// Spawn the real devcontainer executable, piping in standard stream data
const realCLI = '/home/coder/.local/bin/devcontainer-real';
const child = spawn(realCLI, args, { stdio: 'inherit' });

child.on('error', (err) => {
    console.error("[Coder Devcontainer Wrapper] Fatal Error running devcontainer CLI:", err);
    cleanup();
    process.exit(1);
});

child.on('exit', (code, signal) => {
    cleanup();
    if (code !== null) {
        process.exit(code);
    } else if (signal) {
        process.kill(process.pid, signal);
    }
});

// Guard against standard exit codes to prevent orphaned temporary files
process.on('SIGINT', () => { cleanup(); process.exit(130); });
process.on('SIGTERM', () => { cleanup(); process.exit(143); });
process.on('SIGHUP', () => { cleanup(); process.exit(129); });