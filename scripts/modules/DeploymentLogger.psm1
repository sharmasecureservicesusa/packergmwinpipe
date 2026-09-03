<#
.SYNOPSIS
    DeploymentLogger module: a buffering logger that ships events to a
    Cloudflare Pipelines (or any HTTP ingest) endpoint.
.DESCRIPTION
    Exposes the DeploymentLogger class and the Get-DeploymentLogger factory.
    Scripts dot-source or Import-Module this file and then call
    Get-DeploymentLogger to obtain a logger instance. Console output is emitted
    for every event; buffered events are flushed to the ingest endpoint when
    the buffer fills or Flush() is called.
#>

class DeploymentLogger {
    [string]$Endpoint
    [string]$ApiKey
    [string]$DeploymentId
    [string]$Hostname
    [System.Collections.Generic.List[hashtable]]$Buffer

    DeploymentLogger([string]$endpoint, [string]$apiKey, [string]$deploymentId) {
        $this.Endpoint     = $endpoint
        $this.ApiKey       = $apiKey
        $this.DeploymentId = $deploymentId
        $this.Hostname     = $env:COMPUTERNAME
        $this.Buffer       = [System.Collections.Generic.List[hashtable]]::new()
    }

    # --- Log overloads ---
    [void] Log([string]$message) {
        $this.Log($message, "INFO", @{})
    }

    [void] Log([string]$message, [string]$level) {
        $this.Log($message, $level, @{})
    }

    [void] Log([string]$message, [string]$level, [hashtable]$customData) {
        $timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Write-Host "[$timestamp] [$level] $message" -ForegroundColor $(
            switch ($level) {
                "ERROR"  { [ConsoleColor]::Red }
                "WARN"   { [ConsoleColor]::Yellow }
                "NOTICE" { [ConsoleColor]::Cyan }
                default  { [ConsoleColor]::Gray }
            }
        )

        $entry = @{
            timestamp    = $timestamp
            deploymentId = $this.DeploymentId
            hostname     = $this.Hostname
            level        = $level
            message      = $message
            data         = $customData
        }

        $this.Buffer.Add($entry)

        if ($this.Buffer.Count -ge 25) {
            $this.Flush()
        }
    }

    # --- LogException overloads ---
    [void] LogException([System.Management.Automation.ErrorRecord]$err) {
        $this.LogException($err, "An unhandled exception occurred")
    }

    [void] LogException([System.Management.Automation.ErrorRecord]$err, [string]$contextMessage) {
        $meta = @{
            ExceptionMessage = $err.Exception.Message
            InvocationInfo   = $err.InvocationInfo.PositionMessage
            ScriptStackTrace = $err.ScriptStackTrace
        }
        $this.Log("$contextMessage - Error: $($err.Exception.Message)", "ERROR", $meta)
    }

    # --- Flush buffered events to the ingest endpoint ---
    [void] Flush() {
        if ($this.Buffer.Count -eq 0 -or [string]::IsNullOrWhiteSpace($this.Endpoint)) { return }

        $payload = $this.Buffer | ConvertTo-Json -Depth 5 -Compress
        $headers = @{
            "Authorization" = "Bearer $($this.ApiKey)"
            "Content-Type"  = "application/json"
        }

        try {
            Invoke-RestMethod -Uri $this.Endpoint `
                              -Method Post `
                              -Headers $headers `
                              -Body $payload `
                              -TimeoutSec 5 `
                              -ErrorAction Stop | Out-Null
            $this.Buffer.Clear()
        } catch {
            Write-Warning "Failed to flush logs to remote endpoint: $($_.Exception.Message)"
        }
    }
}

function Get-DeploymentLogger {
    [CmdletBinding()]
    param(
        [string]$IngestUrl    = $env:LOG_INGEST_URL,
        [string]$ApiKey       = $env:LOG_API_KEY,
        [string]$DeploymentId = $env:DEPLOYMENT_ID
    )

    if ([string]::IsNullOrWhiteSpace($DeploymentId)) {
        $DeploymentId = "packer-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }

    return [DeploymentLogger]::new($IngestUrl, $ApiKey, $DeploymentId)
}
