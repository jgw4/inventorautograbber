param(
    [Parameter(Mandatory = $true)]
    [string]$src,

    [string]$out,

    [ValidateRange(1, 20000)]
    [int]$outwidth = 2400,

    [ValidateRange(1, 20000)]
    [int]$outheight = 2400,

    [ValidateSet("png", "jpg", "bmp", "gif", "tif")]
    [string]$outext = "png",

    [string]$bg = "White",

    [ValidateSet(
        "Wireframe",
        "HiddenEdges",
        "ShadedWithHiddenEdges",
        "Shaded",
        "Realistic",
        "ShadedWithEdges",
        "WireframeNoHiddenEdges",
        "WireframeWithHiddenEdges",
        "Monochrome",
        "Watercolor",
        "Illustration",
        "TechnicalIllustration"
    )]
    [string]$viewstyle = "ShadedWithEdges",

    [string]$lightingstyle = "",

    [switch]$Recurse,

    [switch]$UseRunningInventor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Get-InventorApplication {
    param(
        [switch]$UseRunningInventor
    )

    if ($UseRunningInventor) {
        try {
            return [pscustomobject]@{
                Application = [Runtime.InteropServices.Marshal]::GetActiveObject("Inventor.Application")
                Created = $false
            }
        }
        catch {
        }
    }

    return [pscustomobject]@{
        Application = New-Object -ComObject Inventor.Application
        Created = $true
    }
}

function Get-VaultPreferencesPath {
    $path = Join-Path $env:APPDATA "Autodesk\Inventor 2026 Vault Addin\ApplicationPreferences.xml"

    if (Test-Path -LiteralPath $path) {
        return $path
    }

    return $null
}

function Set-VaultPromptPreference {
    param(
        [Parameter(Mandatory = $true)]
        [xml]$Xml,

        [Parameter(Mandatory = $true)]
        [string]$CategoryId,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $namespaceUri = $Xml.DocumentElement.NamespaceURI
    $ns = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $ns.AddNamespace("p", $namespaceUri)

    $category = $Xml.SelectSingleNode("//p:Category[@ID='$CategoryId']", $ns)
    if ($null -eq $category) {
        return
    }

    $property = $category.SelectSingleNode("p:Property[@Name='$PropertyName']", $ns)
    if ($null -eq $property) {
        $property = $Xml.CreateElement("Property", $namespaceUri)
        $null = $property.SetAttribute("Name", $PropertyName)
        $null = $property.SetAttribute("Value", $Value)
        $null = $category.AppendChild($property)
    }
    else {
        $null = $property.SetAttribute("Value", $Value)
    }
}

function Set-VaultPromptDefaultsForBatch {
    $preferencesPath = Get-VaultPreferencesPath
    if ([string]::IsNullOrWhiteSpace($preferencesPath)) {
        return
    }

    $xml = New-Object xml
    $xml.Load($preferencesPath)

    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_READONLY_WARN_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_READONLY_WARN_UserAnswer" -Value "Yes"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_CHECKOUT_LOCKED_WARN_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_CHECKOUT_LOCKED_WARN_UserAnswer" -Value "Yes"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutOnFileEdit_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutOnFileEdit_UserAnswer" -Value "Yes"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutProperties_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutProperties_UserAnswer" -Value "No"

    $xml.Save($preferencesPath)
}

function Test-InventorRunning {
    try {
        $null = [Runtime.InteropServices.Marshal]::GetActiveObject("Inventor.Application")
        return $true
    }
    catch {
        return $false
    }
}

function Wait-InventorReady {
    param(
        [Parameter(Mandatory = $true)]
        $Inventor,

        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while (-not $Inventor.Ready) {
        if ((Get-Date) -ge $deadline) {
            throw "Inventor did not finish initializing within $TimeoutSeconds seconds."
        }

        Start-Sleep -Milliseconds 500
    }
}

function New-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $sanitized = $Name

    foreach ($char in $invalidChars) {
        $sanitized = $sanitized.Replace($char, "_")
    }

    $sanitized = ($sanitized -replace "\s+", " ").Trim()

    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return "Unnamed"
    }

    return $sanitized
}

function Get-PartNumber {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    try {
        $designTracking = $Document.PropertySets.Item("Design Tracking Properties")
        $partNumber = [string]$designTracking.Item("Part Number").Value

        if (-not [string]::IsNullOrWhiteSpace($partNumber)) {
            return $partNumber.Trim()
        }
    }
    catch {
    }

    return [IO.Path]::GetFileNameWithoutExtension([string]$Document.FullFileName)
}

function Hide-DocumentHelpers {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    try {
        $objectVisibility = $Document.ObjectVisibility
    }
    catch {
        return
    }

    try { $objectVisibility.AllWorkFeatures = $false } catch {}
    try { $objectVisibility.UserWorkPlanes = $false } catch {}
    try { $objectVisibility.UserWorkAxes = $false } catch {}
    try { $objectVisibility.UserWorkPoints = $false } catch {}
    try { $objectVisibility.OriginWorkPlanes = $false } catch {}
    try { $objectVisibility.OriginWorkAxes = $false } catch {}
    try { $objectVisibility.OriginWorkPoints = $false } catch {}
    try { $objectVisibility.UCSWorkPlanes = $false } catch {}
    try { $objectVisibility.UCSWorkAxes = $false } catch {}
    try { $objectVisibility.UCSWorkPoints = $false } catch {}
    try { $objectVisibility.Sketches = $false } catch {}
    try { $objectVisibility.Sketches3D = $false } catch {}
    try { $objectVisibility.SketchDimensions = $false } catch {}
}

function Get-ImageFormatInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileType
    )

    switch ($FileType.ToLowerInvariant()) {
        "png" {
            return @{
                Extension = "png"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Png
                SupportsTransparency = $true
            }
        }
        "jpg" {
            return @{
                Extension = "jpg"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Jpeg
                SupportsTransparency = $false
            }
        }
        "bmp" {
            return @{
                Extension = "bmp"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Bmp
                SupportsTransparency = $false
            }
        }
        "gif" {
            return @{
                Extension = "gif"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Gif
                SupportsTransparency = $false
            }
        }
        "tif" {
            return @{
                Extension = "tif"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Tiff
                SupportsTransparency = $false
            }
        }
    }
}

function Get-InventorDisplayModeValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ViewStyle
    )

    $displayModes = @{
        Wireframe = 8706
        HiddenEdges = 8707
        ShadedWithHiddenEdges = 8707
        Shaded = 8708
        Realistic = 8709
        ShadedWithEdges = 8710
        WireframeNoHiddenEdges = 8711
        WireframeWithHiddenEdges = 8712
        Monochrome = 8713
        Watercolor = 8714
        Illustration = 8715
        TechnicalIllustration = 8716
    }

    return [int]$displayModes[$ViewStyle]
}

function Resolve-OutputBackground {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Background,

        [Parameter(Mandatory = $true)]
        [hashtable]$ImageFormatInfo
    )

    if ($Background.Trim().ToLowerInvariant() -eq "transparent") {
        if (-not $ImageFormatInfo.SupportsTransparency) {
            throw "Transparent background is only supported when -outext png is used."
        }

        return @{
            Mode = "Transparent"
            Color = [System.Drawing.Color]::Transparent
        }
    }

    try {
        if ($Background.Trim().StartsWith("#")) {
            $color = [System.Drawing.ColorTranslator]::FromHtml($Background)
        }
        else {
            $color = [System.Drawing.Color]::FromName($Background)
        }
    }
    catch {
        throw "Background color '$Background' is invalid. Use a named color like White, a hex value like #F5F5F5, or transparent."
    }

    if ($color.IsEmpty) {
        throw "Background color '$Background' is invalid. Use a named color like White, a hex value like #F5F5F5, or transparent."
    }

    return @{
        Mode = "Solid"
        Color = $color
    }
}

function Write-InventorProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$FileNumber,

        [Parameter(Mandatory = $true)]
        [int]$TotalFiles,

        [Parameter(Mandatory = $true)]
        [int]$CompletedFiles,

        [Parameter(Mandatory = $true)]
        [int]$FilePercent,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Elapsed
    )

    $effectiveCompletedFiles = [Math]::Min($TotalFiles, $CompletedFiles + ($FilePercent / 100.0))
    $jobPercent = [int][Math]::Floor(($effectiveCompletedFiles / $TotalFiles) * 100)
    $etaCompletedFiles = [Math]::Min($TotalFiles, $CompletedFiles + [int]($FilePercent -ge 100))
    $etaSeconds = $null
    $etaText = "calculating"

    if ($etaCompletedFiles -ge $TotalFiles) {
        $etaSeconds = 0
        $etaText = "00:00:00"
    }
    elseif ($etaCompletedFiles -gt 0 -and $Elapsed.Elapsed.TotalSeconds -gt 0) {
        $averageSecondsPerFile = $Elapsed.Elapsed.TotalSeconds / $etaCompletedFiles
        $etaSeconds = [int][Math]::Ceiling($averageSecondsPerFile * ($TotalFiles - $etaCompletedFiles))
        $etaHours = [int][Math]::Floor($etaSeconds / 3600)
        $etaMinutes = [int][Math]::Floor(($etaSeconds % 3600) / 60)
        $etaRemainderSeconds = $etaSeconds % 60
        $etaText = "{0:00}:{1:00}:{2:00}" -f $etaHours, $etaMinutes, $etaRemainderSeconds
    }

    $jobProgress = @{
        Id = 1
        Activity = "InventorAutoGrabber job"
        Status = "File {0} of {1}: {2} | Job ETA: {3}" -f $FileNumber, $TotalFiles, $FileName, $etaText
        PercentComplete = $jobPercent
    }

    if ($null -ne $etaSeconds) {
        $jobProgress.SecondsRemaining = $etaSeconds
    }

    Write-Progress @jobProgress
    Write-Progress `
        -Id 2 `
        -ParentId 1 `
        -Activity ("File {0} of {1}: {2}" -f $FileNumber, $TotalFiles, $FileName) `
        -Status $Stage `
        -PercentComplete $FilePercent
}

function Write-RunLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,

        [Parameter(Mandatory = $true)]
        [int]$DiscoveredFiles,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$FailedFiles,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SkippedFiles
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $logPath = Join-Path $OutputDirectory ("iag-run-{0}.log" -f $timestamp)
    $suffix = 1
    while (Test-Path -LiteralPath $logPath) {
        $logPath = Join-Path $OutputDirectory ("iag-run-{0}-{1}.log" -f $timestamp, $suffix)
        $suffix++
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $null = $lines.Add("InventorAutoGrabber run report")
    $null = $lines.Add(("Started: {0:yyyy-MM-dd HH:mm:ss}" -f $StartedAt))
    $null = $lines.Add(("Finished: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)))
    $null = $lines.Add(("Source: {0}" -f $SourceDirectory))
    $null = $lines.Add(("Files discovered: {0}" -f $DiscoveredFiles))
    $null = $lines.Add(("Failed files: {0}" -f $FailedFiles.Count))
    $null = $lines.Add(("Skipped files: {0}" -f $SkippedFiles.Count))
    $null = $lines.Add("")
    $null = $lines.Add("FAILED FILES")

    if ($FailedFiles.Count -eq 0) {
        $null = $lines.Add("(none)")
    }
    else {
        foreach ($entry in $FailedFiles) {
            $null = $lines.Add(("{0} -- {1}" -f $entry.Path, $entry.Reason))
        }
    }

    $null = $lines.Add("")
    $null = $lines.Add("SKIPPED FILES")
    if ($SkippedFiles.Count -eq 0) {
        $null = $lines.Add("(none)")
    }
    else {
        foreach ($entry in $SkippedFiles) {
            $null = $lines.Add(("{0} -- {1}" -f $entry.Path, $entry.Reason))
        }
    }

    [IO.File]::WriteAllLines($logPath, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    return $logPath
}

function Save-IsometricSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        $Inventor,

        [Parameter(Mandatory = $true)]
        $Document,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [int]$OutputWidth,

        [Parameter(Mandatory = $true)]
        [int]$OutputHeight,

        [Parameter(Mandatory = $true)]
        [hashtable]$ImageFormatInfo,

        [Parameter(Mandatory = $true)]
        [hashtable]$BackgroundStyle,

        [Parameter(Mandatory = $true)]
        [string]$BackgroundDescription,

        [Parameter(Mandatory = $true)]
        [string]$ViewStyle,

        [string]$LightingStyle,

        [scriptblock]$ProgressCallback
    )

    $captureStep = "getting active view"

    try {
        $view = $Inventor.ActiveView

        if (-not [string]::IsNullOrWhiteSpace($LightingStyle)) {
            $captureStep = "finding lighting style '$LightingStyle'"
            $lightingStyles = $Document.LightingStyles
            $availableLightingStyles = New-Object 'System.Collections.Generic.List[string]'
            $selectedLightingStyle = $null

            for ($styleIndex = 1; $styleIndex -le $lightingStyles.Count; $styleIndex++) {
                $candidateStyle = $lightingStyles.Item($styleIndex)
                $null = $availableLightingStyles.Add([string]$candidateStyle.Name)
                if ($candidateStyle.Name -ieq $LightingStyle) {
                    $selectedLightingStyle = $candidateStyle
                }
            }

            if ($null -eq $selectedLightingStyle) {
                $availableNames = if ($availableLightingStyles.Count -gt 0) { $availableLightingStyles -join ", " } else { "none" }
                throw "Lighting style '$LightingStyle' is not available for '$($Document.FullFileName)'. Available styles: $availableNames."
            }

            $captureStep = "applying lighting style '$LightingStyle'"
            $Document.ActiveLightingStyle = $selectedLightingStyle
        }

        $captureStep = "hiding work features and sketches"
        Hide-DocumentHelpers -Document $Document

        $captureStep = "setting view style to $ViewStyle"
        $view.DisplayMode = Get-InventorDisplayModeValue -ViewStyle $ViewStyle

        $captureStep = "updating view"
        $view.Update()

        $orientations = @(
            @{ Label = "iso_top_right"; Value = 10759 }  # kIsoTopRightViewOrientation
            @{ Label = "iso_top_left"; Value = 10760 }   # kIsoTopLeftViewOrientation
            @{ Label = "iso_bottom_right"; Value = 10761 } # kIsoBottomRightViewOrientation
            @{ Label = "iso_bottom_left"; Value = 10762 }  # kIsoBottomLeftViewOrientation
        )

        $baseName = New-SafeFileName -Name (Get-PartNumber -Document $Document)
        $bitmapOptions = $Inventor.TransientObjects.CreateNameValueMap()
        $bitmapOptions.Add("TransparentBackground", $true)

        $warmupPath = Join-Path -Path $OutputDirectory -ChildPath "__inventor_snapshot_warmup.tmp.png"
        if (Test-Path -LiteralPath $warmupPath) {
            Remove-Item -LiteralPath $warmupPath -Force
        }

        $captureStep = "warming up first render"
        $warmupCamera = $view.Camera
        $warmupCamera.ViewOrientationType = 10759 # kIsoTopRightViewOrientation
        $warmupCamera.Fit()
        $warmupCamera.Apply()
        Start-Sleep -Milliseconds 300
        $view.Update()
        $view.SaveAsBitmapWithOptions(
            [string]$warmupPath,
            [int]$OutputWidth,
            [int]$OutputHeight,
            $bitmapOptions
        )

        if (Test-Path -LiteralPath $warmupPath) {
            Remove-Item -LiteralPath $warmupPath -Force
        }

        if ($null -ne $ProgressCallback) {
            & $ProgressCallback 20 "Preparing views"
        }

        $orientationIndex = 0
        foreach ($orientation in $orientations) {
            $captureStep = "getting camera for $($orientation.Label)"
            $camera = $view.Camera

            $captureStep = "setting orientation to $($orientation.Label)"
            $camera.ViewOrientationType = $orientation.Value

            $captureStep = "fitting camera for $($orientation.Label)"
            $camera.Fit()

            $captureStep = "applying camera for $($orientation.Label)"
            $camera.Apply()

            Start-Sleep -Milliseconds 200

            $captureStep = "updating view for $($orientation.Label)"
            $view.Update()

            $candidateName = "{0}_{1}.{2}" -f $baseName, $orientation.Label, $ImageFormatInfo.Extension
            $targetPath = Join-Path -Path $OutputDirectory -ChildPath $candidateName
            $suffix = 1

            while (Test-Path -LiteralPath $targetPath) {
                $candidateName = "{0}_{1}_{2}.{3}" -f $baseName, $orientation.Label, $suffix, $ImageFormatInfo.Extension
                $targetPath = Join-Path -Path $OutputDirectory -ChildPath $candidateName
                $suffix++
            }

            $tempCapturePath = Join-Path -Path $OutputDirectory -ChildPath ([IO.Path]::GetFileNameWithoutExtension($targetPath) + ".tmp.png")
            if (Test-Path -LiteralPath $tempCapturePath) {
                Remove-Item -LiteralPath $tempCapturePath -Force
            }

            $captureStep = "saving transparent bitmap for $($orientation.Label)"
            $view.SaveAsBitmapWithOptions(
                [string]$tempCapturePath,
                [int]$OutputWidth,
                [int]$OutputHeight,
                $bitmapOptions
            )

            try {
                if ($BackgroundStyle.Mode -eq "Transparent") {
                    $captureStep = "saving transparent output for $($orientation.Label)"
                    Move-Item -LiteralPath $tempCapturePath -Destination $targetPath -Force
                }
                else {
                    $captureStep = "flattening bitmap to $BackgroundDescription background for $($orientation.Label)"
                    $sourceImage = [System.Drawing.Image]::FromFile($tempCapturePath)
                    $compositedBitmap = $null

                    try {
                        $compositedBitmap = New-Object System.Drawing.Bitmap $OutputWidth, $OutputHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

                        $graphics = [System.Drawing.Graphics]::FromImage($compositedBitmap)

                        try {
                            $graphics.Clear($BackgroundStyle.Color)
                            $graphics.DrawImage($sourceImage, 0, 0, $OutputWidth, $OutputHeight)
                        }
                        finally {
                            $graphics.Dispose()
                        }
                    }
                    finally {
                        $sourceImage.Dispose()
                    }

                    $compositedBitmap.Save($targetPath, $ImageFormatInfo.ImageFormat)
                }
            }
            finally {
                if ($null -ne $compositedBitmap) {
                    $compositedBitmap.Dispose()
                }

                if (Test-Path -LiteralPath $tempCapturePath) {
                    Remove-Item -LiteralPath $tempCapturePath -Force
                }
            }

            $orientationIndex++
            if ($null -ne $ProgressCallback) {
                $filePercent = 20 + [int][Math]::Round(($orientationIndex / $orientations.Count) * 70)
                & $ProgressCallback $filePercent ("Saved {0} of {1} views" -f $orientationIndex, $orientations.Count)
            }
        }
    }
    catch {
        throw "Snapshot step '$captureStep' failed: $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($out)) {
    $out = Join-Path -Path $PSScriptRoot -ChildPath "output"
}

$resolvedSource = (Resolve-Path -LiteralPath $src).Path
$resolvedOutputDirectory = [IO.Path]::GetFullPath($out)
$imageFormatInfo = Get-ImageFormatInfo -FileType $outext
$backgroundStyle = Resolve-OutputBackground -Background $bg -ImageFormatInfo $imageFormatInfo

if (-not (Test-Path -LiteralPath $resolvedOutputDirectory)) {
    New-Item -ItemType Directory -Path $resolvedOutputDirectory | Out-Null
}

$searchOptions = @{
    LiteralPath = $resolvedSource
    File = $true
}

if ($Recurse) {
    $searchOptions.Recurse = $true
}

$runStartedAt = Get-Date
$failedFiles = New-Object 'System.Collections.Generic.List[object]'
$skippedFiles = New-Object 'System.Collections.Generic.List[object]'
$sourceFiles = @(Get-ChildItem @searchOptions | Sort-Object FullName)
$files = @($sourceFiles |
    Where-Object { $_.Extension -in ".ipt", ".iam" } |
    Sort-Object FullName)

foreach ($sourceFile in $sourceFiles) {
    if ($sourceFile.Extension -notin ".ipt", ".iam") {
        $skippedFiles.Add([pscustomobject]@{
            Path = $sourceFile.FullName
            Reason = "Unsupported file extension '$($sourceFile.Extension)'."
        })
    }
}

if (-not $files) {
    $logPath = Write-RunLog `
        -OutputDirectory $resolvedOutputDirectory `
        -SourceDirectory $resolvedSource `
        -StartedAt $runStartedAt `
        -DiscoveredFiles $sourceFiles.Count `
        -FailedFiles @() `
        -SkippedFiles $skippedFiles.ToArray()
    throw "No .ipt or .iam files were found in '$resolvedSource'. Run log: '$logPath'."
}

if (-not $UseRunningInventor -and (Test-InventorRunning)) {
    throw "An Inventor session is already running. Close Inventor first, or rerun with -UseRunningInventor if you want to attach to the current session."
}

if (-not $UseRunningInventor) {
    Set-VaultPromptDefaultsForBatch
}

$inventorSession = Get-InventorApplication -UseRunningInventor:$UseRunningInventor
$inventor = $inventorSession.Application
$createdInventor = $inventorSession.Created
$settingsCaptured = $false
$files = @($files)
$totalFiles = $files.Count
$completedFiles = 0
$jobStopwatch = New-Object System.Diagnostics.Stopwatch
$runLogPath = $null

try {
    $inventor.Visible = $true
    Wait-InventorReady -Inventor $inventor

    $originalScreenUpdating = $inventor.ScreenUpdating
    $originalSilentOperation = $inventor.SilentOperation
    $settingsCaptured = $true

    $inventor.ScreenUpdating = $false
    $inventor.SilentOperation = $true

    $jobStopwatch.Start()

    foreach ($file in $files) {
        $document = $null
        $fileFailureReasons = New-Object 'System.Collections.Generic.List[string]'
        $fileNumber = $completedFiles + 1
        $progressWriter = ${function:Write-InventorProgress}
        $progressCallback = {
            param(
                [int]$FilePercent,
                [string]$Stage
            )

            & $progressWriter `
                -FileNumber $fileNumber `
                -TotalFiles $totalFiles `
                -CompletedFiles $completedFiles `
                -FilePercent $FilePercent `
                -FileName $file.Name `
                -Stage $Stage `
                -Elapsed $jobStopwatch
        }.GetNewClosure()

        $fileFailed = $false
        & $progressCallback 0 "Opening document"

        try {
            Write-Host ("Processing {0}" -f $file.FullName)

            $currentStep = "opening document"
            $document = $inventor.Documents.Open([string]$file.FullName)
            & $progressCallback 10 "Document opened"

            $currentStep = "activating document"
            $document.Activate()
            & $progressCallback 15 "Document activated"

            $currentStep = "capturing snapshots"
            Save-IsometricSnapshots `
                -Inventor $inventor `
                -Document $document `
                -OutputDirectory $resolvedOutputDirectory `
                -OutputWidth $outwidth `
                -OutputHeight $outheight `
                -ImageFormatInfo $imageFormatInfo `
                -BackgroundStyle $backgroundStyle `
                -BackgroundDescription $bg `
                -ViewStyle $viewstyle `
                -LightingStyle $lightingstyle `
                -ProgressCallback $progressCallback
        }
        catch {
            $fileFailed = $true
            $fileFailureReasons.Add(("{0}: {1}" -f $currentStep, $_.Exception.Message))
            Write-Warning ("Failed to process '{0}' while {1}: {2}" -f $file.FullName, $currentStep, $_.Exception.Message)
        }
        finally {
            if ($null -ne $document) {
                try {
                    $document.Close($true)
                }
                catch {
                    $fileFailed = $true
                    $fileFailureReasons.Add(("closing document: {0}" -f $_.Exception.Message))
                    Write-Warning ("Failed to close '{0}': {1}" -f $file.FullName, $_.Exception.Message)
                }
                finally {
                    try {
                        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($document)
                    }
                    catch {
                        $fileFailed = $true
                        $fileFailureReasons.Add(("releasing document reference: {0}" -f $_.Exception.Message))
                        Write-Warning ("Failed to release the document reference for '{0}': {1}" -f $file.FullName, $_.Exception.Message)
                    }

                    $document = $null
                }
            }

            if ($fileFailed) {
                $failedFiles.Add([pscustomobject]@{
                    Path = $file.FullName
                    Reason = $fileFailureReasons -join "; "
                })
            }

            $completionStatus = if ($fileFailed) { "Finished with errors" } else { "Complete" }
            & $progressCallback 100 $completionStatus
            $completedFiles++
        }
    }
}
catch {
    $abortReason = "Not processed because the job stopped: $($_.Exception.Message)"
    for ($fileIndex = $completedFiles; $fileIndex -lt $totalFiles; $fileIndex++) {
        $skippedFiles.Add([pscustomobject]@{
            Path = $files[$fileIndex].FullName
            Reason = $abortReason
        })
    }

    throw
}
finally {
    $jobStopwatch.Stop()
    Write-Progress -Id 2 -Completed
    Write-Progress -Id 1 -Completed

    if ($settingsCaptured) {
        try {
            $inventor.ScreenUpdating = $originalScreenUpdating
            $inventor.SilentOperation = $originalSilentOperation
        }
        catch {
            Write-Warning ("Failed to restore Inventor settings: {0}" -f $_.Exception.Message)
        }
    }

    if ($createdInventor) {
        try {
            $inventor.Quit()
        }
        catch {
            Write-Warning ("Failed to close the Inventor session: {0}" -f $_.Exception.Message)
        }
        finally {
            try {
                $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($inventor)
            }
            catch {
                Write-Warning ("Failed to release the Inventor application reference: {0}" -f $_.Exception.Message)
            }
        }
    }

    try {
        $runLogPath = Write-RunLog `
            -OutputDirectory $resolvedOutputDirectory `
            -SourceDirectory $resolvedSource `
            -StartedAt $runStartedAt `
            -DiscoveredFiles $sourceFiles.Count `
            -FailedFiles $failedFiles.ToArray() `
            -SkippedFiles $skippedFiles.ToArray()
        Write-Host ("Run log written to: {0}" -f $runLogPath)
    }
    catch {
        Write-Warning ("Failed to write the run log: {0}" -f $_.Exception.Message)
    }
}

Write-Host ("Finished. {0} files were saved to: {1}" -f $imageFormatInfo.Extension.ToUpperInvariant(), $resolvedOutputDirectory)
