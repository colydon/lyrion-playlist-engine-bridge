param(
    [string]$ServerHost = '192.168.0.54',
    [string]$User = 'tc',
    [string]$PlayerName = 'Kantoor',
    [string]$PlayerId,
    [int]$Count = 20,
    [string]$SqlFile = (Join-Path $PSScriptRoot 'DagMix.sql'),
    [string]$CustomSkipFilter = '',
    [switch]$PreviewOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SshCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteCommand
    )

    $arguments = @('-o', 'StrictHostKeyChecking=no', "$User@$ServerHost", $RemoteCommand)

    $output = & ssh @arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    return ($output -join "`n").Trim()
}

function Send-FileOverScp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )

    $arguments = @('-o', 'StrictHostKeyChecking=no', $LocalPath, "$User@$ServerHost`:$RemotePath")
    $output = & scp @arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }
}

function Resolve-PlayerId {
    if ($PlayerId) {
        return $PlayerId
    }

    $payload = '{"id":1,"method":"slim.request","params":["",["players",0,100]]}'
    $jsonText = Invoke-SshCommand -RemoteCommand "curl -s -X POST -H 'Content-Type: application/json' -d '$payload' http://127.0.0.1:9000/jsonrpc.js"
    $response = $jsonText | ConvertFrom-Json
    $players = @($response.result.players_loop)

    $exactMatch = @($players | Where-Object { $_.name -eq $PlayerName })
    if ($exactMatch.Count -eq 1) {
        return $exactMatch[0].playerid
    }

    $partialMatch = @($players | Where-Object { $_.name -like "*$PlayerName*" })
    if ($partialMatch.Count -eq 1) {
        return $partialMatch[0].playerid
    }

    if ($players.Count -eq 0) {
        throw 'No LMS players were returned by the server.'
    }

    $availablePlayers = ($players | ForEach-Object { "- $($_.name) [$($_.playerid)]" }) -join "`n"
    throw "Could not resolve player '$PlayerName'. Available players:`n$availablePlayers"
}

if (-not (Test-Path -LiteralPath $SqlFile)) {
    throw "SQL file not found: $SqlFile"
}

if ($Count -lt 1) {
    throw 'Count must be at least 1.'
}

$resolvedPlayerId = Resolve-PlayerId
$sqlContent = Get-Content -LiteralPath $SqlFile -Raw

$previewOnlyValue = if ($PreviewOnly) { '1' } else { '0' }

$remoteTemplate = @'
set -eu

cat > /tmp/dagmix-run.sql <<'DAGMIX_SQL_EOF'
__SQL_CONTENT__
DAGMIX_SQL_EOF

PLAYER_ID='__PLAYER_ID__'
TRACK_COUNT='__TRACK_COUNT__'
PREVIEW_ONLY='__PREVIEW_ONLY__'
CUSTOM_SKIP_FILTER='__CUSTOM_SKIP_FILTER__'

json_post() {
    curl -s -X POST -H 'Content-Type: application/json' -d "$1" http://127.0.0.1:9000/jsonrpc.js >/dev/null
}

SQL=
SQL=$(perl -0pe 's/^\s*--.*$//mg; s/[\r\n]+/ /g; s/\s+/ /g' /tmp/dagmix-run.sql)
SQL=$(printf '%s' "$SQL" | sed "s/'PlaylistPlayer'/'$PLAYER_ID'/g")
SQL=${SQL%;}
SQL="$SQL limit $TRACK_COUNT;"

TRACK_ROWS=$(sqlite3 /usr/local/slimserver/Cache/library.db "attach '/usr/local/slimserver/prefs/persist.db' as persist; $SQL")

if [ -z "$TRACK_ROWS" ]; then
    echo "DagMix returned no tracks."
    exit 0
fi

if [ "$PREVIEW_ONLY" = "1" ]; then
    printf '%s\n' "$TRACK_ROWS"
    exit 0
fi

if [ -n "$CUSTOM_SKIP_FILTER" ]; then
    printf '%s customskip setfilter %s\n' "$PLAYER_ID" "$CUSTOM_SKIP_FILTER" | nc 127.0.0.1 9090 >/dev/null || true
fi

FIRST_ID=$(printf '%s\n' "$TRACK_ROWS" | head -n 1 | cut -d'|' -f1)

json_post "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_ID\",[\"power\",1]]}"
json_post "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_ID\",[\"playlist\",\"playtracks\",\"track.id=$FIRST_ID\"]]}"

printf '%s\n' "$TRACK_ROWS" | tail -n +2 | while IFS='|' read -r TRACK_ID TRACK_ARTIST
do
    [ -n "$TRACK_ID" ] || continue
    json_post "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_ID\",[\"playlist\",\"addtracks\",\"track.id=$TRACK_ID\"]]}"
done

json_post "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER_ID\",[\"play\"]]}"

printf 'Queued %s DagMix tracks on %s\n' "$(printf '%s\n' "$TRACK_ROWS" | wc -l | tr -d ' ')" "$PLAYER_ID"
printf '%s\n' "$TRACK_ROWS"
'@

$remoteScript = $remoteTemplate.Replace('__SQL_CONTENT__', $sqlContent.TrimEnd())
$remoteScript = $remoteScript.Replace('__PLAYER_ID__', $resolvedPlayerId)
$remoteScript = $remoteScript.Replace('__TRACK_COUNT__', $Count.ToString())
$remoteScript = $remoteScript.Replace('__PREVIEW_ONLY__', $previewOnlyValue)
$remoteScript = $remoteScript.Replace('__CUSTOM_SKIP_FILTER__', $CustomSkipFilter)

$localTempScript = Join-Path $env:TEMP ("dagmix-run-" + [guid]::NewGuid().ToString() + '.sh')
$remoteTempScript = '/tmp/' + [IO.Path]::GetFileName($localTempScript)

try {
    [IO.File]::WriteAllText($localTempScript, $remoteScript, [Text.Encoding]::ASCII)
    Send-FileOverScp -LocalPath $localTempScript -RemotePath $remoteTempScript
    $result = Invoke-SshCommand -RemoteCommand "sh $remoteTempScript; rm -f $remoteTempScript"
}
finally {
    if (Test-Path -LiteralPath $localTempScript) {
        Remove-Item -LiteralPath $localTempScript -Force
    }
}

if (-not $result) {
    Write-Output 'DagMix command finished, but returned no output.'
}
else {
    Write-Output $result
}