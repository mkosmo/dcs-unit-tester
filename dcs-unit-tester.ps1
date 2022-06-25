using namespace System.Text.Json
param (
	[string] $GamePath,
	[string] $TrackDirectory,
	[switch] $QuitDcsOnFinish,
	[switch] $InvertAssersion,
	[switch] $UpdateTracks,
	[switch] $Reseed,
	[switch] $Headless
)
$ErrorActionPreference = "Stop"
Add-Type -Path "$PSScriptRoot\DCS.Lua.Connector.dll"
$connector = New-Object -TypeName DCS.Lua.Connector.LuaConnector -ArgumentList "127.0.0.1","5000"
$connector.Timeout = [System.TimeSpan]::FromSeconds(0.25)
$dutAssersionRegex = '^DUT_ASSERSION=(true|false)$'
try {
	if (-Not $GamePath) {
		Write-Host "No Game Path provided, attempting to retrieve from registry" -ForegroundColor Yellow -BackgroundColor Black
		$dcsExe = .$PSScriptRoot/dcs-find.ps1 -GetExecutable
		if (Test-Path -LiteralPath $dcsExe) {
			$GamePath = $dcsExe
			Write-Host "`tFound Game Path at $dcsExe" -ForegroundColor Green -BackgroundColor Black
		}
	else {
			Write-Host "`tRegistry points to $dcsExe but file does not exist" -ForegroundColor Red -BackgroundColor Black
		}
	}
	if (-Not $GamePath) {
		Write-Host "`tDCS path not found in registry" -ForegroundColor Red -BackgroundColor Black
		exit 1
	}

	if (-Not $TrackDirectory) {
		choice /c yn /m "Search for tracks in current directory ($PWD)?"
		if ($LASTEXITCODE -eq 1) {
			$TrackDirectory = $PWD
		}
	}
	if (-Not $TrackDirectory) {
		$trackDirectoryInput = Read-Host "Enter track directory path"
		$trackDirectoryInput = $trackDirectoryInput -replace '"', ""
		if (Test-Path $trackDirectoryInput) {
			$TrackDirectory = $trackDirectoryInput
		} else {
			Write-Host "Track Directory $TrackDirectory does not exist" -ForegroundColor Red -BackgroundColor Black
		}
	}
	if (-Not $TrackDirectory) {
		Write-Host "No track directory path set" -ForegroundColor Red -BackgroundColor Black
		exit 1
	}

	function GetProcessFromPath {
		param($Path)
		return [System.IO.Path]::GetFileNameWithoutExtension($Path)
	}

	function GetProcessRunning {
		param($Path)
		return Get-Process (GetProcessFromPath $Path) -ErrorAction SilentlyContinue
	}

	function GetDCSRunning {
		return (GetProcessRunning -Path $GamePath)
	}

	function LoadTrack {
		param([string] $TrackPath)
		try {
			$lua = "local function ends_with(str, ending)
			return ending == '' or str:sub(-#ending) == ending
		end
		
		function DCS.startMission(filename)
		local command = 'mission'
		if ends_with(filename, '.trk') then
				command = 'track'
			end
			return _G.module_mission.play({ file = filename, command = command}, '', filename)
		end
		
		return DCS.startMission('{missionPath}')"
			$TrackPath = $TrackPath.Trim("`'").Trim("`"").Replace("`\", "/");
			return $connector.SendReceiveCommandAsync($lua.Replace('{missionPath}', $TrackPath)).GetAwaiter().GetResult()
		} catch [System.TimeoutException] {
			return $false;
		}
	}

	function OnMenu {
		try {
			$lua = "return DCS.getModelTime()"
			return ($connector.SendReceiveCommandAsync($lua).GetAwaiter().GetResult().Result -eq 0)
		} catch [System.TimeoutException] {
			return $false;
		}
	}

	function Ping {
		return ($connector.PingAsync().GetAwaiter().GetResult())
	}
	function Spinner {
		$symbols = @("/","-","\","|")
		return ($symbols[$global:spinIndex++ % $symbols.Length])
	}
	function Overwrite() {
		param(
			[string] $text,
			$ForegroundColor = 'white',
			$BackgroundColor = 'black'
		)
		$textLen = 0
		for ($i=0; $i -lt $text.Length; $i++) {
			if ($text[$i] -eq [char]9){
				$textLen += 8
			} else {
				$textLen += 1
			}
		}
		$text = "`r$text$(' '*($Host.UI.RawUI.WindowSize.Width - $textLen))"
		Write-Host $text -NoNewline -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
	}
	# Gets all the tracks in the track directory that do not start with a .
	$tracks = Get-ChildItem -Path $TrackDirectory -File -Recurse | Where-Object { $_.extension -eq ".trk" -and (-not $_.Name.StartsWith('.'))}
	$trackCount = ($tracks | Measure-Object).Count
	Write-Host "Found $($trackCount) tracks in $TrackDirectory"
	$trackProgress = 1
	$successCount = 0
	$stopwatch =  [system.diagnostics.stopwatch]::StartNew()
	$globalStopwatch =  [system.diagnostics.stopwatch]::StartNew()

	# Stack representing the subdirectory we are in, used for reporting correct nested test suites to TeamCity
	$testSuiteStack = New-Object Collections.Generic.List[string]

	# Run the tracks
	$tracks | ForEach-Object {
		$relativeTestPath = $([System.IO.Path]::GetRelativePath($pwd, $_.FullName))
		$testSuites = (Split-Path $relativeTestPath -Parent) -split "\\" -split "/"
		$testName = $(split-path $_.FullName -leafBase)
		if ($Headless) {
			# Finish any test suites we were in if they aren't in the new path
			$index = $testSuiteStack.Count - 1

			$testSuiteStack | Sort-Object -Descending {(++$script:i)} | % { # <= Reverse Loop
				if ($testSuites.Count -gt $index) {
					$peek = $testSuites[$index]
				} else {
					$peek = $null
				}
				if ($peek -ne $_) {
					$testSuiteStack.RemoveAt($index)
					Write-Host "##teamcity[testSuiteFinished name='$_']"
				}
				$index = $index - 1
			}

			# Start suites to match the new subdirectories
			$index = 0
			$testSuites | % {
				if ($testSuiteStack.Count -ge $index + 1) {
					$peek = $testSuiteStack[$index]
					if ($peek -ne $_) {
						$testSuiteStack.Add($_)
						Write-Host "##teamcity[testSuiteStarted name='$_']"
					}
				} else {
					$testSuiteStack.Add($_)
					Write-Host "##teamcity[testSuiteStarted name='$_']"
				}
				$index = $index + 1
			}
		}

		# Progress report
		if ($Headless) {
			Write-Host "##teamcity[progressMessage '($trackProgress/$trackCount) Running `"$relativeTestPath`"']"
		} else {
			Write-Host "`t($trackProgress/$trackCount) Running `"$relativeTestPath`""
		}

		# Start DCS
		if (-not (GetDCSRunning)){
			Overwrite "`t`t🕑 Starting DCS $(Spinner)" -F Y
			if ($trackProgress -gt 1) { sleep 10 }
			Start-Process -FilePath $GamePath -ArgumentList "-w","DCS.unittest"
		}
		while (-not (Ping)) {
			if ($Headless) { continue; }
			Overwrite "`t`t🕑 Waiting for game response $(Spinner)" -F Y
		}
		sleep 1
		while (-not (OnMenu)) {
			if ($Headless) { continue; }
			Overwrite "`t`t🕑 Waiting for menu $(Spinner)" -F Y
		}
		sleep 1

		# Report Test Start
		if ($Headless) { Write-Host "##teamcity[testStarted name='$testName' captureStandardOutput='true']" }
		if ($UpdateTracks) {
			# Update scripts in the mission incase the source scripts updated
			.$PSScriptRoot/Set-ArchiveEntry.ps1 -Archive $_.FullName -SourceFile "$PSScriptRoot\MissionScripts\OnMissionEnd.lua" -Destination "l10n/DEFAULT/OnMissionEnd.lua"
			.$PSScriptRoot/Set-ArchiveEntry.ps1 -Archive $_.FullName -SourceFile "$PSScriptRoot\MissionScripts\InitialiseNetworking.lua" -Destination "l10n/DEFAULT/InitialiseNetworking.lua"
		}
		if ($Reseed) {
			# Update track seed in the mission to make it random
			$temp = New-TemporaryFile
			try {
				$randomSeed = Get-Random -Minimum 0 -Maximum 1000000
				Set-Content -Path $temp -Value $randomSeed
				Write-Host "Setting track seed to $randomSeed"
				.$PSScriptRoot/Set-ArchiveEntry.ps1 -Archive $_.FullName -SourceFile $temp -Destination "track_data/seed"
			} finally {
				Remove-Item -Path $temp
			}
		}
		LoadTrack -TrackPath $_.FullName | out-null
		Overwrite "`t`t✅ DCS Ready" -F Green
		$output = New-Object -TypeName "System.Collections.Generic.List``1[[System.String]]";
		try {
			# Set up endpoint and start listening
			$endpoint = new-object System.Net.IPEndPoint([ipaddress]::any,1337) 
			$listener = new-object System.Net.Sockets.TcpListener $EndPoint
			$listener.start()
		
			# Wait for an incoming connection, if no connection occurs throw an exception
			$task = $listener.AcceptTcpClientAsync()
			while (-not $task.AsyncWaitHandle.WaitOne(100)) {
				if (-Not (GetDCSRunning)) {
					throw [System.TimeoutException] "❌ Track TCP Connection"
				}
			}
			$data = $task.GetAwaiter().GetResult()
			Write-Host "`t`t✅ DCS TCP Connection" -ForegroundColor Green -BackgroundColor Black
			$stopwatch.Reset();
			$stopwatch.Start();
			# Stream setup
			$stream = $data.GetStream() 
			$bytes = New-Object System.Byte[] 1024
		
			# Read data from stream and write it to host
			while (($i = $stream.Read($bytes,0,$bytes.Length)) -ne 0){
				$EncodedText = New-Object System.Text.ASCIIEncoding
				$EncodedText.GetString($bytes,0, $i).Split(';') | % {
					if (-not $_) { return }
					# Print output messages that aren't the assersion	
					if (-not ($_ -match $dutAssersionRegex)) { Write-Host "`t`t📄 $_" }
					$output.Add($_)
				}
				if (-Not (GetDCSRunning)) {
					throw [System.TimeoutException] "❌ Track ended without sending anything"
				}
			}
		} catch [Exception] {
			Write-Host "`t`tError: $($_.ToString())`n$($_.ScriptStackTrace)" -ForegroundColor Red -BackgroundColor Black
		} finally {		 
			# Close TCP connection and stop listening
			if ($listener) { $listener.stop() }
			if ($stream) { $stream.close() }
		}
		$resultSet = $false
		# Attempt to find the unit test assersion output line
		$output | ForEach-Object {
			if ($_ -match $dutAssersionRegex){
				$result = [System.Boolean]::Parse($Matches[1])
				$resultSet = $true
			}
		}
		if ($resultSet -eq $false){
			Write-Host "`t`t❌ Track did not send an assersion result, maybe crash?, assuming failed" -ForegroundColor Red -BackgroundColor Black
			$result = $FALSE
		} else {
			if ($InvertAssersion) {
				Write-Host "`t`t📄 Inverting Result was $result now $(!$result)"
				$result = (!$result)
			}
		}
		# Export result
		if ($result -eq $TRUE) {
			Write-Host "`t`t✅ Test Passed after $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green -BackgroundColor Black
			$successCount = $successCount + 1
		} else {
			Write-Host "`t`t❌ Test Failed after $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Red -BackgroundColor Black
			if ($Headless) { Write-Host "##teamcity[testFailed name='$testName' duration='$($stopwatch.Elapsed.TotalMilliseconds)']" }
		}
		if ($Headless) { Write-Host "##teamcity[testFinished name='$testName' duration='$($stopwatch.Elapsed.TotalMilliseconds)']" }
		if ($output) { $output.Clear() }
		while (-not (OnMenu)) {
			if ($Headless) { continue; }
			Overwrite "`t`t🕑 Waiting for menu $(Spinner)" -F Y
		}
		$tacviewDirectory = "~\Documents\Tacview"
		if ($Headless -and (Test-Path $tacviewDirectory)) {
			$tacviewPath = gci "$tacviewDirectory\*DCS-$testName*.acmi" | sort -Descending LastWriteTime | Select -First 1
			if (-not [string]::IsNullOrWhiteSpace($tacviewPath)) {
				Write-Host "Tacview found for $testName at $tacviewPath"
				Write-Host "##teamcity[publishArtifacts '$tacviewPath']"
				$artifactPath = split-path $tacviewPath -leaf
				Write-Host "##teamcity[testMetadata testName='$testName' type='artifact' value='$artifactPath']"
			} else {
				Write-Host "Tacview not found for $testName"
			}
		}
		$trackProgress = $trackProgress + 1
	}

	# We're finished so finish the test suites
	if ($Headless) {
		$testSuiteStack | Sort-Object -Descending {(++$script:i)} | % {
			Write-Host "##teamcity[testSuiteFinished name='$_']"
		}
	}
	if ($QuitDcsOnFinish){
		sleep 2
		try {
			$connector.SendReceiveCommandAsync("return DCS.exitProcess()").GetAwaiter().GetResult() | out-null
		} catch {
			#Ignore errors
		}
	}
	Write-Host "Finished, passed tests: " -NoNewline
	if ($successCount -eq $trackCount){
		Write-Host "✅ [$successCount/$trackCount]" -F Green -B Black -NoNewline
	} else {
		Write-Host "❌ [$successCount/$trackCount]" -F Red -B Black -NoNewline
	}
	Write-Host " in $($globalStopwatch.Elapsed.ToString('hh\:mm\:ss'))";
	if (-not $Headless -and (Get-ExecutionPolicy -Scope Process) -eq 'Bypass'){
		Read-Host "Press enter to exit"
	}
} finally {
	if ($connector) { $connector.Dispose() }
}